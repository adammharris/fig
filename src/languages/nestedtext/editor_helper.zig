//! NestedText-specific editing helpers for `Editor(NestedText)`.
//!
//! The generic span-splice engine lives in `../../editor.zig`; this module
//! holds the NestedText-only logic it delegates to, mirroring TOML/YAML/fig/
//! plist's own `editor_helper.zig` split. NestedText needs MORE of its own
//! logic than any format but plist, for two independent reasons:
//!
//!   1. **Value framing.** Every value here is untyped text (no typed/quoted
//!      literal syntax to splice verbatim the way YAML/TOML/fig do), so a
//!      caller-supplied `value_text` is always a raw scalar that must be
//!      RENDERED into this grammar's own same-line-vs-nested-`>`-block form:
//!      non-empty and free of `\n` stays on the same line (`key: value` /
//!      `- value`); empty or multi-line becomes a nested `>`-block, one line
//!      per physical line, at 4 extra spaces of indent (mirroring
//!      `printer.zig`'s fixed `indent_width` — hardcoded like YAML/TOML's own
//!      `col + 2`, not sniffed from the document). This also means `set`/
//!      `replaceValAtPath` needs a real reframe (like YAML/fig's own): the
//!      NEW value's shape can differ from the OLD one's (inline <-> nested),
//!      so the whole `key`-to-value-end (or `-`-to-value-end) region gets
//!      regenerated rather than splicing into the old value's slot.
//!   2. **Sequence items have no keyvalue-shaped wrapper node.** A mapping
//!      entry's `.keyvalue` node spans from its KEY's own line (always,
//!      regardless of where the value ends up), so the generic engine's
//!      line-position math already works for mapping entries with no
//!      NestedText-specific help. A sequence item is just its bare value
//!      node re-used as the sequence's child directly — and NestedText,
//!      unlike YAML in practice, allows genuinely NOTHING after a `-` on its
//!      own line whenever the value is nested/empty (a same-line `- key:
//!      value` is parsed as the LITERAL string `"key: value"`, never a
//!      nested mapping — see `parser.zig`'s module doc, "region" algorithm).
//!      So an item's OWN span can start on a later line than its `-`,
//!      breaking every generic helper that assumes otherwise: `appendToSeq`/
//!      `prependToSeq`'s `dashColumn` (reads the column off the wrong line),
//!      `removeSeqItem`/`moveItem`/`reorderItems`'s block-boundary math, and
//!      the leading-comment ops when `path` ends in `.index`. This module's
//!      `dashPosAfterPrev`/`seqItemLineStart`/`dashPosByIndex` recover the
//!      real `-` position by scanning from a known-good anchor (the
//!      sequence's own span, which — like a `.keyvalue`'s — is always
//!      anchored at the FIRST item's `-` line) instead of trusting the
//!      target item's own span.
//!
//! **Deliberately out of scope** (declined with a clear error rather than
//! guessed at): inserting into a genuinely EMPTY inline `{}`/`[]` container.
//! NestedText's reader accepts these as childless `.mapping`/`.sequence`
//! nodes (unlike a block dict/list, which always has >=1 entry by
//! construction — see `parser.zig`'s `parseContainerAt`), but the printer
//! never emits them and expanding one into block form is a `plist`-style
//! "expand empty container" transform this session didn't have budget for;
//! `ntInsertKey`/`ntAppendItem`/`ntPrependItem` all raise
//! `error.EmptyInlineContainer` there instead of silently doing nothing (or
//! something wrong). `set`'s auto-vivify (`editor.zig`) excludes NestedText
//! for the same reason: its seed IS exactly this shape, which would only
//! defer the same error by one step. Also out of scope: a `value_text`
//! that's itself a nested container fragment (inserting/setting a whole new
//! sub-mapping/sub-list via CLI text) — every op here treats `value_text` as
//! a raw SCALAR string, matching NestedText's own "strings all the way down"
//! design; structural composition of brand-new nested containers isn't
//! exposed by this editor (existing containers can still be freely
//! inserted-into/deleted-from/reordered).

const std = @import("std");
const testing = std.testing;

const AST = @import("../../ast/ast.zig");
const Document = @import("../../document.zig");
const Span = @import("../../util/span.zig");
const editor = @import("../../editor.zig");
const NestedText = @import("nestedtext.zig").Language;

