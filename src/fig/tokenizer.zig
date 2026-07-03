//! fig authoring dialect — low-level scanning helpers shared by the block-layer
//! and flow-mode parsers (see `parser.zig`). These are pure functions/structs
//! operating on caller-owned byte slices; no parser state lives here, mirroring
//! how the TOML tokenizer separates lexical classification from tree assembly.
//!
//! Scope (see DESIGN.md "Grammar" / "The context-sensitive layer"):
//!   * `sniffBare` — the literal-else-string bare-token classifier (rule 3).
//!   * Quoted / multiline string scanning (rule 5, "suspended regions").
//!   * Bare-key character classification.

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("../ast/ast.zig");
const datetime = @import("../util/datetime.zig");
const ascii = @import("../util/ascii.zig");

pub const ExtKind = AST.Node.Kind.Extended.ExtKind;

/// The result of sniffing a bare (unquoted, undelimited) token.
pub const Sniffed = union(enum) {
    null_,
    boolean: bool,
    number: NumberResult,
    datetime: struct { kind: ExtKind, raw: []const u8 },
    /// Nothing typed matched; the caller keeps the original text verbatim as a
    /// plain string (the literal-else-string fallback).
    string,
};

/// Literal-else-string: classify a trimmed bare token. Never fails — a token
/// that matches nothing typed sniffs as `.string`. Enum atoms and `inf`/`nan`
/// are NOT sniffed here — they are explicit-typing-only (DESIGN.md "Enum:
/// explicit-only"), so a bare `@x`/`inf` correctly falls through to `.string`.
/// `true`/`false`/`null` are matched case-sensitively (lowercase only) — `Yes`,
/// `TRUE`, `on` stay strings (the Norway-problem fix).
pub fn sniffBare(token: []const u8) Sniffed {
    if (token.len == 0) return .string;
    if (std.mem.eql(u8, token, "null")) return .null_;
    if (std.mem.eql(u8, token, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, token, "false")) return .{ .boolean = false };
    if (sniffNumber(token)) |n| return .{ .number = n };
    if (datetime.classify(token, .{})) |k| {
        return .{ .datetime = .{
            .kind = switch (k) {
                .offset_datetime => .offset_datetime,
                .local_datetime => .local_datetime,
                .local_date => .local_date,
                .local_time => .local_time,
            },
            .raw = token,
        } };
    } else |_| {}
    return .string;
}

pub const NumberResult = struct { raw: []const u8, kind: enum { integer, float } };

/// TOML-style bare-number sniff: decimal integers/floats (with optional
/// exponent) and `0x`/`0o`/`0b` integers. A leading zero on a multi-digit
/// decimal integer part is NOT a number — it stays a string, keeping
/// zero-padded IDs/zip codes intact (DESIGN.md "Leading-zero rule").
pub fn sniffNumber(token: []const u8) ?NumberResult {
    if (token.len == 0) return null;
    var i: usize = 0;
    if (token[0] == '+' or token[0] == '-') i = 1;
    if (i >= token.len) return null;
    const body = token[i..];

    if (body.len >= 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'o' or body[1] == 'b')) {
        const digits = body[2..];
        if (digits.len == 0) return null;
        for (digits) |c| {
            const ok = switch (body[1]) {
                'x' => ascii.isHex(c),
                'o' => ascii.isOctal(c),
                'b' => ascii.isBinary(c),
                else => unreachable,
            };
            if (!ok) return null;
        }
        return .{ .raw = token, .kind = .integer };
    }

    var j: usize = i;
    const int_start = j;
    while (j < token.len and ascii.isDigit(token[j])) : (j += 1) {}
    const int_len = j - int_start;
    if (int_len == 0) return null;
    if (int_len > 1 and token[int_start] == '0') return null; // leading zero
    var is_float = false;
    if (j < token.len and token[j] == '.') {
        is_float = true;
        j += 1;
        const frac_start = j;
        while (j < token.len and ascii.isDigit(token[j])) : (j += 1) {}
        if (j == frac_start) return null; // a dot needs >=1 fractional digit
    }
    if (j < token.len and (token[j] == 'e' or token[j] == 'E')) {
        is_float = true;
        j += 1;
        if (j < token.len and (token[j] == '+' or token[j] == '-')) j += 1;
        const exp_start = j;
        while (j < token.len and ascii.isDigit(token[j])) : (j += 1) {}
        if (j == exp_start) return null;
    }
    if (j != token.len) return null; // trailing garbage -> not a clean number
    return .{ .raw = token, .kind = if (is_float) .float else .integer };
}

