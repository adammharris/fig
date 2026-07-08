//! NestedText printer: renders a fig AST as canonical, always-block-style
//! NestedText (never the inline `{...}`/`[...]` forms — those are the
//! parser's business to accept, not the printer's to choose; matches how
//! INI's printer always writes `[section]` blocks rather than picking a
//! denser form).
//!
//! Every value is untyped text (NestedText has no typed scalars — same
//! simplification INI makes): a number/boolean/`extended` node stringifies
//! to its canonical text.
//!
//! Same-line (`key: value` / `- value`) vs. nested `>`-block is a
//! ROUND-TRIP-FORCED choice, not a style preference: rest-of-line values are
//! taken 100% literally on reparse (see `parser.zig`'s module doc), so
//! same-line is always safe EXCEPT for two cases forced by the grammar
//! itself: an EMPTY value has no same-line spelling at all (`key:` with
//! nothing after means "value is a nested block", and an absent nested block
//! is a parse error — not empty string; the only way to spell "" is a nested
//! bare `>` line), and a value containing a literal `\n` obviously can't fit
//! one line. A multiline KEY (`: key` form) is similarly forced whenever the
//! key is empty, starts with a byte the tokenizer would misread as a
//! different tag or a comment/indentation character, or contains a literal
//! `\n` or a `: ` substring that would confuse the key/value split scan; see
//! `needsMultilineKey`. A multiline key's value is ALWAYS a nested block
//! (never same-line — the grammar has no same-line form after a multiline
//! key), so a scalar value there is always rendered as a `>`-block even when
//! it would otherwise fit on one line.
//!
//! Comments: `#` full-line only (matches INI's own limitation) — a
//! *trailing* comment has no same-line spelling in this grammar, so it
//! prints as its own `#` line immediately after the item, same convention
//! INI's printer uses.

const Printer = @This();
const std = @import("std");
const AST = @import("../../ast/ast.zig");
const Writer = std.Io.Writer;

pub const Error = Writer.Error || error{ NullUnsupported, NonStringKey, UnresolvedAlias };

const indent_width: usize = 4;

pub fn print(writer: *Writer, ast: *const AST, options: AST.SerializeOptions) Error!void {
    switch (ast.nodes[ast.root].kind) {
        .null_ => {},
        .mapping => try printMapping(writer, ast, ast.root, 0),
        .sequence => try printSequence(writer, ast, ast.root, 0),
        else => try writeStringBlock(writer, 0, try scalarText(ast, ast.root)),
    }
    _ = options;
    try writer.flush();
}

/// Print the subtree at `id` as a standalone fragment, re-rooting a shallow
/// copy of `ast` — same trick INI's `printNode` uses.
pub fn printNode(writer: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize, options: AST.SerializeOptions) Error!void {
    _ = depth;
    var fragment = ast.*;
    fragment.root = id;
    try print(writer, &fragment, options);
}

// ── Containers ───────────────────────────────────────────────────────────────

fn printMapping(w: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize) Error!void {
    var cur = ast.nodes[id].kind.mapping;
    while (cur) |kv_id| : (cur = ast.nodes[kv_id].next_sibling) {
        const kv = ast.nodes[kv_id].kind.keyvalue;
        try printLeadingComments(w, ast, ast.leadingCommentAnchor(kv_id), depth);
        const key_text = try keyText(ast, kv.key);
        const multiline_key = needsMultilineKey(key_text);
        if (multiline_key) {
            try writeMultilineKeyLines(w, depth, key_text);
        } else {
            try writeIndent(w, depth);
            try w.writeAll(key_text);
            try w.writeByte(':');
        }
        try printItemValue(w, ast, kv.value, depth, multiline_key);
        try printTrailingComment(w, ast, ast.trailingCommentAnchor(kv_id), depth);
    }
    try printDanglingComments(w, ast, id, depth);
}

fn printSequence(w: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize) Error!void {
    var cur = ast.nodes[id].kind.sequence;
    while (cur) |item_id| : (cur = ast.nodes[item_id].next_sibling) {
        try printLeadingComments(w, ast, ast.leadingCommentAnchor(item_id), depth);
        try writeIndent(w, depth);
        try w.writeByte('-');
        try printItemValue(w, ast, item_id, depth, false);
        try printTrailingComment(w, ast, ast.trailingCommentAnchor(item_id), depth);
    }
    try printDanglingComments(w, ast, id, depth);
}

