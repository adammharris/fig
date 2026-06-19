//! Editor module, generic over Language.

const std = @import("std");

const AST = @import("ast.zig");
const Document = @import("document.zig");
const Span = @import("util/span.zig");
const json = @import("json/json.zig");
const log = std.log.scoped(.editor);

pub fn Editor(comptime Language: type) type {
    @import("language.zig").validate(Language);
    return struct {
        const Self = @This();

        // Which leading-comment syntax this language uses, so the owned-comment
        // scan in delete/move (`commentBlockStart`) recognizes the right marker.
        // JSON/JSONC/JSON5 use `//` and `/* */`; YAML and TOML use `#`. Plain
        // JSON has no comments, but `.slashes` is harmless there since no `//`
        // line can exist.
        const comment_style: CommentStyle = if (Language == json.Language) .slashes else .hash;

        allocator: std.mem.Allocator,
        source: std.ArrayList(u8) = .empty,
        document: ?Document = null,
        format: Language.Type = Language.default_type,

        fn getParsed(self: *const Self) !Document {
            return self.document orelse {
                log.err("Not initialized!", .{});
                return error.NotInitialized;
            };
        }

        pub fn init(self: *Self, input: []const u8) !void {
            if (self.source.items.len != 0 or self.document != null) return error.MultipleInit;
            try self.source.appendSlice(self.allocator, input);
            self.document = try self.parseSource();
        }

        /// Replace a span with a new span. Atomic: on success `self.document` is
        /// the reparse of the edited source; if the edit produces source that no
        /// longer parses, the source is rolled back and the prior `self.document`
        /// stays valid, so a failed edit leaves the editor exactly as it was.
        pub fn replaceAtSpan(self: *Self, span: Span, replacement: []const u8) !void {
            // Snapshot the whole source so a failed reparse can be undone. The
            // edit already costs a full reparse, so an O(n) copy is negligible.
            const backup = try self.allocator.dupe(u8, self.source.items);
            defer self.allocator.free(backup);

            try self.replaceSource(span, replacement);
            self.reparse() catch |err| {
                // Restore byte-for-byte. Capacity is retained from before the
                // edit (>= backup.len), so the refill cannot fail.
                self.source.clearRetainingCapacity();
                self.source.appendSliceAssumeCapacity(backup);
                return err;
            };
        }

        /// Replace the value at `path`. Reference-layer behavior is copy-on-write:
        /// editing a value that is an alias (`b: *x`) replaces the `*x` text with
        /// the new literal (severing only that alias — its anchor and any other
        /// alias are untouched), which falls out of splicing the alias node's own
        /// span. A key supplied only by a `<<` merge is materialized locally,
        /// shadowing the merge. Use `replaceValAtPathFollowing` to edit through to
        /// a shared anchor instead.
        pub fn replaceValAtPath(self: *Self, path: []const AST.PathSegment, replacement: []const u8) !void {
            const parsed = try self.getParsed();
            const node = parsed.ast.getValByPath(path) catch |err| {
                // A merge-only key surfaces as NotFound (default nav doesn't follow
                // `<<`); COW it by inserting a local `key: value` that shadows the
                // merge.
                if (Language == Yaml and err == error.NotFound and try self.mergeSuppliesKey(parsed, path)) {
                    try self.insertKey(path[0 .. path.len - 1], path[path.len - 1].key, replacement);
                    return;
                }
                return err;
            };
            const span = parsed.span(node);
            // For a YAML mapping value, reframe the whole `: value` so the new
            // value is correctly shaped whatever its form — a scalar stays
            // inline, a block collection descends onto the following lines —
            // rather than splicing into the old value's slot, which can't
            // change inline<->block (e.g. `k: []` -> a block list). JSON has no
            // block style, so it keeps the direct splice.
            if (Language == Yaml and path.len > 0 and std.meta.activeTag(path[path.len - 1]) == .key) {
                try self.reframeMappingValue(parsed, path, span, replacement);
                return;
            }
            try self.replaceAtSpan(span, replacement);
        }

        /// Replace a mapping key's value, re-emitting `: value` through
        /// `writeMapValue` so the new value's framing (inline scalar vs block
        /// collection on following lines) is always valid regardless of the old
        /// value's shape.
        fn reframeMappingValue(self: *Self, parsed: Document, path: []const AST.PathSegment, val_span: Span, replacement: []const u8) !void {
            const source = self.source.items;
            const key_node = try parsed.ast.getKeyByPath(path);
            const key_span = parsed.span(key_node);
            const col = columnOf(source, key_span.start);
            // The `:` indicator sits just past the key (a plain key cannot
            // contain `:`, and a quoted key's `:` is inside `key_span`).
            const colon = std.mem.indexOfScalarPos(u8, source, key_span.end, ':') orelse
                return error.InvalidDocument;

            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);
            // writeMapValue emits the `:` itself, so replace from the existing
            // colon through the old value's end (a null value is a zero-width
            // span at the colon, hence the `@max`).
            try self.writeMapValue(&out, col, replacement);
            const end = @max(val_span.end, colon + 1);
            try self.replaceAtSpan(Span.init(colon, end), out.items);
        }

        /// Like `replaceValAtPath`, but follow into the reference layer: when the
        /// target value is an alias, edit the *anchored node* (the shared source),
        /// so every alias to that anchor reflects the change. The `&name` (and any
        /// tag) prefix is preserved — only the anchored value's bytes are
        /// replaced. A non-alias target behaves exactly like `replaceValAtPath`.
        pub fn replaceValAtPathFollowing(self: *Self, path: []const AST.PathSegment, replacement: []const u8) !void {
            const parsed = try self.getParsed();
            const node = parsed.ast.getValByPath(path) catch {
                return self.replaceValAtPath(path, replacement);
            };
            if (Language == Yaml and node.kind == .alias) {
                const target = parsed.ast.nodes[try parsed.ast.resolveAlias(node)];
                try self.replaceAtSpan(self.valueSpanWithoutProps(parsed, target), replacement);
                return;
            }
            try self.replaceValAtPath(path, replacement);
        }

        /// True when `path`'s final `.key` segment is not a physical entry of its
        /// parent mapping but is supplied by a `<<` merge.
        fn mergeSuppliesKey(self: *Self, parsed: Document, path: []const AST.PathSegment) !bool {
            _ = self;
            if (path.len == 0 or std.meta.activeTag(path[path.len - 1]) != .key) return false;
            const parent = parsed.ast.getValByPath(path[0 .. path.len - 1]) catch return false;
            if (parent.kind != .mapping) return false;
            return (parsed.ast.mergedChild(parent, path[path.len - 1].key) catch return false) != null;
        }

        /// The span of `node`'s value bytes, excluding any leading `&anchor`/`!tag`
        /// property prefix (the node's stored span starts at the property). Used by
        /// follow-mode so editing the anchored value keeps the anchor intact.
        fn valueSpanWithoutProps(self: *Self, parsed: Document, node: AST.Node) Span {
            const source = self.source.items;
            const full = parsed.span(node);
            var start = full.start;
            if (parsed.anchorSpan(node)) |a| start = @max(start, a.end);
            if (parsed.tagSpan(node)) |t| start = @max(start, t.end);
            while (start < full.end and (source[start] == ' ' or source[start] == '\t')) start += 1;
            return Span.init(start, full.end);
        }

        pub fn replaceKeyAtPath(self: *Self, path: []const AST.PathSegment, replacement: []const u8) !void {
            const parsed = try self.getParsed();
            const node = try parsed.ast.getKeyByPath(path);
            const span = parsed.span(node);
            try self.replaceAtSpan(span, replacement);
        }

        // ===============
        // INSERT / DELETE
        // ===============
        //
        // These ops never reserialize the document: each computes a byte span +
        // replacement text and reuses `replaceAtSpan` (splice + reparse). Inserts
        // splice at a zero-length span; deletes splice an empty replacement.
        // `value_text`/`key_text` arrive already serialized (single-line scalars,
        // or multi-line block text indented from column 0); the editor only
        // re-frames indentation and newline/comma context for the splice site.

        /// Insert `key_text: value_text` into the mapping at `path` (empty path =
        /// root). Appends after the mapping's last entry for block mappings, or
        /// inside the braces for flow `{}`. If `path` resolves to a `null` value
        /// (a bare `key:`), promotes it to a one-entry nested mapping.
        pub fn insertKey(self: *Self, path: []const AST.PathSegment, key_text: []const u8, value_text: []const u8) !void {
            const parsed = try self.getParsed();
            const node = try parsed.ast.getValByPath(path);
            const span = parsed.span(node);
            const source = self.source.items;
            if (Language == Toml)
                return self.tomlInsertKey(parsed, node, span, path.len == 0, key_text, value_text);
            switch (node.kind) {
                .mapping => |first| {
                    if (isFlow(source, span)) {
                        try self.insertFlowEntry(span, first != null, key_text, value_text);
                    } else {
                        try self.insertBlockKey(parsed, node, key_text, value_text);
                    }
                },
                .null_ => try self.promoteNullToMapping(span, node.id == parsed.ast.root, key_text, value_text),
                else => return error.NotAMapping,
            }
        }

        /// Delete the mapping entry at `path` (which must name a key). Removes the
        /// entry's full line(s) plus any owned leading comment block (a run of
        /// comment lines — `#` for YAML/TOML, `//` or `/* */` for JSON5/JSONC —
        /// with no intervening blank line), leaving no blank gap.
        pub fn deleteKey(self: *Self, path: []const AST.PathSegment) !void {
            const parsed = try self.getParsed();
            const node = parsed.ast.getNodeByPath(path) catch |err| {
                // A key that exists only via a `<<` merge has no physical line to
                // delete, and there is no YAML syntax to un-inherit it — deleting
                // the merge source is a different operation. Refuse explicitly.
                if (Language == Yaml and err == error.NotFound and try self.mergeSuppliesKey(parsed, path))
                    return error.MergeOnlyKey;
                return err;
            };
            if (node.kind != .keyvalue) return error.NotAMapping;
            const span = parsed.span(node);
            const source = self.source.items;
            // A TOML `[header]` table or `[[array]]` element has no contiguous
            // line span (its body is assembled from scattered headers), so a
            // line-based delete would only remove the header key. Refuse it; only
            // scalar/array/inline-table/dotted entries delete cleanly. (Detected
            // by the entry's line starting with `[`, which a normal `key = value`
            // never does.)
            if (Language == Toml) {
                const fns = firstNonSpace(source, lineStartBefore(source, span.start));
                if (fns < source.len and source[fns] == '[') return error.CannotDeleteTable;
            }
            const line_start = lineStartBefore(source, span.start);
            const del_start = commentBlockStart(source, line_start, comment_style);
            const del_end = lineEndAfter(source, span.end -| 1);
            try self.replaceAtSpan(Span.init(del_start, del_end), "");
        }

        /// Append `value_text` as a new item to the sequence at `path`.
        pub fn appendToSeq(self: *Self, path: []const AST.PathSegment, value_text: []const u8) !void {
            const parsed = try self.getParsed();
            const node = try parsed.ast.getValByPath(path);
            if (node.kind != .sequence) return error.NotASequence;
            const span = parsed.span(node);
            const source = self.source.items;
            if (isFlow(source, span)) {
                const first = node.kind.sequence;
                try self.insertFlowItem(span, first != null, value_text);
                return;
            }
            // A non-flow TOML sequence is an array-of-tables; use
            // `appendTableToArray` for those. (TOML has no block scalar array.)
            if (Language == Toml) return error.NotAnInlineArray;
            const last = (try parsed.ast.lastChild(&node)) orelse return error.NotASequence;
            const first_item = (try parsed.ast.child(&node)).?;
            const dash_col = dashColumn(source, parsed.span(first_item).start);
            const insert_at = lineEndAfter(source, parsed.span(last).end -| 1);
            try self.insertSeqLine(insert_at, dash_col, value_text);
        }

        /// Insert `value_text` before the first item of the sequence at `path`.
        pub fn prependToSeq(self: *Self, path: []const AST.PathSegment, value_text: []const u8) !void {
            const parsed = try self.getParsed();
            const node = try parsed.ast.getValByPath(path);
            if (node.kind != .sequence) return error.NotASequence;
            const span = parsed.span(node);
            const source = self.source.items;
            if (isFlow(source, span)) {
                try self.prependFlowItem(span, node.kind.sequence != null, value_text);
                return;
            }
            if (Language == Toml) return error.NotAnInlineArray;
            const first_item = (try parsed.ast.child(&node)) orelse return error.NotASequence;
            const first_start = parsed.span(first_item).start;
            const line_start = lineStartBefore(source, first_start);
            const dash_col = dashColumn(source, first_start);
            try self.insertSeqLine(line_start, dash_col, value_text);
        }

        /// Remove the item at `index` from the sequence at `path`.
        pub fn removeSeqItem(self: *Self, path: []const AST.PathSegment, index: usize) !void {
            const parsed = try self.getParsed();
            const node = try parsed.ast.getValByPath(path);
            if (node.kind != .sequence) return error.NotASequence;
            const span = parsed.span(node);
            const source = self.source.items;
            var item = (try parsed.ast.child(&node)) orelse return error.NotFound;
            for (0..index) |_| item = parsed.ast.next(&item) orelse return error.NotFound;
            const item_span = parsed.span(item);
            if (isFlow(source, span)) {
                try self.removeFlowItem(item_span, index == 0);
                return;
            }
            if (Language == Toml) return error.NotAnInlineArray;
            const line_start = commentBlockStart(source, lineStartBefore(source, item_span.start), comment_style);
            const del_end = lineEndAfter(source, item_span.end -| 1);
            try self.replaceAtSpan(Span.init(line_start, del_end), "");
        }

        // ============
        // MOVE / REORDER
        // ============
        //
        // Like insert/delete, these never reserialize: they relocate whole entry
        // blocks (a mapping key's owned comment block + line(s), or a sequence
        // item's) and reuse `replaceAtSpan` to splice + reparse. The moved bytes
        // are the originals, so comments, quoting, and formatting ride along.
        // Block containers tile into per-entry blocks (trailing trivia rides with
        // the preceding entry); a flow sequence (`[a, b]`) reuses its original
        // separators so only the items move.

        /// Move the mapping entry named by `src_path` to sit immediately before
        /// the entry named by `dest_path`. Both paths must name keys in the
        /// *same* block mapping. The moved entry carries its owned leading
        /// comment block and any trailing same-line comment; the bytes between
        /// the two entries are preserved. Moving an entry to before itself (or
        /// into its own comment block) is a no-op.
        pub fn moveKey(self: *Self, src_path: []const AST.PathSegment, dest_path: []const AST.PathSegment) !void {
            const parsed = try self.getParsed();
            const src = try parsed.ast.getNodeByPath(src_path);
            if (src.kind != .keyvalue) return error.NotAMapping;
            const dest = try parsed.ast.getNodeByPath(dest_path);
            if (dest.kind != .keyvalue) return error.NotAMapping;
            const source = self.source.items;
            try self.moveBlock(
                entryBlockStart(source, parsed.span(src), comment_style),
                entryBlockEnd(source, parsed.span(src)),
                entryBlockStart(source, parsed.span(dest), comment_style),
            );
        }

        /// Move the sequence item at index `from` to index `to` (both positions
        /// in the current order; standard array-move semantics — the item is
        /// removed and reinserted, shifting the others to fill). A block item
        /// carries its owned leading comment block. No-op when `from == to`.
        pub fn moveItem(self: *Self, path: []const AST.PathSegment, from: usize, to: usize) !void {
            const parsed = try self.getParsed();
            const node = try parsed.ast.getValByPath(path);
            if (node.kind != .sequence) return error.NotASequence;
            const n = try seqLen(parsed, node);
            if (from >= n or to >= n) return error.NotFound;
            if (from == to) return;
            // Build the post-move index order, then reorder by it.
            const order = try self.allocator.alloc(usize, n);
            defer self.allocator.free(order);
            for (order, 0..) |*o, i| o.* = i;
            const val = order[from];
            if (from < to) {
                var i = from;
                while (i < to) : (i += 1) order[i] = order[i + 1];
            } else {
                var i = from;
                while (i > to) : (i -= 1) order[i] = order[i - 1];
            }
            order[to] = val;
            try self.reorderSeqNode(parsed, node, order);
        }

        /// Reorder the entries of the block mapping at `path` (empty path =
        /// root) so the keys listed in `keys` come first, in that order; entries
        /// whose key is not listed keep their original relative order and follow.
        /// Keys in `keys` that the mapping does not contain are ignored. Each
        /// entry's owned comments — and any interleaved blank lines / orphan
        /// comments, which ride with the entry that precedes them — are
        /// preserved, so no bytes are dropped. Errors on a flow mapping (`{…}`).
        pub fn reorderKeys(self: *Self, path: []const AST.PathSegment, keys: []const []const u8) !void {
            const parsed = try self.getParsed();
            const node = try parsed.ast.getValByPath(path);
            if (node.kind != .mapping) return error.NotAMapping;
            const first_id = node.kind.mapping orelse return; // empty mapping
            const source = self.source.items;
            if (isFlow(source, parsed.span(node))) return error.NotAMapping;

            // Gather each entry's key (for matching) and block, in document order.
            var entry_keys: std.ArrayList([]const u8) = .empty;
            defer entry_keys.deinit(self.allocator);
            var blocks: std.ArrayList(Block) = .empty;
            defer blocks.deinit(self.allocator);

            var cur = parsed.ast.nodes[first_id];
            var last_end: usize = 0;
            while (true) {
                if (cur.kind != .keyvalue) return error.InvalidDocument;
                const key_node = parsed.ast.nodes[cur.kind.keyvalue.key];
                const key = switch (key_node.kind) {
                    .string => |s| s,
                    else => return error.InvalidDocument,
                };
                try entry_keys.append(self.allocator, key);
                try blocks.append(self.allocator, .{ .start = entryBlockStart(source, parsed.span(cur), comment_style), .end = 0 });
                last_end = entryBlockEnd(source, parsed.span(cur));
                cur = parsed.ast.next(&cur) orelse break;
            }
            tileBlocks(blocks.items, last_end);

            // Translate the requested keys into entry indices (first unused match
            // wins), then reorder the blocks by that index list.
            var order: std.ArrayList(usize) = .empty;
            defer order.deinit(self.allocator);
            const chosen = try self.allocator.alloc(bool, blocks.items.len);
            defer self.allocator.free(chosen);
            @memset(chosen, false);
            for (keys) |k| {
                for (entry_keys.items, 0..) |seen, i| {
                    if (!chosen[i] and std.mem.eql(u8, seen, k)) {
                        try order.append(self.allocator, i);
                        chosen[i] = true;
                        break;
                    }
                }
            }
            try self.reorderBlocks(blocks.items[0].start, last_end, blocks.items, order.items);
        }

        /// Reorder the items of the sequence at `path` (block or flow) so the
        /// items at the indices listed in `indices` (positions in the current
        /// order) come first, in that order; items not listed keep their
        /// original relative order and follow. Out-of-range indices are ignored.
        /// Block items carry their owned comments; a flow sequence keeps its
        /// original separators so only the items move.
        pub fn reorderItems(self: *Self, path: []const AST.PathSegment, indices: []const usize) !void {
            const parsed = try self.getParsed();
            const node = try parsed.ast.getValByPath(path);
            if (node.kind != .sequence) return error.NotASequence;
            try self.reorderSeqNode(parsed, node, indices);
        }

        // --- move / reorder internals ---

        /// Reorder a sequence node's items by `order` (bring-to-front indices),
        /// dispatching on flow vs block style.
        fn reorderSeqNode(self: *Self, parsed: Document, node: AST.Node, order: []const usize) !void {
            const source = self.source.items;
            var spans: std.ArrayList(Span) = .empty;
            defer spans.deinit(self.allocator);
            var maybe = try parsed.ast.child(&node);
            while (maybe) |item| {
                try spans.append(self.allocator, parsed.span(item));
                maybe = parsed.ast.next(&item);
            }
            if (spans.items.len == 0) return;
            if (isFlow(source, parsed.span(node))) {
                try self.reorderFlowItems(spans.items, order);
                return;
            }
            if (Language == Toml) return error.NotAnInlineArray;
            var blocks: std.ArrayList(Block) = .empty;
            defer blocks.deinit(self.allocator);
            for (spans.items) |s| {
                try blocks.append(self.allocator, .{ .start = entryBlockStart(source, s, comment_style), .end = 0 });
            }
            const last_end = entryBlockEnd(source, spans.items[spans.items.len - 1]);
            tileBlocks(blocks.items, last_end);
            try self.reorderBlocks(blocks.items[0].start, last_end, blocks.items, order);
        }

        /// Splice a block container's region so the entries indexed by `order`
        /// (in document order) come first, then the rest in original order.
        /// `blocks` must be in document order and tile `[region_start, region_end)`.
        fn reorderBlocks(self: *Self, region_start: usize, region_end: usize, blocks: []const Block, order: []const usize) !void {
            const perm = try fullOrder(self.allocator, order, blocks.len);
            defer self.allocator.free(perm);
            const source = self.source.items;
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);
            for (perm) |i| try appendBlockSep(&out, self.allocator, source[blocks[i].start..blocks[i].end]);
            try self.replaceAtSpan(Span.init(region_start, region_end), out.items);
        }

        /// Splice a flow sequence (`[a, b, …]`) so its items follow `order`,
        /// reusing each slot's original separator bytes so the comma/space
        /// framing is preserved while only the item contents move.
        fn reorderFlowItems(self: *Self, items: []const Span, order: []const usize) !void {
            const perm = try fullOrder(self.allocator, order, items.len);
            defer self.allocator.free(perm);
            const source = self.source.items;
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);
            for (perm, 0..) |src_idx, slot| {
                try out.appendSlice(self.allocator, source[items[src_idx].start..items[src_idx].end]);
                // Reuse the separator that originally sat after position `slot`.
                if (slot + 1 < perm.len) {
                    try out.appendSlice(self.allocator, source[items[slot].end..items[slot + 1].start]);
                }
            }
            try self.replaceAtSpan(Span.init(items[0].start, items[items.len - 1].end), out.items);
        }

        /// Move the block `[src_start, src_end)` so it begins at `dest_start`,
        /// preserving the bytes between source and destination. No-op when the
        /// destination falls within the source block.
        fn moveBlock(self: *Self, src_start: usize, src_end: usize, dest_start: usize) !void {
            if (dest_start >= src_start and dest_start <= src_end) return;
            const source = self.source.items;
            const moved = source[src_start..src_end];
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);
            if (src_end <= dest_start) {
                // src precedes dest: [src][between][dest..] -> [between][src][dest..]
                try appendBlockSep(&out, self.allocator, source[src_end..dest_start]);
                try appendBlockSep(&out, self.allocator, moved);
                try self.replaceAtSpan(Span.init(src_start, dest_start), out.items);
            } else {
                // dest precedes src: [dest..][between][src] -> [src][dest..][between]
                try appendBlockSep(&out, self.allocator, moved);
                try appendBlockSep(&out, self.allocator, source[dest_start..src_start]);
                try self.replaceAtSpan(Span.init(dest_start, src_end), out.items);
            }
        }

        // --- insert helpers (build text, then splice) ---

        fn insertBlockKey(self: *Self, parsed: Document, mapping: AST.Node, key_text: []const u8, value_text: []const u8) !void {
            const source = self.source.items;
            const last = (try parsed.ast.lastChild(&mapping)).?;
            const key_node = (try parsed.ast.firstChildKey(&mapping)).?;
            const col = columnOf(source, parsed.span(key_node).start);
            const insert_at = lineEndAfter(source, parsed.span(last).end -| 1);

            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);
            if (insert_at > 0 and source[insert_at - 1] != '\n') try out.append(self.allocator, '\n');
            try out.appendNTimes(self.allocator, ' ', col);
            try out.appendSlice(self.allocator, key_text);
            try self.writeMapValue(&out, col, value_text);
            try out.append(self.allocator, '\n');
            try self.replaceAtSpan(Span.init(insert_at, insert_at), out.items);
        }

        // --- TOML structural inserts ---
        //
        // TOML splits a logical table across `[header]`…dotted-key…lines, so an
        // insert must land where the new entry attaches to the *intended* table.
        // A scalar `key = value` is placed at the end of the table's own header
        // region — after its last direct (non-`[header]`) entry, before any
        // sub-table header opens — never after a sub-table, which would silently
        // reparent it. `key_text`/`value_text` are verbatim TOML literals.

        fn tomlInsertKey(self: *Self, parsed: Document, node: AST.Node, span: Span, is_root: bool, key_text: []const u8, value_text: []const u8) !void {
            if (node.kind != .mapping) return error.NotAMapping;
            const source = self.source.items;
            // Inline table `{ … }`: splice a `key = value` inside the braces.
            if (isFlow(source, span))
                return self.tomlInsertFlowEntry(parsed, node, span, key_text, value_text);

            // Block table: scan its direct children for the in-region ones (those
            // whose line does not start with `[` — i.e. scalars, arrays, inline
            // tables, and dotted sub-tables, all of which live under this table's
            // header). The last such child's line is where the new entry goes; its
            // column sets the indentation.
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
        fn tomlInsertFlowEntry(self: *Self, parsed: Document, node: AST.Node, span: Span, key_text: []const u8, value_text: []const u8) !void {
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

        /// Append a new `[[header]]` element to the array-of-tables at `path`,
        /// with `body_text` (verbatim TOML `key = value` lines, possibly empty) as
        /// its contents. The element is spliced after the AoT's current last
        /// element — past every line of that element's subtree, so a nested
        /// sub-table inside it is not split. TOML-only.
        pub fn appendTableToArray(self: *Self, path: []const AST.PathSegment, body_text: []const u8) !void {
            if (Language != Toml) @compileError("appendTableToArray is TOML-only");
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

        /// Append `: value` for a mapping entry whose key is already written at
        /// column `col`. Scalars and block scalars stay inline (`key: value`);
        /// a multi-line block collection goes on the following lines, indented
        /// (a nested mapping at `col + 2`, an indentless sequence at `col`).
        fn writeMapValue(self: *Self, out: *std.ArrayList(u8), col: usize, value_text: []const u8) !void {
            const v = stripTrailingNewline(value_text);
            const nl = std.mem.indexOfScalar(u8, v, '\n');
            const first_line = std.mem.trimStart(u8, if (nl) |i| v[0..i] else v, " ");
            const is_block_scalar = first_line.len > 0 and (first_line[0] == '|' or first_line[0] == '>');
            // A block sequence is recognizable even on a single line (`- a`); it
            // must still descend, since `key: - a` is invalid. A scalar value
            // (no line break, not a sequence dash) stays inline. (A serialized
            // scalar that would read as a dash is quoted, so this is safe.)
            const is_seq = std.mem.startsWith(u8, first_line, "- ") or std.mem.eql(u8, first_line, "-");
            if (is_block_scalar or (nl == null and !is_seq)) {
                try out.appendSlice(self.allocator, ": ");
                try reindentInto(out, self.allocator, v, col);
                return;
            }
            // Block collection value: descend onto the next lines.
            const child_col = if (is_seq) col else col + 2;
            try out.append(self.allocator, ':');
            var it = std.mem.splitScalar(u8, v, '\n');
            while (it.next()) |line| {
                try out.append(self.allocator, '\n');
                if (line.len > 0) try out.appendNTimes(self.allocator, ' ', child_col);
                try out.appendSlice(self.allocator, line);
            }
        }

        fn insertSeqLine(self: *Self, insert_at: usize, dash_col: usize, value_text: []const u8) !void {
            const source = self.source.items;
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);
            if (insert_at > 0 and source[insert_at - 1] != '\n') try out.append(self.allocator, '\n');
            try out.appendNTimes(self.allocator, ' ', dash_col);
            try out.appendSlice(self.allocator, "- ");
            try reindentInto(&out, self.allocator, value_text, dash_col + 2);
            try out.append(self.allocator, '\n');
            try self.replaceAtSpan(Span.init(insert_at, insert_at), out.items);
        }

        fn promoteNullToMapping(self: *Self, null_span: Span, is_root: bool, key_text: []const u8, value_text: []const u8) !void {
            const source = self.source.items;
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);
            if (is_root) {
                // Empty document: the whole source becomes a single entry.
                try out.appendSlice(self.allocator, key_text);
                try out.appendSlice(self.allocator, ": ");
                try reindentInto(&out, self.allocator, value_text, 0);
                try out.append(self.allocator, '\n');
                try self.replaceAtSpan(Span.init(0, source.len), out.items);
                return;
            }
            const line_start = lineStartBefore(source, null_span.start);
            const key_col = firstNonSpace(source, line_start) - line_start;
            const child_col = key_col + 2;
            try out.append(self.allocator, '\n');
            try out.appendNTimes(self.allocator, ' ', child_col);
            try out.appendSlice(self.allocator, key_text);
            try out.appendSlice(self.allocator, ": ");
            try reindentInto(&out, self.allocator, value_text, child_col);
            try self.replaceAtSpan(null_span, out.items);
        }

        fn insertFlowEntry(self: *Self, span: Span, non_empty: bool, key_text: []const u8, value_text: []const u8) !void {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);
            const at = if (non_empty) blk: {
                try out.appendSlice(self.allocator, ", ");
                break :blk span.end - 1; // before the closing '}'
            } else span.start + 1; // just after '{'
            try out.appendSlice(self.allocator, key_text);
            try out.appendSlice(self.allocator, ": ");
            try out.appendSlice(self.allocator, value_text);
            try self.replaceAtSpan(Span.init(at, at), out.items);
        }

        fn insertFlowItem(self: *Self, span: Span, non_empty: bool, value_text: []const u8) !void {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);
            const at = if (non_empty) blk: {
                try out.appendSlice(self.allocator, ", ");
                break :blk span.end - 1; // before the closing ']'
            } else span.start + 1; // just after '['
            try out.appendSlice(self.allocator, value_text);
            try self.replaceAtSpan(Span.init(at, at), out.items);
        }

        fn prependFlowItem(self: *Self, span: Span, non_empty: bool, value_text: []const u8) !void {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);
            try out.appendSlice(self.allocator, value_text);
            if (non_empty) try out.appendSlice(self.allocator, ", ");
            const at = span.start + 1; // just after '['
            try self.replaceAtSpan(Span.init(at, at), out.items);
        }

        fn removeFlowItem(self: *Self, item_span: Span, is_first: bool) !void {
            const source = self.source.items;
            if (is_first) {
                // Drop the item and a following ", " if present.
                var e = item_span.end;
                while (e < source.len and (source[e] == ' ' or source[e] == '\t')) e += 1;
                if (e < source.len and source[e] == ',') {
                    e += 1;
                    while (e < source.len and (source[e] == ' ' or source[e] == '\t')) e += 1;
                }
                try self.replaceAtSpan(Span.init(item_span.start, e), "");
            } else {
                // Drop a preceding ", " and the item.
                var s = item_span.start;
                while (s > 0 and (source[s - 1] == ' ' or source[s - 1] == '\t')) s -= 1;
                if (s > 0 and source[s - 1] == ',') {
                    s -= 1;
                    while (s > 0 and (source[s - 1] == ' ' or source[s - 1] == '\t')) s -= 1;
                }
                try self.replaceAtSpan(Span.init(s, item_span.end), "");
            }
        }

        /// Replace a span of bytes with a new span of bytes.
        /// Not aware of self.format. Invalidates self.parsed until reparsed.
        fn replaceSource(self: *Self, old_span: Span, text: []const u8) !void {
            if (old_span.end < old_span.start or old_span.end > self.source.items.len) {
                return error.InvalidSpan;
            }
            try self.source.replaceRange(self.allocator, old_span.start, old_span.len(), text);
        }

        /// After an edit, restores self.parsed so node spans are valid again.
        fn reparse(self: *Self) !void {
            const parsed = try self.parseSource();
            self.freeDocument();
            self.document = parsed;
        }

        fn parseSource(self: *Self) !Document {
            var parser: Language.Parser = .{ .allocator = self.allocator };
            return Language.parse(&parser, self.source.items, self.format);
        }

        fn freeDocument(self: *Self) void {
            if (self.document) |parsed| {
                parsed.deinit(self.allocator);
                self.document = null;
            }
        }

        pub fn deinit(self: *Self) void {
            self.freeDocument();
            self.source.deinit(self.allocator);
        }
    };
}

