//! The body of each CLI action — one function per `CliAction`, called from
//! `main.zig`'s thin dispatch switch. Each function takes the arena
//! allocator, the process `Io`, the stdout/stderr terminals, and its own
//! action's option struct (from `types.zig`); together they're exactly the
//! free variables the original monolithic `main()` switch closed over.
const std = @import("std");
const fig = @import("fig");
const build_options = @import("build_options");

const gron = @import("gron.zig");
const diff = @import("diff.zig");
const types = @import("types.zig");
const help = @import("help.zig");
const args_mod = @import("args.zig");
const fileio = @import("fileio.zig");
const diag_report = @import("diag_report.zig");
const parse_dispatch = @import("parse_dispatch.zig");
const edit_ops = @import("edit_ops.zig");
const reformat = @import("reformat.zig");

const Help = help.Help;
const Format = types.Format;
const EditOp = types.EditOp;
const append_index = types.append_index;
const Io = std.Io;

pub fn runHelp(stderr_term: *Io.Terminal, binary_name: []const u8) !void {
    try stderr_term.writer.print(help.title_string, .{});
    try Help.general(stderr_term, binary_name);
}

/// Print the CLI's own version alongside the core library version it embeds
/// and its marketing epoch — two independent SemVer tracks (see
/// docs/VERSIONING.md; a CLI-only breaking change bumps `cli_version`
/// without requiring a `core_version`/ABI release, and vice versa) plus one
/// purely cosmetic label (`epoch` has no compatibility meaning — it's the
/// core's marketing name, not a version number).
pub fn runVersion(stdout_term: *Io.Terminal, cli_version: []const u8, core_version: []const u8, epoch: []const u8) !void {
    try stdout_term.writer.print("fig {s} (core {s} \"{s}\")\n", .{ cli_version, core_version, epoch });
    try stdout_term.writer.flush();
}

pub fn runEdit(a: std.mem.Allocator, io: Io, stdout_term: *Io.Terminal, binary_name: []const u8, opts: types.EditOptions) !void {
    if (opts.requested_help) {
        try Help.edit(stdout_term, binary_name);
        return;
    }
    const input = try fileio.getInput(io, opts.file, .read_write);
    defer if (!std.mem.eql(u8, opts.file, "-")) input.close(io);

    const op: EditOp = if (opts.key) .replace_key else .replace_value;
    if (try args_mod.resolveEmbedType(io, a, input, opts.embed, opts.detect_embed)) |embed_type| {
        try edit_ops.applyToEmbed(a, io, input, embed_type, opts.path, opts.replacement, op);
    } else switch (if (opts.detect) try parse_dispatch.detectFileFormat(io, a, opts.file) else opts.format) {
        .json, .jsonc, .json5 => |f| if (comptime build_options.lang_json) {
            const replacement = try std.fmt.allocPrint(a, "\"{s}\"", .{opts.replacement});
            try edit_ops.applyToFile(fig.Language.JSON, a, io, input, opts.path, replacement, op, edit_ops.jsonDialect(f));
        } else return error.FormatDisabled,
        .yaml, .yml => if (comptime build_options.lang_yaml) {
            try edit_ops.applyToFile(fig.Language.YAML, a, io, input, opts.path, opts.replacement, op, fig.Language.YAML.default_type);
        } else return error.FormatDisabled,
        // TOML value/key replacement: a value or key node has a tight,
        // contiguous span (the parser's node_spans point at the original
        // source bytes), so the generic span-splice editor handles it
        // even when the owning table is assembled from scattered headers.
        // The replacement is taken verbatim as a TOML literal, like YAML
        // and ZON. (Structural inserts/deletes that must place text
        // relative to a scattered table are still unsupported.)
        .toml => if (comptime build_options.lang_toml)
            try edit_ops.applyToFile(fig.Language.TOML, a, io, input, opts.path, opts.replacement, op, fig.Language.TOML.default_type)
        else
            return error.FormatDisabled,
        // ZON edits take the replacement verbatim (a literal ZON value),
        // like YAML — the editor splices and reparses it.
        .zon => if (comptime build_options.lang_zon)
            try edit_ops.applyToFile(fig.Language.ZON, a, io, input, opts.path, opts.replacement, op, fig.Language.ZON.default_type)
        else
            return error.FormatDisabled,
        // XML is reader-only: no in-place editor yet.
        .xml => return error.UnsupportedXmlEdit,
        // INI: root/section key replace-value takes the replacement verbatim
        // as a literal, same as TOML/YAML/fig/ZON/dotenv/.properties.
        .ini => if (comptime build_options.lang_ini)
            try edit_ops.applyToFile(fig.Language.INI, a, io, input, opts.path, opts.replacement, op, fig.Language.INI.default_type)
        else
            return error.FormatDisabled,
        // dotenv/.properties: flat `KEY=value`, no nesting — the generic
        // block-mapping editor handles them directly (see `Editor`'s
        // `kv_sep`). The replacement is taken verbatim as a literal, same as
        // YAML/TOML/fig/ZON (only the JSON family needs requoting).
        .dotenv => if (comptime build_options.lang_dotenv)
            try edit_ops.applyToFile(fig.Language.DOTENV, a, io, input, opts.path, opts.replacement, op, fig.Language.DOTENV.default_type)
        else
            return error.FormatDisabled,
        .properties => if (comptime build_options.lang_properties)
            try edit_ops.applyToFile(fig.Language.PROPERTIES, a, io, input, opts.path, opts.replacement, op, fig.Language.PROPERTIES.default_type)
        else
            return error.FormatDisabled,
        // plist: unlike generic XML, plist HAS an in-place editor
        // (`Editor(Plist)`). The replacement is rendered into a typed value
        // element (fig `sniffBare` typing, or spliced verbatim when it already
        // starts with `<`) — see `languages/plist/editor_helper.zig`.
        .plist => if (comptime build_options.lang_plist)
            try edit_ops.applyToFile(fig.Language.PLIST, a, io, input, opts.path, opts.replacement, op, fig.Language.PLIST.default_type)
        else
            return error.FormatDisabled,
        // The canonical form is a parse/print pair with no span-splicing
        // editor; convert via `get` instead of editing in place.
        .canonical => return error.UnsupportedCanonicalEdit,
        // fig value/key replacement: `Editor(Fig)` splices the exact
        // node span (`Fig.Parser` now tracks real spans — see
        // `fig/parser.zig`'s "AST assembly" section), same as TOML.
        // The replacement is taken verbatim as a fig literal.
        .fig => if (comptime build_options.lang_fig)
            try edit_ops.applyToFile(fig.Language.FIG, a, io, input, opts.path, opts.replacement, op, fig.Language.FIG.default_type)
        else
            return error.FormatDisabled,
        // gron is a CLI-only get/echo format with no in-place editor.
        .gron => return error.UnsupportedGronEdit,
        // NestedText: `Editor(NestedText)` renders the replacement as a raw
        // scalar (same-line or a nested `>`-block, per its shape) rather than
        // splicing it verbatim as syntax — this format has no typed/quoted
        // literal to splice in the first place. See `nt_edit.ntReplaceValue`.
        .nestedtext => if (comptime build_options.lang_nestedtext)
            try edit_ops.applyToFile(fig.Language.NESTEDTEXT, a, io, input, opts.path, opts.replacement, op, fig.Language.NESTEDTEXT.default_type)
        else
            return error.FormatDisabled,
    }
}

