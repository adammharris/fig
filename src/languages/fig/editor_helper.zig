//! fig-specific editing helpers for `Editor(Fig)`.
//!
//! The generic span-splice engine lives in `../editor.zig`; this module holds
//! the fig-only logic it delegates to. Unlike TOML (whose `[header]` syntax
//! forces a multi-region gather for almost every structural op) or YAML
//! (indentation-column rendering), fig's block layer is line-oriented and
//! self-describing — every line's `>` count states its own depth, so a new
//! sibling line can be spliced in *anywhere* after an existing child's full
//! text and still parse correctly. That collapses most of what would
//! otherwise be format-specific plumbing into one trick, used throughout this
//! file: **copy an existing sibling's marker-prefix text verbatim** (the run
//! of `>` markers + separator space immediately before its key/value) rather
//! than recomputing depth/indentation from scratch. See DESIGN.md's "Depth is
//! a correctness risk" and "prefix-count depth" for why this is safe.
//!
//! ## Whole-container structural ops (`deleteContainer`/`moveContainer`/
//! `reorderContainers`)
//!
//! fig has no `[bracket]` syntax to grep for like TOML, but the same
//! multi-region gather TOML needs (`toml/editor_helper.zig`) generalizes here:
//! ANY block (non-flow) mapping/sequence-valued entry was introduced by SOME
//! header line — a bare/dotted zero-marker path OR a nested `>` line, no
//! difference in kind (DESIGN.md "a header only selects/creates a map path")
//! — so `gatherContainerRegions` recurses into every block-container child
//! exactly the way `toml_edit.gatherTableRegions` recurses into every
//! `[header]` child, using each child's own (always-accurate — see
//! `fig/parser.zig`'s "AST assembly") span to recover its header line. This
//! correctly handles fig's TOML-equivalent scattering (a container's fields
//! split across separate dotted paths interleaved with foreign siblings,
//! DESIGN.md's `[a]`/`[other]`/`[a.b]` example translated to `a`/`other`/
//! `a.b`) for free.
//!
//! ## Scope (documented, not silent)
//!
//! fig uniquely also allows the exact SAME header path to be **re-entered**
//! verbatim (`database` written a second time, or `> pool` reopened later in
//! the same parent's body) to add more keys (DESIGN.md "Re-entering a path to
//! add new keys is fine") — the one shape `gatherContainerRegions` cannot
//! discover on its own, since only the FIRST occurrence's header-line position
//! is tracked (`TNode.span.start`, stamped once at creation). Deleting/moving
//! such a container still gathers every child correctly (they are all in the
//! node's one merged AST mapping regardless of which physical occurrence
//! wrote them) but only removes the FIRST header line, leaving any later
//! reopened header line orphaned with nothing under it — `FigEmptyContainer`
//! on the reparse `replaceAtSpan` always does, so the edit fails safely
//! (rolled back), never corrupts. `replaceValAtPath` overwriting such a
//! container's entire value in one splice carries the same narrow gap.
//! Index-addressed (`xs[i]`) elements built from more than one disjoint
//! top-level assignment are the sequence-side analogue; DESIGN.md already
//! flags `[i]` addressing itself as the edit-fragile, not-for-authoring
//! surface (`[]`/`+`/`> *` are the primary, always-contiguous ways to build a
//! list), so this is a pre-existing, self-selecting rarity rather than a new
//! footgun.

const std = @import("std");

const AST = @import("../../ast/ast.zig");
const Document = @import("../../document.zig");
const Span = @import("../../util/span.zig");
const editor = @import("../../editor.zig");
const Fig = @import("fig.zig").Language;
const log = std.log.scoped(.editor);

const FigEditor = editor.Editor(Fig);

const lineStartBefore = editor.lineStartBefore;
const lineEndAfter = editor.lineEndAfter;
const firstNonSpace = editor.firstNonSpace;
const isFlow = editor.isFlow;

/// The marker-prefix text (leading whitespace + `>` run + the one load-bearing
/// separator space, or "" at root) that precedes the content starting at
/// `content_start` on its own line. Copying this verbatim for a new sibling
/// line reproduces the exact depth *and* the file's spaced-vs-glued marker
/// style, with no separate bookkeeping.
fn linePrefix(source: []const u8, content_start: usize) []const u8 {
    return source[lineStartBefore(source, content_start)..content_start];
}

// ============================================================================
// insertKey — `Editor(Fig).insertKey`'s fig branch
// ============================================================================

