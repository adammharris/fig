const Allocator = @import("std").mem.Allocator;
const build_options = @import("build_options");

pub const Language = @This();

// Per-language gates: a compiled-out format resolves to `void`, so its module is
// never referenced and never built. Every call site that touches a gated
// `Language.*` must guard the access behind the same `build_options.lang_*`
// flag (a `comptime` check), or it will fail to compile against `void`. JSON is
// always present.
pub const JSON = @import("json/json.zig").Language;
pub const YAML = if (build_options.lang_yaml) @import("yaml/yaml.zig").Language else void;
pub const TOML = if (build_options.lang_toml) @import("toml/toml.zig").Language else void;
pub const ZON = if (build_options.lang_zon) @import("zon/zon.zig").Language else void;
pub const XML = if (build_options.lang_xml) @import("xml/xml.zig").Language else void;

pub fn detect(allocator: Allocator, input: []const u8) ?JSON.Type {
    var parser = JSON.Parser{ .allocator = allocator };

    if (JSON.parse(&parser, input, .JSON)) |doc| {
        doc.deinit(allocator);
        return .JSON;
    } else |_| {}

    if (JSON.parse(&parser, input, .JSONC)) |doc| {
        doc.deinit(allocator);
        return .JSONC;
    } else |_| {}

    return null;
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