// ======================
// SOURCE-COORDINATE UTILS
// ======================
//
// Editing reframes splice text against the raw source, because indentation,
// trailing newlines, and comments live *outside* any AST node span (node spans
// are tight: they exclude leading indent and, except for block scalars, the
// trailing newline; comments are not represented in the AST at all).

/// Byte index of the start of the line containing `at` (just past the previous
/// '\n', or 0).
fn lineStartBefore(source: []const u8, at: usize) usize {
    var i = at;
    while (i > 0) : (i -= 1) {
        if (source[i - 1] == '\n') return i;
    }
    return 0;
}

/// Byte index just past the next '\n' at or after `at`, or `source.len`.
fn lineEndAfter(source: []const u8, at: usize) usize {
    if (std.mem.indexOfScalarPos(u8, source, at, '\n')) |nl| return nl + 1;
    return source.len;
}

/// Index of the first non-space/non-tab byte at or after `from`.
fn firstNonSpace(source: []const u8, from: usize) usize {
    var i = from;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
    return i;
}

/// Column (0-based) of the byte at `at` within its line.
fn columnOf(source: []const u8, at: usize) usize {
    return at - lineStartBefore(source, at);
}

/// Column of the `-` introducing the sequence item whose content begins at
/// `item_content_start`. The item's node span starts *after* the dash, so we
/// recover the dash from the first non-space byte on the item's line.
fn dashColumn(source: []const u8, item_content_start: usize) usize {
    const line_start = lineStartBefore(source, item_content_start);
    return firstNonSpace(source, line_start) - line_start;
}

