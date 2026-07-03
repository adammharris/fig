//! TOML tokenizer. Turns a TOML []const u8 into a slice of Tokens.
//!
//! TOML is line-oriented and context-sensitive: the same bytes mean different
//! things before vs after `=` (a bare key `1979-05-27` vs a date value), so the
//! tokenizer tracks a per-line key/value position. Value scalars are emitted as
//! single tokens (`.string` / `.number` / `.datetime` / `.boolean`) spanning
//! their whole source; the parser decodes them, mirroring the JSON tokenizer.
//!
//! Phase 1 scope: root-level `key = value` with scalar values. Table headers
//! (`[...]`/`[[...]]`), arrays, and inline tables emit their bracket/brace
//! tokens but are assembled by the parser in Phases 2–3.

pub const Tokenizer = @This();

const std = @import("std");
const Span = @import("../../util/span.zig");
const Type = @import("toml.zig").Type;
pub const Token = @import("../../token.zig").Token(Kind);

pub const Kind = enum {
    // Structural
    /// =
    equals,
    /// .
    dot,
    /// ,
    comma,
    /// [
    open_bracket,
    /// ]
    close_bracket,
    /// [[
    double_open_bracket,
    /// ]]
    double_close_bracket,
    /// {
    open_brace,
    /// }
    close_brace,
    newline,
    end_of_file,

    // variable-length
    /// bare or quoted key
    key,
    /// string scalar (basic/literal, single or multi-line)
    string,
    /// integer/float scalar (raw, parser validates)
    number,
    /// true/false
    boolean,
    /// RFC 3339-derived date/time scalar
    datetime,
    comment,
    whitespace,

    /// Length of fixed-width token kinds; null for variable-length.
    pub fn len(self: Kind) ?usize {
        return switch (self) {
            .end_of_file => 0,
            .equals, .dot, .comma, .open_bracket, .close_bracket, .open_brace, .close_brace => 1,
            .double_open_bracket, .double_close_bracket => 2,
            else => null,
        };
    }
};

pub const TokenizeError = error{
    UnexpectedCarriageReturn,
    UnclosedString,
    BadKey,
    BadValue,
    BadControlChar,
} || std.mem.Allocator.Error;

/// Control characters forbidden in comments and single-line strings: U+0000–
/// U+0008, U+000A–U+001F, U+007F. Tab (U+0009) is allowed.
fn forbiddenInline(c: u8) bool {
    return (c < 0x20 and c != '\t') or c == 0x7f;
}

/// Same, but for multi-line strings, which additionally permit the newline
/// bytes (U+000A, U+000D).
fn forbiddenMultiline(c: u8) bool {
    return (c < 0x20 and c != '\t' and c != '\n' and c != '\r') or c == 0x7f;
}

tokens: std.ArrayList(Token) = .empty,
str: []const u8,
version: Type = .TOML_1_0,
i: usize = 0,
/// True between `=` and end-of-line at the top level: value position. Reset at
/// every newline (only when not inside a flow collection).
in_value: bool = false,
/// Stack of open `[`/`{` collections. Inside a `{ }` inline table we must know
/// whether we're at a key or a value position so a `.` is read as a key
/// separator vs a decimal point — the line-level `in_value` can't track that.
flow: std.ArrayList(Flow) = .empty,
allocator: std.mem.Allocator,

const Flow = struct {
    /// `{` inline table (vs `[` array).
    table: bool,
    /// (tables only) currently reading a key, not a value.
    expect_key: bool = false,
};

fn inFlow(self: *Tokenizer) bool {
    return self.flow.items.len > 0;
}
fn flowTop(self: *Tokenizer) *Flow {
    return &self.flow.items[self.flow.items.len - 1];
}
/// True when the next token is an inline-table key (bare key / quoted key / dot
/// / `=`), rather than a value.
fn atInlineKey(self: *Tokenizer) bool {
    return self.inFlow() and self.flowTop().table and self.flowTop().expect_key;
}

