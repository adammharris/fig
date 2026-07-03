//! TOML-specific editing helpers for `Editor(Toml)`.
//!
//! The generic span-splice engine lives in `../editor.zig`; this module holds the
//! TOML-only logic it delegates to — the multi-region gather that lets whole-table
//! ops (delete/insert/rename/move/reorder) work across TOML's scattered headers,
//! plus header-path rendering. Everything here is a pure function of
//! `(Document, source, allocator)` returning regions/bytes, so it has no
//! dependency on the `Editor` struct itself (only the shared source-coordinate
//! utilities, aliased below). See `editor.zig` for the public methods.

const std = @import("std");

const AST = @import("../../ast/ast.zig");
const Document = @import("../../document.zig");
const Span = @import("../../util/span.zig");
const editor = @import("../../editor.zig");
const Toml = @import("toml.zig").Language;
const log = std.log.scoped(.editor);

/// The concrete editor these structural ops drive. All functions below take a
/// `*TomlEditor`: they are the TOML arm of the generic engine, factored out so
/// `editor.zig` stays format-agnostic and every TOML edit lives in one file. The
/// public methods on `editor.Editor(Toml)` are thin wrappers that call these.
const TomlEditor = editor.Editor(Toml);

// Shared source-coordinate / rendering utilities (defined in editor.zig).
const lineStartBefore = editor.lineStartBefore;
const lineEndAfter = editor.lineEndAfter;
const firstNonSpace = editor.firstNonSpace;
const commentBlockStart = editor.commentBlockStart;
const CommentStyle = editor.CommentStyle;
const isFlow = editor.isFlow;
const appendBlockSep = editor.appendBlockSep;

/// Largest source `end` over the subtree rooted at `id` — the textual end of an
/// AoT element including any nested `[header]`/`[[header]]` sub-tables (whose own
/// node spans point at their header key, with their body following). Used to
/// find where a new `[[…]]` element can be spliced without splitting the prior
/// element's contents.
pub fn subtreeMaxEnd(parsed: Document, id: AST.Node.Id) usize {
    var max = parsed.span(parsed.ast.nodes[id]).end;
    switch (parsed.ast.nodes[id].kind) {
        .mapping => |first| {
            var c = first;
            while (c) |cid| : (c = parsed.ast.nodes[cid].next_sibling) max = @max(max, subtreeMaxEnd(parsed, cid));
        },
        .sequence => |first| {
            var c = first;
            while (c) |cid| : (c = parsed.ast.nodes[cid].next_sibling) max = @max(max, subtreeMaxEnd(parsed, cid));
        },
        .keyvalue => |kv| max = @max(max, @max(subtreeMaxEnd(parsed, kv.key), subtreeMaxEnd(parsed, kv.value))),
        else => {},
    }
    return max;
}

// --- TOML whole-table structural editing (multi-region) ---
//
// A logical TOML table is assembled from scattered source: `[a]` x=1 … `[other]`
// y=2 … `[a.b]` z=3. The AST has one mapping node per logical table; its span is
// only its key segment inside the header, and its keyvalue children carry their
// own line spans. So a whole-table op (delete/move/rename) cannot splice a single
// `[min,max)` range — foreign tables may be interleaved. Instead we *gather* the
// disjoint line-regions that belong to the table's subtree and rebuild the source
// once. `replaceAtSpan` reparses per call, so every op does exactly one splice.

/// A line-aligned source range `[start, end)` belonging to a logical table.
pub const Region = struct { start: usize, end: usize };

/// Expand `seg_span` (a header key segment, sitting inside `[...]`/`[[...]]`) to
/// its full physical line(s) plus any owned leading comment block. Returns null
/// when the segment's line does not start with `[` — i.e. the table is a dotted
/// or root table that has no header line of its own.
pub fn headerLineRegion(source: []const u8, seg_span: Span, style: CommentStyle) ?Region {
    const ls = lineStartBefore(source, seg_span.start);
    const fns = firstNonSpace(source, ls);
    if (fns >= source.len or source[fns] != '[') return null;
    return .{
        .start = commentBlockStart(source, ls, style),
        .end = lineEndAfter(source, seg_span.end -| 1),
    };
}

/// Full line-region of an in-table entry (`key = value`, possibly multi-line):
/// its owned comment block through the newline ending its last line.
pub fn entryLineRegion(source: []const u8, kv_span: Span, style: CommentStyle) Region {
    return .{
        .start = commentBlockStart(source, lineStartBefore(source, kv_span.start), style),
        .end = lineEndAfter(source, kv_span.end -| 1),
    };
}

/// Line start of the nearest line at or above `at` whose first non-space byte is
/// `[` (a `[table]` / `[[aot]]` header), or null if none. Used to recover an
/// array-of-tables element's header, whose node span is shared across elements
/// and so cannot be trusted.
fn headerLineAtOrAbove(source: []const u8, at: usize) ?usize {
    var ls = lineStartBefore(source, at);
    while (true) {
        const fns = firstNonSpace(source, ls);
        if (fns < source.len and source[fns] == '[') return ls;
        if (ls == 0) return null;
        ls = lineStartBefore(source, ls - 1);
    }
}

/// Line start of the nearest line at or after `at` whose first non-space byte is
/// `[`, or null. Forward counterpart of `headerLineAtOrAbove`, for locating an
/// *empty* AoT element's header (no child to anchor an upward scan).
fn headerLineAtOrAfter(source: []const u8, at: usize) ?usize {
    var ls = at;
    while (ls < source.len) {
        const fns = firstNonSpace(source, ls);
        if (fns < source.len and source[fns] == '[') return ls;
        ls = lineEndAfter(source, ls);
    }
    return null;
}

/// Append every line-region belonging to the logical table rooted at `node` (a
/// `.mapping`). `include_header` adds the table's own `[header]` line (omitted for
/// the AoT-element case, which recovers its `[[…]]` header by scanning). Children
/// are classified purely by whether their source line starts with `[`: such a
/// line is a sub-table (`.mapping`) or nested AoT (`.sequence`) and is recursed
/// into; any other line is an in-region entry whose whole span is taken verbatim
/// (covering scalars, multi-line arrays/strings, inline tables, and dotted keys).
pub fn gatherTableRegions(parsed: Document, source: []const u8, allocator: std.mem.Allocator, node: AST.Node, include_header: bool, out: *std.ArrayList(Region)) std.mem.Allocator.Error!void {
    if (include_header) {
        if (headerLineRegion(source, parsed.span(node), .hash)) |r| try out.append(allocator, r);
    }
    if (node.kind != .mapping) return;
    var cur = node.kind.mapping;
    while (cur) |id| : (cur = parsed.ast.nodes[id].next_sibling) {
        const kv = parsed.ast.nodes[id];
        const kv_span = parsed.span(kv);
        const fns = firstNonSpace(source, lineStartBefore(source, kv_span.start));
        const is_header = fns < source.len and source[fns] == '[';
        if (!is_header) {
            try out.append(allocator, entryLineRegion(source, kv_span, .hash));
            continue;
        }
        // Sub-table header line: recurse into the keyvalue's value node.
        const val = parsed.ast.nodes[kv.kind.keyvalue.value];
        switch (val.kind) {
            .mapping => try gatherTableRegions(parsed, source, allocator, val, true, out),
            .sequence => try gatherAotRegions(parsed, source, allocator, val, out),
            else => try out.append(allocator, entryLineRegion(source, kv_span, .hash)),
        }
    }
}

