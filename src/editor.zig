//! Editor module, generic over Language.

const std = @import("std");
const build_options = @import("build_options");

const AST = @import("ast/ast.zig");
const Document = @import("document.zig");
const Span = @import("util/span.zig");
const json = @import("languages/json/json.zig");
const json_string = @import("util/json_string.zig");
const log = std.log.scoped(.editor);

// Format-specific editing logic the generic engine delegates to from its
// `if (Language == Toml/Yaml/Fig)` branches: TOML's multi-region gather +
// whole-table ops, YAML's reference-layer / block-framing helpers, and fig's
// marker-prefix-copying block/flow insert + append/prepend. See each module's
// header for the split rationale. These modules also hold that language's editor
// tests, so editor-test code lives next to the concern it exercises.
const toml_edit = @import("languages/toml/editor_helper.zig");
const yaml_edit = @import("languages/yaml/editor_helper.zig");
const fig_edit = @import("languages/fig/editor_helper.zig");
// Language tags used by the comptime branches above.
const Toml = @import("languages/toml/toml.zig").Language;
const Yaml = @import("languages/yaml/yaml.zig").Language;
const Fig = @import("languages/fig/fig.zig").Language;
// Used only for the comptime comment-marker choice (ZON uses `//`, like Zig).
const Zon = @import("languages/zon/zon.zig").Language;