/// Whether the container at `span` is written in flow style (`{...}`/`[...]`).
/// The AST records no flow/block flag, so we sniff the first content byte.
fn isFlow(source: []const u8, span: Span) bool {
    const i = firstNonSpace(source, span.start);
    return i < source.len and (source[i] == '{' or source[i] == '[');
}

/// Comment syntax for the owned-comment scan: `#` line comments (YAML/TOML) vs
/// `//` line comments and `/* */` blocks (JSON5/JSONC).
const CommentStyle = enum { hash, slashes };

/// Grow `line_start` upward to absorb an entry's owned comment block: the
/// contiguous run of comment lines immediately above, with no intervening blank
/// line (trivia policy "comment-above-belongs-to-key"). A blank line or any
/// non-comment content stops the scan. With `.slashes`, multi-line `/* ... */`
/// blocks are walked as a unit so a delete/move carries the whole block, not
/// just its closing line.
fn commentBlockStart(source: []const u8, line_start: usize, style: CommentStyle) usize {
    var ls = line_start;
    // `.slashes` only: set while scanning upward through the interior of a
    // `/* ... */` block whose opener `/*` has not been reached yet.
    var in_block = false;
    while (ls > 0) {
        const prev_start = lineStartBefore(source, ls - 1);
        const line = source[prev_start..ls];
        const trimmed = std.mem.trimStart(u8, std.mem.trimEnd(u8, line, "\r\n"), " \t");
        const is_comment = switch (style) {
            .hash => trimmed.len > 0 and trimmed[0] == '#',
            .slashes => blk: {
                if (in_block) {
                    // Inside a block comment, moving up: every line belongs to it
                    // until we reach the line bearing the `/*` opener.
                    if (std.mem.indexOf(u8, trimmed, "/*") != null) in_block = false;
                    break :blk true;
                }
                if (std.mem.startsWith(u8, trimmed, "//")) break :blk true;
                // A line ending a `/* */` block: enter block-scan mode unless it is
                // a self-contained single-line `/* ... */`.
                if (std.mem.endsWith(u8, trimmed, "*/")) {
                    if (!std.mem.startsWith(u8, trimmed, "/*")) in_block = true;
                    break :blk true;
                }
                break :blk false;
            },
        };
        if (is_comment) {
            ls = prev_start;
        } else break;
    }
    return ls;
}

