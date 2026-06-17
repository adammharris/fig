//! ZON printer: renders a fig AST as Zig Object Notation.
//!
//! Container literals use `.{ ... }` with trailing commas (idiomatic ZON, as
//! `zig fmt` would produce). Struct field names are emitted bare (`.name`) when
//! they form a legal Zig identifier, otherwise quoted (`.@"name"`).
//!
//! Native ZON scalars carried as `extended` nodes round-trip exactly: an
//! `enum_literal` re-emits as `.name` (or `.@"name"`), a `char_literal` as `'a'`
//! (re-encoded from its stored codepoint). A datetime `extended` node (only
//! produced by TOML) has no ZON form, so it falls back to a quoted string.
//!
//! Best-effort, niche output:
//!   * `number.raw` is emitted verbatim. When the AST came from ZON that is
//!     always valid; values minted by other formats are assumed decimal.

const Printer = @This();
const std = @import("std");
const AST = @import("../ast.zig");
const Writer = std.Io.Writer;

/// ZON cannot represent a YAML alias (materialize expands them first) nor a
/// non-string struct-field key.
pub const Error = Writer.Error || error{ UnresolvedAlias, NonStringKey };

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
        .string => |value| try writeString(writer, value),
        .extended => |ext| try writeExtended(writer, ext),
        .sequence => |first_child| try printSequence(writer, ast, first_child, depth),
        .mapping => |first_child| try printMapping(writer, ast, first_child, depth),
        .keyvalue => |kv| {
            try writeFieldName(writer, ast, kv.key);
            try writer.writeAll(" = ");
            try printNode(writer, ast, kv.value, depth);
        },
        .alias => return error.UnresolvedAlias,
    }
}

fn printSequence(writer: *Writer, ast: *const AST, first_child: ?AST.Node.Id, depth: usize) Error!void {
    if (first_child == null) {
        try writer.writeAll(".{}");
        return;
    }
    try writer.writeAll(".{\n");
    var current = first_child;
    while (current) |id| {
        try writeIndent(writer, depth + 1);
        try printNode(writer, ast, id, depth + 1);
        try writer.writeAll(",\n");
        current = ast.nodes[id].next_sibling;
    }
    try writeIndent(writer, depth);
    try writer.writeByte('}');
}

fn printMapping(writer: *Writer, ast: *const AST, first_child: ?AST.Node.Id, depth: usize) Error!void {
    if (first_child == null) {
        try writer.writeAll(".{}");
        return;
    }
    try writer.writeAll(".{\n");
    var current = first_child;
    while (current) |id| {
        try writeIndent(writer, depth + 1);
        try printNode(writer, ast, id, depth + 1);
        try writer.writeAll(",\n");
        current = ast.nodes[id].next_sibling;
    }
    try writeIndent(writer, depth);
    try writer.writeByte('}');
}

/// Emit a struct field name: `.name` if it's a bare identifier, else `.@"..."`.
fn writeFieldName(writer: *Writer, ast: *const AST, key_id: AST.Node.Id) Error!void {
    const name = switch (ast.nodes[key_id].kind) {
        .string => |s| s,
        else => return error.NonStringKey, // ZON field names must derive from a string key
    };
    try writeDotName(writer, name);
}

/// Render an `extended` scalar back to ZON. Enum and char literals reproduce
/// their source form; a datetime (TOML-only) has no ZON type, so it degrades to
/// a quoted string.
fn writeExtended(writer: *Writer, ext: AST.Node.Kind.Extended) Error!void {
    switch (ext.kind) {
        .enum_literal => try writeDotName(writer, ext.text),
        .char_literal => try writeCharLiteral(writer, ext.text),
        else => try writeString(writer, ext.text),
    }
}

/// Emit a dotted name (`.name` or `.@"..."`) — shared by struct field names and
/// enum literals, which have identical lexical rules.
fn writeDotName(writer: *Writer, name: []const u8) Error!void {
    try writer.writeByte('.');
    if (isBareIdentifier(name)) {
        try writer.writeAll(name);
    } else {
        try writer.writeAll("@\"");
        try writeStringInner(writer, name);
        try writer.writeByte('"');
    }
}