/// Append every region of an array-of-tables `node` (a `.sequence` of element
/// mappings): each element's `[[…]]` header plus its body. Element mappings share
/// one node span, so each header is recovered by scanning from the element's
/// content (or, for an empty element, forward from the previous element's end).
pub fn gatherAotRegions(parsed: Document, source: []const u8, allocator: std.mem.Allocator, node: AST.Node, out: *std.ArrayList(Region)) std.mem.Allocator.Error!void {
    var search_from: usize = 0;
    var elem = node.kind.sequence;
    while (elem) |eid| : (elem = parsed.ast.nodes[eid].next_sibling) {
        const em = parsed.ast.nodes[eid];
        try gatherElementRegions(parsed, source, allocator, em, search_from, out);
        search_from = lineEndAfter(source, subtreeMaxEnd(parsed, eid) -| 1);
    }
}

/// Append one AoT element's regions: its `[[…]]` header (recovered by scan) and
/// its body. `search_from` is the end of the previous element (start for the
/// first), used to find an empty element's header.
pub fn gatherElementRegions(parsed: Document, source: []const u8, allocator: std.mem.Allocator, elem: AST.Node, search_from: usize, out: *std.ArrayList(Region)) std.mem.Allocator.Error!void {
    const first = if (elem.kind == .mapping) elem.kind.mapping else null;
    const header_ls: ?usize = if (first) |fc|
        headerLineAtOrAbove(source, lineStartBefore(source, parsed.span(parsed.ast.nodes[fc]).start) -| 1)
    else
        headerLineAtOrAfter(source, search_from);
    if (header_ls) |ls| try out.append(allocator, .{
        .start = commentBlockStart(source, ls, .hash),
        .end = lineEndAfter(source, ls),
    });
    // Body: same child classification as a regular table.
    var cur = if (elem.kind == .mapping) elem.kind.mapping else null;
    while (cur) |id| : (cur = parsed.ast.nodes[id].next_sibling) {
        const kv = parsed.ast.nodes[id];
        const kv_span = parsed.span(kv);
        const fns = firstNonSpace(source, lineStartBefore(source, kv_span.start));
        const is_header = fns < source.len and source[fns] == '[';
        if (!is_header) {
            try out.append(allocator, entryLineRegion(source, kv_span, .hash));
            continue;
        }
        const val = parsed.ast.nodes[kv.kind.keyvalue.value];
        switch (val.kind) {
            .mapping => try gatherTableRegions(parsed, source, allocator, val, true, out),
            .sequence => try gatherAotRegions(parsed, source, allocator, val, out),
            else => try out.append(allocator, entryLineRegion(source, kv_span, .hash)),
        }
    }
}

/// Span of the dotted-key segment at `depth` (0-based) within the header line of
/// `region` (`[a.b.c]` or `[[a.b.c]]`), or null when the region has no header
/// line or fewer than `depth+1` segments. The span covers the raw key token
/// (including any surrounding quotes), so splicing a rendered replacement over it
/// rewrites just that one path segment.
pub fn headerSegmentSpan(source: []const u8, region: Region, depth: usize) ?Span {
    // Locate the `[`-line inside the region (comments may precede it).
    var ls = region.start;
    const line_start = while (ls < region.end) : (ls = lineEndAfter(source, ls)) {
        const fns = firstNonSpace(source, ls);
        if (fns < source.len and source[fns] == '[') break fns;
    } else return null;

    var p = line_start;
    while (p < source.len and source[p] == '[') p += 1; // skip `[` or `[[`
    var seg: usize = 0;
    while (p < source.len and source[p] != ']') {
        while (p < source.len and (source[p] == ' ' or source[p] == '\t')) p += 1;
        if (p >= source.len or source[p] == ']') break;
        const start = p;
        switch (source[p]) {
            '"' => {
                p += 1;
                while (p < source.len and source[p] != '"') : (p += 1) {
                    if (source[p] == '\\') p += 1;
                }
                if (p < source.len) p += 1; // closing quote
            },
            '\'' => {
                p += 1;
                while (p < source.len and source[p] != '\'') p += 1;
                if (p < source.len) p += 1; // closing quote
            },
            else => while (p < source.len and isTomlBareKey(source[p .. p + 1])) : (p += 1) {},
        }
        const end = p;
        if (seg == depth) return Span.init(start, end);
        seg += 1;
        while (p < source.len and (source[p] == ' ' or source[p] == '\t')) p += 1;
        if (p < source.len and source[p] == '.') p += 1; // segment separator
    }
    return null;
}

/// Sort regions by start and coalesce overlapping ones into a disjoint, ascending
/// set (in place); returns the coalesced count.
pub fn normalizeRegions(regions: []Region) usize {
    std.mem.sort(Region, regions, {}, struct {
        fn lt(_: void, a: Region, b: Region) bool {
            return a.start < b.start;
        }
    }.lt);
    if (regions.len == 0) return 0;
    var w: usize = 0;
    for (regions[1..]) |r| {
        // Merge only on real overlap, not mere touching — rename needs each header
        // line as its own region, while delete/move are unaffected (a zero-width
        // gap between touching regions copies nothing).
        if (r.start < regions[w].end) {
            regions[w].end = @max(regions[w].end, r.end);
        } else {
            w += 1;
            regions[w] = r;
        }
    }
    return w + 1;
}

/// Append `block` to `out` separated from any preceding content by exactly one
/// blank line (two newlines). `block` is appended verbatim (it already ends in a
/// newline). Used to splice a relocated TOML table so it reads as its own section.
pub fn appendWithBlankBefore(out: *std.ArrayList(u8), allocator: std.mem.Allocator, block: []const u8) !void {
    if (block.len == 0) return;
    const n = out.items.len;
    if (n > 0) {
        if (n >= 2 and out.items[n - 1] == '\n' and out.items[n - 2] == '\n') {
            // already a blank line
        } else if (out.items[n - 1] == '\n') {
            try out.append(allocator, '\n');
        } else {
            try out.appendSlice(allocator, "\n\n");
        }
    }
    try out.appendSlice(allocator, block);
}

