//! dotenv (.env) tokenizer. Turns a dotenv `[]const u8` into a slice of Tokens.
//!
//! Like INI, line-oriented and context-sensitive (`in_value`, reset at every
//! newline) — but a deliberately DIFFERENT dialect from INI, not a re-skin of
//! it, in every place real `.env` tooling (the JS/Ruby/Python `dotenv`
//! packages, which have mostly converged on one convention) actually differs:
//!   * keys are strict bash identifiers (`[A-Za-z_][A-Za-z0-9_]*`) — a `.env`
//!     is meant to become shell/process environment variables, unlike INI's
//!     free-form keys;
//!   * an optional `export ` prefix (bash-export style) is accepted and
//!     discarded — handled by the PARSER as "the last key-shaped token before
//!     `=` wins, iff the one before it is literally `export`", not here;
//!   * `"..."`/`'...'` quoting is real: double-quoted values decode `\n \t \r
//!     \\ \"` escapes AND may embed a literal newline (span multiple physical
//!     lines); single-quoted values are fully raw (no escapes at all, not even
//!     `\\` — same as a shell) but may ALSO embed a literal newline. Neither
//!     exists in INI.
//!   * comments: a full-line `#` (first non-whitespace on the line) always
//!     starts one, matching INI; but so does a `#` that trails an UNQUOTED
//!     value when at least one whitespace character precedes it (`FOO=bar
//!     #note` → value `bar`), or one that follows a closing quote at all
//!     (whitespace before it is optional there — the quote is already an
//!     unambiguous terminator). A `#` with NO preceding whitespace inside an
//!     unquoted value is literal (`FOO=#bar` → value `#bar`) — this exact
//!     whitespace-gated rule is what real dotenv parsers do, and it's the one
//!     place dotenv recognizes a trailing comment at all where INI never does.
//!
//! `MissingEquals` — unlike INI's tokenizer, where it's tokenizer-level and so
//! not recoverable — is a PARSER error here (see `parser.zig`): key-scanning is
//! just "an identifier run," so the tokenizer never needs to look ahead for
//! `=` itself, which makes a missing `=` recoverable under `parseCollecting`
//! the same way `DuplicateKey` is.
pub const Tokenizer = @This();

const std = @import("std");
const Span = @import("../../util/span.zig");
const Type = @import("dotenv.zig").Type;
pub const Token = @import("../../token.zig").Token(Kind);

pub const Kind = enum {
    /// =
    equals,
    newline,
    end_of_file,

    // variable-length
    /// `[A-Za-z_][A-Za-z0-9_]*`
    key,
    /// `"..."`, span includes both quotes
    double_quoted,
    /// `'...'`, span includes both quotes
    single_quoted,
    /// raw, trimmed value text with no quoting
    unquoted,
    /// `#`/trailing comment; span covers the content only (leader excluded)
    comment,

    pub fn len(self: Kind) ?usize {
        return switch (self) {
            .end_of_file => 0,
            .equals => 1,
            else => null,
        };
    }
};

pub const TokenizeError = error{
    UnexpectedCarriageReturn,
    UnclosedString,
    UnexpectedChar,
    TrailingContent,
} || std.mem.Allocator.Error;

tokens: std.ArrayList(Token) = .empty,
str: []const u8,
version: Type = .DOTENV,
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
            else => if (self.in_value) try self.lexValueContext() else try self.lexKeyContext(),
        }
    }

    try self.emit(.end_of_file, self.str.len, self.str.len);
    return self.tokens.toOwnedSlice(self.allocator);
}

fn emit(self: *Tokenizer, kind: Kind, start: usize, end: usize) TokenizeError!void {
    try self.tokens.append(self.allocator, Token.init(kind, Span.init(start, end)));
}

fn isIdentStart(c: u8) bool {
    return c == '_' or std.ascii.isAlphabetic(c);
}
fn isIdentChar(c: u8) bool {
    return c == '_' or std.ascii.isAlphanumeric(c);
}

// ── Key context ──────────────────────────────────────────────────────────────

fn lexKeyContext(self: *Tokenizer) TokenizeError!void {
    switch (self.str[self.i]) {
        '#' => try self.lexComment(),
        '=' => {
            try self.emit(.equals, self.i, self.i + 1);
            self.i += 1;
            self.in_value = true;
        },
        else => |c| if (isIdentStart(c)) try self.lexKey() else return error.UnexpectedChar,
    }
}

