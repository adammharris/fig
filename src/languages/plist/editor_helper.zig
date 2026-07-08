//! plist-specific editing helpers for `Editor(Plist)`.
//!
//! The generic span-splice engine lives in `../../editor.zig`; this module holds
//! the plist-only logic it delegates to. plist needs far MORE of its own logic
//! than TOML/YAML/fig/INI, because it is the one editable format that isn't
//! line-oriented `key<sep>value`: it's XML, so a dict entry is a *pair of
//! sibling elements* — `<key>name</key>` then a typed value element
//! (`<string>fig</string>`) — on two separate lines, and a value has no bare
//! literal spelling at all. That breaks every assumption the generic block-map
//! helpers make (`kv_sep`, one-line entries, splice-a-literal-value), so the
//! structural ops are implemented here from scratch:
//!
//!   - `renderValue`: the crux. A CLI value string (`fig set app.plist k=42`)
//!     has no plist meaning until it's wrapped in a typed element. We reuse the
//!     `.fig` dialect's own literal-else-string classifier (`sniffBare`) to pick
//!     the type — `true`/`false` → `<true/>`/`<false/>`, integer → `<integer>`,
//!     float → `<real>`, any datetime shape → `<date>`, everything else →
//!     `<string>` (XML-escaped). `null` has no plist type (`NullUnsupported`).
//!     A value that already starts with `<` is spliced VERBATIM — the escape
//!     hatch for `<data>` (which can't be sniffed from bare text), an explicit
//!     `<date>`, a nested `<dict>`/`<array>`, or forcing a type (`<string>2.0`).
//!   - `plistReplaceValue` (set/edit): render, then swap the value element's
//!     full-extent span.
//!   - `plistInsertKey`: append a two-line `<key>`/value entry to a `<dict>`,
//!     matching the existing children's indent (or expanding an empty
//!     `<dict/>`).
//!   - `plistAppendItem`/`plistPrependItem`: the array twins — a value element
//!     on its own line, no `- ` dash (that's the YAML/block-list shape the
//!     generic engine writes, which is why arrays can't ride it).
//!   - comment ops: `<!-- ... -->`, not a `#`/`//`/`;` line marker.
//!
//! What DOESN'T live here: delete-key and remove-seq-item. Once `comment_style`
//! is `.xml_comment` (see `editor.zig`), the generic line-based delete already
//! does the right thing — a plist entry/item occupies whole lines, and the
//! keyvalue's full-extent span (recorded by `parser.zig`) covers both the key
//! and value lines, so `lineStartBefore(span.start)`→`lineEndAfter(span.end)`
//! removes the entry cleanly, owned `<!-- -->` block and all. No plist branch
//! needed there.

const std = @import("std");
const testing = std.testing;

const AST = @import("../../ast/ast.zig");
const Document = @import("../../document.zig");
const Span = @import("../../util/span.zig");
const editor = @import("../../editor.zig");
const Plist = @import("plist.zig").Language;
// The `.fig` dialect's bare-token classifier — reused so plist value typing
// obeys the exact same literal-else-string rules the fig language documents
// (Norway-safe booleans, leading-zero-stays-string, datetime sniffing). Pure
// functions on caller-owned slices; compiles regardless of `-Dfig`.
const sniff = @import("../fig/tokenizer.zig");

/// The concrete editor these ops drive — the plist arm of the generic engine.
const PlistEditor = editor.Editor(Plist);

const lineStartBefore = editor.lineStartBefore;
const firstNonSpace = editor.firstNonSpace;

// ── value rendering ────────────────────────────────────────────────────────────