/// A bare key/identifier char: letters, digits, `_`, `-`.
pub fn isBareKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// How a `[`/`{`-led block RHS commits (DESIGN.md "Committed values"): commitment
/// is a property of the *whole* RHS, not just the first char.
pub const BracketCommit = enum {
    /// The matching close is the final non-comment token on the line → parse as
    /// flow (committed; a later parse failure is a hard error).
    flow,
    /// A balanced close is followed by more non-comment content (`[text](url)`, a
    /// glob, a regex) → never flow; the whole line is a bare string.
    bare_trailing,
    /// The bracket does not close on this line → multi-line flow region *or* a
    /// genuine truncation. Handed to the flow parser (it scans across lines and
    /// raises FigUnclosedFlow at EOF).
    unclosed,
};

/// Decide how a `[`/`{`-led block RHS commits. `start` indexes the opening
/// bracket; scanning stops at the first newline (bare block values are
/// single-line). Quoted spans are skipped so brackets inside strings don't count
/// toward matching (`['[Blog](x)']` closes at its final `]`, not the inner one).
pub fn classifyBracketCommit(source: []const u8, start: usize) BracketCommit {
    std.debug.assert(source[start] == '[' or source[start] == '{');
    var depth: usize = 0;
    var i = start;
    while (i < source.len and source[i] != '\n') {
        switch (source[i]) {
            '\'', '"' => i = skipQuotedSpan(source, i) orelse return .unclosed,
            '[', '{' => {
                depth += 1;
                i += 1;
            },
            ']', '}' => {
                depth -= 1;
                i += 1;
                if (depth == 0)
                    return if (restIsCommentOnly(source, i)) .flow else .bare_trailing;
            },
            else => i += 1,
        }
    }
    return .unclosed;
}

/// Skip a single-line quoted span starting at the opening quote `source[start]`.
/// Returns the index just past the close, or null if it doesn't close before the
/// newline (an unterminated quote inside the brackets → treat as `.unclosed`).
/// `"` honors `\`-escapes; `'` is raw (mirroring the value grammar).
fn skipQuotedSpan(source: []const u8, start: usize) ?usize {
    const q = source[start];
    var i = start + 1;
    while (i < source.len and source[i] != '\n') : (i += 1) {
        if (q == '"' and source[i] == '\\') {
            i += 1;
            continue;
        }
        if (source[i] == q) return i + 1;
    }
    return null;
}

/// After a balanced close at `from`, is the rest of the line only whitespace and
/// an optional `#` comment? Honors the `#`-after-whitespace rule: a `#` glued to
/// the close (`[1,2]#x`) is literal, so the value is `.bare_trailing`, not flow.
fn restIsCommentOnly(source: []const u8, from: usize) bool {
    var i = from;
    var saw_space = false;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\r')) : (i += 1) saw_space = true;
    if (i >= source.len or source[i] == '\n') return true;
    return saw_space and source[i] == '#';
}