/// Start of a mapping entry's full block: its owned leading comment block
/// (`commentBlockStart`) at the start of the key's line. Mirrors the span math
/// `deleteKey` uses, factored out for move/reorder.
fn entryBlockStart(source: []const u8, kv_span: Span, style: CommentStyle) usize {
    return commentBlockStart(source, lineStartBefore(source, kv_span.start), style);
}

/// End of a mapping entry's full block: just past the newline ending its last
/// line (or `source.len` when the final line is unterminated).
fn entryBlockEnd(source: []const u8, kv_span: Span) usize {
    return lineEndAfter(source, kv_span.end -| 1);
}

/// Append a relocated entry `block` to `out`, guaranteeing a single '\n'
/// separator from whatever precedes it. The block's own bytes are appended
/// verbatim (its trailing newline, if any, is preserved), so concatenating
/// blocks in a new order never welds two entries onto one line.
fn appendBlockSep(out: *std.ArrayList(u8), allocator: std.mem.Allocator, block: []const u8) !void {
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
        try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, block);
}

/// A relocatable entry block: a byte range `[start, end)` covering one mapping
/// entry or sequence item (its owned comment block through its last line).
const Block = struct { start: usize, end: usize };

/// Fill each block's `end` from the next block's `start` so the blocks tile a
/// contiguous region; the final block runs to `last_end`. Trailing trivia (a
/// blank line, an orphan comment) thus rides with the preceding entry.
fn tileBlocks(blocks: []Block, last_end: usize) void {
    for (blocks, 0..) |*b, i| {
        b.end = if (i + 1 < blocks.len) blocks[i + 1].start else last_end;
    }
}