/// Insert `key_text = value_text` into the mapping `node` (a block or flow
/// mapping; `is_root` when `node` is the document root, where keys carry zero
/// markers). Dispatches on `isFlow`; block insertion lands the new line right
/// after the mapping's last child's own full extent (safe even if `node`
/// itself is a re-entered/scattered container — see module doc comment) with
/// a marker-prefix copied from an existing child.
pub fn figInsertKey(self: *FigEditor, parsed: Document, node: AST.Node, span: Span, is_root: bool, key_text: []const u8, value_text: []const u8) !void {
    if (node.kind != .mapping) return error.NotAMapping;
    const source = self.source.items;
    if (isFlow(source, span))
        return figInsertFlowEntry(self, parsed, node, span, key_text, value_text);

    // A parsed block mapping is never empty — `FigEmptyContainer` rejects an
    // empty container at parse time — so there is always an existing child to
    // anchor the insertion on and (for a non-root mapping) to copy a prefix
    // from. Root keys always carry zero markers, so no lookup is needed there.
    const prefix: []const u8 = if (is_root) "" else blk: {
        const first_key = (try parsed.ast.firstChildKey(&node)).?;
        break :blk linePrefix(source, parsed.span(first_key).start);
    };
    const last = (try parsed.ast.lastChild(&node)).?;
    const insert_at = lineEndAfter(source, parsed.span(last).end -| 1);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    if (insert_at > 0 and source[insert_at - 1] != '\n') try out.append(self.allocator, '\n');
    try out.appendSlice(self.allocator, prefix);
    try out.appendSlice(self.allocator, key_text);
    try out.appendSlice(self.allocator, " = ");
    try out.appendSlice(self.allocator, value_text);
    try out.append(self.allocator, '\n');
    try self.replaceAtSpan(Span.init(insert_at, insert_at), out.items);
}

/// Splice `key_text <sep> value_text` into a flow mapping (`{ … }`), matching
/// the object's own pair mode: fig-inline (`=`, bare-or-quoted keys) or JSON
/// (`:`, quoted keys required) — a flow object may not mix the two
/// (`FigMixedFlowSeparators`). An empty `{}` defaults to fig-inline, the
/// native/first-class spelling. `key_text` is spliced verbatim (the same
/// contract every other `insertKey` arm relies on): inserting an unquoted key
/// into a JSON-mode object is caught by the reparse-rollback safety net
/// (`replaceAtSpan`), not pre-validated here.
fn figInsertFlowEntry(self: *FigEditor, parsed: Document, node: AST.Node, span: Span, key_text: []const u8, value_text: []const u8) !void {
    const source = self.source.items;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);

    if (node.kind.mapping) |first_id| {
        const kv = parsed.ast.nodes[first_id].kind.keyvalue;
        const first_key_end = parsed.span(parsed.ast.nodes[kv.key]).end;
        const after = firstNonSpace(source, first_key_end);
        const sep: []const u8 = if (after < source.len and source[after] == ':') ": " else " = ";

        var last = first_id;
        while (parsed.ast.nodes[last].next_sibling) |n| last = n;
        const at = parsed.span(parsed.ast.nodes[last]).end;

        try out.appendSlice(self.allocator, ", ");
        try out.appendSlice(self.allocator, key_text);
        try out.appendSlice(self.allocator, sep);
        try out.appendSlice(self.allocator, value_text);
        try self.replaceAtSpan(Span.init(at, at), out.items);
        return;
    }

    try out.append(self.allocator, ' ');
    try out.appendSlice(self.allocator, key_text);
    try out.appendSlice(self.allocator, " = ");
    try out.appendSlice(self.allocator, value_text);
    try out.append(self.allocator, ' ');
    const at = span.start + 1; // just after '{'
    try self.replaceAtSpan(Span.init(at, at), out.items);
}

// ============================================================================
// append/prepend — `Editor(Fig).appendToSeq`/`prependToSeq`'s block-sequence arm
// ============================================================================

/// Append `value_text` as a new element line at the end of the block sequence
/// `node` (`> *`/`> * value`, at whatever depth its siblings already sit at).
/// `value_text` must be a single-line scalar literal — a multi-line value
/// (e.g. a map-shaped element) needs its own per-line marker prefixes, which
/// this does not synthesize; such an attempt fails safely via the
/// reparse-rollback safety net rather than corrupting the file. Building a
/// map-shaped element is `> *` block authoring (DESIGN.md) or the dedicated
/// append-header op, neither of which this single-value primitive covers.
pub fn figAppendSeqLine(self: *FigEditor, parsed: Document, node: AST.Node, value_text: []const u8) !void {
    const source = self.source.items;
    const first = (try parsed.ast.child(&node)).?; // FigEmptyContainer: never empty
    const last = (try parsed.ast.lastChild(&node)).?;
    const prefix = linePrefix(source, parsed.span(first).start);
    const insert_at = lineEndAfter(source, parsed.span(last).end -| 1);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    if (insert_at > 0 and source[insert_at - 1] != '\n') try out.append(self.allocator, '\n');
    try out.appendSlice(self.allocator, prefix);
    try out.appendSlice(self.allocator, value_text);
    try out.append(self.allocator, '\n');
    try self.replaceAtSpan(Span.init(insert_at, insert_at), out.items);
}

/// Insert `value_text` as a new element line just before the block sequence
/// `node`'s current first element. Same single-line-scalar contract as
/// `figAppendSeqLine`.
pub fn figPrependSeqLine(self: *FigEditor, parsed: Document, node: AST.Node, value_text: []const u8) !void {
    const source = self.source.items;
    const first = (try parsed.ast.child(&node)).?;
    const first_start = parsed.span(first).start;
    const prefix = linePrefix(source, first_start);
    const line_start = lineStartBefore(source, first_start);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    try out.appendSlice(self.allocator, prefix);
    try out.appendSlice(self.allocator, value_text);
    try out.append(self.allocator, '\n');
    try self.replaceAtSpan(Span.init(line_start, line_start), out.items);
}

