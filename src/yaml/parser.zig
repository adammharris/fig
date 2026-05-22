//! The parser turns YAML tokens into a concrete syntax tree.
//! Depends on the tokenizer and the abstract Document struct.

const std = @import("std");
const Document = @import("../document.zig");
const Span = @import("../util/span.zig");
const testing = std.testing;
const Tokenizer = @import("tokenizer.zig");
const Token = Tokenizer.Token;
const Type = @import("yaml.zig").Language.Type;

const Parser = @This();

const ContainerKind = enum { sequence, mapping };
const OpenContainer = struct {
    id: Document.Node.Id,
    kind: ContainerKind,
    first_child: ?Document.Node.Id = null,
    last_child: ?Document.Node.Id = null,
    pending_key: ?Document.Node.Id = null,
    pending_value_span: usize = 0,
    pending_sequence_item_span: ?usize = null,
};

nodes: std.ArrayList(Document.Node) = .empty,
container_stack: std.ArrayList(OpenContainer) = .empty,
tokens: []const Token = &.{},
index: usize = 0,
force_new_container: bool = false,
root: ?Document.Node.Id = null,

allocator: std.mem.Allocator,
source: []const u8 = "",

const ParseError = error{ UnexpectedToken, EmptyDocument };
const ParserError = ParseError || std.mem.Allocator.Error;

/// Primary entry point
/// Pass allocator, input, and type, and get a Document.
pub fn parse(allocator: std.mem.Allocator, input: []const u8, format: Type) !Document {
    var parser: Parser = .{ .allocator = allocator };
    defer parser.deinit();
    return parser.parseOnce(input, format);
}

/// Secondary entry point, called on a parser object.
/// Caller must handle memory by calling `defer deinit` or similar.
pub fn parseOnce(self: *Parser, input: []const u8, format: Type) !Document {
    self.source = input;

    var tokenizer: Tokenizer = .{
        .allocator = self.allocator,
        .source = input,
        .type = format,
    };

    self.tokens = try tokenizer.tokenize();
    defer self.allocator.free(self.tokens);

    while (true) {
        self.skipTriviaNoNewline();
        switch (self.peek().kind) {
            .indent => {
                self.force_new_container = true;
                _ = self.advance();
            },
            .dedent => {
                try self.closePendingEmptyValue();
                const id = try self.closeContainer(self.peek().span.end);
                _ = self.advance();
                try self.finishValue(id);
            },
            .newline => _ = self.advance(),
            .dash => try self.parseSequenceEntry(),
            .scalar => {
                if (!self.isMappingStart()) return ParseError.UnexpectedToken;
                try self.parseMappingEntry();
            },
            .end_of_file => break,
            else => return ParseError.UnexpectedToken,
        }
    }

    if (self.nodes.items.len == 0) return ParseError.EmptyDocument;

    while (self.container_stack.items.len > 0) {
        try self.closePendingEmptyValue();
        const id = try self.closeContainer(self.peek().span.end);
        try self.finishValue(id);
    }

    const root = self.root orelse return ParseError.EmptyDocument;
    const nodes = try self.nodes.toOwnedSlice(self.allocator);
    self.nodes = .empty;
    return .{
        .source = input,
        .root = root,
        .nodes = nodes,
    };
}

pub fn deinit(self: *Parser) void {
    self.container_stack.deinit(self.allocator);
    self.nodes.deinit(self.allocator);
}

fn parseSequenceEntry(self: *Parser) ParserError!void {
    const dash = self.advance();
    const sequence_id = try self.ensureContainer(.sequence, dash.span.start);
    self.clearPendingSequenceItem(sequence_id);
    self.skipTriviaNoNewline();

    switch (self.peek().kind) {
        .newline, .dedent, .end_of_file => {
            self.currentContainer().pending_sequence_item_span = dash.span.end;
        },
        .scalar => {
            if (self.isMappingStart()) {
                const mapping_id = try self.openContainer(.mapping, self.peek().span.start);
                try self.parseMappingEntry();
                const id = try self.closeContainer(self.nodes.items[mapping_id].span.end);
                try self.finishValue(id);
            } else {
                const value_id = try self.parseScalar();
                try self.finishValue(value_id);
            }
        },
        .dash => try self.parseSequenceEntry(),
        else => return ParseError.UnexpectedToken,
    }
}

