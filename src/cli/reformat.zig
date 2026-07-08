//! The `fmt` and `convert` actions' cores: parse a slice under one format and
//! re-emit it, either in the same format (`reformatSlice`) or a different one
//! (`convertSlice`), sharing `get`'s parse-error/authoring-warning reporting
//! and lossy-conversion diagnostics so both actions' stderr output matches
//! `get`'s for the same file.
const std = @import("std");
const fig = @import("fig");
const build_options = @import("build_options");

const types = @import("types.zig");
const parse_dispatch = @import("parse_dispatch.zig");
const diag_report = @import("diag_report.zig");

const Format = types.Format;
const Io = std.Io;

/// Parse `content` as `format` and re-emit it in the *same* format — the `fmt`
/// action's core, and `get`'s twin minus the cross-format machinery: since the
/// output format always equals the input, there's no YAML reference-layer
/// materialization and no `--lossless` envelope pass to consider (those only
/// matter when `from != to`). Returns the reformatted bytes (caller-owned).
pub fn reformatSlice(
    allocator: std.mem.Allocator,
    term: *Io.Terminal,
    file_path: []const u8,
    format: Format,
    content: []const u8,
    serialize: fig.AST.SerializeOptions,
    quiet: bool,
    strict: bool,
) !([]u8) {
    if (format == .gron) {
        try term.writer.print("error: cannot format gron (a CLI projection, not a stored document format).\n", .{});
        try term.writer.flush();
        return error.UnsupportedGronFmt;
    }

    var fig_report: fig.Language.FIG.Parser.Report = .{};
    var json_report: fig.Language.JSON.Parser.Report = .{};
    var toml_report: fig.Language.TOML.Parser.Report = .{};
    const doc = parse_dispatch.parseSliceAs(format, .{}, allocator, content, false, .{ .fig = &fig_report, .json = &json_report, .toml = &toml_report }) catch |err| {
        if (fig_report.diag) |d|
            try diag_report.reportParseError(term, content, file_path, d.offset, d.end, fig.Language.FIG.Parser.describe(d.code), fig.Language.FIG.Parser.shortLabel(d.code));
        if (json_report.diag) |d|
            try diag_report.reportParseError(term, content, file_path, d.offset, d.end, fig.Language.JSON.Parser.describe(d.code), fig.Language.JSON.Parser.shortLabel(d.code));
        if (toml_report.diag) |d|
            try diag_report.reportParseError(term, content, file_path, d.offset, d.end, fig.Language.TOML.Parser.describe(d.code), fig.Language.TOML.Parser.shortLabel(d.code));
        return err;
    };
    try diag_report.handleParseWarnings(term, content, file_path, "fig authoring", fig_report.warnings, fig.Language.FIG.Parser.Warning.describeWarning, fig.Language.FIG.Parser.Warning.shortLabel, quiet, strict);
    try diag_report.handleParseWarnings(term, content, file_path, "JSON authoring", json_report.warnings, fig.Language.JSON.Parser.Warning.describeWarning, fig.Language.JSON.Parser.Warning.shortLabel, quiet, strict);
    try diag_report.handleParseWarnings(term, content, file_path, "TOML authoring", toml_report.warnings, fig.Language.TOML.Parser.Warning.describeWarning, fig.Language.TOML.Parser.Warning.shortLabel, quiet, strict);

    const target: fig.AST.SerializeFormat = switch (format) {
        .json => .json,
        .jsonc => .jsonc,
        .json5 => .json5,
        .yaml, .yml => .yaml,
        .toml => .toml,
        .zon => .zon,
        .canonical => .canonical,
        .fig => .fig,
        .xml => .xml,
        .ini => .ini,
        .dotenv => .dotenv,
        .properties => .properties,
        .gron => unreachable, // rejected up front above
    };

    if (!quiet or strict) {
        const warnings = try fig.Diagnostics.analyze(allocator, &doc.ast, doc.ast.root, target, .{
            .pretty = serialize.pretty,
            .strip_comments = serialize.strip_comments,
            .lossless = false,
        });
        var surfaced: usize = 0;
        for (warnings) |w| {
            if (w.cause != .format_limitation) continue;
            surfaced += 1;
            if (!quiet) {
                try term.setColor(.yellow);
                try term.writer.writeAll("warning: ");
                try term.setColor(.reset);
                try w.render(term.writer, target);
                try term.writer.writeByte('\n');
            }
        }
        if (!quiet) try term.writer.flush();
        if (strict and surfaced > 0) {
            try term.writer.print("error: {d} lossy conversion warning(s); --strict aborts.\n", .{surfaced});
            try term.writer.flush();
            std.process.exit(1);
        }
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (target == .toml) {
        // Same lossy-strip-then-print path `get` uses for a lossy TOML target:
        // TOML has no null, so an unrepresentable value is dropped up front
        // (already reported above) rather than aborting mid-print.
        const result = try fig.Lossless.lossyStrip(allocator, &doc.ast, doc.ast.root, .toml);
        if (result.ast) |stripped| try stripped.serializeWith(&out.writer, .toml, serialize);
    } else if (parse_dispatch.flatStripFormat(target)) |fmt| {
        // `fmt` never converts format (always reads and writes the same one),
        // so — unlike `convertSlice`'s twin below — there's no `--lossless` to
        // gate this on: a value already unrepresentable in the source can only
        // have gotten there via a lossless-envelope decode from a PRIOR
        // conversion, and re-emitting the same format always strips it again.
        const result = try fig.FlatStrip.lossyStrip(allocator, &doc.ast, doc.ast.root, fmt);
        if (result.ast) |stripped| try stripped.serializeWith(&out.writer, target, serialize);
    } else {
        doc.ast.serializeWith(&out.writer, target, serialize) catch |err| switch (err) {
            error.FigUnrepresentableRoot => diag_report.reportFigUnrepresentableRoot(term),
            else => |e| diag_report.reportSerializeError(term, e),
        };
    }
    return out.toOwnedSlice();
}

/// Parse `content` as `from` and re-emit it as `to` — `convert`'s core, and the
/// in-place-writeback twin of `get`'s cross-format pipeline: materializing
/// YAML's reference layer when leaving YAML (aliases/merges/tags resolved),
/// the optional `--lossless` envelope round-trip, the same lossy-conversion
/// diagnostics, and TOML's lossy null-strip when serializing without
/// `--lossless`. Unlike `get` there is no `--path`/gron/`--body` projection —
/// `convert` always converts the whole document (or, under embed-archetype
/// mode, the whole embedded region's content). Returns the converted bytes
/// (caller-owned).
pub fn convertSlice(
    allocator: std.mem.Allocator,
    term: *Io.Terminal,
    file_path: []const u8,
    from: Format,
    to: Format,
    content: []const u8,
    serialize: fig.AST.SerializeOptions,
    lossless: bool,
    lax_tags: bool,
    quiet: bool,
    strict: bool,
) !([]u8) {
    if (to == .gron) {
        try term.writer.print("error: cannot convert to gron (a CLI projection, not a stored document format).\n", .{});
        try term.writer.flush();
        return error.UnsupportedGronFmt;
    }

    var fig_report: fig.Language.FIG.Parser.Report = .{};
    var json_report: fig.Language.JSON.Parser.Report = .{};
    var toml_report: fig.Language.TOML.Parser.Report = .{};
    const doc = parse_dispatch.parseSliceAs(from, .{}, allocator, content, false, .{ .fig = &fig_report, .json = &json_report, .toml = &toml_report }) catch |err| {
        if (fig_report.diag) |d|
            try diag_report.reportParseError(term, content, file_path, d.offset, d.end, fig.Language.FIG.Parser.describe(d.code), fig.Language.FIG.Parser.shortLabel(d.code));
        if (json_report.diag) |d|
            try diag_report.reportParseError(term, content, file_path, d.offset, d.end, fig.Language.JSON.Parser.describe(d.code), fig.Language.JSON.Parser.shortLabel(d.code));
        if (toml_report.diag) |d|
            try diag_report.reportParseError(term, content, file_path, d.offset, d.end, fig.Language.TOML.Parser.describe(d.code), fig.Language.TOML.Parser.shortLabel(d.code));
        return err;
    };
    try diag_report.handleParseWarnings(term, content, file_path, "fig authoring", fig_report.warnings, fig.Language.FIG.Parser.Warning.describeWarning, fig.Language.FIG.Parser.Warning.shortLabel, quiet, strict);
    try diag_report.handleParseWarnings(term, content, file_path, "JSON authoring", json_report.warnings, fig.Language.JSON.Parser.Warning.describeWarning, fig.Language.JSON.Parser.Warning.shortLabel, quiet, strict);
    try diag_report.handleParseWarnings(term, content, file_path, "TOML authoring", toml_report.warnings, fig.Language.TOML.Parser.Warning.describeWarning, fig.Language.TOML.Parser.Warning.shortLabel, quiet, strict);

    // Converting YAML to a non-YAML format resolves the reference layer first
    // (aliases → copies, merges → flattened, tags applied/dropped). YAML→YAML
    // keeps it intact for round-trip; JSON never has it. Mirrors `get`.
    const src_is_yaml = from == .yaml or from == .yml;
    const dst_is_yaml = to == .yaml or to == .yml;
    const base_ast: *const fig.AST = if (src_is_yaml and !dst_is_yaml) blk: {
        if (comptime build_options.lang_yaml) {
            const mode: fig.Language.YAML.TagMode = if (lax_tags) .lax else .strict;
            const mat = try allocator.create(fig.AST);
            mat.* = try fig.Language.YAML.materialize(allocator, &doc.ast, mode);
            break :blk mat;
        } else unreachable;
    } else &doc.ast;

    const ast: *const fig.AST = if (lossless and !(src_is_yaml and dst_is_yaml)) blk: {
        const maybe_target: ?fig.Lossless.Target = switch (to) {
            .json, .jsonc, .json5, .gron => .json,
            .yaml, .yml => .yaml,
            .toml => .toml,
            .zon => .zon,
            // XML has no envelope of its own — see the matching comment on the
            // `.get` action's twin switch above. INI/dotenv are the same story.
            .canonical, .fig, .xml, .ini, .dotenv, .properties => null,
        };
        const decoded = try allocator.create(fig.AST);
        decoded.* = try fig.Lossless.decode(allocator, base_ast);
        const target = maybe_target orelse break :blk decoded;
        const encoded = try allocator.create(fig.AST);
        encoded.* = try fig.Lossless.encode(allocator, decoded, target);
        break :blk encoded;
    } else base_ast;

    const target: fig.AST.SerializeFormat = switch (to) {
        .json => .json,
        .jsonc => .jsonc,
        .json5 => .json5,
        .yaml, .yml => .yaml,
        .toml => .toml,
        .zon => .zon,
        .canonical => .canonical,
        .fig => .fig,
        .xml => .xml,
        .ini => .ini,
        .dotenv => .dotenv,
        .properties => .properties,
        .gron => unreachable, // rejected up front above
    };

    if (!quiet or strict) {
        const warnings = try fig.Diagnostics.analyze(allocator, ast, ast.root, target, .{
            .pretty = serialize.pretty,
            .strip_comments = serialize.strip_comments,
            .lossless = lossless,
        });
        var surfaced: usize = 0;
        for (warnings) |w| {
            if (w.cause != .format_limitation) continue;
            surfaced += 1;
            if (!quiet) {
                try term.setColor(.yellow);
                try term.writer.writeAll("warning: ");
                try term.setColor(.reset);
                try w.render(term.writer, target);
                try term.writer.writeByte('\n');
            }
        }
        if (!quiet) try term.writer.flush();
        if (strict and surfaced > 0) {
            try term.writer.print("error: {d} lossy conversion warning(s); --strict aborts.\n", .{surfaced});
            try term.writer.flush();
            std.process.exit(1);
        }
    }

    const flat_strip_fmt: ?fig.FlatStrip.Format = if (!lossless) parse_dispatch.flatStripFormat(target) else null;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (target == .toml and !lossless) {
        // Same lossy-strip-then-print path `get` uses for a lossy TOML target:
        // TOML has no null, so an unrepresentable value is dropped up front
        // (already reported above) rather than aborting mid-print.
        const result = try fig.Lossless.lossyStrip(allocator, ast, ast.root, .toml);
        if (result.ast) |stripped| try stripped.serializeWith(&out.writer, .toml, serialize);
    } else if (flat_strip_fmt) |fmt| {
        // INI/dotenv/.properties: same idea as TOML's null-stripping above,
        // but depth-based (see `fig.FlatStrip`'s module doc); gated on
        // `!lossless` for the same reason `get`'s twin path is — see there.
        const result = try fig.FlatStrip.lossyStrip(allocator, ast, ast.root, fmt);
        if (result.ast) |stripped| try stripped.serializeWith(&out.writer, target, serialize);
    } else {
        ast.serializeWith(&out.writer, target, serialize) catch |err| switch (err) {
            error.FigUnrepresentableRoot => diag_report.reportFigUnrepresentableRoot(term),
            else => |e| diag_report.reportSerializeError(term, e),
        };
    }
    return out.toOwnedSlice();
}
