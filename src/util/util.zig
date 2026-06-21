pub const Span = @import("span.zig");
pub const Unicode = @import("unicode.zig");
pub const json_string = @import("json_string.zig");

test {
    _ = json_string;
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

test "util.eql" {
    try @import("std").testing.expect(eql(u8, "hello, world!", "hello, world!"));
}
