//! Content-based parsing shared by `get`/`fmt`/`convert`/`check`: mapping the
//! CLI's `Format` (plus an optional `--spec` version) to the right language
//! parser, and `check`'s per-file validate-and-report entry point.
const std = @import("std");
const fig = @import("fig");
const build_options = @import("build_options");

const gron = @import("gron.zig");
const types = @import("types.zig");
const fileio = @import("fileio.zig");
const diag_report = @import("diag_report.zig");
const args_mod = @import("args.zig");

const Format = types.Format;
const Io = std.Io;

/// The canonical oracle format is opt-in (`-Dcanonical=true`) and otherwise
/// compiled out of the CLI — but always present in a test build. Mirrors the
/// `canonical_enabled` gate in `ast/serialize_options.zig`.
const canonical_enabled = build_options.lang_canonical or @import("builtin").is_test;

/// Per-language version/dialect to parse under. Each field defaults to its
/// language's `default_type`, so `parseSliceAs(fmt, .{}, …)` behaves exactly as
/// before — only `check --spec` overrides a field. JSON strictness is carried by
/// the `Format` itself (json/jsonc/json5); ZON/XML/native have one grammar each,
/// so they need no field here.
pub const Spec = struct {
    toml: fig.Language.TOML.Type = fig.Language.TOML.default_type,
    yaml: fig.Language.YAML.Type = fig.Language.YAML.default_type,
};

/// Resolve a `--spec` version string against the format it will parse. Null
/// `spec_str` yields the default spec. Errors when the version is unknown for
/// that format, or when the format exposes no selectable version (then `--spec`
/// doesn't apply — JSON strictness is the format name, ZON/XML/native are
/// single-grammar). YAML selects 1.2.2 (default) or 1.1; the versions differ in
/// scalar type resolution (see `scalarKind1_1` in the YAML parser).
pub fn resolveSpec(format: Format, spec_str: ?[]const u8) error{UnsupportedSpec}!Spec {
    const s = spec_str orelse return .{};
    const eq = std.mem.eql;
    return switch (format) {
        .toml => if (eq(u8, s, "1.0") or eq(u8, s, "1.0.0"))
            .{ .toml = .TOML_1_0 }
        else if (eq(u8, s, "1.1") or eq(u8, s, "1.1.0"))
            .{ .toml = .TOML_1_1 }
        else
            error.UnsupportedSpec,
        .yaml, .yml => if (eq(u8, s, "1.2") or eq(u8, s, "1.2.2"))
            .{ .yaml = .v1_2_2 }
        else if (eq(u8, s, "1.1") or eq(u8, s, "1.1.0"))
            .{ .yaml = .v1_1 }
        else
            error.UnsupportedSpec,
        .json, .jsonc, .json5, .zon, .xml, .canonical, .fig, .gron, .ini, .dotenv, .properties => error.UnsupportedSpec,
    };
}

/// Per-language parse-report out-parameters for `parseSliceAs` — one optional
/// pointer per language that has grown the rich diagnostic layer (position +
/// teaching messages, authoring-time warnings; see `languages/fig/parser.zig`'s
/// `Report` and `languages/json/parser.zig`'s twin). Grows by one field as
/// YAML gains its own `Report` type; every existing caller is unaffected (each
/// field defaults to `null`, meaning "don't collect this language's report").
pub const ParseReports = struct {
    fig: ?*fig.Language.FIG.Parser.Report = null,
    json: ?*fig.Language.JSON.Parser.Report = null,
    toml: ?*fig.Language.TOML.Parser.Report = null,
};