pub fn runSet(a: std.mem.Allocator, io: Io, stdout_term: *Io.Terminal, stderr_term: *Io.Terminal, binary_name: []const u8, opts: types.SetOptions) !void {
    if (opts.requested_help) {
        try Help.set(stdout_term, binary_name);
        return;
    }
    if (opts.path.len == 0) {
        try stderr_term.writer.print("error: set needs a path to the key (or, with --seq, the sequence) to upsert.\n", .{});
        try stderr_term.writer.flush();
        std.process.exit(2);
    }
    // `set` upserts, so it may target a file that doesn't exist yet:
    // create it and seed a minimal valid empty document (see
    // `createSeededFile`/`emptyDocSeed`) so the editor lands the first
    // key into a parseable buffer. The other structural actions keep the
    // plain open — they edit what's already there and have nothing to
    // seed into a blank file. Two cases refuse the create up front,
    // before any file lands on disk:
    //   - a freshly created file is empty, so its format can't be sniffed
    //     (`--detect`): it must carry a known extension;
    //   - a format with no empty-document form (`emptyDocSeed` == null,
    //     e.g. fig) has nothing valid to seed.
    // When targeting an embed, the host is seeded empty ("") and the
    // embed machinery (`initRegion`) synthesizes the inner block itself.
    var created = false;
    const input = fileio.getInput(io, opts.file, .read_write) catch |err| switch (err) {
        error.FileNotFound => blk: {
            if (std.mem.eql(u8, opts.file, "-")) return err;
            if (opts.detect) {
                try stderr_term.writer.print("error: cannot create {s}: an unrecognized extension gives no format to seed. Use a known extension (.json/.jsonc/.yaml/.toml/.zon) or an existing file.\n", .{opts.file});
                try stderr_term.writer.flush();
                std.process.exit(2);
            }
            const seed: []const u8 = if (opts.embed != null or opts.detect_embed) "" else edit_ops.emptyDocSeed(opts.format) orelse {
                try stderr_term.writer.print("error: cannot create {s}: {s} has no empty-document form to seed a new file. Start from an existing file.\n", .{ opts.file, @tagName(opts.format) });
                try stderr_term.writer.flush();
                std.process.exit(2);
            };
            created = true;
            break :blk try fileio.createSeededFile(io, opts.file, seed);
        },
        else => return err,
    };
    defer if (!std.mem.eql(u8, opts.file, "-")) input.close(io);

    const resolved = if (opts.detect) try parse_dispatch.detectFileFormat(io, a, opts.file) else opts.format;
    // `--seq` reconciles the sequence at `path`; otherwise upsert a scalar.
    // Both flow through the shared structural-edit router, so the embed
    // path (which open-or-inits a missing block) is reused for free.
    const op: EditOp = if (opts.seq) .{ .set_sequence = opts.values } else .set;
    const text: []const u8 = if (opts.seq) "" else opts.value;
    // On a from-scratch create, roll the new file back if the edit fails
    // (e.g. a path whose parent segment resolves to a scalar, which `set`
    // refuses rather than clobber) so a failed `set` leaves no bare seed
    // behind — matching how it leaves an existing file untouched on
    // failure. A merely-missing parent map is no longer a failure: `set`
    // auto-vivifies it (see `Editor.set`).
    const embed = try args_mod.resolveEmbedType(io, a, input, opts.embed, opts.detect_embed);
    edit_ops.applyStructuralEdit(a, io, input, resolved, embed, opts.path, text, op) catch |err| {
        if (created) fileio.deleteCreatedFile(io, opts.file);
        return err;
    };
}

