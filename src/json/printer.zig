const Printer = @This();
const std = @import("std");
const AST = @import("../ast.zig");
const Writer = std.Io.Writer;

/// Prints a given document in JSON format.
pub fn print(writer: *Writer, document: *const AST) Writer.Error!void {
    try printNode(writer, document, document.root, 0);
    try writer.writeByte('\n');
    try writer.flush();
}

fn printNode(writer: *Writer, document: *const AST, id: AST.Node.Id, depth: usize) Writer.Error!void {
    const node = document.nodes[id];
    switch (node.kind) {
        .null_ => try writer.writeAll("null"),
        .boolean => |value| try writer.writeAll(if (value) "true" else "false"),
        .number => |value| try writer.writeAll(value.raw),
        .string => |value| try writeJsonString(writer, value),
        .sequence => |first_child| try printSequence(writer, document, first_child, depth),
        .mapping => |first_child| try printMapping(writer, document, first_child, depth),
        .keyvalue => |kv| {
            try printNode(writer, document, kv.key, depth);
            try writer.writeAll(": ");
            try printNode(writer, document, kv.value, depth);
        },
    }
}

fn printSequence(writer: *Writer, document: *const AST, first_child: ?AST.Node.Id, depth: usize) Writer.Error!void {
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

fn printMapping(writer: *Writer, document: *const AST, first_child: ?AST.Node.Id, depth: usize) Writer.Error!void {
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
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(char),
        }
    }
    try writer.writeByte('"');
}

fn writeIndent(writer: *Writer, depth: usize) Writer.Error!void {
    for (0..depth) |_| try writer.writeAll("  ");
}

test "prints JSON document" {
    const Parser = @import("parser.zig");
    const input = "{\"name\":\"Ada\",\"tags\":[\"zig\",true,null]}";
    const doc = try Parser.parseAbstract(std.testing.allocator, input, .JSON);
    defer std.testing.allocator.free(doc.nodes);

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
