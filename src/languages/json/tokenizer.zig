//! JSON Tokenizer. Turns a []const u8 in JSON format to a slice of Tokens.
//!
//! Allocates (then frees) memory for an expanding ArrayList of tokens.

pub const Tokenizer = @This();

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.tokenizer);
const testing = std.testing;
const JsonFormat = @import("json.zig").Type;
const Span = @import("../../util/span.zig");
const ascii = @import("../../util/util.zig").ascii;
pub const Token = @import("../../token.zig").Token(Kind);

pub const Kind = enum {
    // Structural
    /// {
    open_brace,
    /// }
    close_brace,
    /// [
    open_bracket,
    /// ]
    close_bracket,

    colon,
    comma,
    end_of_file,

    // Literals
    true_,
    false_,
    null_,

    // variable-length
    string,
    number,
    comment,
    whitespace,
    /// JSON5 only: an unquoted ECMAScript IdentifierName. Used as an object key,
    /// or as a value when it spells `Infinity` / `NaN`.
    identifier,

    /// Find length of token kind. Returns null for variable-length tokens.
    pub fn len(self: Kind) ?usize {
        return switch (self) {
            .end_of_file => 0,
            .open_brace, .close_brace, .open_bracket, .close_bracket, .colon, .comma => 1,
            .true_, .null_ => 4,
            .false_ => 5,
            else => null,
        };
    }
};

/// `pub` so the parser can fold it into its own unified `Error` set (see
/// `parser.zig`'s `Error`) — a tokenizer failure surfaces before the parser's
/// token loop even starts, so it needs its own describable code there too.
pub const TokenizeError = error{ UnexpectedToken, MissingToken, OutOfMemory, UnexpectedSlash, MissingCloseBrace, MissingOpenQuote, MissingColon, MissingCloseBracket, LeadingZero, UnclosedString, UnexpectedEndOfInput, UnclosedComment };

// State
tokens: std.ArrayList(Token) = .empty,
index: usize = 0,

// Initial fields
allocator: std.mem.Allocator,
str: []const u8 = "",
kind: JsonFormat = JsonFormat.JSONC,

pub fn tokenize(self: *Tokenizer) ![]const Token {
    errdefer self.tokens.deinit(self.allocator);
    try self.tokens.ensureTotalCapacity(self.allocator, self.str.len + 1);

    if (std.mem.startsWith(u8, self.str, "\xEF\xBB\xBF")) {
        self.index = 3;
    }

    const json5 = self.kind == JsonFormat.JSON5;
    while (self.char()) |c| {
        // JSON5 widens the alphabet: unquoted identifier keys (and the bare
        // `Infinity`/`NaN` values), single-quoted strings, a leading `+` or `.`
        // on numbers, and the extra ES whitespace (vertical tab, form feed).
        if (json5) {
            if (isIdentStart(c)) {
                try self.addToken(try self.identifierOrKeyword());
                continue;
            }
            switch (c) {
                '\'' => {
                    try self.addToken(try self.string('\''));
                    continue;
                },
                '+', '.' => {
                    try self.addToken(try self.number());
                    continue;
                },
                0x0b, 0x0c => {
                    try self.addToken(try self.getWhitespace());
                    continue;
                },
                else => {},
            }
        }
        try self.addToken(switch (c) {
            '{' => .init(.open_brace, .init(self.index, self.index + 1)),
            '}' => .init(.close_brace, .init(self.index, self.index + 1)),
            '[' => .init(.open_bracket, .init(self.index, self.index + 1)),
            ']' => .init(.close_bracket, .init(self.index, self.index + 1)),
            ':' => .init(.colon, .init(self.index, self.index + 1)),
            ',' => .init(.comma, .init(self.index, self.index + 1)),
            't' => try self.findLiteral(.true_),
            'f' => try self.findLiteral(.false_),
            'n' => try self.findLiteral(.null_),
            '"' => try self.string('"'),
            '/' => try self.comment(),
            '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '-' => try self.number(),
            ' ', '\t', '\n', '\r' => try self.getWhitespace(),
            else => return TokenizeError.UnexpectedToken,
        });
    }

    try self.addToken(.fixed(.end_of_file, self.index));
    return try self.tokens.toOwnedSlice(self.allocator);
}