/// Render a TOML header path (`a.b.c`) from a PathSegment list into `out`. Index
/// segments are skipped — `[[a.b]]` always targets `a`'s last element, so the
/// index is implied. Each key prints bare when it is all `[A-Za-z0-9_-]`, else as
/// a basic-quoted string.
pub fn appendTomlHeaderPath(out: *std.ArrayList(u8), allocator: std.mem.Allocator, path: []const AST.PathSegment) !void {
    var first = true;
    for (path) |seg| switch (seg) {
        .index => {},
        .key => |k| {
            if (!first) try out.append(allocator, '.');
            first = false;
            if (isTomlBareKey(k)) {
                try out.appendSlice(allocator, k);
            } else {
                try out.append(allocator, '"');
                for (k) |ch| switch (ch) {
                    '"' => try out.appendSlice(allocator, "\\\""),
                    '\\' => try out.appendSlice(allocator, "\\\\"),
                    else => try out.append(allocator, ch),
                };
                try out.append(allocator, '"');
            }
        },
    };
}

pub fn isTomlBareKey(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

// ============================================================================
// STRUCTURAL EDITING — the TOML arm of `editor.Editor`
// ============================================================================
//
// These drive the editor's splice engine (`self.replaceAtSpan`, which reparses
// and rolls back on failure) using the region helpers above. `editor.zig` keeps
// only thin public wrappers (`Editor(Toml).deleteTable` etc.) that forward here,
// plus the comptime `if (Language == Toml)` branches that call into these for
// the shared ops (e.g. `insertKey`).

// --- TOML structural inserts ---
//
// TOML splits a logical table across `[header]`…dotted-key…lines, so an insert
// must land where the new entry attaches to the *intended* table. A scalar
// `key = value` is placed at the end of the table's own header region — after
// its last direct (non-`[header]`) entry, before any sub-table header opens —
// never after a sub-table, which would silently reparent it. `key_text`/
// `value_text` are verbatim TOML literals.
pub fn tomlInsertKey(self: *TomlEditor, parsed: Document, node: AST.Node, span: Span, is_root: bool, key_text: []const u8, value_text: []const u8) !void {
    if (node.kind != .mapping) return error.NotAMapping;
    const source = self.source.items;
    // Inline table `{ … }`: splice a `key = value` inside the braces.
    if (isFlow(source, span))
        return tomlInsertFlowEntry(self, parsed, node, span, key_text, value_text);

    // Block table: scan its direct children for the in-region ones (those whose
    // line does not start with `[` — i.e. scalars, arrays, inline tables, and
    // dotted sub-tables, all of which live under this table's header). The last
    // such child's line is where the new entry goes; its column sets the indent.
    var last_end: ?usize = null;
    var col: usize = 0;
    var col_set = false;
    var cur = node.kind.mapping;
    while (cur) |id| : (cur = parsed.ast.nodes[id].next_sibling) {
        const kv_span = parsed.span(parsed.ast.nodes[id]);
        const ls = lineStartBefore(source, kv_span.start);
        const fns = firstNonSpace(source, ls);
        if (fns < source.len and source[fns] == '[') continue; // sub-table header: out of region
        last_end = kv_span.end;
        if (!col_set) {
            col = fns - ls;
            col_set = true;
        }
    }

    const insert_at = if (last_end) |e|
        lineEndAfter(source, e -| 1)
    else if (is_root)
        0 // empty document: top of file
    else
        lineEndAfter(source, span.end -| 1); // header-only table: just past its `[header]` line

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    if (insert_at > 0 and source[insert_at - 1] != '\n') try out.append(self.allocator, '\n');
    try out.appendNTimes(self.allocator, ' ', col);
    try out.appendSlice(self.allocator, key_text);
    try out.appendSlice(self.allocator, " = ");
    try out.appendSlice(self.allocator, value_text);
    try out.append(self.allocator, '\n');
    try self.replaceAtSpan(Span.init(insert_at, insert_at), out.items);
}

/// Splice `key = value` into an inline table, keeping the conventional
/// `{ a = 1, b = 2 }` spacing: into a non-empty table the entry is inserted
/// right after the last entry's value (`…1` → `…1, key = value`); into an
/// empty `{}` it is padded with surrounding spaces (`{ key = value }`).
pub fn tomlInsertFlowEntry(self: *TomlEditor, parsed: Document, node: AST.Node, span: Span, key_text: []const u8, value_text: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    const at = if (node.kind.mapping) |first| blk: {
        var last = first;
        while (parsed.ast.nodes[last].next_sibling) |n| last = n;
        try out.appendSlice(self.allocator, ", ");
        break :blk parsed.span(parsed.ast.nodes[last]).end;
    } else blk: {
        try out.append(self.allocator, ' ');
        break :blk span.start + 1; // just after '{'
    };
    try out.appendSlice(self.allocator, key_text);
    try out.appendSlice(self.allocator, " = ");
    try out.appendSlice(self.allocator, value_text);
    if (node.kind.mapping == null) try out.append(self.allocator, ' ');
    try self.replaceAtSpan(Span.init(at, at), out.items);
}

/// Append a new `[[header]]` element to the array-of-tables at `path`, with
/// `body_text` (verbatim TOML `key = value` lines, possibly empty) as its
/// contents. The element is spliced after the AoT's current last element — past
/// every line of that element's subtree, so a nested sub-table inside it is not
/// split.
pub fn appendTableToArray(self: *TomlEditor, path: []const AST.PathSegment, body_text: []const u8) !void {
    const parsed = try self.getParsed();
    const node = try parsed.ast.getValByPath(path);
    if (node.kind != .sequence) return error.NotAnArrayOfTables;
    var elem = node.kind.sequence orelse return error.NotAnArrayOfTables;
    var last_elem = elem;
    while (true) {
        if (parsed.ast.nodes[elem].kind != .mapping) return error.NotAnArrayOfTables;
        last_elem = elem;
        elem = parsed.ast.nodes[elem].next_sibling orelse break;
    }
    const source = self.source.items;
    const end = subtreeMaxEnd(parsed, last_elem);
    const insert_at = lineEndAfter(source, end -| 1);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    if (insert_at > 0 and source[insert_at - 1] != '\n') try out.append(self.allocator, '\n');
    try out.append(self.allocator, '\n'); // blank line before the new header
    try out.appendSlice(self.allocator, "[[");
    try appendTomlHeaderPath(&out, self.allocator, path);
    try out.appendSlice(self.allocator, "]]\n");
    if (body_text.len > 0) {
        try out.appendSlice(self.allocator, body_text);
        if (body_text[body_text.len - 1] != '\n') try out.append(self.allocator, '\n');
    }
    try self.replaceAtSpan(Span.init(insert_at, insert_at), out.items);
}

// --- TOML whole-table structural editing ---
//
// A logical TOML table spans scattered source lines, so these ops gather the
// table's disjoint regions (see `gatherTableRegions`) and rebuild the source in
// a *single* splice. Foreign tables interleaved between the gathered regions are
// left in place. Library-level (not CLI/C-ABI wired), matching the rest of TOML
// editing.

/// Rebuild the source with `regions` (disjoint, ascending) removed, in one
/// `replaceAtSpan` so the reparse/rollback runs once. `regions` is the slice
/// actually used (caller passes the coalesced prefix).
pub fn spliceOutRegions(self: *TomlEditor, regions: []const Region) !void {
    const source = self.source.items;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    var pos: usize = 0;
    for (regions) |r| {
        try out.appendSlice(self.allocator, source[pos..r.start]);
        pos = r.end;
    }
    try out.appendSlice(self.allocator, source[pos..]);
    try self.replaceAtSpan(Span.init(0, source.len), out.items);
}

/// Delete the whole table, array-of-tables, or single AoT element named by
/// `path` — including every scattered region of its subtree — leaving any
/// interleaved foreign tables untouched. A path ending in an index targets one
/// AoT element; otherwise the path's value must be a `[table]` (`.mapping`) or a
/// `[[aot]]` array (`.sequence`). A scalar key is refused with `error.NotATable`
/// (use `deleteKey`).
pub fn deleteTable(self: *TomlEditor, path: []const AST.PathSegment) !void {
    if (path.len == 0) return error.NotATable;
    const parsed = try self.getParsed();
    const node = try parsed.ast.getValByPath(path);
    const source = self.source.items;

    var regions: std.ArrayList(Region) = .empty;
    defer regions.deinit(self.allocator);

    switch (node.kind) {
        .mapping => {
            if (path[path.len - 1] == .index) {
                // A single AoT element: span is shared across elements, so
                // recover its header by scanning. Search anchor = end of the
                // preceding element (or 0 for the first).
                const search_from = try aotElementSearchFrom(self, parsed, path);
                try gatherElementRegions(parsed, source, self.allocator, node, search_from, &regions);
            } else {
                try gatherTableRegions(parsed, source, self.allocator, node, true, &regions);
            }
        },
        .sequence => try gatherAotRegions(parsed, source, self.allocator, node, &regions),
        else => return error.NotATable,
    }
    const n = normalizeRegions(regions.items);
    try spliceOutRegions(self, regions.items[0..n]);
}

/// Search anchor for the AoT element at `path` (which ends in an index): the
/// source end of the previous element, or 0 when it is the first. Lets
/// `gatherElementRegions` locate an empty element's header.
pub fn aotElementSearchFrom(self: *TomlEditor, parsed: Document, path: []const AST.PathSegment) !usize {
    const idx = path[path.len - 1].index;
    if (idx == 0) return 0;
    const seq = try parsed.ast.getValByPath(path[0 .. path.len - 1]);
    if (seq.kind != .sequence) return 0;
    var prev = seq.kind.sequence;
    var i: usize = 0;
    while (prev) |pid| : (prev = parsed.ast.nodes[pid].next_sibling) {
        if (i + 1 == idx) return lineEndAfter(self.source.items, subtreeMaxEnd(parsed, pid) -| 1);
        i += 1;
    }
    return 0;
}

/// Create a new `[path]` table (or sub-table) whose body is `body_text`
/// (verbatim TOML `key = value` lines, possibly empty). The header is spliced
/// *after* the parent table's entire subtree — or at end-of-file for a
/// root-level table — so no existing key is reparented. Refuses
/// `error.TableExists` if the table already exists.
pub fn insertTable(self: *TomlEditor, path: []const AST.PathSegment, body_text: []const u8) !void {
    if (path.len == 0) return error.NotATable;
    const parsed = try self.getParsed();
    if (parsed.ast.getValByPath(path)) |_| {
        return error.TableExists;
    } else |_| {}
    const source = self.source.items;

    // Insertion point: just past the parent table's whole subtree, else EOF.
    const insert_at = blk: {
        if (path.len > 1) {
            if (parsed.ast.getValByPath(path[0 .. path.len - 1])) |parent| {
                if (parent.kind == .mapping)
                    break :blk lineEndAfter(source, subtreeMaxEnd(parsed, parent.id) -| 1);
            } else |_| {}
        }
        break :blk source.len;
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    if (insert_at > 0 and source[insert_at - 1] != '\n') try out.append(self.allocator, '\n');
    if (insert_at > 0) try out.append(self.allocator, '\n'); // blank line before the header
    try out.appendSlice(self.allocator, "[");
    try appendTomlHeaderPath(&out, self.allocator, path);
    try out.appendSlice(self.allocator, "]\n");
    if (body_text.len > 0) {
        try out.appendSlice(self.allocator, body_text);
        if (body_text[body_text.len - 1] != '\n') try out.append(self.allocator, '\n');
    }
    try self.replaceAtSpan(Span.init(insert_at, insert_at), out.items);
}

/// Rename the leaf key of the table at `path` to `new_leaf`, rewriting the
/// table's own header and every descendant sub-header that shares the prefix
/// (`[a.b]`, `[a.b.c]`, `[[a.b]]` → `[q.b]`, `[q.b.c]`, `[[q.b]]` when renaming
/// `a`→`q`). Format-preserving: only the renamed segment of each affected header
/// changes. A collision with an existing sibling is rejected via the reparse
/// rollback (`error.DuplicateKey`).
pub fn renameTable(self: *TomlEditor, path: []const AST.PathSegment, new_leaf: []const u8) !void {
    if (path.len == 0) return error.NotATable;
    const parsed = try self.getParsed();
    const node = try parsed.ast.getValByPath(path);
    if (node.kind != .mapping and node.kind != .sequence) return error.NotATable;
    const source = self.source.items;

    // Depth of the renamed segment within each header (count of key segments
    // before the leaf; AoT indices don't appear in headers).
    var depth: usize = 0;
    for (path[0 .. path.len - 1]) |seg| switch (seg) {
        .key => depth += 1,
        .index => {},
    };

    // Gather every header line belonging to this table's subtree, then rewrite
    // the segment at `depth` in each. Rebuild once.
    var regions: std.ArrayList(Region) = .empty;
    defer regions.deinit(self.allocator);
    switch (node.kind) {
        .mapping => try gatherTableRegions(parsed, source, self.allocator, node, true, &regions),
        .sequence => try gatherAotRegions(parsed, source, self.allocator, node, &regions),
        else => unreachable,
    }
    const n = normalizeRegions(regions.items);

    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(self.allocator);
    try appendTomlHeaderPath(&rendered, self.allocator, &.{.{ .key = new_leaf }});

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    var pos: usize = 0;
    for (regions.items[0..n]) |r| {
        // Only header regions carry the renamed segment; a region may begin with
        // an owned comment block, so locate the `[`-line within it.
        const seg = headerSegmentSpan(source, r, depth) orelse continue;
        try out.appendSlice(self.allocator, source[pos..seg.start]);
        try out.appendSlice(self.allocator, rendered.items);
        pos = seg.end;
    }
    try out.appendSlice(self.allocator, source[pos..]);
    try self.replaceAtSpan(Span.init(0, source.len), out.items);
}

/// Move the whole table at `src_path` to sit immediately before the table at
/// `dest_path` (a top-level/header table), or to end-of-file when `dest_path` is
/// null. The table's scattered fragments are removed from their original
/// positions and re-emitted **contiguously** at the destination (comments ride
/// along); foreign tables stay put. A no-op when the destination falls inside
/// the source's own region.
pub fn moveTable(self: *TomlEditor, src_path: []const AST.PathSegment, dest_path: ?[]const AST.PathSegment) !void {
    if (src_path.len == 0) return error.NotATable;
    const parsed = try self.getParsed();
    const node = try parsed.ast.getValByPath(src_path);
    if (node.kind != .mapping and node.kind != .sequence) return error.NotATable;
    const source = self.source.items;

    var regions: std.ArrayList(Region) = .empty;
    defer regions.deinit(self.allocator);
    switch (node.kind) {
        .mapping => try gatherTableRegions(parsed, source, self.allocator, node, true, &regions),
        .sequence => try gatherAotRegions(parsed, source, self.allocator, node, &regions),
        else => unreachable,
    }
    const n = normalizeRegions(regions.items);
    const used = regions.items[0..n];
    if (n == 0) return;

    // Destination: start of the dest table's header line, or EOF.
    const dest_at = blk: {
        if (dest_path) |dp| {
            const dn = try parsed.ast.getValByPath(dp);
            const hr = headerLineRegion(source, parsed.span(dn), .hash) orelse return error.NotATable;
            break :blk hr.start;
        }
        break :blk source.len;
    };
    // No-op only if the destination lands strictly inside a moved region (a
    // boundary at a fragment's edge — e.g. EOF coinciding with the last fragment
    // — is still a real relocation that collapses the fragments).
    for (used) |r| if (dest_at > r.start and dest_at < r.end) return;

    // Capture the table's bytes (document order, gaps dropped) — this is the
    // contiguous re-emission spliced at the destination.
    var moved: std.ArrayList(u8) = .empty;
    defer moved.deinit(self.allocator);
    for (used) |r| try moved.appendSlice(self.allocator, source[r.start..r.end]);

    // Build the source with the table removed, tracking where `dest_at` lands in
    // the result; then splice `moved` there with one blank line of separation
    // from preceding content.
    var kept: std.ArrayList(u8) = .empty;
    defer kept.deinit(self.allocator);
    var insert_pos: ?usize = null;
    var pos: usize = 0;
    for (used) |r| {
        if (insert_pos == null and dest_at >= pos and dest_at <= r.start) {
            try kept.appendSlice(self.allocator, source[pos..dest_at]);
            insert_pos = kept.items.len;
            try kept.appendSlice(self.allocator, source[dest_at..r.start]);
        } else {
            try kept.appendSlice(self.allocator, source[pos..r.start]);
        }
        pos = r.end;
    }
    if (insert_pos == null) {
        try kept.appendSlice(self.allocator, source[pos..dest_at]);
        insert_pos = kept.items.len;
        try kept.appendSlice(self.allocator, source[dest_at..]);
    } else {
        try kept.appendSlice(self.allocator, source[pos..]);
    }

    const ip = insert_pos.?;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    try out.appendSlice(self.allocator, kept.items[0..ip]);
    try appendWithBlankBefore(&out, self.allocator, moved.items);
    try out.appendSlice(self.allocator, kept.items[ip..]);
    try self.replaceAtSpan(Span.init(0, source.len), out.items);
}

/// Reorder a set of top-level tables (named by `order`, the keys in their
/// desired final order) among themselves. Each named table's scattered fragments
/// are removed and re-emitted contiguously, in `order`, at the position the
/// earliest of them currently occupies. Tables not named are untouched. Each
/// name must resolve to a `[table]` or `[[aot]]`.
pub fn reorderTables(self: *TomlEditor, order: []const []const u8) !void {
    if (order.len == 0) return;
    const parsed = try self.getParsed();
    const source = self.source.items;

    // Per-table region bundles, plus the global removal set.
    var all: std.ArrayList(Region) = .empty;
    defer all.deinit(self.allocator);
    // Captured bytes for each named table, in `order`.
    var bundles: std.ArrayList([]u8) = .empty;
    defer {
        for (bundles.items) |b| self.allocator.free(b);
        bundles.deinit(self.allocator);
    }

    for (order) |name| {
        const path: [1]AST.PathSegment = .{.{ .key = name }};
        const node = try parsed.ast.getValByPath(&path);
        if (node.kind != .mapping and node.kind != .sequence) return error.NotATable;
        var regions: std.ArrayList(Region) = .empty;
        defer regions.deinit(self.allocator);
        switch (node.kind) {
            .mapping => try gatherTableRegions(parsed, source, self.allocator, node, true, &regions),
            .sequence => try gatherAotRegions(parsed, source, self.allocator, node, &regions),
            else => unreachable,
        }
        const n = normalizeRegions(regions.items);
        var bytes: std.ArrayList(u8) = .empty;
        for (regions.items[0..n]) |r| {
            try bytes.appendSlice(self.allocator, source[r.start..r.end]);
            try all.append(self.allocator, r);
        }
        try bundles.append(self.allocator, try bytes.toOwnedSlice(self.allocator));
    }
    const total = normalizeRegions(all.items);
    const used = all.items[0..total];
    if (total == 0) return;
    const anchor = used[0].start;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    var pos: usize = 0;
    for (used) |r| {
        if (anchor >= pos and anchor <= r.start) {
            try out.appendSlice(self.allocator, source[pos..anchor]);
            for (bundles.items) |b| {
                try appendBlockSep(&out, self.allocator, b);
                if (b.len > 0 and b[b.len - 1] != '\n') try out.append(self.allocator, '\n');
            }
            try out.appendSlice(self.allocator, source[anchor..r.start]);
        } else {
            try out.appendSlice(self.allocator, source[pos..r.start]);
        }
        pos = r.end;
    }
    try out.appendSlice(self.allocator, source[pos..]);
    try self.replaceAtSpan(Span.init(0, source.len), out.items);
}

// =======
// TESTS
// =======
//
// TOML editor tests live here (rather than in editor.zig) so each language's
// editing tests sit next to that language's helpers. They exercise the public
// `Editor(Toml)` surface end-to-end: point edits (value/key replacement on the
// contiguous spans every node keeps even in a scattered table), scalar/inline
// insert+delete, and the whole-table structural ops (delete/insert/rename/move/
// reorder) built on the multi-region gather above.

fn newTomlEditor(input: []const u8) !editor.Editor(Toml) {
    var ed: editor.Editor(Toml) = .{ .allocator = std.testing.allocator };
    try ed.init(input);
    return ed;
}

fn expectTomlSource(ed: *const editor.Editor(Toml), expected: []const u8) !void {
    errdefer log.err("actual:   \"{s}\"", .{ed.source.items});
    errdefer log.err("expected: \"{s}\"", .{expected});
    try std.testing.expectEqualStrings(expected, ed.source.items);
}

test "toml replace root scalar value" {
    var ed = try newTomlEditor("title = \"old\"\nport = 8080\n");
    defer ed.deinit();
    try ed.replaceValAtPath(&.{.{ .key = "port" }}, "9090");
    try expectTomlSource(&ed, "title = \"old\"\nport = 9090\n");
}

test "toml replace string value keeps quoting verbatim" {
    var ed = try newTomlEditor("title = \"old\"\n");
    defer ed.deinit();
    try ed.replaceValAtPath(&.{.{ .key = "title" }}, "\"new title\"");
    try expectTomlSource(&ed, "title = \"new title\"\n");
}

test "toml replace value in a table" {
    var ed = try newTomlEditor("[server]\nhost = \"a\"\nport = 1\n");
    defer ed.deinit();
    try ed.replaceValAtPath(&.{ .{ .key = "server" }, .{ .key = "port" } }, "2");
    try expectTomlSource(&ed, "[server]\nhost = \"a\"\nport = 2\n");
}

test "toml replace value through scattered table headers" {
    var ed = try newTomlEditor("[a]\nx = 1\n[a.b]\ny = 2\n[a.c]\nz = 3\n");
    defer ed.deinit();
    // The owning table `a` spans the whole file (it nests b and c), but the
    // value node's span is contiguous, so the point edit is exact.
    try ed.replaceValAtPath(&.{ .{ .key = "a" }, .{ .key = "b" }, .{ .key = "y" } }, "99");
    try expectTomlSource(&ed, "[a]\nx = 1\n[a.b]\ny = 99\n[a.c]\nz = 3\n");
}

test "toml replace dotted-key value" {
    var ed = try newTomlEditor("a.b.c = 1\n");
    defer ed.deinit();
    try ed.replaceValAtPath(&.{ .{ .key = "a" }, .{ .key = "b" }, .{ .key = "c" } }, "2");
    try expectTomlSource(&ed, "a.b.c = 2\n");
}

test "toml replace value with an inline array" {
    var ed = try newTomlEditor("ports = [1, 2]\n");
    defer ed.deinit();
    try ed.replaceValAtPath(&.{.{ .key = "ports" }}, "[3, 4, 5]");
    try expectTomlSource(&ed, "ports = [3, 4, 5]\n");
}

test "toml rename a leaf key" {
    var ed = try newTomlEditor("[server]\nport = 8080\n");
    defer ed.deinit();
    try ed.replaceKeyAtPath(&.{ .{ .key = "server" }, .{ .key = "port" } }, "listen_port");
    try expectTomlSource(&ed, "[server]\nlisten_port = 8080\n");
}

test "toml failed edit rolls back and keeps editor usable" {
    var ed = try newTomlEditor("a = 1\nb = 2\n");
    defer ed.deinit();
    // An unterminated array fails to reparse; the source must be restored.
    if (ed.replaceValAtPath(&.{.{ .key = "a" }}, "[oops")) |_| {
        return error.TestExpectedFailedEdit;
    } else |_| {}
    try expectTomlSource(&ed, "a = 1\nb = 2\n");
    try ed.replaceValAtPath(&.{.{ .key = "a" }}, "9");
    try expectTomlSource(&ed, "a = 9\nb = 2\n");
}

// --- TOML structural editing (insert/delete scalar keys, inline arrays, AoT append) ---
//
// Format-preserving via spans; the genuinely scattered cases (whole-table
// delete/move, non-contiguous tables) refuse with a clear error.

test "toml insert key into root" {
    var ed = try newTomlEditor("a = 1\nb = 2\n");
    defer ed.deinit();
    try ed.insertKey(&.{}, "c", "3");
    try expectTomlSource(&ed, "a = 1\nb = 2\nc = 3\n");
}

test "toml insert key into empty document" {
    var ed = try newTomlEditor("");
    defer ed.deinit();
    try ed.insertKey(&.{}, "a", "1");
    try expectTomlSource(&ed, "a = 1\n");
}

test "toml insert root key goes above the first header" {
    // The new root key must land in root's own region — before `[t]` opens —
    // not after the table (which would reparent it into `[t]`).
    var ed = try newTomlEditor("x = 1\n[t]\ny = 2\n");
    defer ed.deinit();
    try ed.insertKey(&.{}, "z", "3");
    try expectTomlSource(&ed, "x = 1\nz = 3\n[t]\ny = 2\n");
}

test "toml insert key into a table" {
    var ed = try newTomlEditor("[server]\nhost = \"a\"\nport = 1\n");
    defer ed.deinit();
    try ed.insertKey(&.{.{ .key = "server" }}, "tls", "true");
    try expectTomlSource(&ed, "[server]\nhost = \"a\"\nport = 1\ntls = true\n");
}

test "toml insert into a table that has a sub-table inserts before the sub-header" {
    var ed = try newTomlEditor("[a]\nx = 1\n[a.b]\ny = 2\n");
    defer ed.deinit();
    try ed.insertKey(&.{.{ .key = "a" }}, "w", "9");
    try expectTomlSource(&ed, "[a]\nx = 1\nw = 9\n[a.b]\ny = 2\n");
}

test "toml insert into a header-only table" {
    var ed = try newTomlEditor("[a]\n[a.b]\ny = 2\n");
    defer ed.deinit();
    try ed.insertKey(&.{.{ .key = "a" }}, "x", "1");
    try expectTomlSource(&ed, "[a]\nx = 1\n[a.b]\ny = 2\n");
}

test "toml insert preserves the column of existing entries" {
    var ed = try newTomlEditor("[a]\n  x = 1\n");
    defer ed.deinit();
    try ed.insertKey(&.{.{ .key = "a" }}, "y", "2");
    try expectTomlSource(&ed, "[a]\n  x = 1\n  y = 2\n");
}

test "toml insert into an inline table" {
    var ed = try newTomlEditor("p = { x = 1 }\n");
    defer ed.deinit();
    try ed.insertKey(&.{.{ .key = "p" }}, "y", "2");
    try expectTomlSource(&ed, "p = { x = 1, y = 2 }\n");
}

test "toml insert into an empty inline table" {
    var ed = try newTomlEditor("p = {}\n");
    defer ed.deinit();
    try ed.insertKey(&.{.{ .key = "p" }}, "x", "1");
    try expectTomlSource(&ed, "p = { x = 1 }\n");
}

test "toml insert duplicate key rolls back" {
    var ed = try newTomlEditor("a = 1\n");
    defer ed.deinit();
    try std.testing.expectError(error.DuplicateKey, ed.insertKey(&.{}, "a", "2"));
    try expectTomlSource(&ed, "a = 1\n");
}

test "toml delete scalar key" {
    var ed = try newTomlEditor("a = 1\nb = 2\nc = 3\n");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "b" }});
    try expectTomlSource(&ed, "a = 1\nc = 3\n");
}