pub fn runInsert(a: std.mem.Allocator, io: Io, stdout_term: *Io.Terminal, stderr_term: *Io.Terminal, binary_name: []const u8, opts: types.InsertOptions) !void {
    if (opts.requested_help) {
        try Help.insert(stdout_term, binary_name);
        return;
    }
    const input = try fileio.getInput(io, opts.file, .read_write);
    defer if (!std.mem.eql(u8, opts.file, "-")) input.close(io);

    // The destination is the *parent* container plus the trailing slot.
    // A trailing key inserts into a mapping; a trailing index pre/appends
    // to a sequence. An empty parent is the root container.
    if (opts.path.len == 0) {
        try stderr_term.writer.print("error: insert needs a destination path (e.g. a.b.newkey or list[-]).\n", .{});
        try stderr_term.writer.flush();
        std.process.exit(2);
    }
    const parent = opts.path[0 .. opts.path.len - 1];
    const resolved = if (opts.detect) try parse_dispatch.detectFileFormat(io, a, opts.file) else opts.format;
    const embed = try args_mod.resolveEmbedType(io, a, input, opts.embed, opts.detect_embed);
    switch (opts.path[opts.path.len - 1]) {
        .key => |key| try edit_ops.applyStructuralEdit(a, io, input, resolved, embed, parent, opts.value, .{ .insert_key = key }),
        .index => |index| {
            // The editor only prepends or appends; an addressable middle
            // index has no primitive, so reject it rather than guess.
            const op: EditOp = if (index == 0)
                .prepend_seq
            else if (index == append_index)
                .append_seq
            else {
                try stderr_term.writer.print("error: sequence insert supports only [0] (prepend) or [-]/[$] (append); mid-sequence insert is not yet available.\n", .{});
                try stderr_term.writer.flush();
                std.process.exit(2);
            };
            try edit_ops.applyStructuralEdit(a, io, input, resolved, embed, parent, opts.value, op);
        },
    }
}

pub fn runDelete(a: std.mem.Allocator, io: Io, stdout_term: *Io.Terminal, stderr_term: *Io.Terminal, binary_name: []const u8, opts: types.DeleteOptions) !void {
    if (opts.requested_help) {
        try Help.delete(stdout_term, binary_name);
        return;
    }
    const input = try fileio.getInput(io, opts.file, .read_write);
    defer if (!std.mem.eql(u8, opts.file, "-")) input.close(io);

    if (opts.path.len == 0) {
        try stderr_term.writer.print("error: delete needs a path to the entry or item to remove.\n", .{});
        try stderr_term.writer.flush();
        std.process.exit(2);
    }
    const resolved = if (opts.detect) try parse_dispatch.detectFileFormat(io, a, opts.file) else opts.format;
    const embed = try args_mod.resolveEmbedType(io, a, input, opts.embed, opts.detect_embed);
    // A trailing index removes that item from the parent sequence; a
    // trailing key deletes the mapping entry named by the full path.
    switch (opts.path[opts.path.len - 1]) {
        .index => |index| try edit_ops.applyStructuralEdit(a, io, input, resolved, embed, opts.path[0 .. opts.path.len - 1], "", .{ .remove_seq_item = index }),
        .key => try edit_ops.applyStructuralEdit(a, io, input, resolved, embed, opts.path, "", .delete_key),
    }
}

