const Printer = @This();
const std = @import("std");
const AST = @import("../ast.zig");
const Writer = std.Io.Writer;

/// JSON cannot represent a YAML alias. A materialized AST contains none (aliases
/// are expanded to copied subtrees by `yaml.materialize`), so reaching one here
/// means an unmaterialized YAML AST was handed to the JSON printer.
pub const Error = Writer.Error || error{UnresolvedAlias};

writer: *Writer,
ast: *const AST,
options: AST.SerializeOptions,

/// Prints a given document in JSON format.
pub fn print(writer: *Writer, ast: *const AST, options: AST.SerializeOptions) Error!void {
    var p: Printer = .{ .writer = writer, .ast = ast, .options = options };
    try p.node(ast.root, 0);
    try writer.writeByte('\n');
    try writer.flush();
}

/// Prints the subtree rooted at `id`. Used for partial renders; unlike `print`
/// it adds no trailing newline and does not flush.
pub fn printNode(writer: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize, options: AST.SerializeOptions) Error!void {
    var p: Printer = .{ .writer = writer, .ast = ast, .options = options };
    try p.node(id, depth);
}

fn node(self: *Printer, id: AST.Node.Id, depth: usize) Error!void {
    const n = self.ast.nodes[id];
    switch (n.kind) {
        .null_ => try self.writer.writeAll("null"),
        .boolean => |value| try self.writer.writeAll(if (value) "true" else "false"),
        .number => |value| try self.writer.writeAll(value.raw),
        // JSON has none of these types. Datetimes and enum literals render as
        // strings (the timestamp / the bare name); a char literal renders as its
        // codepoint number.
        .extended => |value| switch (value.kind) {
            .char_literal => try self.writer.writeAll(value.text),
            else => try writeJsonString(self.writer, value.text),
        },
        .string => |value| try writeJsonString(self.writer, value),
        .sequence => |first_child| try self.sequence(first_child, depth),
        .mapping => |first_child| try self.mapping(first_child, depth),
        .keyvalue => |kv| {
            try self.node(kv.key, depth);
            // Compact output omits the space after the colon.
            try self.writer.writeAll(if (self.options.pretty) ": " else ":");
            try self.node(kv.value, depth);
        },
        .alias => return error.UnresolvedAlias,
    }
}

fn sequence(self: *Printer, first_child: ?AST.Node.Id, depth: usize) Error!void {
    try self.container('[', ']', first_child, depth);
}

fn mapping(self: *Printer, first_child: ?AST.Node.Id, depth: usize) Error!void {
    try self.container('{', '}', first_child, depth);
}

/// Sequences and mappings differ only in their delimiters and in how each child
/// renders (a bare node vs. a `key: value`), the latter dispatched by `node`.
fn container(self: *Printer, open: u8, close: u8, first_child: ?AST.Node.Id, depth: usize) Error!void {
    if (first_child == null) {
        try self.writer.writeByte(open);
        try self.writer.writeByte(close);
        return;
    }

    const pretty = self.options.pretty;
    try self.writer.writeByte(open);
    if (pretty) try self.writer.writeByte('\n');

    var current_id = first_child;
    while (current_id) |id| {
        if (pretty) try self.writeIndent(depth + 1);
        try self.node(id, depth + 1);
        current_id = self.ast.nodes[id].next_sibling;
        if (current_id != null) try self.writer.writeByte(',');
        if (pretty) try self.writer.writeByte('\n');
    }

    if (pretty) try self.writeIndent(depth);
    try self.writer.writeByte(close);
}

fn writeIndent(self: *Printer, depth: usize) Writer.Error!void {
    for (0..depth * self.options.indent) |_| try self.writer.writeByte(' ');
}

fn writeJsonString(writer: *Writer, value: []const u8) Writer.Error!void {
    try writer.writeByte('"');
    for (value) |char| {
        switch (char) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x07, 0x0b, 0x0e...0x1f => try writeControlEscape(writer, char),
            else => try writer.writeByte(char),
        }
    }
    try writer.writeByte('"');
}

fn writeControlEscape(writer: *Writer, char: u8) Writer.Error!void {
    const hex = "0123456789abcdef";
    try writer.writeAll("\\u00");
    try writer.writeByte(hex[char >> 4]);
    try writer.writeByte(hex[char & 0x0f]);
}

test "prints JSON document" {
    const Parser = @import("parser.zig");
    const input = "{\"name\":\"Ada\",\"tags\":[\"zig\",true,null]}";
    var doc = try Parser.parseAbstract(std.testing.allocator, input, .JSON);
    defer doc.deinit();

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try print(&output.writer, &doc, .{});
    try std.testing.expectEqualSlices(u8,
        \\{
        \\  "name": "Ada",
        \\  "tags": [
        \\    "zig",
        \\    true,
        \\    null
        \\  ]
        \\}
        \\
    , output.written());
}

test "prints compact JSON document" {
    const Parser = @import("parser.zig");
    const input = "{\"name\":\"Ada\",\"tags\":[\"zig\",true,null],\"empty\":{}}";
    var doc = try Parser.parseAbstract(std.testing.allocator, input, .JSON);
    defer doc.deinit();

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try print(&output.writer, &doc, .{ .pretty = false });
    try std.testing.expectEqualSlices(u8,
        \\{"name":"Ada","tags":["zig",true,null],"empty":{}}
        \\
    , output.written());
}

test "honors custom indent width" {
    const Parser = @import("parser.zig");
    const input = "{\"a\":[1]}";
    var doc = try Parser.parseAbstract(std.testing.allocator, input, .JSON);
    defer doc.deinit();

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try print(&output.writer, &doc, .{ .indent = 4 });
    try std.testing.expectEqualSlices(u8,
        \\{
        \\    "a": [
        \\        1
        \\    ]
        \\}
        \\
    , output.written());
}