fn findLiteral(self: *const Tokenizer, kind: Token.Kind) TokenizeError!Token {
    switch (kind) {
        .null_ => {
            if (self.matches("null")) return .fixed(.null_, self.index);
        },
        .true_ => {
            if (self.matches("true")) return .fixed(.true_, self.index);
        },
        .false_ => {
            if (self.matches("false")) return .fixed(.false_, self.index);
        },
        else => return error.UnexpectedToken,
    }
    return TokenizeError.UnexpectedToken;
}

/// Collects all whitespace and returns it as a token.
/// Can return null. `addToken` checks for null.
fn getWhitespace(self: *Tokenizer) TokenizeError!Token {
    const start = self.index;
    while (self.char()) |c| {
        if (!std.ascii.isWhitespace(c)) break;
        self.index += 1;
    }
    const end = self.index;
    if (start == end) unreachable;
    return .init(.whitespace, .init(start, end));
}

// =====================
// CONVENIENCE FUNCTIONS
// =====================

/// Convenience function for accessing current character
fn char(self: *const Tokenizer) ?u8 {
    if (self.index >= self.str.len) return null;
    return self.str[self.index];
}

/// Convenience function for adding a token to the tokens array
fn addToken(self: *Tokenizer, token: Token) TokenizeError!void {
    try self.tokens.append(self.allocator, token);
    self.index = token.span.end;
}

/// Checks if the index is on a given sequence of characters.
fn matches(self: *const Tokenizer, str: []const u8) bool {
    if (str.len > self.str.len - self.index) return false;
    var local_index = self.index;
    for (str) |c| {
        if (self.str[local_index] != c) return false;
        local_index += 1;
    }
    return true;
}

const isDigit = ascii.isDigit;

/// ASCII subset of an ECMAScript IdentifierStart (`$`, `_`, letters). Unicode and
/// `\u` escapes in identifiers are out of scope (the suite's `todo/` cases).
fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

fn isIdentPart(c: u8) bool {
    return isIdentStart(c) or isDigit(c);
}

/// Scan a run of identifier characters, classifying the three reserved value
/// keywords (`true`/`false`/`null`) into their dedicated tokens and everything
/// else (`Infinity`, `NaN`, and bare object keys) into an `identifier` token.
fn identifierOrKeyword(self: *Tokenizer) TokenizeError!Token {
    const start = self.index;
    while (self.char()) |c| {
        if (!isIdentPart(c)) break;
        self.index += 1;
    }
    const word = self.str[start..self.index];
    const kind: Token.Kind = if (std.mem.eql(u8, word, "true"))
        .true_
    else if (std.mem.eql(u8, word, "false"))
        .false_
    else if (std.mem.eql(u8, word, "null"))
        .null_
    else
        .identifier;
    return .init(kind, .init(start, self.index));
}

const isHexDigit = ascii.isHex;

// ========================
// TERMINAL TOKEN FUNCTIONS
// ========================