pub fn Editor(comptime Language: type) type {
    @import("languages/language.zig").validate(Language);
    return struct {
        const Self = @This();

        // Which leading-comment syntax this language uses, so the owned-comment
        // scan in delete/move (`commentBlockStart`) recognizes the right marker.
        // JSON/JSONC/JSON5 and ZON use `//` (ZON, like Zig); YAML and TOML use
        // `#`. Plain JSON has no comments, but `.slashes` is harmless there since
        // no `//` line can exist.
        const comment_style: CommentStyle = if (Language == json.Language or Language == Zon) .slashes else .hash;

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

        /// Upsert a mapping value: replace the value at `path`, or — when only
        /// the trailing key is absent — insert it as a fresh `key: value` entry
        /// in the parent mapping. This is the "set this key, creating it if
        /// missing" primitive every config editor reaches for; it folds the
        /// usual `replaceValAtPath` → (on `NotFound`) `insertKey` two-step into
        /// one op.
        ///
        /// The path's last segment MUST name a key — `set` only ever *creates* a
        /// mapping entry, never a sequence item, so a path ending in an index is
        /// rejected with `NotAMapping`. Only the trailing leaf is conjured: a
        /// missing *intermediate* container (the parent mapping itself doesn't
        /// exist) is not vivified, surfacing as `NotFound` from the insert just
        /// as a bare `insertKey` would.
        ///
        /// Delegates to `replaceValAtPath`, so the replace case inherits that
        /// op's YAML value reframing (inline↔block) and merge-key COW.
        ///
        /// Key duality: the replace branch matches the trailing segment
        /// *logically* (against decoded key names), but the insert branch needs
        /// the key as *syntax*. `set` bridges the two — when it inserts, it
        /// renders the logical key into the format's key syntax (quoting/escaping
        /// it for strict JSON, verbatim for YAML/TOML where a simple key already
        /// is its own syntax) — so creating a not-yet-present key works for every
        /// editable format, JSON included.
        pub fn set(self: *Self, path: []const AST.PathSegment, value_text: []const u8) !void {
            if (path.len == 0 or std.meta.activeTag(path[path.len - 1]) != .key)
                return error.NotAMapping;
            self.replaceValAtPath(path, value_text) catch |replace_err| {
                // The value isn't there to replace — create it. The trailing key
                // is logical (it just matched against decoded names), so render it
                // into the format's key syntax before splicing. `insertKey`
                // re-validates the parent (a mapping, or an empty/null root it
                // promotes), so a non-mapping parent or missing intermediate still
                // errors; surface the original replace error when the insert can't
                // proceed. Falling back on any replace error (not just `NotFound`)
                // is what lets `set` seed a freshly-created, still-empty document —
                // where navigating to the key fails with `NotAMapping`.
                const key_text = try self.formatInsertKey(path[path.len - 1].key);
                defer self.allocator.free(key_text);
                self.insertKey(path[0 .. path.len - 1], key_text, value_text) catch
                    return replace_err;
            };
        }

        /// Render a logical mapping key into this format's key syntax for the
        /// `set` insert branch. Strict-JSON-family keys must be quoted and escaped
        /// (`b` → `"b"`); YAML/TOML/ZON splice the key verbatim, as `insertKey`'s
        /// other callers do. Always returns an owned slice (the caller frees it).
        fn formatInsertKey(self: *Self, key: []const u8) ![]u8 {
            if (comptime Language == json.Language) {
                var w = std.Io.Writer.Allocating.init(self.allocator);
                defer w.deinit();
                try json_string.writeQuoted(&w.writer, key);
                return self.allocator.dupe(u8, w.written());
            }
            return self.allocator.dupe(u8, key);
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

        // ========
        // COMMENTS
        // ========
        //
        // Comments are trivia — they live OUTSIDE every AST node span — so these
        // ops reuse the same splice + reparse machinery as the structural edits:
        // compute a byte position from a node's span, splice the comment text,
        // reparse. The reparse is the safety net (`replaceAtSpan` rolls back if
        // the result no longer parses).

        /// The line-comment marker for this language/dialect, or null when the
        /// dialect forbids comments (strict JSON). `self.format` distinguishes
        /// strict JSON from JSONC/JSON5, which the marker choice must honor since
        /// the splice is reparsed under that same dialect.
        fn lineCommentMarker(self: *const Self) ?[]const u8 {
            if (comptime Language == json.Language) {
                // `//` is valid in JSONC/JSON5 but not strict JSON.
                return if (self.format == .JSON) null else "//";
            }
            // ZON uses Zig's `//`; YAML and TOML use `#`.
            if (comptime Language == Zon) return "//";
            return "#";
        }

        /// Add an own-line comment ABOVE the node at `path` — the key's line for a
        /// mapping entry, else the node's own line — matched to that line's
        /// indentation. It lands at the BOTTOM of any existing leading comment
        /// block (the comment line nearest the node). `text` may be multi-line;
        /// each line becomes its own comment line. Returns `CommentsUnsupported`
        /// for a dialect without comment syntax (strict JSON).
        pub fn addLeadingComment(self: *Self, path: []const AST.PathSegment, text: []const u8) !void {
            const marker = self.lineCommentMarker() orelse return error.CommentsUnsupported;
            const parsed = try self.getParsed();
            const node = try parsed.ast.getNodeByPath(path);
            const span = parsed.span(node);
            const source = self.source.items;
            const line_start = lineStartBefore(source, span.start);
            // fig's `#`-only comment line needs the same `>` marker-run prefix
            // as the line it anchors above (comment depth is load-bearing for
            // attachment — DESIGN.md "Comments") — `firstNonSpace` would stop
            // at the `>` and yield bare whitespace, dropping the markers
            // entirely. `span.start` already sits right after that prefix for
            // every fig node (see `TNode.span`'s doc comment in
            // `fig/parser.zig`), so slicing back to the line start recovers it
            // exactly. Every other language's prefix is pure whitespace, where
            // `firstNonSpace` and `span.start` agree anyway.
            const indent = if (Language == Fig) source[line_start..span.start] else source[line_start..firstNonSpace(source, line_start)];

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);
            try renderLineComments(self.allocator, &buf, indent, marker, text);
            try self.replaceAtSpan(Span.init(line_start, line_start), buf.items);
        }

        /// The byte window `[start, line_end)` on the entry-at-`path`'s line where a
        /// same-line trailing comment lives, shared by the set/delete/get trailing
        /// ops. For a scalar or flow value the window runs from just past the value
        /// to that line's newline. For a BLOCK-style mapping/sequence value — whose
        /// node span begins at its first child on a later line — the trailing
        /// comment instead rides the key's line (e.g. `contents: # note` above a
        /// block sequence), so the window is the key line, starting just past the
        /// key. `start` always sits before any comment marker and after the value
        /// (scalar) or key (block), so a `#`/`//` inside the value can't false-match.
        fn trailingCommentWindow(self: *Self, path: []const AST.PathSegment) !struct { start: usize, line_end: usize } {
            const parsed = try self.getParsed();
            const val = try parsed.ast.getValByPath(path);
            const val_span = parsed.span(val);
            const source = self.source.items;
            const is_block_collection = switch (std.meta.activeTag(val.kind)) {
                .mapping, .sequence => !isFlow(source, val_span),
                else => false,
            };
            const start = if (is_block_collection)
                parsed.span(try parsed.ast.getKeyByPath(path)).end
            else
                val_span.end;
            const line_end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
            return .{ .start = start, .line_end = line_end };
        }

        /// Set the same-line trailing comment on the value at `path`: replace an
        /// existing trailing comment on that line, or append one if there is none.
        /// `text` must be a single line. Returns `CommentsUnsupported` for a
        /// dialect without comment syntax (strict JSON), `MultilineComment` if
        /// `text` contains a newline.
        pub fn setTrailingComment(self: *Self, path: []const AST.PathSegment, text: []const u8) !void {
            const marker = self.lineCommentMarker() orelse return error.CommentsUnsupported;
            if (std.mem.indexOfScalar(u8, text, '\n') != null) return error.MultilineComment;
            const win = try self.trailingCommentWindow(path);
            const source = self.source.items;

            // If a comment marker already follows on this line, splice from it
            // (replace); otherwise splice from the line's end (append).
            var cut = if (std.mem.indexOf(u8, source[win.start..win.line_end], marker)) |rel|
                win.start + rel
            else
                win.line_end;
            // Drop the run of spaces/tabs just before the splice so the rebuilt
            // " <marker> text" controls its own single leading space.
            while (cut > win.start and (source[cut - 1] == ' ' or source[cut - 1] == '\t')) cut -= 1;

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(self.allocator);
            try buf.appendSlice(self.allocator, " ");
            try buf.appendSlice(self.allocator, marker);
            if (text.len > 0) {
                try buf.append(self.allocator, ' ');
                try buf.appendSlice(self.allocator, text);
            }
            try self.replaceAtSpan(Span.init(cut, win.line_end), buf.items);
        }

        /// Remove the run of own-line comments immediately ABOVE the node at
        /// `path` — its owned leading block (contiguous comment lines with no
        /// blank line between, the same block `deleteKey` carries). A no-op when
        /// the node has none. Returns `CommentsUnsupported` for a dialect without
        /// comment syntax (strict JSON).
        pub fn deleteLeadingComments(self: *Self, path: []const AST.PathSegment) !void {
            _ = self.lineCommentMarker() orelse return error.CommentsUnsupported;
            const parsed = try self.getParsed();
            const node = try parsed.ast.getNodeByPath(path);
            const span = parsed.span(node);
            const source = self.source.items;
            const line_start = lineStartBefore(source, span.start);
            const block_start = commentBlockStart(source, line_start, comment_style);
            if (block_start == line_start) return; // nothing above to remove
            try self.replaceAtSpan(Span.init(block_start, line_start), "");
        }

        /// Remove the same-line trailing comment on the value at `path`, if any.
        /// A no-op when there is none. Returns `CommentsUnsupported` for a dialect
        /// without comment syntax (strict JSON).
        pub fn deleteTrailingComment(self: *Self, path: []const AST.PathSegment) !void {
            const marker = self.lineCommentMarker() orelse return error.CommentsUnsupported;
            const win = try self.trailingCommentWindow(path);
            const source = self.source.items;
            const rel = std.mem.indexOf(u8, source[win.start..win.line_end], marker) orelse return; // none
            var cut = win.start + rel;
            // Take the whitespace separating the value from the comment with it.
            while (cut > win.start and (source[cut - 1] == ' ' or source[cut - 1] == '\t')) cut -= 1;
            try self.replaceAtSpan(Span.init(cut, win.line_end), "");
        }

        /// Read back the own-line comment block immediately ABOVE the node at
        /// `path` — the same owned block `deleteLeadingComments` removes — with each
        /// line's indentation and `marker` (and one following space) stripped, lines
        /// rejoined by '\n'. Returns `null` when there is no block above the node
        /// (distinct from a present-but-empty comment — a bare `#` — which yields
        /// ""). The caller owns the returned bytes. Returns `CommentsUnsupported`
        /// for a dialect without comment syntax (strict JSON).
        pub fn getLeadingComment(self: *Self, path: []const AST.PathSegment) !?[]u8 {
            const marker = self.lineCommentMarker() orelse return error.CommentsUnsupported;
            const parsed = try self.getParsed();
            const node = try parsed.ast.getNodeByPath(path);
            const span = parsed.span(node);
            const source = self.source.items;
            const line_start = lineStartBefore(source, span.start);
            const block_start = commentBlockStart(source, line_start, comment_style);
            if (block_start == line_start) return null; // no block above

            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(self.allocator);
            var it = std.mem.splitScalar(u8, source[block_start..line_start], '\n');
            var first = true;
            while (it.next()) |raw| {
                const line = std.mem.trimEnd(u8, raw, "\r");
                const trimmed = std.mem.trimStart(u8, line, " \t");
                if (trimmed.len == 0) continue; // skip a trailing empty split slice
                if (!first) try out.append(self.allocator, '\n');
                first = false;
                try out.appendSlice(self.allocator, stripLineCommentMarker(trimmed, marker));
            }
            return try out.toOwnedSlice(self.allocator);
        }

        /// Read back the same-line trailing comment on the value at `path` — the
        /// one `setTrailingComment` sets and `deleteTrailingComment` removes — with
        /// its `marker` (and one following space) stripped. Returns `null` when
        /// there is no trailing comment (distinct from a present-but-empty bare `#`,
        /// which yields ""). The caller owns the returned bytes. Returns
        /// `CommentsUnsupported` for a dialect without comment syntax (strict JSON).
        pub fn getTrailingComment(self: *Self, path: []const AST.PathSegment) !?[]u8 {
            const marker = self.lineCommentMarker() orelse return error.CommentsUnsupported;
            const win = try self.trailingCommentWindow(path);
            const source = self.source.items;
            const rel = std.mem.indexOf(u8, source[win.start..win.line_end], marker) orelse
                return null; // none
            const after = std.mem.trimEnd(u8, source[win.start + rel .. win.line_end], " \t\r");
            return try self.allocator.dupe(u8, stripLineCommentMarker(after, marker));
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
            if (Language == Fig)
                return fig_edit.figInsertKey(self, parsed, node, span, path.len == 0, key_text, value_text);
            switch (node.kind) {
                .mapping => |first| {
                    if (isFlow(source, span)) {
                        try self.insertFlowMapEntry(parsed, node, span, first != null, key_text, value_text);
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
            // A fig block (non-flow) mapping/sequence value may be a
            // re-entered/scattered container (DESIGN.md "Re-entering a path
            // to add new keys is fine") — TOML's `CannotDeleteTable` twin,
            // refusing rather than risk swallowing an interleaved foreign
            // sibling on a scattered container's line-based delete. A flow
            // (`{…}`/`[…]`) value is always tightly contiguous, so it deletes
            // normally below.
            if (Language == Fig) {
                const val = parsed.ast.nodes[node.kind.keyvalue.value];
                if ((val.kind == .mapping or val.kind == .sequence) and !isFlow(source, parsed.span(val)))
                    return error.CannotDeleteContainer;
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
                try self.insertFlowItem(parsed, node, span, first != null, value_text);
                return;
            }
            // A non-flow TOML sequence is an array-of-tables; use
            // `appendTableToArray` for those. (TOML has no block scalar array.)
            if (Language == Toml) return error.NotAnInlineArray;
            if (Language == Fig) return fig_edit.figAppendSeqLine(self, parsed, node, value_text);
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
            if (Language == Fig) return fig_edit.figPrependSeqLine(self, parsed, node, value_text);
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

        /// Reconcile the sequence at `path` so its items are exactly `items` —
        /// each an already-serialized *scalar* value in this document's format —
        /// while preserving the comments on items that survive the change.
        ///
        /// Items are matched to the current items by abstract value (kind +
        /// value, honoring multiplicity), so an item that is kept or merely
        /// reordered keeps its leading and trailing comments; only a genuinely
        /// new value is inserted and only a genuinely dropped value is deleted.
        /// The final item order matches `items`. This is the comment-preserving
        /// alternative to replacing the whole list value (which would blow every
        /// item's comments away).
        ///
        /// It is a thin orchestration over `appendToSeq` / `removeSeqItem` /
        /// `reorderItems`: append the new values, delete the dropped ones, then
        /// reorder to `items`. The compound edit is atomic — on any error the
        /// document is restored byte-for-byte.
        ///
        /// Declines (errors) rather than guessing when the shape isn't a flat
        /// scalar list it can safely diff:
        ///   * a target that isn't a sequence value -> `NotASequence`;
        ///   * empty `items`, an empty current list, or any non-scalar item on
        ///     either side -> `UnsupportedShape` — the caller should fall back to
        ///     replacing the whole value (e.g. with `[]` for the empty case).
        /// A format whose scalars cannot stand alone as a document (TOML) also
        /// surfaces as `UnsupportedShape`; reconciling a TOML inline array buys
        /// nothing anyway, as it carries no per-element comments.
        pub fn setSequence(self: *Self, path: []const AST.PathSegment, items: []const []const u8) !void {
            if (items.len == 0) return error.UnsupportedShape;

            // ---- plan against the current parse (no mutation yet) ----
            // Current item kinds. These borrow `self.document`, so the plan must
            // be reduced to plain indices before the first edit reparses.
            var cur: std.ArrayList(AST.Node.Kind) = .empty;
            defer cur.deinit(self.allocator);
            {
                const parsed = try self.getParsed();
                const node = try parsed.ast.getValByPath(path);
                if (node.kind != .sequence) return error.NotASequence;
                var maybe = try parsed.ast.child(&node);
                while (maybe) |item| {
                    if (!isScalarKind(item.kind)) return error.UnsupportedShape;
                    try cur.append(self.allocator, item.kind);
                    maybe = parsed.ast.next(&item);
                }
            }
            if (cur.items.len == 0) return error.UnsupportedShape;

            // Target item kinds: parse each serialized value back to a scalar so
            // matching is by abstract value, not formatting (`1` != `'1'`). A
            // format whose scalar can't stand alone as a document (TOML) fails
            // the parse and is declined here.
            var tdocs: std.ArrayList(Document) = .empty;
            defer {
                for (tdocs.items) |d| d.deinit(self.allocator);
                tdocs.deinit(self.allocator);
            }
            var tgt: std.ArrayList(AST.Node.Kind) = .empty;
            defer tgt.deinit(self.allocator);
            for (items) |text| {
                var parser: Language.Parser = .{ .allocator = self.allocator };
                const d = Language.parse(&parser, text, self.format) catch return error.UnsupportedShape;
                const k = d.ast.nodes[d.ast.root].kind;
                if (!isScalarKind(k)) {
                    d.deinit(self.allocator);
                    return error.UnsupportedShape;
                }
                try tdocs.append(self.allocator, d);
                try tgt.append(self.allocator, k);
            }

            const m = cur.items.len;
            const t = tgt.items.len;

            // Occurrence index of element `i` = how many earlier elements share
            // its value. (kind, occ) is the per-item identity used for matching,
            // so duplicate values are paired up by their order of appearance.
            const occ = struct {
                fn at(kinds: []const AST.Node.Kind, i: usize) usize {
                    var c: usize = 0;
                    for (kinds[0..i]) |k| {
                        if (k.eql(kinds[i])) c += 1;
                    }
                    return c;
                }
            }.at;

            // A current item survives iff some target item shares its identity.
            const removed = try self.allocator.alloc(bool, m);
            defer self.allocator.free(removed);
            var removed_count: usize = 0;
            for (0..m) |i| {
                removed[i] = true;
                for (0..t) |j| {
                    if (cur.items[i].eql(tgt.items[j]) and occ(cur.items, i) == occ(tgt.items, j)) {
                        removed[i] = false;
                        break;
                    }
                }
                if (removed[i]) removed_count += 1;
            }

            // A target item is an addition iff no current item shares its identity.
            var additions: std.ArrayList(usize) = .empty;
            defer additions.deinit(self.allocator);
            for (0..t) |j| {
                var present = false;
                for (0..m) |i| {
                    if (cur.items[i].eql(tgt.items[j]) and occ(cur.items, i) == occ(tgt.items, j)) {
                        present = true;
                        break;
                    }
                }
                if (!present) try additions.append(self.allocator, j);
            }

            // The physical order after append+remove is survivors (old order)
            // then additions (target order). `slots[s]` says what sits at index
            // `s`: a kept current item or an appended target item.
            const Slot = union(enum) { keep: usize, add: usize };
            var slots: std.ArrayList(Slot) = .empty;
            defer slots.deinit(self.allocator);
            for (0..m) |i| {
                if (!removed[i]) try slots.append(self.allocator, .{ .keep = i });
            }
            for (additions.items) |j| try slots.append(self.allocator, .{ .add = j });

            // `order[k]` = the slot holding target item `k`, so a reorder by
            // `order` (a full permutation) lands the sequence in target order.
            const order = try self.allocator.alloc(usize, t);
            defer self.allocator.free(order);
            const used = try self.allocator.alloc(bool, slots.items.len);
            defer self.allocator.free(used);
            @memset(used, false);
            for (0..t) |k| {
                var found: ?usize = null;
                for (slots.items, 0..) |slot, s| {
                    if (used[s]) continue;
                    const hit = switch (slot) {
                        .keep => |i| cur.items[i].eql(tgt.items[k]) and occ(cur.items, i) == occ(tgt.items, k),
                        .add => |j| j == k,
                    };
                    if (hit) {
                        found = s;
                        break;
                    }
                }
                const s = found orelse return error.UnsupportedShape; // unreachable by construction
                order[k] = s;
                used[s] = true;
            }

            // No-op: same items, same order — leave the bytes untouched so a
            // redundant set never churns formatting.
            var needs_reorder = false;
            for (order, 0..) |o, k| {
                if (o != k) {
                    needs_reorder = true;
                    break;
                }
            }
            if (removed_count == 0 and additions.items.len == 0 and !needs_reorder) return;

            // ---- apply: append, remove, reorder — atomic across all steps ----
            const backup = try self.allocator.dupe(u8, self.source.items);
            defer self.allocator.free(backup);
            errdefer {
                // Capacity only grew during the edits, so the refill cannot fail;
                // `backup` parsed before, so the reparse cannot fail either.
                self.source.clearRetainingCapacity();
                self.source.appendSliceAssumeCapacity(backup);
                self.reparse() catch {};
            }

            // Append first so a full replacement never empties the block mid-edit
            // (an empty block sequence has no valid syntax). Appends land at the
            // tail, leaving the original items' indices valid for removal.
            for (additions.items) |j| try self.appendToSeq(path, items[j]);

            // Remove dropped originals high-index-first so lower indices stay put.
            var di: usize = m;
            while (di > 0) {
                di -= 1;
                if (removed[di]) try self.removeSeqItem(path, di);
            }

            if (needs_reorder) try self.reorderItems(path, order);
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

        // --- fig whole-container structural editing (fig-only) ---
        //
        // The implementations live in `fig/editor_helper.zig`, next to the
        // region-gather helpers they build on — the fig generalization of the
        // TOML wrappers just above. `renameTable`'s fig twin doesn't exist: the
        // generic `replaceKeyAtPath` already splices a header's key in place.
        // See the helper module for the per-op contract and its scope.

        /// Delete the whole block mapping/sequence named by `path`.
        pub fn deleteContainer(self: *Self, path: []const AST.PathSegment) !void {
            if (Language != Fig) @compileError("deleteContainer is fig-only");
            return fig_edit.deleteContainer(self, path);
        }

        /// Move the block container at `src_path` before `dest_path` (or to EOF
        /// if null).
        pub fn moveContainer(self: *Self, src_path: []const AST.PathSegment, dest_path: ?[]const AST.PathSegment) !void {
            if (Language != Fig) @compileError("moveContainer is fig-only");
            return fig_edit.moveContainer(self, src_path, dest_path);
        }

        /// Reorder top-level block containers to the order given by `order`
        /// (their keys).
        pub fn reorderContainers(self: *Self, order: []const []const u8) !void {
            if (Language != Fig) @compileError("reorderContainers is fig-only");
            return fig_edit.reorderContainers(self, order);
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

        /// Insert a `key: value` entry into a brace-delimited (flow) mapping,
        /// matching its layout. A pretty-printed mapping — one whose closing `}`
        /// sits on its own line below the members — gets the new entry on its own
        /// line, indented to match the existing members (a trailing comma after
        /// the last member's value, newline, member indent, `key: value`). A
        /// compact single-line mapping keeps the inline `", key: value"` style.
        fn insertFlowMapEntry(self: *Self, parsed: Document, node: AST.Node, span: Span, non_empty: bool, key_text: []const u8, value_text: []const u8) !void {
            const source = self.source.items;
            if (non_empty) {
                const last = (try parsed.ast.lastChild(&node)).?;
                const last_end = parsed.span(last).end;
                const close = span.end - 1; // the '}'
                // Multi-line layout: the closing brace is separated from the last
                // member by a newline. Splice after the last member's value so the
                // new entry lands on its own line, not jammed before the brace.
                if (std.mem.indexOfScalar(u8, source[last_end..close], '\n') != null) {
                    const key_node = (try parsed.ast.firstChildKey(&node)).?;
                    const col = columnOf(source, parsed.span(key_node).start);
                    var out: std.ArrayList(u8) = .empty;
                    defer out.deinit(self.allocator);
                    try out.appendSlice(self.allocator, ",\n");
                    try out.appendNTimes(self.allocator, ' ', col);
                    try out.appendSlice(self.allocator, key_text);
                    try out.appendSlice(self.allocator, ": ");
                    try out.appendSlice(self.allocator, value_text);
                    try self.replaceAtSpan(Span.init(last_end, last_end), out.items);
                    return;
                }
            }
            return self.insertFlowEntry(span, non_empty, key_text, value_text);
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

        /// Insert `value_text` as the new last item of the flow sequence
        /// `node`/`span`. Splices immediately after the current last
        /// element rather than before the closing `]`, so a pre-existing
        /// trailing comma (legal in fig/JSON5 flow arrays) isn't doubled
        /// into an empty element that fails to reparse. When the array is
        /// laid out one item per line, the new item follows that same
        /// one-per-line style, indented to match the first item — mirroring
        /// `insertFlowMapEntry`'s multi-line handling.
        fn insertFlowItem(self: *Self, parsed: Document, node: AST.Node, span: Span, non_empty: bool, value_text: []const u8) !void {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator);
            const source = self.source.items;
            if (non_empty) {
                const last = (try parsed.ast.lastChild(&node)).?;
                const last_end = parsed.span(last).end;
                const close = span.end - 1; // the ']'
                if (std.mem.indexOfScalar(u8, source[last_end..close], '\n') != null) {
                    const first_item = (try parsed.ast.child(&node)).?;
                    const col = columnOf(source, parsed.span(first_item).start);
                    try out.appendSlice(self.allocator, ",\n");
                    try out.appendNTimes(self.allocator, ' ', col);
                } else {
                    try out.appendSlice(self.allocator, ", ");
                }
                try out.appendSlice(self.allocator, value_text);
                try self.replaceAtSpan(Span.init(last_end, last_end), out.items);
                return;
            }
            try out.appendSlice(self.allocator, value_text);
            const at = span.start + 1; // just after '['
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

/// Strip a leading line-comment `marker` (and one following space) from `line`,
/// the inverse of how `renderLineComments`/`setTrailingComment` emit a comment.
/// `line` must already have its leading whitespace trimmed. A line that doesn't
/// start with `marker` is returned unchanged.
fn stripLineCommentMarker(line: []const u8, marker: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, line, marker)) return line;
    var rest = line[marker.len..];
    if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    return rest;
}

/// Render `text` as one or more own-line comments into `out`, each line being
/// `indent` + `marker` (+ a space and the line's text, unless the line is empty)
/// + '\n'. A single trailing newline in `text` is ignored so it never yields a
/// stray empty comment line.
fn renderLineComments(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    indent: []const u8,
    marker: []const u8,
    text: []const u8,
) !void {
    const body = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        try out.appendSlice(allocator, indent);
        try out.appendSlice(allocator, marker);
        if (line.len > 0) {
            try out.append(allocator, ' ');
            try out.appendSlice(allocator, line);
        }
        try out.append(allocator, '\n');
    }
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

/// Whether a node is a leaf scalar — the kinds `setSequence` can match by value.
fn isScalarKind(kind: AST.Node.Kind) bool {
    return switch (kind) {
        .null_, .boolean, .string, .number, .extended => true,
        .sequence, .mapping, .keyvalue, .alias => false,
    };
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

// ── Comment-editing tests ──────────────────────────────────────────────────
const testing = std.testing;

fn expectCommentEdit(
    comptime Lang: type,
    format: Lang.Type,
    input: []const u8,
    expected: []const u8,
    op: enum { leading, trailing },
    path: []const AST.PathSegment,
    text: []const u8,
) !void {
    var ed: Editor(Lang) = .{ .allocator = testing.allocator, .format = format };
    try ed.init(input);
    defer ed.deinit();
    switch (op) {
        .leading => try ed.addLeadingComment(path, text),
        .trailing => try ed.setTrailingComment(path, text),
    }
    try testing.expectEqualStrings(expected, ed.source.items);
}

test "addLeadingComment inserts an own-line comment above a YAML key" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    try expectCommentEdit(Yaml, .v1_2_2, "a: 1\nb: 2\n", "a: 1\n# note\nb: 2\n", .leading, &.{.{ .key = "b" }}, "note");
}

test "addLeadingComment matches indentation and lands nearest the key" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    // Nested key: comment takes the key's 2-space indent and sits just above it,
    // below the pre-existing comment.
    try expectCommentEdit(
        Yaml,
        .v1_2_2,
        "outer:\n  # kept\n  inner: 1\n",
        "outer:\n  # kept\n  # new\n  inner: 1\n",
        .leading,
        &.{ .{ .key = "outer" }, .{ .key = "inner" } },
        "new",
    );
}

test "setTrailingComment appends and then replaces a YAML same-line comment" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    try expectCommentEdit(Yaml, .v1_2_2, "a: 1\n", "a: 1 # done\n", .trailing, &.{.{ .key = "a" }}, "done");
    // Re-setting replaces the existing trailing comment rather than nesting it.
    try expectCommentEdit(Yaml, .v1_2_2, "a: 1 # old\n", "a: 1 # new\n", .trailing, &.{.{ .key = "a" }}, "new");
}

test "addLeadingComment on TOML uses #" {
    if (comptime !build_options.lang_toml) return error.SkipZigTest;
    try expectCommentEdit(Toml, .TOML_1_1, "a = 1\nb = 2\n", "a = 1\n# note\nb = 2\n", .leading, &.{.{ .key = "b" }}, "note");
}

// This instantiation (plus every `Editor(Fig)` call below) is also what pulls
// `fig/editor_helper.zig` into the test build's reachability graph — `zig
// test` discovers a file's `test` blocks only once something forces it to be
// analyzed, and a bare top-level `const fig_edit = @import(...)` is not
// enough on its own (mirrors why the TOML test above matters for
// `toml/editor_helper.zig`, and why `fig/editor_helper.zig`'s OWN tests carry
// the rest of `Editor(Fig)`'s coverage rather than duplicating it here).
test "addLeadingComment on fig uses # at the target's own marker depth" {
    if (comptime !build_options.lang_fig) return error.SkipZigTest;
    try expectCommentEdit(Fig, .Fig, "a = 1\nb = 2\n", "a = 1\n# note\nb = 2\n", .leading, &.{.{ .key = "b" }}, "note");
    try expectCommentEdit(
        Fig,
        .Fig,
        "database\n> pool\n> > size = 10\n",
        "database\n> pool\n> > # note\n> > size = 10\n",
        .leading,
        &.{ .{ .key = "database" }, .{ .key = "pool" }, .{ .key = "size" } },
        "note",
    );
}

test "comment ops on JSONC use // and respect indentation" {
    try expectCommentEdit(
        json.Language,
        .JSONC,
        "{\n  \"a\": 1\n}",
        "{\n  // note\n  \"a\": 1\n}",
        .leading,
        &.{.{ .key = "a" }},
        "note",
    );
}

test "set inserts into a pretty-printed JSON object on its own line, indented" {
    var ed: Editor(json.Language) = .{ .allocator = testing.allocator, .format = .JSON };
    try ed.init("{\n  \"a\": 1,\n  \"b\": 2\n}");
    defer ed.deinit();
    try ed.set(&.{.{ .key = "c" }}, "3");
    try testing.expectEqualStrings("{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": 3\n}", ed.source.items);
}

test "set keeps compact single-line JSON objects inline" {
    var ed: Editor(json.Language) = .{ .allocator = testing.allocator, .format = .JSON };
    try ed.init("{\"a\": 1, \"b\": 2}");
    defer ed.deinit();
    try ed.set(&.{.{ .key = "c" }}, "3");
    try testing.expectEqualStrings("{\"a\": 1, \"b\": 2, \"c\": 3}", ed.source.items);
}

test "comment ops are rejected for strict JSON" {
    var ed: Editor(json.Language) = .{ .allocator = testing.allocator, .format = .JSON };
    try ed.init("{\"a\":1}");
    defer ed.deinit();
    try testing.expectError(error.CommentsUnsupported, ed.addLeadingComment(&.{.{ .key = "a" }}, "x"));
    try testing.expectError(error.CommentsUnsupported, ed.setTrailingComment(&.{.{ .key = "a" }}, "x"));
}

test "multi-line leading comment becomes one line per row" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    try expectCommentEdit(Yaml, .v1_2_2, "a: 1\n", "# one\n# two\na: 1\n", .leading, &.{.{ .key = "a" }}, "one\ntwo");
}

test "setTrailingComment rejects a multi-line comment" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    var ed: Editor(Yaml) = .{ .allocator = testing.allocator, .format = .v1_2_2 };
    try ed.init("a: 1\n");
    defer ed.deinit();
    try testing.expectError(error.MultilineComment, ed.setTrailingComment(&.{.{ .key = "a" }}, "x\ny"));
}

fn expectCommentDelete(
    comptime Lang: type,
    format: Lang.Type,
    input: []const u8,
    expected: []const u8,
    op: enum { leading, trailing },
    path: []const AST.PathSegment,
) !void {
    var ed: Editor(Lang) = .{ .allocator = testing.allocator, .format = format };
    try ed.init(input);
    defer ed.deinit();
    switch (op) {
        .leading => try ed.deleteLeadingComments(path),
        .trailing => try ed.deleteTrailingComment(path),
    }
    try testing.expectEqualStrings(expected, ed.source.items);
}

test "deleteLeadingComments removes the owned block above a YAML key" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    // Only the block touching the key goes; a blank line breaks ownership, so the
    // earlier comment (above the blank) stays.
    try expectCommentDelete(
        Yaml,
        .v1_2_2,
        "# top\n\n# a\n# b\nkey: 1\n",
        "# top\n\nkey: 1\n",
        .leading,
        &.{.{ .key = "key" }},
    );
    // No leading comment → no-op.
    try expectCommentDelete(Yaml, .v1_2_2, "key: 1\n", "key: 1\n", .leading, &.{.{ .key = "key" }});
}

test "deleteTrailingComment removes a same-line comment (YAML/JSONC), else no-op" {
    if (comptime build_options.lang_yaml)
        try expectCommentDelete(Yaml, .v1_2_2, "a: 1 # gone\nb: 2\n", "a: 1\nb: 2\n", .trailing, &.{.{ .key = "a" }});
    // No trailing comment → no-op.
    if (comptime build_options.lang_yaml)
        try expectCommentDelete(Yaml, .v1_2_2, "a: 1\n", "a: 1\n", .trailing, &.{.{ .key = "a" }});
    // JSONC `//` trailing.
    try expectCommentDelete(json.Language, .JSONC, "{\n  \"a\": 1 // x\n}", "{\n  \"a\": 1\n}", .trailing, &.{.{ .key = "a" }});
}

test "ZON owned-comment scan uses // (comment_style fix)" {
    if (comptime !build_options.lang_zon) return error.SkipZigTest;
    try expectCommentDelete(
        Zon,
        .ZON,
        ".{\n    // note\n    .n = 3,\n}\n",
        ".{\n    .n = 3,\n}\n",
        .leading,
        &.{.{ .key = "n" }},
    );
}

test "comment delete ops are rejected for strict JSON" {
    var ed: Editor(json.Language) = .{ .allocator = testing.allocator, .format = .JSON };
    try ed.init("{\"a\":1}");
    defer ed.deinit();
    try testing.expectError(error.CommentsUnsupported, ed.deleteLeadingComments(&.{.{ .key = "a" }}));
    try testing.expectError(error.CommentsUnsupported, ed.deleteTrailingComment(&.{.{ .key = "a" }}));
}

fn expectCommentGet(
    comptime Lang: type,
    format: Lang.Type,
    input: []const u8,
    /// `null` asserts the comment is ABSENT; a string asserts it is present with
    /// exactly those bytes (`""` = a present-but-empty bare marker).
    expected: ?[]const u8,
    op: enum { leading, trailing },
    path: []const AST.PathSegment,
) !void {
    var ed: Editor(Lang) = .{ .allocator = testing.allocator, .format = format };
    try ed.init(input);
    defer ed.deinit();
    const got = switch (op) {
        .leading => try ed.getLeadingComment(path),
        .trailing => try ed.getTrailingComment(path),
    };
    defer if (got) |g| testing.allocator.free(g);
    if (expected) |want| {
        try testing.expect(got != null);
        try testing.expectEqualStrings(want, got.?);
    } else {
        try testing.expect(got == null);
    }
}

test "getLeadingComment returns the owned block above a key, markers stripped" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    try expectCommentGet(Yaml, .v1_2_2, "# one\n# two\na: 1\n", "one\ntwo", .leading, &.{.{ .key = "a" }});
    // No block above → absent (null).
    try expectCommentGet(Yaml, .v1_2_2, "a: 1\nb: 2\n", null, .leading, &.{.{ .key = "b" }});
}

test "getTrailingComment returns the same-line comment, marker stripped" {
    if (comptime build_options.lang_yaml) {
        try expectCommentGet(Yaml, .v1_2_2, "a: 1 # done\n", "done", .trailing, &.{.{ .key = "a" }});
        // No trailing comment → absent (null).
        try expectCommentGet(Yaml, .v1_2_2, "a: 1\n", null, .trailing, &.{.{ .key = "a" }});
    }
    // JSONC `//` trailing.
    try expectCommentGet(json.Language, .JSONC, "{\n  \"a\": 1 // x\n}", "x", .trailing, &.{.{ .key = "a" }});
}

test "trailing comment on a block-collection key rides the key line" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const seq = "contents: # note\n- one\n- two\n";
    // get: the comment after the colon on the key's line, not after the last item.
    try expectCommentGet(Yaml, .v1_2_2, seq, "note", .trailing, &.{.{ .key = "contents" }});
    // set: replaces the key-line comment in place (does not append after `two`).
    try expectCommentEdit(Yaml, .v1_2_2, seq, "contents: # new\n- one\n- two\n", .trailing, &.{.{ .key = "contents" }}, "new");
    // set on a block key with no existing comment lands on the key line.
    try expectCommentEdit(Yaml, .v1_2_2, "k:\n- a\n- b\n", "k: # added\n- a\n- b\n", .trailing, &.{.{ .key = "k" }}, "added");
    // delete: removes the key-line comment.
    try expectCommentDelete(Yaml, .v1_2_2, seq, "contents:\n- one\n- two\n", .trailing, &.{.{ .key = "contents" }});
}