/// Render a CLI value string into a plist typed element, appended to `out`.
/// See the module header for the typing rules and the `<`-prefix escape hatch.
pub fn renderValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value_text: []const u8) !void {
    const t = std.mem.trim(u8, value_text, " \t\r\n");
    if (t.len > 0 and t[0] == '<') {
        // Explicit element (or element tree): the caller has spelled the plist
        // syntax themselves — splice it as-is. Reparse validates it; a bogus
        // `<foo` rolls back via `replaceAtSpan`.
        try out.appendSlice(allocator, t);
        return;
    }
    switch (sniff.sniffBare(t)) {
        .null_ => return error.NullUnsupported, // plist has no null primitive
        .boolean => |b| try out.appendSlice(allocator, if (b) "<true/>" else "<false/>"),
        .number => |n| try wrapText(allocator, out, if (n.kind == .integer) "integer" else "real", n.raw, false),
        .datetime => |d| try wrapText(allocator, out, "date", d.raw, false),
        .string => try wrapText(allocator, out, "string", t, true),
    }
}

/// `<tag>text</tag>`, XML-escaping `text` when `escape` (PCDATA content, i.e.
/// strings/keys — numbers and dates are already lexically safe).
fn wrapText(allocator: std.mem.Allocator, out: *std.ArrayList(u8), tag: []const u8, text: []const u8, escape: bool) !void {
    try out.append(allocator, '<');
    try out.appendSlice(allocator, tag);
    try out.append(allocator, '>');
    if (escape) try appendEscaped(allocator, out, text) else try out.appendSlice(allocator, text);
    try out.appendSlice(allocator, "</");
    try out.appendSlice(allocator, tag);
    try out.append(allocator, '>');
}

/// Escape `&`/`<`/`>` in PCDATA content (mirrors the printer's `writeEscaped`).
fn appendEscaped(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(allocator, "&amp;"),
        '<' => try out.appendSlice(allocator, "&lt;"),
        '>' => try out.appendSlice(allocator, "&gt;"),
        else => try out.append(allocator, c),
    };
}

// ── set / edit ─────────────────────────────────────────────────────────────────

/// Replace the value element at `node` (a value node from `getValByPath`) with
/// a freshly rendered typed element. The node's span is the whole
/// `<type>…</type>`, so this swaps the element wholesale — the plist analogue of
/// the line-oriented formats' in-place value splice.
pub fn plistReplaceValue(self: *PlistEditor, parsed: Document, node: AST.Node, replacement: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    try renderValue(self.allocator, &out, replacement);
    try self.replaceAtSpan(parsed.span(node), out.items);
}

// ── insert (dict) / append+prepend (array) ─────────────────────────────────────

/// Insert `<key>key_text</key>` + rendered value as a new entry in the `<dict>`
/// at `dict`. Appends after the last existing entry (matching its indent), or
/// expands an empty `<dict/>`/`<dict></dict>` into the multi-line form.
pub fn plistInsertKey(self: *PlistEditor, parsed: Document, dict: AST.Node, key_text: []const u8, value_text: []const u8) !void {
    if (dict.kind != .mapping) return error.NotAMapping;
    const source = self.source.items;

    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(self.allocator);
    try renderValue(self.allocator, &val, value_text);

    if (try parsed.ast.child(&dict)) |first_entry| {
        // Non-empty: splice after the last entry's value, on a fresh line at
        // the existing children's indentation.
        const indent = lineIndent(source, parsed.span(first_entry).start);
        const insert_at = parsed.span((try parsed.ast.lastChild(&dict)).?).end;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        try out.append(self.allocator, '\n');
        try appendDictEntry(self.allocator, &out, indent, key_text, val.items);
        try self.replaceAtSpan(Span.init(insert_at, insert_at), out.items);
    } else {
        try expandEmptyContainer(self, parsed, dict, "dict", key_text, val.items);
    }
}

/// Append a rendered value element as a new item to the `<array>` at `seq`.
pub fn plistAppendItem(self: *PlistEditor, parsed: Document, seq: AST.Node, value_text: []const u8) !void {
    const source = self.source.items;
    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(self.allocator);
    try renderValue(self.allocator, &val, value_text);

    if (try parsed.ast.child(&seq)) |first_item| {
        const indent = lineIndent(source, parsed.span(first_item).start);
        const insert_at = parsed.span((try parsed.ast.lastChild(&seq)).?).end;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        try out.append(self.allocator, '\n');
        try out.appendSlice(self.allocator, indent);
        try out.appendSlice(self.allocator, val.items);
        try self.replaceAtSpan(Span.init(insert_at, insert_at), out.items);
    } else {
        try expandEmptyContainer(self, parsed, seq, "array", null, val.items);
    }
}