/// Flow-element twin of `classifyBracketCommit`. Inside a flow collection an
/// element ends at the next top-level `,`/`]`/`}` (or newline / `#` / EOF), not
/// at end-of-line, and flow spans newlines — so both the terminal test and the
/// scan range differ from the block-layer classifier. A balanced bracket group
/// followed by a flow terminator is genuine nested flow (`[1, 2]` as a list
/// member); one followed by more content is a bare-string element (`[Blog](/x)`,
/// a markdown link) — the flow-position form of the balanced-then-trailing rule
/// that lets markdown links go unquoted. There is no `.unclosed` outcome: an
/// unterminated bracket is left to the flow parser (which raises
/// FigUnclosedFlow), so this reports `.flow`.
pub fn classifyFlowBracket(source: []const u8, start: usize) BracketCommit {
    std.debug.assert(source[start] == '[' or source[start] == '{');
    var depth: usize = 0;
    var i = start;
    while (i < source.len) {
        switch (source[i]) {
            '\'', '"' => i = skipQuotedSpan(source, i) orelse return .flow,
            '[', '{' => {
                depth += 1;
                i += 1;
            },
            ']', '}' => {
                depth -= 1;
                i += 1;
                if (depth == 0)
                    return if (flowRestIsTerminator(source, i)) .flow else .bare_trailing;
            },
            else => i += 1,
        }
    }
    return .flow;
}

/// After a flow element's balanced close at `from`, does the next non-blank byte
/// terminate the element (`,`/`]`/`}`), end the line/input, or open a comment
/// (`#`)? If so the bracket group WAS the whole value → genuine nested flow;
/// otherwise more content follows and it is a bare-string element.
fn flowRestIsTerminator(source: []const u8, from: usize) bool {
    var i = from;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\r')) : (i += 1) {}
    if (i >= source.len) return true;
    return switch (source[i]) {
        ',', ']', '}', '\n', '#' => true,
        else => false,
    };
}

// ── Quoted / multiline string scanning ──────────────────────────────────────
// Each scanner starts at the OPENING delimiter and returns the decoded text
// plus the index just past the CLOSING delimiter. Decoded text is always
// caller-owned (allocated with `allocator`).

pub const ScanError = error{
    FigUnclosedString,
    FigBadEscape,
} || Allocator.Error;

pub const ScanResult = struct { text: []const u8, end: usize };

/// `'...'` — raw/literal, no escapes. A newline before the close is an error
/// (single-line only; use `'''...'''` for verbatim multi-line blobs).
pub fn scanSingleQuoted(allocator: Allocator, source: []const u8, start: usize) ScanError!ScanResult {
    std.debug.assert(source[start] == '\'');
    var i = start + 1;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (c == '\n') return error.FigUnclosedString;
        if (c == '\'') {
            const text = try allocator.dupe(u8, source[start + 1 .. i]);
            return .{ .text = text, .end = i + 1 };
        }
    }
    return error.FigUnclosedString;
}

/// `"..."` — escaped: `\n \t \r \\ \" \' \uXXXX`. A newline before the close is
/// an error.
pub fn scanDoubleQuoted(allocator: Allocator, source: []const u8, start: usize) ScanError!ScanResult {
    std.debug.assert(source[start] == '"');
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i = start + 1;
    while (i < source.len) {
        const c = source[i];
        if (c == '\n') return error.FigUnclosedString;
        if (c == '"') {
            return .{ .text = try out.toOwnedSlice(allocator), .end = i + 1 };
        }
        if (c == '\\') {
            i = try decodeEscape(allocator, source, i, &out);
            continue;
        }
        try out.append(allocator, c);
        i += 1;
    }
    return error.FigUnclosedString;
}

/// Decode one `\...` escape starting at `source[i] == '\\'`, appending the
/// decoded byte(s) to `out`. Returns the index just past the escape.
fn decodeEscape(allocator: Allocator, source: []const u8, i: usize, out: *std.ArrayList(u8)) ScanError!usize {
    if (i + 1 >= source.len) return error.FigBadEscape;
    const e = source[i + 1];
    switch (e) {
        'n' => try out.append(allocator, '\n'),
        't' => try out.append(allocator, '\t'),
        'r' => try out.append(allocator, '\r'),
        '\\' => try out.append(allocator, '\\'),
        '"' => try out.append(allocator, '"'),
        '\'' => try out.append(allocator, '\''),
        'u' => {
            if (i + 6 > source.len) return error.FigBadEscape;
            const hex = source[i + 2 .. i + 6];
            const cp = std.fmt.parseInt(u21, hex, 16) catch return error.FigBadEscape;
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch return error.FigBadEscape;
            try out.appendSlice(allocator, buf[0..len]);
            return i + 6;
        },
        else => return error.FigBadEscape,
    }
    return i + 2;
}