pub fn tokenize(self: *Tokenizer) TokenizeError![]Token {
    errdefer self.tokens.deinit(self.allocator);
    defer self.flow.deinit(self.allocator);

    // A leading UTF-8 BOM is permitted and ignored.
    if (std.mem.startsWith(u8, self.str, "\xEF\xBB\xBF")) self.i = 3;

    while (self.i < self.str.len) {
        const c = self.str[self.i];
        switch (c) {
            '\n' => {
                try self.emit(.newline, self.i, self.i + 1);
                self.i += 1;
                if (!self.inFlow()) self.in_value = false;
            },
            '\r' => {
                // CR is only valid as part of CRLF.
                if (self.i + 1 < self.str.len and self.str[self.i + 1] == '\n') {
                    try self.emit(.newline, self.i, self.i + 2);
                    self.i += 2;
                    if (!self.inFlow()) self.in_value = false;
                } else return error.UnexpectedCarriageReturn;
            },
            ' ', '\t' => try self.lexWhitespace(),
            '#' => try self.lexComment(),
            else => {
                if (self.in_value or self.inFlow()) {
                    try self.lexValue();
                } else {
                    try self.lexKeyContext();
                }
            },
        }
    }

    try self.emit(.end_of_file, self.str.len, self.str.len);
    return self.tokens.toOwnedSlice(self.allocator);
}

fn emit(self: *Tokenizer, kind: Kind, start: usize, end: usize) TokenizeError!void {
    try self.tokens.append(self.allocator, Token.init(kind, Span.init(start, end)));
}

fn lexWhitespace(self: *Tokenizer) TokenizeError!void {
    const start = self.i;
    while (self.i < self.str.len and (self.str[self.i] == ' ' or self.str[self.i] == '\t')) self.i += 1;
    try self.emit(.whitespace, start, self.i);
}

fn lexComment(self: *Tokenizer) TokenizeError!void {
    const start = self.i;
    while (self.i < self.str.len and self.str[self.i] != '\n' and self.str[self.i] != '\r') {
        if (forbiddenInline(self.str[self.i])) return error.BadControlChar;
        self.i += 1;
    }
    try self.emit(.comment, start, self.i);
}

// ── Key context ─────────────────────────────────────────────────────────────

fn lexKeyContext(self: *Tokenizer) TokenizeError!void {
    const c = self.str[self.i];
    switch (c) {
        '=' => {
            try self.emit(.equals, self.i, self.i + 1);
            self.i += 1;
            self.in_value = true;
        },
        '.' => {
            try self.emit(.dot, self.i, self.i + 1);
            self.i += 1;
        },
        '[' => {
            if (self.i + 1 < self.str.len and self.str[self.i + 1] == '[') {
                try self.emit(.double_open_bracket, self.i, self.i + 2);
                self.i += 2;
            } else {
                try self.emit(.open_bracket, self.i, self.i + 1);
                self.i += 1;
            }
        },
        ']' => {
            if (self.i + 1 < self.str.len and self.str[self.i + 1] == ']') {
                try self.emit(.double_close_bracket, self.i, self.i + 2);
                self.i += 2;
            } else {
                try self.emit(.close_bracket, self.i, self.i + 1);
                self.i += 1;
            }
        },
        '"', '\'' => try self.lexQuotedKey(),
        else => try self.lexBareKey(),
    }
}

fn lexBareKey(self: *Tokenizer) TokenizeError!void {
    const start = self.i;
    while (self.i < self.str.len and isBareKeyChar(self.str[self.i])) self.i += 1;
    if (self.i == start) return error.BadKey; // nothing consumed → stray char
    try self.emit(.key, start, self.i);
}

/// A quoted key is a single-line basic or literal string used as a key.
fn lexQuotedKey(self: *Tokenizer) TokenizeError!void {
    const start = self.i;
    try self.scanSingleLineString(self.str[self.i]);
    try self.emit(.key, start, self.i);
}

// ── Value context ───────────────────────────────────────────────────────────