/// The concrete editor these ops drive — the NestedText arm of the generic engine.
const NtEditor = editor.Editor(NestedText);

const lineStartBefore = editor.lineStartBefore;
const lineEndAfter = editor.lineEndAfter;
const firstNonSpace = editor.firstNonSpace;
const columnOf = editor.columnOf;

/// Matches `printer.zig`'s own `indent_width` — NestedText only requires a
/// nested region's indent to be GREATER than its parent's (any amount), but
/// this editor always writes the same fixed step the printer does, exactly
/// like YAML/TOML hardcode `col + 2` rather than sniffing the document's own
/// convention.
const indent_width: usize = 4;

// ── Value rendering ──────────────────────────────────────────────────────────

/// Append the tail of a `key:`/`-` line already written up to (not including)
/// its own line terminator: `" " ++ text` when `text` fits on the same line
/// (non-empty, no literal `\n`) and isn't `force_nested`; otherwise a nested
/// `>`-block, one line per physical line of `text` (an empty line becomes a
/// bare `>`), each at `child_col` spaces — mirroring `printer.zig`'s
/// `writeStringBlock`. Never emits a trailing newline after the last line
/// (the caller decides whether one is needed — see `ntReplaceValue`).
fn appendValueTail(allocator: std.mem.Allocator, out: *std.ArrayList(u8), child_col: usize, text: []const u8, force_nested: bool) !void {
    if (!force_nested and text.len != 0 and std.mem.indexOfScalar(u8, text, '\n') == null) {
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, text);
        return;
    }
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try out.append(allocator, '\n');
        try out.appendNTimes(allocator, ' ', child_col);
        if (line.len == 0) {
            try out.append(allocator, '>');
        } else {
            try out.appendSlice(allocator, "> ");
            try out.appendSlice(allocator, line);
        }
    }
}

/// Render `text` as a ROOT document value: a `>`-block at column 0, no
/// leading marker (the whole-document root has no `key:`/`-` to follow) and
/// always nested — a bare top-level scalar line has no grammar at all (see
/// `parser.zig`: an unrecognized `.other` line at the top level is a parse
/// error; only dict/list/string(`>`)/inline forms are valid there).
fn appendRootBlock(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        if (line.len == 0) {
            try out.append(allocator, '>');
        } else {
            try out.appendSlice(allocator, "> ");
            try out.appendSlice(allocator, line);
        }
    }
}

/// Whether `key` needs the `: key` multiline form instead of plain `key:` —
/// ported verbatim from `printer.zig`'s `needsMultilineKey` so a freshly
/// inserted/renamed key round-trips exactly the way the printer would have
/// written it.
fn needsMultilineKey(key: []const u8) bool {
    if (key.len == 0) return true;
    const c0 = key[0];
    if (c0 == '#' or c0 == '{' or c0 == '[' or c0 == ' ' or c0 == '\t') return true;
    if ((c0 == '-' or c0 == ':' or c0 == '>') and (key.len == 1 or key[1] == ' ')) return true;
    if (std.mem.indexOfScalar(u8, key, '\n') != null) return true;
    if (std.mem.indexOf(u8, key, ": ") != null) return true;
    return false;
}

/// Append `key`'s multiline `: line` form (one `: line` — or bare `:` for an
/// empty line — per physical line of `key`, each at `col` spaces), mirroring
/// `printer.zig`'s `writeMultilineKeyLines`. No leading/trailing newline (the
/// caller sequences it against whatever follows), matching `appendValueTail`'s
/// convention.
fn appendMultilineKeyLines(allocator: std.mem.Allocator, out: *std.ArrayList(u8), col: usize, key: []const u8) !void {
    var it = std.mem.splitScalar(u8, key, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        try out.appendNTimes(allocator, ' ', col);
        if (line.len == 0) {
            try out.append(allocator, ':');
        } else {
            try out.appendSlice(allocator, ": ");
            try out.appendSlice(allocator, line);
        }
    }
}

