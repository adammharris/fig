const std = @import("std");

pub const Language = @This();

pub const JSON = @import("json/json.zig").Language;
pub const YAML = @import("yaml/yaml.zig").Language;

pub fn detect(allocator: std.mem.Allocator, input: []const u8) ?JSON.Type {
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