/// Build a full permutation of `0..n`: the valid, de-duplicated indices in
/// `order` first (in the given order), then every remaining index in ascending
/// (original) order. Caller owns the returned slice. An empty `order` yields
/// the identity, so a reorder with nothing to bring forward is a no-op.
fn fullOrder(allocator: std.mem.Allocator, order: []const usize, n: usize) ![]usize {
    const result = try allocator.alloc(usize, n);
    errdefer allocator.free(result);
    const used = try allocator.alloc(bool, n);
    defer allocator.free(used);
    @memset(used, false);
    var k: usize = 0;
    for (order) |idx| {
        if (idx < n and !used[idx]) {
            result[k] = idx;
            used[idx] = true;
            k += 1;
        }
    }
    for (0..n) |i| {
        if (!used[i]) {
            result[k] = i;
            k += 1;
        }
    }
    return result;
}

/// Count the children of a container node.
fn seqLen(parsed: Document, node: AST.Node) !usize {
    var n: usize = 0;
    var maybe = try parsed.ast.child(&node);
    while (maybe) |c| {
        n += 1;
        maybe = parsed.ast.next(&c);
    }
    return n;
}

/// Drop a single trailing '\n' (the serializer ends every value with one).
fn stripTrailingNewline(text: []const u8) []const u8 {
    if (text.len > 0 and text[text.len - 1] == '\n') return text[0 .. text.len - 1];
    return text;
}

/// Append `value_text` to `out`, re-indented so it sits at column `indent`.
/// The first line is emitted verbatim (it follows `key: ` or `- `); every
/// subsequent non-blank line is prefixed with `indent` spaces, preserving the
/// serializer's own relative indentation. One trailing '\n' is stripped.
fn reindentInto(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value_text: []const u8, indent: usize) !void {
    const text = stripTrailingNewline(value_text);
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) {
            try out.append(allocator, '\n');
            if (line.len > 0) try out.appendNTimes(allocator, ' ', indent);
        }
        try out.appendSlice(allocator, line);
        first = false;
    }
}

// --- TOML structural helpers ---