/// `'''` ... `'''` — raw/verbatim multi-line. The opener line may carry a
/// trailing `# comment` (returned separately, per DESIGN.md); content begins
/// at the next line and is copied byte-for-byte (no dedent, no escapes) up to
/// (not including) the final line's trailing newline.
pub fn scanTripleSingle(allocator: Allocator, source: []const u8, start: usize) ScanError!MultilineResult {
    return scanTriple(allocator, source, start, '\'', false);
}

/// `"""` ... `"""` — escaped, with the common leading indentation (measured
/// from the closing delimiter's own line) stripped from every content line.
pub fn scanTripleDouble(allocator: Allocator, source: []const u8, start: usize) ScanError!MultilineResult {
    return scanTriple(allocator, source, start, '"', true);
}

pub const MultilineResult = struct {
    text: []const u8,
    end: usize,
    /// A `# comment` on the opening delimiter's own line, if any.
    opener_comment: ?[]const u8,
};

fn scanTriple(allocator: Allocator, source: []const u8, start: usize, q: u8, dedent_and_escape: bool) ScanError!MultilineResult {
    std.debug.assert(source[start] == q and source[start + 1] == q and source[start + 2] == q);
    var i = start + 3;
    // Rest of the opener line: only whitespace and an optional `# comment` are
    // meaningful; content capture begins at the next newline.
    var opener_comment: ?[]const u8 = null;
    while (i < source.len and source[i] != '\n') : (i += 1) {
        if (source[i] == '#') {
            const cstart = i + 1;
            var j = cstart;
            while (j < source.len and source[j] != '\n') j += 1;
            opener_comment = std.mem.trim(u8, source[cstart..j], " \t\r");
            i = j;
            break;
        }
    }
    if (i < source.len and source[i] == '\n') i += 1;
    const body_start = i;

    const marker = [3]u8{ q, q, q };
    const close_pos = std.mem.indexOfPos(u8, source, body_start, &marker) orelse
        return error.FigUnclosedString;

    // Dedent amount: the whitespace run immediately preceding the close on its
    // own line.
    var line_start = close_pos;
    while (line_start > body_start and source[line_start - 1] != '\n') line_start -= 1;
    const dedent = close_pos - line_start;

    // Body text excludes the closing line and its preceding newline.
    var body_end = line_start;
    if (body_end > body_start and source[body_end - 1] == '\n') body_end -= 1;
    if (body_end > body_start and source[body_end - 1] == '\r') body_end -= 1;
    const body = if (body_end >= body_start) source[body_start..body_end] else "";

    // Consume up to two extra quotes hugging the close (mirrors TOML), so
    // `""""""` (a literal `""` at the end) round-trips.
    var end = close_pos + 3;
    var extra: usize = 0;
    while (extra < 2 and end < source.len and source[end] == q) : (extra += 1) end += 1;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    while (it.next()) |raw_line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        var line = raw_line;
        if (dedent_and_escape) {
            var stripped: usize = 0;
            while (stripped < dedent and line.len > 0 and (line[0] == ' ' or line[0] == '\t')) : (stripped += 1) line = line[1..];
        }
        if (dedent_and_escape) {
            var k: usize = 0;
            while (k < line.len) {
                if (line[k] == '\\') {
                    k = try decodeEscape(allocator, line, k, &out);
                } else {
                    try out.append(allocator, line[k]);
                    k += 1;
                }
            }
        } else {
            try out.appendSlice(allocator, line);
        }
    }

    return .{ .text = try out.toOwnedSlice(allocator), .end = end, .opener_comment = opener_comment };
}