/// Parse already-read `content` as the CLI `format` under `spec`. The
/// content-based parser the `get` and `check` actions use: reading the input
/// once means detection and parsing share the same bytes, so a piped stdin is
/// consumed only once. `.jsonc`/`.json5` select the JSON dialect; `.yml` aliases
/// YAML; `.canonical` is the AST's 1:1 oracle grammar. `spec` picks the version
/// where one is selectable (TOML 1.0 vs 1.1, YAML version).
///
/// `reports` (fields optional) receives each covered language's own parse
/// report — `diag` on failure (position + teaching message), `warnings`
/// (authoring-time lints) always; `errors` (every failure, source order) when
/// `recover`. Only the `.fig`, `.json`/`.jsonc`/`.json5`, and `.toml` branches
/// fill one; the other formats keep their bare error-name reporting for now.
pub fn parseSliceAs(format: Format, spec: Spec, allocator: std.mem.Allocator, content: []const u8, recover: bool, reports: ParseReports) !fig.Document {
    return switch (format) {
        .json => if (comptime build_options.lang_json) parseJson(allocator, content, .JSON, recover, reports.json) else error.FormatDisabled,
        .jsonc => if (comptime build_options.lang_json) parseJson(allocator, content, .JSONC, recover, reports.json) else error.FormatDisabled,
        .json5 => if (comptime build_options.lang_json) parseJson(allocator, content, .JSON5, recover, reports.json) else error.FormatDisabled,
        .yaml, .yml => if (comptime build_options.lang_yaml) fig.Language.YAML.Parser.parse(allocator, content, spec.yaml) else error.FormatDisabled,
        .toml => if (comptime build_options.lang_toml) blk: {
            var local: fig.Language.TOML.Parser.Report = .{};
            const r = reports.toml orelse &local;
            break :blk if (recover)
                fig.Language.TOML.Parser.parseCollecting(allocator, content, spec.toml, r)
            else
                fig.Language.TOML.Parser.parseWithReport(allocator, content, spec.toml, r);
        } else error.FormatDisabled,
        .zon => if (comptime build_options.lang_zon) fig.Language.ZON.Parser.parse(allocator, content, fig.Language.ZON.default_type) else error.FormatDisabled,
        .xml => if (comptime build_options.lang_xml) fig.Language.XML.Parser.parse(allocator, content, fig.Language.XML.default_type) else error.FormatDisabled,
        .canonical => if (comptime canonical_enabled) fig.Canonical.parse(allocator, content) else error.FormatDisabled,
        .fig => if (comptime build_options.lang_fig) blk: {
            var local: fig.Language.FIG.Parser.Report = .{};
            const r = reports.fig orelse &local;
            // `recover` collects the whole file's errors (`check`); otherwise
            // stop at the first (`get`/convert only needs to fail once).
            break :blk if (recover)
                fig.Language.FIG.Parser.parseCollecting(allocator, content, fig.Language.FIG.default_type, r)
            else
                fig.Language.FIG.Parser.parseWithReport(allocator, content, fig.Language.FIG.default_type, r);
        } else error.FormatDisabled,
        // gron ("ungron") reconstructs the AST from its `path = value` lines,
        // reusing the JSON parser for each RHS — so it needs JSON compiled in.
        .gron => if (comptime build_options.lang_json) gron.parseDocument(allocator, content) else error.FormatDisabled,
        .ini => if (comptime build_options.lang_ini) fig.Language.INI.Parser.parse(allocator, content, fig.Language.INI.default_type) else error.FormatDisabled,
        .dotenv => if (comptime build_options.lang_dotenv) fig.Language.DOTENV.Parser.parse(allocator, content, fig.Language.DOTENV.default_type) else error.FormatDisabled,
        .properties => if (comptime build_options.lang_properties) fig.Language.PROPERTIES.Parser.parse(allocator, content, fig.Language.PROPERTIES.default_type) else error.FormatDisabled,
    };
}

/// The three JSON dialects share one parser/`Report` type, differing only in
/// `jtype` — factored out of `parseSliceAs` so its `.json`/`.jsonc`/`.json5`
/// arms don't triplicate the recover-vs-single-shot dispatch.
pub fn parseJson(allocator: std.mem.Allocator, content: []const u8, jtype: fig.Language.JSON.Type, recover: bool, report: ?*fig.Language.JSON.Parser.Report) !fig.Document {
    var local: fig.Language.JSON.Parser.Report = .{};
    const r = report orelse &local;
    return if (recover)
        fig.Language.JSON.Parser.parseCollecting(allocator, content, jtype, r)
    else
        fig.Language.JSON.Parser.parseWithReport(allocator, content, jtype, r);
}

/// Map a `Language.detect` result to the CLI `Format`. `Detected` has no
/// `jsonc` or `canonical` (neither is content-sniffed), so the mapping is
/// total.
pub fn mapDetected(d: fig.Language.Detected) Format {
    return switch (d) {
        .json => .json,
        .json5 => .json5,
        .yaml => .yaml,
        .toml => .toml,
        .zon => .zon,
        .xml => .xml,
        .fig => .fig,
        .ini => .ini,
        .dotenv => .dotenv,
        .properties => .properties,
    };
}

