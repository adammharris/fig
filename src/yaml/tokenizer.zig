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
                try self.addToken(.fixed(.colon, cursor));
                cursor += 1;
                at_content_start = false;
            },
            '\'', '"' => {
                const end = try quotedScalarEnd(self.source, cursor, line.end);
                try self.addScalar(cursor, end);
                cursor = end;
                at_content_start = false;
            },
            '-' => {
                if (at_content_start) {
                    try self.addToken(.fixed(.dash, cursor));
                    cursor += 1;
                    at_content_start = false;
                } else {
                    const end = scalarEnd(self.source, cursor, line.end);
                    try self.addScalar(cursor, end);
                    cursor = end;
                    at_content_start = false;
                }
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
            ':', '#' => break,
            else => {},
        }
    }
    return end;
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
