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

        pub fn replaceValAtPath(self: *Self, path: []const AST.PathSegment, replacement: []const u8) !void {
            const parsed = try self.getParsed();
            const node = try parsed.ast.getValByPath(path);
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
        /// `#` lines with no intervening blank line), leaving no blank gap.
        pub fn deleteKey(self: *Self, path: []const AST.PathSegment) !void {
            const parsed = try self.getParsed();
            const node = try parsed.ast.getNodeByPath(path);
            if (node.kind != .keyvalue) return error.NotAMapping;
            const span = parsed.span(node);
            const source = self.source.items;
            const line_start = lineStartBefore(source, span.start);
            const del_start = commentBlockStart(source, line_start);
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
            const line_start = commentBlockStart(source, lineStartBefore(source, item_span.start));
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
                entryBlockStart(source, parsed.span(src)),
                entryBlockEnd(source, parsed.span(src)),
                entryBlockStart(source, parsed.span(dest)),
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
                try blocks.append(self.allocator, .{ .start = entryBlockStart(source, parsed.span(cur)), .end = 0 });
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
            var blocks: std.ArrayList(Block) = .empty;
            defer blocks.deinit(self.allocator);
            for (spans.items) |s| {
                try blocks.append(self.allocator, .{ .start = entryBlockStart(source, s), .end = 0 });
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

/// Grow `line_start` upward to absorb an owned comment block: a contiguous run
/// of `#` comment lines immediately above, with no intervening blank line
/// (trivia policy "comment-above-belongs-to-key"). A blank line or any
/// non-comment content stops the scan.
fn commentBlockStart(source: []const u8, line_start: usize) usize {
    var ls = line_start;
    while (ls > 0) {
        const prev_start = lineStartBefore(source, ls - 1);
        const line = source[prev_start..ls];
        const trimmed = std.mem.trimStart(u8, std.mem.trimEnd(u8, line, "\r\n"), " \t");
        if (trimmed.len > 0 and trimmed[0] == '#') {
            ls = prev_start;
        } else break;
    }
    return ls;
}

/// Start of a mapping entry's full block: its owned leading comment block
/// (`commentBlockStart`) at the start of the key's line. Mirrors the span math
/// `deleteKey` uses, factored out for move/reorder.
fn entryBlockStart(source: []const u8, kv_span: Span) usize {
    return commentBlockStart(source, lineStartBefore(source, kv_span.start));
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