fn lexValue(self: *Tokenizer) TokenizeError!void {
    const c = self.str[self.i];
    switch (c) {
        '[' => {
            try self.emit(.open_bracket, self.i, self.i + 1);
            self.i += 1;
            try self.flow.append(self.allocator, .{ .table = false });
        },
        ']' => {
            if (self.inFlow()) _ = self.flow.pop();
            try self.emit(.close_bracket, self.i, self.i + 1);
            self.i += 1;
        },
        '{' => {
            try self.emit(.open_brace, self.i, self.i + 1);
            self.i += 1;
            try self.flow.append(self.allocator, .{ .table = true, .expect_key = true });
        },
        '}' => {
            if (self.inFlow()) _ = self.flow.pop();
            try self.emit(.close_brace, self.i, self.i + 1);
            self.i += 1;
        },
        ',' => {
            try self.emit(.comma, self.i, self.i + 1);
            self.i += 1;
            if (self.inFlow() and self.flowTop().table) self.flowTop().expect_key = true;
        },
        '=' => {
            try self.emit(.equals, self.i, self.i + 1);
            self.i += 1;
            if (self.inFlow() and self.flowTop().table) self.flowTop().expect_key = false;
        },
        '.' => {
            try self.emit(.dot, self.i, self.i + 1);
            self.i += 1;
        },
        '"', '\'' => {
            // A quoted key in inline-table key position, else a string value.
            // Both lex identically; the parser interprets by position.
            try self.lexStringValue();
        },
        else => {
            if (self.atInlineKey()) {
                try self.lexBareKey();
                return;
            }
            if (self.matchDatetime(self.i)) |end| {
                try self.emit(.datetime, self.i, end);
                self.i = end;
                return;
            }
            try self.lexBareword();
        },
    }
}

fn lexStringValue(self: *Tokenizer) TokenizeError!void {
    const start = self.i;
    const q = self.str[self.i];
    if (self.i + 2 < self.str.len and self.str[self.i + 1] == q and self.str[self.i + 2] == q) {
        try self.scanMultiLineString(q);
    } else {
        try self.scanSingleLineString(q);
    }
    try self.emit(.string, start, self.i);
}

/// Scan a single-line basic (`"`) or literal (`'`) string, leaving `self.i`
/// just past the closing quote. A newline before the close is an error.
fn scanSingleLineString(self: *Tokenizer, q: u8) TokenizeError!void {
    std.debug.assert(self.str[self.i] == q);
    self.i += 1;
    const basic = q == '"';
    while (self.i < self.str.len) {
        const c = self.str[self.i];
        if (c == '\n' or c == '\r') return error.UnclosedString;
        if (forbiddenInline(c)) return error.BadControlChar;
        if (basic and c == '\\') {
            // Skip the escaped byte (validated by the parser's decoder).
            self.i += 2;
            continue;
        }
        if (c == q) {
            self.i += 1;
            return;
        }
        self.i += 1;
    }
    return error.UnclosedString;
}

/// Scan a multi-line basic (`"""`) or literal (`'''`) string. The opening and
/// closing delimiters are three `q`s; basic strings honor `\` escapes (so an
/// escaped quote doesn't close the string).
fn scanMultiLineString(self: *Tokenizer, q: u8) TokenizeError!void {
    self.i += 3; // opening delimiter
    const basic = q == '"';
    while (self.i < self.str.len) {
        const c = self.str[self.i];
        if (forbiddenMultiline(c)) return error.BadControlChar;
        // A carriage return is only allowed as part of CRLF, even in a
        // multi-line string (a bare CR is a forbidden control char).
        if (c == '\r' and !(self.i + 1 < self.str.len and self.str[self.i + 1] == '\n'))
            return error.BadControlChar;
        if (basic and c == '\\') {
            self.i += 2;
            continue;
        }
        if (c == q and
            self.i + 2 <= self.str.len and
            self.str[self.i + 1] == q and self.str[self.i + 2] == q)
        {
            self.i += 3;
            // TOML allows up to two extra quotes hugging the close (e.g. `""""""`
            // → a string of `""`). Consume up to two trailing quotes.
            var extra: usize = 0;
            while (extra < 2 and self.i < self.str.len and self.str[self.i] == q) : (extra += 1) self.i += 1;
            return;
        }
        self.i += 1;
    }
    return error.UnclosedString;
}

