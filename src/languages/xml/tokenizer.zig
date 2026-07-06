//! XML tokenizer. Turns an XML `[]const u8` into a slice of `Token`s.
//!
//! XML is mode-dependent: the same byte means different things in *content*
//! (between tags) versus inside a *tag* (between `<name` and `>`). A space is
//! literal text in content but an attribute separator in a tag; a name is only a
//! name inside a tag. The scanner tracks this with `in_tag`.
//!
//! Constructs with no place in the config-oriented data model are consumed and
//! discarded here, so the parser's grammar stays clean:
//!   * comments `<!-- … -->`, processing instructions / the `<?xml … ?>`
//!     declaration `<? … ?>`, and a `<!DOCTYPE … >` are skipped (emit nothing);
//!   * an internal DTD subset (`<!DOCTYPE … [ … ]>`) is rejected
//!     (`UnsupportedDoctype`) — entity declarations are out of scope for v1.
//! CDATA is preserved as a `cdata` token (its contents are literal text).
//!
//! Entity references (`&amp;`, `&#10;`) inside `char_data`/`attr_value` are left
//! intact in the token span; the parser decodes them.

const Tokenizer = @This();

const std = @import("std");
const Span = @import("../../util/span.zig");
pub const Token = @import("../../token.zig").Token(Kind);

pub const Kind = enum {
    /// `<` opening an element start-tag (span is just the `<`).
    lt,
    /// `</` opening an element end-tag.
    lt_slash,
    /// `>` closing a tag.
    gt,
    /// `/>` closing an empty-element tag.
    slash_gt,
    /// `=` between an attribute name and its value.
    eq,
    /// An element or attribute name.
    name,
    /// A quoted attribute value; span covers the bytes *inside* the quotes.
    attr_value,
    /// A run of character data between tags; span is the raw bytes.
    char_data,
    /// The contents of a `<![CDATA[ … ]]>` section (literal text, no entities).
    cdata,
    /// End of input.
    eof,

    /// Length of fixed-width token kinds; null for variable-length.
    pub fn len(self: Kind) ?usize {
        return switch (self) {
            .eof => 0,
            .lt, .gt, .eq => 1,
            .lt_slash, .slash_gt => 2,
            else => null,
        };
    }
};

pub const TokenizeError = error{
    /// A start/end tag that never closed before end of input.
    UnclosedTag,
    /// An attribute value with no closing quote.
    UnclosedAttributeValue,
    /// A `<!--` with no `-->`.
    UnclosedComment,
    /// A `<![CDATA[` with no `]]>`.
    UnclosedCData,
    /// A `<?` with no `?>`.
    UnclosedPI,
    /// A DOCTYPE with an internal subset `[ … ]` (entity declarations etc.).
    UnsupportedDoctype,
    /// Markup that isn't well-formed (`<` not followed by a name/`/`/`!`/`?`,
    /// a stray `<!`, a literal `<` inside an attribute value, …).
    InvalidMarkup,
    /// A byte that may not appear where it does inside a tag.
    UnexpectedCharacter,
} || std.mem.Allocator.Error;

allocator: std.mem.Allocator,
str: []const u8,
pos: usize = 0,
/// True while scanning the interior of a start/end tag (after `<name`/`</`,
/// before the closing `>`/`/>`), where whitespace separates attributes rather
/// than forming text.
in_tag: bool = false,
tokens: std.ArrayList(Token) = .empty,

pub fn tokenize(self: *Tokenizer) TokenizeError![]const Token {
    errdefer self.tokens.deinit(self.allocator);
    while (!self.atEnd()) {
        if (self.in_tag) try self.lexInTag() else try self.lexContent();
    }
    if (self.in_tag) return error.UnclosedTag;
    try self.emit(.eof, self.pos, self.pos);
    return self.tokens.toOwnedSlice(self.allocator);
}

// ── content mode ────────────────────────────────────────────────────────────

fn lexContent(self: *Tokenizer) TokenizeError!void {
    if (self.peek() == '<') return self.lexLeftAngle();
    // A run of character data up to the next `<`.
    const start = self.pos;
    while (!self.atEnd() and self.peek() != '<') : (self.pos += 1) {}
    try self.emit(.char_data, start, self.pos);
}

