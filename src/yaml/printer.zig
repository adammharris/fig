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
                if (!try tryWriteBlockStringValue(writer, document, id, depth + 1)) {
                    try printInlineValue(writer, document, id);
                    try writer.writeByte('\n');
                }
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
                // Indentless: a sequence value's dashes sit at the key's column.
                try printSequence(writer, document, child, depth);
            }
        },
        else => {
            try writer.writeAll(": ");
            if (!try tryWriteBlockStringValue(writer, document, kv.value, depth + 1)) {
                try printInlineValue(writer, document, kv.value);
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
/// with leading/trailing whitespace (indentation / trailing-space ambiguity),
/// and 2+ trailing newlines (which would need the `|+` keep indicator). Anything
/// rejected here is double-quoted instead, which always round-trips.
fn blockScalarOk(s: []const u8) bool {
    if (std.mem.indexOfScalar(u8, s, '\n') == null) return false;
    if (std.mem.endsWith(u8, s, "\n\n")) return false;
    const body = if (std.mem.endsWith(u8, s, "\n")) s[0 .. s.len - 1] else s;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue; // interior blank lines are fine (emitted empty)
        if (line[0] == ' ' or line[0] == '\t') return false;
        if (line[line.len - 1] == ' ' or line[line.len - 1] == '\t') return false;
        for (line) |c| if (c < 0x20 or c == 0x7f) return false;
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

test "prints YAML document" {
    // Native is the AST-literal syntax here — this test's subject is YAML
    // printing, not JSON reading.
    const Parser = @import("../native/parser.zig");
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

test "yaml printer: block scalars round-trip through the parser" {
    const Parser = @import("parser.zig");
    const cases = [_][]const u8{
        "multi\nline\ntext", // clean -> |-
        "a\nb\n", // one trailing newline -> | (clip)
        "a\n\nb", // interior blank line
        "a\nb\n\n", // 2+ trailing newlines -> double-quote fallback
        "trailing \nspace", // trailing space on a line -> fallback
        " leading\nline", // leading space on first line -> fallback
        "tab\there\nx", // control char other than \n -> double-quote
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
