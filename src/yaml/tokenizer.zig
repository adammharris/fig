//! YAML tokenizer

const Tokenizer = @This();

const std = @import("std");
const testing = std.testing;
const Type = @import("yaml.zig").Type;

pub const Token = @import("../token.zig").Token(Kind);

pub const Kind = enum {
    // Structural
    indent,
    dedent,
    newline,
    dash,
    colon,
    scalar,
    comment,
    whitespace,
    doc_start, // `---` document start marker
    doc_end, // `...` document end marker
    end_of_file,

    pub fn len(self: Kind) ?usize {
        return switch (self) {
            .end_of_file, .dedent => 0,
            .newline, .dash, .colon => 1,
            else => null,
        };
    }
};

const TokenizeError = error{ InvalidIndent, TabIndent, OutOfMemory, UnclosedString };

const Line = struct {
    start: usize,
    content_start: usize, // if blank line, equals end
    end: usize, // excludes newline
    newline_end: usize, // includes newline if present
    fn isBlank(self: *const Line) bool {
        return self.content_start == self.end;
    }
};

tokens: std.ArrayList(Token) = .empty,
i: usize = 0,

allocator: std.mem.Allocator,
source: []const u8 = "",
type: Type = .v1_2_2,

pub fn tokenize(self: *Tokenizer) ![]const Token {
    errdefer self.tokens.deinit(self.allocator);
    try self.tokens.ensureTotalCapacity(self.allocator, self.source.len + 1);

    var current_indent: usize = 0;
    var indent_stack: std.ArrayList(usize) = .empty;
    defer indent_stack.deinit(self.allocator);
    try indent_stack.append(self.allocator, 0);

    // YAML is whitespace-sensitive, so we parse line-by-line.
    while (try self.getLine()) |line| {
        if (line.isBlank()) continue;

        const indent = line.content_start - line.start;
        if (indent > current_indent) {
            try indent_stack.append(self.allocator, indent);
            try self.addToken(.init(.indent, .init(line.start, line.content_start)));
            current_indent = indent;
        } else if (indent < current_indent) {
            while (indent < current_indent) {
                _ = indent_stack.pop();
                current_indent = indent_stack.getLast();
                try self.addToken(.fixed(.dedent, line.content_start));
            }
            if (indent != current_indent) return TokenizeError.InvalidIndent;
        }

        // Document markers (`---`, `...`) are only recognized at column 0.
        // Any dedents above have already closed open containers.
        if (indent == 0) {
            if (self.docMarker(line)) |kind| {
                const cs = line.content_start;
                try self.addToken(.init(kind, .init(cs, cs + 3)));
                // Tokenize any content sharing the marker's line (e.g. `--- foo`).
                var rest = cs + 3;
                while (rest < line.end and isBlank(self.source[rest])) rest += 1;
                if (rest < line.end) {
                    try self.tokenizeLineContent(.{
                        .start = rest,
                        .content_start = rest,
                        .end = line.end,
                        .newline_end = line.newline_end,
                    });
                }
                if (line.newline_end > line.end) {
                    try self.addToken(.init(.newline, .init(line.end, line.newline_end)));
                }
                continue;
            }
        }

        try self.tokenizeLineContent(line);
        if (line.newline_end > line.end) {
            try self.addToken(.init(.newline, .init(line.end, line.newline_end)));
        }
    }

    while (indent_stack.items.len != 0) {
        _ = indent_stack.pop();
        if (indent_stack.items.len == 0) break;
        try self.addToken(.fixed(.dedent, self.i));
    }

    try self.addToken(.fixed(.end_of_file, self.i));
    return try self.tokens.toOwnedSlice(self.allocator);
}

