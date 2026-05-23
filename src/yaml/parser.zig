//! The parser turns YAML tokens into a concrete syntax tree.
//! Depends on the tokenizer and the abstract Document struct.

const std = @import("std");
const Document = @import("../document.zig");
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
    pending_sequence_item: bool = false,
    continues_sequence_item: bool = false,
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
                if (self.container_stack.items.len > 0 and self.currentContainer().continues_sequence_item) {
                    self.currentContainer().continues_sequence_item = false;
                } else {
                    self.force_new_container = true;
                }
                _ = self.advance();
            },
            .dedent => {
                try self.closePendingEmptyValue();
                const id = try self.closeContainer();
                _ = self.advance();
                try self.finishValue(id);
            },
            .newline => _ = self.advance(),
            .dash => {
                try self.closeSequenceItemContinuation();
                try self.parseSequenceEntry();
            },
            .scalar => {
                try self.closeSequenceItemContinuation();
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
        const id = try self.closeContainer();
        try self.finishValue(id);
    }

    const root = self.root orelse return ParseError.EmptyDocument;
    const nodes = try self.nodes.toOwnedSlice(self.allocator);
    self.nodes = .empty;
    return .{
        .root = root,
        .nodes = nodes,
    };
}

pub fn deinit(self: *Parser) void {
    self.container_stack.deinit(self.allocator);
    self.nodes.deinit(self.allocator);
}

