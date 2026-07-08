//! NestedText tokenizer. Turns a NestedText `[]const u8` into a slice of
//! `Line`s — ONE entry per physical line, already classified by the tag
//! character(s) that start its content. This is a deliberate departure from
//! every other tokenizer in this codebase (which emit a character-level
//! token stream via the shared `Token(Kind)` generic): NestedText's grammar
//! is fundamentally "classify this whole line, then decide how it relates to
//! the lines around it by indentation" (much closer to a pre-split line list
//! than a token stream), and unlike YAML there is no flow-context that needs
//! character-level tokens — inline `{...}`/`[...]` forms are always the
//! entire remainder of one line, parsed by a tiny separate scanner in
//! `parser.zig`, not by this tokenizer.
//!
//! Per line, after stripping a run of leading `' '` (space) bytes:
//!   - nothing left (or only trailing whitespace) → `.blank`
//!   - `#` → `.comment` (content = rest of line after the `#`)
//!   - `-` followed by `' '` or end-of-line → `.dash` (list-item tag)
//!   - `:` followed by `' '` or end-of-line → `.colon` (dict-item tag /
//!     multiline-key line)
//!   - `>` followed by `' '` or end-of-line → `.gt` (string-item tag)
//!   - anything else → `.other` — the parser decides whether this is a
//!     `key: value` dict item (scan for the first `: `/trailing `:`), an
//!     inline `{...}`/`[...]` candidate, or unrecognized.
//! For the four tag kinds, `content` is everything after the tag *and* the
//! one mandatory separating space (if any followed) — i.e. exactly what
//! NestedText calls the "rest-of-line" text for that tag. A bare tag with
//! nothing after it (not even a space) or a tag followed immediately by a
//! single space then end-of-line both yield an EMPTY `content` span, which is
//! how the parser recognizes "this item's value is on nested, more-indented
//! lines" per the spec. For `.other`, `content` is the entire line (the
//! parser does its own scanning).
//!
//! Indentation must be plain `' '` bytes; a literal tab or a non-breaking
//! space (U+00A0, the one non-ASCII whitespace character the official
//! conformance suite tests for) in the leading run is `error.InvalidIndentChar`.

const Tokenizer = @This();

const std = @import("std");
const Span = @import("../../util/span.zig");

pub const Kind = enum { blank, comment, dash, colon, gt, other, end_of_file };

pub const Line = struct {
    kind: Kind,
    /// Count of leading `' '` bytes (0 for a blank line with none).
    indent: usize,
    /// Byte offset where this physical line begins (the first indentation
    /// byte, or the content byte if indent is 0).
    line_start: usize,
    /// See the kind-by-kind breakdown in the module doc comment above.
    content: Span,
    /// 1-based, for diagnostics.
    line_no: usize,
};

pub const TokenizeError = error{InvalidIndentChar} || std.mem.Allocator.Error;

str: []const u8,
i: usize = 0,
line_no: usize = 0,
allocator: std.mem.Allocator,
lines: std.ArrayList(Line) = .empty,

pub fn tokenize(self: *Tokenizer) TokenizeError![]Line {
    errdefer self.lines.deinit(self.allocator);

    if (std.mem.startsWith(u8, self.str, "\xEF\xBB\xBF")) self.i = 3; // BOM

    while (self.i < self.str.len) try self.tokenizeLine();

    try self.lines.append(self.allocator, .{
        .kind = .end_of_file,
        .indent = 0,
        .line_start = self.str.len,
        .content = Span.init(self.str.len, self.str.len),
        .line_no = self.line_no + 1,
    });
    return self.lines.toOwnedSlice(self.allocator);
}

fn tokenizeLine(self: *Tokenizer) TokenizeError!void {
    self.line_no += 1;
    const line_start = self.i;

    var j = self.i;
    while (j < self.str.len and self.str[j] == ' ') j += 1;

    var end = j;
    while (end < self.str.len and self.str[end] != '\n' and self.str[end] != '\r') end += 1;

    const indent = j - line_start;

    if (j == end) {
        try self.emit(.blank, indent, line_start, Span.init(end, end));
        self.advanceLine(end);
        return;
    }

    if (self.str[j] == '\t') return error.InvalidIndentChar;
    if (j + 1 < self.str.len and self.str[j] == 0xC2 and self.str[j + 1] == 0xA0) {
        return error.InvalidIndentChar; // U+00A0 NO-BREAK SPACE
    }

    const c = self.str[j];
    if (c == '#') {
        try self.emit(.comment, indent, line_start, Span.init(j + 1, end));
    } else if (c == '-' and (j + 1 == end or self.str[j + 1] == ' ')) {
        try self.emit(.dash, indent, line_start, tagContent(j, end));
    } else if (c == ':' and (j + 1 == end or self.str[j + 1] == ' ')) {
        try self.emit(.colon, indent, line_start, tagContent(j, end));
    } else if (c == '>' and (j + 1 == end or self.str[j + 1] == ' ')) {
        try self.emit(.gt, indent, line_start, tagContent(j, end));
    } else {
        try self.emit(.other, indent, line_start, Span.init(j, end));
    }
    self.advanceLine(end);
}