fn getLine(self: *Tokenizer) TokenizeError!?Line {
    if (self.i >= self.source.len) return null;

    const start = self.i;
    while (self.i < self.source.len and self.source[self.i] != '\n') {
        self.i += 1;
    }

    const end = self.i;
    if (self.i < self.source.len and self.source[self.i] == '\n') {
        self.i += 1;
    }

    var content_start = start;
    while (content_start < end and self.source[content_start] == ' ') {
        content_start += 1;
    }
    if (content_start < end and self.source[content_start] == '\t') {
        // Tabs are not allowed in YAML indentation.
        return TokenizeError.TabIndent;
    }

    return .{
        .start = start,
        .content_start = content_start,
        .end = end,
        .newline_end = self.i,
    };
}

fn tokenizeLineContent(self: *Tokenizer, line: Line) TokenizeError!void {
    var cursor = line.content_start;
    var at_content_start = true;

    while (cursor < line.end) {
        switch (self.source[cursor]) {
            ' ' => {
                const end = whitespaceEnd(self.source, cursor, line.end);
                try self.addToken(.init(.whitespace, .init(cursor, end)));
                cursor = end;
            },
            '#' => {
                try self.addToken(.init(.comment, .init(cursor, line.end)));
                return;
            },
            ':' => {
                // A colon is a mapping value indicator only when followed by
                // whitespace or the end of line. Otherwise (e.g. `http://x`)
                // it is part of a plain scalar.
                if (followedByBlank(self.source, cursor, line.end)) {
                    try self.addToken(.fixed(.colon, cursor));
                    cursor += 1;
                } else {
                    const end = scalarEnd(self.source, cursor, line.end);
                    try self.addScalar(cursor, end);
                    cursor = end;
                }
                at_content_start = false;
            },
            '\'', '"' => {
                const end = try quotedScalarEnd(self.source, cursor, line.end);
                try self.addScalar(cursor, end);
                cursor = end;
                at_content_start = false;
            },
            '-' => {
                // A dash is a sequence entry indicator only at the start of a
                // node and when followed by whitespace or end of line.
                // Otherwise (e.g. `-3`) it begins a plain scalar.
                if (at_content_start and followedByBlank(self.source, cursor, line.end)) {
                    try self.addToken(.fixed(.dash, cursor));
                    cursor += 1;
                } else {
                    const end = scalarEnd(self.source, cursor, line.end);
                    try self.addScalar(cursor, end);
                    cursor = end;
                }
                at_content_start = false;
            },
            else => {
                const end = scalarEnd(self.source, cursor, line.end);
                try self.addScalar(cursor, end);
                cursor = end;
                at_content_start = false;
            },
        }
    }
}

fn addToken(self: *Tokenizer, token: Token) TokenizeError!void {
    try self.tokens.append(self.allocator, token);
}

fn addScalar(self: *Tokenizer, start: usize, end: usize) TokenizeError!void {
    const trimmed_end = trimRightSpaces(self.source, start, end);
    if (trimmed_end > start) {
        try self.addToken(.init(.scalar, .init(start, trimmed_end)));
    }
}

