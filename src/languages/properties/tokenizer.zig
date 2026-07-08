//! Java `.properties` tokenizer. Turns a `.properties` `[]const u8` into a
//! slice of Tokens.
//!
//! The richest — and most permissive — of fig's three flat key/value formats,
//! matching `java.util.Properties.load`'s actual documented behavior rather
//! than re-skinning INI or dotenv:
//!   * the key/value separator is the FIRST unescaped `=`, `:`, or plain
//!     whitespace — `a=b`, `a:b`, and `a b` are all the same statement. A key
//!     with no separator at all (`flag` alone on a line) is legal: value `""`.
//!   * both key AND value recognize backslash escapes: `\t \n \r \f \\`, a
//!     `\uXXXX` unicode escape, `\` followed by anything else yields that
//!     character literally (`\:`/`\=`/`\#`/`\ ` — the standard way to embed a
//!     separator-looking or leading-whitespace-looking byte), and — the
//!     hallmark feature neither INI nor dotenv has — a `\` immediately before
//!     a line ending is a LINE CONTINUATION: the backslash, the newline, and
//!     the next line's leading whitespace all vanish, joining it onto the
//!     current logical line. Unlike Java's stricter unrecognized-escape
//!     handling in some other contexts, an unrecognized `\c` here is never an
//!     error (matching `Properties.load`) — only a malformed `\uXXXX` is.
//!   * comments start with `#` OR `!` (both accepted, matching real
//!     `.properties` tooling) as the first non-whitespace byte of a physical
//!     line — never continued, unlike a key/value line.
//!   * source is required to be valid UTF-8 (fig's usual policy), with
//!     `\uXXXX` still honored for interop with the classic ISO-8859-1-era
//!     convention — NOT the legacy raw-Latin-1-bytes reading some very old
//!     tooling still defaults to.
//!
//! Escape/continuation scanning (`scanEscaped`) is shared between key and
//! value scanning — the only difference is which bytes terminate a KEY scan
//! (`=`/`:`/whitespace); a value scan never terminates early, running to the
//! true (non-continued) end of the logical line.
pub const Tokenizer = @This();

const std = @import("std");
const Span = @import("../../util/span.zig");
const Type = @import("properties.zig").Type;
pub const Token = @import("../../token.zig").Token(Kind);

pub const Kind = enum {
    newline,
    end_of_file,
    /// escape-aware raw key span (decoded by the parser)
    key,
    /// escape-aware raw value span (decoded by the parser); absent when the
    /// line had no separator, or nothing follows one
    value,
    /// `#`/`!` line comment; span covers the content only (leader excluded)
    comment,

    pub fn len(self: Kind) ?usize {
        return switch (self) {
            .end_of_file => 0,
            else => null,
        };
    }
};

pub const TokenizeError = error{
    UnexpectedCarriageReturn,
    /// A `\` as the very last byte of the file (not part of a `\<newline>`
    /// continuation) — Java's own reader is more lenient here; fig treats it
    /// as a hard error rather than silently guessing what was meant.
    UnclosedEscape,
} || std.mem.Allocator.Error;

tokens: std.ArrayList(Token) = .empty,
str: []const u8,
version: Type = .PROPERTIES,
i: usize = 0,
allocator: std.mem.Allocator,

pub fn tokenize(self: *Tokenizer) TokenizeError![]Token {
    errdefer self.tokens.deinit(self.allocator);

    if (std.mem.startsWith(u8, self.str, "\xEF\xBB\xBF")) self.i = 3; // BOM

    while (self.i < self.str.len) {
        // Leading whitespace on a fresh logical line is insignificant (and a
        // whitespace-only line collapses to the `\n` case below — a "blank
        // line" needs no separate detection).
        while (self.i < self.str.len and isInlineWs(self.str[self.i])) self.i += 1;
        if (self.i >= self.str.len) break;
        switch (self.str[self.i]) {
            '\n' => {
                try self.emit(.newline, self.i, self.i + 1);
                self.i += 1;
            },
            '\r' => {
                if (self.i + 1 < self.str.len and self.str[self.i + 1] == '\n') {
                    try self.emit(.newline, self.i, self.i + 2);
                    self.i += 2;
                } else return error.UnexpectedCarriageReturn;
            },
            '#', '!' => try self.lexComment(),
            else => try self.lexKeyValueLine(),
        }
    }

    try self.emit(.end_of_file, self.str.len, self.str.len);
    return self.tokens.toOwnedSlice(self.allocator);
}

fn emit(self: *Tokenizer, kind: Kind, start: usize, end: usize) TokenizeError!void {
    try self.tokens.append(self.allocator, Token.init(kind, Span.init(start, end)));
}

fn isInlineWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == 0x0c; // space, tab, form feed
}

fn isSeparator(c: u8) bool {
    return c == '=' or c == ':' or isInlineWs(c);
}

fn lexComment(self: *Tokenizer) TokenizeError!void {
    self.i += 1; // leader
    const start = self.i;
    while (self.i < self.str.len and self.str[self.i] != '\n' and self.str[self.i] != '\r') self.i += 1;
    try self.emit(.comment, start, self.i);
}

/// `key<sep>value`. `<sep>`: whitespace*, then optionally ONE `=`/`:`, then
/// whitespace* — any of `a=b`, `a:b`, `a b`, `a = b` are equivalent. No
/// separator at all (scan ran straight to end-of-line) leaves the whole line
/// as the key, with the value absent (empty).
fn lexKeyValueLine(self: *Tokenizer) TokenizeError!void {
    const key_start = self.i;
    try self.scanEscaped(true);
    try self.emit(.key, key_start, self.i);

    while (self.i < self.str.len and isInlineWs(self.str[self.i])) self.i += 1;
    if (self.i < self.str.len and (self.str[self.i] == '=' or self.str[self.i] == ':')) {
        self.i += 1;
        while (self.i < self.str.len and isInlineWs(self.str[self.i])) self.i += 1;
    }
    if (self.i >= self.str.len or self.str[self.i] == '\n' or self.str[self.i] == '\r') return; // no value

    const value_start = self.i;
    try self.scanEscaped(false);
    try self.emit(.value, value_start, self.i);
}

/// Advance `self.i` across an escape-aware run: a backslash always protects
/// the byte after it (never checked against `key_mode`'s terminator set, and
/// never itself a stopping point), EXCEPT a backslash immediately before a
/// line ending, which is a continuation — consumed together with the next
/// line's leading whitespace, transparently extending the scan onto it. Stops
/// (without consuming) at the first unescaped byte `isSeparator` accepts when
/// `key_mode`, or at the true end of the logical line/file otherwise.
fn scanEscaped(self: *Tokenizer, key_mode: bool) TokenizeError!void {
    while (self.i < self.str.len) {
        const c = self.str[self.i];
        if (c == '\n' or c == '\r') return;
        if (c == '\\') {
            if (self.i + 1 < self.str.len and self.str[self.i + 1] == '\n') {
                self.i += 2;
                self.skipContinuationWs();
                continue;
            }
            if (self.i + 2 < self.str.len and self.str[self.i + 1] == '\r' and self.str[self.i + 2] == '\n') {
                self.i += 3;
                self.skipContinuationWs();
                continue;
            }
            if (self.i + 1 >= self.str.len) return error.UnclosedEscape;
            self.i += 2; // backslash + escaped byte, protected as one unit
            continue;
        }
        if (key_mode and isSeparator(c)) return;
        self.i += 1;
    }
}

fn skipContinuationWs(self: *Tokenizer) void {
    while (self.i < self.str.len and (self.str[self.i] == ' ' or self.str[self.i] == '\t')) self.i += 1;
}