/// Insert a rendered value element before the first item of the `<array>` at
/// `seq`.
pub fn plistPrependItem(self: *PlistEditor, parsed: Document, seq: AST.Node, value_text: []const u8) !void {
    const source = self.source.items;
    var val: std.ArrayList(u8) = .empty;
    defer val.deinit(self.allocator);
    try renderValue(self.allocator, &val, value_text);

    if (try parsed.ast.child(&seq)) |first_item| {
        const item_start = parsed.span(first_item).start;
        const indent = lineIndent(source, item_start);
        const line_start = lineStartBefore(source, item_start);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, indent);
        try out.appendSlice(self.allocator, val.items);
        try out.append(self.allocator, '\n');
        try self.replaceAtSpan(Span.init(line_start, line_start), out.items);
    } else {
        try expandEmptyContainer(self, parsed, seq, "array", null, val.items);
    }
}

/// Rewrite an empty `<dict/>`/`<array/>` (or `<…></…>`) into the multi-line
/// form holding one entry/item. `key_text != null` → a dict entry (a
/// `<key>`/value pair); null → a bare array item.
fn expandEmptyContainer(self: *PlistEditor, parsed: Document, container: AST.Node, tag: []const u8, key_text: ?[]const u8, rendered_value: []const u8) !void {
    const source = self.source.items;
    const span = parsed.span(container);
    const base = lineIndent(source, span.start);
    const unit = indentUnit(source);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    try out.append(self.allocator, '<');
    try out.appendSlice(self.allocator, tag);
    try out.appendSlice(self.allocator, ">\n");
    if (key_text) |k| {
        var child_indent: std.ArrayList(u8) = .empty;
        defer child_indent.deinit(self.allocator);
        try child_indent.appendSlice(self.allocator, base);
        try child_indent.appendSlice(self.allocator, unit);
        try appendDictEntry(self.allocator, &out, child_indent.items, k, rendered_value);
    } else {
        try out.appendSlice(self.allocator, base);
        try out.appendSlice(self.allocator, unit);
        try out.appendSlice(self.allocator, rendered_value);
    }
    try out.append(self.allocator, '\n');
    try out.appendSlice(self.allocator, base);
    try out.appendSlice(self.allocator, "</");
    try out.appendSlice(self.allocator, tag);
    try out.append(self.allocator, '>');
    try self.replaceAtSpan(span, out.items);
}

/// `<indent><key>key</key>\n<indent><value…>` — a dict entry's two lines, the
/// key and value at the same indent (matching the printer's layout).
fn appendDictEntry(allocator: std.mem.Allocator, out: *std.ArrayList(u8), indent: []const u8, key: []const u8, rendered_value: []const u8) !void {
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, "<key>");
    try appendEscaped(allocator, out, key);
    try out.appendSlice(allocator, "</key>\n");
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, rendered_value);
}

// ── comments (`<!-- ... -->`) ──────────────────────────────────────────────────

/// Insert own-line `<!-- text -->` comment line(s) immediately above the entry
/// at `path`, at its indentation. Multi-line `text` becomes one comment line
/// per line. XML forbids `--` inside a comment, so text containing it is
/// refused (`InvalidComment`) rather than emitted as malformed markup.
pub fn plistAddLeadingComment(self: *PlistEditor, path: []const AST.PathSegment, text: []const u8) !void {
    if (std.mem.indexOf(u8, text, "--") != null) return error.InvalidComment;
    const parsed = try self.getParsed();
    const node = try parsed.ast.getNodeByPath(path);
    const source = self.source.items;
    const line_start = lineStartBefore(source, parsed.span(node).start);
    const indent = source[line_start..firstNonSpace(source, line_start)];

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try out.appendSlice(self.allocator, indent);
        try out.appendSlice(self.allocator, "<!-- ");
        try out.appendSlice(self.allocator, line);
        try out.appendSlice(self.allocator, " -->\n");
    }
    try self.replaceAtSpan(Span.init(line_start, line_start), out.items);
}

