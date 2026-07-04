const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

pub const Language = @This();

// Per-language gates: a compiled-out format resolves to `void`, so its module is
// never referenced and never built. Every call site that touches a gated
// `Language.*` must guard the access behind the same `build_options.lang_*`
// flag (a `comptime` check), or it will fail to compile against `void`. JSON is
// gateable like the rest now that `detect` no longer assumes it as a base.
pub const JSON = if (build_options.lang_json) @import("json/json.zig").Language else void;
pub const YAML = if (build_options.lang_yaml) @import("yaml/yaml.zig").Language else void;
pub const TOML = if (build_options.lang_toml) @import("toml/toml.zig").Language else void;
pub const ZON = if (build_options.lang_zon) @import("zon/zon.zig").Language else void;
pub const XML = if (build_options.lang_xml) @import("xml/xml.zig").Language else void;
pub const FIG = if (build_options.lang_fig) @import("fig/fig.zig").Language else void;

/// A format `detect` can recognize. The `jsonc` dialect and `canonical` are
/// deliberately excluded: jsonc overlaps json/json5 on most input, and
/// canonical is an explicit selection rather than something to sniff. `fig`
/// IS included, but slotted just ahead of YAML (see the ordering note on
/// `detect`) since its grammar overlaps TOML/YAML on plain `key = value`
/// content — it only wins detection on input that is either invalid for
/// every stricter format, or uses fig-only structural syntax (`>` section
/// depth, `*` elements, `+` continuations, `[]` group headers).
pub const Detected = enum { json, json5, yaml, toml, zon, xml, fig };

/// Best-effort content sniffing: try each COMPILED-IN parser and return the
/// first that accepts `input`, or null if none do (also what an
/// all-languages-disabled build returns). Order matters because the grammars
/// overlap — from most to least strict: JSON/JSON5, ZON, XML, TOML, then fig,
/// then YAML. fig sits just before YAML, not after it: YAML is so permissive
/// (a bare line is a valid plain scalar) that almost anything falls through to
/// it, which would starve fig of a turn if it went last. fig itself overlaps
/// TOML heavily (both accept plain `key = value`), so it is tried only after
/// TOML has had first claim — a plain TOML-shaped document still resolves to
/// `.toml`, and fig only wins on content TOML can't parse (its `>`/`*`/`+`/`[]`
/// structural markers) or that is otherwise TOML-invalid. This is a heuristic,
/// not a proof: input valid as more than one format resolves to the earliest
/// candidate in this order.
pub fn detect(allocator: Allocator, input: []const u8) ?Detected {
    if (comptime build_options.lang_json) {
        if (tryParse(JSON, allocator, input, .JSON)) return .json;
        if (tryParse(JSON, allocator, input, .JSON5)) return .json5;
    }
    if (comptime build_options.lang_zon) {
        if (tryParse(ZON, allocator, input, ZON.default_type)) return .zon;
    }
    if (comptime build_options.lang_xml) {
        if (tryParse(XML, allocator, input, XML.default_type)) return .xml;
    }
    if (comptime build_options.lang_toml) {
        if (tryParse(TOML, allocator, input, TOML.default_type)) return .toml;
    }
    if (comptime build_options.lang_fig) {
        if (tryParse(FIG, allocator, input, FIG.default_type)) return .fig;
    }
    if (comptime build_options.lang_yaml) {
        if (tryParse(YAML, allocator, input, YAML.default_type)) return .yaml;
    }
    return null;
}

/// Parse with `Lang` and report only whether it succeeded, releasing the document
/// either way. The detection probe — content is parsed, never retained.
fn tryParse(comptime Lang: type, allocator: Allocator, input: []const u8, t: Lang.Type) bool {
    const doc = Lang.Parser.parse(allocator, input, t) catch return false;
    doc.deinit(allocator);
    return true;
}

pub fn validate(comptime Lang: type) void {
    comptime {
        if (!@hasDecl(Lang, "Type"))
            @compileError("Language must define Type");

        if (!@hasDecl(Lang, "default_type"))
            @compileError("Language must define default_type");

        if (!@hasDecl(Lang, "parse"))
            @compileError("Language must define parse");
        if (!@hasDecl(Lang, "print"))
            @compileError("Language must define print");
    }
}

test "detect identifies each compiled-in format by content" {
    const a = std.testing.allocator;
    if (comptime build_options.lang_json) {
        try std.testing.expectEqual(Detected.json, detect(a, "{\"x\":1}").?);
    }
    if (comptime build_options.lang_zon) {
        try std.testing.expectEqual(Detected.zon, detect(a, ".{ .x = 1 }").?);
    }
    if (comptime build_options.lang_xml) {
        try std.testing.expectEqual(Detected.xml, detect(a, "<r/>").?);
    }
    if (comptime build_options.lang_toml) {
        try std.testing.expectEqual(Detected.toml, detect(a, "x = 1\n").?);
    }
    if (comptime build_options.lang_fig) {
        // A bare container header line (no `=`, no `:`, no brackets) followed
        // by a `>`-depth child isn't valid JSON/ZON/XML/TOML, so this resolves
        // to fig even though it's tried before YAML.
        try std.testing.expectEqual(Detected.fig, detect(a, "database\n> host = localhost\n").?);
    }
    if (comptime build_options.lang_yaml) {
        // A plain mapping that is not valid JSON/TOML/fig/etc. falls through to
        // YAML, the most permissive grammar and therefore tried last.
        try std.testing.expectEqual(Detected.yaml, detect(a, "key: value\n").?);
    }
}

test "detect: plain `key = value` prefers TOML over fig despite fig accepting it too" {
    const a = std.testing.allocator;
    if (comptime !build_options.lang_toml or !build_options.lang_fig) return error.SkipZigTest;
    // fig's root-level dotted assignment accepts the exact same shape TOML
    // does; TOML is tried first, so it wins the tie.
    try std.testing.expectEqual(Detected.toml, detect(a, "x = 1\n").?);
}
