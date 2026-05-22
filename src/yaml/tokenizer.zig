//! YAML tokenizer

const Tokenizer = @This();

const std = @import("std");
const log = std.log.scoped(.tokenizer);
const testing = std.testing;
const Span = @import("../util/span.zig");
const Type = @import("yaml.zig").Language.Type;

pub const Token = @import("../token.zig").Token(Kind);

pub const Kind = enum {
    // Structural
    indent,
    dedent,
    newline, //size: 1
    dash,
    colon,
    scalar,
    comment,
    end_of_file,

    pub fn len(self: Kind) ?usize {
        return switch (self) {
            .end_of_file, .dedent => 0,
            .newline, .dash, .colon => 1,
            else => null,
        };
    }
};

const Line = struct {
    start: usize,
    content_start: usize, // if blank line, equals end
    end: usize, // excludes newline
    newline_end: usize, // includes newline if present
};

tokens: std.ArrayList(Token) = .empty,
i: usize = 0,

allocator: std.mem.Allocator,
source: []const u8 = "",
type: Type,

pub fn tokenize(self: *Tokenizer) ![] const Token {
    errdefer self.tokens.deinit(self.allocator);
    try self.tokens.ensureTotalCapacity(self.allocator, self.source.len + 1);

    var current_indent = 0;
    var indent_stack: std.ArrayList(usize) = .empty;
    // YAML is whitespace-sensitive, so we parse line-by-line.
    while (self.getLine()) |line| {
        const lineinfo = countLeadingSpaces(line);
        if (lineinfo.spaces > current_indent) {
            indent_stack.append(lineinfo.spaces);
            self.tokens.appendAssumeCapacity(
                .init(.indent, .init(self.i - line.len, self.i))
            );
            current_indent = lineinfo.spaces;
        } else if (lineinfo.spaces < current_indent) {
            while (lineinfo.spaces < current_indent) {
                while (lineinfo.spaces < current_indent) {
                    self.tokens.appendAssumeCapacity(.fixed(.dedent, self.i));
                    current_indent = indent_stack.pop();
                }
                if (lineinfo.spaces != current_indent) return error.InvalidToken;
            }
        }
        // Now parse scalar/colon/dash
        while (self.i - line.len)
        switch (self.getChar()) {
            '-' => {
                self.tokens.appendAssumeCapacity(.fixed(.dash, self.i));
            },
            '#' => {}, //TODO: parse comment
            else => {
                self.scalar()
            }
        }

        // On to the next line!
        self.tokens.appendAssumeCapacity(.init(.newline, .init(self.i, self.i+1)));
    }

    while (indent_stack.items.len != 0) {
        while (lineinfo.spaces < current_indent) {
            self.tokens.appendAssumeCapacity(.fixed(.dedent, self.i));
            current_indent = indent_stack.pop();
        }
    }
    try self.addToken(.fixed(.end_of_file, self.i));
    return try self.tokens.toOwnedSlice(self.allocator);
}

fn getLine(self: *Tokenizer) ?Line {
    if (self.i >= self.source.len) return null;
    const start = self.i;
    while (self.i < self.source.len and self.source[self.i] != '\n') {
        self.i += 1;
    }
    const end = self.i;
    const line: Line = .{
        .start = start,
        .content_start:
    };
}

fn countLeadingSpaces(line: []const u8) struct { spaces: u32, char: u8} {
    var spaces = 0;
    var char = "";
    for (line) |c| {
        if (c == ' ') {
            spaces += 1;
        } else {
            char = c;
            break;
        }
    }
    return .{ .spaces = spaces, .char = char };
}


test "parse line" {
    const line = "   - hello\n";
    Parser.
}