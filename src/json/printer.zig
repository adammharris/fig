const Printer = @This();
const std = @import("std");
const AST = @import("../ast.zig");
const Writer = std.Io.Writer;

/// JSON cannot represent a YAML alias. A materialized AST contains none (aliases
/// are expanded to copied subtrees by `yaml.materialize`), so reaching one here
/// means an unmaterialized YAML AST was handed to the JSON printer.
pub const Error = Writer.Error || error{UnresolvedAlias};

/// Prints a given document in JSON format.
pub fn print(writer: *Writer, ast: *const AST) Error!void {
    try printNode(writer, ast, ast.root, 0);
    try writer.writeByte('\n');
    try writer.flush();
}

pub fn printNode(writer: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize) Error!void {
    const node = ast.nodes[id];
    switch (node.kind) {
        .null_ => try writer.writeAll("null"),
        .boolean => |value| try writer.writeAll(if (value) "true" else "false"),
        .number => |value| try writer.writeAll(value.raw),
        // JSON has no datetime type; emit the raw RFC-3339 text as a string.
        .datetime => |value| try writeJsonString(writer, value.raw),
        .string => |value| try writeJsonString(writer, value),
        .sequence => |first_child| try printSequence(writer, ast, first_child, depth),
        .mapping => |first_child| try printMapping(writer, ast, first_child, depth),
        .keyvalue => |kv| {
            try printNode(writer, ast, kv.key, depth);
            try writer.writeAll(": ");
            try printNode(writer, ast, kv.value, depth);
        },
        .alias => return error.UnresolvedAlias,
    }
}

fn printSequence(writer: *Writer, document: *const AST, first_child: ?AST.Node.Id, depth: usize) Error!void {
    if (first_child == null) {
        try writer.writeAll("[]");
        return;
    }

    try writer.writeAll("[\n");
    var current_id = first_child;
    while (current_id) |id| {
        try writeIndent(writer, depth + 1);
        try printNode(writer, document, id, depth + 1);
        current_id = document.nodes[id].next_sibling;
        if (current_id != null) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    try writeIndent(writer, depth);
    try writer.writeByte(']');
}

fn printMapping(writer: *Writer, document: *const AST, first_child: ?AST.Node.Id, depth: usize) Error!void {
    if (first_child == null) {
        try writer.writeAll("{}");
        return;
    }

    try writer.writeAll("{\n");
    var current_id = first_child;
    while (current_id) |id| {
        try writeIndent(writer, depth + 1);
        try printNode(writer, document, id, depth + 1);
        current_id = document.nodes[id].next_sibling;
        if (current_id != null) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    try writeIndent(writer, depth);
    try writer.writeByte('}');
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

fn writeIndent(writer: *Writer, depth: usize) Writer.Error!void {
    for (0..depth) |_| try writer.writeAll("  ");
}

test "prints JSON document" {
    const Parser = @import("parser.zig");
    const input = "{\"name\":\"Ada\",\"tags\":[\"zig\",true,null]}";
    var doc = try Parser.parseAbstract(std.testing.allocator, input, .JSON);
    defer doc.deinit();

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try print(&output.writer, &doc);
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
