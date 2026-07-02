const Printer = @This();
const std = @import("std");
const AST = @import("../ast/ast.zig");
const Writer = std.Io.Writer;

/// Prints a given document in YAML block format.
pub fn print(writer: *Writer, ast: *const AST) Writer.Error!void {
    // Document-level leading comments (those bound to the root) sit at column 0
    // above everything else.
    try leadingComments(writer, ast, ast.leadingCommentAnchor(ast.root), 0);
    try printNode(writer, ast, ast.root, 0);
    // End-of-document comments dangling off the root, at column 0.
    try danglingComments(writer, ast, ast.root, 0);
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
        .extended => |value| {
            // YAML's core schema has none of these types (timestamps were YAML
            // 1.1). Enum literals become string scalars (may need quoting);
            // datetimes and char codepoints emit verbatim as plain scalars.
            switch (value.kind) {
                .enum_literal => try printScalar(writer, value.text),
                else => try writer.writeAll(value.text),
            }
            try writer.writeByte('\n');
        },
        .string => |value| {
            try printScalar(writer, value);
            try writer.writeByte('\n');
        },
        .sequence => |first_child| try printSequence(writer, ast, first_child, depth),
        .mapping => |first_child| try printMapping(writer, ast, first_child, depth),
        .keyvalue => |kv| try printKeyValue(writer, ast, kv, depth, false),
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
        // A scalar element owns its leading directly. A block-mapping element
        // (`- key: val`) parked its leading on its first key (the parser's
        // `parking_container`), which still renders above the `- ` line.
        try leadingComments(writer, document, seqItemLeadAnchor(document, id), depth);
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
                if (!try tryWriteBlockStringValue(writer, document, id, depth + 1)) {
                    try printInlineValue(writer, document, id);
                    try trailingComment(writer, document, id);
                    try writer.writeByte('\n');
                }
            },
        }
        current_id = item.next_sibling;
    }
}

/// Where a sequence item's leading comment lives. A block-mapping item parks it
/// on the item-mapping's first key (so it sits above the `- ` line); every other
/// item owns its leading on the item node itself.
fn seqItemLeadAnchor(ast: *const AST, id: AST.Node.Id) AST.Node.Id {
    return switch (ast.nodes[id].kind) {
        .mapping => |first| if (first) |kv| ast.nodes[kv].kind.keyvalue.key else id,
        else => id,
    };
}

fn printMapping(writer: *Writer, document: *const AST, first_child: ?AST.Node.Id, depth: usize) Writer.Error!void {
    if (first_child == null) {
        try writer.writeAll("{}\n");
        return;
    }

    var current_id = first_child;
    while (current_id) |id| {
        try leadingComments(writer, document, document.leadingCommentAnchor(id), depth);
        try printKeyValue(writer, document, document.nodes[id].kind.keyvalue, depth, false);
        current_id = document.nodes[id].next_sibling;
    }
}

fn printSequenceMapping(writer: *Writer, document: *const AST, first_pair: AST.Node.Id, depth: usize) Writer.Error!void {
    // Every pair sits one level deeper than the sequence: the `- ` prefix already
    // occupies that level's two columns. The first pair is written right after the
    // `- `, so its own leading indent is suppressed (`skip_indent`) — but its base
    // depth is still `depth + 1`, so a nested block value (mapping/sequence) indents
    // relative to the key's real column, not the sequence's. Passing `0` here would
    // emit nested children a level too shallow, turning them into siblings.
    try printKeyValue(writer, document, document.nodes[first_pair].kind.keyvalue, depth + 1, true);

    var current_id = document.nodes[first_pair].next_sibling;
    while (current_id) |id| {
        try leadingComments(writer, document, document.leadingCommentAnchor(id), depth + 1);
        try printKeyValue(writer, document, document.nodes[id].kind.keyvalue, depth + 1, false);
        current_id = document.nodes[id].next_sibling;
    }
}