fn isValueTerminator(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or
        c == '#' or c == ',' or c == ']' or c == '}' or
        // `=` ends an inline-table bare key (`{a=1}`); a scalar never contains
        // one, so this is safe in value position too.
        c == '=';
}

pub fn isBareKeyChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or c == '_' or c == '-';
}

/// Scan a non-string scalar bareword (boolean or number) and classify it.
fn lexBareword(self: *Tokenizer) TokenizeError!void {
    const start = self.i;
    while (self.i < self.str.len and !isValueTerminator(self.str[self.i])) self.i += 1;
    const word = self.str[start..self.i];
    if (word.len == 0) return error.BadValue;
    if (std.mem.eql(u8, word, "true") or std.mem.eql(u8, word, "false")) {
        try self.emit(.boolean, start, self.i);
    } else {
        try self.emit(.number, start, self.i);
    }
}

// ── Datetime matching ───────────────────────────────────────────────────────
// Returns the end index of an RFC-3339-derived date/time starting at `at`, or
// null if the bytes there are not a datetime (then the bareword/number lexer
// runs). Only structural shape is checked; range validity (month ≤ 12, etc.) is
// the parser's job.

fn digitsAt(self: *Tokenizer, at: usize, n: usize) bool {
    if (at + n > self.str.len) return false;
    for (self.str[at .. at + n]) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn charAt(self: *Tokenizer, at: usize, c: u8) bool {
    return at < self.str.len and self.str[at] == c;
}

fn matchDatetime(self: *Tokenizer, at: usize) ?usize {
    // Full date: 4DIGIT - 2DIGIT - 2DIGIT
    if (self.digitsAt(at, 4) and self.charAt(at + 4, '-') and
        self.digitsAt(at + 5, 2) and self.charAt(at + 7, '-') and self.digitsAt(at + 8, 2))
    {
        const date_end = at + 10;
        // Time separator: `T`/`t`, or a space *only if* a time follows.
        var sep: ?usize = null;
        if (self.charAt(date_end, 'T') or self.charAt(date_end, 't')) {
            sep = date_end + 1;
        } else if (self.charAt(date_end, ' ') and self.matchTime(date_end + 1) != null) {
            sep = date_end + 1;
        }
        if (sep) |time_start| {
            const time_end = self.matchTime(time_start) orelse return date_end; // date-only fallback
            return self.matchOffset(time_end) orelse time_end;
        }
        return date_end; // local date
    }
    // Local time: 2DIGIT : 2DIGIT : 2DIGIT [.frac]
    if (self.matchTime(at)) |end| return end;
    return null;
}

/// Match HH:MM[:SS[.fraction]]. Seconds are required in TOML 1.0 but optional
/// in 1.1. Returns the end index.
fn matchTime(self: *Tokenizer, at: usize) ?usize {
    if (!(self.digitsAt(at, 2) and self.charAt(at + 2, ':') and self.digitsAt(at + 3, 2)))
        return null; // HH:MM
    var end = at + 5;
    if (self.charAt(end, ':') and self.digitsAt(end + 1, 2)) {
        end += 3; // :SS
        if (self.charAt(end, '.')) {
            var f = end + 1;
            if (!self.digitsAt(f, 1)) return null; // a dot needs ≥1 fractional digit
            while (self.digitsAt(f, 1)) f += 1;
            end = f;
        }
    } else if (self.version == .TOML_1_0) {
        return null; // 1.0 requires seconds
    }
    return end;
}

/// Match a time offset (`Z`/`z` or ±HH:MM) at `at`, or null if none.
fn matchOffset(self: *Tokenizer, at: usize) ?usize {
    if (self.charAt(at, 'Z') or self.charAt(at, 'z')) return at + 1;
    if ((self.charAt(at, '+') or self.charAt(at, '-')) and
        self.digitsAt(at + 1, 2) and self.charAt(at + 3, ':') and self.digitsAt(at + 4, 2))
        return at + 6;
    return null;
}