pub fn runGet(a: std.mem.Allocator, io: Io, stdout_term: *Io.Terminal, stderr_term: *Io.Terminal, binary_name: []const u8, opts: types.GetOptions) !void {
    if (opts.requested_help) {
        try Help.get(stdout_term, binary_name);
        return;
    }
    const input = try fileio.getInput(io, opts.file, .read_only);
    defer if (!std.mem.eql(u8, opts.file, "-")) input.close(io);

    // `--body`: print the host prose OUTSIDE the fences (the region's
    // `body` span) — the complement of extracting the embed content. With
    // no such region the whole file is the body.
    if (opts.body) {
        const content = try fileio.readAll(a, io, input);
        const embed_type = args_mod.resolveEmbedTypeFromContent(content, opts.embed, opts.detect_embed) orelse fig.Embed.Type{ .frontmatter = .yaml };
        if (fig.Embed.locateRegion(content, embed_type)) |region| {
            try stdout_term.writer.writeAll(content[region.body.start..region.body.end]);
        } else |err| switch (err) {
            error.NotFound => try stdout_term.writer.writeAll(content),
            else => return err,
        }
        try stdout_term.writer.flush();
        return;
    }

    // Resolved input/output formats. They equal the parsed options unless
    // the input format has to be sniffed from the file's contents (no
    // `--input`, unrecognized extension): detection overwrites `from`, and
    // — when no `--output` was given — `to` follows it (an echo round-trip
    // rather than a silent convert-to-JSON).
    var from = opts.from;
    var to = opts.to;

    const doc = if (try args_mod.resolveEmbedType(io, a, input, opts.embed, opts.detect_embed)) |embed_type| blk_embed: {
        // `embed_type` may have just been sniffed at runtime
        // (`detect_embed`), in which case the parse-time
        // placeholder `from`/`to` (the extension's guess, not the
        // real archetype) needs correcting: the inner format
        // always follows the archetype outright, and — same as
        // the whole-file `detect` echo below — an unpinned
        // output follows it too rather than silently defaulting
        // to something else (e.g. `.yaml` for a `.md` file whose
        // actual frontmatter turned out to be fig or JSON).
        from = args_mod.embedFormat(embed_type);
        if (!opts.output_explicit) to = from;
        break :blk_embed try edit_ops.parseEmbeddedFromFile(a, io, input, embed_type);
    } else blk: {
        // Read once so detection and parsing share the same bytes — a
        // piped stdin can only be consumed a single time.
        const content = try fileio.readAll(a, io, input);
        if (opts.detect) {
            from = try parse_dispatch.resolveFormatFromContent(a, content, opts.file);
            if (!opts.output_explicit) to = from;
        }
        var fig_report: fig.Language.FIG.Parser.Report = .{};
        var json_report: fig.Language.JSON.Parser.Report = .{};
        var toml_report: fig.Language.TOML.Parser.Report = .{};
        const parsed = parse_dispatch.parseSliceAs(from, .{}, a, content, false, .{ .fig = &fig_report, .json = &json_report, .toml = &toml_report }) catch |err| {
            // A parse failure renders as a `file:line:col` teaching
            // message (DESIGN.md: every diagnostic names the fix) and
            // exits cleanly — no error-return trace for a user typo.
            // Only fig/JSON/TOML fill a report so far; every other
            // format still falls through to the bare `return err`.
            if (fig_report.diag) |d|
                try diag_report.reportParseError(stderr_term, content, opts.file, d.offset, d.end, fig.Language.FIG.Parser.describe(d.code), fig.Language.FIG.Parser.shortLabel(d.code));
            if (json_report.diag) |d|
                try diag_report.reportParseError(stderr_term, content, opts.file, d.offset, d.end, fig.Language.JSON.Parser.describe(d.code), fig.Language.JSON.Parser.shortLabel(d.code));
            if (toml_report.diag) |d|
                try diag_report.reportParseError(stderr_term, content, opts.file, d.offset, d.end, fig.Language.TOML.Parser.describe(d.code), fig.Language.TOML.Parser.shortLabel(d.code));
            return err;
        };
        // Authoring-time lints (parse-time warnings) ride the same
        // `--quiet`/`--strict` contract as the serialize-side
        // diagnostics below: quiet silences, strict aborts.
        try diag_report.handleParseWarnings(stderr_term, content, opts.file, "fig authoring", fig_report.warnings, fig.Language.FIG.Parser.Warning.describeWarning, fig.Language.FIG.Parser.Warning.shortLabel, opts.quiet, opts.strict);
        try diag_report.handleParseWarnings(stderr_term, content, opts.file, "JSON authoring", json_report.warnings, fig.Language.JSON.Parser.Warning.describeWarning, fig.Language.JSON.Parser.Warning.shortLabel, opts.quiet, opts.strict);
        try diag_report.handleParseWarnings(stderr_term, content, opts.file, "TOML authoring", toml_report.warnings, fig.Language.TOML.Parser.Warning.describeWarning, fig.Language.TOML.Parser.Warning.shortLabel, opts.quiet, opts.strict);
        break :blk parsed;
    };

    // Converting YAML to a non-YAML format resolves the reference layer
    // first (aliases → copies, merges → flattened, tags applied/dropped).
    // YAML→YAML keeps it intact for round-trip; JSON never has it.
    const src_is_yaml = from == .yaml or from == .yml;
    const dst_is_yaml = to == .yaml or to == .yml;
    const base_ast: *const fig.AST = if (src_is_yaml and !dst_is_yaml) blk: {
        // Reachable only when the source is YAML, so YAML is compiled in;
        // the comptime guard keeps `Language.YAML` out of the gated build.
        if (comptime build_options.lang_yaml) {
            const mode: fig.Language.YAML.TagMode = if (opts.lax_tags) .lax else .strict;
            const mat = try a.create(fig.AST);
            mat.* = try fig.Language.YAML.materialize(a, &doc.ast, mode);
            break :blk mat;
        } else unreachable;
    } else &doc.ast;

    // Lossless mode: decode any `$fig` envelopes in the input back to
    // their real node kinds, then re-encode for the target format. Skipped
    // for YAML→YAML, whose reference layer (anchors/tags) lives in
    // side-tables the core-AST passes would strip — and which round-trips
    // losslessly already. The passes operate on a core AST, so any
    // non-YAML source (or a materialized YAML source) is safe.
    const ast: *const fig.AST = if (opts.lossless and !(src_is_yaml and dst_is_yaml)) blk: {
        const maybe_target: ?fig.Lossless.Target = switch (to) {
            // JSON5 reuses the JSON envelope target. It could hold
            // Infinity/NaN natively, so this is conservative (those ride
            // in a `$fig` envelope) but still fully lossless.
            // gron's value layer is JSON, so it shares the JSON envelope
            // target: an unrepresentable value (a TOML datetime, etc.)
            // rides in a `$fig` envelope that prints as a JSON object.
            .json, .jsonc, .json5, .gron => .json,
            .yaml, .yml => .yaml,
            .toml => .toml,
            .zon => .zon,
            // Canonical encodes every node kind directly, so no envelope
            // is needed on output — only decode envelopes found in input.
            // fig shares canonical's node model (same AST, no distinct
            // envelope value-space of its own), so it gets the same
            // decode-only treatment; a node fig can't natively spell
            // (non-string key, YAML alias, scalar root) is the
            // documented "no authoring spelling" gap — fall to
            // `canonical`/`--lossless` with a different `--to` instead.
            // (A scalar root specifically makes the fig printer hard-error
            // with `FigUnrepresentableRoot` rather than emit non-conforming
            // text — see `languages/fig/printer.zig`'s `root`.)
            // XML has no envelope of its own either: every scalar
            // collapses to element/attribute text regardless (see
            // `languages/xml/printer.zig`), so an envelope couldn't
            // preserve anything a plain print doesn't already lose. INI is
            // the same story (also no typed scalars of its own). plist DOES
            // have typed scalars, but has no `Lossless.Target` envelope of
            // its own yet either — a separate future phase, same boundary
            // as XML/INI/dotenv/properties today. NestedText is the same
            // story (also no typed scalars, no envelope of its own).
            .canonical, .fig, .xml, .ini, .dotenv, .properties, .plist, .nestedtext => null,
        };
        const decoded = try a.create(fig.AST);
        decoded.* = try fig.Lossless.decode(a, base_ast);
        const target = maybe_target orelse break :blk decoded;
        const encoded = try a.create(fig.AST);
        encoded.* = try fig.Lossless.encode(a, decoded, target);
        break :blk encoded;
    } else base_ast;

    const node_id = if (opts.path) |p| (try ast.getValByPath(p)).id else ast.root;

    // gron is a CLI-only projection that derives straight from the AST,
    // so it has no `SerializeFormat`: print it here and return, bypassing
    // the serializer dispatch, the lossy/lossless diagnostics below, and
    // the C ABI entirely. YAML aliases are already materialized above.
    if (to == .gron) {
        if (comptime build_options.lang_json) {
            try gron.printNode(stdout_term.writer, ast, node_id, opts.gron_projection);
            try stdout_term.writer.flush();
        } else return error.FormatDisabled;
        return;
    }

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
        .plist => .plist,
        .nestedtext => .nestedtext,
        .gron => unreachable, // handled by the early return above
    };

    // Surface everything the conversion would silently lose (comments
    // dropped/degraded, values dropped/degraded) — unless `--quiet`. The
    // pass is read-only and runs on the AST as it will be printed: under
    // `--lossless` the lossy nodes are already enveloped, so no value
    // warnings fire. `--strict` turns any warning into a hard failure.
    if (!opts.quiet or opts.strict) {
        const warnings = try fig.Diagnostics.analyze(a, ast, node_id, target, .{
            .pretty = opts.serialize.pretty,
            .strip_comments = opts.serialize.strip_comments,
            .lossless = opts.lossless,
        });
        // The CLI only surfaces losses the FORMAT forced. A loss the user
        // explicitly asked for (e.g. `--strip-comments`) carries
        // `explicit_option` and is not surprising, so it neither warns nor
        // trips `--strict` — it just rides through on the warning layer for
        // a library consumer that wants it.
        var surfaced: usize = 0;
        for (warnings) |w| {
            if (w.cause != .format_limitation) continue;
            surfaced += 1;
            if (!opts.quiet) {
                try stderr_term.setColor(.yellow);
                try stderr_term.writer.writeAll("warning: ");
                try stderr_term.setColor(.reset);
                try w.render(stderr_term.writer, target);
                try stderr_term.writer.writeByte('\n');
            }
        }
        if (!opts.quiet) try stderr_term.writer.flush();
        if (opts.strict and surfaced > 0) {
            try stderr_term.writer.print("error: {d} lossy conversion warning(s); --strict aborts.\n", .{surfaced});
            try stderr_term.writer.flush();
            std.process.exit(1);
        }
    }

    // `!opts.lossless` only: under `--lossless` these formats fall through to
    // the plain print below and, having no envelope of their own (see
    // `fig.FlatStrip`'s module doc), surface whatever they can't hold as a
    // real error via `reportSerializeError` — `--lossless` means "don't
    // silently drop data," so silently stripping under it would defeat the
    // flag's whole point.
    const flat_strip_fmt: ?fig.FlatStrip.Format = if (!opts.lossless) parse_dispatch.flatStripFormat(target) else null;

    if (target == .toml and !opts.lossless) {
        // TOML has no null. In lossy mode, rather than the printer
        // aborting mid-document on one, strip unrepresentable values up
        // front so output stays valid and complete (the warnings above
        // already reported them). `lossyStrip` re-roots at `node_id`, so
        // the result serializes whole.
        const result = try fig.Lossless.lossyStrip(a, ast, node_id, .toml);
        if (result.ast) |stripped| {
            try stripped.serializeWith(stdout_term.writer, .toml, opts.serialize);
        }
    } else if (flat_strip_fmt) |fmt| {
        // INI/dotenv/.properties: same idea as TOML's null-stripping above,
        // but the capability rule is DEPTH-based, not scalar-kind-based — an
        // array, or a table nested past what the format allows, would
        // otherwise abort the printer mid-document (already warned about
        // above).
        const result = try fig.FlatStrip.lossyStrip(a, ast, node_id, fmt);
        if (result.ast) |stripped| {
            try stripped.serializeWith(stdout_term.writer, target, opts.serialize);
        }
    } else if (opts.path == null) {
        ast.serializeWith(stdout_term.writer, target, opts.serialize) catch |err| switch (err) {
            error.FigUnrepresentableRoot => diag_report.reportFigUnrepresentableRoot(stderr_term),
            else => |e| diag_report.reportSerializeError(stderr_term, e),
        };
    } else {
        ast.serializeNodeWith(stdout_term.writer, target, node_id, opts.serialize) catch |err| switch (err) {
            error.FigUnrepresentableRoot => diag_report.reportFigUnrepresentableRoot(stderr_term),
            else => |e| diag_report.reportSerializeError(stderr_term, e),
        };
    }
    try stdout_term.writer.flush();
}

