//! The parser turns JSON tokens into a concrete syntax tree.
//! Depends on the tokenizer and the abstract Document struct

const std = @import("std");
const builtin = @import("builtin");
const AST = @import("../ast.zig");
const Document = @import("../document.zig");
const testing = std.testing;
const log = std.log.scoped(.parser);
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Type = @import("json.zig").Type;
const Token = @import("../token.zig").Token(@import("tokenizer.zig").Kind);
const Span = @import("../util/span.zig");

const Parser = @This();

const ContainerKind = enum { array, object };
/// Either an array or object in the process of being parsed.
const OpenContainer = struct {
    id: AST.Node.Id,
    kind: ContainerKind,
    first_child: ?AST.Node.Id = null,
    last_child: ?AST.Node.Id = null,
    pending_key: ?AST.Node.Id = null,
};

// State
state: State = .ExpectValue,
nodes: std.ArrayList(AST.Node) = .empty,
node_spans: std.ArrayList(Span) = .empty,
container_stack: std.ArrayList(OpenContainer) = .empty,

root: ?AST.Node.Id = null,

// Initial fields
allocator: std.mem.Allocator,

const ParseError = error{ UnclosedObject, UnclosedArray, UnclosedString, InvalidBool, InvalidNumber, UnexpectedToken };

const State = enum {
    ExpectValue,

    ExpectArrayValueOrEnd,
    ExpectArrayCommaOrEnd,

    ExpectObjectKeyOrEnd,
    ExpectObjectColon,
    ExpectObjectValue,
    ExpectObjectCommaOrEnd,

    ExpectEndOfFile,
};

/// Expects "true" or "false", translates to boolean
pub fn getBool(slice: []const u8) ParseError!bool {
    if (std.mem.eql(u8, slice, "true")) return true;
    if (std.mem.eql(u8, slice, "false")) return false;
    logErr("Tried to parse invalid value as boolean: `{s}`", .{slice});
    return error.InvalidBool;
}

/// Simply removes double quotes from a JSON string.
pub fn getString(slice: []const u8) ParseError![]const u8 {
    if (slice.len >= 2 and slice[0] == '"' and slice[slice.len - 1] == '"') {
        return slice[1 .. slice.len - 1];
    }
    logErr("Tried to parse invalid value as string: `{s}`", .{slice});
    return error.UnclosedString;
}

fn logErr(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.cpu.arch.isWasm()) {
        log.err(fmt, args);
    }
}

/// Returns lossless struct representation of a number
pub fn getNumber(slice: []const u8) ParseError!AST.Node.Kind.Number {
    var numDots: usize = 0;
    for (slice) |char| {
        if (char == '.') numDots += 1;
    }
    return .{ .raw = slice, .kind = switch (numDots) {
        0 => if (std.mem.indexOfAny(u8, slice, "eE") == null) .integer else .float,
        1 => .float,
        else => return error.InvalidNumber,
    } };
}

/// Main entry function
pub fn parseAbstract(allocator: std.mem.Allocator, input: []const u8, format: Type) !AST {
    const parsed = try parse(allocator, input, format);
    allocator.free(parsed.node_spans);
    return parsed.ast;
}

pub fn parse(allocator: std.mem.Allocator, input: []const u8, format: Type) !Document {
    var parser: Parser = .{ .allocator = allocator };
    defer parser.deinit();
    return parser.parse_once(input, format);
}

