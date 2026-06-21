//! Editor module, generic over Language.

const std = @import("std");

const AST = @import("ast.zig");
const Document = @import("document.zig");
const Span = @import("util/span.zig");
const json = @import("json/json.zig");
const log = std.log.scoped(.editor);

// Format-specific editing logic the generic engine delegates to from its
// `if (Language == Toml/Yaml)` branches: TOML's multi-region gather + whole-table
// ops, and YAML's reference-layer / block-framing helpers. See each module's
// header for the split rationale. These modules also hold that language's editor
// tests, so editor-test code lives next to the concern it exercises.
const toml_edit = @import("toml/editor_helper.zig");
const yaml_edit = @import("yaml/editor_helper.zig");
// Language tags used by the comptime branches above.
const Toml = @import("toml/toml.zig").Language;
const Yaml = @import("yaml/yaml.zig").Language;

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

        pub fn getParsed(self: *const Self) !Document {
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
                if (Language == Yaml and err == error.NotFound and try yaml_edit.mergeSuppliesKey(parsed, path)) {
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
                try yaml_edit.reframeMappingValue(self, parsed, path, span, replacement);
                return;
            }
            try self.replaceAtSpan(span, replacement);
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
                try self.replaceAtSpan(yaml_edit.valueSpanWithoutProps(self, parsed, target), replacement);
                return;
            }
            try self.replaceValAtPath(path, replacement);
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
                return toml_edit.tomlInsertKey(self, parsed, node, span, path.len == 0, key_text, value_text);
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
                if (Language == Yaml and err == error.NotFound and try yaml_edit.mergeSuppliesKey(parsed, path))
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

        // --- TOML whole-table structural editing (TOML-only) ---
        //
        // The implementations live in `toml/editor_helper.zig`, next to the
        // region helpers they build on, so this generic engine stays
        // format-agnostic. These wrappers are the public `Editor(Toml)` surface;
        // each guards with a comptime error so the method does not exist for
        // other formats. See the helper module for the per-op contract.

        /// Append a `[[header]]` element (body `body_text`) to the AoT at `path`.
        pub fn appendTableToArray(self: *Self, path: []const AST.PathSegment, body_text: []const u8) !void {
            if (Language != Toml) @compileError("appendTableToArray is TOML-only");
            return toml_edit.appendTableToArray(self, path, body_text);
        }

        /// Delete the table / array-of-tables / AoT element named by `path`.
        pub fn deleteTable(self: *Self, path: []const AST.PathSegment) !void {
            if (Language != Toml) @compileError("deleteTable is TOML-only");
            return toml_edit.deleteTable(self, path);
        }

        /// Create a new `[path]` table with body `body_text`.
        pub fn insertTable(self: *Self, path: []const AST.PathSegment, body_text: []const u8) !void {
            if (Language != Toml) @compileError("insertTable is TOML-only");
            return toml_edit.insertTable(self, path, body_text);
        }

        /// Rename the leaf segment of the table at `path` to `new_leaf`.
        pub fn renameTable(self: *Self, path: []const AST.PathSegment, new_leaf: []const u8) !void {
            if (Language != Toml) @compileError("renameTable is TOML-only");
            return toml_edit.renameTable(self, path, new_leaf);
        }

        /// Move the table at `src_path` before `dest_path` (or to EOF if null).
        pub fn moveTable(self: *Self, src_path: []const AST.PathSegment, dest_path: ?[]const AST.PathSegment) !void {
            if (Language != Toml) @compileError("moveTable is TOML-only");
            return toml_edit.moveTable(self, src_path, dest_path);
        }

        /// Reorder top-level tables to the order given by `order` (their keys).
        pub fn reorderTables(self: *Self, order: []const []const u8) !void {
            if (Language != Toml) @compileError("reorderTables is TOML-only");
            return toml_edit.reorderTables(self, order);
        }

        /// Append `: value` for a mapping entry whose key is already written at
        /// column `col`. Scalars and block scalars stay inline (`key: value`);
        /// a multi-line block collection goes on the following lines, indented
        /// (a nested mapping at `col + 2`, an indentless sequence at `col`).
        pub fn writeMapValue(self: *Self, out: *std.ArrayList(u8), col: usize, value_text: []const u8) !void {
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
pub fn lineStartBefore(source: []const u8, at: usize) usize {
    var i = at;
    while (i > 0) : (i -= 1) {
        if (source[i - 1] == '\n') return i;
    }
    return 0;
}

/// Byte index just past the next '\n' at or after `at`, or `source.len`.
pub fn lineEndAfter(source: []const u8, at: usize) usize {
    if (std.mem.indexOfScalarPos(u8, source, at, '\n')) |nl| return nl + 1;
    return source.len;
}

/// Index of the first non-space/non-tab byte at or after `from`.
pub fn firstNonSpace(source: []const u8, from: usize) usize {
    var i = from;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
    return i;
}

/// Column (0-based) of the byte at `at` within its line.
pub fn columnOf(source: []const u8, at: usize) usize {
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
pub fn isFlow(source: []const u8, span: Span) bool {
    const i = firstNonSpace(source, span.start);
    return i < source.len and (source[i] == '{' or source[i] == '[');
}

/// Comment syntax for the owned-comment scan: `#` line comments (YAML/TOML) vs
/// `//` line comments and `/* */` blocks (JSON5/JSONC).
pub const CommentStyle = enum { hash, slashes };

/// Grow `line_start` upward to absorb an entry's owned comment block: the
/// contiguous run of comment lines immediately above, with no intervening blank
/// line (trivia policy "comment-above-belongs-to-key"). A blank line or any
/// non-comment content stops the scan. With `.slashes`, multi-line `/* ... */`
/// blocks are walked as a unit so a delete/move carries the whole block, not
/// just its closing line.
pub fn commentBlockStart(source: []const u8, line_start: usize, style: CommentStyle) usize {
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
pub fn appendBlockSep(out: *std.ArrayList(u8), allocator: std.mem.Allocator, block: []const u8) !void {
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