pub fn runComment(a: std.mem.Allocator, io: Io, stdout_term: *Io.Terminal, stderr_term: *Io.Terminal, binary_name: []const u8, opts: types.CommentOptions) !void {
    if (opts.requested_help) {
        try Help.comment(stdout_term, binary_name);
        return;
    }
    // `--get` only reads: open read-only and never write back.
    const input = try fileio.getInput(io, opts.file, if (opts.get) .read_only else .read_write);
    defer if (!std.mem.eql(u8, opts.file, "-")) input.close(io);

    const resolved = if (opts.detect) try parse_dispatch.detectFileFormat(io, a, opts.file) else opts.format;

    if (opts.get) {
        const comment = if (try args_mod.resolveEmbedType(io, a, input, opts.embed, opts.detect_embed)) |embed_type|
            try edit_ops.getCommentFromEmbed(a, io, input, embed_type, opts.path, opts.inline_comment)
        else switch (resolved) {
            // Strict JSON has no comment syntax: there can be nothing to get.
            .json => {
                try stderr_term.writer.print("error: strict JSON has no comments; use a .jsonc or .json5 file instead.\n", .{});
                try stderr_term.writer.flush();
                std.process.exit(2);
            },
            .jsonc, .json5 => |f| if (comptime build_options.lang_json) try edit_ops.getCommentFromFile(fig.Language.JSON, a, io, input, opts.path, opts.inline_comment, edit_ops.jsonDialect(f)) else return error.FormatDisabled,
            .yaml, .yml => if (comptime build_options.lang_yaml)
                try edit_ops.getCommentFromFile(fig.Language.YAML, a, io, input, opts.path, opts.inline_comment, fig.Language.YAML.default_type)
            else
                return error.FormatDisabled,
            .toml => if (comptime build_options.lang_toml)
                try edit_ops.getCommentFromFile(fig.Language.TOML, a, io, input, opts.path, opts.inline_comment, fig.Language.TOML.default_type)
            else
                return error.FormatDisabled,
            .zon => if (comptime build_options.lang_zon)
                try edit_ops.getCommentFromFile(fig.Language.ZON, a, io, input, opts.path, opts.inline_comment, fig.Language.ZON.default_type)
            else
                return error.FormatDisabled,
            .xml => return error.UnsupportedXmlEdit,
            // A leading (own-line, above-the-key) comment reads fine; `--inline`
            // surfaces `error.CommentsUnsupported` from the editor — INI has no
            // same-line trailing comment syntax (see `Editor`'s
            // `trailingCommentMarker`).
            .ini => if (comptime build_options.lang_ini)
                try edit_ops.getCommentFromFile(fig.Language.INI, a, io, input, opts.path, opts.inline_comment, fig.Language.INI.default_type)
            else
                return error.FormatDisabled,
            .dotenv => if (comptime build_options.lang_dotenv)
                try edit_ops.getCommentFromFile(fig.Language.DOTENV, a, io, input, opts.path, opts.inline_comment, fig.Language.DOTENV.default_type)
            else
                return error.FormatDisabled,
            .properties => if (comptime build_options.lang_properties)
                try edit_ops.getCommentFromFile(fig.Language.PROPERTIES, a, io, input, opts.path, opts.inline_comment, fig.Language.PROPERTIES.default_type)
            else
                return error.FormatDisabled,
            // plist comments are `<!-- ... -->`; both leading (own-line) and
            // `--inline` trailing reads are supported (see `plist_edit`).
            .plist => if (comptime build_options.lang_plist)
                try edit_ops.getCommentFromFile(fig.Language.PLIST, a, io, input, opts.path, opts.inline_comment, fig.Language.PLIST.default_type)
            else
                return error.FormatDisabled,
            .canonical => return error.UnsupportedCanonicalEdit,
            .fig => if (comptime build_options.lang_fig)
                try edit_ops.getCommentFromFile(fig.Language.FIG, a, io, input, opts.path, opts.inline_comment, fig.Language.FIG.default_type)
            else
                return error.FormatDisabled,
            .gron => return error.UnsupportedGronEdit,
            // A leading (own-line) comment reads fine; `--inline` surfaces
            // `error.CommentsUnsupported` from the editor — NestedText has no
            // same-line trailing comment syntax (see `Editor`'s
            // `trailingCommentMarker`), matching INI.
            .nestedtext => if (comptime build_options.lang_nestedtext)
                try edit_ops.getCommentFromFile(fig.Language.NESTEDTEXT, a, io, input, opts.path, opts.inline_comment, fig.Language.NESTEDTEXT.default_type)
            else
                return error.FormatDisabled,
        };
        // Print the comment followed by a newline. An absent comment (null)
        // and a present-but-empty one both print just the newline — the CLI
        // can't distinguish them, but the bindings can (Option / null).
        try stdout_term.writer.print("{s}\n", .{comment orelse ""});
        try stdout_term.writer.flush();
        return;
    }

    // Pick the op from the two flags: `--inline` selects the trailing
    // (same-line) comment vs the leading block; `--delete` removes it
    // rather than adding/setting. The marker (`#`, `//`) is the editor's
    // job.
    const op: EditOp = if (opts.delete)
        (if (opts.inline_comment) .delete_trailing_comment else .delete_leading_comments)
    else
        (if (opts.inline_comment) .set_trailing_comment else .add_leading_comment);

    if (try args_mod.resolveEmbedType(io, a, input, opts.embed, opts.detect_embed)) |embed_type| {
        try edit_ops.applyToEmbed(a, io, input, embed_type, opts.path, opts.text, op);
    } else switch (resolved) {
        // Strict JSON has no comment syntax: fail with a clear message
        // rather than letting the editor surface a bare error.
        .json => {
            try stderr_term.writer.print("error: strict JSON has no comments; use a .jsonc or .json5 file instead.\n", .{});
            try stderr_term.writer.flush();
            std.process.exit(2);
        },
        // JSONC/JSON5 accept `//` comments (reparsed under the dialect).
        .jsonc, .json5 => |f| if (comptime build_options.lang_json) try edit_ops.applyToFile(fig.Language.JSON, a, io, input, opts.path, opts.text, op, edit_ops.jsonDialect(f)) else return error.FormatDisabled,
        .yaml, .yml => if (comptime build_options.lang_yaml)
            try edit_ops.applyToFile(fig.Language.YAML, a, io, input, opts.path, opts.text, op, fig.Language.YAML.default_type)
        else
            return error.FormatDisabled,
        .toml => if (comptime build_options.lang_toml)
            try edit_ops.applyToFile(fig.Language.TOML, a, io, input, opts.path, opts.text, op, fig.Language.TOML.default_type)
        else
            return error.FormatDisabled,
        .zon => if (comptime build_options.lang_zon)
            try edit_ops.applyToFile(fig.Language.ZON, a, io, input, opts.path, opts.text, op, fig.Language.ZON.default_type)
        else
            return error.FormatDisabled,
        .xml => return error.UnsupportedXmlEdit,
        // `add`/`delete` leading comment ops work; `--inline` set/delete
        // surfaces `error.CommentsUnsupported` (see the `--get` branch above).
        .ini => if (comptime build_options.lang_ini)
            try edit_ops.applyToFile(fig.Language.INI, a, io, input, opts.path, opts.text, op, fig.Language.INI.default_type)
        else
            return error.FormatDisabled,
        .dotenv => if (comptime build_options.lang_dotenv)
            try edit_ops.applyToFile(fig.Language.DOTENV, a, io, input, opts.path, opts.text, op, fig.Language.DOTENV.default_type)
        else
            return error.FormatDisabled,
        .properties => if (comptime build_options.lang_properties)
            try edit_ops.applyToFile(fig.Language.PROPERTIES, a, io, input, opts.path, opts.text, op, fig.Language.PROPERTIES.default_type)
        else
            return error.FormatDisabled,
        // plist: full in-place editing (insert/delete/comment) via `Editor(Plist)`.
        .plist => if (comptime build_options.lang_plist)
            try edit_ops.applyToFile(fig.Language.PLIST, a, io, input, opts.path, opts.text, op, fig.Language.PLIST.default_type)
        else
            return error.FormatDisabled,
        .canonical => return error.UnsupportedCanonicalEdit,
        .fig => if (comptime build_options.lang_fig)
            try edit_ops.applyToFile(fig.Language.FIG, a, io, input, opts.path, opts.text, op, fig.Language.FIG.default_type)
        else
            return error.FormatDisabled,
        .gron => return error.UnsupportedGronEdit,
        // `add`/`delete` leading comment ops work; `--inline` set/delete
        // surfaces `error.CommentsUnsupported` (see the `--get` branch above).
        .nestedtext => if (comptime build_options.lang_nestedtext)
            try edit_ops.applyToFile(fig.Language.NESTEDTEXT, a, io, input, opts.path, opts.text, op, fig.Language.NESTEDTEXT.default_type)
        else
            return error.FormatDisabled,
    }
}