/// Whether the key at `key_span` is currently written in MULTILINE (`: key`)
/// form rather than plain (`key:`) form. A multiline key's physical FIRST
/// line, once you skip its indentation, starts with a `:` tag exactly like a
/// tokenizer `.colon` line (`:` at end-of-line, or `:` followed by a space) —
/// a plain key's line can never start that way (the tokenizer would have
/// dispatched it as a multiline-key line to begin with, never handing the
/// parser's `.other`/plain-key path a leading `": "`/bare-`:` to trip over),
/// so this check is exact, not a heuristic.
fn isMultilineKeySpan(source: []const u8, key_span: Span) bool {
    const line_start = lineStartBefore(source, key_span.start);
    const fns = firstNonSpace(source, line_start);
    if (fns >= source.len or source[fns] != ':') return false;
    if (fns + 1 >= source.len) return true;
    const c = source[fns + 1];
    return c == ' ' or c == '\n' or c == '\r';
}

/// Whether a value's span is the implicit empty-string SENTINEL (an omitted
/// `key:`/`-` with nothing more-indented following — see `parser.zig`'s
/// `MissingBehavior.empty_string`): its zero-width span sits at the START of
/// whatever comes next (a dedented sibling's line, or EOF) rather than just
/// before its own line's `\n` the way every other value shape's span does
/// (same-line scalar, nested container, or an explicit `>`-block, even an
/// empty one — `parseContainerAt`/`parseStringBlock` never produce a
/// zero-width span). `ntReplaceValue` uses this to decide whether the
/// replacement needs to supply its OWN trailing newline (sentinel: yes,
/// nothing to reuse) or can rely on the original line's `\n` riding along
/// just past the splice (every other shape: no).
fn isEmptySentinel(span: Span) bool {
    return span.len() == 0;
}

// ── Sequence item dash-position recovery ────────────────────────────────────

/// Byte position of the `-` introducing the sequence item that immediately
/// follows `prev` (or the FIRST item, when `prev` is null) in `seq`. For the
/// first item this is recovered from the sequence node's own span — which,
/// like a `.keyvalue`'s, is always anchored at the `-` line that started the
/// block (see `parser.zig`'s `parseListBlock`) — regardless of whether that
/// first item's own value is nested. For a later item, scans forward from
/// `prev`'s owned content to the next real content line, skipping blank and
/// comment lines exactly as `parser.zig`'s own `probeNext`/`skipBlank` do (so
/// a leading comment immediately above the next item is correctly left
/// un-skipped-past — it's that item's, not `prev`'s).
fn dashPosAfterPrev(source: []const u8, parsed: Document, seq: AST.Node, prev: ?AST.Node) usize {
    if (prev) |p| return firstNonSpace(source, nextContentLineStart(source, parsed.span(p).end));
    return firstNonSpace(source, parsed.span(seq).start);
}

/// `dashPosAfterPrev`, but by ordinal `index` (0-based) rather than an
/// already-in-hand `prev` node — for call sites (comment ops, `set`) that
/// only have a `PathSegment.index`, not a live traversal cursor.
fn dashPosByIndex(source: []const u8, parsed: Document, seq: AST.Node, index: usize) !usize {
    if (index == 0) return dashPosAfterPrev(source, parsed, seq, null);
    var prev = (try parsed.ast.child(&seq)) orelse return error.NotFound;
    var i: usize = 0;
    while (i < index - 1) : (i += 1) prev = parsed.ast.next(&prev) orelse return error.NotFound;
    return dashPosAfterPrev(source, parsed, seq, prev);
}

/// Scan forward from byte `from` (the end of a sibling's owned content) past
/// any blank/comment lines to the start of the next real content line — the
/// only two things NestedText's grammar allows between block siblings (see
/// `parser.zig`'s `skipBlank`/`probeNext`), so the line this lands on is
/// guaranteed to be the next sibling's own tag line (or a leading comment
/// belonging to it, which is exactly what a caller computing a comment-aware
/// block boundary wants to land on next).
fn nextContentLineStart(source: []const u8, from: usize) usize {
    var i = lineEndAfter(source, from);
    while (i < source.len) {
        const line_end = lineEndAfter(source, i);
        const fns = firstNonSpace(source, i);
        const is_blank = fns >= source.len or fns >= line_end or source[fns] == '\n' or source[fns] == '\r';
        const is_comment = !is_blank and source[fns] == '#';
        if (is_blank or is_comment) {
            i = line_end;
            continue;
        }
        return i;
    }
    return i;
}