test "toml delete key with owned comment" {
    var ed = try newTomlEditor("a = 1\n# note\nb = 2\n");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "b" }});
    try expectTomlSource(&ed, "a = 1\n");
}

test "toml delete key inside a table" {
    var ed = try newTomlEditor("[t]\nx = 1\ny = 2\n");
    defer ed.deinit();
    try ed.deleteKey(&.{ .{ .key = "t" }, .{ .key = "x" } });
    try expectTomlSource(&ed, "[t]\ny = 2\n");
}

test "toml delete an inline-table-valued key" {
    var ed = try newTomlEditor("a = 1\np = { x = 1, y = 2 }\nb = 2\n");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "p" }});
    try expectTomlSource(&ed, "a = 1\nb = 2\n");
}

test "toml delete dotted key removes the line" {
    var ed = try newTomlEditor("a.b.c = 1\na.b.d = 2\n");
    defer ed.deinit();
    try ed.deleteKey(&.{ .{ .key = "a" }, .{ .key = "b" }, .{ .key = "c" } });
    try expectTomlSource(&ed, "a.b.d = 2\n");
}

test "toml deleting a header table is refused" {
    var ed = try newTomlEditor("[a]\nx = 1\n[a.b]\ny = 2\n");
    defer ed.deinit();
    try std.testing.expectError(error.CannotDeleteTable, ed.deleteKey(&.{ .{ .key = "a" }, .{ .key = "b" } }));
    try expectTomlSource(&ed, "[a]\nx = 1\n[a.b]\ny = 2\n");
}