fn parseMappingEntry(self: *Parser) ParserError!void {
    const mapping_id = try self.ensureContainer(.mapping, self.peek().span.start);
    try self.closePendingEmptyValue();

    const key_id = try self.parseScalar();
    self.skipTriviaNoNewline();
    if (self.peek().kind != .colon) return ParseError.UnexpectedToken;
    const colon = self.advance();

    {
        const parent = self.containerById(mapping_id);
        parent.pending_key = key_id;
        parent.pending_value_span = colon.span.end;
    }

    self.skipTriviaNoNewline();
    switch (self.peek().kind) {
        .scalar => {
            if (self.isMappingStart()) {
                const child_id = try self.openContainer(.mapping, self.peek().span.start);
                try self.parseMappingEntry();
                const id = try self.closeContainer(self.nodes.items[child_id].span.end);
                try self.finishValue(id);
            } else {
                const value_id = try self.parseScalar();
                try self.finishValue(value_id);
            }
        },
        .dash => {
            const child_id = try self.openContainer(.sequence, self.peek().span.start);
            try self.parseSequenceEntry();
            const id = try self.closeContainer(self.nodes.items[child_id].span.end);
            try self.finishValue(id);
        },
        .newline, .dedent, .end_of_file => {},
        else => return ParseError.UnexpectedToken,
    }
}

fn parseScalar(self: *Parser) ParserError!Document.Node.Id {
    if (self.peek().kind != .scalar) return ParseError.UnexpectedToken;
    const token = self.advance();
    return self.addNode(scalarKind(token.source(self.source)), token.span);
}

fn ensureContainer(self: *Parser, kind: ContainerKind, start: usize) ParserError!Document.Node.Id {
    if (!self.force_new_container and self.container_stack.items.len > 0) {
        const current = self.currentContainer();
        if (current.kind == kind) return current.id;
    }

    self.force_new_container = false;
    return self.openContainer(kind, start);
}

fn openContainer(self: *Parser, kind: ContainerKind, start: usize) ParserError!Document.Node.Id {
    const id = try self.addNode(switch (kind) {
        .sequence => .{ .sequence = null },
        .mapping => .{ .mapping = null },
    }, .init(start, start));

    try self.container_stack.append(self.allocator, .{
        .id = id,
        .kind = kind,
    });

    return id;
}

fn closeContainer(self: *Parser, span_end: usize) ParserError!Document.Node.Id {
    if (self.container_stack.items.len == 0) return ParseError.UnexpectedToken;
    const container = self.container_stack.pop().?;
    if (container.first_child == null) {
        self.nodes.items[container.id].span.end = span_end;
    }
    return container.id;
}

fn finishValue(self: *Parser, value_id: Document.Node.Id) ParserError!void {
    if (self.container_stack.items.len == 0) {
        self.root = value_id;
        return;
    }

    const parent = self.currentContainer();
    switch (parent.kind) {
        .sequence => {
            self.attachChild(parent, value_id);
            parent.pending_sequence_item_span = null;
        },
        .mapping => {
            const key_id = parent.pending_key orelse return ParseError.UnexpectedToken;
            parent.pending_key = null;

            const key_span = self.nodes.items[key_id].span;
            const value_span = self.nodes.items[value_id].span;
            const pair_id = try self.addNode(.{ .keyvalue = .{
                .key = key_id,
                .value = value_id,
            } }, .{
                .start = key_span.start,
                .end = value_span.end,
            });

            self.attachChild(parent, pair_id);
        },
    }
}