test "trailing comment on a parent key ignores a child's same-line comment" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    // The `# bc` belongs to child `b`; the parent `a` has no trailing comment.
    try expectCommentGet(Yaml, .v1_2_2, "a:\n  b: 1 # bc\n", null, .trailing, &.{.{ .key = "a" }});
    try expectCommentGet(Yaml, .v1_2_2, "a:\n  b: 1 # bc\n", "bc", .trailing, &.{ .{ .key = "a" }, .{ .key = "b" } });
}

test "getLeadingComment round-trips an empty comment line" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    // A bare `#` (no text) decodes to an empty line within the block.
    try expectCommentGet(Yaml, .v1_2_2, "# one\n#\n# three\na: 1\n", "one\n\nthree", .leading, &.{.{ .key = "a" }});
}

test "get distinguishes a present-but-empty comment from an absent one" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    // A bare `#` is PRESENT with empty text → "" (not null).
    try expectCommentGet(Yaml, .v1_2_2, "a: 1 #\n", "", .trailing, &.{.{ .key = "a" }});
    try expectCommentGet(Yaml, .v1_2_2, "#\na: 1\n", "", .leading, &.{.{ .key = "a" }});
    // No marker at all → absent (null).
    try expectCommentGet(Yaml, .v1_2_2, "a: 1\n", null, .trailing, &.{.{ .key = "a" }});
}