fn scalarEnd(source: []const u8, start: usize, line_end: usize) usize {
    var end = start;
    while (end < line_end) : (end += 1) {
        switch (source[end]) {
            // A colon ends the scalar only when it is a value indicator,
            // i.e. followed by whitespace or end of line.
            ':' => if (followedByBlank(source, end, line_end)) break,
            // A `#` begins a comment only when preceded by whitespace.
            '#' => if (end > start and isBlank(source[end - 1])) break,
            else => {},
        }
    }
    return end;
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Detects a document marker (`---` or `...`) occupying its own column-0 line.
/// The three marker bytes must be followed by whitespace or end of line.
fn docMarker(self: *const Tokenizer, line: Line) ?Kind {
    const cs = line.content_start;
    if (line.end - cs < 3) return null;
    const c = self.source[cs];
    if (c != '-' and c != '.') return null;
    if (self.source[cs + 1] != c or self.source[cs + 2] != c) return null;
    if (cs + 3 != line.end and !isBlank(self.source[cs + 3])) return null;
    return if (c == '-') .doc_start else .doc_end;
}

/// True when the byte after `i` is whitespace or `i` is the last byte on the line.
fn followedByBlank(source: []const u8, i: usize, line_end: usize) bool {
    return i + 1 >= line_end or isBlank(source[i + 1]);
}

fn quotedScalarEnd(source: []const u8, start: usize, line_end: usize) TokenizeError!usize {
    return switch (source[start]) {
        '\'' => singleQuotedScalarEnd(source, start, line_end),
        '"' => doubleQuotedScalarEnd(source, start, line_end),
        else => unreachable,
    };
}

fn singleQuotedScalarEnd(source: []const u8, start: usize, line_end: usize) TokenizeError!usize {
    var end = start + 1;
    while (end < line_end) : (end += 1) {
        if (source[end] != '\'') continue;
        if (end + 1 < line_end and source[end + 1] == '\'') {
            end += 1;
            continue;
        }
        return end + 1;
    }
    return TokenizeError.UnclosedString;
}

fn doubleQuotedScalarEnd(source: []const u8, start: usize, line_end: usize) TokenizeError!usize {
    var end = start + 1;
    while (end < line_end) : (end += 1) {
        switch (source[end]) {
            '"' => return end + 1,
            '\\' => {
                end += 1;
                if (end >= line_end) return TokenizeError.UnclosedString;
            },
            else => {},
        }
    }
    return TokenizeError.UnclosedString;
}

fn trimRightSpaces(source: []const u8, start: usize, end: usize) usize {
    var trimmed = end;
    while (trimmed > start and source[trimmed - 1] == ' ') {
        trimmed -= 1;
    }
    return trimmed;
}

fn whitespaceEnd(source: []const u8, start: usize, line_end: usize) usize {
    var end = start;
    while (end < line_end and (source[end] == ' ' or source[end] == '\t')) {
        end += 1;
    }
    return end;
}

// =======
// Testing
// =======

fn testTokenizer(input: []const u8, expected: []const Token) !void {
    var tokenizer: Tokenizer = .{ .allocator = testing.allocator, .source = input };
    const tokens = try tokenizer.tokenize();
    defer testing.allocator.free(tokens);
    try testing.expectEqualSlices(Token, expected, tokens);
}

fn testTokenizerError(input: []const u8, expected_error: anyerror) !void {
    var tokenizer: Tokenizer = .{ .allocator = testing.allocator, .source = input };
    if (tokenizer.tokenize()) |tokens| {
        defer testing.allocator.free(tokens);
        try testing.expect(false);
    } else |err| {
        try testing.expectEqual(expected_error, err);
    }
}

fn tok(kind: Token.Kind, start: usize, end: usize) Token {
    return Token.init(kind, .init(start, end));
}

test "yaml flat mapping" {
    try testTokenizer(
        "name: Ada\nage: 37\n",
        &.{
            tok(.scalar, 0, 4),
            tok(.colon, 4, 5),
            tok(.whitespace, 5, 6),
            tok(.scalar, 6, 9),
            tok(.newline, 9, 10),
            tok(.scalar, 10, 13),
            tok(.colon, 13, 14),
            tok(.whitespace, 14, 15),
            tok(.scalar, 15, 17),
            tok(.newline, 17, 18),
            tok(.end_of_file, 18, 18),
        },
    );
}

test "yaml flat sequence" {
    try testTokenizer(
        "- one\n- two\n",
        &.{
            tok(.dash, 0, 1),
            tok(.whitespace, 1, 2),
            tok(.scalar, 2, 5),
            tok(.newline, 5, 6),
            tok(.dash, 6, 7),
            tok(.whitespace, 7, 8),
            tok(.scalar, 8, 11),
            tok(.newline, 11, 12),
            tok(.end_of_file, 12, 12),
        },
    );
}

test "yaml nested indentation" {
    try testTokenizer(
        \\root:
        \\  child: value
        \\next: value
        \\
    ,
        &.{
            tok(.scalar, 0, 4),
            tok(.colon, 4, 5),
            tok(.newline, 5, 6),
            tok(.indent, 6, 8),
            tok(.scalar, 8, 13),
            tok(.colon, 13, 14),
            tok(.whitespace, 14, 15),
            tok(.scalar, 15, 20),
            tok(.newline, 20, 21),
            tok(.dedent, 21, 21),
            tok(.scalar, 21, 25),
            tok(.colon, 25, 26),
            tok(.whitespace, 26, 27),
            tok(.scalar, 27, 32),
            tok(.newline, 32, 33),
            tok(.end_of_file, 33, 33),
        },
    );
}

test "yaml quoted scalars are single tokens" {
    try testTokenizer(
        "quoted: 'a: # b'\n",
        &.{
            tok(.scalar, 0, 6),
            tok(.colon, 6, 7),
            tok(.whitespace, 7, 8),
            tok(.scalar, 8, 16),
            tok(.newline, 16, 17),
            tok(.end_of_file, 17, 17),
        },
    );

    try testTokenizer(
        "\"quoted:key\": \"value # not comment\"\n",
        &.{
            tok(.scalar, 0, 12),
            tok(.colon, 12, 13),
            tok(.whitespace, 13, 14),
            tok(.scalar, 14, 35),
            tok(.newline, 35, 36),
            tok(.end_of_file, 36, 36),
        },
    );
}

test "yaml quoted scalars must close on the line" {
    try testTokenizerError("'unterminated", error.UnclosedString);
    try testTokenizerError("\"unterminated", error.UnclosedString);
}

test "yaml colon is an indicator only before whitespace" {
    // A colon followed by a non-space (a URL) stays inside the plain scalar.
    try testTokenizer(
        "url: http://example.com\n",
        &.{
            tok(.scalar, 0, 3),
            tok(.colon, 3, 4),
            tok(.whitespace, 4, 5),
            tok(.scalar, 5, 23),
            tok(.newline, 23, 24),
            tok(.end_of_file, 24, 24),
        },
    );

    // `a:b` with no trailing space is a single plain scalar.
    try testTokenizer(
        "a:b\n",
        &.{
            tok(.scalar, 0, 3),
            tok(.newline, 3, 4),
            tok(.end_of_file, 4, 4),
        },
    );
}

test "yaml dash is an indicator only before whitespace" {
    // `-3` is a (negative) plain scalar, not an empty sequence entry.
    try testTokenizer(
        "value: -3\n",
        &.{
            tok(.scalar, 0, 5),
            tok(.colon, 5, 6),
            tok(.whitespace, 6, 7),
            tok(.scalar, 7, 9),
            tok(.newline, 9, 10),
            tok(.end_of_file, 10, 10),
        },
    );
}

test "yaml document markers" {
    try testTokenizer(
        "---\nname: Ada\n...\n",
        &.{
            tok(.doc_start, 0, 3),
            tok(.newline, 3, 4),
            tok(.scalar, 4, 8),
            tok(.colon, 8, 9),
            tok(.whitespace, 9, 10),
            tok(.scalar, 10, 13),
            tok(.newline, 13, 14),
            tok(.doc_end, 14, 17),
            tok(.newline, 17, 18),
            tok(.end_of_file, 18, 18),
        },
    );
}

test "yaml hash starts a comment only after whitespace" {
    // `a#b` has no comment: the hash is part of the plain scalar.
    try testTokenizer(
        "a#b\n",
        &.{
            tok(.scalar, 0, 3),
            tok(.newline, 3, 4),
            tok(.end_of_file, 4, 4),
        },
    );

    // `a #b` does: the hash is preceded by whitespace.
    try testTokenizer(
        "a #b\n",
        &.{
            tok(.scalar, 0, 1),
            tok(.comment, 2, 4),
            tok(.newline, 4, 5),
            tok(.end_of_file, 5, 5),
        },
    );
}
