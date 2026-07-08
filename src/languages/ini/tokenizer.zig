//! INI tokenizer. Turns an INI `[]const u8` into a slice of Tokens.
//!
//! INI is line-oriented and, like TOML, context-sensitive: the same byte means
//! different things before vs. after `=` on a line (`in_value`), reset at
//! every newline — no flow-nesting stack is needed (INI has no arrays/inline
//! tables to nest into).
//!
//! Deliberately narrow scope vs. the many incompatible things "INI" means in
//! the wild: `=` is the only separator (`.properties`'s `:`/bare-whitespace
//! forms live in that format instead — see `languages/properties/`), `;` and
//! `#` both start comments, and — the one rule that most affects real-world
//! files — **a comment must be the first non-whitespace content on its line**.
//! There is no same-line trailing `# ...` after a value: many real INI files
//! legitimately contain `;`/`#` inside an unquoted value (`path=C:\a;b`), so
//! treating those as unterminated comments would corrupt them. A value is
//! simply "the rest of the line, trimmed."
pub const Tokenizer = @This();

const std = @import("std");
const Span = @import("../../util/span.zig");
const Type = @import("ini.zig").Type;
pub const Token = @import("../../token.zig").Token(Kind);

pub const Kind = enum {
    /// [
    open_bracket,
    /// ]
    close_bracket,
    /// =
    equals,
    newline,
    end_of_file,

    // variable-length
    /// A bare run of text: a section name, a key, or (in value position) the
    /// rest of the line. Interpretation is entirely positional — the parser
    /// decides which of the three this is from where it appears.
    text,
    /// `;`/`#` line comment; span covers the content only (leader excluded).
    comment,

    pub fn len(self: Kind) ?usize {
        return switch (self) {
            .end_of_file => 0,
            .open_bracket, .close_bracket, .equals => 1,
            else => null,
        };
    }
};

pub const TokenizeError = error{
    UnexpectedCarriageReturn,
    UnclosedSection,
    MissingEquals,
    TrailingContent,
} || std.mem.Allocator.Error;

tokens: std.ArrayList(Token) = .empty,
str: []const u8,
version: Type = .INI,
i: usize = 0,
/// True between `=` and end-of-line: value position. Reset at every newline.
in_value: bool = false,
allocator: std.mem.Allocator,

pub fn tokenize(self: *Tokenizer) TokenizeError![]Token {
    errdefer self.tokens.deinit(self.allocator);

    if (std.mem.startsWith(u8, self.str, "\xEF\xBB\xBF")) self.i = 3; // BOM

    while (self.i < self.str.len) {
        const c = self.str[self.i];
        switch (c) {
            '\n' => {
                try self.emit(.newline, self.i, self.i + 1);
                self.i += 1;
                self.in_value = false;
            },
            '\r' => {
                if (self.i + 1 < self.str.len and self.str[self.i + 1] == '\n') {
                    try self.emit(.newline, self.i, self.i + 2);
                    self.i += 2;
                    self.in_value = false;
                } else return error.UnexpectedCarriageReturn;
            },
            ' ', '\t' => self.i += 1, // insignificant; never tokenized
            else => if (self.in_value) try self.lexValueText() else try self.lexKeyContext(),
        }
    }

    try self.emit(.end_of_file, self.str.len, self.str.len);
    return self.tokens.toOwnedSlice(self.allocator);
}

fn emit(self: *Tokenizer, kind: Kind, start: usize, end: usize) TokenizeError!void {
    try self.tokens.append(self.allocator, Token.init(kind, Span.init(start, end)));
}

fn atLineEnd(self: *Tokenizer, at: usize) bool {
    return at >= self.str.len or self.str[at] == '\n' or self.str[at] == '\r';
}

// ── Key-context line start ──────────────────────────────────────────────────

fn lexKeyContext(self: *Tokenizer) TokenizeError!void {
    switch (self.str[self.i]) {
        ';', '#' => try self.lexComment(),
        '[' => try self.lexSectionHeader(),
        else => try self.lexKey(),
    }
}

fn lexComment(self: *Tokenizer) TokenizeError!void {
    self.i += 1; // leader
    const start = self.i;
    while (!self.atLineEnd(self.i)) self.i += 1;
    try self.emit(.comment, start, self.i);
}

/// `[name]` — name runs to the next `]` (not itself a line boundary); nothing
/// but whitespace may follow before the newline/EOF.
fn lexSectionHeader(self: *Tokenizer) TokenizeError!void {
    try self.emit(.open_bracket, self.i, self.i + 1);
    self.i += 1;
    const start = self.i;
    while (self.i < self.str.len and self.str[self.i] != ']') {
        if (self.str[self.i] == '\n' or self.str[self.i] == '\r') return error.UnclosedSection;
        self.i += 1;
    }
    if (self.i >= self.str.len) return error.UnclosedSection;
    try self.emit(.text, trimStart(self.str, start), trimEnd(self.str, start, self.i));
    try self.emit(.close_bracket, self.i, self.i + 1);
    self.i += 1;
    // Only whitespace may trail a header on its own line.
    while (self.i < self.str.len and (self.str[self.i] == ' ' or self.str[self.i] == '\t')) self.i += 1;
    if (!self.atLineEnd(self.i)) return error.TrailingContent;
}

/// A key runs to `=` (required) or the line end (an error: `MissingEquals`).
fn lexKey(self: *Tokenizer) TokenizeError!void {
    const start = self.i;
    while (self.i < self.str.len and self.str[self.i] != '=' and self.str[self.i] != '\n' and self.str[self.i] != '\r') {
        self.i += 1;
    }
    if (self.i >= self.str.len or self.str[self.i] != '=') return error.MissingEquals;
    try self.emit(.text, trimStart(self.str, start), trimEnd(self.str, start, self.i));
    try self.emit(.equals, self.i, self.i + 1);
    self.i += 1;
    self.in_value = true;
}

// ── Value context ────────────────────────────────────────────────────────────

/// Everything to end-of-line is the value, trimmed of surrounding whitespace.
/// No escaping, no comment recognition — see the module doc comment.
fn lexValueText(self: *Tokenizer) TokenizeError!void {
    const start = self.i;
    while (!self.atLineEnd(self.i)) self.i += 1;
    try self.emit(.text, trimStart(self.str, start), trimEnd(self.str, start, self.i));
}

fn trimStart(str: []const u8, start: usize) usize {
    var s = start;
    while (s < str.len and (str[s] == ' ' or str[s] == '\t')) s += 1;
    return s;
}

fn trimEnd(str: []const u8, start: usize, end: usize) usize {
    var e = end;
    while (e > start and (str[e - 1] == ' ' or str[e - 1] == '\t')) e -= 1;
    return e;
}