test "toml deleting an array-of-tables is refused" {
    var ed = try newTomlEditor("[[fruit]]\nname = \"apple\"\n");
    defer ed.deinit();
    try std.testing.expectError(error.CannotDeleteTable, ed.deleteKey(&.{.{ .key = "fruit" }}));
}

test "toml inline array append/prepend/remove" {
    var ed = try newTomlEditor("ports = [1, 2]\n");
    defer ed.deinit();
    try ed.appendToSeq(&.{.{ .key = "ports" }}, "3");
    try expectTomlSource(&ed, "ports = [1, 2, 3]\n");
    try ed.prependToSeq(&.{.{ .key = "ports" }}, "0");
    try expectTomlSource(&ed, "ports = [0, 1, 2, 3]\n");
    try ed.removeSeqItem(&.{.{ .key = "ports" }}, 2);
    try expectTomlSource(&ed, "ports = [0, 1, 3]\n");
}

test "toml inline array ops on array-of-tables are refused" {
    var ed = try newTomlEditor("[[fruit]]\nname = \"apple\"\n");
    defer ed.deinit();
    try std.testing.expectError(error.NotAnInlineArray, ed.appendToSeq(&.{.{ .key = "fruit" }}, "1"));
}

test "toml append array-of-tables element" {
    var ed = try newTomlEditor("[[fruit]]\nname = \"apple\"\n");
    defer ed.deinit();
    try ed.appendTableToArray(&.{.{ .key = "fruit" }}, "name = \"pear\"\n");
    try expectTomlSource(&ed, "[[fruit]]\nname = \"apple\"\n\n[[fruit]]\nname = \"pear\"\n");
}