// ============================================================================
// WHOLE-CONTAINER STRUCTURAL EDITING (multi-region) — `deleteContainer`,
// `moveContainer`, `reorderContainers`. See the module doc comment for the
// gather algorithm and its scope. `renameContainer` needs no dedicated op:
// the generic `replaceKeyAtPath` already splices a single-occurrence header's
// key in place (it only touches the key's own tight span).
// ============================================================================

/// A line-aligned source range `[start, end)` belonging to a logical
/// container's subtree. Mirrors `toml/editor_helper.zig`'s `Region`.
const Region = struct { start: usize, end: usize };

/// The physical line of a fig block container's OWN header — the comment
/// block above it through the header line's own newline. `content_start` is
/// any position on that line at or after the marker prefix — a mapping
/// entry's `key_span.start` or a sequence element's own `span.start`, both of
/// which every node already carries (see `fig/parser.zig`'s `TNode.span` doc
/// comment) — `lineStartBefore` recovers the true line start regardless of
/// exactly where within it `content_start` falls (e.g. the "b" of a dotted
/// "a.b" header).
fn headerLineRegion(source: []const u8, content_start: usize) Region {
    const ls = lineStartBefore(source, content_start);
    return .{ .start = commentBlockStart(source, ls), .end = lineEndAfter(source, ls) };
}

/// The physical region of a DIRECT (scalar or flow-container) mapping entry
/// or sequence element: its owned comment block through the end of its own
/// span's last line (multi-line only for a `'''`/`"""` string value).
fn entryLineRegion(source: []const u8, span: Span) Region {
    return .{ .start = commentBlockStart(source, lineStartBefore(source, span.start)), .end = lineEndAfter(source, span.end -| 1) };
}

/// `../editor.zig`'s `commentBlockStart`, pinned to fig's `#` marker (the only
/// comment style fig has, so no `CommentStyle` parameter is threaded through
/// this module).
fn commentBlockStart(source: []const u8, line_start: usize) usize {
    return editor.commentBlockStart(source, line_start, .hash);
}

/// Append every region belonging to the subtree of block container `node`
/// (mapping or sequence), NOT including `node`'s own header line (the caller
/// adds that — see the module doc comment on why fig has no single
/// `include_header` flag the way TOML's `gatherTableRegions` does: a fig
/// container's "header" is just wherever its owning key/element sits, always
/// recoverable from a child's own span, so there is no header-less root case
/// to special-case here the way TOML's dotted-only tables need). Each child is
/// classified purely by its value's kind: a block (non-flow) mapping/sequence
/// is itself introduced by a header line and recursed into; anything else
/// (scalar, or a flow container, which is tightly single-region) is a direct
/// entry taken whole.
fn gatherContainerRegions(parsed: Document, source: []const u8, allocator: std.mem.Allocator, node: AST.Node, out: *std.ArrayList(Region)) std.mem.Allocator.Error!void {
    switch (node.kind) {
        .mapping => |first| {
            var cur = first;
            while (cur) |id| : (cur = parsed.ast.nodes[id].next_sibling) {
                const kv = parsed.ast.nodes[id];
                const kv_span = parsed.span(kv);
                const val = parsed.ast.nodes[kv.kind.keyvalue.value];
                try gatherChild(parsed, source, allocator, val, kv_span, out);
            }
        },
        .sequence => |first| {
            var cur = first;
            while (cur) |id| : (cur = parsed.ast.nodes[id].next_sibling) {
                const el = parsed.ast.nodes[id];
                try gatherChild(parsed, source, allocator, el, parsed.span(el), out);
            }
        },
        else => unreachable, // callers only pass a mapping/sequence node
    }
}

/// One child's contribution to its parent's gather: `own_span` is the span a
/// direct entry would use whole (a mapping's `keyvalue` span, or a sequence
/// element's own span — the two differ only in whether a separate key exists,
/// which `val`/`val_span` below already accounts for).
fn gatherChild(parsed: Document, source: []const u8, allocator: std.mem.Allocator, val: AST.Node, own_span: Span, out: *std.ArrayList(Region)) std.mem.Allocator.Error!void {
    switch (val.kind) {
        .mapping, .sequence => {
            const val_span = parsed.span(val);
            if (isFlow(source, val_span)) {
                try out.append(allocator, entryLineRegion(source, own_span));
            } else {
                try out.append(allocator, headerLineRegion(source, val_span.start));
                try gatherContainerRegions(parsed, source, allocator, val, out);
            }
        },
        else => try out.append(allocator, entryLineRegion(source, own_span)),
    }
}

