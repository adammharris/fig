//! Shared JSON string encoder: double-quote and escape a byte slice using the
//! JSON escape set.
//!
//! This is the single source of truth for the *encode* side, used by both the
//! JSON printer and the native printer (their previous copies were byte-for-byte
//! identical, so a change to one silently diverged from the other). The escape
//! set here is the inverse of what each parser's escape *decoder* accepts —
//! anything emitted here must decode back unchanged, so keep the two in lockstep.

const std = @import("std");
const Writer = std.Io.Writer;

/// Write `value` as a quoted, escaped JSON string (surrounding `"` included).
/// Bytes ≥ 0x20 other than `"`/`\` pass through verbatim, so arbitrary UTF-8
/// round-trips. Runs of pass-through bytes are flushed with a single `writeAll`,
/// dropping to the escape path only at a byte that needs it — ASCII-heavy
/// strings (the common case) emit in one call rather than byte-by-byte.
pub fn writeQuoted(writer: *Writer, value: []const u8) Writer.Error!void {
    try writer.writeByte('"');
    var run_start: usize = 0;
    for (value, 0..) |char, i| {
        const escape: []const u8 = switch (char) {
            '"' => "\\\"",
            '\\' => "\\\\",
            0x08 => "\\b",
            0x0c => "\\f",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                try writer.writeAll(value[run_start..i]);
                try writeControlEscape(writer, char);
                run_start = i + 1;
                continue;
            },
            else => continue, // pass-through: extend the current run
        };
        try writer.writeAll(value[run_start..i]);
        try writer.writeAll(escape);
        run_start = i + 1;
    }
    try writer.writeAll(value[run_start..]);
    try writer.writeByte('"');
}

/// Emit a non-printable control byte as a `\u00XX` escape.
fn writeControlEscape(writer: *Writer, char: u8) Writer.Error!void {
    const hex = "0123456789abcdef";
    try writer.writeAll("\\u00");
    try writer.writeByte(hex[char >> 4]);
    try writer.writeByte(hex[char & 0x0f]);
}

test "passes through, escapes, and quotes" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeQuoted(&out.writer, "tab:\t quote:\" back:\\ ctrl:\x07 utf:\xc3\xa9");
    try std.testing.expectEqualStrings(
        "\"tab:\\t quote:\\\" back:\\\\ ctrl:\\u0007 utf:\xc3\xa9\"",
        out.written(),
    );
}
