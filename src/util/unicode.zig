//! Helper functions for parsing Unicode sequences.
const std = @import("std");
const Unicode = @This();

pub fn isHighSurrogate(p: u21) bool {
    return p >= 0xD800 and p <= 0xDBFF;
}
pub fn isLowSurrogate(p: u21) bool {
    return p >= 0xDC00 and p <= 0xDFFF;
}
pub fn isSurrogate(p: u21) bool {
    return p >= 0xD800 and p <= 0xDFFF;
}

pub const EncodeError = error{InvalidCodepoint} || std.mem.Allocator.Error;

/// UTF-8 encode `codepoint` and append it to `out`. Rejects the surrogate range
/// and out-of-range values (anything `utf8Encode` can't represent) as
/// `error.InvalidCodepoint`. This is the shared tail of the JSON/YAML/TOML
/// `\u`/`\U`/`\x` escape decoders, which differ only in how they *parse* the
/// codepoint, not in how they emit it.
pub fn encodeAppend(out: *std.ArrayList(u8), allocator: std.mem.Allocator, codepoint: u21) EncodeError!void {
    if (isSurrogate(codepoint)) return error.InvalidCodepoint;
    var buf: [4]u8 = undefined;
    const written = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidCodepoint;
    try out.appendSlice(allocator, buf[0..written]);
}

test "encodeAppend emits UTF-8 and rejects surrogates" {
    const t = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try encodeAppend(&out, t.allocator, 0x00E9); // é
    try encodeAppend(&out, t.allocator, 0x1D11E); // 𝄞
    try t.expectEqualStrings("\xc3\xa9\xf0\x9d\x84\x9e", out.items);
    try t.expectError(error.InvalidCodepoint, encodeAppend(&out, t.allocator, 0xD800));
}