/// Remove the owned run of `<!-- -->` comment lines immediately above the entry
/// at `path` (contiguous, no blank line between — the same block the generic
/// delete carries). A no-op when there is none.
pub fn plistDeleteLeadingComments(self: *PlistEditor, path: []const AST.PathSegment) !void {
    const parsed = try self.getParsed();
    const node = try parsed.ast.getNodeByPath(path);
    const source = self.source.items;
    const line_start = lineStartBefore(source, parsed.span(node).start);
    const block_start = editor.commentBlockStart(source, line_start, .xml_comment);
    if (block_start == line_start) return;
    try self.replaceAtSpan(Span.init(block_start, line_start), "");
}

/// Read back the owned `<!-- -->` comment block above the entry at `path`, with
/// each line's indent and `<!-- ` / ` -->` delimiters stripped, rejoined by
/// '\n'. Null when there is no block. Caller owns the returned bytes.
pub fn plistGetLeadingComment(self: *PlistEditor, path: []const AST.PathSegment) !?[]u8 {
    const parsed = try self.getParsed();
    const node = try parsed.ast.getNodeByPath(path);
    const source = self.source.items;
    const line_start = lineStartBefore(source, parsed.span(node).start);
    const block_start = editor.commentBlockStart(source, line_start, .xml_comment);
    if (block_start == line_start) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(self.allocator);
    var it = std.mem.splitScalar(u8, source[block_start..line_start], '\n');
    var first = true;
    while (it.next()) |raw| {
        const trimmed = std.mem.trimStart(u8, std.mem.trimEnd(u8, raw, "\r"), " \t");
        if (trimmed.len == 0) continue;
        if (!first) try out.append(self.allocator, '\n');
        first = false;
        try out.appendSlice(self.allocator, stripCommentDelimiters(trimmed));
    }
    return try out.toOwnedSlice(self.allocator);
}

/// Set the same-line trailing comment on the value at `path`: replace an
/// existing `<!-- -->` after the value element, or append one. `text` must be a
/// single line and free of `--`.
pub fn plistSetTrailingComment(self: *PlistEditor, path: []const AST.PathSegment, text: []const u8) !void {
    if (std.mem.indexOfScalar(u8, text, '\n') != null) return error.MultilineComment;
    if (std.mem.indexOf(u8, text, "--") != null) return error.InvalidComment;
    const win = try trailingWindow(self, path);
    const source = self.source.items;

    var cut = if (std.mem.indexOf(u8, source[win.start..win.line_end], "<!--")) |rel|
        win.start + rel
    else
        win.line_end;
    while (cut > win.start and (source[cut - 1] == ' ' or source[cut - 1] == '\t')) cut -= 1;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    try out.appendSlice(self.allocator, " <!-- ");
    try out.appendSlice(self.allocator, text);
    try out.appendSlice(self.allocator, " -->");
    try self.replaceAtSpan(Span.init(cut, win.line_end), out.items);
}

/// Remove the same-line trailing `<!-- -->` on the value at `path`, if any.
pub fn plistDeleteTrailingComment(self: *PlistEditor, path: []const AST.PathSegment) !void {
    const win = try trailingWindow(self, path);
    const source = self.source.items;
    const rel = std.mem.indexOf(u8, source[win.start..win.line_end], "<!--") orelse return;
    var cut = win.start + rel;
    while (cut > win.start and (source[cut - 1] == ' ' or source[cut - 1] == '\t')) cut -= 1;
    try self.replaceAtSpan(Span.init(cut, win.line_end), "");
}

/// Read back the same-line trailing `<!-- -->` on the value at `path`, delimiters
/// stripped. Null when there is none. Caller owns the returned bytes.
pub fn plistGetTrailingComment(self: *PlistEditor, path: []const AST.PathSegment) !?[]u8 {
    const win = try trailingWindow(self, path);
    const source = self.source.items;
    const rel = std.mem.indexOf(u8, source[win.start..win.line_end], "<!--") orelse return null;
    const raw = std.mem.trimEnd(u8, source[win.start + rel .. win.line_end], " \t\r");
    return try self.allocator.dupe(u8, stripCommentDelimiters(raw));
}