fn parse_once(self: *Parser, input: []const u8, kind: Type) !Document {
    var tokenizer: Tokenizer = .{
        .allocator = self.allocator,
        .str = input,
        .kind = kind,
    };

    const tokens = try tokenizer.tokenize();
    defer self.allocator.free(tokens);

    // Each Document.Node has an id, a kind, and a next_sibling ID.
    // We produce them from the tokens.

    //TODO: parse tokens
    for (tokens) |token| {
        if (token.kind == .whitespace) continue;
        if (token.kind == .comment) continue;

        switch (self.state) {
            .ExpectValue => {
                // TODO: update state
                switch (token.kind) {
                    .open_brace => {
                        const id = try self.addNode(.{ .mapping = null }, token.span);
                        try self.openContainer(.object, id);
                        self.state = .ExpectObjectKeyOrEnd;
                    },
                    .open_bracket => {
                        const id = try self.addNode(.{ .sequence = null }, token.span);
                        try self.openContainer(.array, id);
                        self.state = .ExpectArrayValueOrEnd;
                    },
                    .null_ => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .true_, .false_ => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .string => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .number => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },

            .ExpectArrayValueOrEnd => {
                switch (token.kind) {
                    .open_bracket => {
                        const id = try self.addNode(.{ .sequence = null }, token.span);
                        try self.openContainer(.array, id);
                        self.state = .ExpectArrayValueOrEnd;
                    },
                    .open_brace => {
                        const id = try self.addNode(.{ .mapping = null }, token.span);
                        try self.openContainer(.object, id);
                        self.state = .ExpectObjectKeyOrEnd;
                    },
                    .null_ => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .true_, .false_ => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .string => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .number => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .close_bracket => {
                        const id = try self.closeContainer(token.span.end);
                        try self.finishValue(id);
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },
            .ExpectArrayCommaOrEnd => {
                switch (token.kind) {
                    .close_bracket => {
                        const id = try self.closeContainer(token.span.end);
                        try self.finishValue(id);
                    },
                    .comma => {
                        self.state = .ExpectValue;
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },

            .ExpectObjectKeyOrEnd => {
                switch (token.kind) {
                    .string => {
                        const key_id = try self.addTokenNode(input, token);
                        const parent = &self.container_stack.items[self.container_stack.items.len - 1];
                        parent.pending_key = key_id;
                        self.state = .ExpectObjectColon;
                    },
                    .close_brace => {
                        const id = try self.closeContainer(token.span.end);
                        try self.finishValue(id);
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },
            .ExpectObjectColon => {
                switch (token.kind) {
                    .colon => {
                        self.state = .ExpectObjectValue;
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },
            .ExpectObjectValue => {
                switch (token.kind) {
                    .open_brace => {
                        const id = try self.addNode(.{ .mapping = null }, token.span);
                        try self.openContainer(.object, id);
                        self.state = .ExpectObjectKeyOrEnd;
                    },
                    .open_bracket => {
                        const id = try self.addNode(.{ .sequence = null }, token.span);
                        try self.openContainer(.array, id);
                        self.state = .ExpectArrayValueOrEnd;
                    },
                    .null_ => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .true_, .false_ => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .string => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    .number => {
                        const id = try self.addTokenNode(input, token);
                        try self.finishValue(id);
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },
            .ExpectObjectCommaOrEnd => {
                switch (token.kind) {
                    .close_brace => {
                        const id = try self.closeContainer(token.span.end);
                        try self.finishValue(id);
                    },
                    .comma => {
                        self.state = .ExpectObjectKeyOrEnd; // TODO: allow trailing comma?
                    },
                    else => return ParseError.UnexpectedToken,
                }
            },

            .ExpectEndOfFile => {
                switch (token.kind) {
                    .end_of_file => continue,
                    else => return ParseError.UnexpectedToken,
                }
            },
        }
    }

    // while loop completed.
    // Ready to return a Document!
    const nodes = try self.nodes.toOwnedSlice(self.allocator);
    self.nodes = .empty;
    const node_spans = try self.node_spans.toOwnedSlice(self.allocator);
    self.node_spans = .empty;
    return .{
        .source = input,
        .ast = .{
            .root = self.root orelse return ParseError.UnexpectedToken,
            .nodes = nodes,
        },
        .node_spans = node_spans,
    };
}

pub fn deinit(self: *Parser) void {
    self.container_stack.deinit(self.allocator);
    self.nodes.deinit(self.allocator);
    self.node_spans.deinit(self.allocator);
}

// ===============
// PARSING HELPERS
// ===============

/// Add an incomplete node to self.nodes. Called as soon as `[` or `{` is found.
fn addNode(self: *Parser, kind: AST.Node.Kind, span: Span) !AST.Node.Id {
    const id: AST.Node.Id = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{
        .id = id,
        .kind = kind,
        .next_sibling = null, // Update if there is a next sibling
    });
    try self.node_spans.append(self.allocator, span);
    return id;
}

fn addTokenNode(self: *Parser, input: []const u8, token: Token) !AST.Node.Id {
    return self.addNode(try tokenKind(input, token), token.span);
}

fn tokenKind(input: []const u8, token: Token) ParseError!AST.Node.Kind {
    const raw = token.source(input);
    return switch (token.kind) {
        .null_ => .null_,
        .true_, .false_ => .{ .boolean = try getBool(raw) },
        .string => .{ .string = try getString(raw) },
        .number => .{ .number = try getNumber(raw) },
        else => ParseError.UnexpectedToken,
    };
}

/// Attaches a completed child to the current open container.
fn attachChild(self: *Parser, parent: *OpenContainer, child_id: AST.Node.Id) void {
    if (parent.first_child != null) {
        self.nodes.items[parent.last_child.?].next_sibling = child_id;
    } else {
        parent.first_child = child_id;
        switch (parent.kind) {
            .array => self.nodes.items[parent.id].kind = .{ .sequence = child_id },
            .object => self.nodes.items[parent.id].kind = .{ .mapping = child_id },
        }
    }
    parent.last_child = child_id;
}

fn finishValue(self: *Parser, value_id: AST.Node.Id) !void {
    // If there is no parent, the parsing is complete
    if (self.container_stack.items.len == 0) {
        self.root = value_id;
        self.state = .ExpectEndOfFile;
        return;
    }

    const parent = &self.container_stack.items[self.container_stack.items.len - 1];

    switch (parent.kind) {
        .array => {
            self.attachChild(parent, value_id);
            self.state = .ExpectArrayCommaOrEnd;
        },
        .object => {
            const key_id = parent.pending_key orelse return ParseError.UnexpectedToken;
            parent.pending_key = null;

            const key_span = self.node_spans.items[key_id];
            const value_span = self.node_spans.items[value_id];
            const pair_id = try self.addNode(.{ .keyvalue = .{
                .key = key_id,
                .value = value_id,
            } }, .{
                .start = key_span.start,
                .end = value_span.end,
            });

            self.attachChild(parent, pair_id);
            self.state = .ExpectObjectCommaOrEnd;
        },
    }
}

/// Pushes stack metadata for a container node that already exists in self.nodes
fn openContainer(self: *Parser, kind: ContainerKind, node_id: AST.Node.Id) !void {
    try self.container_stack.append(self.allocator, .{
        .id = node_id,
        .kind = kind,
    });
}

/// Pops the current container, patches its span end, and returns the node ID.
fn closeContainer(self: *Parser, span_end: usize) !AST.Node.Id {
    if (self.container_stack.items.len == 0) return ParseError.UnexpectedToken;
    const container = self.container_stack.pop().?;
    self.node_spans.items[container.id].end = span_end;
    return container.id;
}

// =======
// Testing
// =======

fn testParser(input: []const u8, expected: AST) !void {
    const doc = try Parser.parseAbstract(testing.allocator, input, .JSON);
    defer testing.allocator.free(doc.nodes);
    try testing.expect(expected.eql(doc));
}

test "simple JSON document" {
    try testParser(
        \\[{"hello":"world"}]
    , .{ .root = 0, .nodes = &[_]AST.Node{
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