test "sniffNumber rejects leading zero, accepts hex/float/exponent" {
    try std.testing.expect(sniffNumber("007") == null);
    try std.testing.expect(sniffNumber("0") != null);
    try std.testing.expect(sniffNumber("0.5") != null);
    try std.testing.expectEqualStrings("0xFF", sniffNumber("0xFF").?.raw);
    try std.testing.expect(sniffNumber("1.5e3").?.kind == .float);
    try std.testing.expect(sniffNumber("12 monkeys") == null);
}

test "sniffBare classifies literals" {
    try std.testing.expect(sniffBare("null") == .null_);
    try std.testing.expect(sniffBare("true").boolean == true);
    try std.testing.expect(sniffBare("Yes") == .string);
    try std.testing.expect(sniffBare("007") == .string);
    try std.testing.expect(sniffBare("2026-07-01").datetime.kind == .local_date);
}

test "scanDoubleQuoted decodes escapes" {
    const a = std.testing.allocator;
    const r = try scanDoubleQuoted(a, "\"a\\tb\\n\\u2603\"", 0);
    defer a.free(r.text);
    try std.testing.expectEqualStrings("a\tb\n☃", r.text);
}

test "scanTripleDouble dedents and decodes" {
    const a = std.testing.allocator;
    const src =
        \\"""
        \\    hi
        \\    there
        \\    """
    ;
    const r = try scanTripleDouble(a, src, 0);
    defer a.free(r.text);
    try std.testing.expectEqualStrings("hi\nthere", r.text);
}

test "classifyBracketCommit: flow vs bare-trailing vs unclosed" {
    // terminal close → flow
    try std.testing.expect(classifyBracketCommit("[80, 443]\n", 0) == .flow);
    try std.testing.expect(classifyBracketCommit("[80, 443]  # c\n", 0) == .flow);
    try std.testing.expect(classifyBracketCommit("{}", 0) == .flow);
    try std.testing.expect(classifyBracketCommit("[['a, b']]", 0) == .flow); // brackets inside quotes don't count
    // balanced then trailing content → bare string
    try std.testing.expect(classifyBracketCommit("[Blog](/x)\n", 0) == .bare_trailing);
    try std.testing.expect(classifyBracketCommit("[a-z]*.md", 0) == .bare_trailing);
    try std.testing.expect(classifyBracketCommit("[b]x[/b]", 0) == .bare_trailing);
    try std.testing.expect(classifyBracketCommit("[80]#glued", 0) == .bare_trailing); // glued # is literal
    // never closes on the line → unclosed (multi-line flow or truncation)
    try std.testing.expect(classifyBracketCommit("[80, 443", 0) == .unclosed);
    try std.testing.expect(classifyBracketCommit("[\n", 0) == .unclosed);
    try std.testing.expect(classifyBracketCommit("['unterminated]", 0) == .unclosed);
}

test "classifyFlowBracket: nested flow vs bare-trailing element" {
    // A balanced group followed by a flow terminator is a nested collection.
    try std.testing.expect(classifyFlowBracket("[1, 2], 3]", 0) == .flow);
    try std.testing.expect(classifyFlowBracket("[1, 2]]", 0) == .flow);
    try std.testing.expect(classifyFlowBracket("{ x = 1 }, y]", 0) == .flow);
    try std.testing.expect(classifyFlowBracket("[a, b]\n", 0) == .flow);
    // A balanced group with trailing content is a bare-string element (a
    // markdown link, glob, regex) — the flow twin of the block bare-trailing.
    try std.testing.expect(classifyFlowBracket("[Blog](/x), [Resume](/y)]", 0) == .bare_trailing);
    try std.testing.expect(classifyFlowBracket("[a-z]*.md, next]", 0) == .bare_trailing);
    // Unterminated → left to the flow parser (reported as flow).
    try std.testing.expect(classifyFlowBracket("[1, 2", 0) == .flow);
}

test "scanTripleSingle is verbatim" {
    const a = std.testing.allocator;
    const src = "'''\nraw \\n text\n'''";
    const r = try scanTripleSingle(a, src, 0);
    defer a.free(r.text);
    try std.testing.expectEqualStrings("raw \\n text", r.text);
}
