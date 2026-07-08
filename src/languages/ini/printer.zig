//! INI printer: renders a fig AST as canonical INI.
//!
//! Root-level scalar entries print first (INI's `key = value` lines before any
//! section), then each mapping-valued entry prints as a `[section]` block —
//! in that fixed order regardless of the AST's actual child order, since real
//! INI syntax cannot interleave the two (any key after the first `[section]`
//! belongs to that section, not root) and an AST built by another format's
//! parser/the `Builder` may not already respect that grouping. A section
//! whose own value is itself a mapping (double nesting) has no INI form —
//! `error.UnsupportedValue`.
//!
//! Every value is written as plain, optionally-quoted text — INI has no typed
//! scalars, so a non-string value (from a cross-format conversion) stringifies.
//! A value is wrapped in `"..."` exactly when printing it bare wouldn't
//! round-trip: empty, has leading/trailing whitespace (the parser trims
//! unquoted values), or already starts/ends with a matching quote character
//! (which the parser would otherwise strip as INI-quoting on reread). A value
//! containing a literal newline has no representation at all in this single-
//! line grammar — `error.UnsupportedValue`. (Not handled: a key or section
//! name containing `=`/`]`/a newline — INI has no escaping for those either;
//! narrow enough in practice to leave as a known gap for now.)
//!
//! Comments: leading comments print as `; ...` lines above a key. INI has no
//! same-line trailing-comment syntax fig can safely emit (a `;`/`#` inside an
//! unquoted value is literal — see the tokenizer), so a *trailing* comment
//! prints as its own `;` line immediately after the `key = value` line instead
//! of being dropped.

const Printer = @This();
const std = @import("std");
const AST = @import("../../ast/ast.zig");
const Writer = std.Io.Writer;

pub const Error = Writer.Error || error{ NullUnsupported, NonStringKey, UnsupportedValue, UnresolvedAlias };

const Ctx = struct {
    w: *Writer,
    opts: AST.SerializeOptions,
    wrote: bool = false,

    fn commentBlock(ctx: *Ctx, c: AST.Comment) Error!void {
        var it = std.mem.splitScalar(u8, c.text, '\n');
        while (it.next()) |line| {
            try writeSemiLine(ctx.w, std.mem.trim(u8, line, " \t"));
            try ctx.w.writeByte('\n');
        }
        ctx.wrote = true;
    }

    fn leading(ctx: *Ctx, ast: *const AST, key_id: AST.Node.Id) Error!void {
        for (ast.comments(key_id).leading) |c| try ctx.commentBlock(c);
    }

    fn trailing(ctx: *Ctx, ast: *const AST, value_id: AST.Node.Id) Error!void {
        const c = ast.comments(value_id).trailing orelse return;
        try ctx.commentBlock(c);
    }

    fn dangling(ctx: *Ctx, ast: *const AST, id: AST.Node.Id) Error!void {
        for (ast.comments(id).dangling) |c| try ctx.commentBlock(c);
    }

    fn kvLine(ctx: *Ctx, ast: *const AST, key_id: AST.Node.Id, value_id: AST.Node.Id) Error!void {
        try ctx.leading(ast, key_id);
        try writeKey(ctx.w, ast, key_id);
        try ctx.w.writeAll(" = ");
        try writeValue(ctx.w, ast, value_id);
        try ctx.w.writeByte('\n');
        ctx.wrote = true;
        try ctx.trailing(ast, value_id);
    }

    fn section(ctx: *Ctx, ast: *const AST, key_id: AST.Node.Id, first_child: ?AST.Node.Id) Error!void {
        try ctx.leading(ast, key_id);
        if (ctx.wrote) try ctx.w.writeByte('\n');
        try ctx.w.writeByte('[');
        try writeKey(ctx.w, ast, key_id);
        try ctx.w.writeAll("]\n");
        ctx.wrote = true;
        var cur = first_child;
        while (cur) |id| : (cur = ast.nodes[id].next_sibling) {
            const kv = ast.nodes[id].kind.keyvalue;
            if (ast.nodes[kv.value].kind == .mapping) return error.UnsupportedValue; // no nested sections
            try ctx.kvLine(ast, kv.key, kv.value);
        }
    }
};

fn isMappingValue(ast: *const AST, kv_id: AST.Node.Id) bool {
    const kv = ast.nodes[kv_id].kind.keyvalue;
    return ast.nodes[kv.value].kind == .mapping;
}