/// The line start to anchor a leading-comment op on, for a `path` whose final
/// segment is `.index` — `editor.zig` falls back to this instead of the
/// generic `lineStartBefore(source, span.start)` there (see this module's
/// doc, point 2).
pub fn seqItemLineStart(source: []const u8, parsed: Document, path: []const AST.PathSegment) !usize {
    const seq = try parsed.ast.getValByPath(path[0 .. path.len - 1]);
    if (seq.kind != .sequence) return error.NotASequence;
    const dash_pos = try dashPosByIndex(source, parsed, seq, path[path.len - 1].index);
    return lineStartBefore(source, dash_pos);
}

// ── insertKey ────────────────────────────────────────────────────────────────

/// Insert a `key_text:`/`: key_text` entry (rendering `value_text` same-line
/// or as a nested `>`-block per its shape) into the mapping at `node` — the
/// root promoted from an empty document (`.null_`), or an existing non-empty
/// block mapping. See the module doc for why a childless (inline `{}`)
/// mapping is declined rather than expanded.
pub fn ntInsertKey(self: *NtEditor, parsed: Document, node: AST.Node, key_text: []const u8, value_text: []const u8) !void {
    const source = self.source.items;
    switch (node.kind) {
        .null_ => {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);
            try appendKeyLine(self.allocator, &out, 0, key_text, value_text);
            try self.replaceAtSpan(Span.init(0, source.len), out.items);
        },
        .mapping => {
            if (try parsed.ast.child(&node) == null) return error.EmptyInlineContainer;
            const col = columnOf(source, firstNonSpace(source, parsed.span(node).start));
            const last = (try parsed.ast.lastChild(&node)).?;
            const insert_at = lineEndAfter(source, parsed.span(last).end -| 1);
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);
            if (insert_at > 0 and source[insert_at - 1] != '\n') try out.append(self.allocator, '\n');
            try appendKeyLine(self.allocator, &out, col, key_text, value_text);
            try self.replaceAtSpan(Span.init(insert_at, insert_at), out.items);
        },
        else => return error.NotAMapping,
    }
}

/// `col`-indented `key_text:`/`: key_text` line (plain vs. multiline form per
/// `needsMultilineKey`) plus its rendered value, terminated by a single `\n`.
fn appendKeyLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), col: usize, key_text: []const u8, value_text: []const u8) !void {
    if (needsMultilineKey(key_text)) {
        try appendMultilineKeyLines(allocator, out, col, key_text);
        // A multiline key's value has no same-line form at all — always nested.
        try appendValueTail(allocator, out, col + indent_width, value_text, true);
    } else {
        try out.appendNTimes(allocator, ' ', col);
        try out.appendSlice(allocator, key_text);
        try out.append(allocator, ':');
        try appendValueTail(allocator, out, col + indent_width, value_text, false);
    }
    try out.append(allocator, '\n');
}

// ── set / replaceValAtPath ───────────────────────────────────────────────────

/// Replace the value at `path` (root, a `.key`, or an `.index`) by reframing
/// from just past its key/dash through the old value's end with a freshly
/// rendered `replacement` — see the module doc's "value framing" point for
/// why a direct span splice (as most other languages' generic path does)
/// can't work here. Overwrites whatever the old value's shape was (scalar or
/// a whole nested container) with the new scalar `replacement` wholesale.
pub fn ntReplaceValue(self: *NtEditor, parsed: Document, path: []const AST.PathSegment, span: Span, replacement: []const u8) !void {
    const source = self.source.items;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    const needs_own_newline = isEmptySentinel(span);

    if (path.len == 0) {
        try appendRootBlock(self.allocator, &out, replacement);
        if (needs_own_newline) try out.append(self.allocator, '\n');
        try self.replaceAtSpan(Span.init(0, span.end), out.items);
        return;
    }

    switch (path[path.len - 1]) {
        .key => {
            const key_node = try parsed.ast.getKeyByPath(path);
            const key_span = parsed.span(key_node);
            const col = columnOf(source, firstNonSpace(source, lineStartBefore(source, key_span.start)));
            const multiline_key = isMultilineKeySpan(source, key_span);
            if (!multiline_key) try out.append(self.allocator, ':');
            try appendValueTail(self.allocator, &out, col + indent_width, replacement, multiline_key);
            if (needs_own_newline) try out.append(self.allocator, '\n');
            try self.replaceAtSpan(Span.init(key_span.end, span.end), out.items);
        },
        .index => |idx| {
            const seq = try parsed.ast.getValByPath(path[0 .. path.len - 1]);
            if (seq.kind != .sequence) return error.NotASequence;
            const dash_pos = try dashPosByIndex(source, parsed, seq, idx);
            const col = columnOf(source, dash_pos);
            try appendValueTail(self.allocator, &out, col + indent_width, replacement, false);
            if (needs_own_newline) try out.append(self.allocator, '\n');
            try self.replaceAtSpan(Span.init(dash_pos + 1, span.end), out.items);
        },
    }
}

