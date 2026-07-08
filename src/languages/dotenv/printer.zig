//! dotenv printer: renders a fig AST as canonical `.env`.
//!
//! Flat only: every root entry prints as `KEY=value`; a nested
//! mapping/sequence value has no dotenv form at all (unlike INI, which can
//! at least hold one level of `[section]` nesting) — `error.UnsupportedValue`.
//! A key must already be a valid bash identifier (`[A-Za-z_][A-Za-z0-9_]*`,
//! matching the parser's grammar) — anything else, from a cross-format
//! conversion, is `error.InvalidKey`.
//!
//! A value prints bare when that's unambiguous, else double-quoted with
//! escapes (`\n \t \r \\ \"`) — this printer never emits a literal embedded
//! newline even though the parser can read one back (a canonical single-line-
//! per-entry form is friendlier output; see `needsQuoting`/`writeQuoted`).
//! Comments: leading comments print as `# ...` lines above a key; UNLIKE INI,
//! dotenv's grammar has a real trailing-comment form (a `#` after a value,
//! gated by preceding whitespace — see the tokenizer), so a trailing comment
//! prints inline as `KEY=value # ...`, not pushed to its own line.

const Printer = @This();
const std = @import("std");
const AST = @import("../../ast/ast.zig");
const Writer = std.Io.Writer;

pub const Error = Writer.Error || error{ NullUnsupported, NonStringKey, InvalidKey, UnsupportedValue, UnresolvedAlias };

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
        if (ast.comments(value_id).trailing) |c| {
            try ctx.w.writeAll(" #");
            if (c.text.len != 0) {
                try ctx.w.writeByte(' ');
                for (c.text) |ch| try ctx.w.writeByte(if (ch == '\n') ' ' else ch);
            }
        }
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

fn isIdentStart(c: u8) bool {
    return c == '_' or std.ascii.isAlphabetic(c);
}
fn isIdentChar(c: u8) bool {
    return c == '_' or std.ascii.isAlphanumeric(c);
}
fn isIdentifier(name: []const u8) bool {
    if (name.len == 0 or !isIdentStart(name[0])) return false;
    for (name[1..]) |c| if (!isIdentChar(c)) return false;
    return true;
}

fn writeKey(w: *Writer, ast: *const AST, key_id: AST.Node.Id) Error!void {
    const name = switch (ast.nodes[key_id].kind) {
        .string => |s| s,
        else => return error.NonStringKey,
    };
    if (!isIdentifier(name)) return error.InvalidKey;
    try w.writeAll(name);
}

/// Render a value. dotenv has no typed scalars, so a non-string node (from a
/// cross-format conversion) stringifies to its canonical text; a
/// sequence/mapping has no dotenv value form at all (not even one level, per
/// the module doc).
fn writeValue(w: *Writer, ast: *const AST, id: AST.Node.Id) Error!void {
    switch (ast.nodes[id].kind) {
        .string => |s| try writeText(w, s),
        .number => |n| try w.writeAll(n.raw),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .extended => |ext| try writeText(w, ext.text),
        .null_ => return error.NullUnsupported,
        .sequence, .mapping => return error.UnsupportedValue,
        .keyvalue => unreachable, // never a value position
        .alias => return error.UnresolvedAlias,
    }
}

fn writeText(w: *Writer, value: []const u8) Writer.Error!void {
    if (!needsQuoting(value)) return w.writeAll(value);
    try w.writeByte('"');
    for (value) |c| switch (c) {
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// An empty value is fine bare (`KEY=`); anything else needs quoting if it has
/// leading/trailing whitespace (would be trimmed back on reread) or contains a
/// byte this printer would otherwise have to worry about disambiguating
/// (newline, `"`, `\`, or `#` — conservative: quoting is always SAFE, so any
/// `#` triggers it even though some positions would technically round-trip
/// unquoted too).
fn needsQuoting(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value[0] == ' ' or value[0] == '\t' or value[value.len - 1] == ' ' or value[value.len - 1] == '\t') return true;
    for (value) |c| if (c == '\n' or c == '\r' or c == '"' or c == '\\' or c == '#') return true;
    return false;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const std_testing = std.testing;
const Parser = @import("parser.zig");

fn expectPrint(input: []const u8, expected: []const u8) !void {
    var ast = try Parser.parseAbstract(std_testing.allocator, input, .DOTENV);
    defer ast.deinit();
    var output: Writer.Allocating = .init(std_testing.allocator);
    defer output.deinit();
    try print(&output.writer, &ast, .{});
    try std_testing.expectEqualStrings(expected, output.written());
}

fn expectRoundTrip(input: []const u8) !void {
    var ast = try Parser.parseAbstract(std_testing.allocator, input, .DOTENV);
    defer ast.deinit();
    var out1: Writer.Allocating = .init(std_testing.allocator);
    defer out1.deinit();
    try print(&out1.writer, &ast, .{});

    var reparsed = try Parser.parseAbstract(std_testing.allocator, out1.written(), .DOTENV);
    defer reparsed.deinit();
    var out2: Writer.Allocating = .init(std_testing.allocator);
    defer out2.deinit();
    errdefer std.log.err("printed:\n{s}", .{out1.written()});
    try print(&out2.writer, &reparsed, .{});
    try std_testing.expectEqualStrings(out1.written(), out2.written());
}

test "plain values print bare" {
    try expectPrint("NAME=fig\n", "NAME=fig\n");
}

test "a value needing quoting round-trips through double quotes" {
    try expectRoundTrip("MSG=\"line1\\nline2\"\n");
    try expectRoundTrip("A=' leading space'\n");
}

test "trailing comment prints inline" {
    try expectPrint("A=1 # note\n", "A=1 # note\n");
}

test "leading comment prints as a `#` line" {
    try expectPrint("# header\nA=1\n", "# header\nA=1\n");
}

test "round-trips a mixed document" {
    try expectRoundTrip(
        \\# config
        \\NAME=fig
        \\PATH='C:\Users\bob'
        \\MSG="hi \"there\""
        \\EMPTY=
        \\
    );
}

test "a non-identifier key is unrepresentable" {
    const a = std_testing.allocator;
    var b = AST.Builder.init(a);
    defer b.deinit();
    const v = try b.addString("x");
    const k = try b.addString("not-an-ident");
    const root = try b.addMapping(&.{.{ .key = k, .value = v }});
    var ast = try b.finish(root);
    defer ast.deinit();
    var output: Writer.Allocating = .init(a);
    defer output.deinit();
    try std_testing.expectError(error.InvalidKey, print(&output.writer, &ast, .{}));
}

test "a nested mapping value is unsupported (dotenv has no sections)" {
    const a = std_testing.allocator;
    var b = AST.Builder.init(a);
    defer b.deinit();
    const inner = try b.addMapping(&.{});
    const k = try b.addString("SERVER");
    const root = try b.addMapping(&.{.{ .key = k, .value = inner }});
    var ast = try b.finish(root);
    defer ast.deinit();
    var output: Writer.Allocating = .init(a);
    defer output.deinit();
    try std_testing.expectError(error.UnsupportedValue, print(&output.writer, &ast, .{}));
}