/// Collects all the bytes of a string and returns a JsonToken.string
/// Never returns null, but can be an empty string.
/// Respects escaped values.
fn string(self: *Tokenizer, delimiter: u8) TokenizeError!Token {
    const json5 = self.kind == JsonFormat.JSON5;
    const start = self.index;
    self.index += 1; // skip opening quote

    while (self.char()) |c| {
        if (c == delimiter) { // Closing quote
            self.index += 1;
            return .init(.string, .init(start, self.index));
        }
        switch (c) {
            '\\' => { // Escape a character
                self.index += 1; // skip backslash
                const escaped = self.char() orelse return TokenizeError.UnclosedString;
                if (json5) {
                    // JSON5 accepts any escape: the JSON set, plus `\x`, `\v`,
                    // `\0`, identity escapes (`\'`), and line continuations
                    // (`\` + LF/CR/CRLF). Validation/decoding is deferred to the
                    // parser; here we only need to consume the escaped unit so a
                    // `\'` or `\<newline>` does not terminate the string.
                    self.index += 1;
                    if (escaped == '\r' and self.char() == '\n') self.index += 1;
                    continue;
                }
                switch (escaped) {
                    // Valid escapes: quote, backslash, whitespace
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {
                        self.index += 1;
                    },
                    // Unicode escape. \u<four hex characters>
                    'u' => {
                        self.index += 1;
                        for (0..4) |_| {
                            const hex = self.char() orelse return TokenizeError.UnclosedString;
                            if (!isHexDigit(hex)) return TokenizeError.UnexpectedToken;
                            self.index += 1;
                        }
                    },
                    else => return TokenizeError.UnexpectedToken,
                }
            },
            0x00...0x1f => return TokenizeError.UnexpectedToken,
            else => self.index += 1,
        }
    }
    return error.UnclosedString;
}

/// Collects various kinds of numbers.
/// Negative, decimal, exponent
/// Checks for leading zero as well.
fn number(self: *Tokenizer) TokenizeError!Token {
    if (self.kind == JsonFormat.JSON5) return self.numberJson5();
    const start = self.index;

    // Check for negativity
    if (self.char() == '-') {
        self.index += 1;
    }

    switch (self.char() orelse return TokenizeError.UnexpectedEndOfInput) {
        // Either zero, or illegal leading zero
        '0' => {
            self.index += 1;
            if (self.char()) |c| if (isDigit(c)) return TokenizeError.LeadingZero;
        },
        '1'...'9' => {
            self.index += 1;
            while (self.char()) |c| {
                if (!isDigit(c)) break;
                self.index += 1;
            }
        },
        else => return TokenizeError.UnexpectedToken,
    }

    // Check for decimal
    if (self.char() == '.') {
        self.index += 1;
        const first_fraction = self.char() orelse return TokenizeError.UnexpectedEndOfInput;
        if (!isDigit(first_fraction)) return TokenizeError.UnexpectedToken;
        while (self.char()) |c| {
            if (!isDigit(c)) break;
            self.index += 1;
        }
    }

    // Check for exponent
    if (self.char()) |c| {
        if (c == 'e' or c == 'E') {
            self.index += 1;
            if (self.char()) |sign| {
                if (sign == '+' or sign == '-') self.index += 1;
            }
            const first_exponent = self.char() orelse return TokenizeError.UnexpectedEndOfInput;
            if (!isDigit(first_exponent)) return TokenizeError.UnexpectedToken;

            while (self.char()) |digit| {
                if (!isDigit(digit)) break;
                self.index += 1;
            }
        }
    }

    return .init(.number, .init(start, self.index));
}