pub fn runCheck(a: std.mem.Allocator, io: Io, stdout_term: *Io.Terminal, stderr_term: *Io.Terminal, binary_name: []const u8, opts: types.CheckOptions) !void {
    if (opts.requested_help) {
        try Help.check(stdout_term, binary_name);
        return;
    }

    // Validate every file, reporting each independently, so one bad file
    // doesn't hide the status of the rest. Success lines go to stdout
    // (silenced by `--quiet`); failures always go to stderr. A single
    // bad file makes the whole run exit non-zero — the CI contract.
    var any_failed = false;
    for (opts.files) |file| {
        var diag_source: ?[]const u8 = null;
        var diag_errors: ?[]const fig.ParseDiagnostic.Rendered = null;
        var diag_warnings: ?[]const fig.ParseDiagnostic.Rendered = null;
        if (parse_dispatch.checkOne(a, io, file, opts.format, opts.spec, &diag_source, &diag_errors, &diag_warnings)) |fmt| {
            if (!opts.quiet) {
                try stdout_term.setColor(.green);
                try stdout_term.writer.writeAll("ok");
                try stdout_term.setColor(.reset);
                // Echo the pinned version alongside the format when one
                // was requested, so `ok` states exactly what was checked.
                if (opts.spec) |spec|
                    try stdout_term.writer.print(": {s} ({s} {s})\n", .{ file, @tagName(fmt), spec })
                else
                    try stdout_term.writer.print(": {s} ({s})\n", .{ file, @tagName(fmt) });
                // Authoring-time lints: the file is valid (still `ok`),
                // but likely-mistake lines print right below it. Rendered
                // live against the real terminal (not buffered into a
                // string — see `printDiag`), then flushed immediately so
                // it can't interleave with the next file's logging.
                if (diag_warnings) |ws| {
                    for (ws) |w| try diag_report.printDiag(stderr_term, diag_source.?, file, w.offset, w.end, "warning", .yellow, w.message, w.short_label);
                    try stderr_term.writer.flush();
                }
            }
        } else |err| {
            any_failed = true;
            // A covered-language failure renders as a full
            // `file:line:col: error: …` teaching report per error
            // (recovery collects every error in the file, not just the
            // first) instead of the generic `file: ErrorName` line.
            if (diag_errors) |errs| {
                for (errs) |d| try diag_report.printDiag(stderr_term, diag_source.?, file, d.offset, d.end, "error", .red, d.message, d.short_label);
                try stderr_term.writer.flush();
                continue;
            }
            try stderr_term.setColor(.red);
            try stderr_term.writer.writeAll("error");
            try stderr_term.setColor(.reset);
            switch (err) {
                // A spec mismatch is a CLI usage error, not a malformed
                // document — say so plainly with the offending version.
                error.UnsupportedSpec => try stderr_term.writer.print(
                    ": {s}: --spec '{s}' is not valid for this format\n",
                    .{ file, opts.spec.? },
                ),
                else => try stderr_term.writer.print(": {s}: {s}\n", .{ file, @errorName(err) }),
            }
        }
    }
    try stdout_term.writer.flush();
    try stderr_term.writer.flush();
    if (any_failed) std.process.exit(1);
}