fn closePendingEmptyValue(self: *Parser) ParserError!void {
    if (self.container_stack.items.len == 0) return;

    const parent = self.currentContainer();
    switch (parent.kind) {
        .sequence => if (parent.pending_sequence_item_span) |span| {
            const value_id = try self.addNode(.null_, .init(span, span));
            try self.finishValue(value_id);
        },
        .mapping => if (parent.pending_key != null) {
            const value_id = try self.addNode(.null_, .init(parent.pending_value_span, parent.pending_value_span));
            try self.finishValue(value_id);
        },
    }
}

fn clearPendingSequenceItem(self: *Parser, sequence_id: Document.Node.Id) void {
    const parent = self.containerById(sequence_id);
    parent.pending_sequence_item_span = null;
}

fn attachChild(self: *Parser, parent: *OpenContainer, child_id: Document.Node.Id) void {
    if (parent.first_child) |_| {
        self.nodes.items[parent.last_child.?].next_sibling = child_id;
    } else {
        parent.first_child = child_id;
        switch (parent.kind) {
            .sequence => self.nodes.items[parent.id].kind = .{ .sequence = child_id },
            .mapping => self.nodes.items[parent.id].kind = .{ .mapping = child_id },
        }
    }

    parent.last_child = child_id;
    self.nodes.items[parent.id].span.end = self.nodes.items[child_id].span.end;
}

fn scalarKind(source: []const u8) Document.Node.Kind {
    if (std.mem.eql(u8, source, "null") or std.mem.eql(u8, source, "~")) return .null_;
    if (std.mem.eql(u8, source, "true") or std.mem.eql(u8, source, "false")) return .boolean;
    if (isNumber(source)) return .number;
    return .string;
}

// YAML tokenizer doesn't distinguish number tokens from other
// kinds like some other formats. So we need this lookahead
// function to see if a scalar is a number.
fn isNumber(source: []const u8) bool {
    if (source.len == 0) return false;

    var index: usize = 0;
    if (source[index] == '-') {
        index += 1;
        if (index == source.len) return false;
    }

    var digits: usize = 0;
    while (index < source.len and std.ascii.isDigit(source[index])) : (index += 1) {
        digits += 1;
    }
    if (digits == 0) return false;

    if (index < source.len and source[index] == '.') {
        index += 1;
        var fractional_digits: usize = 0;
        while (index < source.len and std.ascii.isDigit(source[index])) : (index += 1) {
            fractional_digits += 1;
        }
        if (fractional_digits == 0) return false;
    }

    return index == source.len;
}

fn isMappingStart(self: *const Parser) bool {
    if (self.peek().kind != .scalar) return false;

    var lookahead = self.index + 1;
    while (lookahead < self.tokens.len) : (lookahead += 1) {
        switch (self.tokens[lookahead].kind) {
            .whitespace, .comment => {},
            .colon => return true,
            else => return false,
        }
    }
    return false;
}

fn addNode(self: *Parser, kind: Document.Node.Kind, span: Span) ParserError!Document.Node.Id {
    const id: Document.Node.Id = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{
        .id = id,
        .kind = kind,
        .span = span,
        .next_sibling = null,
    });
    return id;
}

fn currentContainer(self: *Parser) *OpenContainer {
    return &self.container_stack.items[self.container_stack.items.len - 1];
}

fn containerById(self: *Parser, id: Document.Node.Id) *OpenContainer {
    for (self.container_stack.items) |*container| {
        if (container.id == id) return container;
    }
    unreachable;
}

fn skipTriviaNoNewline(self: *Parser) void {
    while (true) {
        switch (self.peek().kind) {
            .whitespace, .comment => _ = self.advance(),
            else => return,
        }
    }
}

fn peek(self: *const Parser) Token {
    return self.tokens[self.index];
}

fn advance(self: *Parser) Token {
    const token = self.tokens[self.index];
    self.index += 1;
    return token;
}

// =======
// Testing
// =======

fn testParser(input: []const u8, expected: Document) !void {
    const doc = try Parser.parse(testing.allocator, input, .v1_2);
    defer doc.deinit(testing.allocator);
    try testing.expect(expected.equals(doc));
}

