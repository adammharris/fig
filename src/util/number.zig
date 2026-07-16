//! Number-lexeme rendering shared by the printers.
//!
//! A number's `raw` is the source lexeme — the payload IS the value (`ast.zig`)
//! — so a printer's instinct is to write it back verbatim. That is only correct
//! when the target format reads the lexeme back as the *same number*. It often
//! doesn't: YAML 1.2 resolves `0b1010` to a **string**, and JSON5 rejects
//! `0o755` outright. Writing raw there emits a silent type change, or output
//! the target cannot parse at all.
//!
//! So a printer asks `spellable(raw, <target>)` first, and falls back to
//! `writeCanonical` — decimal, the one spelling every format shares. This is a
//! *spelling* degrade: the value is unchanged, only its notation.

const std = @import("std");

/// The number spellings a target format reads back as a number. A `false` field
/// means the printer must canonicalize that spelling to decimal instead.
pub const Spelling = struct {
    /// `0x1F`
    hex: bool = false,
    /// `0o17`
    octal: bool = false,
    /// `0b1010`
    binary: bool = false,
    /// `1_000` — digit separators
    underscores: bool = false,
    /// `0755` — a multi-digit integer part led by a zero
    leading_zero: bool = false,
    /// `.5` / `5.`
    bare_dot: bool = false,
    /// a leading `+`
    plus: bool = false,
};

/// Strict JSON: none of it. Every non-decimal spelling canonicalizes.
pub const json: Spelling = .{};

/// JSON5 numbers are ES5.1 `NumericLiteral`: hex, leading `+`, and bare dots —
/// but NOT `0o`/`0b` (ES6), `_` (ES2021), or a leading zero. Verified against
/// this repo's own JSON5 tokenizer, which rejects all four.
pub const json5: Spelling = .{ .hex = true, .bare_dot = true, .plus = true };

/// YAML 1.2 core: int is `[-+]?[0-9]+ | 0o[0-7]+ | 0x[0-9a-fA-F]+`, float takes
/// a bare dot. No `0b` and no `_` — 1.2 resolves both to a *string*.
///
/// 1.1's extra spellings (`0b`, `_`, base-60) are deliberately NOT claimed: the
/// YAML printer has no version parameter, so it targets the default type
/// (`yaml.zig`: `default_type = .v1_2_2`). `leading_zero` IS claimed because
/// 1.2 reads `0755` as decimal 755 — note 1.1 would read it as octal 493, an
/// ambiguity the AST cannot represent (the parser stores the lexeme and leaves
/// resolution to the consumer), so it is left alone rather than guessed at.
pub const yaml_1_2: Spelling = .{
    .hex = true,
    .octal = true,
    .leading_zero = true,
    .bare_dot = true,
    .plus = true,
};

/// Whether a format that can spell `s` reads `raw` back as the same number.
pub fn spellable(raw: []const u8, s: Spelling) bool {
    var body = raw;
    if (body.len > 0 and (body[0] == '+' or body[0] == '-')) {
        if (body[0] == '+' and !s.plus) return false;
        body = body[1..];
    }
    if (body.len == 0) return false;
    if (!s.underscores and std.mem.indexOfScalar(u8, body, '_') != null) return false;

    if (body.len >= 2 and body[0] == '0') switch (body[1] | 0x20) {
        'x' => return s.hex,
        'o' => return s.octal,
        'b' => return s.binary,
        else => {},
    };

    // Decimal from here.
    if (!s.bare_dot and (body[0] == '.' or body[body.len - 1] == '.')) return false;
    if (!s.leading_zero) {
        const int_end = std.mem.indexOfAny(u8, body, ".eE") orelse body.len;
        if (int_end > 1 and body[0] == '0') return false;
    }
    return true;
}

/// Write `raw` verbatim when a format spelling `s` reads it back unchanged,
/// else canonicalized to decimal.
pub fn write(writer: anytype, raw: []const u8, s: Spelling) !void {
    if (spellable(raw, s)) return writer.writeAll(raw);
    return writeCanonical(writer, raw);
}

