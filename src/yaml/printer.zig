const Printer = @This();
const std = @import("std");
const AST = @import("../ast.zig");
const Writer = std.Io.Writer;

/// Prints a given document in YAML block format.
pub fn print(writer: *Writer, ast: *const AST) Writer.Error!void {
    try printNode(writer, ast, ast.root, 0);
    try writer.flush();
}

pub fn printNode(writer: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize) Writer.Error!void {
    const node = ast.nodes[id];
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
        .datetime => |value| {
            // YAML's core schema has no timestamp type (that was YAML 1.1);
            // emit the raw text as a plain scalar.
            try writer.writeAll(value.raw);
            try writer.writeByte('\n');
        },
        .string => |value| {
            try printScalar(writer, value);
            try writer.writeByte('\n');
        },
        .sequence => |first_child| try printSequence(writer, ast, first_child, depth),
        .mapping => |first_child| try printMapping(writer, ast, first_child, depth),
        .keyvalue => |kv| try printKeyValue(writer, ast, kv, depth),
        .alias => |name| {
            try writer.writeByte('*');
            try writer.writeAll(name);
            try writer.writeByte('\n');
        },
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
    try writeProps(writer, document, kv.key); // `&k key:` / `!!str key:`
    try printScalar(writer, document.nodes[kv.key].kind.string);
    switch (value.kind) {
        .mapping => |child| {
            try writer.writeByte(':');
            try writePropsAfterColon(writer, document, kv.value); // `: &a` before the block
            if (child == null) {
                try writer.writeAll(" {}\n");
            } else {
                try writer.writeByte('\n');
                try printMapping(writer, document, child, depth + 1);
            }
        },
        .sequence => |child| {
            try writer.writeByte(':');
            try writePropsAfterColon(writer, document, kv.value);
            if (child == null) {
                try writer.writeAll(" []\n");
            } else {
                try writer.writeByte('\n');
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
    try writeProps(writer, document, id);
    switch (node.kind) {
        .null_ => try writer.writeAll("null"),
        .boolean => |value| try writer.writeAll(if (value) "true" else "false"),
        .number => |value| try writer.writeAll(value.raw),
        .datetime => |value| try writer.writeAll(value.raw),
        .string => |value| try printScalar(writer, value),
        .sequence => |child| if (child == null) try writer.writeAll("[]") else try writer.writeAll("[...]"),
        .mapping => |child| if (child == null) try writer.writeAll("{}") else try writer.writeAll("{...}"),
        .alias => |name| {
            try writer.writeByte('*');
            try writer.writeAll(name);
        },
        .keyvalue => unreachable,
    }
}

/// Emit a node's anchor/tag properties (`&name `, `!tag `) from the AST
/// side-tables, so a full reserialize keeps the reference layer intact (an
/// anchored value stays anchored, rather than leaving any alias to it dangling).
/// Order matches YAML's `c-ns-properties`: anchor then tag, both optional.
fn writeProps(writer: *Writer, ast: *const AST, id: AST.Node.Id) Writer.Error!void {
    if (id < ast.node_anchors.len) if (ast.node_anchors[id]) |name| {
        try writer.writeByte('&');
        try writer.writeAll(name);
        try writer.writeByte(' ');
    };
    if (id < ast.node_tags.len) if (ast.node_tags[id]) |tag| {
        try writer.writeAll(tag);
        try writer.writeByte(' ');
    };
}

/// Like `writeProps` but for the position right after a mapping value's `:`,
/// before a block collection or `{}`/`[]`: emits ` &name`/` !tag` with a leading
/// (not trailing) space, so `key:` becomes `key: &a` and a propless value keeps
/// its original `key:` / `key: {}` framing.
fn writePropsAfterColon(writer: *Writer, ast: *const AST, id: AST.Node.Id) Writer.Error!void {
    if (id < ast.node_anchors.len) if (ast.node_anchors[id]) |name| {
        try writer.writeAll(" &");
        try writer.writeAll(name);
    };
    if (id < ast.node_tags.len) if (ast.node_tags[id]) |tag| {
        try writer.writeByte(' ');
        try writer.writeAll(tag);
    };
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
    var doc = try Parser.parseAbstract(std.testing.allocator, input, .JSON);
    defer doc.deinit();

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