/// At a `<` in content mode: dispatch on what follows.
fn lexLeftAngle(self: *Tokenizer) TokenizeError!void {
    const start = self.pos;
    if (self.startsWith("<!--")) return self.skipComment();
    if (self.startsWith("<![CDATA[")) return self.lexCData();
    if (self.startsWith("<!DOCTYPE")) return self.skipDoctype();
    if (self.startsWith("<!")) return error.InvalidMarkup; // stray DTD-style declaration
    if (self.startsWith("<?")) return self.skipPI();
    if (self.startsWith("</")) {
        self.pos += 2;
        try self.emit(.lt_slash, start, self.pos);
        self.in_tag = true;
        return;
    }
    // `<` + name-start ⇒ an element start-tag.
    if (self.pos + 1 < self.str.len and isNameStart(self.str[self.pos + 1])) {
        self.pos += 1;
        try self.emit(.lt, start, self.pos);
        self.in_tag = true;
        return;
    }
    return error.InvalidMarkup;
}

fn lexCData(self: *Tokenizer) TokenizeError!void {
    self.pos += "<![CDATA[".len;
    const start = self.pos;
    const idx = std.mem.indexOf(u8, self.str[self.pos..], "]]>") orelse return error.UnclosedCData;
    self.pos += idx;
    try self.emit(.cdata, start, self.pos);
    self.pos += "]]>".len;
}

fn skipComment(self: *Tokenizer) TokenizeError!void {
    self.pos += "<!--".len;
    const idx = std.mem.indexOf(u8, self.str[self.pos..], "-->") orelse return error.UnclosedComment;
    self.pos += idx + "-->".len;
}

fn skipPI(self: *Tokenizer) TokenizeError!void {
    self.pos += "<?".len;
    const idx = std.mem.indexOf(u8, self.str[self.pos..], "?>") orelse return error.UnclosedPI;
    self.pos += idx + "?>".len;
}

fn skipDoctype(self: *Tokenizer) TokenizeError!void {
    self.pos += "<!DOCTYPE".len;
    while (!self.atEnd()) : (self.pos += 1) {
        switch (self.peek()) {
            '[' => return error.UnsupportedDoctype, // internal subset
            '>' => {
                self.pos += 1;
                return;
            },
            else => {},
        }
    }
    return error.UnclosedTag; // unterminated DOCTYPE
}

// ── tag mode ─────────────────────────────────────────────────────────────────

fn lexInTag(self: *Tokenizer) TokenizeError!void {
    self.skipSpace();
    if (self.atEnd()) return error.UnclosedTag;
    const c = self.peek();
    switch (c) {
        '>' => {
            try self.emit(.gt, self.pos, self.pos + 1);
            self.pos += 1;
            self.in_tag = false;
        },
        '/' => {
            if (!self.startsWith("/>")) return error.UnclosedTag;
            try self.emit(.slash_gt, self.pos, self.pos + 2);
            self.pos += 2;
            self.in_tag = false;
        },
        '=' => {
            try self.emit(.eq, self.pos, self.pos + 1);
            self.pos += 1;
        },
        '"', '\'' => try self.lexAttrValue(c),
        else => {
            if (!isNameStart(c)) return error.UnexpectedCharacter;
            try self.lexName();
        },
    }
}

fn lexName(self: *Tokenizer) TokenizeError!void {
    const start = self.pos;
    self.pos += 1; // first char is a known name-start
    while (!self.atEnd() and isNameChar(self.peek())) : (self.pos += 1) {}
    try self.emit(.name, start, self.pos);
}

fn lexAttrValue(self: *Tokenizer, quote: u8) TokenizeError!void {
    self.pos += 1; // opening quote
    const start = self.pos;
    while (!self.atEnd() and self.peek() != quote) : (self.pos += 1) {
        if (self.peek() == '<') return error.InvalidMarkup; // `<` is illegal in an attribute value
    }
    if (self.atEnd()) return error.UnclosedAttributeValue;
    try self.emit(.attr_value, start, self.pos); // span excludes the quotes
    self.pos += 1; // closing quote
}

// ── helpers ──────────────────────────────────────────────────────────────────

fn atEnd(self: *const Tokenizer) bool {
    return self.pos >= self.str.len;
}

fn peek(self: *const Tokenizer) u8 {
    return self.str[self.pos];
}

fn startsWith(self: *const Tokenizer, prefix: []const u8) bool {
    return std.mem.startsWith(u8, self.str[self.pos..], prefix);
}

fn skipSpace(self: *Tokenizer) void {
    while (!self.atEnd() and isSpace(self.peek())) : (self.pos += 1) {}
}