// ── replaceKeyAtPath ─────────────────────────────────────────────────────────

/// Rename the key at `path` to `new_key_text`. Plain-to-plain and
/// multiline-to-multiline rename in place (the colon, when present, sits
/// outside the key's own span either way, so it's untouched); multiline-to-
/// plain adds the trailing `:` a plain key needs (a multiline key's span
/// carries no separator colon anywhere — see the module's `isMultilineKeySpan`
/// doc). Plain-to-multiline is declined (`error.KeyRequiresMultilineForm`):
/// when the current value is on the SAME line as the key, switching key forms
/// would also have to relocate the value onto a nested line (multiline keys
/// never have a same-line value), which is a value reframe this op doesn't
/// attempt — delete and re-insert the entry instead.
pub fn ntReplaceKey(self: *NtEditor, parsed: Document, path: []const AST.PathSegment, new_key_text: []const u8) !void {
    const source = self.source.items;
    const key_node = try parsed.ast.getKeyByPath(path);
    const key_span = parsed.span(key_node);
    const was_multiline = isMultilineKeySpan(source, key_span);
    const wants_multiline = needsMultilineKey(new_key_text);
    if (wants_multiline and !was_multiline) return error.KeyRequiresMultilineForm;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    if (wants_multiline) {
        const col = columnOf(source, lineStartBefore(source, key_span.start));
        try appendMultilineKeyLines(self.allocator, &out, col, new_key_text);
    } else if (was_multiline) {
        try out.appendSlice(self.allocator, new_key_text);
        try out.append(self.allocator, ':');
    } else {
        try out.appendSlice(self.allocator, new_key_text);
    }
    try self.replaceAtSpan(key_span, out.items);
}

// ── append / prepend ─────────────────────────────────────────────────────────

/// Append `value_text` (rendered same-line or as a nested `>`-block) as a new
/// last item of the block sequence `seq`. `seq` is always non-empty here — a
/// genuinely empty sequence can only be the inline `[]` form, which
/// `editor.zig`'s `isFlow` check routes to the generic flow-item path before
/// this is ever reached.
pub fn ntAppendItem(self: *NtEditor, parsed: Document, seq: AST.Node, value_text: []const u8) !void {
    const source = self.source.items;
    const dash_col = columnOf(source, firstNonSpace(source, parsed.span(seq).start));
    const last = (try parsed.ast.lastChild(&seq)).?;
    const insert_at = lineEndAfter(source, parsed.span(last).end -| 1);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    if (insert_at > 0 and source[insert_at - 1] != '\n') try out.append(self.allocator, '\n');
    try out.appendNTimes(self.allocator, ' ', dash_col);
    try out.append(self.allocator, '-');
    try appendValueTail(self.allocator, &out, dash_col + indent_width, value_text, false);
    try out.append(self.allocator, '\n');
    try self.replaceAtSpan(Span.init(insert_at, insert_at), out.items);
}

/// Insert `value_text` before the first item of the block sequence `seq`.
pub fn ntPrependItem(self: *NtEditor, parsed: Document, seq: AST.Node, value_text: []const u8) !void {
    const source = self.source.items;
    const dash_pos = firstNonSpace(source, parsed.span(seq).start);
    const dash_col = columnOf(source, dash_pos);
    const line_start = lineStartBefore(source, dash_pos);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    try out.appendNTimes(self.allocator, ' ', dash_col);
    try out.append(self.allocator, '-');
    try appendValueTail(self.allocator, &out, dash_col + indent_width, value_text, false);
    try out.append(self.allocator, '\n');
    try self.replaceAtSpan(Span.init(line_start, line_start), out.items);
}

// ── removeSeqItem ────────────────────────────────────────────────────────────