/// Render the value half of a `key:`/`-` item already written up to (but not
/// including) its own line terminator. `force_nested` is set for a multiline
/// key, which has no same-line value form at all.
fn printItemValue(w: *Writer, ast: *const AST, value_id: AST.Node.Id, depth: usize, force_nested: bool) Error!void {
    // `force_nested` (a multiline key) means the key's own last line already
    // ended with its own `\n` — the nested block starts writing indented
    // lines immediately. Otherwise the current line (`key:`/`-`) is still
    // open and needs closing with `\n` before anything nested can start.
    switch (ast.nodes[value_id].kind) {
        .mapping => {
            if (!force_nested) try w.writeByte('\n');
            try printMapping(w, ast, value_id, depth + 1);
        },
        .sequence => {
            if (!force_nested) try w.writeByte('\n');
            try printSequence(w, ast, value_id, depth + 1);
        },
        .alias => return error.UnresolvedAlias,
        .keyvalue => unreachable,
        else => {
            const text = try scalarText(ast, value_id);
            if (!force_nested and text.len != 0 and std.mem.indexOfScalar(u8, text, '\n') == null) {
                try w.writeByte(' ');
                try w.writeAll(text);
                try w.writeByte('\n');
            } else {
                if (!force_nested) try w.writeByte('\n');
                try writeStringBlock(w, depth + 1, text);
            }
        },
    }
}

// ── Keys and scalars ─────────────────────────────────────────────────────────

fn keyText(ast: *const AST, key_id: AST.Node.Id) Error![]const u8 {
    return switch (ast.nodes[key_id].kind) {
        .string => |s| s,
        else => error.NonStringKey,
    };
}

fn scalarText(ast: *const AST, id: AST.Node.Id) Error![]const u8 {
    return switch (ast.nodes[id].kind) {
        .string => |s| s,
        .number => |n| n.raw,
        .boolean => |b| if (b) "true" else "false",
        .extended => |e| e.text,
        .null_ => error.NullUnsupported,
        .alias => error.UnresolvedAlias,
        .sequence, .mapping, .keyvalue => unreachable, // handled by callers before reaching here
    };
}

/// Whether `key` needs the `: key` multiline form instead of plain `key:` —
/// forced whenever plain form would misparse or (for a leading space) be
/// silently absorbed into indentation on reread. See the module doc comment.
fn needsMultilineKey(key: []const u8) bool {
    if (key.len == 0) return true;
    const c0 = key[0];
    if (c0 == '#' or c0 == '{' or c0 == '[' or c0 == ' ' or c0 == '\t') return true;
    if ((c0 == '-' or c0 == ':' or c0 == '>') and (key.len == 1 or key[1] == ' ')) return true;
    if (std.mem.indexOfScalar(u8, key, '\n') != null) return true;
    if (std.mem.indexOf(u8, key, ": ") != null) return true;
    return false;
}

// ── Line writers ─────────────────────────────────────────────────────────────

fn writeIndent(w: *Writer, depth: usize) Writer.Error!void {
    try w.splatByteAll(' ', depth * indent_width);
}

fn writeMultilineKeyLines(w: *Writer, depth: usize, text: []const u8) Writer.Error!void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try writeIndent(w, depth);
        if (line.len == 0) {
            try w.writeAll(":\n");
        } else {
            try w.writeAll(": ");
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    }
}

/// One or more `> line` (or bare `>` for an empty line) lines at `depth`.
/// Splitting `""` on `\n` yields exactly one empty part, so an empty string
/// renders as a single bare `>` — the only way to spell "" in this grammar.
fn writeStringBlock(w: *Writer, depth: usize, text: []const u8) Writer.Error!void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try writeIndent(w, depth);
        if (line.len == 0) {
            try w.writeAll(">\n");
        } else {
            try w.writeAll("> ");
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    }
}

fn writeHashLine(w: *Writer, depth: usize, text: []const u8) Writer.Error!void {
    try writeIndent(w, depth);
    try w.writeByte('#');
    if (text.len != 0) {
        try w.writeByte(' ');
        try w.writeAll(text);
    }
    try w.writeByte('\n');
}

fn printLeadingComments(w: *Writer, ast: *const AST, anchor_id: AST.Node.Id, depth: usize) Error!void {
    for (ast.comments(anchor_id).leading) |c| {
        var it = std.mem.splitScalar(u8, c.text, '\n');
        while (it.next()) |line| try writeHashLine(w, depth, std.mem.trim(u8, line, " \t"));
    }
}