fn emit(self: *Tokenizer, kind: Kind, start: usize, end: usize) TokenizeError!void {
    try self.tokens.append(self.allocator, Token.init(kind, Span.init(start, end)));
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// XML NameStartChar, ASCII subset plus any high byte (so UTF-8 names pass
/// through without strict Unicode-class validation — deferred). `pub`: the
/// printer (`printer.zig`) reuses this exact grammar to validate a mapping key
/// before emitting it as an element/attribute name, so the reader's and
/// writer's notion of "valid Name" can never drift apart.
pub fn isNameStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_' or c == ':' or c >= 0x80;
}

pub fn isNameChar(c: u8) bool {
    return isNameStart(c) or (c >= '0' and c <= '9') or c == '-' or c == '.';
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Tokenize `src` and return just the kind sequence (for terse assertions).
fn kindsOf(src: []const u8) ![]Kind {
    var t = Tokenizer{ .allocator = testing.allocator, .str = src };
    const toks = try t.tokenize();
    defer testing.allocator.free(toks);
    const kinds = try testing.allocator.alloc(Kind, toks.len);
    for (toks, 0..) |tok, i| kinds[i] = tok.kind;
    return kinds;
}

fn expectKinds(src: []const u8, expected: []const Kind) !void {
    const kinds = try kindsOf(src);
    defer testing.allocator.free(kinds);
    try testing.expectEqualSlices(Kind, expected, kinds);
}

test "empty element" {
    try expectKinds("<a/>", &.{ .lt, .name, .slash_gt, .eof });
}

test "element with text" {
    try expectKinds("<a>hi</a>", &.{ .lt, .name, .gt, .char_data, .lt_slash, .name, .gt, .eof });
}

test "attributes, both quote styles" {
    try expectKinds(
        \\<a x="1" y='2'>
    , &.{ .lt, .name, .name, .eq, .attr_value, .name, .eq, .attr_value, .gt, .eof });
}

test "attr_value span excludes quotes" {
    var t = Tokenizer{ .allocator = testing.allocator, .str =
        \\<a x="hello">
    };
    const toks = try t.tokenize();
    defer testing.allocator.free(toks);
    // toks: lt, name(a), name(x), eq, attr_value(hello), gt, eof
    try testing.expectEqual(Kind.attr_value, toks[4].kind);
    try testing.expectEqualStrings("hello", toks[4].source(t.str));
}

test "comment is skipped" {
    try expectKinds("<a><!--c--></a>", &.{ .lt, .name, .gt, .lt_slash, .name, .gt, .eof });
}

test "processing instruction / declaration skipped" {
    try expectKinds(
        \\<?xml version="1.0"?><a/>
    , &.{ .lt, .name, .slash_gt, .eof });
}

test "doctype skipped" {
    try expectKinds("<!DOCTYPE a><a/>", &.{ .lt, .name, .slash_gt, .eof });
}

test "cdata preserved as one token, may contain <" {
    var t = Tokenizer{ .allocator = testing.allocator, .str = "<a><![CDATA[x<y]]></a>" };
    const toks = try t.tokenize();
    defer testing.allocator.free(toks);
    try testing.expectEqual(Kind.cdata, toks[3].kind);
    try testing.expectEqualStrings("x<y", toks[3].source(t.str));
}

test "entity left intact in char_data" {
    var t = Tokenizer{ .allocator = testing.allocator, .str = "<a>x&amp;y</a>" };
    const toks = try t.tokenize();
    defer testing.allocator.free(toks);
    try testing.expectEqualStrings("x&amp;y", toks[3].source(t.str));
}

test "errors" {
    try testing.expectError(error.UnsupportedDoctype, kindsOf("<!DOCTYPE a [ <!ENTITY x \"y\"> ]><a/>"));
    try testing.expectError(error.UnclosedComment, kindsOf("<a><!--unterminated"));
    try testing.expectError(error.UnclosedCData, kindsOf("<a><![CDATA[oops"));
    try testing.expectError(error.UnclosedPI, kindsOf("<?pi never"));
    try testing.expectError(error.UnclosedAttributeValue, kindsOf("<a x=\"oops"));
    try testing.expectError(error.UnclosedTag, kindsOf("<a"));
    try testing.expectError(error.InvalidMarkup, kindsOf("< a/>"));
    try testing.expectError(error.InvalidMarkup, kindsOf("<a b=\"<\"/>"));
}