/// Largest source `end` over the subtree rooted at `id` — the textual end of an
/// AoT element including any nested `[header]`/`[[header]]` sub-tables (whose own
/// node spans point at their header key, with their body following). Used to
/// find where a new `[[…]]` element can be spliced without splitting the prior
/// element's contents.
fn subtreeMaxEnd(parsed: Document, id: AST.Node.Id) usize {
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

/// Render a TOML header path (`a.b.c`) from a PathSegment list into `out`. Index
/// segments are skipped — `[[a.b]]` always targets `a`'s last element, so the
/// index is implied. Each key prints bare when it is all `[A-Za-z0-9_-]`, else as
/// a basic-quoted string.
fn appendTomlHeaderPath(out: *std.ArrayList(u8), allocator: std.mem.Allocator, path: []const AST.PathSegment) !void {
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

fn isTomlBareKey(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

// =======
// TESTING
// =======

fn testEditor(input: []const u8, path: []const AST.PathSegment, key_or_val: enum { key, val }, text: []const u8, expected: []const u8) !void {
    var editor: Editor(json.Language) = .{ .allocator = std.testing.allocator };
    try editor.init(input);
    defer editor.deinit();
    switch (key_or_val) {
        .key => try editor.replaceKeyAtPath(path, text),
        .val => try editor.replaceValAtPath(path, text),
    }
    const actual = editor.source.items;
    errdefer log.err("actual: {s}", .{actual});
    errdefer log.err("expected: {s}", .{expected});
    try std.testing.expect(std.mem.eql(u8, expected, actual));
}

test "simple value edit" {
    try testEditor(
        "[{\"hello\":\"world\"}]",
        &[_]AST.PathSegment{ .{ .index = 0 }, .{ .key = "hello" } },
        .val,
        "\"person!\"",
        "[{\"hello\":\"person!\"}]",
    );
}

test "simple key edit" {
    try testEditor("[{\"hello\":\"world\"}]", &[_]AST.PathSegment{ .{ .index = 0 }, .{ .key = "hello" } }, .key, "\"greetings\"", "[{\"greetings\":\"world\"}]");
}

// --- JSON5 editing ---
//
// JSON5 is a dialect of the JSON language, so it routes through the same generic
// editor. The editor splices source bytes in place (it never reprints), so every
// JSON5-ism outside the edited span — unquoted keys, trailing commas, single
// quotes, `//` and `/* */` comments — survives byte-for-byte. The owned-comment
// scan on delete is `//`/`/* */`-aware so a deleted key carries its own comment.

fn newJson5Editor(input: []const u8) !Editor(json.Language) {
    var ed: Editor(json.Language) = .{ .allocator = std.testing.allocator, .format = .JSON5 };
    try ed.init(input);
    return ed;
}

fn expectJson5Source(ed: *const Editor(json.Language), expected: []const u8) !void {
    errdefer log.err("actual:   \"{s}\"", .{ed.source.items});
    errdefer log.err("expected: \"{s}\"", .{expected});
    try std.testing.expectEqualStrings(expected, ed.source.items);
}

test "json5 value edit preserves unquoted keys, comments, trailing comma" {
    var ed = try newJson5Editor(
        \\{
        \\  // server config
        \\  host: 'localhost',
        \\  port: 8080, // default
        \\}
    );
    defer ed.deinit();
    try ed.replaceValAtPath(&.{.{ .key = "port" }}, "9090");
    try expectJson5Source(&ed,
        \\{
        \\  // server config
        \\  host: 'localhost',
        \\  port: 9090, // default
        \\}
    );
}

test "json5 key rename keeps it unquoted" {
    var ed = try newJson5Editor("{ host: 'localhost', port: 8080 }");
    defer ed.deinit();
    try ed.replaceKeyAtPath(&.{.{ .key = "port" }}, "listen");
    try expectJson5Source(&ed, "{ host: 'localhost', listen: 8080 }");
}

test "json5 delete key carries its owned // comment" {
    var ed = try newJson5Editor(
        \\{
        \\  host: 'localhost',
        \\  // the listening port
        \\  port: 8080,
        \\}
    );
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "port" }});
    try expectJson5Source(&ed,
        \\{
        \\  host: 'localhost',
        \\}
    );
}

test "json5 delete key carries an owned /* */ block comment" {
    var ed = try newJson5Editor(
        \\{
        \\  host: 'localhost',
        \\  /* the listening
        \\     port number */
        \\  port: 8080,
        \\}
    );
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "port" }});
    try expectJson5Source(&ed,
        \\{
        \\  host: 'localhost',
        \\}
    );
}

test "json5 delete leaves an unrelated earlier comment intact" {
    var ed = try newJson5Editor(
        \\{
        \\  // host comment
        \\  host: 'localhost',
        \\  port: 8080,
        \\}
    );
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "port" }});
    try expectJson5Source(&ed,
        \\{
        \\  // host comment
        \\  host: 'localhost',
        \\}
    );
}

// --- TOML value/key replacement (point edits on contiguous spans) ---
//
// TOML structural editing (insert/delete/move into scattered tables) is not
// supported, but replacing an existing value or renaming a key is: those nodes
// have tight, contiguous spans even when the owning table is assembled from
// scattered headers. The generic span-splice-reparse editor handles them with
// no TOML-specific logic; the replacement text is a verbatim TOML literal.

const Toml = @import("toml/toml.zig").Language;

fn newTomlEditor(input: []const u8) !Editor(Toml) {
    var ed: Editor(Toml) = .{ .allocator = std.testing.allocator };
    try ed.init(input);
    return ed;
}

fn expectTomlSource(ed: *const Editor(Toml), expected: []const u8) !void {
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

const Yaml = @import("yaml/yaml.zig").Language;

fn newYamlEditor(input: []const u8) !Editor(Yaml) {
    var ed: Editor(Yaml) = .{ .allocator = std.testing.allocator };
    try ed.init(input);
    return ed;
}

fn expectSource(ed: *const Editor(Yaml), expected: []const u8) !void {
    errdefer log.err("actual:   \"{s}\"", .{ed.source.items});
    errdefer log.err("expected: \"{s}\"", .{expected});
    try std.testing.expectEqualStrings(expected, ed.source.items);
}

// --- reference layer: COW + opt-in follow ---

test "yaml edit through alias is copy-on-write (severs only that alias)" {
    var ed = try newYamlEditor("a: &x 1\nb: *x\n");
    defer ed.deinit();
    try ed.replaceValAtPath(&.{.{ .key = "b" }}, "5");
    try expectSource(&ed, "a: &x 1\nb: 5\n"); // anchor + value of `a` untouched
}

test "yaml follow-mode edits the anchored value, keeping the anchor" {
    var ed = try newYamlEditor("a: &x 1\nb: *x\n");
    defer ed.deinit();
    try ed.replaceValAtPathFollowing(&.{.{ .key = "b" }}, "5");
    try expectSource(&ed, "a: &x 5\nb: *x\n"); // shared source changed; alias intact
}

test "yaml COW materializes a merge-only key locally" {
    var ed = try newYamlEditor("base: &b\n  x: 1\nd:\n  <<: *b\n  y: 2\n");
    defer ed.deinit();
    try ed.replaceValAtPath(&.{ .{ .key = "d" }, .{ .key = "x" } }, "5");
    try expectSource(&ed, "base: &b\n  x: 1\nd:\n  <<: *b\n  y: 2\n  x: 5\n");
}

test "yaml deleting a merge-only key is refused" {
    var ed = try newYamlEditor("base: &b\n  x: 1\nd:\n  <<: *b\n  y: 2\n");
    defer ed.deinit();
    try std.testing.expectError(error.MergeOnlyKey, ed.deleteKey(&.{ .{ .key = "d" }, .{ .key = "x" } }));
}

// --- insert key, block ---

test "yaml insert key block" {
    var ed = try newYamlEditor("a: 1\nb: 2\n");
    defer ed.deinit();
    try ed.insertKey(&.{}, "c", "3");
    try expectSource(&ed, "a: 1\nb: 2\nc: 3\n");
}

test "yaml insert key no trailing newline" {
    var ed = try newYamlEditor("a: 1\nb: 2");
    defer ed.deinit();
    try ed.insertKey(&.{}, "c", "3");
    try expectSource(&ed, "a: 1\nb: 2\nc: 3\n");
}

test "yaml insert key nested column inheritance" {
    var ed = try newYamlEditor("root:\n  x: 1\n");
    defer ed.deinit();
    try ed.insertKey(&.{.{ .key = "root" }}, "y", "2");
    try expectSource(&ed, "root:\n  x: 1\n  y: 2\n");
}

test "yaml insert key multiline block scalar" {
    var ed = try newYamlEditor("a: 1\n");
    defer ed.deinit();
    try ed.insertKey(&.{}, "desc", "|\n  line one\n  line two\n");
    try expectSource(&ed, "a: 1\ndesc: |\n  line one\n  line two\n");
}

// --- insert key, flow / empty ---

test "yaml insert key empty flow map" {
    var ed = try newYamlEditor("env: {}\n");
    defer ed.deinit();
    try ed.insertKey(&.{.{ .key = "env" }}, "X", "1");
    try expectSource(&ed, "env: {X: 1}\n");
}

test "yaml insert key nonempty flow map" {
    var ed = try newYamlEditor("env: {a: 1}\n");
    defer ed.deinit();
    try ed.insertKey(&.{.{ .key = "env" }}, "b", "2");
    try expectSource(&ed, "env: {a: 1, b: 2}\n");
}

test "yaml insert key promotes null value" {
    var ed = try newYamlEditor("k:\n");
    defer ed.deinit();
    try ed.insertKey(&.{.{ .key = "k" }}, "n", "1");
    try expectSource(&ed, "k:\n  n: 1\n");
}

test "yaml insert key with nested mapping value" {
    var ed = try newYamlEditor("a: 1\n");
    defer ed.deinit();
    try ed.insertKey(&.{}, "meta", "x: 1\ny: 2\n");
    try expectSource(&ed, "a: 1\nmeta:\n  x: 1\n  y: 2\n");
}

test "yaml insert key with indentless sequence value" {
    var ed = try newYamlEditor("a: 1\n");
    defer ed.deinit();
    try ed.insertKey(&.{}, "tags", "- x\n- y\n");
    try expectSource(&ed, "a: 1\ntags:\n- x\n- y\n");
}

// --- delete key + trivia ---

test "yaml delete middle key" {
    var ed = try newYamlEditor("a: 1\nb: 2\nc: 3\n");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "b" }});
    try expectSource(&ed, "a: 1\nc: 3\n");
}