test "toml append AoT element after one with a sub-table" {
    // The new element must splice past the last element's nested sub-table, not
    // into the middle of it.
    var ed = try newTomlEditor("[[fruit]]\nname = \"apple\"\n\n[fruit.variety]\nkind = \"red\"\n");
    defer ed.deinit();
    try ed.appendTableToArray(&.{.{ .key = "fruit" }}, "name = \"pear\"\n");
    try expectTomlSource(&ed, "[[fruit]]\nname = \"apple\"\n\n[fruit.variety]\nkind = \"red\"\n\n[[fruit]]\nname = \"pear\"\n");
}

test "toml append empty AoT element" {
    var ed = try newTomlEditor("[[fruit]]\nname = \"apple\"\n");
    defer ed.deinit();
    try ed.appendTableToArray(&.{.{ .key = "fruit" }}, "");
    try expectTomlSource(&ed, "[[fruit]]\nname = \"apple\"\n\n[[fruit]]\n");
}

test "toml append AoT with a dotted header path" {
    var ed = try newTomlEditor("[[a.b]]\nx = 1\n");
    defer ed.deinit();
    try ed.appendTableToArray(&.{ .{ .key = "a" }, .{ .key = "b" } }, "x = 2\n");
    try expectTomlSource(&ed, "[[a.b]]\nx = 1\n\n[[a.b]]\nx = 2\n");
}