/// Write `raw` as a decimal lexeme every format can read: radix converted, `_`
/// and `+` dropped, bare dots padded (`.5` -> `0.5`, `5.` -> `5.0`), leading
/// zeros stripped. Plain decimal digits are copied rather than re-formatted, so
/// arbitrary precision and significant figures survive (`1.10` stays `1.10`).
pub fn writeCanonical(writer: anytype, raw: []const u8) !void {
    var s = raw;
    if (s.len > 0 and s[0] == '-') {
        try writer.writeByte('-');
        s = s[1..];
    } else if (s.len > 0 and s[0] == '+') {
        s = s[1..];
    }

    // Radix integers convert; a lexeme too long or too wide for u128 falls back
    // to the sign-stripped source rather than emitting nothing.
    if (s.len >= 2 and s[0] == '0' and (s[1] | 0x20 == 'x' or s[1] | 0x20 == 'o' or s[1] | 0x20 == 'b')) {
        const base: u8 = switch (s[1] | 0x20) {
            'x' => 16,
            'o' => 8,
            else => 2,
        };
        var buf: [128]u8 = undefined;
        if (stripUnderscores(s[2..], &buf)) |digits| {
            if (std.fmt.parseInt(u128, digits, base)) |v| {
                try writer.print("{d}", .{v});
                return;
            } else |_| {}
        }
        try writer.writeAll(s);
        return;
    }

    const e_idx = std.mem.indexOfAny(u8, s, "eE");
    const mantissa = if (e_idx) |i| s[0..i] else s;
    const exponent = if (e_idx) |i| s[i..] else "";
    const dot = std.mem.indexOfScalar(u8, mantissa, '.');

    var int_digits: usize = 0;
    var seen_nonzero = false;
    for (if (dot) |d| mantissa[0..d] else mantissa) |c| {
        if (c == '_') continue;
        if (c == '0' and !seen_nonzero) continue; // leading zero
        seen_nonzero = true;
        try writer.writeByte(c);
        int_digits += 1;
    }
    if (int_digits == 0) try writer.writeByte('0'); // `0`, `000`, `.5`

    if (dot) |d| {
        try writer.writeByte('.');
        var frac_digits: usize = 0;
        for (mantissa[d + 1 ..]) |c| {
            if (c == '_') continue;
            try writer.writeByte(c);
            frac_digits += 1;
        }
        if (frac_digits == 0) try writer.writeByte('0'); // `5.` -> `5.0`
    }

    for (exponent) |c| {
        if (c != '_') try writer.writeByte(c);
    }
}

/// Copy `s` into `buf` without `_` digit separators; null if it would overflow.
fn stripUnderscores(s: []const u8, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (c == '_') continue;
        if (n >= buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

test "spellable: strict JSON takes only plain decimal" {
    const t = std.testing;
    try t.expect(spellable("1000", json));
    try t.expect(spellable("-1.5e3", json));
    try t.expect(spellable("1.10", json));
    try t.expect(spellable("0", json));
    try t.expect(spellable("0.5", json));
    try t.expect(!spellable("0xff", json));
    try t.expect(!spellable("0o755", json));
    try t.expect(!spellable("0b1010", json));
    try t.expect(!spellable("1_000", json));
    try t.expect(!spellable("+5", json));
    try t.expect(!spellable(".5", json));
    try t.expect(!spellable("5.", json));
    try t.expect(!spellable("0755", json));
}

test "spellable: JSON5 takes hex but not 0o/0b/_" {
    const t = std.testing;
    try t.expect(spellable("0xff", json5));
    try t.expect(spellable("0XFF", json5));
    try t.expect(spellable("+5", json5));
    try t.expect(spellable(".5", json5));
    try t.expect(spellable("5.", json5));
    try t.expect(!spellable("0o755", json5));
    try t.expect(!spellable("0b1010", json5));
    try t.expect(!spellable("0xf_f", json5));
    try t.expect(!spellable("1_000", json5));
    try t.expect(!spellable("0755", json5));
}

test "spellable: YAML 1.2 takes hex and 0o but not 0b/_" {
    const t = std.testing;
    try t.expect(spellable("0xff", yaml_1_2));
    try t.expect(spellable("0o755", yaml_1_2));
    try t.expect(spellable("0755", yaml_1_2)); // 1.2 reads decimal 755
    try t.expect(spellable("1.5e3", yaml_1_2));
    try t.expect(!spellable("0b1010", yaml_1_2)); // resolves to a string
    try t.expect(!spellable("1_000", yaml_1_2)); // resolves to a string
    try t.expect(!spellable("0xdead_beef", yaml_1_2));
}

test "writeCanonical" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    const canon = struct {
        fn f(b: []u8, raw: []const u8) ![]const u8 {
            var w = std.Io.Writer.fixed(b);
            try writeCanonical(&w, raw);
            return w.buffered();
        }
    }.f;

    // Radix -> decimal, separators dropped.
    try t.expectEqualStrings("255", try canon(&buf, "0xff"));
    try t.expectEqualStrings("3735928559", try canon(&buf, "0xdead_beef"));
    try t.expectEqualStrings("493", try canon(&buf, "0o755"));
    try t.expectEqualStrings("10", try canon(&buf, "0b1010"));
    try t.expectEqualStrings("-255", try canon(&buf, "-0xf_f"));
    try t.expectEqualStrings("1000", try canon(&buf, "1_000"));

    // Bare dots padded; `+` dropped; leading zeros stripped.
    try t.expectEqualStrings("0.5", try canon(&buf, ".5"));
    try t.expectEqualStrings("5.0", try canon(&buf, "5."));
    try t.expectEqualStrings("15", try canon(&buf, "+15"));
    try t.expectEqualStrings("755", try canon(&buf, "0755"));
    try t.expectEqualStrings("0", try canon(&buf, "0"));
    try t.expectEqualStrings("0", try canon(&buf, "000"));
    try t.expectEqualStrings("0.5", try canon(&buf, "00.5"));

    // Significant figures and precision survive — never re-formatted.
    try t.expectEqualStrings("1.10", try canon(&buf, "1.10"));
    try t.expectEqualStrings("1e2", try canon(&buf, "1e2"));
    try t.expectEqualStrings("10.5", try canon(&buf, "1_0.5"));
    try t.expectEqualStrings(
        "123456789012345678901234567890",
        try canon(&buf, "123456789012345678901234567890"),
    );
}