test "simple YAML document" {
    try testParser(
        \\- hello: world
    , .{ .root = 0, .source =
        \\- hello: world
    , .nodes = &[_]Document.Node{
        .{ .id = 0, .kind = .{ .sequence = 1 }, .span = .{ .start = 0, .end = 14 }, .next_sibling = null },
        .{
            .id = 1,
            .kind = .{ .mapping = 4 },
            .span = .{ .start = 2, .end = 14 },
            .next_sibling = null,
        },
        .{
            .id = 2,
            .kind = .string,
            .span = .{ .start = 2, .end = 7 },
            .next_sibling = null,
        },
        .{
            .id = 3,
            .kind = .string,
            .span = .{ .start = 9, .end = 14 },
            .next_sibling = null,
        },
        .{
            .id = 4,
            .kind = .{ .keyvalue = .{ .key = 2, .value = 3 } },
            .span = .{ .start = 2, .end = 14 },
            .next_sibling = null,
        },
    } });
}

test "yaml flat mapping" {
    try testParser(
        "name: Ada\nage: 37\n",
        .{ .root = 0, .source = "name: Ada\nage: 37\n", .nodes = &[_]Document.Node{
            .{ .id = 0, .kind = .{ .mapping = 3 }, .span = .{ .start = 0, .end = 17 }, .next_sibling = null },
            .{ .id = 1, .kind = .string, .span = .{ .start = 0, .end = 4 }, .next_sibling = null },
            .{ .id = 2, .kind = .string, .span = .{ .start = 6, .end = 9 }, .next_sibling = null },
            .{ .id = 3, .kind = .{ .keyvalue = .{ .key = 1, .value = 2 } }, .span = .{ .start = 0, .end = 9 }, .next_sibling = 6 },
            .{ .id = 4, .kind = .string, .span = .{ .start = 10, .end = 13 }, .next_sibling = null },
            .{ .id = 5, .kind = .number, .span = .{ .start = 15, .end = 17 }, .next_sibling = null },
            .{ .id = 6, .kind = .{ .keyvalue = .{ .key = 4, .value = 5 } }, .span = .{ .start = 10, .end = 17 }, .next_sibling = null },
        } },
    );
}

test "yaml nested mapping" {
    try testParser(
        "root:\n  child: value\nnext: true\n",
        .{ .root = 0, .source = "root:\n  child: value\nnext: true\n", .nodes = &[_]Document.Node{
            .{ .id = 0, .kind = .{ .mapping = 6 }, .span = .{ .start = 0, .end = 31 }, .next_sibling = null },
            .{ .id = 1, .kind = .string, .span = .{ .start = 0, .end = 4 }, .next_sibling = null },
            .{ .id = 2, .kind = .{ .mapping = 5 }, .span = .{ .start = 8, .end = 20 }, .next_sibling = null },
            .{ .id = 3, .kind = .string, .span = .{ .start = 8, .end = 13 }, .next_sibling = null },
            .{ .id = 4, .kind = .string, .span = .{ .start = 15, .end = 20 }, .next_sibling = null },
            .{ .id = 5, .kind = .{ .keyvalue = .{ .key = 3, .value = 4 } }, .span = .{ .start = 8, .end = 20 }, .next_sibling = null },
            .{ .id = 6, .kind = .{ .keyvalue = .{ .key = 1, .value = 2 } }, .span = .{ .start = 0, .end = 20 }, .next_sibling = 9 },
            .{ .id = 7, .kind = .string, .span = .{ .start = 21, .end = 25 }, .next_sibling = null },
            .{ .id = 8, .kind = .boolean, .span = .{ .start = 27, .end = 31 }, .next_sibling = null },
            .{ .id = 9, .kind = .{ .keyvalue = .{ .key = 7, .value = 8 } }, .span = .{ .start = 21, .end = 31 }, .next_sibling = null },
        } },
    );
}