test "yaml delete key with owned comment" {
    var ed = try newYamlEditor("a: 1\n# note\nb: 2\nc: 3\n");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "b" }});
    try expectSource(&ed, "a: 1\nc: 3\n");
}

test "yaml delete key preserves comment across blank line" {
    var ed = try newYamlEditor("a: 1\n# orphan\n\nb: 2\n");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "b" }});
    try expectSource(&ed, "a: 1\n# orphan\n\n");
}

test "yaml delete key with multiline comment block" {
    var ed = try newYamlEditor("# l1\n# l2\nb: 2\nc: 3\n");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "b" }});
    try expectSource(&ed, "c: 3\n");
}

test "yaml delete last key" {
    var ed = try newYamlEditor("a: 1\nb: 2\n");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "b" }});
    try expectSource(&ed, "a: 1\n");
}

test "yaml delete sole key" {
    var ed = try newYamlEditor("a: 1\n");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "a" }});
    try expectSource(&ed, "");
}

test "yaml delete key trailing same-line comment" {
    var ed = try newYamlEditor("a: 1\nb: 2 # gone\nc: 3\n");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "b" }});
    try expectSource(&ed, "a: 1\nc: 3\n");
}

test "yaml delete key with block scalar value" {
    var ed = try newYamlEditor("a: |\n  x\n  y\nb: 2\n");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "a" }});
    try expectSource(&ed, "b: 2\n");
}

// --- sequences ---

test "yaml append block seq" {
    var ed = try newYamlEditor("- a\n- b\n");
    defer ed.deinit();
    try ed.appendToSeq(&.{}, "c");
    try expectSource(&ed, "- a\n- b\n- c\n");
}

test "yaml append indentless seq" {
    var ed = try newYamlEditor("one:\n- 2\n- 3\n");
    defer ed.deinit();
    try ed.appendToSeq(&.{.{ .key = "one" }}, "4");
    try expectSource(&ed, "one:\n- 2\n- 3\n- 4\n");
}

test "yaml append indented nested seq" {
    var ed = try newYamlEditor("k:\n  - a\n  - b\n");
    defer ed.deinit();
    try ed.appendToSeq(&.{.{ .key = "k" }}, "c");
    try expectSource(&ed, "k:\n  - a\n  - b\n  - c\n");
}

test "yaml prepend block seq" {
    var ed = try newYamlEditor("- a\n- b\n");
    defer ed.deinit();
    try ed.prependToSeq(&.{}, "z");
    try expectSource(&ed, "- z\n- a\n- b\n");
}

test "yaml append flow seq" {
    var ed = try newYamlEditor("t: [a, b]\n");
    defer ed.deinit();
    try ed.appendToSeq(&.{.{ .key = "t" }}, "c");
    try expectSource(&ed, "t: [a, b, c]\n");
}

test "yaml append empty flow seq" {
    var ed = try newYamlEditor("t: []\n");
    defer ed.deinit();
    try ed.appendToSeq(&.{.{ .key = "t" }}, "a");
    try expectSource(&ed, "t: [a]\n");
}

test "yaml remove block seq middle" {
    var ed = try newYamlEditor("- a\n- b\n- c\n");
    defer ed.deinit();
    try ed.removeSeqItem(&.{}, 1);
    try expectSource(&ed, "- a\n- c\n");
}

test "yaml remove flow seq middle" {
    var ed = try newYamlEditor("t: [a, b, c]\n");
    defer ed.deinit();
    try ed.removeSeqItem(&.{.{ .key = "t" }}, 1);
    try expectSource(&ed, "t: [a, c]\n");
}

test "yaml remove flow seq first" {
    var ed = try newYamlEditor("t: [a, b]\n");
    defer ed.deinit();
    try ed.removeSeqItem(&.{.{ .key = "t" }}, 0);
    try expectSource(&ed, "t: [b]\n");
}

// --- atomicity ---

test "yaml failed edit rolls back source and keeps editor usable" {
    var ed = try newYamlEditor("a: 1\nb: 2\n");
    defer ed.deinit();

    // Splice an unterminated flow sequence as a's value: the reparse fails
    // (the specific error is the parser's concern; we only require failure).
    if (ed.replaceValAtPath(&.{.{ .key = "a" }}, "[oops")) |_| {
        return error.TestExpectedFailedEdit;
    } else |_| {}
    // Source is byte-identical to before the failed edit...
    try expectSource(&ed, "a: 1\nb: 2\n");
    // ...and the document still matches it, so a later valid edit works.
    try ed.replaceValAtPath(&.{.{ .key = "a" }}, "9");
    try expectSource(&ed, "a: 9\nb: 2\n");
}

// --- value reframing on replace (inline <-> block) ---

test "yaml replace inline empty seq with a block list" {
    var ed = try newYamlEditor("t: []\n");
    defer ed.deinit();
    try ed.replaceValAtPath(&.{.{ .key = "t" }}, "- a\n- b");
    try expectSource(&ed, "t:\n- a\n- b\n");
}

test "yaml replace block list with an inline empty seq" {
    var ed = try newYamlEditor("t:\n- a\n- b\n");
    defer ed.deinit();
    try ed.replaceValAtPath(&.{.{ .key = "t" }}, "[]");
    try expectSource(&ed, "t: []\n");
}

test "yaml replace scalar with a single-item block list" {
    var ed = try newYamlEditor("k: old\n");
    defer ed.deinit();
    try ed.replaceValAtPath(&.{.{ .key = "k" }}, "- a");
    try expectSource(&ed, "k:\n- a\n");
}

test "yaml replace null value with a block list" {
    var ed = try newYamlEditor("k:\n");
    defer ed.deinit();
    try ed.replaceValAtPath(&.{.{ .key = "k" }}, "- a");
    try expectSource(&ed, "k:\n- a\n");
}

test "yaml replace scalar with a nested mapping" {
    var ed = try newYamlEditor("m: x\n");
    defer ed.deinit();
    try ed.replaceValAtPath(&.{.{ .key = "m" }}, "a: 1\nb: 2");
    try expectSource(&ed, "m:\n  a: 1\n  b: 2\n");
}

test "yaml replace scalar with scalar keeps it inline" {
    var ed = try newYamlEditor("title: Hello\n");
    defer ed.deinit();
    try ed.replaceValAtPath(&.{.{ .key = "title" }}, "Hi");
    try expectSource(&ed, "title: Hi\n");
}

test "yaml replace preserves a trailing line comment" {
    var ed = try newYamlEditor("title: Hello # note\n");
    defer ed.deinit();
    try ed.replaceValAtPath(&.{.{ .key = "title" }}, "Hi");
    try expectSource(&ed, "title: Hi # note\n");
}

test "yaml reframe a nested mapping value" {
    var ed = try newYamlEditor("root:\n  c: []\n");
    defer ed.deinit();
    try ed.replaceValAtPath(&.{ .{ .key = "root" }, .{ .key = "c" } }, "- x");
    try expectSource(&ed, "root:\n  c:\n  - x\n");
}

// --- move key ---

test "yaml move key forward (src before dest)" {
    var ed = try newYamlEditor("a: 1\nb: 2\nc: 3\n");
    defer ed.deinit();
    // Move a to before c: a lands between b and c.
    try ed.moveKey(&.{.{ .key = "a" }}, &.{.{ .key = "c" }});
    try expectSource(&ed, "b: 2\na: 1\nc: 3\n");
}

test "yaml move key backward (dest before src)" {
    var ed = try newYamlEditor("a: 1\nb: 2\nc: 3\n");
    defer ed.deinit();
    // Move c to before a.
    try ed.moveKey(&.{.{ .key = "c" }}, &.{.{ .key = "a" }});
    try expectSource(&ed, "c: 3\na: 1\nb: 2\n");
}

test "yaml move key carries owned comment" {
    var ed = try newYamlEditor("a: 1\n# note for c\nc: 3\nb: 2\n");
    defer ed.deinit();
    try ed.moveKey(&.{.{ .key = "c" }}, &.{.{ .key = "a" }});
    try expectSource(&ed, "# note for c\nc: 3\na: 1\nb: 2\n");
}