/// Sort `regions` by start and coalesce overlapping/touching ones into a
/// disjoint, ascending set (in place); returns the coalesced count. Mirrors
/// `toml/editor_helper.zig`'s `normalizeRegions` (touching regions DO merge
/// here — unlike TOML's rename, nothing in this module needs to address a
/// region's own start independently of its neighbor).
fn normalizeRegions(regions: []Region) usize {
    std.mem.sort(Region, regions, {}, struct {
        fn lt(_: void, a: Region, b: Region) bool {
            return a.start < b.start;
        }
    }.lt);
    if (regions.len == 0) return 0;
    var w: usize = 0;
    for (regions[1..]) |r| {
        if (r.start <= regions[w].end) {
            regions[w].end = @max(regions[w].end, r.end);
        } else {
            w += 1;
            regions[w] = r;
        }
    }
    return w + 1;
}

/// Rebuild the source with `regions` (disjoint, ascending) removed, in one
/// `replaceAtSpan` so the reparse/rollback runs once.
fn spliceOutRegions(self: *FigEditor, regions: []const Region) !void {
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

/// Append `block` to `out` separated from any preceding content by exactly
/// one blank line (two newlines) — used when relocating a container so it
/// reads as its own section at the destination. Mirrors
/// `toml/editor_helper.zig`'s `appendWithBlankBefore`.
fn appendWithBlankBefore(out: *std.ArrayList(u8), allocator: std.mem.Allocator, block: []const u8) !void {
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

/// The gathered, coalesced region set for the block container at `path`
/// (including its own header line) — the shared setup `deleteContainer`,
/// `moveContainer`, and `reorderContainers` all start from. Errors
/// `NotAContainer` when `path` doesn't resolve to a mapping/sequence, or
/// resolves to one written as a flow value (tightly single-region — delete it
/// via `deleteKey` instead, move/reorder don't apply to an inline value).
fn gatherKeyedContainer(parsed: Document, source: []const u8, allocator: std.mem.Allocator, path: []const AST.PathSegment) !struct { node: AST.Node, regions: std.ArrayList(Region) } {
    if (path.len == 0) return error.NotAContainer;
    const node = try parsed.ast.getValByPath(path);
    if (node.kind != .mapping and node.kind != .sequence) return error.NotAContainer;
    const span = parsed.span(node);
    if (isFlow(source, span)) return error.NotAContainer;

    var regions: std.ArrayList(Region) = .empty;
    errdefer regions.deinit(allocator);
    try regions.append(allocator, headerLineRegion(source, span.start));
    try gatherContainerRegions(parsed, source, allocator, node, &regions);
    return .{ .node = node, .regions = regions };
}

/// Delete the whole block (non-flow) mapping or sequence named by `path` —
/// its own header line plus every region of its subtree (see the module doc
/// comment for the gather algorithm and its one scope gap). `path` may end in
/// a key or an index (deleting one sequence element entire — though
/// `removeSeqItem` is the more direct primitive for that). A scalar or
/// flow-valued target is refused with `error.NotAContainer` (use `deleteKey`/
/// `removeSeqItem`).
pub fn deleteContainer(self: *FigEditor, path: []const AST.PathSegment) !void {
    const parsed = try self.getParsed();
    const source = self.source.items;
    var g = try gatherKeyedContainer(parsed, source, self.allocator, path);
    defer g.regions.deinit(self.allocator);
    const n = normalizeRegions(g.regions.items);
    try spliceOutRegions(self, g.regions.items[0..n]);
}

/// Move the whole block container at `src_path` so it begins immediately
/// before the block container at `dest_path` (also a header-introduced
/// mapping/sequence), or at end-of-file when `dest_path` is null. The
/// source's scattered fragments (if any — see the module doc comment) are
/// removed from their original positions and re-emitted **contiguously** at
/// the destination, separated from surrounding content by a blank line; any
/// interleaved foreign siblings stay put. A no-op when the destination falls
/// inside the source's own gathered region.
pub fn moveContainer(self: *FigEditor, src_path: []const AST.PathSegment, dest_path: ?[]const AST.PathSegment) !void {
    const parsed = try self.getParsed();
    const source = self.source.items;
    var g = try gatherKeyedContainer(parsed, source, self.allocator, src_path);
    defer g.regions.deinit(self.allocator);
    const n = normalizeRegions(g.regions.items);
    const used = g.regions.items[0..n];
    if (n == 0) return;

    const dest_at = blk: {
        if (dest_path) |dp| {
            const dn = try parsed.ast.getValByPath(dp);
            const dspan = parsed.span(dn);
            if (isFlow(source, dspan)) return error.NotAContainer;
            break :blk headerLineRegion(source, dspan.start).start;
        }
        break :blk source.len;
    };
    for (used) |r| if (dest_at > r.start and dest_at < r.end) return; // no-op: destination is inside the source

    var moved: std.ArrayList(u8) = .empty;
    defer moved.deinit(self.allocator);
    for (used) |r| try moved.appendSlice(self.allocator, source[r.start..r.end]);

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

/// Reorder a set of top-level block containers (named by `order`, the keys in
/// their desired final order) among themselves. Each named container's
/// gathered fragments are removed and re-emitted contiguously, in `order`, at
/// the position the earliest of them currently occupies (tight `appendBlockSep`
/// separation — these were already siblings, unlike `moveContainer`'s
/// blank-line-separated relocation). Keys not named are untouched. Each name
/// must resolve to a root-level mapping/sequence (`error.NotAContainer`).
pub fn reorderContainers(self: *FigEditor, order: []const []const u8) !void {
    if (order.len == 0) return;
    const parsed = try self.getParsed();
    const source = self.source.items;

    var all: std.ArrayList(Region) = .empty;
    defer all.deinit(self.allocator);
    var bundles: std.ArrayList([]u8) = .empty;
    defer {
        for (bundles.items) |b| self.allocator.free(b);
        bundles.deinit(self.allocator);
    }

    for (order) |name| {
        const path: [1]AST.PathSegment = .{.{ .key = name }};
        var g = try gatherKeyedContainer(parsed, source, self.allocator, &path);
        defer g.regions.deinit(self.allocator);
        const n = normalizeRegions(g.regions.items);
        var bytes: std.ArrayList(u8) = .empty;
        for (g.regions.items[0..n]) |r| {
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
                try editor.appendBlockSep(&out, self.allocator, b);
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
// fig editor tests live here (rather than in editor.zig) so each language's
// editing tests sit next to that language's helpers, mirroring
// `toml/editor_helper.zig`.

fn newFigEditor(input: []const u8) !editor.Editor(Fig) {
    var ed: editor.Editor(Fig) = .{ .allocator = std.testing.allocator };
    try ed.init(input);
    return ed;
}

fn expectFigSource(ed: *const editor.Editor(Fig), expected: []const u8) !void {
    errdefer log.err("actual:   \"{s}\"", .{ed.source.items});
    errdefer log.err("expected: \"{s}\"", .{expected});
    try std.testing.expectEqualStrings(expected, ed.source.items);
}

// --- point edits (value/key replace — generic engine, spans only) ---

test "fig replace root scalar value" {
    var ed = try newFigEditor("title = old\nport = 8080\n");
    defer ed.deinit();
    try ed.replaceValAtPath(&.{.{ .key = "port" }}, "9090");
    try expectFigSource(&ed, "title = old\nport = 9090\n");
}

test "fig replace value nested under marker depth" {
    var ed = try newFigEditor("database\n> host = localhost\n> pool\n> > size = 10\n");
    defer ed.deinit();
    try ed.replaceValAtPath(&.{ .{ .key = "database" }, .{ .key = "pool" }, .{ .key = "size" } }, "20");
    try expectFigSource(&ed, "database\n> host = localhost\n> pool\n> > size = 20\n");
}

test "fig rename a leaf key" {
    var ed = try newFigEditor("server\n> port = 8080\n");
    defer ed.deinit();
    try ed.replaceKeyAtPath(&.{ .{ .key = "server" }, .{ .key = "port" } }, "listen_port");
    try expectFigSource(&ed, "server\n> listen_port = 8080\n");
}

test "fig failed edit rolls back and keeps editor usable" {
    var ed = try newFigEditor("a = 1\nb = 2\n");
    defer ed.deinit();
    if (ed.replaceValAtPath(&.{.{ .key = "a" }}, "[oops")) |_| {
        return error.TestExpectedFailedEdit;
    } else |_| {}
    try expectFigSource(&ed, "a = 1\nb = 2\n");
    try ed.replaceValAtPath(&.{.{ .key = "a" }}, "9");
    try expectFigSource(&ed, "a = 9\nb = 2\n");
}

// --- comments (generic engine, once spans + fig's `#` marker are right) ---

test "fig add leading comment matches marker depth" {
    var ed = try newFigEditor("database\n> host = localhost\n> pool\n> > size = 10\n");
    defer ed.deinit();
    try ed.addLeadingComment(&.{ .{ .key = "database" }, .{ .key = "pool" }, .{ .key = "size" } }, "note");
    try expectFigSource(&ed, "database\n> host = localhost\n> pool\n> > # note\n> > size = 10\n");
}

test "fig set trailing comment on a nested header line" {
    var ed = try newFigEditor("database\n> pool\n> > size = 10\n");
    defer ed.deinit();
    try ed.setTrailingComment(&.{ .{ .key = "database" }, .{ .key = "pool" } }, "nested container");
    try expectFigSource(&ed, "database\n> pool # nested container\n> > size = 10\n");
}

// --- insertKey (block) ---

test "fig insert key into root" {
    var ed = try newFigEditor("a = 1\nb = 2\n");
    defer ed.deinit();
    try ed.insertKey(&.{}, "c", "3");
    try expectFigSource(&ed, "a = 1\nb = 2\nc = 3\n");
}

test "fig insert key into a nested marker-block mapping" {
    var ed = try newFigEditor("database\n> host = localhost\n");
    defer ed.deinit();
    try ed.insertKey(&.{.{ .key = "database" }}, "port", "5432");
    try expectFigSource(&ed, "database\n> host = localhost\n> port = 5432\n");
}

test "fig insert key preserves spaced marker style at depth 2" {
    var ed = try newFigEditor("database\n> pool\n> > size = 10\n");
    defer ed.deinit();
    try ed.insertKey(&.{ .{ .key = "database" }, .{ .key = "pool" } }, "timeout", "30");
    try expectFigSource(&ed, "database\n> pool\n> > size = 10\n> > timeout = 30\n");
}

test "fig insert key after a container whose own line ends without a value" {
    // The new key must land after `pool`'s WHOLE nested body, not right after
    // the `pool` header line itself.
    var ed = try newFigEditor("database\n> pool\n> > size = 10\n");
    defer ed.deinit();
    try ed.insertKey(&.{.{ .key = "database" }}, "name", "primary");
    try expectFigSource(&ed, "database\n> pool\n> > size = 10\n> name = primary\n");
}

test "fig insert key into a fig-inline flow mapping" {
    var ed = try newFigEditor("p = { x = 1 }\n");
    defer ed.deinit();
    try ed.insertKey(&.{.{ .key = "p" }}, "y", "2");
    try expectFigSource(&ed, "p = { x = 1, y = 2 }\n");
}

test "fig insert key into an empty flow mapping defaults to fig-inline" {
    var ed = try newFigEditor("p = {}\n");
    defer ed.deinit();
    try ed.insertKey(&.{.{ .key = "p" }}, "x", "1");
    try expectFigSource(&ed, "p = { x = 1 }\n");
}

test "fig insert key into a JSON-mode flow mapping matches its colon separator" {
    var ed = try newFigEditor("p = { \"x\": 1 }\n");
    defer ed.deinit();
    try ed.insertKey(&.{.{ .key = "p" }}, "\"y\"", "2");
    try expectFigSource(&ed, "p = { \"x\": 1, \"y\": 2 }\n");
}

test "fig insert duplicate key rolls back" {
    var ed = try newFigEditor("a = 1\n");
    defer ed.deinit();
    try std.testing.expectError(error.FigDuplicateKey, ed.insertKey(&.{}, "a", "2"));
    try expectFigSource(&ed, "a = 1\n");
}

// --- deleteKey ---

test "fig delete scalar key" {
    var ed = try newFigEditor("a = 1\nb = 2\nc = 3\n");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "b" }});
    try expectFigSource(&ed, "a = 1\nc = 3\n");
}

test "fig delete key with owned comment" {
    var ed = try newFigEditor("a = 1\n# note\nb = 2\n");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "b" }});
    try expectFigSource(&ed, "a = 1\n");
}

