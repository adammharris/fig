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
    block_header, // `|`/`>` plus chomping/indent indicators
    block_scalar, // raw body lines of a block scalar
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
pending_block: ?PendingBlock = null,

allocator: std.mem.Allocator,
source: []const u8 = "",
type: Type = .v1_2_2,

const PendingBlock = struct {
    /// Indentation (column) of the line the header sits on. Block content must
    /// be more indented than this, and the explicit-indent indicator is counted
    /// relative to it.
    header_indent: usize,
    explicit_indent: ?usize,
};

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
                try self.flushPendingBlock();
                continue;
            }
        }

        try self.tokenizeLineContent(line);
        if (line.newline_end > line.end) {
            try self.addToken(.init(.newline, .init(line.end, line.newline_end)));
        }
        try self.flushPendingBlock();
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
            '|', '>' => {
                // A `|`/`>` in value position begins a block scalar. (Anywhere
                // else it is swallowed by scalarEnd before reaching this switch,
                // so the current byte being `|`/`>` means we are at value start.)
                if (blockHeaderEnd(self.source, cursor, line.end)) |hdr_end| {
                    try self.addToken(.init(.block_header, .init(cursor, hdr_end)));
                    var rest = hdr_end;
                    while (rest < line.end and isBlank(self.source[rest])) rest += 1;
                    if (rest < line.end and self.source[rest] == '#') {
                        try self.addToken(.init(.comment, .init(rest, line.end)));
                    }
                    self.pending_block = .{
                        .header_indent = line.content_start - line.start,
                        .explicit_indent = explicitIndent(self.source, cursor, hdr_end),
                    };
                    return;
                }
                const end = scalarEnd(self.source, cursor, line.end);
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

/// If a block-scalar header (`|`/`>` plus optional chomping/indent indicators)
/// occupies the rest of the line, returns the index just past the indicators.
/// The indicators may be followed only by whitespace and/or a comment.
fn blockHeaderEnd(source: []const u8, start: usize, line_end: usize) ?usize {
    var i = start + 1;
    var seen_chomp = false;
    var seen_indent = false;
    while (i < line_end) : (i += 1) {
        switch (source[i]) {
            '+', '-' => {
                if (seen_chomp) return null;
                seen_chomp = true;
            },
            '1'...'9' => {
                if (seen_indent) return null;
                seen_indent = true;
            },
            else => break,
        }
    }
    const indicators_end = i;
    while (i < line_end and isBlank(source[i])) i += 1;
    if (i < line_end) {
        // The only thing allowed after the indicators is a comment, and a `#`
        // is a comment only when separated from the indicators by whitespace.
        if (source[i] != '#' or i == indicators_end) return null;
    }
    return indicators_end;
}

/// Extracts the explicit indentation indicator digit from a header, if present.
fn explicitIndent(source: []const u8, start: usize, header_end: usize) ?usize {
    var i = start + 1;
    while (i < header_end) : (i += 1) {
        if (source[i] >= '1' and source[i] <= '9') return source[i] - '0';
    }
    return null;
}

fn flushPendingBlock(self: *Tokenizer) TokenizeError!void {
    const info = self.pending_block orelse return;
    self.pending_block = null;
    try self.consumeBlockBody(info);
}

/// Consumes the indented body lines of a block scalar (already past the header
/// line's newline) and emits a single `block_scalar` token spanning them. The
/// body runs until the first non-blank line indented no more than the content
/// indentation; blank lines are always included so chomping can see them.
fn consumeBlockBody(self: *Tokenizer, info: PendingBlock) TokenizeError!void {
    const body_start = self.i;
    var content_indent: ?usize = if (info.explicit_indent) |d| info.header_indent + d else null;
    // While auto-detecting, the largest indentation seen on a leading empty
    // line: it is an error for one to be more indented than the first content
    // line (YAML 1.2.2 §8.1.1.1).
    var max_leading_blank: usize = 0;
    // Smallest column at which a tab appears in a leading empty line. A tab is
    // invalid only inside the indentation zone, i.e. before the content indent.
    var min_blank_tab: ?usize = null;
    var last_end = body_start;

    while (self.i < self.source.len) {
        const line_start = self.i;
        var end = line_start;
        while (end < self.source.len and self.source[end] != '\n') end += 1;
        const newline_end = if (end < self.source.len) end + 1 else end;

        var spaces = line_start;
        while (spaces < end and self.source[spaces] == ' ') spaces += 1;
        var ws = line_start;
        while (ws < end and isBlank(self.source[ws])) ws += 1;
        const blank = ws == end;
        const indent = spaces - line_start;

        if (blank) {
            if (content_indent == null) {
                if (ws > spaces) {
                    const tab_col = spaces - line_start;
                    if (min_blank_tab == null or tab_col < min_blank_tab.?) min_blank_tab = tab_col;
                }
                if (indent > max_leading_blank) max_leading_blank = indent;
            }
        } else {
            if (content_indent) |ci| {
                if (indent < ci) break;
            } else {
                if (indent <= info.header_indent) break;
                if (max_leading_blank > indent) return TokenizeError.InvalidIndent;
                if (min_blank_tab) |col| if (col < indent) return TokenizeError.TabIndent;
                content_indent = indent;
            }
        }

        self.i = newline_end;
        last_end = newline_end;
    }

    // An empty block scalar whose only lines carried tabs has tabs in the
    // indentation zone (there is no content to measure against).
    if (content_indent == null and min_blank_tab != null) return TokenizeError.TabIndent;

    if (last_end > body_start) {
        try self.addToken(.init(.block_scalar, .init(body_start, last_end)));
    }
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

test "yaml block scalar header and body are single tokens" {
    // The `|` header and the two indented body lines become one block_header
    // plus one block_scalar token; the body is not tokenized as structure.
    try testTokenizer(
        "text: |\n  a\n  b\nnext: x\n",
        &.{
            tok(.scalar, 0, 4),
            tok(.colon, 4, 5),
            tok(.whitespace, 5, 6),
            tok(.block_header, 6, 7),
            tok(.newline, 7, 8),
            tok(.block_scalar, 8, 16),
            tok(.scalar, 16, 20),
            tok(.colon, 20, 21),
            tok(.whitespace, 21, 22),
            tok(.scalar, 22, 23),
            tok(.newline, 23, 24),
            tok(.end_of_file, 24, 24),
        },
    );
}

test "yaml block scalar header carries indicators" {
    try testTokenizer(
        "k: |2-\n    x\n",
        &.{
            tok(.scalar, 0, 1),
            tok(.colon, 1, 2),
            tok(.whitespace, 2, 3),
            tok(.block_header, 3, 6),
            tok(.newline, 6, 7),
            tok(.block_scalar, 7, 13),
            tok(.end_of_file, 13, 13),
        },
    );
}

test "yaml block scalar rejects tabs and bad indentation" {
    try testTokenizerError("foo: |\n\t\nbar: 1\n", error.TabIndent);
    try testTokenizerError("foo: |\n     \n  ok\n", error.InvalidIndent);
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