/// Re-encode a char literal from its stored decimal codepoint. Common escapes
/// and printable ASCII emit directly; anything else uses `'\u{...}'`. A codepoint
/// that fails to parse (only if minted oddly by another format) falls back to its
/// numeric text, which is still valid ZON.
fn writeCharLiteral(writer: *Writer, text: []const u8) Error!void {
    const cp = std.fmt.parseInt(u21, text, 10) catch return writer.writeAll(text);
    try writer.writeByte('\'');
    switch (cp) {
        '\'' => try writer.writeAll("\\'"),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x20...0x26, 0x28...0x5b, 0x5d...0x7e => try writer.writeByte(@intCast(cp)),
        else => try writer.print("\\u{{{x}}}", .{cp}),
    }
    try writer.writeByte('\'');
}

fn writeString(writer: *Writer, value: []const u8) Writer.Error!void {
    try writer.writeByte('"');
    try writeStringInner(writer, value);
    try writer.writeByte('"');
}

fn writeStringInner(writer: *Writer, value: []const u8) Writer.Error!void {
    for (value) |char| {
        switch (char) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            // Other control bytes: Zig uses `\xNN` (no `\uNNNN` form for these).
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try writeHexEscape(writer, char),
            else => try writer.writeByte(char),
        }
    }
}

fn writeHexEscape(writer: *Writer, char: u8) Writer.Error!void {
    const hex = "0123456789abcdef";
    try writer.writeAll("\\x");
    try writer.writeByte(hex[char >> 4]);
    try writer.writeByte(hex[char & 0x0f]);
}

fn writeIndent(writer: *Writer, depth: usize) Writer.Error!void {
    for (0..depth) |_| try writer.writeAll("    ");
}

/// A name is a bare ZON identifier when it matches `[A-Za-z_][A-Za-z0-9_]*` and
/// is not a Zig keyword (`error`, `true`, ...), which would have to be quoted.
fn isBareIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| {
        const ok = c == '_' or std.ascii.isAlphabetic(c) or (i > 0 and std.ascii.isDigit(c));
        if (!ok) return false;
    }
    return std.zig.Token.getKeyword(name) == null;
}

// =========
// TESTS
// =========

const Parser = @import("parser.zig");

fn expectPrint(input: []const u8, expected: []const u8) !void {
    var ast = try Parser.parseAbstract(std.testing.allocator, input, .ZON);
    defer ast.deinit();

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try print(&output.writer, &ast);
    try std.testing.expectEqualStrings(expected, output.written());
}

test "prints a struct literal" {
    try expectPrint(".{ .name = \"Ada\", .age = 36 }",
        \\.{
        \\    .name = "Ada",
        \\    .age = 36,
        \\}
        \\
    );
}

test "prints nested arrays and structs" {
    try expectPrint(".{ .xs = .{ 1, 2 }, .ok = true }",
        \\.{
        \\    .xs = .{
        \\        1,
        \\        2,
        \\    },
        \\    .ok = true,
        \\}
        \\
    );
}

test "prints empty container" {
    try expectPrint(".{}", ".{}\n");
}

test "quotes non-identifier field names" {
    try expectPrint(".{ .@\"has space\" = 1 }",
        \\.{
        \\    .@"has space" = 1,
        \\}
        \\
    );
}

test "keyword field names are quoted" {
    try expectPrint(".{ .@\"error\" = 1 }",
        \\.{
        \\    .@"error" = 1,
        \\}
        \\
    );
}

test "escapes strings" {
    try expectPrint(".{ .s = \"a\\tb\\nc\" }",
        \\.{
        \\    .s = "a\tb\nc",
        \\}
        \\
    );
}

test "enum literals round-trip" {
    try expectPrint(".{ .mode = .fast, .@\"weird key\" = .@\"weird val\" }",
        \\.{
        \\    .mode = .fast,
        \\    .@"weird key" = .@"weird val",
        \\}
        \\
    );
}

test "char literals round-trip" {
    try expectPrint(".{ .a = 'A', .nl = '\\n', .q = '\\'', .emoji = '😀' }",
        \\.{
        \\    .a = 'A',
        \\    .nl = '\n',
        \\    .q = '\'',
        \\    .emoji = '\u{1f600}',
        \\}
        \\
    );
}
