const std = @import("std");

pub const Span = @import("span.zig");
pub const Unicode = @import("unicode.zig");
pub const json_string = @import("json_string.zig");
pub const ascii = @import("ascii.zig");
pub const datetime = @import("datetime.zig");

test {
    _ = json_string;
    _ = ascii;
    _ = datetime;
    _ = Unicode;
}

/// Like std.mem.eql, but also works if type has a `.eql` function defined.
pub fn eql(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"opaque", .vector, .array => {
            if (!@hasDecl(T, "eql")) @compileError("No eql defined for this type");
            for (a, b) |aa, bb| if (!aa.eql(bb)) return false;
        },
        else => for (a, b) |aa, bb| if (aa != bb) return false,
    }
    return true;
}

/// True when byte slice `s` exactly equals one of `options`. The shared form of
/// the keyword-set matching the format parsers do (null/bool spellings, the
/// `inf`/`nan` floats, etc.).
pub fn eqlAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

test "util.eql" {
    try std.testing.expect(eql(u8, "hello, world!", "hello, world!"));
}

test "util.eqlAny" {
    try std.testing.expect(eqlAny("yes", &.{ "y", "yes", "true" }));
    try std.testing.expect(!eqlAny("maybe", &.{ "y", "yes", "true" }));
}