test "toml appendTableToArray on a non-AoT is refused" {
    var ed = try newTomlEditor("nums = [1, 2]\n");
    defer ed.deinit();
    try std.testing.expectError(error.NotAnArrayOfTables, ed.appendTableToArray(&.{.{ .key = "nums" }}, "x = 1\n"));
}

// --- deleteTable ---

test "toml delete simple header table" {
    var ed = try newTomlEditor("[a]\nx = 1\n[b]\ny = 2\n");
    defer ed.deinit();
    try ed.deleteTable(&.{.{ .key = "a" }});
    try expectTomlSource(&ed, "[b]\ny = 2\n");
}

test "toml delete table leaves interleaved foreign table intact" {
    var ed = try newTomlEditor("[a]\nx = 1\n[other]\ny = 2\n[a.b]\nz = 3\n");
    defer ed.deinit();
    try ed.deleteTable(&.{.{ .key = "a" }});
    try expectTomlSource(&ed, "[other]\ny = 2\n");
}

test "toml delete header-only table with sub-tables" {
    var ed = try newTomlEditor("[a]\n[a.b]\ny = 2\n");
    defer ed.deinit();
    try ed.deleteTable(&.{.{ .key = "a" }});
    try expectTomlSource(&ed, "");
}

test "toml delete table carries owned comment" {
    var ed = try newTomlEditor("# about a\n[a]\nx = 1\n[b]\ny = 2\n");
    defer ed.deinit();
    try ed.deleteTable(&.{.{ .key = "a" }});
    try expectTomlSource(&ed, "[b]\ny = 2\n");
}

