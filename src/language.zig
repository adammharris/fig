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

/// A format `detect` can recognize. The native `.fig` format and the `jsonc`
/// dialect are deliberately excluded: jsonc overlaps json/json5 on most input,
/// and native is an explicit selection rather than something to sniff.
pub const Detected = enum { json, json5, yaml, toml, zon, xml };

/// Best-effort content sniffing: try each COMPILED-IN parser and return the
/// first that accepts `input`, or null if none do (also what an
/// all-languages-disabled build returns). Order matters because the grammars
/// overlap — the strict/structured formats are tried before YAML, which is so
/// permissive (a bare line is a valid scalar) that it would otherwise claim
/// nearly any input. This is a heuristic, not a proof: input valid as more than
/// one format resolves to the earliest candidate in this order.
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
    if (comptime build_options.lang_yaml) {
        // A plain mapping that is not valid JSON/TOML/etc. falls through to YAML,
        // the most permissive grammar and therefore tried last.
        try std.testing.expectEqual(Detected.yaml, detect(a, "key: value\n").?);
    }
}