/// Remove sequence item `item` (whose immediately preceding sibling is
/// `prev`, or null when `item` is first) — the whole owned block: any leading
/// `#`-comment run above its `-` line, through its last (possibly nested)
/// line. `editor.zig`'s `removeSeqItem` has already resolved `item`/`prev` by
/// the time this is called (it needs `prev` too, for the same dash-position
/// recovery `appendToSeq`/`prependToSeq` need — see the module doc).
pub fn ntRemoveSeqItem(self: *NtEditor, parsed: Document, seq: AST.Node, item: AST.Node, prev: ?AST.Node) !void {
    const source = self.source.items;
    const dash_pos = dashPosAfterPrev(source, parsed, seq, prev);
    const del_start = editor.commentBlockStart(source, lineStartBefore(source, dash_pos), .hash);
    const item_span = parsed.span(item);
    const del_end = lineEndAfter(source, item_span.end -| 1);
    try self.replaceAtSpan(Span.init(del_start, del_end), "");
}

// ── move / reorder ───────────────────────────────────────────────────────────

/// Reorder the block sequence `seq`'s items per `order` (bring-to-front
/// indices, same contract as `Editor.reorderItems`/`moveItem`) — the
/// NestedText arm of `editor.zig`'s private `reorderSeqNode`, needed because
/// its generic per-item block-start computation (`entryBlockStart`, keyed off
/// each item's own span) can't be trusted here (see the module doc). Reuses
/// `editor.zig`'s own `Block`/`fullOrder`/`appendBlockSep` for the actual
/// tiling/permutation/splice, which — unlike the block-start recovery — is
/// completely format-agnostic.
pub fn ntReorderSeqItems(self: *NtEditor, parsed: Document, seq: AST.Node, order: []const usize) !void {
    const source = self.source.items;
    var blocks: std.ArrayList(editor.Block) = .empty;
    defer blocks.deinit(self.allocator);
    var last_span: ?Span = null;

    var maybe = try parsed.ast.child(&seq);
    var prev: ?AST.Node = null;
    while (maybe) |item| {
        const dash_pos = dashPosAfterPrev(source, parsed, seq, prev);
        const start = editor.commentBlockStart(source, lineStartBefore(source, dash_pos), .hash);
        try blocks.append(self.allocator, .{ .start = start, .end = 0 });
        last_span = parsed.span(item);
        prev = item;
        maybe = parsed.ast.next(&item);
    }
    if (blocks.items.len == 0) return;

    const last_end = lineEndAfter(source, last_span.?.end -| 1);
    editor.tileBlocks(blocks.items, last_end);

    const perm = try editor.fullOrder(self.allocator, order, blocks.items.len);
    defer self.allocator.free(perm);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    for (perm) |i| try editor.appendBlockSep(&out, self.allocator, source[blocks.items[i].start..blocks.items[i].end]);
    try self.replaceAtSpan(Span.init(blocks.items[0].start, last_end), out.items);
}

// ── Tests ────────────────────────────────────────────────────────────────────

fn expectEdit(comptime op: []const u8, src: []const u8, args: anytype, expected: []const u8) !void {
    var ed: NtEditor = .{ .allocator = testing.allocator, .format = .NESTEDTEXT };
    try ed.init(src);
    defer ed.deinit();
    try @call(.auto, @field(NtEditor, op), .{&ed} ++ args);
    errdefer std.log.err("actual: \"{s}\"", .{ed.source.items});
    try testing.expectEqualStrings(expected, ed.source.items);
}

test "insertKey: promotes an empty document to the first root key" {
    try expectEdit("set", "", .{ &[_]AST.PathSegment{.{ .key = "name" }}, "fig" }, "name: fig\n");
}

test "insertKey: appends after the last existing entry, matching indent" {
    try expectEdit("insertKey", "a: 1\n", .{ &[_]AST.PathSegment{}, "b", "2" }, "a: 1\nb: 2\n");
    try expectEdit(
        "insertKey",
        "server:\n    host: localhost\n",
        .{ &[_]AST.PathSegment{.{ .key = "server" }}, "port", "80" },
        "server:\n    host: localhost\n    port: 80\n",
    );
}

test "insertKey: empty/multiline value renders as a nested `>`-block" {
    try expectEdit("insertKey", "a: 1\n", .{ &[_]AST.PathSegment{}, "b", "" }, "a: 1\nb:\n    >\n");
    try expectEdit("insertKey", "a: 1\n", .{ &[_]AST.PathSegment{}, "b", "line1\nline2" }, "a: 1\nb:\n    > line1\n    > line2\n");
}