pub fn runFmt(a: std.mem.Allocator, io: Io, stdout_term: *Io.Terminal, stderr_term: *Io.Terminal, binary_name: []const u8, opts: types.FmtOptions) !void {
    if (opts.requested_help) {
        try Help.fmt(stdout_term, binary_name);
        return;
    }
    // `--diff` is a preview mode just like `--dry-run` — nothing is
    // ever written to `file` under either.
    const preview_only = opts.dry_run or opts.diff;
    const is_stdin = std.mem.eql(u8, opts.file, "-");
    if (!preview_only and is_stdin) {
        try stderr_term.writer.print(
            "error: cannot format stdin in place; pass --dry-run or --diff to print the formatted result instead.\n",
            .{},
        );
        try stderr_term.writer.flush();
        std.process.exit(2);
    }

    // Read-only when only previewing (`--dry-run`/`--diff`): no need to
    // open for writing what will never be written. Otherwise read_write,
    // like `edit`/`set`/`insert`/`delete` — read the whole file first,
    // then splice the same handle in place (never via shell redirection,
    // which truncates a `> file` target before this process ever runs).
    const input = try fileio.getInput(io, opts.file, if (preview_only) .read_only else .read_write);
    defer if (!is_stdin) input.close(io);

    const content = try fileio.readAll(a, io, input);

    // `--embed`: only the region between the fences is reformatted; the
    // rest of the host document is carried through byte-identical.
    if (args_mod.resolveEmbedTypeFromContent(content, opts.embed, opts.detect_embed)) |embed_type| {
        const region = try fig.Embed.locateRegion(content, embed_type);
        const inner = content[region.content.start..region.content.end];
        const reformatted_inner = try reformat.reformatSlice(a, stderr_term, opts.file, args_mod.embedFormat(embed_type), inner, opts.serialize, opts.quiet, opts.strict);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try out.appendSlice(a, content[0..region.content.start]);
        try out.appendSlice(a, reformatted_inner);
        try out.appendSlice(a, content[region.content.end..]);

        const changed = !std.mem.eql(u8, content, out.items);
        if (opts.diff) {
            try diff.unifiedDiff(a, stdout_term.writer, opts.file, content, out.items, 3);
            try stdout_term.writer.flush();
            if (changed) std.process.exit(1);
        } else if (opts.dry_run) {
            try stdout_term.writer.writeAll(out.items);
            try stdout_term.writer.flush();
            if (changed) std.process.exit(1);
        } else if (changed) {
            try input.writePositionalAll(io, out.items, 0);
            try input.setLength(io, out.items.len);
        }
        return;
    }

    var from = opts.from;
    if (opts.detect) from = try parse_dispatch.resolveFormatFromContent(a, content, opts.file);

    const reformatted = try reformat.reformatSlice(a, stderr_term, opts.file, from, content, opts.serialize, opts.quiet, opts.strict);
    const changed = !std.mem.eql(u8, content, reformatted);

    if (opts.diff) {
        try diff.unifiedDiff(a, stdout_term.writer, opts.file, content, reformatted, 3);
        try stdout_term.writer.flush();
        if (changed) std.process.exit(1);
    } else if (opts.dry_run) {
        try stdout_term.writer.writeAll(reformatted);
        try stdout_term.writer.flush();
        if (changed) std.process.exit(1);
    } else if (changed) {
        // Read-then-splice-same-handle (never shell redirection): the
        // in-memory `content` above was read before this write touches
        // the file, so there is no truncate-before-read race.
        try input.writePositionalAll(io, reformatted, 0);
        try input.setLength(io, reformatted.len);
    }
}