fn printKeyValue(writer: *Writer, document: *const AST, kv: anytype, depth: usize, skip_indent: bool) Writer.Error!void {
    const value = document.nodes[kv.value];
    if (!skip_indent) try writeIndent(writer, depth);
    try writeProps(writer, document, kv.key); // `&k key:` / `!!str key:`
    try printScalar(writer, document.nodes[kv.key].kind.string);
    switch (value.kind) {
        .mapping => |child| {
            try writer.writeByte(':');
            try writePropsAfterColon(writer, document, kv.value); // `: &a` before the block
            if (child == null) {
                try writer.writeAll(" {}\n");
            } else {
                // A comment on the `key:` line rides here, above the block value.
                try trailingComment(writer, document, kv.value);
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
                try trailingComment(writer, document, kv.value);
                try writer.writeByte('\n');
                // Indentless: a sequence value's dashes sit at the key's column.
                try printSequence(writer, document, child, depth);
            }
        },
        else => {
            try writer.writeAll(": ");
            if (!try tryWriteBlockStringValue(writer, document, kv.value, depth + 1)) {
                try printInlineValue(writer, document, kv.value);
                // Trailing comment rides the value's line (`key: value # note`).
                // Block-scalar values omit it (no single line to ride).
                try trailingComment(writer, document, kv.value);
                try writer.writeByte('\n');
            }
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
        .extended => |value| switch (value.kind) {
            .enum_literal => try printScalar(writer, value.text),
            else => try writer.writeAll(value.text),
        },
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

// ── Scalar emission ─────────────────────────────────────────────────────────

/// Emit a scalar inline — plain, single-quoted, or double-quoted as the value
/// requires so it reads back unchanged. Used for keys and single-line values; a
/// multi-line string *value* becomes a `|` block scalar instead (see
/// `tryWriteBlockStringValue`), so a newline reaching here (e.g. in a key) is
/// double-quoted.
fn printScalar(writer: *Writer, raw: []const u8) Writer.Error!void {
    if (hasControlChar(raw)) {
        try writeDoubleQuoted(writer, raw);
    } else if (needsQuoting(raw)) {
        try writeSingleQuoted(writer, raw);
    } else {
        try writer.writeAll(raw);
    }
}

/// True if any byte is an ASCII control character (newline/tab included). Such a
/// scalar can only be represented inline by double-quoting.
fn hasControlChar(s: []const u8) bool {
    for (s) |c| if (c < 0x20 or c == 0x7f) return true;
    return false;
}

/// Whether a plain (unquoted) scalar would be misread — as another type, or as
/// YAML structure — and so needs single-quoting. Assumes no control characters
/// (those force double-quoting upstream).
fn needsQuoting(s: []const u8) bool {
    if (s.len == 0) return true; // empty plain scalar reads back as null
    if (resolvesToNonString(s)) return true;
    if (s[0] == ' ' or s[s.len - 1] == ' ') return true; // leading/trailing space is lost
    switch (s[0]) {
        // A plain scalar may not begin with an indicator character.
        '!', '&', '*', '?', '|', '>', '%', '@', '`', '"', '\'', '#', ',', '[', ']', '{', '}' => return true,
        // `-`/`:` are unsafe as the first char only before a space (or alone).
        '-', ':' => if (s.len == 1 or s[1] == ' ') return true,
        else => {},
    }
    // Interior `: ` (mapping indicator), trailing `:`, or ` #` (comment) force quoting.
    if (std.mem.indexOf(u8, s, ": ") != null) return true;
    if (s[s.len - 1] == ':') return true;
    if (std.mem.indexOf(u8, s, " #") != null) return true;
    return false;
}

/// Plain scalars that YAML 1.2's core schema resolves to a non-string type
/// (null, bool, the special floats) or a number.
fn resolvesToNonString(s: []const u8) bool {
    const keywords = [_][]const u8{
        "null", "Null", "NULL", "~",
        "true", "True", "TRUE", "false", "False", "FALSE",
        ".inf", ".Inf", ".INF", "-.inf", "-.Inf", "-.INF", "+.inf", ".nan", ".NaN", ".NAN",
    };
    for (keywords) |kw| if (std.mem.eql(u8, s, kw)) return true;
    return looksNumeric(s);
}

/// Whether `s` would parse as a YAML number. Zig's float parser also accepts
/// bare `inf`/`nan`, which the core schema does not, so those are excluded.
fn looksNumeric(s: []const u8) bool {
    if (asciiContains(s, "inf") or asciiContains(s, "nan")) return false;
    if (std.fmt.parseInt(i64, s, 10)) |_| return true else |_| {}
    if (std.fmt.parseInt(u64, s, 10)) |_| return true else |_| {}
    if (std.fmt.parseFloat(f64, s)) |_| return true else |_| {}
    return false;
}

/// Case-insensitive ASCII substring test.
fn asciiContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn writeSingleQuoted(writer: *Writer, s: []const u8) Writer.Error!void {
    try writer.writeByte('\'');
    for (s) |c| {
        if (c == '\'') try writer.writeByte('\''); // '' escapes a quote
        try writer.writeByte(c);
    }
    try writer.writeByte('\'');
}

fn writeDoubleQuoted(writer: *Writer, s: []const u8) Writer.Error!void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\t' => try writer.writeAll("\\t"),
            '\r' => try writer.writeAll("\\r"),
            else => if (c < 0x20 or c == 0x7f)
                try writer.print("\\x{x:0>2}", .{c})
            else
                try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

// ── Block scalars (multi-line strings) ──────────────────────────────────────

/// Emit `id` as a `|` block scalar when it is a multi-line string a block scalar
/// can round-trip; returns whether it did (the caller falls back to an inline
/// scalar otherwise). The caller has already written the `key: ` / `- ` lead-in;
/// on success this writes any anchor/tag props, the indicator, and the indented
/// content lines.
fn tryWriteBlockStringValue(writer: *Writer, ast: *const AST, id: AST.Node.Id, indent: usize) Writer.Error!bool {
    const node = ast.nodes[id];
    if (node.kind != .string) return false;
    const s = node.kind.string;
    if (!blockScalarOk(s)) return false;
    try writeProps(writer, ast, id);
    try writeBlockScalar(writer, s, indent);
    return true;
}

/// Whether a multi-line string can be faithfully emitted as a `|` block scalar.
/// Conservative: rejects carriage returns and other non-newline controls, lines
/// with trailing whitespace (invisible, editor-fragile), leading whitespace on
/// the FIRST non-empty line only (it anchors YAML's indentation auto-detection;
/// deeper-indented later lines round-trip fine — think shell-script bodies),
/// and 2+ trailing newlines (which would need the `|+` keep indicator). Anything
/// rejected here is double-quoted instead, which always round-trips.
fn blockScalarOk(s: []const u8) bool {
    if (std.mem.indexOfScalar(u8, s, '\n') == null) return false;
    if (std.mem.endsWith(u8, s, "\n\n")) return false;
    const body = if (std.mem.endsWith(u8, s, "\n")) s[0 .. s.len - 1] else s;
    var it = std.mem.splitScalar(u8, body, '\n');
    var first_content = true;
    while (it.next()) |line| {
        if (line.len == 0) continue; // interior blank lines are fine (emitted empty)
        if (first_content and (line[0] == ' ' or line[0] == '\t')) return false;
        first_content = false;
        if (line[line.len - 1] == ' ' or line[line.len - 1] == '\t') return false;
        for (line) |c| if (c != '\t' and (c < 0x20 or c == 0x7f)) return false;
    }
    return true;
}

/// Write the block-scalar indicator and indented content for a string that
/// passed `blockScalarOk`. `|` clips a single trailing newline, `|-` strips a
/// missing one. Blank lines are emitted empty (no trailing-indent ambiguity).
fn writeBlockScalar(writer: *Writer, s: []const u8, indent: usize) Writer.Error!void {
    const clip = std.mem.endsWith(u8, s, "\n");
    try writer.writeAll(if (clip) "|\n" else "|-\n");
    const body = if (clip) s[0 .. s.len - 1] else s;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (line.len == 0) {
            try writer.writeByte('\n');
        } else {
            try writeIndent(writer, indent);
            try writer.writeAll(line);
            try writer.writeByte('\n');
        }
    }
}

fn writeIndent(writer: *Writer, depth: usize) Writer.Error!void {
    for (0..depth) |_| try writer.writeAll("  ");
}

// ── Comments ────────────────────────────────────────────────────────────────
// YAML has only `#` line comments. A `block` comment captured from another
// format (`/* … */`) therefore degrades to a run of `#` lines, one per content
// line — content survives, block-ness does not (it can't, in YAML).

/// Emit a node's leading comments above its line, at `depth`. Each comment (line
/// or block) becomes one or more `# …` lines; a multi-line block yields one `#`
/// line per content line.
fn leadingComments(writer: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize) Writer.Error!void {
    for (ast.comments(id).leading) |c| {
        var it = std.mem.splitScalar(u8, c.text, '\n');
        while (it.next()) |line| {
            try writeIndent(writer, depth);
            try writeHashLine(writer, std.mem.trim(u8, line, " \t"));
            try writer.writeByte('\n');
        }
    }
}

/// Emit a node's trailing comment after its value (` # …`). A multi-line block
/// is flattened to one line (newlines → spaces) since a YAML trailing comment
/// must stay on the value's line.
fn trailingComment(writer: *Writer, ast: *const AST, id: AST.Node.Id) Writer.Error!void {
    const c = ast.comments(id).trailing orelse return;
    try writer.writeAll(" #");
    if (c.text.len != 0) {
        try writer.writeByte(' ');
        for (c.text) |ch| try writer.writeByte(if (ch == '\n') ' ' else ch);
    }
}

/// Emit a container's dangling comments (orphans at the end of its body) at
/// `depth`, each as one or more `#` lines.
fn danglingComments(writer: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize) Writer.Error!void {
    for (ast.comments(id).dangling) |c| {
        var it = std.mem.splitScalar(u8, c.text, '\n');
        while (it.next()) |line| {
            try writeIndent(writer, depth);
            try writeHashLine(writer, std.mem.trim(u8, line, " \t"));
            try writer.writeByte('\n');
        }
    }
}

/// Write `# text` (or a bare `#` for an empty comment).
fn writeHashLine(writer: *Writer, text: []const u8) Writer.Error!void {
    try writer.writeByte('#');
    if (text.len != 0) {
        try writer.writeByte(' ');
        try writer.writeAll(text);
    }
}

test "yaml emits comments; block degrades to a # run" {
    const a = std.testing.allocator;
    var b = AST.Builder.init(a);
    defer b.deinit();

    // { name: "fig", nums: [1, 2] } with assorted comments, including a block
    // comment that must degrade to two `#` lines in YAML.
    const v_name = try b.addString("fig");
    try b.setComments(v_name, .{ .trailing = .{ .text = "inline", .style = .line } });
    const k_name = try b.addString("name");
    try b.setComments(k_name, .{ .leading = &.{.{ .text = "greeting", .style = .line }} });

    const n1 = try b.addInt(1);
    try b.setComments(n1, .{ .leading = &.{.{ .text = "first\nsecond", .style = .block }} });
    const n2 = try b.addInt(2);
    try b.setComments(n2, .{ .trailing = .{ .text = "two", .style = .line } });
    const v_nums = try b.addSequence(&.{ n1, n2 });
    const k_nums = try b.addString("nums");

    const root = try b.addMapping(&.{
        .{ .key = k_name, .value = v_name },
        .{ .key = k_nums, .value = v_nums },
    });
    try b.setComments(root, .{ .leading = &.{.{ .text = "config", .style = .line }} });

    var ast = try b.finish(root);
    defer ast.deinit();

    var out: Writer.Allocating = .init(a);
    defer out.deinit();
    try print(&out.writer, &ast);
    try std.testing.expectEqualStrings(
        \\# config
        \\# greeting
        \\name: fig # inline
        \\nums:
        \\# first
        \\# second
        \\- 1
        \\- 2 # two
        \\
    , out.written());
}

test "a comment on a key: line with a block value rides the key line" {
    const Parser = @import("parser.zig");
    // The comment trails the entry (`contents:`), not the first sequence item.
    const cases = [_][]const u8{
        "contents: # note\n- a\n- b\n",
        "outer: # note\n  inner: 1\n",
    };
    for (cases) |src| {
        const doc = try Parser.parse(std.testing.allocator, src, .v1_2_2);
        defer doc.deinit(std.testing.allocator);
        var out: Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try print(&out.writer, &doc.ast);
        try std.testing.expectEqualStrings(src, out.written());
    }
}

test "prints YAML document" {
    // Native is the AST-literal syntax here — this test's subject is YAML
    // printing, not JSON reading.
    const Parser = @import("../canonical/parser.zig");
    const input = "{\"name\":\"Ada\",\"tags\":[\"zig\",true,null]}";
    var doc = try Parser.parseAbstract(std.testing.allocator, input);
    defer doc.deinit();

    var output: Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try print(&output.writer, &doc);
    try std.testing.expectEqualSlices(u8,
        \\name: Ada
        \\tags:
        \\- zig
        \\- true
        \\- null
        \\
    , output.written());
}

test "yaml printer: nested block value on a sequence item's first pair indents under the key" {
    const a = std.testing.allocator;
    var b = AST.Builder.init(a);
    defer b.deinit();

    // { audience: [ { outer: { inner: 1 } }, { last: 3 } ] }
    // The nested mapping AND a nested sequence both hang off the FIRST pair of a
    // sequence-item mapping — the case that previously emitted children a level too
    // shallow, collapsing them into siblings (`outer: null` + `inner: 1`).
    const inner = try b.addMapping(&.{.{ .key = try b.addString("inner"), .value = try b.addInt(1) }});
    const item0 = try b.addMapping(&.{.{ .key = try b.addString("outer"), .value = inner }});
    const item1 = try b.addMapping(&.{.{ .key = try b.addString("last"), .value = try b.addInt(3) }});
    const seq = try b.addSequence(&.{ item0, item1 });
    const root = try b.addMapping(&.{.{ .key = try b.addString("audience"), .value = seq }});

    var ast = try b.finish(root);
    defer ast.deinit();

    var out: Writer.Allocating = .init(a);
    defer out.deinit();
    try print(&out.writer, &ast);
    try std.testing.expectEqualStrings(
        \\audience:
        \\- outer:
        \\    inner: 1
        \\- last: 3
        \\
    , out.written());
}

test "yaml printer: nested sequence on a sequence item's first pair indents under the key" {
    const a = std.testing.allocator;
    var b = AST.Builder.init(a);
    defer b.deinit();

    // { audience: [ { outer: [1, 2] } ] } — a nested indentless sequence whose
    // dashes must sit at the key's column, not escape to the parent sequence's.
    const nums = try b.addSequence(&.{ try b.addInt(1), try b.addInt(2) });
    const item0 = try b.addMapping(&.{.{ .key = try b.addString("outer"), .value = nums }});
    const seq = try b.addSequence(&.{item0});
    const root = try b.addMapping(&.{.{ .key = try b.addString("audience"), .value = seq }});

    var ast = try b.finish(root);
    defer ast.deinit();

    var out: Writer.Allocating = .init(a);
    defer out.deinit();
    try print(&out.writer, &ast);
    try std.testing.expectEqualStrings(
        \\audience:
        \\- outer:
        \\  - 1
        \\  - 2
        \\
    , out.written());
}

/// Build `{ s: value }`, serialize it, and return the owned YAML (caller frees).
fn emitStringValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var b = AST.Builder.init(allocator);
    defer b.deinit();
    const v = try b.addString(value);
    const k = try b.addString("s");
    const root = try b.addMapping(&.{.{ .key = k, .value = v }});
    var ast = try b.finish(root);
    defer ast.deinit();

    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    try print(&out.writer, &ast);
    return allocator.dupe(u8, out.written());
}

test "yaml printer: multi-line string value emits a |- block scalar" {
    const yaml = try emitStringValue(std.testing.allocator, "multi\nline\ntext");
    defer std.testing.allocator.free(yaml);
    try std.testing.expectEqualStrings("s: |-\n  multi\n  line\n  text\n", yaml);
}

test "yaml printer: a trailing newline clips to |, two fall back to double-quote" {
    const clip = try emitStringValue(std.testing.allocator, "a\nb\n");
    defer std.testing.allocator.free(clip);
    try std.testing.expectEqualStrings("s: |\n  a\n  b\n", clip);

    const keep = try emitStringValue(std.testing.allocator, "a\nb\n\n");
    defer std.testing.allocator.free(keep);
    try std.testing.expectEqualStrings("s: \"a\\nb\\n\\n\"\n", keep);
}

test "yaml printer: indented interior lines still block-scalar (shell script shape)" {
    const yaml = try emitStringValue(std.testing.allocator, "if x; then\n  echo hi\nfi\n");
    defer std.testing.allocator.free(yaml);
    try std.testing.expectEqualStrings("s: |\n  if x; then\n    echo hi\n  fi\n", yaml);
}

test "yaml printer: block scalars round-trip through the parser" {
    const Parser = @import("parser.zig");
    const cases = [_][]const u8{
        "multi\nline\ntext", // clean -> |-
        "a\nb\n", // one trailing newline -> | (clip)
        "a\n\nb", // interior blank line
        "a\nb\n\n", // 2+ trailing newlines -> double-quote fallback
        "trailing \nspace", // trailing space on a line -> fallback
        " leading\nline", // leading space on FIRST line -> fallback (indent detection)
        "if x; then\n  echo hi\nfi\n", // indented INTERIOR lines -> | is fine
        "tab\there\nx", // interior tab is content -> | is fine
        "\rreturn\nx", // \r control char -> double-quote
    };
    for (cases) |s| {
        const yaml = try emitStringValue(std.testing.allocator, s);
        defer std.testing.allocator.free(yaml);

        var doc = try Parser.parse(std.testing.allocator, yaml, .v1_2_2);
        defer doc.deinit(std.testing.allocator);
        const root = doc.ast.nodes[doc.ast.root];
        const kv = doc.ast.nodes[root.kind.mapping.?].kind.keyvalue;
        try std.testing.expectEqualStrings(s, doc.ast.nodes[kv.value].kind.string);
    }
}