fn lexKey(self: *Tokenizer) TokenizeError!void {
    const start = self.i;
    self.i += 1; // isIdentStart already checked
    while (self.i < self.str.len and isIdentChar(self.str[self.i])) self.i += 1;
    try self.emit(.key, start, self.i);
}

/// Full-line comment (only reachable at the start of a logical line, in key
/// context). Content only — leader excluded — like INI's.
fn lexComment(self: *Tokenizer) TokenizeError!void {
    self.i += 1; // '#'
    const start = self.i;
    while (!self.atLineEnd(self.i)) self.i += 1;
    try self.emit(.comment, start, self.i);
}

fn atLineEnd(self: *Tokenizer, at: usize) bool {
    return at >= self.str.len or self.str[at] == '\n' or self.str[at] == '\r';
}

// ── Value context ────────────────────────────────────────────────────────────

fn lexValueContext(self: *Tokenizer) TokenizeError!void {
    switch (self.str[self.i]) {
        '"' => {
            try self.lexQuoted('"', .double_quoted);
            try self.afterQuotedValue();
        },
        '\'' => {
            try self.lexQuoted('\'', .single_quoted);
            try self.afterQuotedValue();
        },
        else => try self.lexUnquoted(),
    }
}

/// Scan a `"`/`'`-delimited value, which may embed a literal newline (a bare
/// `\r` is still only valid as part of `\r\n`, checked the same as the
/// top-level scanner). Double-quoted honors `\`-escapes structurally (skips
/// the escaped byte so `\"` doesn't close early); single-quoted has none — a
/// `\` is just a literal byte, matching a shell's single-quote semantics
/// (so it also can never contain a `'`).
fn lexQuoted(self: *Tokenizer, q: u8, kind: Kind) TokenizeError!void {
    const start = self.i;
    self.i += 1; // opening quote
    const escapes = q == '"';
    while (self.i < self.str.len) {
        const c = self.str[self.i];
        if (c == '\r') {
            if (self.i + 1 < self.str.len and self.str[self.i + 1] == '\n') {
                self.i += 2;
                continue;
            }
            return error.UnexpectedCarriageReturn;
        }
        if (escapes and c == '\\') {
            if (self.i + 1 >= self.str.len) return error.UnclosedString;
            self.i += 2;
            continue;
        }
        if (c == q) {
            self.i += 1;
            try self.emit(kind, start, self.i);
            return;
        }
        self.i += 1;
    }
    return error.UnclosedString;
}

/// After a closing quote: optional whitespace, then a `#` comment or the
/// line end — anything else is `TrailingContent` (mirrors INI's rule after a
/// `[section]` header). Unlike an unquoted value's comment (see the module
/// doc), no preceding whitespace is required here — the quote itself is
/// already an unambiguous terminator.
fn afterQuotedValue(self: *Tokenizer) TokenizeError!void {
    while (self.i < self.str.len and (self.str[self.i] == ' ' or self.str[self.i] == '\t')) self.i += 1;
    if (self.i < self.str.len and self.str[self.i] == '#') {
        try self.lexComment();
        return;
    }
    if (!self.atLineEnd(self.i)) return error.TrailingContent;
}

/// Raw value text with no quoting: runs to end of line, UNLESS a `#` preceded
/// by whitespace starts a trailing comment (see the module doc) — that
/// comment is lexed immediately here so the outer loop doesn't re-enter value
/// context on it. Trimmed of surrounding whitespace.
fn lexUnquoted(self: *Tokenizer) TokenizeError!void {
    const start = self.i;
    var end = start;
    // Whitespace between `=` and the value's first byte was already consumed
    // (silently) by the top-level loop before dispatching here, so a `#`
    // sitting right at `start` needs this to know whitespace preceded it too
    // (`FOO=   #note` is a comment; `FOO=#note` is the literal value `#note`).
    var saw_space = self.i > 0 and (self.str[self.i - 1] == ' ' or self.str[self.i - 1] == '\t');
    while (self.i < self.str.len) {
        const c = self.str[self.i];
        if (c == '\n' or c == '\r') break;
        if (c == '#' and saw_space) break;
        saw_space = (c == ' ' or c == '\t');
        self.i += 1;
        end = self.i;
    }
    try self.emit(.unquoted, trimStart(self.str, start), trimEnd(self.str, start, end));
    if (self.i < self.str.len and self.str[self.i] == '#') try self.lexComment();
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