test "fig delete a nested scalar key" {
    var ed = try newFigEditor("database\n> host = localhost\n> port = 5432\n");
    defer ed.deinit();
    try ed.deleteKey(&.{ .{ .key = "database" }, .{ .key = "port" } });
    try expectFigSource(&ed, "database\n> host = localhost\n");
}

test "fig delete a flow-container-valued key" {
    var ed = try newFigEditor("a = 1\np = { x = 1 }\nb = 2\n");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "p" }});
    try expectFigSource(&ed, "a = 1\nb = 2\n");
}

test "fig deleting a block-container-valued key is refused" {
    var ed = try newFigEditor("database\n> host = localhost\n> pool\n> > size = 10\n");
    defer ed.deinit();
    try std.testing.expectError(error.CannotDeleteContainer, ed.deleteKey(&.{ .{ .key = "database" }, .{ .key = "pool" } }));
    try expectFigSource(&ed, "database\n> host = localhost\n> pool\n> > size = 10\n");
}

// --- block sequence append/prepend/remove ---

test "fig append/prepend/remove a scalar sequence" {
    var ed = try newFigEditor("ports\n> * 1\n> * 2\n");
    defer ed.deinit();
    try ed.appendToSeq(&.{.{ .key = "ports" }}, "3");
    try expectFigSource(&ed, "ports\n> * 1\n> * 2\n> * 3\n");
    try ed.prependToSeq(&.{.{ .key = "ports" }}, "0");
    try expectFigSource(&ed, "ports\n> * 0\n> * 1\n> * 2\n> * 3\n");
    try ed.removeSeqItem(&.{.{ .key = "ports" }}, 2);
    try expectFigSource(&ed, "ports\n> * 0\n> * 1\n> * 3\n");
}