/// Content span for a one-byte tag at `tag_pos` in a line ending at `end`
/// (exclusive of the line terminator): consumes the tag plus, if present, the
/// one mandatory separating space, leaving whatever (possibly nothing) comes
/// after as the rest-of-line content.
fn tagContent(tag_pos: usize, end: usize) Span {
    const after_tag = tag_pos + 1;
    // If there's at least one more byte before end-of-line, the caller's
    // dispatch condition already guarantees it's the mandatory ' ' — skip it.
    if (after_tag < end) return Span.init(after_tag + 1, end);
    return Span.init(end, end);
}

fn emit(self: *Tokenizer, kind: Kind, indent: usize, line_start: usize, content: Span) TokenizeError!void {
    try self.lines.append(self.allocator, .{
        .kind = kind,
        .indent = indent,
        .line_start = line_start,
        .content = content,
        .line_no = self.line_no,
    });
}

/// Advance past the line terminator (if any) following content-end `end`:
/// `\r\n`, bare `\n`, or bare `\r` are all accepted (lenient — NestedText's
/// own spec assumes `\n`, but there's no conformance case exercising `\r`
/// handling, so this mirrors the common lenient practice elsewhere in fig
/// rather than inventing a new error path).
fn advanceLine(self: *Tokenizer, end: usize) void {
    var k = end;
    if (k < self.str.len and self.str[k] == '\r') k += 1;
    if (k < self.str.len and self.str[k] == '\n') k += 1;
    self.i = k;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn tokenizeAll(input: []const u8) ![]Line {
    var t: Tokenizer = .{ .allocator = testing.allocator, .str = input };
    return t.tokenize();
}

test "classifies dict/list/string tags and blank/comment lines" {
    const src = "key: value\n- item\n> str\n\n# comment\n";
    const lines = try tokenizeAll(src);
    defer testing.allocator.free(lines);
    try testing.expectEqual(Kind.other, lines[0].kind);
    try testing.expectEqualStrings("key: value", src[lines[0].content.start..lines[0].content.end]);
    try testing.expectEqual(Kind.dash, lines[1].kind);
    try testing.expectEqualStrings("item", src[lines[1].content.start..lines[1].content.end]);
    try testing.expectEqual(Kind.gt, lines[2].kind);
    try testing.expectEqualStrings("str", src[lines[2].content.start..lines[2].content.end]);
    try testing.expectEqual(Kind.blank, lines[3].kind);
    try testing.expectEqual(Kind.comment, lines[4].kind);
    try testing.expectEqualStrings(" comment", src[lines[4].content.start..lines[4].content.end]);
}

test "dash/colon/gt tags with and without content" {
    const src = "- a\n-\n: b\n:\n> c\n>\n";
    const lines = try tokenizeAll(src);
    defer testing.allocator.free(lines);
    try testing.expectEqual(Kind.dash, lines[0].kind);
    try testing.expectEqualStrings("a", src[lines[0].content.start..lines[0].content.end]);
    try testing.expectEqual(Kind.dash, lines[1].kind);
    try testing.expectEqual(@as(usize, 0), lines[1].content.len());
    try testing.expectEqual(Kind.colon, lines[2].kind);
    try testing.expectEqualStrings("b", src[lines[2].content.start..lines[2].content.end]);
    try testing.expectEqual(Kind.colon, lines[3].kind);
    try testing.expectEqual(@as(usize, 0), lines[3].content.len());
    try testing.expectEqual(Kind.gt, lines[4].kind);
    try testing.expectEqualStrings("c", src[lines[4].content.start..lines[4].content.end]);
    try testing.expectEqual(Kind.gt, lines[5].kind);
    try testing.expectEqual(@as(usize, 0), lines[5].content.len());
}

test "indentation is counted and tabs are rejected" {
    const lines = try tokenizeAll("  - a\n");
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 2), lines[0].indent);

    try testing.expectError(error.InvalidIndentChar, tokenizeAll("\t> a\n"));
    try testing.expectError(error.InvalidIndentChar, tokenizeAll("  \xC2\xA0 > a\n"));
}

test "other line carries the whole rest-of-line for the parser to scan" {
    const src = "regex: [+-]?[0-9]+\n";
    const lines = try tokenizeAll(src);
    defer testing.allocator.free(lines);
    try testing.expectEqual(Kind.other, lines[0].kind);
    try testing.expectEqualStrings("regex: [+-]?[0-9]+", src[lines[0].content.start..lines[0].content.end]);
}

test "trailing end_of_file token" {
    const lines = try tokenizeAll("a: b\n");
    defer testing.allocator.free(lines);
    try testing.expectEqual(Kind.end_of_file, lines[lines.len - 1].kind);
}