test "insertKey: a key needing multiline form gets the `: key` spelling" {
    try expectEdit("insertKey", "a: 1\n", .{ &[_]AST.PathSegment{}, "- looks like a list tag", "v" }, "a: 1\n: - looks like a list tag\n    > v\n");
}

test "insertKey: declines a childless inline `{}` target" {
    var ed: NtEditor = .{ .allocator = testing.allocator, .format = .NESTEDTEXT };
    try ed.init("{}");
    defer ed.deinit();
    try testing.expectError(error.EmptyInlineContainer, ed.insertKey(&.{}, "a", "1"));
}

test "set: same-line scalar replace, autodetecting old shape" {
    try expectEdit("set", "name: fig\n", .{ &[_]AST.PathSegment{.{ .key = "name" }}, "zig" }, "name: zig\n");
}

test "set: switches a same-line value to a nested `>`-block and back" {
    try expectEdit("set", "name: fig\n", .{ &[_]AST.PathSegment{.{ .key = "name" }}, "line1\nline2" }, "name:\n    > line1\n    > line2\n");
    try expectEdit("set", "name:\n    > line1\n    > line2\n", .{ &[_]AST.PathSegment{.{ .key = "name" }}, "fig" }, "name: fig\n");
}

test "set: empty value becomes the nested bare `>` block" {
    try expectEdit("set", "name: fig\n", .{ &[_]AST.PathSegment{.{ .key = "name" }}, "" }, "name:\n    >\n");
    try expectEdit("set", "name:\n    >\n", .{ &[_]AST.PathSegment{.{ .key = "name" }}, "fig" }, "name: fig\n");
}

test "set: replaces a whole nested container value with a scalar" {
    try expectEdit(
        "set",
        "server:\n    host: localhost\n    port: 80\n",
        .{ &[_]AST.PathSegment{.{ .key = "server" }}, "disabled" },
        "server: disabled\n",
    );
}

test "set: on a multiline key's value stays nested even for a short value" {
    try expectEdit(
        "set",
        ": key 1\n: spread over 2 lines\n    > value 1\n",
        .{ &[_]AST.PathSegment{.{ .key = "key 1\nspread over 2 lines" }}, "v" },
        ": key 1\n: spread over 2 lines\n    > v\n",
    );
}

test "replaceValAtPath: on a list item, by index" {
    // `set` only ever creates/replaces a MAPPING entry (its path must end in
    // `.key`); an `.index`-ending or path-less (root) target goes through
    // `replaceValAtPath` directly, same as every other language.
    try expectEdit("replaceValAtPath", "- a\n- b\n- c\n", .{ &[_]AST.PathSegment{.{ .index = 1 }}, "z" }, "- a\n- z\n- c\n");
}

test "replaceValAtPath: on a list item whose value is nested/empty" {
    try expectEdit(
        "replaceValAtPath",
        "- a\n-\n    nested: 1\n- c\n",
        .{ &[_]AST.PathSegment{.{ .index = 1 }}, "b" },
        "- a\n- b\n- c\n",
    );
}

test "replaceValAtPath: the whole-document root value" {
    try expectEdit("replaceValAtPath", "> hello\n", .{ &[_]AST.PathSegment{}, "goodbye" }, "> goodbye\n");
    try expectEdit("replaceValAtPath", "", .{ &[_]AST.PathSegment{}, "hi" }, "> hi\n");
}

test "replaceKeyAtPath: plain to plain" {
    try expectEdit("replaceKeyAtPath", "name: fig\n", .{ &[_]AST.PathSegment{.{ .key = "name" }}, "lang" }, "lang: fig\n");
}

test "replaceKeyAtPath: multiline to plain adds the separator colon" {
    try expectEdit(
        "replaceKeyAtPath",
        ": - looks like a list tag\n    > v\n",
        .{ &[_]AST.PathSegment{.{ .key = "- looks like a list tag" }}, "plain" },
        "plain:\n    > v\n",
    );
}

test "replaceKeyAtPath: plain to multiline is declined when the value is same-line" {
    var ed: NtEditor = .{ .allocator = testing.allocator, .format = .NESTEDTEXT };
    try ed.init("name: fig\n");
    defer ed.deinit();
    try testing.expectError(error.KeyRequiresMultilineForm, ed.replaceKeyAtPath(&.{.{ .key = "name" }}, "- oops"));
}