/// Finish a `convert` invocation given the original `content` and the
/// `result` it converts to: write `result` back to `input` in place when
/// `write` is set (skipped if the bytes are already identical), then print
/// either a unified diff (`show_diff`) or the whole `result` to stdout — the
/// whole result only when neither `write` nor `show_diff` fired, so `--write`
/// alone stays silent (like `fmt`) and `--write --diff` shows what changed
/// without also dumping the full file. Shared by both of `runConvert`'s modes
/// (whole-file and `--to-embed`), which differ only in how `result` is produced.
fn finishConvert(a: std.mem.Allocator, io: Io, stdout_term: *Io.Terminal, input: Io.File, file_path: []const u8, content: []const u8, result: []const u8, write: bool, show_diff: bool) !void {
    const changed = !std.mem.eql(u8, content, result);
    if (write and changed) {
        try input.writePositionalAll(io, result, 0);
        try input.setLength(io, result.len);
    }
    if (show_diff) {
        try diff.unifiedDiff(a, stdout_term.writer, file_path, content, result, 3);
        try stdout_term.writer.flush();
    } else if (!write) {
        try stdout_term.writer.writeAll(result);
        try stdout_term.writer.flush();
    }
}

pub fn runConvert(a: std.mem.Allocator, io: Io, stdout_term: *Io.Terminal, stderr_term: *Io.Terminal, binary_name: []const u8, opts: types.ConvertOptions) !void {
    if (opts.requested_help) {
        try Help.convert(stdout_term, binary_name);
        return;
    }
    const is_stdin = std.mem.eql(u8, opts.file, "-");
    if (opts.write and is_stdin) {
        try stderr_term.writer.print(
            "error: cannot write stdin in place; omit --write to print the converted result instead.\n",
            .{},
        );
        try stderr_term.writer.flush();
        std.process.exit(2);
    }

    const input = try fileio.getInput(io, opts.file, if (opts.write) .read_write else .read_only);
    defer if (!is_stdin) input.close(io);

    const content = try fileio.readAll(a, io, input);

    if (opts.to_embed) |to_embed_type| {
        // Embed-archetype mode: resolve the SOURCE archetype (--embed,
        // else content-sniffed with `Embed.detect` — extension-derived
        // defaults were already folded into `opts.embed` at parse time),
        // convert the region's inner content, then rehouse it under the
        // target archetype's fences, preserving the host prose exactly.
        const source_type = opts.embed orelse (if (opts.detect_embed) fig.Embed.detect(content) else null) orelse {
            try stderr_term.writer.print(
                "error: could not detect an embedded region in `{s}`; pass --embed explicitly.\n",
                .{opts.file},
            );
            try stderr_term.writer.flush();
            std.process.exit(2);
        };
        const region = try fig.Embed.locateRegion(content, source_type);
        const inner = content[region.content.start..region.content.end];
        const converted_inner = try reformat.convertSlice(
            a,
            stderr_term,
            opts.file,
            args_mod.embedFormat(source_type),
            args_mod.embedFormat(to_embed_type),
            inner,
            opts.serialize,
            opts.lossless,
            opts.lax_tags,
            opts.quiet,
            opts.strict,
        );
        const out = try fig.Embed.retype(a, content, region, to_embed_type, converted_inner);
        try finishConvert(a, io, stdout_term, input, opts.file, content, out, opts.write, opts.diff);
        return;
    }

    var from = opts.from;
    if (opts.detect) from = try parse_dispatch.resolveFormatFromContent(a, content, opts.file);

    const converted = try reformat.convertSlice(
        a,
        stderr_term,
        opts.file,
        from,
        opts.to,
        content,
        opts.serialize,
        opts.lossless,
        opts.lax_tags,
        opts.quiet,
        opts.strict,
    );
    try finishConvert(a, io, stdout_term, input, opts.file, content, converted, opts.write, opts.diff);
}