/// JSON5 number: optional `+`/`-` sign, then one of
///   * `Infinity` / `NaN`              (non-finite; the parser lifts these to an
///                                      extended `number_special` node)
///   * `0x`-prefixed hexadecimal integer
///   * a decimal with an optional leading or trailing `.` and optional exponent
/// Leading zeros on a decimal integer stay illegal (no octal), matching JSON.
fn numberJson5(self: *Tokenizer) TokenizeError!Token {
    const start = self.index;

    if (self.char() == '+' or self.char() == '-') self.index += 1;

    if (self.matches("Infinity")) {
        self.index += "Infinity".len;
        return .init(.number, .init(start, self.index));
    }
    if (self.matches("NaN")) {
        self.index += "NaN".len;
        return .init(.number, .init(start, self.index));
    }

    // Hexadecimal integer: `0x`/`0X` then at least one hex digit.
    if (self.char() == '0' and (self.peek(1) == 'x' or self.peek(1) == 'X')) {
        self.index += 2;
        const hex_start = self.index;
        while (self.char()) |c| {
            if (!isHexDigit(c)) break;
            self.index += 1;
        }
        if (self.index == hex_start) return TokenizeError.UnexpectedToken; // bare `0x`
        return .init(.number, .init(start, self.index));
    }

    var digits_seen = false;

    // Integer part. A leading zero may not be followed by another digit (octal).
    if (self.char() == '0') {
        self.index += 1;
        digits_seen = true;
        if (self.char()) |c| if (isDigit(c)) return TokenizeError.LeadingZero;
    } else {
        while (self.char()) |c| {
            if (!isDigit(c)) break;
            self.index += 1;
            digits_seen = true;
        }
    }

    // Fractional part. Leading (`.5`) and trailing (`5.`) points are both legal.
    if (self.char() == '.') {
        self.index += 1;
        while (self.char()) |c| {
            if (!isDigit(c)) break;
            self.index += 1;
            digits_seen = true;
        }
    }

    // A lone `.` (or sign with no digits at all) is not a number.
    if (!digits_seen) return TokenizeError.UnexpectedToken;

    // Exponent.
    if (self.char()) |c| {
        if (c == 'e' or c == 'E') {
            self.index += 1;
            if (self.char()) |sign| {
                if (sign == '+' or sign == '-') self.index += 1;
            }
            const exp_start = self.index;
            while (self.char()) |d| {
                if (!isDigit(d)) break;
                self.index += 1;
            }
            if (self.index == exp_start) return TokenizeError.UnexpectedEndOfInput;
        }
    }

    return .init(.number, .init(start, self.index));
}

/// Look ahead `n` bytes from the current index without consuming.
fn peek(self: *const Tokenizer, n: usize) ?u8 {
    const i = self.index + n;
    if (i >= self.str.len) return null;
    return self.str[i];
}

/// Collects all bytes until arriving at a newline
/// Never returns null, but can be empty
fn comment(self: *Tokenizer) TokenizeError!Token {
    // Comments are not supported in the canonical JSON format
    if (self.kind == JsonFormat.JSON) return error.UnexpectedSlash;
    // Make sure there isn't just a random single slash
    if (self.index + 1 >= self.str.len) return TokenizeError.UnexpectedSlash;

    const start = self.index;
    const second = self.str[self.index + 1];

    return switch (second) {
        '/' => { // Single line comment
            self.index += 2;
            while (self.char()) |c| {
                // A line comment ends at any line terminator. JSON5/ES allow a
                // bare CR (and CRLF) to close it, not just LF.
                if (c == '\n' or c == '\r') break;
                self.index += 1;
            }
            return .init(.comment, .init(start, self.index));
        },
        '*' => { // Multi-line comment
            self.index += 2;
            while (self.index + 1 < self.str.len) {
                if (self.str[self.index] == '*' and self.str[self.index + 1] == '/') {
                    self.index += 2;
                    return .init(.comment, .init(start, self.index));
                }
                self.index += 1;
            }
            return TokenizeError.UnclosedComment;
        },
        else => return TokenizeError.UnexpectedSlash,
    };
}

// =======
// Testing
// =======

// Run tests standalone with
// `zig build test -Dtest-filter=tokenizer --summary all`

fn tok(kind: Token.Kind, start: usize, end: usize) Token {
    return Token.init(kind, .init(start, end));
}

fn testTokenizer(input: []const u8, expected: []const Token) !void {
    var tokenizer: Tokenizer = .{ .allocator = testing.allocator, .str = input };
    const tokens = try tokenizer.tokenize();
    defer testing.allocator.free(tokens);
    //errdefer log.err("expected: {any}", .{expected});
    //errdefer log.err("actual: {any}", .{tokens});
    try testing.expectEqualSlices(Token, expected, tokens);
}