test "fig remove a map-shaped sequence element carries its whole body" {
    var ed = try newFigEditor("servers\n> *\n>> host = a.com\n> *\n>> host = b.com\n");
    defer ed.deinit();
    try ed.removeSeqItem(&.{.{ .key = "servers" }}, 0);
    try expectFigSource(&ed, "servers\n> *\n>> host = b.com\n");
}

test "fig inline array append/prepend/remove (flow)" {
    var ed = try newFigEditor("ports = [1, 2]\n");
    defer ed.deinit();
    try ed.appendToSeq(&.{.{ .key = "ports" }}, "3");
    try expectFigSource(&ed, "ports = [1, 2, 3]\n");
    try ed.prependToSeq(&.{.{ .key = "ports" }}, "0");
    try expectFigSource(&ed, "ports = [0, 1, 2, 3]\n");
    try ed.removeSeqItem(&.{.{ .key = "ports" }}, 2);
    try expectFigSource(&ed, "ports = [0, 1, 3]\n");
}

// --- renameContainer: no dedicated op — replaceKeyAtPath already does it ---

test "fig rename a container's key via the generic replaceKeyAtPath" {
    var ed = try newFigEditor("database\n> host = localhost\n> pool\n> > size = 10\n");
    defer ed.deinit();
    try ed.replaceKeyAtPath(&.{ .{ .key = "database" }, .{ .key = "pool" } }, "settings");
    try expectFigSource(&ed, "database\n> host = localhost\n> settings\n> > size = 10\n");
}