/// Sniff `content` with `Language.detect`, emit an info-level log of what was
/// inferred, and return it — the fallback when neither `--input` nor the file
/// extension pinned the format. Errors (after a clear message) if nothing matches.
pub fn resolveFormatFromContent(allocator: std.mem.Allocator, content: []const u8, file_path: []const u8) !Format {
    const detected = fig.Language.detect(allocator, content) orelse {
        std.log.scoped(.detect).err("could not infer the format of `{s}` from its contents; pass an explicit format", .{file_path});
        return error.UnsupportedFileFormat;
    };
    const format = mapDetected(detected);
    std.log.scoped(.detect).info("inferred format `{s}` for `{s}` from its contents", .{ @tagName(format), file_path });
    return format;
}

/// Open `file_path` read-only and sniff its contents. For the in-place edit paths
/// (`edit`/`comment`), which then re-open the file read-write to splice it — so
/// detection reads through a separate handle and never disturbs the edit read.
pub fn detectFileFormat(io: Io, allocator: std.mem.Allocator, file_path: []const u8) !Format {
    const probe = try fileio.getInput(io, file_path, .read_only);
    defer if (!std.mem.eql(u8, file_path, "-")) probe.close(io);
    const content = try fileio.readAll(allocator, io, probe);
    return resolveFormatFromContent(allocator, content, file_path);
}