/// The `[start, line_end)` window just past the value element at `path` where a
/// same-line trailing comment lives.
fn trailingWindow(self: *PlistEditor, path: []const AST.PathSegment) !struct { start: usize, line_end: usize } {
    const parsed = try self.getParsed();
    const val = try parsed.ast.getValByPath(path);
    const source = self.source.items;
    const start = parsed.span(val).end;
    const line_end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
    return .{ .start = start, .line_end = line_end };
}

/// Strip `<!--`/`-->` and the surrounding whitespace from a single-line comment.
fn stripCommentDelimiters(s: []const u8) []const u8 {
    var inner = s;
    if (std.mem.startsWith(u8, inner, "<!--")) inner = inner[4..];
    if (std.mem.endsWith(u8, inner, "-->")) inner = inner[0 .. inner.len - 3];
    return std.mem.trim(u8, inner, " \t");
}

// ── shared indentation helpers ─────────────────────────────────────────────────

/// The leading whitespace (indent) of the line containing byte `at`.
fn lineIndent(source: []const u8, at: usize) []const u8 {
    const ls = lineStartBefore(source, at);
    return source[ls..firstNonSpace(source, ls)];
}

/// One indentation unit for this document: the leading whitespace of the first
/// indented element line. A plist's first child sits exactly one level in, so
/// its own indent IS the unit — tabs for Xcode/`plutil`, two spaces for fig's
/// printer. Falls back to two spaces for a single-line/compact document.
fn indentUnit(source: []const u8) []const u8 {
    var ls: usize = 0;
    while (ls < source.len) {
        const le = std.mem.indexOfScalarPos(u8, source, ls, '\n') orelse source.len;
        const fns = firstNonSpace(source, ls);
        if (fns > ls and fns < le and source[fns] == '<') return source[ls..fns];
        if (le == source.len) break;
        ls = le + 1;
    }
    return "  ";
}

// ── tests ────────────────────────────────────────────────────────────────────

const wrapper =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
;

fn expectEdit(comptime op: []const u8, src: []const u8, args: anytype, expected: []const u8) !void {
    var ed: PlistEditor = .{ .allocator = testing.allocator, .format = .XML };
    try ed.init(src);
    defer ed.deinit();
    try @call(.auto, @field(PlistEditor, op), .{&ed} ++ args);
    try testing.expectEqualStrings(expected, ed.source.items);
}

test "renderValue: fig sniffBare picks the typed element" {
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "42", .out = "<integer>42</integer>" },
        .{ .in = "-7", .out = "<integer>-7</integer>" },
        .{ .in = "3.14", .out = "<real>3.14</real>" },
        .{ .in = "true", .out = "<true/>" },
        .{ .in = "false", .out = "<false/>" },
        .{ .in = "hello", .out = "<string>hello</string>" },
        .{ .in = "007", .out = "<string>007</string>" }, // leading zero stays string
        .{ .in = "Yes", .out = "<string>Yes</string>" }, // Norway-safe
        .{ .in = "2026-07-08", .out = "<date>2026-07-08</date>" },
        .{ .in = "a < b & c", .out = "<string>a &lt; b &amp; c</string>" },
        .{ .in = "<data>SGk=</data>", .out = "<data>SGk=</data>" }, // escape hatch
        .{ .in = "<string>2.0</string>", .out = "<string>2.0</string>" }, // force string
    };
    for (cases) |c| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try renderValue(testing.allocator, &out, c.in);
        try testing.expectEqualStrings(c.out, out.items);
    }
}

test "renderValue: null has no plist type" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.NullUnsupported, renderValue(testing.allocator, &out, "null"));
}

