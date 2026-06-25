//! Small character-class predicates shared by the format parsers.
//!
//! `isDigit`/`isHex` are aliased from `std.ascii` so callers have a single
//! import point for the whole set; `isOctal`/`isBinary` aren't in the stdlib,
//! so they live here. Each has the `fn (u8) bool` shape the parsers pass as a
//! comptime predicate to their underscore/digit-run validators.

const std = @import("std");

pub const isDigit = std.ascii.isDigit;
pub const isHex = std.ascii.isHex;

pub fn isOctal(c: u8) bool {
    return c >= '0' and c <= '7';
}

pub fn isBinary(c: u8) bool {
    return c == '0' or c == '1';
}

test "digit predicates" {
    const t = std.testing;
    try t.expect(isDigit('0') and isDigit('9') and !isDigit('a'));
    try t.expect(isHex('f') and isHex('A') and !isHex('g'));
    try t.expect(isOctal('7') and !isOctal('8'));
    try t.expect(isBinary('1') and !isBinary('2'));
}