pub fn print(writer: *Writer, ast: *const AST, options: AST.SerializeOptions) Error!void {
    var ctx = Ctx{ .w = writer, .opts = options };
    switch (ast.nodes[ast.root].kind) {
        .mapping => |first| {
            var cur = first;
            while (cur) |id| : (cur = ast.nodes[id].next_sibling) {
                if (isMappingValue(ast, id)) continue;
                const kv = ast.nodes[id].kind.keyvalue;
                try ctx.kvLine(ast, kv.key, kv.value);
            }
            cur = first;
            while (cur) |id| : (cur = ast.nodes[id].next_sibling) {
                if (!isMappingValue(ast, id)) continue;
                const kv = ast.nodes[id].kind.keyvalue;
                try ctx.section(ast, kv.key, ast.nodes[kv.value].kind.mapping);
                try ctx.dangling(ast, kv.value);
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

fn keyText(ast: *const AST, key_id: AST.Node.Id) Error![]const u8 {
    return switch (ast.nodes[key_id].kind) {
        .string => |s| s,
        else => error.NonStringKey,
    };
}

fn writeKey(w: *Writer, ast: *const AST, key_id: AST.Node.Id) Error!void {
    try writeText(w, try keyText(ast, key_id));
}

/// Render a value. INI has no typed scalars, so a non-string node (from a
/// cross-format conversion) stringifies to its canonical text; a
/// sequence/mapping has no INI value form.
fn writeValue(w: *Writer, ast: *const AST, id: AST.Node.Id) Error!void {
    switch (ast.nodes[id].kind) {
        .string => |s| try writeText(w, s),
        .number => |n| try w.writeAll(n.raw),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .extended => |ext| try w.writeAll(ext.text),
        .null_ => return error.NullUnsupported,
        .sequence, .mapping => return error.UnsupportedValue,
        .keyvalue => unreachable, // never a value position
        .alias => return error.UnresolvedAlias,
    }
}

/// Write `value` bare, unless bare wouldn't round-trip (see module doc).
fn writeText(w: *Writer, value: []const u8) Error!void {
    for (value) |c| if (c == '\n' or c == '\r') return error.UnsupportedValue;
    if (needsQuoting(value)) {
        try w.writeByte('"');
        try w.writeAll(value);
        try w.writeByte('"');
    } else {
        try w.writeAll(value);
    }
}

fn needsQuoting(value: []const u8) bool {
    if (value.len == 0) return true;
    if (value[0] == ' ' or value[0] == '\t') return true;
    if (value[value.len - 1] == ' ' or value[value.len - 1] == '\t') return true;
    if (value.len >= 2) {
        const q = value[0];
        if ((q == '"' or q == '\'') and value[value.len - 1] == q) return true;
    }
    return false;
}

fn writeSemiLine(w: *Writer, text: []const u8) Writer.Error!void {
    try w.writeByte(';');
    if (text.len != 0) {
        try w.writeByte(' ');
        try w.writeAll(text);
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

const std_testing = std.testing;
const Parser = @import("parser.zig");

fn expectPrint(input: []const u8, expected: []const u8) !void {
    var ast = try Parser.parseAbstract(std_testing.allocator, input, .INI);
    defer ast.deinit();
    var output: Writer.Allocating = .init(std_testing.allocator);
    defer output.deinit();
    try print(&output.writer, &ast, .{});
    try std_testing.expectEqualStrings(expected, output.written());
}

fn expectRoundTrip(input: []const u8) !void {
    var ast = try Parser.parseAbstract(std_testing.allocator, input, .INI);
    defer ast.deinit();
    var out1: Writer.Allocating = .init(std_testing.allocator);
    defer out1.deinit();
    try print(&out1.writer, &ast, .{});

    var reparsed = try Parser.parseAbstract(std_testing.allocator, out1.written(), .INI);
    defer reparsed.deinit();
    var out2: Writer.Allocating = .init(std_testing.allocator);
    defer out2.deinit();
    errdefer std.log.err("printed:\n{s}", .{out1.written()});
    try print(&out2.writer, &reparsed, .{});
    try std_testing.expectEqualStrings(out1.written(), out2.written());
}

test "root scalars then sections" {
    // A blank line separates the root preamble from the first `[section]`
    // (and each subsequent section), matching TOML's printer convention.
    try expectPrint(
        \\name = fig
        \\[server]
        \\host = localhost
        \\
    ,
        \\name = fig
        \\
        \\[server]
        \\host = localhost
        \\
    );
}

test "leading and trailing comments" {
    try expectPrint(
        \\; header
        \\name = fig
        \\
    ,
        \\; header
        \\name = fig
        \\
    );
}

test "quotes a value with leading/trailing whitespace" {
    try expectPrint("k = \" spaced \"\n", "k = \" spaced \"\n");
}

test "quotes an already-quote-wrapped literal value so it round-trips" {
    try expectRoundTrip("k = \"\"quoted\"\"\n"); // literal value: "quoted"
}

test "value with embedded semicolon stays literal" {
    try expectPrint("k = a;b\n", "k = a;b\n");
}

test "round-trips a mixed document" {
    try expectRoundTrip(
        \\name = fig
        \\
        \\[server]
        \\host = localhost
        \\port = 80
        \\
        \\[client]
        \\timeout = 30
        \\
    );
}

test "double-nested section is unsupported" {
    const a = std_testing.allocator;
    var b = AST.Builder.init(a);
    defer b.deinit();
    const inner = try b.addMapping(&.{});
    const inner_key = try b.addString("inner");
    const outer = try b.addMapping(&.{.{ .key = inner_key, .value = inner }});
    const outer_key = try b.addString("outer");
    const root = try b.addMapping(&.{.{ .key = outer_key, .value = outer }});
    var ast = try b.finish(root);
    defer ast.deinit();
    var output: Writer.Allocating = .init(a);
    defer output.deinit();
    try std_testing.expectError(error.UnsupportedValue, print(&output.writer, &ast, .{}));
}