test "get comment ops are rejected for strict JSON" {
    var ed: Editor(json.Language) = .{ .allocator = testing.allocator, .format = .JSON };
    try ed.init("{\"a\":1}");
    defer ed.deinit();
    try testing.expectError(error.CommentsUnsupported, ed.getLeadingComment(&.{.{ .key = "a" }}));
    try testing.expectError(error.CommentsUnsupported, ed.getTrailingComment(&.{.{ .key = "a" }}));
}

// ── set (upsert) tests ──────────────────────────────────────────────────────

fn expectSet(
    comptime Lang: type,
    format: Lang.Type,
    input: []const u8,
    path: []const AST.PathSegment,
    value: []const u8,
    expected: []const u8,
) !void {
    var ed: Editor(Lang) = .{ .allocator = testing.allocator, .format = format };
    try ed.init(input);
    defer ed.deinit();
    try ed.set(path, value);
    try testing.expectEqualStrings(expected, ed.source.items);
}

test "set replaces an existing YAML value" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    try expectSet(Yaml, .v1_2_2, "a: 1\nb: 2\n", &.{.{ .key = "a" }}, "9", "a: 9\nb: 2\n");
}

test "set inserts a missing top-level YAML key" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    try expectSet(Yaml, .v1_2_2, "a: 1\n", &.{.{ .key = "b" }}, "2", "a: 1\nb: 2\n");
}

