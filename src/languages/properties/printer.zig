//! `.properties` printer: renders a fig AST as canonical Java `.properties`.
//!
//! Flat only, like dotenv: every root entry prints as `key=value`; a nested
//! mapping/sequence value has no `.properties` form — `error.UnsupportedValue`.
//! Always uses `=` as the separator (never `:` or bare whitespace — those are
//! reader-only conveniences, see `parser.zig`).
//!
//! Escaping: `\n \r \t \f \\` always escape (a raw newline/CR can never
//! appear in a key/value span at all — see the tokenizer; a literal one must
//! round-trip through the `\n`/`\r` escape, not a physical line break). A
//! key ALSO escapes `=`, `:`, and any whitespace (those are what terminate
//! key-scanning — see the tokenizer's `isSeparator`) wherever they appear,
//! plus a LEADING `#`/`!` specifically (so it can't be misread as starting a
//! comment line on reread). A value only escapes LEADING whitespace (the
//! parser would otherwise skip it as post-separator padding); `=`/`:`/`#`/`!`
//! are never special inside a value and print bare.

const Printer = @This();
const std = @import("std");
const AST = @import("../../ast/ast.zig");
const Writer = std.Io.Writer;

pub const Error = Writer.Error || error{ NullUnsupported, NonStringKey, UnsupportedValue, UnresolvedAlias };

const Ctx = struct {
    w: *Writer,
    opts: AST.SerializeOptions,

    fn commentBlock(ctx: *Ctx, c: AST.Comment) Error!void {
        var it = std.mem.splitScalar(u8, c.text, '\n');
        while (it.next()) |line| {
            try ctx.w.writeByte('#');
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len != 0) {
                try ctx.w.writeByte(' ');
                try ctx.w.writeAll(trimmed);
            }
            try ctx.w.writeByte('\n');
        }
    }

    fn leading(ctx: *Ctx, ast: *const AST, key_id: AST.Node.Id) Error!void {
        for (ast.comments(key_id).leading) |c| try ctx.commentBlock(c);
    }

    fn dangling(ctx: *Ctx, ast: *const AST, id: AST.Node.Id) Error!void {
        for (ast.comments(id).dangling) |c| try ctx.commentBlock(c);
    }

    fn kvLine(ctx: *Ctx, ast: *const AST, key_id: AST.Node.Id, value_id: AST.Node.Id) Error!void {
        try ctx.leading(ast, key_id);
        try writeKey(ctx.w, ast, key_id);
        try ctx.w.writeByte('=');
        try writeValue(ctx.w, ast, value_id);
        try ctx.w.writeByte('\n');
    }
};

pub fn print(writer: *Writer, ast: *const AST, options: AST.SerializeOptions) Error!void {
    var ctx = Ctx{ .w = writer, .opts = options };
    switch (ast.nodes[ast.root].kind) {
        .mapping => |first| {
            var cur = first;
            while (cur) |id| : (cur = ast.nodes[id].next_sibling) {
                const kv = ast.nodes[id].kind.keyvalue;
                try ctx.kvLine(ast, kv.key, kv.value);
            }
            try ctx.dangling(ast, ast.root);
        },
        else => {
            try writeValue(writer, ast, ast.root);
            try writer.writeByte('\n');
        },
    }
    try writer.flush();
}

/// Print the subtree at `id` as a standalone fragment: a mapping prints as a
/// full document rooted there, anything else prints as a bare value line.
pub fn printNode(writer: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize, options: AST.SerializeOptions) Error!void {
    _ = depth;
    switch (ast.nodes[id].kind) {
        .mapping => {
            var fragment = ast.*;
            fragment.root = id;
            try print(writer, &fragment, options);
        },
        else => {
            try writeValue(writer, ast, id);
            try writer.writeByte('\n');
        },
    }
}

// ── Keys and values ─────────────────────────────────────────────────────────

fn isKeySpecial(c: u8) bool {
    return c == '=' or c == ':' or c == ' ' or c == '\t' or c == 0x0c;
}

fn writeEscapedByte(w: *Writer, c: u8) Writer.Error!void {
    switch (c) {
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x0c => try w.writeAll("\\f"),
        '\\' => try w.writeAll("\\\\"),
        else => {
            try w.writeByte('\\');
            try w.writeByte(c);
        },
    }
}