// --- deleteContainer ---

test "fig delete a nested block container" {
    var ed = try newFigEditor("database\n> host = localhost\n> pool\n> > size = 10\n");
    defer ed.deinit();
    try ed.deleteContainer(&.{ .{ .key = "database" }, .{ .key = "pool" } });
    try expectFigSource(&ed, "database\n> host = localhost\n");
}

test "fig delete a whole top-level container with all descendants" {
    var ed = try newFigEditor("database\n> host = localhost\n> pool\n> > size = 10\nother = 1\n");
    defer ed.deinit();
    try ed.deleteContainer(&.{.{ .key = "database" }});
    try expectFigSource(&ed, "other = 1\n");
}

test "fig delete carries an owned leading comment" {
    var ed = try newFigEditor("# about database\ndatabase\n> host = localhost\nother = 1\n");
    defer ed.deinit();
    try ed.deleteContainer(&.{.{ .key = "database" }});
    try expectFigSource(&ed, "other = 1\n");
}

test "fig delete a container split across dotted re-entry, foreign sibling intact" {
    // `a`/`other`/`a.b` — the fig equivalent of TOML's `[a]`/`[other]`/`[a.b]`
    // interleaving: `a.b` is a SEPARATE dotted path (not the identical header
    // `a` written twice), so gather finds it via recursion into `a`'s own
    // child "b", with no separate header-occurrence tracking needed.
    var ed = try newFigEditor("a\n> x = 1\nother = 1\na.b\n> z = 3\n");
    defer ed.deinit();
    try ed.deleteContainer(&.{.{ .key = "a" }});
    try expectFigSource(&ed, "other = 1\n");
}

test "fig delete a block sequence" {
    var ed = try newFigEditor("servers\n> *\n>> host = a.com\n> *\n>> host = b.com\nother = 1\n");
    defer ed.deinit();
    try ed.deleteContainer(&.{.{ .key = "servers" }});
    try expectFigSource(&ed, "other = 1\n");
}

test "fig delete one index-addressed block-mapped sequence element" {
    var ed = try newFigEditor("servers\n> *\n>> host = a.com\n> *\n>> host = b.com\n");
    defer ed.deinit();
    try ed.deleteContainer(&.{ .{ .key = "servers" }, .{ .index = 0 } });
    try expectFigSource(&ed, "servers\n> *\n>> host = b.com\n");
}

test "fig deleteContainer on a scalar is refused" {
    var ed = try newFigEditor("x = 1\n");
    defer ed.deinit();
    try std.testing.expectError(error.NotAContainer, ed.deleteContainer(&.{.{ .key = "x" }}));
    try expectFigSource(&ed, "x = 1\n");
}

test "fig deleteContainer on a flow-valued key is refused" {
    var ed = try newFigEditor("p = { x = 1 }\n");
    defer ed.deinit();
    try std.testing.expectError(error.NotAContainer, ed.deleteContainer(&.{.{ .key = "p" }}));
    try expectFigSource(&ed, "p = { x = 1 }\n");
}

test "fig deleteContainer on a re-entered header fails safely instead of corrupting" {
    // The exact same header (`database`, not a deeper dotted path) written
    // twice — the one shape gather can't fully discover (see the module doc
    // comment). Deleting removes every gathered child, orphaning the SECOND
    // "database" line with nothing under it; `FigEmptyContainer` on the
    // reparse then rolls the whole edit back rather than leaving a broken file.
    var ed = try newFigEditor("database\n> x = 1\nother = 1\ndatabase\n> y = 2\n");
    defer ed.deinit();
    try std.testing.expectError(error.FigEmptyContainer, ed.deleteContainer(&.{.{ .key = "database" }}));
    try expectFigSource(&ed, "database\n> x = 1\nother = 1\ndatabase\n> y = 2\n");
}

// --- moveContainer ---

test "fig move a container to end of file" {
    var ed = try newFigEditor("a\n> x = 1\nb\n> y = 2\n");
    defer ed.deinit();
    try ed.moveContainer(&.{.{ .key = "a" }}, null);
    try expectFigSource(&ed, "b\n> y = 2\n\na\n> x = 1\n");
}

test "fig move a container before another" {
    var ed = try newFigEditor("a\n> x = 1\nb\n> y = 2\nc\n> w = 3\n");
    defer ed.deinit();
    try ed.moveContainer(&.{.{ .key = "c" }}, &.{.{ .key = "b" }});
    try expectFigSource(&ed, "a\n> x = 1\n\nc\n> w = 3\nb\n> y = 2\n");
}