test "appendToSeq / prependToSeq put a scalar item on its own line" {
    try expectEdit("appendToSeq", "- a\n- b\n", .{ &[_]AST.PathSegment{}, "c" }, "- a\n- b\n- c\n");
    try expectEdit("prependToSeq", "- a\n- b\n", .{ &[_]AST.PathSegment{}, "z" }, "- z\n- a\n- b\n");
}

test "appendToSeq / prependToSeq render an empty/multiline item as a nested `>`-block" {
    try expectEdit("appendToSeq", "- a\n", .{ &[_]AST.PathSegment{}, "" }, "- a\n-\n    >\n");
    try expectEdit("prependToSeq", "- a\n", .{ &[_]AST.PathSegment{}, "l1\nl2" }, "-\n    > l1\n    > l2\n- a\n");
}

test "appendToSeq: after a nested-value first item, indent still matches the sequence" {
    try expectEdit(
        "appendToSeq",
        "-\n    nested: 1\n",
        .{ &[_]AST.PathSegment{}, "b" },
        "-\n    nested: 1\n- b\n",
    );
}

test "removeSeqItem removes a nested/empty-valued item cleanly, leaving siblings intact" {
    try expectEdit(
        "removeSeqItem",
        "- a\n-\n    nested: 1\n- c\n",
        .{ &[_]AST.PathSegment{}, @as(usize, 1) },
        "- a\n- c\n",
    );
    // Removing the first item (nested/empty) is anchored via the sequence's
    // own span, not a (nonexistent) previous sibling.
    try expectEdit(
        "removeSeqItem",
        "-\n    nested: 1\n- b\n",
        .{ &[_]AST.PathSegment{}, @as(usize, 0) },
        "- b\n",
    );
}

test "removeSeqItem carries a leading comment above a nested item" {
    try expectEdit(
        "removeSeqItem",
        "- a\n# note\n-\n    nested: 1\n- c\n",
        .{ &[_]AST.PathSegment{}, @as(usize, 1) },
        "- a\n- c\n",
    );
}

test "moveItem / reorderItems relocate whole (possibly nested) item blocks" {
    try expectEdit(
        "moveItem",
        "- a\n-\n    nested: 1\n- c\n",
        .{ &[_]AST.PathSegment{}, @as(usize, 2), @as(usize, 0) },
        "- c\n- a\n-\n    nested: 1\n",
    );
    try expectEdit(
        "reorderItems",
        "- a\n- b\n- c\n",
        .{ &[_]AST.PathSegment{}, &[_]usize{ 2, 0 } },
        "- c\n- a\n- b\n",
    );
}

test "addLeadingComment / getLeadingComment / deleteLeadingComments on a nested-valued list item" {
    var ed: NtEditor = .{ .allocator = testing.allocator, .format = .NESTEDTEXT };
    try ed.init("- a\n-\n    nested: 1\n- c\n");
    defer ed.deinit();
    const path = &[_]AST.PathSegment{.{ .index = 1 }};
    try ed.addLeadingComment(path, "note");
    try testing.expectEqualStrings("- a\n# note\n-\n    nested: 1\n- c\n", ed.source.items);
    const got = (try ed.getLeadingComment(path)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("note", got);
    try ed.deleteLeadingComments(path);
    try testing.expectEqualStrings("- a\n-\n    nested: 1\n- c\n", ed.source.items);
}

test "trailing comments are unsupported (no same-line comment spelling)" {
    var ed: NtEditor = .{ .allocator = testing.allocator, .format = .NESTEDTEXT };
    try ed.init("name: fig\n");
    defer ed.deinit();
    const path = &[_]AST.PathSegment{.{ .key = "name" }};
    try testing.expectError(error.CommentsUnsupported, ed.setTrailingComment(path, "note"));
    try testing.expectError(error.CommentsUnsupported, ed.getTrailingComment(path));
    try testing.expectError(error.CommentsUnsupported, ed.deleteTrailingComment(path));
}

test "deleteKey removes a whole nested-value entry (generic engine, no override needed)" {
    try expectEdit(
        "deleteKey",
        "a: 1\nserver:\n    host: localhost\n    port: 80\nb: 2\n",
        .{&[_]AST.PathSegment{.{ .key = "server" }}},
        "a: 1\nb: 2\n",
    );
}