test "set inserts a missing nested key under an existing mapping" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    try expectSet(
        Yaml,
        .v1_2_2,
        "outer:\n  inner: 1\n",
        &.{ .{ .key = "outer" }, .{ .key = "added" } },
        "2",
        "outer:\n  inner: 1\n  added: 2\n",
    );
}

test "set reframes a YAML value inline->block on replace" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    // Inherits replaceValAtPath's reframing: a scalar becomes a block list
    // (fig writes indentless block sequences under a key).
    try expectSet(Yaml, .v1_2_2, "a: 1\n", &.{.{ .key = "a" }}, "- x\n- y", "a:\n- x\n- y\n");
}

test "set replaces an existing JSON value (replace branch is format-agnostic)" {
    // The replace branch matches keys logically, so it works for strict JSON.
    try expectSet(json.Language, .JSON, "{\"a\": 1}", &.{.{ .key = "a" }}, "\"x\"", "{\"a\": \"x\"}");
}

test "set creates a new JSON key, quoting it for the format" {
    // The insert branch renders the logical key into JSON syntax (`b` -> `"b"`),
    // so creating a not-yet-present key produces valid JSON.
    try expectSet(json.Language, .JSON, "{\"a\": 1}", &.{.{ .key = "b" }}, "2", "{\"a\": 1, \"b\": 2}");
    // A key needing escaping is escaped, not spliced raw.
    try expectSet(json.Language, .JSON, "{}", &.{.{ .key = "a\"b" }}, "1", "{\"a\\\"b\": 1}");
}

test "set rejects a path that does not end in a key" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    var ed: Editor(Yaml) = .{ .allocator = testing.allocator, .format = .v1_2_2 };
    try ed.init("a:\n  - 1\n");
    defer ed.deinit();
    try testing.expectError(error.NotAMapping, ed.set(&.{ .{ .key = "a" }, .{ .index = 0 } }, "9"));
    try testing.expectError(error.NotAMapping, ed.set(&.{}, "9"));
}

test "set does not vivify a missing intermediate container" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    var ed: Editor(Yaml) = .{ .allocator = testing.allocator, .format = .v1_2_2 };
    try ed.init("a: 1\n");
    defer ed.deinit();
    // Parent `missing` does not exist: the insert surfaces NotFound, not a new
    // nested table.
    try testing.expectError(error.NotFound, ed.set(&.{ .{ .key = "missing" }, .{ .key = "leaf" } }, "2"));
}