test "fig move a dotted-re-entry-scattered container collapses fragments contiguously" {
    var ed = try newFigEditor("a\n> x = 1\nb\n> y = 2\na.c\n> z = 3\n");
    defer ed.deinit();
    try ed.moveContainer(&.{.{ .key = "a" }}, null);
    try expectFigSource(&ed, "b\n> y = 2\n\na\n> x = 1\na.c\n> z = 3\n");
}

test "fig move destination inside the source is a no-op" {
    var ed = try newFigEditor("a\n> x = 1\n> pool\n> > size = 10\n");
    defer ed.deinit();
    try ed.moveContainer(&.{.{ .key = "a" }}, &.{ .{ .key = "a" }, .{ .key = "pool" } });
    try expectFigSource(&ed, "a\n> x = 1\n> pool\n> > size = 10\n");
}

test "fig moveContainer on a scalar is refused" {
    var ed = try newFigEditor("x = 1\na\n> y = 2\n");
    defer ed.deinit();
    try std.testing.expectError(error.NotAContainer, ed.moveContainer(&.{.{ .key = "x" }}, null));
    try expectFigSource(&ed, "x = 1\na\n> y = 2\n");
}

// --- realistic input lifted from con.fig's kitchen sink (`fig fmt` house
// style: spaced markers, trailing comments on nearly every line, a `#`
// section-header comment above the next top-level entry) ---

test "fig delete a nested container carries its own trailing comments, leaves the sibling section comment alone" {
    var ed = try newFigEditor(
        \\database # container header (bare word, no `=`)
        \\> host = localhost # database.host
        \\> port = 5432 # database.port  (bare number)
        \\> pool # nested container header
        \\> > size = 10 # database.pool.size
        \\> > timeout = 30 # database.pool.timeout
        \\
        \\# === Dotted-key flattener (flatten within one line) ===
        \\cache
        \\> redis
        \\> > host = 127.0.0.1 # cache.redis.host  (IP -> string, 3 dots)
        \\
    );
    defer ed.deinit();
    try ed.deleteContainer(&.{ .{ .key = "database" }, .{ .key = "pool" } });
    try expectFigSource(
        &ed,
        \\database # container header (bare word, no `=`)
        \\> host = localhost # database.host
        \\> port = 5432 # database.port  (bare number)
        \\
        \\# === Dotted-key flattener (flatten within one line) ===
        \\cache
        \\> redis
        \\> > host = 127.0.0.1 # cache.redis.host  (IP -> string, 3 dots)
        \\
        ,
    );
}

test "fig move a container up front of a differently-commented sibling" {
    var ed = try newFigEditor(
        \\database # container header (bare word, no `=`)
        \\> host = localhost # database.host
        \\
        \\# === Dotted-key flattener (flatten within one line) ===
        \\cache
        \\> redis
        \\> > host = 127.0.0.1 # cache.redis.host
        \\
    );
    defer ed.deinit();
    try ed.moveContainer(&.{.{ .key = "cache" }}, &.{.{ .key = "database" }});
    // No blank line goes IN FRONT of `cache` (it lands at the absolute start
    // of the file — `appendWithBlankBefore` only separates from PRECEDING
    // output, and there is none here); the original blank line that used to
    // separate `database` from `cache`'s leading comment rides along after
    // `database` instead (part of `database`'s own "kept" tail).
    try expectFigSource(
        &ed,
        \\# === Dotted-key flattener (flatten within one line) ===
        \\cache
        \\> redis
        \\> > host = 127.0.0.1 # cache.redis.host
        \\database # container header (bare word, no `=`)
        \\> host = localhost # database.host
        \\
        \\
        ,
    );
}

// --- reorderContainers ---

test "fig reorder top-level containers" {
    var ed = try newFigEditor("a\n> x = 1\nb\n> y = 2\nc\n> w = 3\n");
    defer ed.deinit();
    try ed.reorderContainers(&.{ "c", "a", "b" });
    try expectFigSource(&ed, "c\n> w = 3\na\n> x = 1\nb\n> y = 2\n");
}

test "fig reorder leaves an unnamed container untouched, in its original relative position" {
    var ed = try newFigEditor("a\n> x = 1\nb\n> y = 2\nc\n> w = 3\n");
    defer ed.deinit();
    // Only `b`/`a` are named (swapped); `c` isn't mentioned, so it stays put.
    try ed.reorderContainers(&.{ "b", "a" });
    try expectFigSource(&ed, "b\n> y = 2\na\n> x = 1\nc\n> w = 3\n");
}

test "fig reorderContainers on a scalar is refused" {
    var ed = try newFigEditor("x = 1\na\n> y = 2\n");
    defer ed.deinit();
    try std.testing.expectError(error.NotAContainer, ed.reorderContainers(&.{ "x", "a" }));
    try expectFigSource(&ed, "x = 1\na\n> y = 2\n");
}