fn testTokenizerError(input: []const u8, format: JsonFormat, expected_error: anyerror) !void {
    var tokenizer: Tokenizer = .{
        .allocator = testing.allocator,
        .str = input,
        .kind = format,
    };

    if (tokenizer.tokenize()) |tokens| {
        defer testing.allocator.free(tokens);
        try testing.expect(false);
    } else |err| {
        try testing.expectEqual(expected_error, err);
    }
}

test "array no whitespace" {
    try testTokenizer(
        \\["hello","there"]
    , &.{
        tok(.open_bracket, 0, 1),
        tok(.string, 1, 8),
        tok(.comma, 8, 9),
        tok(.string, 9, 16),
        tok(.close_bracket, 16, 17),
        tok(.end_of_file, 17, 17),
    });
}

test "whitespace" {
    try testTokenizer(" [ \"hello\" ,  \"there\" ] ", &.{
        tok(.whitespace, 0, 1),
        tok(.open_bracket, 1, 2),
        tok(.whitespace, 2, 3),
        tok(.string, 3, 10),
        tok(.whitespace, 10, 11),
        tok(.comma, 11, 12),
        tok(.whitespace, 12, 14),
        tok(.string, 14, 21),
        tok(.whitespace, 21, 22),
        tok(.close_bracket, 22, 23),
        tok(.whitespace, 23, 24),
        tok(.end_of_file, 24, 24),
    });
    try testTokenizer(" { \"hello\" :  \"there\" } ", &.{
        tok(.whitespace, 0, 1),
        tok(.open_brace, 1, 2),
        tok(.whitespace, 2, 3),
        tok(.string, 3, 10),
        tok(.whitespace, 10, 11),
        tok(.colon, 11, 12),
        tok(.whitespace, 12, 14),
        tok(.string, 14, 21),
        tok(.whitespace, 21, 22),
        tok(.close_brace, 22, 23),
        tok(.whitespace, 23, 24),
        tok(.end_of_file, 24, 24),
    });
}

test "object with array" {
    try testTokenizer(
        \\{"array": ["hello" ,  "there"]}
    , &.{
        tok(.open_brace, 0, 1),
        tok(.string, 1, 8),
        tok(.colon, 8, 9),
        tok(.whitespace, 9, 10),
        tok(.open_bracket, 10, 11),
        tok(.string, 11, 18),
        tok(.whitespace, 18, 19),
        tok(.comma, 19, 20),
        tok(.whitespace, 20, 22),
        tok(.string, 22, 29),
        tok(.close_bracket, 29, 30),
        tok(.close_brace, 30, 31),
        tok(.end_of_file, 31, 31),
    });
}

test "primitives" {
    try testTokenizer(
        \\[true, false, null, "string", 40334]
    , &.{
        tok(.open_bracket, 0, 1),
        tok(.true_, 1, 5),
        tok(.comma, 5, 6),
        tok(.whitespace, 6, 7),
        tok(.false_, 7, 12),
        tok(.comma, 12, 13),
        tok(.whitespace, 13, 14),
        tok(.null_, 14, 18),
        tok(.comma, 18, 19),
        tok(.whitespace, 19, 20),
        tok(.string, 20, 28),
        tok(.comma, 28, 29),
        tok(.whitespace, 29, 30),
        tok(.number, 30, 35),
        tok(.close_bracket, 35, 36),
        tok(.end_of_file, 36, 36),
    });
}

