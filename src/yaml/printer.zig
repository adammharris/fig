const Printer = @This();
const std = @import("std");
const AST = @import("../ast.zig");
const Writer = std.Io.Writer;

/// Prints a given document in YAML block format.
pub fn print(writer: *Writer, document: *const AST) Writer.Error!void {
    try printNode(writer, document, document.root, 0);
    try writer.flush();
}

fn printNode(writer: *Writer, document: *const AST, id: AST.Node.Id, depth: usize) Writer.Error!void {
    const node = document.nodes[id];
    switch (node.kind) {
        .null_ => try writer.writeAll("null\n"),
        .boolean => |value| {
            try writer.writeAll(if (value) "true" else "false");
            try writer.writeByte('\n');
        },
        .number => |value| {
            try writer.writeAll(value.raw);
            try writer.writeByte('\n');
        },
        .string => |value| {
            try printScalar(writer, value);
            try writer.writeByte('\n');
        },
        .sequence => |first_child| try printSequence(writer, document, first_child, depth),
        .mapping => |first_child| try printMapping(writer, document, first_child, depth),
        .keyvalue => |kv| try printKeyValue(writer, document, kv, depth),
    }
}

fn printSequence(writer: *Writer, document: *const AST, first_child: ?AST.Node.Id, depth: usize) Writer.Error!void {
    if (first_child == null) {
        try writer.writeAll("[]\n");
        return;
    }

    var current_id = first_child;
    while (current_id) |id| {
        const item = document.nodes[id];
        try writeIndent(writer, depth);
        switch (item.kind) {
            .mapping => |child| {
                try writer.writeAll("- ");
                if (child) |first_pair| {
                    try printSequenceMapping(writer, document, first_pair, depth);
                } else {
                    try writer.writeAll("{}\n");
                }
            },
            .sequence => |child| {
                try writer.writeAll("- ");
                if (child == null) {
                    try writer.writeAll("[]\n");
                } else {
                    try writer.writeByte('\n');
                    try printSequence(writer, document, child, depth + 1);
                }
            },
            else => {
                try writer.writeAll("- ");
                try printInlineValue(writer, document, id);
                try writer.writeByte('\n');
            },
        }
        current_id = item.next_sibling;
    }
}

fn printMapping(writer: *Writer, document: *const AST, first_child: ?AST.Node.Id, depth: usize) Writer.Error!void {
    if (first_child == null) {
        try writer.writeAll("{}\n");
        return;
    }

    var current_id = first_child;
    while (current_id) |id| {
        try printKeyValue(writer, document, document.nodes[id].kind.keyvalue, depth);
        current_id = document.nodes[id].next_sibling;
    }
}

fn printSequenceMapping(writer: *Writer, document: *const AST, first_pair: AST.Node.Id, depth: usize) Writer.Error!void {
    try printKeyValue(writer, document, document.nodes[first_pair].kind.keyvalue, 0);

    var current_id = document.nodes[first_pair].next_sibling;
    while (current_id) |id| {
        try printKeyValue(writer, document, document.nodes[id].kind.keyvalue, depth + 1);
        current_id = document.nodes[id].next_sibling;
    }
}

fn printKeyValue(writer: *Writer, document: *const AST, kv: anytype, depth: usize) Writer.Error!void {
    const value = document.nodes[kv.value];
    try writeIndent(writer, depth);
    try printScalar(writer, document.nodes[kv.key].kind.string);
    switch (value.kind) {
        .mapping => |child| {
            if (child == null) {
                try writer.writeAll(": {}\n");
            } else {
                try writer.writeAll(":\n");
                try printMapping(writer, document, child, depth + 1);
            }
        },
        .sequence => |child| {
            if (child == null) {
                try writer.writeAll(": []\n");
            } else {
                try writer.writeAll(":\n");
                try printSequence(writer, document, child, depth + 1);
            }
        },
        else => {
            try writer.writeAll(": ");
            try printInlineValue(writer, document, kv.value);
            try writer.writeByte('\n');
        },
    }
}

fn printInlineValue(writer: *Writer, document: *const AST, id: AST.Node.Id) Writer.Error!void {
    const node = document.nodes[id];
    switch (node.kind) {
        .null_ => try writer.writeAll("null"),
        .boolean => |value| try writer.writeAll(if (value) "true" else "false"),
        .number => |value| try writer.writeAll(value.raw),
        .string => |value| try printScalar(writer, value),
        .sequence => |child| if (child == null) try writer.writeAll("[]") else try writer.writeAll("[...]"),
        .mapping => |child| if (child == null) try writer.writeAll("{}") else try writer.writeAll("{...}"),
        .keyvalue => unreachable,
    }
}

fn printScalar(writer: *Writer, raw: []const u8) Writer.Error!void {
    try writer.writeAll(raw);
}

fn writeIndent(writer: *Writer, depth: usize) Writer.Error!void {
    for (0..depth) |_| try writer.writeAll("  ");
}

test "prints YAML document" {
    const Parser = @import("../json/parser.zig");
    const input = "{\"name\":\"Ada\",\"tags\":[\"zig\",true,null]}";
    const doc = try Parser.parseAbstract(std.testing.allocator, input, .JSON);
    defer std.testing.allocator.free(doc.nodes);

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try print(&output.writer, &doc);
    try std.testing.expectEqualSlices(u8,
        \\name: Ada
        \\tags:
        \\  - zig
        \\  - true
        \\  - null
        \\
    , output.written());
}