/// Validate that `file` parses cleanly, returning the resolved format on success.
/// Format precedence mirrors `get`: an explicit `--input` `override`, else the
/// file extension, else sniffing the contents. `spec_str` (from `--spec`) pins
/// the language version to validate against and is resolved once the format is
/// known — an unknown/inapplicable version is reported like a parse error. When
/// the extension implies an embedded region (e.g. markdown frontmatter) the
/// inner document is extracted and parsed. Any IO/parse/spec error propagates to
/// the caller, which reports it — except fig and JSON: a parse failure fills
/// `diag_errors` with every diagnostic rendered into the language-agnostic
/// `ParseDiagnostic.Rendered` shape, and a clean parse may fill `diag_warnings`
/// the same way (both borrow `diag_source`, which is set alongside them). The
/// caller renders these live against the real terminal via `printDiag` rather
/// than a pre-rendered string, so it can color the label — see `printDiag`'s
/// doc comment for why that can't happen in here instead.
pub fn checkOne(allocator: std.mem.Allocator, io: Io, file: []const u8, override: ?Format, spec_str: ?[]const u8, diag_source: *?[]const u8, diag_errors: *?[]const fig.ParseDiagnostic.Rendered, diag_warnings: *?[]const fig.ParseDiagnostic.Rendered) !Format {
    const input = try fileio.getInput(io, file, .read_only);
    defer if (!std.mem.eql(u8, file, "-")) input.close(io);
    const content = try fileio.readAll(allocator, io, input);

    var format: Format = undefined;
    var embed: ?fig.Embed.Type = null;
    if (override) |f| {
        // An explicit format is taken at face value: no extension-driven embed
        // extraction, so `--input yaml file.md` parses the whole file as YAML.
        format = f;
    } else if (args_mod.detectLanguageFromFileEnding(file)) |d| {
        format = d.format;
        embed = args_mod.resolveEmbedTypeFromContent(content, null, d.embed_detect);
    } else {
        format = try resolveFormatFromContent(allocator, content, file);
    }

    // Resolve `--spec` against the now-known format. This rejects a nonsense
    // version (e.g. `--spec 1.0` on a JSON or markdown file) before parsing.
    const spec = try resolveSpec(format, spec_str);

    // `Embed.extract` parses the inner region; `parseSliceAs` parses the whole
    // file. Either surfaces a parse error — all we need to validate. The parsed
    // result is discarded; we only care that it parsed. (Embed extraction uses
    // the inner format's default version; `spec` was still validated above.)
    if (embed) |embed_type| {
        _ = try fig.Embed.extract(allocator, content, embed_type);
    } else {
        diag_source.* = content;
        var fig_report: fig.Language.FIG.Parser.Report = .{};
        var json_report: fig.Language.JSON.Parser.Report = .{};
        var toml_report: fig.Language.TOML.Parser.Report = .{};
        // `recover` so a file reports EVERY error in one pass (a language
        // server squiggles them all; `check` shouldn't hide errors 2..N behind
        // the first). Formats without a report yet stop at their first error
        // and fall back to the generic `file: ErrorName` line below.
        _ = parseSliceAs(format, spec, allocator, content, true, .{ .fig = &fig_report, .json = &json_report, .toml = &toml_report }) catch |err| {
            if (fig_report.errors.len > 0) {
                diag_errors.* = try diag_report.renderAll(allocator, fig_report.errors, fig.Language.FIG.Parser.describe, fig.Language.FIG.Parser.shortLabel);
            } else if (fig_report.diag) |d| {
                diag_errors.* = try diag_report.renderAll(allocator, &[_]fig.Language.FIG.Parser.Diagnostic{d}, fig.Language.FIG.Parser.describe, fig.Language.FIG.Parser.shortLabel);
            } else if (json_report.errors.len > 0) {
                diag_errors.* = try diag_report.renderAll(allocator, json_report.errors, fig.Language.JSON.Parser.describe, fig.Language.JSON.Parser.shortLabel);
            } else if (json_report.diag) |d| {
                diag_errors.* = try diag_report.renderAll(allocator, &[_]fig.Language.JSON.Parser.Diagnostic{d}, fig.Language.JSON.Parser.describe, fig.Language.JSON.Parser.shortLabel);
            } else if (toml_report.errors.len > 0) {
                diag_errors.* = try diag_report.renderAll(allocator, toml_report.errors, fig.Language.TOML.Parser.describe, fig.Language.TOML.Parser.shortLabel);
            } else if (toml_report.diag) |d| {
                diag_errors.* = try diag_report.renderAll(allocator, &[_]fig.Language.TOML.Parser.Diagnostic{d}, fig.Language.TOML.Parser.describe, fig.Language.TOML.Parser.shortLabel);
            }
            return err;
        };
        if (fig_report.warnings.len > 0) {
            diag_warnings.* = try diag_report.renderAll(allocator, fig_report.warnings, fig.Language.FIG.Parser.Warning.describeWarning, fig.Language.FIG.Parser.Warning.shortLabel);
        } else if (json_report.warnings.len > 0) {
            diag_warnings.* = try diag_report.renderAll(allocator, json_report.warnings, fig.Language.JSON.Parser.Warning.describeWarning, fig.Language.JSON.Parser.Warning.shortLabel);
        } else if (toml_report.warnings.len > 0) {
            diag_warnings.* = try diag_report.renderAll(allocator, toml_report.warnings, fig.Language.TOML.Parser.Warning.describeWarning, fig.Language.TOML.Parser.Warning.shortLabel);
        }
    }
    return format;
}

test "resolveSpec maps YAML version strings" {
    const t = std.testing;
    // Default (no --spec) yields each language's default; YAML default is 1.2.2.
    try t.expectEqual(fig.Language.YAML.default_type, (try resolveSpec(.yaml, null)).yaml);
    try t.expectEqual(@as(fig.Language.YAML.Type, .v1_2_2), (try resolveSpec(.yaml, "1.2.2")).yaml);
    try t.expectEqual(@as(fig.Language.YAML.Type, .v1_2_2), (try resolveSpec(.yaml, "1.2")).yaml);
    // 1.1 is now selectable (was previously rejected as UnsupportedSpec).
    try t.expectEqual(@as(fig.Language.YAML.Type, .v1_1), (try resolveSpec(.yaml, "1.1")).yaml);
    try t.expectEqual(@as(fig.Language.YAML.Type, .v1_1), (try resolveSpec(.yaml, "1.1.0")).yaml);
    try t.expectEqual(@as(fig.Language.YAML.Type, .v1_1), (try resolveSpec(.yml, "1.1")).yaml);
    // Unknown YAML versions still error.
    try t.expectError(error.UnsupportedSpec, resolveSpec(.yaml, "1.3"));
    try t.expectError(error.UnsupportedSpec, resolveSpec(.yaml, "2"));
}