test "yaml move key carries trailing same-line comment" {
    var ed = try newYamlEditor("a: 1\nb: 2 # keep\nc: 3\n");
    defer ed.deinit();
    try ed.moveKey(&.{.{ .key = "b" }}, &.{.{ .key = "a" }});
    try expectSource(&ed, "b: 2 # keep\na: 1\nc: 3\n");
}

test "yaml move key with block scalar value" {
    var ed = try newYamlEditor("a: |\n  x\n  y\nb: 2\n");
    defer ed.deinit();
    try ed.moveKey(&.{.{ .key = "b" }}, &.{.{ .key = "a" }});
    try expectSource(&ed, "b: 2\na: |\n  x\n  y\n");
}

test "yaml move key to itself is a no-op" {
    var ed = try newYamlEditor("a: 1\nb: 2\n");
    defer ed.deinit();
    try ed.moveKey(&.{.{ .key = "a" }}, &.{.{ .key = "a" }});
    try expectSource(&ed, "a: 1\nb: 2\n");
}

// --- reorder keys ---

test "yaml reorder keys full order" {
    var ed = try newYamlEditor("a: 1\nb: 2\nc: 3\n");
    defer ed.deinit();
    try ed.reorderKeys(&.{}, &.{ "c", "a", "b" });
    try expectSource(&ed, "c: 3\na: 1\nb: 2\n");
}

test "yaml reorder keys partial appends rest in original order" {
    var ed = try newYamlEditor("a: 1\nb: 2\nc: 3\nd: 4\n");
    defer ed.deinit();
    // Only c, a listed; b and d keep their original relative order after.
    try ed.reorderKeys(&.{}, &.{ "c", "a" });
    try expectSource(&ed, "c: 3\na: 1\nb: 2\nd: 4\n");
}

test "yaml reorder keys preserves owned comments" {
    var ed = try newYamlEditor("# about a\na: 1\nb: 2\n# about c\nc: 3\n");
    defer ed.deinit();
    try ed.reorderKeys(&.{}, &.{ "c", "b", "a" });
    try expectSource(&ed, "# about c\nc: 3\nb: 2\n# about a\na: 1\n");
}

test "yaml reorder keys preserves interleaved blank line with preceding entry" {
    var ed = try newYamlEditor("a: 1\n\nb: 2\nc: 3\n");
    defer ed.deinit();
    // The blank line rides with a (its preceding entry).
    try ed.reorderKeys(&.{}, &.{ "c", "a", "b" });
    try expectSource(&ed, "c: 3\na: 1\n\nb: 2\n");
}

test "yaml reorder keys unknown key ignored" {
    var ed = try newYamlEditor("a: 1\nb: 2\n");
    defer ed.deinit();
    try ed.reorderKeys(&.{}, &.{ "z", "b", "a" });
    try expectSource(&ed, "b: 2\na: 1\n");
}

test "yaml reorder keys no-op when order matches" {
    var ed = try newYamlEditor("a: 1\nb: 2\nc: 3\n");
    defer ed.deinit();
    try ed.reorderKeys(&.{}, &.{ "a", "b", "c" });
    try expectSource(&ed, "a: 1\nb: 2\nc: 3\n");
}

test "yaml reorder keys empty list keeps original order" {
    var ed = try newYamlEditor("a: 1\nb: 2\n");
    defer ed.deinit();
    try ed.reorderKeys(&.{}, &.{});
    try expectSource(&ed, "a: 1\nb: 2\n");
}

test "yaml reorder keys nested mapping" {
    var ed = try newYamlEditor("root:\n  x: 1\n  y: 2\n  z: 3\n");
    defer ed.deinit();
    try ed.reorderKeys(&.{.{ .key = "root" }}, &.{ "z", "x" });
    try expectSource(&ed, "root:\n  z: 3\n  x: 1\n  y: 2\n");
}

test "yaml reorder keys with block scalar entry" {
    var ed = try newYamlEditor("a: 1\nbody: |\n  line one\n  line two\nb: 2\n");
    defer ed.deinit();
    try ed.reorderKeys(&.{}, &.{ "body", "b", "a" });
    try expectSource(&ed, "body: |\n  line one\n  line two\nb: 2\na: 1\n");
}

// --- move sequence item ---

test "yaml move item block forward" {
    var ed = try newYamlEditor("- a\n- b\n- c\n");
    defer ed.deinit();
    // Move item 0 (a) to index 2: remove a, reinsert -> b, c, a.
    try ed.moveItem(&.{}, 0, 2);
    try expectSource(&ed, "- b\n- c\n- a\n");
}

test "yaml move item block backward" {
    var ed = try newYamlEditor("- a\n- b\n- c\n");
    defer ed.deinit();
    try ed.moveItem(&.{}, 2, 0);
    try expectSource(&ed, "- c\n- a\n- b\n");
}

test "yaml move item carries owned comment" {
    var ed = try newYamlEditor("- a\n# note for c\n- c\n- b\n");
    defer ed.deinit();
    // Items: a(0), c(1), b(2). Move c to the front.
    try ed.moveItem(&.{}, 1, 0);
    try expectSource(&ed, "# note for c\n- c\n- a\n- b\n");
}

test "yaml move item to itself is a no-op" {
    var ed = try newYamlEditor("- a\n- b\n");
    defer ed.deinit();
    try ed.moveItem(&.{}, 1, 1);
    try expectSource(&ed, "- a\n- b\n");
}

test "yaml move flow item" {
    var ed = try newYamlEditor("t: [a, b, c]\n");
    defer ed.deinit();
    try ed.moveItem(&.{.{ .key = "t" }}, 0, 2);
    try expectSource(&ed, "t: [b, c, a]\n");
}

// --- reorder sequence items ---

test "yaml reorder items block partial" {
    var ed = try newYamlEditor("- a\n- b\n- c\n");
    defer ed.deinit();
    // Bring index 2 then 0 to the front; the rest (b) follows in order.
    try ed.reorderItems(&.{}, &.{ 2, 0 });
    try expectSource(&ed, "- c\n- a\n- b\n");
}

test "yaml reorder items nested under key" {
    var ed = try newYamlEditor("tags:\n- x\n- y\n- z\n");
    defer ed.deinit();
    try ed.reorderItems(&.{.{ .key = "tags" }}, &.{ 2, 1, 0 });
    try expectSource(&ed, "tags:\n- z\n- y\n- x\n");
}

test "yaml reorder items indented nested seq" {
    var ed = try newYamlEditor("k:\n  - a\n  - b\n  - c\n");
    defer ed.deinit();
    try ed.reorderItems(&.{.{ .key = "k" }}, &.{1});
    try expectSource(&ed, "k:\n  - b\n  - a\n  - c\n");
}

test "yaml reorder items preserves owned comment" {
    var ed = try newYamlEditor("- a\n# note for b\n- b\n- c\n");
    defer ed.deinit();
    try ed.reorderItems(&.{}, &.{ 1, 0 });
    try expectSource(&ed, "# note for b\n- b\n- a\n- c\n");
}

test "yaml reorder flow items keeps spaced separators" {
    var ed = try newYamlEditor("t: [a, b, c]\n");
    defer ed.deinit();
    try ed.reorderItems(&.{.{ .key = "t" }}, &.{ 2, 0 });
    try expectSource(&ed, "t: [c, a, b]\n");
}

test "yaml reorder flow items keeps tight separators" {
    var ed = try newYamlEditor("t: [a,b,c]\n");
    defer ed.deinit();
    try ed.reorderItems(&.{.{ .key = "t" }}, &.{ 2, 1, 0 });
    try expectSource(&ed, "t: [c,b,a]\n");
}

test "yaml reorder items out of range index ignored" {
    var ed = try newYamlEditor("- a\n- b\n");
    defer ed.deinit();
    try ed.reorderItems(&.{}, &.{ 9, 1 });
    try expectSource(&ed, "- b\n- a\n");
}

test "yaml reorder items no-op when order matches" {
    var ed = try newYamlEditor("- a\n- b\n- c\n");
    defer ed.deinit();
    try ed.reorderItems(&.{}, &.{ 0, 1, 2 });
    try expectSource(&ed, "- a\n- b\n- c\n");
}

test "yaml reorder items empty list keeps original order" {
    var ed = try newYamlEditor("- a\n- b\n");
    defer ed.deinit();
    try ed.reorderItems(&.{}, &.{});
    try expectSource(&ed, "- a\n- b\n");
}