test "set replaces a value, preserving or changing type by autodetection" {
    // string -> string
    try expectEdit("set", "<dict><key>name</key><string>fig</string></dict>", .{ &[_]AST.PathSegment{.{ .key = "name" }}, "zig" }, "<dict><key>name</key><string>zig</string></dict>");
    // autodetect promotes to integer
    try expectEdit("set", "<dict><key>n</key><integer>1</integer></dict>", .{ &[_]AST.PathSegment{.{ .key = "n" }}, "99" }, "<dict><key>n</key><integer>99</integer></dict>");
    // escape hatch forces string over a numeric-looking value
    try expectEdit("set", "<dict><key>v</key><string>1.0</string></dict>", .{ &[_]AST.PathSegment{.{ .key = "v" }}, "<string>2.0</string>" }, "<dict><key>v</key><string>2.0</string></dict>");
}

test "insertKey appends a two-line entry at the children's indent" {
    try expectEdit(
        "insertKey",
        wrapper ++ "\n<dict>\n  <key>a</key>\n  <integer>1</integer>\n</dict>\n</plist>\n",
        .{ &[_]AST.PathSegment{}, "b", "hello" },
        wrapper ++ "\n<dict>\n  <key>a</key>\n  <integer>1</integer>\n  <key>b</key>\n  <string>hello</string>\n</dict>\n</plist>\n",
    );
}

test "insertKey expands an empty <dict/>" {
    try expectEdit(
        "insertKey",
        wrapper ++ "\n<dict/>\n</plist>\n",
        .{ &[_]AST.PathSegment{}, "a", "1" },
        wrapper ++ "\n<dict>\n  <key>a</key>\n  <integer>1</integer>\n</dict>\n</plist>\n",
    );
}

test "deleteKey (generic path, xml_comment style) removes the whole entry" {
    try expectEdit(
        "deleteKey",
        wrapper ++ "\n<dict>\n  <key>a</key>\n  <integer>1</integer>\n  <key>b</key>\n  <string>x</string>\n</dict>\n</plist>\n",
        .{&[_]AST.PathSegment{.{ .key = "a" }}},
        wrapper ++ "\n<dict>\n  <key>b</key>\n  <string>x</string>\n</dict>\n</plist>\n",
    );
}

test "array append and prepend put an element on its own line (no dash)" {
    try expectEdit(
        "appendToSeq",
        wrapper ++ "\n<array>\n  <string>one</string>\n</array>\n</plist>\n",
        .{ &[_]AST.PathSegment{}, "two" },
        wrapper ++ "\n<array>\n  <string>one</string>\n  <string>two</string>\n</array>\n</plist>\n",
    );
    try expectEdit(
        "prependToSeq",
        wrapper ++ "\n<array>\n  <string>one</string>\n</array>\n</plist>\n",
        .{ &[_]AST.PathSegment{}, "zero" },
        wrapper ++ "\n<array>\n  <string>zero</string>\n  <string>one</string>\n</array>\n</plist>\n",
    );
}

test "leading comment add / get / delete round-trips through <!-- -->" {
    var ed: PlistEditor = .{ .allocator = testing.allocator, .format = .XML };
    try ed.init(wrapper ++ "\n<dict>\n  <key>a</key>\n  <integer>1</integer>\n</dict>\n</plist>\n");
    defer ed.deinit();
    const path = &[_]AST.PathSegment{.{ .key = "a" }};
    try ed.addLeadingComment(path, "the answer");
    try testing.expect(std.mem.indexOf(u8, ed.source.items, "<!-- the answer -->") != null);
    const got = (try ed.getLeadingComment(path)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("the answer", got);
    try ed.deleteLeadingComments(path);
    try testing.expect(std.mem.indexOf(u8, ed.source.items, "<!--") == null);
}

test "trailing comment set / get on a value element" {
    var ed: PlistEditor = .{ .allocator = testing.allocator, .format = .XML };
    try ed.init(wrapper ++ "\n<dict>\n  <key>a</key>\n  <integer>1</integer>\n</dict>\n</plist>\n");
    defer ed.deinit();
    const path = &[_]AST.PathSegment{.{ .key = "a" }};
    try ed.setTrailingComment(path, "note");
    try testing.expect(std.mem.indexOf(u8, ed.source.items, "<integer>1</integer> <!-- note -->") != null);
    const got = (try ed.getTrailingComment(path)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("note", got);
}