test "numbers" {
    try testTokenizer(
        \\[1,-1,0,0.2,12e+3,1e10,0e1,-0.2,1e+10]
    , &.{
        tok(.open_bracket, 0, 1),
        tok(.number, 1, 2),
        tok(.comma, 2, 3),
        tok(.number, 3, 5),
        tok(.comma, 5, 6),
        tok(.number, 6, 7),
        tok(.comma, 7, 8),
        tok(.number, 8, 11),
        tok(.comma, 11, 12),
        tok(.number, 12, 17),
        tok(.comma, 17, 18),
        tok(.number, 18, 22),
        tok(.comma, 22, 23),
        tok(.number, 23, 26),
        tok(.comma, 26, 27),
        tok(.number, 27, 31),
        tok(.comma, 31, 32),
        tok(.number, 32, 37),
        tok(.close_bracket, 37, 38),
        tok(.end_of_file, 38, 38),
    });
}

test "empty object/array" {
    try testTokenizer(
        \\[]
    , &.{
        tok(.open_bracket, 0, 1),
        tok(.close_bracket, 1, 2),
        tok(.end_of_file, 2, 2),
    });
    try testTokenizer(
        \\{}
    , &.{
        tok(.open_brace, 0, 1),
        tok(.close_brace, 1, 2),
        tok(.end_of_file, 2, 2),
    });
}

test "truncated literals are rejected" {
    try testTokenizerError("tru", .JSONC, error.UnexpectedToken);
    try testTokenizerError("fals", .JSONC, error.UnexpectedToken);
    try testTokenizerError("n", .JSONC, error.UnexpectedToken);
}

test "strings reject invalid JSON escapes and control bytes" {
    try testTokenizerError("\"\\x\"", .JSONC, error.UnexpectedToken);
    try testTokenizerError("\"line\nbreak\"", .JSONC, error.UnexpectedToken);
    try testTokenizerError("\"\\u12", .JSONC, error.UnclosedString);
    try testTokenizerError("\"\\u12g4\"", .JSONC, error.UnexpectedToken);
}

test "strict JSON numbers reject invalid forms" {
    try testTokenizerError("-", .JSONC, error.UnexpectedEndOfInput);
    try testTokenizerError("-.2", .JSONC, error.UnexpectedToken);
    try testTokenizerError("1.", .JSONC, error.UnexpectedEndOfInput);
    try testTokenizerError("1e+", .JSONC, error.UnexpectedEndOfInput);
    try testTokenizerError("-012", .JSONC, error.LeadingZero);
    try testTokenizerError("012", .JSONC, error.LeadingZero);
}

test "JSONC comments" {
    try testTokenizer("[// hi\n1]", &.{
        tok(.open_bracket, 0, 1),
        tok(.comment, 1, 6),
        tok(.whitespace, 6, 7),
        tok(.number, 7, 8),
        tok(.close_bracket, 8, 9),
        tok(.end_of_file, 9, 9),
    });

    try testTokenizerError("/", .JSONC, error.UnexpectedSlash);
    //multiline test
    try testTokenizer("/* hi */", &.{ tok(.comment, 0, 8), tok(.end_of_file, 8, 8) });
    // multiline inline test
    try testTokenizer("{\"hello\":/* hi */\"world\"}",
        &.{
            tok(.open_brace, 0, 1),
            tok(.string, 1, 8),
            tok(.colon, 8, 9),
            tok(.comment, 9, 17),
            tok(.string, 17, 24),
            tok(.close_brace, 24, 25),
            tok(.end_of_file, 25, 25)});
    try testTokenizer( // multiline comment test
        \\{
        \\  "hello": "world"
        \\/*
        \\hello, this is  a
        \\multiline comment
        \\*/
        \\}
        ,
        &.{
            tok(.open_brace, 0, 1),
            tok(.whitespace, 1, 4),
            tok(.string, 4, 11),
            tok(.colon, 11, 12),
            tok(.whitespace, 12, 13),
            tok(.string, 13, 20),
            tok(.whitespace, 20, 21),
            tok(.comment, 21, 62),
            tok(.whitespace, 62, 63),
            tok(.close_brace, 63, 64),
            tok(.end_of_file, 64, 64)});
    try testTokenizerError("// hi", .JSON, error.UnexpectedSlash);
}