fn writeKey(w: *Writer, ast: *const AST, key_id: AST.Node.Id) Error!void {
    const name = switch (ast.nodes[key_id].kind) {
        .string => |s| s,
        else => return error.NonStringKey,
    };
    for (name, 0..) |c, idx| {
        if (idx == 0 and (c == '#' or c == '!')) {
            try writeEscapedByte(w, c);
        } else if (c == '\n' or c == '\r' or c == '\t' or c == 0x0c or c == '\\' or isKeySpecial(c)) {
            try writeEscapedByte(w, c);
        } else {
            try w.writeByte(c);
        }
    }
}

/// Render a value. `.properties` has no typed scalars, so a non-string node
/// (from a cross-format conversion) stringifies to its canonical text; a
/// sequence/mapping has no `.properties` value form at all.
fn writeValue(w: *Writer, ast: *const AST, id: AST.Node.Id) Error!void {
    switch (ast.nodes[id].kind) {
        .string => |s| try writeValueText(w, s),
        .number => |n| try w.writeAll(n.raw),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .extended => |ext| try writeValueText(w, ext.text),
        .null_ => return error.NullUnsupported,
        .sequence, .mapping => return error.UnsupportedValue,
        .keyvalue => unreachable, // never a value position
        .alias => return error.UnresolvedAlias,
    }
}

fn writeValueText(w: *Writer, value: []const u8) Writer.Error!void {
    for (value, 0..) |c, idx| {
        if (idx == 0 and (c == ' ' or c == '\t' or c == 0x0c)) {
            try writeEscapedByte(w, c);
        } else switch (c) {
            '\n', '\r', '\t', 0x0c, '\\' => try writeEscapedByte(w, c),
            else => try w.writeByte(c),
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

const std_testing = std.testing;
const Parser = @import("parser.zig");

fn expectPrint(input: []const u8, expected: []const u8) !void {
    var ast = try Parser.parseAbstract(std_testing.allocator, input, .PROPERTIES);
    defer ast.deinit();
    var output: Writer.Allocating = .init(std_testing.allocator);
    defer output.deinit();
    try print(&output.writer, &ast, .{});
    try std_testing.expectEqualStrings(expected, output.written());
}

fn expectRoundTrip(input: []const u8) !void {
    var ast = try Parser.parseAbstract(std_testing.allocator, input, .PROPERTIES);
    defer ast.deinit();
    var out1: Writer.Allocating = .init(std_testing.allocator);
    defer out1.deinit();
    try print(&out1.writer, &ast, .{});

    var reparsed = try Parser.parseAbstract(std_testing.allocator, out1.written(), .PROPERTIES);
    defer reparsed.deinit();
    var out2: Writer.Allocating = .init(std_testing.allocator);
    defer out2.deinit();
    errdefer std.log.err("printed:\n{s}", .{out1.written()});
    try print(&out2.writer, &reparsed, .{});
    try std_testing.expectEqualStrings(out1.written(), out2.written());
}

test "canonicalizes to `=`, regardless of the source separator" {
    try expectPrint("a: 1\n", "a=1\n");
    try expectPrint("a 1\n", "a=1\n");
}

test "escapes control characters and a leading space in a value" {
    try expectPrint("v=a\\tb\\nc\n", "v=a\\tb\\nc\n");
    try expectRoundTrip("v=\\ leading\n");
}

test "escapes a leading `#`/`!` in a key" {
    try expectRoundTrip("\\#weird=1\n");
    try expectRoundTrip("\\!weird=1\n");
}

test "escapes separator-like characters in a key" {
    try expectRoundTrip("a\\:b\\=c\\ d=1\n");
}

test "line-continuation collapses; round-trips as one line" {
    try expectPrint("long=part1\\\n  part2\n", "long=part1part2\n");
}

test "leading comment prints as a `#` line" {
    try expectPrint("# header\na=1\n", "# header\na=1\n");
}

test "round-trips a mixed document" {
    try expectRoundTrip(
        \\# config
        \\db.host=localhost
        \\db.port=5432
        \\greeting=hi \\ttab
        \\
    );
}

test "a nested mapping value is unsupported (no sections)" {
    const a = std_testing.allocator;
    var b = AST.Builder.init(a);
    defer b.deinit();
    const inner = try b.addMapping(&.{});
    const k = try b.addString("server");
    const root = try b.addMapping(&.{.{ .key = k, .value = inner }});
    var ast = try b.finish(root);
    defer ast.deinit();
    var output: Writer.Allocating = .init(a);
    defer output.deinit();
    try std_testing.expectError(error.UnsupportedValue, print(&output.writer, &ast, .{}));
}