fn parseSequenceEntry(self: *Parser) ParserError!void {
    _ = self.advance();
    const sequence_id = try self.ensureContainer(.sequence);
    self.clearPendingSequenceItem(sequence_id);
    self.skipTriviaNoNewline();

    switch (self.peek().kind) {
        .newline, .dedent, .end_of_file => {
            self.currentContainer().pending_sequence_item = true;
        },
        .scalar => {
            if (self.isMappingStart()) {
                const mapping_id = try self.openContainer(.mapping);
                self.containerById(mapping_id).continues_sequence_item = true;
                try self.parseMappingEntry();
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
    const mapping_id = try self.ensureContainer(.mapping);
    try self.closePendingEmptyValue();

    const key_id = try self.parseScalar();
    self.skipTriviaNoNewline();
    if (self.peek().kind != .colon) return ParseError.UnexpectedToken;
    _ = self.advance();

    {
        const parent = self.containerById(mapping_id);
        parent.pending_key = key_id;
    }

    self.skipTriviaNoNewline();
    switch (self.peek().kind) {
        .scalar => {
            if (self.isMappingStart()) {
                _ = try self.openContainer(.mapping);
                try self.parseMappingEntry();
                const id = try self.closeContainer();
                try self.finishValue(id);
            } else {
                const value_id = try self.parseScalar();
                try self.finishValue(value_id);
            }
        },
        .dash => {
            _ = try self.openContainer(.sequence);
            try self.parseSequenceEntry();
            const id = try self.closeContainer();
            try self.finishValue(id);
        },
        .newline, .dedent, .end_of_file => {},
        else => return ParseError.UnexpectedToken,
    }
}

fn parseScalar(self: *Parser) ParserError!Document.Node.Id {
    if (self.peek().kind != .scalar) return ParseError.UnexpectedToken;
    const token = self.advance();
    return self.addNode(try scalarKind(token.source(self.source)));
}

fn ensureContainer(self: *Parser, kind: ContainerKind) ParserError!Document.Node.Id {
    if (!self.force_new_container and self.container_stack.items.len > 0) {
        const current = self.currentContainer();
        if (current.kind == kind) return current.id;
    }

    self.force_new_container = false;
    return self.openContainer(kind);
}

fn openContainer(self: *Parser, kind: ContainerKind) ParserError!Document.Node.Id {
    const id = try self.addNode(switch (kind) {
        .sequence => .{ .sequence = null },
        .mapping => .{ .mapping = null },
    });

    try self.container_stack.append(self.allocator, .{
        .id = id,
        .kind = kind,
    });

    return id;
}

fn closeContainer(self: *Parser) ParserError!Document.Node.Id {
    if (self.container_stack.items.len == 0) return ParseError.UnexpectedToken;
    const container = self.container_stack.pop().?;
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
            parent.pending_sequence_item = false;
        },
        .mapping => {
            const key_id = parent.pending_key orelse return ParseError.UnexpectedToken;
            parent.pending_key = null;

            const pair_id = try self.addNode(.{ .keyvalue = .{
                .key = key_id,
                .value = value_id,
            } });

            self.attachChild(parent, pair_id);
        },
    }
}

fn closePendingEmptyValue(self: *Parser) ParserError!void {
    if (self.container_stack.items.len == 0) return;

    const parent = self.currentContainer();
    switch (parent.kind) {
        .sequence => if (parent.pending_sequence_item) {
            const value_id = try self.addNode(.null_);
            try self.finishValue(value_id);
        },
        .mapping => if (parent.pending_key != null) {
            const value_id = try self.addNode(.null_);
            try self.finishValue(value_id);
        },
    }
}

fn closeSequenceItemContinuation(self: *Parser) ParserError!void {
    if (self.container_stack.items.len == 0) return;
    if (!self.currentContainer().continues_sequence_item) return;

    self.currentContainer().continues_sequence_item = false;
    try self.closePendingEmptyValue();
    const id = try self.closeContainer();
    try self.finishValue(id);
}

fn clearPendingSequenceItem(self: *Parser, sequence_id: Document.Node.Id) void {
    const parent = self.containerById(sequence_id);
    parent.pending_sequence_item = false;
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
}

fn scalarKind(source: []const u8) ParserError!Document.Node.Kind {
    if (std.mem.eql(u8, source, "{}")) return .{ .mapping = null };
    if (std.mem.eql(u8, source, "[]")) return .{ .sequence = null };
    if (std.mem.eql(u8, source, "null") or std.mem.eql(u8, source, "~")) return .null_;
    if (std.mem.eql(u8, source, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, source, "false")) return .{ .boolean = false };
    if (isNumber(source)) return .{ .number = .{
        .raw = source,
        .kind = if (std.mem.indexOfScalar(u8, source, '.') == null) .integer else .float,
    } };
    return .{ .string = source };
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

fn addNode(self: *Parser, kind: Document.Node.Kind) ParserError!Document.Node.Id {
    const id: Document.Node.Id = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{
        .id = id,
        .kind = kind,
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
    try testing.expect(expected.eql(doc));
}

test "simple YAML document" {
    try testParser(
        \\- hello: world
    , .{ .root = 0, .nodes = &[_]Document.Node{
        .{ .id = 0, .kind = .{ .sequence = 1 }, .next_sibling = null },
        .{
            .id = 1,
            .kind = .{ .mapping = 4 },
            .next_sibling = null,
        },
        .{
            .id = 2,
            .kind = .{ .string = "hello" },
            .next_sibling = null,
        },
        .{
            .id = 3,
            .kind = .{ .string = "world" },
            .next_sibling = null,
        },
        .{
            .id = 4,
            .kind = .{ .keyvalue = .{ .key = 2, .value = 3 } },
            .next_sibling = null,
        },
    } });
}

test "yaml flat mapping" {
    try testParser(
        "name: Ada\nage: 37\n",
        .{ .root = 0, .nodes = &[_]Document.Node{
            .{ .id = 0, .kind = .{ .mapping = 3 }, .next_sibling = null },
            .{ .id = 1, .kind = .{ .string = "name" }, .next_sibling = null },
            .{ .id = 2, .kind = .{ .string = "Ada" }, .next_sibling = null },
            .{ .id = 3, .kind = .{ .keyvalue = .{ .key = 1, .value = 2 } }, .next_sibling = 6 },
            .{ .id = 4, .kind = .{ .string = "age" }, .next_sibling = null },
            .{ .id = 5, .kind = .{ .number = .{ .raw = "37", .kind = .integer } }, .next_sibling = null },
            .{ .id = 6, .kind = .{ .keyvalue = .{ .key = 4, .value = 5 } }, .next_sibling = null },
        } },
    );
}

test "yaml nested mapping" {
    try testParser(
        "root:\n  child: value\nnext: true\n",
        .{ .root = 0, .nodes = &[_]Document.Node{
            .{ .id = 0, .kind = .{ .mapping = 6 }, .next_sibling = null },
            .{ .id = 1, .kind = .{ .string = "root" }, .next_sibling = null },
            .{ .id = 2, .kind = .{ .mapping = 5 }, .next_sibling = null },
            .{ .id = 3, .kind = .{ .string = "child" }, .next_sibling = null },
            .{ .id = 4, .kind = .{ .string = "value" }, .next_sibling = null },
            .{ .id = 5, .kind = .{ .keyvalue = .{ .key = 3, .value = 4 } }, .next_sibling = null },
            .{ .id = 6, .kind = .{ .keyvalue = .{ .key = 1, .value = 2 } }, .next_sibling = 9 },
            .{ .id = 7, .kind = .{ .string = "next" }, .next_sibling = null },
            .{ .id = 8, .kind = .{ .boolean = true }, .next_sibling = null },
            .{ .id = 9, .kind = .{ .keyvalue = .{ .key = 7, .value = 8 } }, .next_sibling = null },
        } },
    );
}

test "yaml sequence item mapping continuation" {
    const input =
        \\- adapter: CodeLLDB
        \\  label: Debug library tests
        \\  build:
        \\    command: zig
        \\    args:
        \\      - build
        \\      - install-tests
        \\
    ;

    const doc = try Parser.parse(testing.allocator, input, .v1_2);
    defer doc.deinit(testing.allocator);

    const label = try doc.getValByPath(&.{
        .{ .index = 0 },
        .{ .key = "label" },
    });
    try testing.expectEqualSlices(u8, "Debug library tests", label.kind.string);

    const build = try doc.getValByPath(&.{
        .{ .index = 0 },
        .{ .key = "build" },
    });
    try testing.expect(std.meta.activeTag(build.kind) == .mapping);

    var args_pair_id = build.kind.mapping.?;
    while (!std.mem.eql(u8, "args", doc.nodes[doc.nodes[args_pair_id].kind.keyvalue.key].kind.string)) {
        args_pair_id = doc.nodes[args_pair_id].next_sibling orelse return error.NotFound;
    }

    const args = doc.nodes[doc.nodes[args_pair_id].kind.keyvalue.value];
    try testing.expect(std.meta.activeTag(args.kind) == .sequence);
    const first_arg_id = args.kind.sequence.?;
    const second_arg = doc.nodes[doc.nodes[first_arg_id].next_sibling.?];
    try testing.expectEqualSlices(u8, "install-tests", second_arg.kind.string);
}

test "yaml empty flow collection scalars" {
    const doc = try Parser.parse(testing.allocator, "env: {}\ntags: []\n", .v1_2);
    defer doc.deinit(testing.allocator);

    const env = try doc.getValByPath(&.{.{ .key = "env" }});
    try testing.expectEqual(@as(?Document.Node.Id, null), env.kind.mapping);

    const tags = try doc.getValByPath(&.{.{ .key = "tags" }});
    try testing.expectEqual(@as(?Document.Node.Id, null), tags.kind.sequence);
}