fn printTrailingComment(w: *Writer, ast: *const AST, anchor_id: AST.Node.Id, depth: usize) Error!void {
    const c = ast.comments(anchor_id).trailing orelse return;
    var it = std.mem.splitScalar(u8, c.text, '\n');
    while (it.next()) |line| try writeHashLine(w, depth, std.mem.trim(u8, line, " \t"));
}

fn printDanglingComments(w: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize) Error!void {
    for (ast.comments(id).dangling) |c| {
        var it = std.mem.splitScalar(u8, c.text, '\n');
        while (it.next()) |line| try writeHashLine(w, depth, std.mem.trim(u8, line, " \t"));
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

const std_testing = std.testing;
const Parser = @import("parser.zig");

fn expectPrint(input: []const u8, expected: []const u8) !void {
    var ast = try Parser.parseAbstract(std_testing.allocator, input, .NESTEDTEXT);
    defer ast.deinit();
    var output: Writer.Allocating = .init(std_testing.allocator);
    defer output.deinit();
    try print(&output.writer, &ast, .{});
    try std_testing.expectEqualStrings(expected, output.written());
}

fn expectRoundTrip(input: []const u8) !void {
    var ast = try Parser.parseAbstract(std_testing.allocator, input, .NESTEDTEXT);
    defer ast.deinit();
    var out1: Writer.Allocating = .init(std_testing.allocator);
    defer out1.deinit();
    try print(&out1.writer, &ast, .{});

    var reparsed = try Parser.parseAbstract(std_testing.allocator, out1.written(), .NESTEDTEXT);
    defer reparsed.deinit();
    var out2: Writer.Allocating = .init(std_testing.allocator);
    defer out2.deinit();
    errdefer std.log.err("printed:\n{s}", .{out1.written()});
    try print(&out2.writer, &reparsed, .{});
    try std_testing.expectEqualStrings(out1.written(), out2.written());
}

test "simple mapping round-trips through print in place" {
    try expectPrint("name: fig\n", "name: fig\n");
}

test "nested mapping" {
    try expectPrint("server:\n    host: localhost\n    port: 80\n", "server:\n    host: localhost\n    port: 80\n");
}

test "list" {
    try expectPrint("- a\n- b\n", "- a\n- b\n");
}

test "empty string value prints as a nested bare `>` line" {
    try expectPrint(":\n  >\n", ":\n    >\n");
}

test "multiline value prints as a `>` block" {
    var b = AST.Builder.init(std_testing.allocator);
    defer b.deinit();
    const key = try b.addString("k");
    const value = try b.addString("line1\nline2");
    const root = try b.addMapping(&.{.{ .key = key, .value = value }});
    var ast = try b.finish(root);
    defer ast.deinit();
    var output: Writer.Allocating = .init(std_testing.allocator);
    defer output.deinit();
    try print(&output.writer, &ast, .{});
    try std_testing.expectEqualStrings("k:\n    > line1\n    > line2\n", output.written());
}

test "key needing multiline form" {
    var b = AST.Builder.init(std_testing.allocator);
    defer b.deinit();
    const key = try b.addString("- starts like a list tag");
    const value = try b.addString("v");
    const root = try b.addMapping(&.{.{ .key = key, .value = value }});
    var ast = try b.finish(root);
    defer ast.deinit();
    var output: Writer.Allocating = .init(std_testing.allocator);
    defer output.deinit();
    try print(&output.writer, &ast, .{});
    try std_testing.expectEqualStrings(": - starts like a list tag\n    > v\n", output.written());
}

test "round-trips a mixed document with comments" {
    try expectRoundTrip(
        \\# header
        \\name: fig
        \\server:
        \\    host: localhost
        \\    port: 80
        \\items:
        \\    - a
        \\    - b
        \\
    );
}

test "empty document prints as nothing" {
    try expectPrint("", "");
}

test "root scalar prints as a `>` block" {
    try expectPrint("> hello\n", "> hello\n");
}

test "null mid-tree is unsupported" {
    var b = AST.Builder.init(std_testing.allocator);
    defer b.deinit();
    const key = try b.addString("k");
    const value = try b.addNull();
    const root = try b.addMapping(&.{.{ .key = key, .value = value }});
    var ast = try b.finish(root);
    defer ast.deinit();
    var output: Writer.Allocating = .init(std_testing.allocator);
    defer output.deinit();
    try std_testing.expectError(error.NullUnsupported, print(&output.writer, &ast, .{}));
}