test "toml delete table with multi-line array value" {
    var ed = try newTomlEditor("[a]\nl = [\n  1,\n  2,\n]\n[b]\ny = 2\n");
    defer ed.deinit();
    try ed.deleteTable(&.{.{ .key = "a" }});
    try expectTomlSource(&ed, "[b]\ny = 2\n");
}

test "toml delete dotted-only table" {
    var ed = try newTomlEditor("a.b = 1\na.c = 2\nz = 9\n");
    defer ed.deinit();
    try ed.deleteTable(&.{.{ .key = "a" }});
    try expectTomlSource(&ed, "z = 9\n");
}

test "toml delete whole array-of-tables" {
    var ed = try newTomlEditor("[[f]]\nn = \"a\"\n[[f]]\nn = \"b\"\n");
    defer ed.deinit();
    try ed.deleteTable(&.{.{ .key = "f" }});
    try expectTomlSource(&ed, "");
}

test "toml delete single AoT element" {
    var ed = try newTomlEditor("[[f]]\nn = \"a\"\n[[f]]\nn = \"b\"\n");
    defer ed.deinit();
    try ed.deleteTable(&.{ .{ .key = "f" }, .{ .index = 0 } });
    try expectTomlSource(&ed, "[[f]]\nn = \"b\"\n");
}

test "toml delete AoT element with nested sub-table" {
    var ed = try newTomlEditor("[[f]]\nn = \"a\"\n[f.sub]\nk = 1\n[[f]]\nn = \"b\"\n");
    defer ed.deinit();
    try ed.deleteTable(&.{ .{ .key = "f" }, .{ .index = 0 } });
    try expectTomlSource(&ed, "[[f]]\nn = \"b\"\n");
}

test "toml deleteTable on a scalar key is refused" {
    var ed = try newTomlEditor("x = 1\n");
    defer ed.deinit();
    try std.testing.expectError(error.NotATable, ed.deleteTable(&.{.{ .key = "x" }}));
}

// --- insertTable ---

test "toml insert new table at root end" {
    var ed = try newTomlEditor("a = 1\n[t]\nx = 1\n");
    defer ed.deinit();
    try ed.insertTable(&.{.{ .key = "s" }}, "p = 1\n");
    try expectTomlSource(&ed, "a = 1\n[t]\nx = 1\n\n[s]\np = 1\n");
}

test "toml insert sub-table after parent subtree" {
    var ed = try newTomlEditor("[a]\nx = 1\n");
    defer ed.deinit();
    try ed.insertTable(&.{ .{ .key = "a" }, .{ .key = "b" } }, "z = 3\n");
    try expectTomlSource(&ed, "[a]\nx = 1\n\n[a.b]\nz = 3\n");
}

test "toml insert empty table" {
    var ed = try newTomlEditor("a = 1\n");
    defer ed.deinit();
    try ed.insertTable(&.{.{ .key = "t" }}, "");
    try expectTomlSource(&ed, "a = 1\n\n[t]\n");
}

test "toml insert table with quoted-key segment" {
    var ed = try newTomlEditor("a = 1\n");
    defer ed.deinit();
    try ed.insertTable(&.{.{ .key = "needs space" }}, "x = 1\n");
    try expectTomlSource(&ed, "a = 1\n\n[\"needs space\"]\nx = 1\n");
}

test "toml insert duplicate table is refused" {
    var ed = try newTomlEditor("[a]\nx = 1\n");
    defer ed.deinit();
    try std.testing.expectError(error.TableExists, ed.insertTable(&.{.{ .key = "a" }}, "y = 2\n"));
}

// --- renameTable ---

test "toml rename leaf table header" {
    var ed = try newTomlEditor("[server]\nport = 8080\n");
    defer ed.deinit();
    try ed.renameTable(&.{.{ .key = "server" }}, "http");
    try expectTomlSource(&ed, "[http]\nport = 8080\n");
}

test "toml rename rewrites descendant sub-headers" {
    var ed = try newTomlEditor("[a]\nx = 1\n[a.b]\nz = 3\n[a.b.c]\nw = 4\n");
    defer ed.deinit();
    try ed.renameTable(&.{.{ .key = "a" }}, "q");
    try expectTomlSource(&ed, "[q]\nx = 1\n[q.b]\nz = 3\n[q.b.c]\nw = 4\n");
}

test "toml rename does not touch a similar-prefix foreign table" {
    var ed = try newTomlEditor("[a]\nx = 1\n[ab]\ny = 2\n");
    defer ed.deinit();
    try ed.renameTable(&.{.{ .key = "a" }}, "q");
    try expectTomlSource(&ed, "[q]\nx = 1\n[ab]\ny = 2\n");
}

test "toml rename leaf needing quotes" {
    var ed = try newTomlEditor("[a]\nx = 1\n");
    defer ed.deinit();
    try ed.renameTable(&.{.{ .key = "a" }}, "new key");
    try expectTomlSource(&ed, "[\"new key\"]\nx = 1\n");
}

test "toml rename AoT header" {
    var ed = try newTomlEditor("[[a.b]]\nn = 1\n[[a.b]]\nn = 2\n");
    defer ed.deinit();
    try ed.renameTable(&.{ .{ .key = "a" }, .{ .key = "b" } }, "c");
    try expectTomlSource(&ed, "[[a.c]]\nn = 1\n[[a.c]]\nn = 2\n");
}

// --- moveTable / reorderTables ---

test "toml move table to end" {
    var ed = try newTomlEditor("[a]\nx = 1\n[b]\ny = 2\n");
    defer ed.deinit();
    try ed.moveTable(&.{.{ .key = "a" }}, null);
    try expectTomlSource(&ed, "[b]\ny = 2\n\n[a]\nx = 1\n");
}

test "toml move scattered table collapses fragments contiguously" {
    var ed = try newTomlEditor("[a]\nx = 1\n[b]\ny = 2\n[a.c]\nz = 3\n");
    defer ed.deinit();
    try ed.moveTable(&.{.{ .key = "a" }}, null);
    try expectTomlSource(&ed, "[b]\ny = 2\n\n[a]\nx = 1\n[a.c]\nz = 3\n");
}

test "toml move table before another" {
    var ed = try newTomlEditor("[a]\nx = 1\n[b]\ny = 2\n[c]\nw = 3\n");
    defer ed.deinit();
    try ed.moveTable(&.{.{ .key = "c" }}, &.{.{ .key = "b" }});
    try expectTomlSource(&ed, "[a]\nx = 1\n\n[c]\nw = 3\n[b]\ny = 2\n");
}

test "toml reorder top-level tables" {
    var ed = try newTomlEditor("[a]\nx = 1\n[b]\ny = 2\n[c]\nw = 3\n");
    defer ed.deinit();
    try ed.reorderTables(&.{ "c", "a", "b" });
    try expectTomlSource(&ed, "[c]\nw = 3\n[a]\nx = 1\n[b]\ny = 2\n");
}
