//! Builder — programmatic construction of an AST, the write-path mirror of the
//! read-path navigation helpers in `reader.zig`. This file IS the `Builder`
//! type (re-exported as `AST.Builder` from `ast.zig`).
//!
//! Formalizes the node-construction pattern the parsers share (id = array index,
//! children linked via `next_sibling`, decoded strings collected for
//! `owned_strings`).
//!
//! Construction is bottom-up: add the children, then add the container from
//! their ids. `finish` freezes the result into an owned `AST`.
//!
//! Two contracts:
//!   * Every string handed to the builder is *copied* into the AST's
//!     `owned_strings` — a built AST has no `source` to borrow from, so caller
//!     buffers need not outlive the builder.
//!   * Each node id must be placed in exactly one container. A node carries a
//!     single `next_sibling`, so reusing an id in two containers corrupts the
//!     tree (asserted in safe builds via the link helpers' single-owner walk).

const Builder = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const Writer = std.Io.Writer;

const AST = @import("ast.zig");
const Node = AST.Node;
const Comment = AST.Comment;
const NodeComments = AST.NodeComments;
const Span = @import("../util/span.zig");

allocator: Allocator,
nodes: std.ArrayList(Node) = .empty,
owned_strings: std.ArrayList([]const u8) = .empty,
/// Parallel to `nodes` (one zero-span entry appended per node by `append`).
/// Opt-in: a build that never calls `setSpan` just carries zero spans, which
/// `takeSpans` still returns (so a `Document` built from them has the right
/// length, if a caller wants one). Only the fig parser populates this today —
/// every other parser tracks spans itself alongside its own direct node
/// construction (see each parser's `node_spans`/`addNode`).
spans: std.ArrayList(Span) = .empty,
/// Parallel to `nodes` (one entry appended per node, default-empty). Only
/// materialized into the finished AST when `any_comments` is set, so a build
/// that never touches comments carries the AST's `&.{}` default. The runs are
/// growable lists (not plain slices) so the incremental comment helpers
/// amortize their appends instead of reallocating one element at a time;
/// `finish` freezes them into the AST's plain-slice `NodeComments`.
comments: std.ArrayList(PendingComments) = .empty,
/// Scratch `[]NodeComments` that `view` rebuilds on each call (borrowing the
/// pending runs' `.items`), reused so `view` only allocates when it must grow.
/// Not part of any finished AST.
view_comments: std.ArrayList(NodeComments) = .empty,
any_comments: bool = false,
/// Type tags by node id (`ast.node_tags`). Unlike `comments`/`spans` this is
/// NOT grown per-node in `append` — tags are rare, so `setTag` grows it to the
/// tagged id on demand (null-filling the gap). A build that never tags a node
/// carries the AST's `&.{}` default; readers length-guard the table, so a short
/// slice is fine. Frozen into the AST's plain slice by `finish` when `any_tags`.
node_tags: std.ArrayList(?AST.Tag) = .empty,
any_tags: bool = false,

pub const Entry = struct { key: Node.Id, value: Node.Id };

/// Builder-side mutable form of `NodeComments`: the `leading`/`dangling` runs
/// are growable `ArrayList`s (an empty list allocates nothing) so incremental
/// appends amortize. Frozen into plain-slice `NodeComments` by `finish`, or
/// borrowed via the `view_comments` scratch table by `view`.
const PendingComments = struct {
    leading: std.ArrayList(Comment) = .empty,
    trailing: ?Comment = null,
    dangling: std.ArrayList(Comment) = .empty,
};

pub fn init(allocator: Allocator) Builder {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Builder) void {
    for (self.owned_strings.items) |s| self.allocator.free(s);
    self.owned_strings.deinit(self.allocator);
    self.nodes.deinit(self.allocator);
    for (self.comments.items) |*nc| {
        nc.leading.deinit(self.allocator);
        nc.dangling.deinit(self.allocator);
    }
    self.comments.deinit(self.allocator);
    self.view_comments.deinit(self.allocator);
    self.spans.deinit(self.allocator);
    // Only the outer list is ours; any `.text` tag payload aliases owned_strings
    // (freed above) — same discipline as the AST's own `node_tags` free.
    self.node_tags.deinit(self.allocator);
}

/// Set `id`'s source span (a byte range into the input `id` was parsed from).
/// Only meaningful for a builder whose caller tracks source positions (fig's
/// parser does; a hand-assembled AST with no source text leaves every span at
/// its `append`-time default of `Span.init(0, 0)`).
pub fn setSpan(self: *Builder, id: Node.Id, span: Span) void {
    self.spans.items[id] = span;
}

/// Move out the per-node span table built via `setSpan` (parallel to `nodes`,
/// one entry per node in id order — the same length as `ast.nodes` after
/// `finish`). Call any time after the ids of interest were minted (`finish`
/// does not consume `spans`, so this may run before or after it). The caller
/// owns the returned slice.
pub fn takeSpans(self: *Builder) Allocator.Error![]Span {
    const spans = try self.spans.toOwnedSlice(self.allocator);
    self.spans = .empty;
    return spans;
}

/// Attach comments to an already-added node, REPLACING any previously set on
/// `id` (pass `.{}` to clear). Every comment's text is copied into
/// `owned_strings` (so the finished AST owns it). For attaching comments one
/// at a time, prefer the amortized `addLeadingComment`/`addDanglingComment`/
/// `setTrailingComment` helpers.
pub fn setComments(self: *Builder, id: Node.Id, node_comments: NodeComments) Allocator.Error!void {
    const slot = &self.comments.items[id];
    slot.leading.clearRetainingCapacity();
    slot.dangling.clearRetainingCapacity();
    try slot.leading.ensureTotalCapacity(self.allocator, node_comments.leading.len);
    for (node_comments.leading) |c|
        slot.leading.appendAssumeCapacity(.{ .text = try self.dupe(c.text), .style = c.style });
    try slot.dangling.ensureTotalCapacity(self.allocator, node_comments.dangling.len);
    for (node_comments.dangling) |c|
        slot.dangling.appendAssumeCapacity(.{ .text = try self.dupe(c.text), .style = c.style });
    slot.trailing = if (node_comments.trailing) |t|
        .{ .text = try self.dupe(t.text), .style = t.style }
    else
        null;
    self.any_comments = true;
}

/// Append one comment to the run rendered ABOVE `id` (its `leading` run), in
/// call order. The text is copied into owned storage. This is the incremental
/// counterpart to `setComments` (which replaces a node's whole comment set) —
/// reach for it when attaching comments one at a time; the backing run is a
/// growable list, so repeated appends amortize.
///
/// Comments are format-agnostic: a target format without comment syntax here
/// (plain JSON, or compact JSON5/JSONC/ZON) drops them on serialize. That is a
/// reported loss, not an error — see `fig.Diagnostics.analyze` — so this never
/// rejects based on a format.
pub fn addLeadingComment(self: *Builder, id: Node.Id, comment: Comment) Allocator.Error!void {
    const text = try self.dupe(comment.text);
    try self.comments.items[id].leading.append(self.allocator, .{ .text = text, .style = comment.style });
    self.any_comments = true;
}

/// Append one comment to `id`'s `dangling` run — comments at the END of a
/// container's body, after its last child (an orphan in an empty container, or
/// comments sitting before its closing delimiter / at end of document). Only
/// meaningful on a container node; see `NodeComments`.
pub fn addDanglingComment(self: *Builder, id: Node.Id, comment: Comment) Allocator.Error!void {
    const text = try self.dupe(comment.text);
    try self.comments.items[id].dangling.append(self.allocator, .{ .text = text, .style = comment.style });
    self.any_comments = true;
}

/// Set `id`'s single same-line `trailing` comment (rendered to the right of
/// the value). Replaces any previous trailing comment on the node. The text is
/// copied into owned storage.
pub fn setTrailingComment(self: *Builder, id: Node.Id, comment: Comment) Allocator.Error!void {
    const text = try self.dupe(comment.text);
    self.comments.items[id].trailing = .{ .text = text, .style = comment.style };
    self.any_comments = true;
}

/// Attach a cross-format type tag to an already-added node (`ast.node_tags`),
/// replacing any tag previously set on `id`. A `.text` tag is copied into owned
/// storage; a `.kind` tag owns nothing. The table grows to `id` on demand
/// (null-filling any gap), so tagging is pay-per-use.
pub fn setTag(self: *Builder, id: Node.Id, tag: AST.Tag) Allocator.Error!void {
    while (self.node_tags.items.len <= id) try self.node_tags.append(self.allocator, null);
    self.node_tags.items[id] = switch (tag) {
        .kind => tag,
        .text => |t| .{ .text = try self.dupe(t) },
    };
    self.any_tags = true;
}

pub fn addNull(self: *Builder) Allocator.Error!Node.Id {
    return self.append(.null_);
}

pub fn addBool(self: *Builder, value: bool) Allocator.Error!Node.Id {
    return self.append(.{ .boolean = value });
}

/// Add a signed integer scalar (rendered as decimal text in `number.raw`).
pub fn addInt(self: *Builder, value: i64) Allocator.Error!Node.Id {
    const raw = try std.fmt.allocPrint(self.allocator, "{d}", .{value});
    return self.append(.{ .number = .{ .raw = try self.own(raw), .kind = .integer } });
}

/// Add an unsigned integer scalar (decimal text). Separate from `addInt` so
/// values above `maxInt(i64)` round-trip without overflow.
pub fn addUint(self: *Builder, value: u64) Allocator.Error!Node.Id {
    const raw = try std.fmt.allocPrint(self.allocator, "{d}", .{value});
    return self.append(.{ .number = .{ .raw = try self.own(raw), .kind = .integer } });
}

/// Add a numeric scalar from already-formatted text (copied). `is_float`
/// records which `number.kind` it is. This is the escape hatch for floats
/// (whose canonical text policy is the caller's until the binding work pins
/// it) and for integers outside the i64/u64 range.
pub fn addNumberRaw(self: *Builder, raw: []const u8, is_float: bool) Allocator.Error!Node.Id {
    return self.append(.{ .number = .{ .raw = try self.dupe(raw), .kind = if (is_float) .float else .integer } });
}

/// Add a string scalar (copied).
pub fn addString(self: *Builder, value: []const u8) Allocator.Error!Node.Id {
    return self.append(.{ .string = try self.dupe(value) });
}

/// Add a format-specific scalar (TOML datetime, ZON enum/char literal).
/// See `Node.Kind.Extended`.
pub fn addExtended(self: *Builder, kind: Node.Kind.Extended.ExtKind, text: []const u8) Allocator.Error!Node.Id {
    return self.append(.{ .extended = .{ .kind = kind, .text = try self.dupe(text) } });
}

/// Add a sequence whose elements are the given node ids, in order.
/// Empty is allowed (`&.{}`), yielding a node with no children.
pub fn addSequence(self: *Builder, items: []const Node.Id) Allocator.Error!Node.Id {
    self.link(items);
    return self.append(.{ .sequence = if (items.len == 0) null else items[0] });
}

/// Add a mapping from the given entries, in order. A `keyvalue` node is
/// minted for each entry, and the wrappers are linked as siblings.
pub fn addMapping(self: *Builder, entries: []const Entry) Allocator.Error!Node.Id {
    var first: ?Node.Id = null;
    var prev: ?Node.Id = null;
    for (entries) |entry| {
        const kv = try self.append(.{ .keyvalue = .{ .key = entry.key, .value = entry.value } });
        if (prev) |p| {
            self.nodes.items[p].next_sibling = kv;
        } else {
            first = kv;
        }
        prev = kv;
    }
    return self.append(.{ .mapping = first });
}

/// Add one `keyvalue` node wrapping `key`/`value`, returning its own id —
/// the lower-level twin of `addMapping` for a caller that needs the entry's
/// id before assembling the mapping (e.g. to `setSpan` it). Pair with
/// `addMappingFromEntries`.
pub fn addKeyValue(self: *Builder, key: Node.Id, value: Node.Id) Allocator.Error!Node.Id {
    return self.append(.{ .keyvalue = .{ .key = key, .value = value } });
}

/// Add a mapping from already-built `keyvalue` node ids (as returned by
/// `addKeyValue`), in order. Siblings are linked exactly like `addMapping`;
/// this just skips minting the `keyvalue` wrappers itself.
pub fn addMappingFromEntries(self: *Builder, kv_ids: []const Node.Id) Allocator.Error!Node.Id {
    self.link(kv_ids);
    return self.append(.{ .mapping = if (kv_ids.len == 0) null else kv_ids[0] });
}

/// Freeze the builder into an owned `AST` rooted at `root`. The builder is
/// reset to empty, so a subsequent `deinit` is harmless. The returned AST
/// owns its nodes and strings; free it with `ast.deinit()`. It carries the type
/// tags set via `setTag` (the AST's `node_tags`); the YAML anchor/alias
/// reference layer stays empty (no builder API populates it).
pub fn finish(self: *Builder, root: Node.Id) Allocator.Error!AST {
    const nodes = try self.nodes.toOwnedSlice(self.allocator);
    self.nodes = .empty;
    const owned_strings = try self.owned_strings.toOwnedSlice(self.allocator);
    self.owned_strings = .empty;
    var ast: AST = .{
        .allocator = self.allocator,
        .owned_strings = owned_strings,
        .root = root,
        .nodes = nodes,
    };
    if (self.any_comments) {
        // Freeze each growable pending run into the AST's plain-slice form.
        const table = try self.allocator.alloc(NodeComments, self.comments.items.len);
        errdefer self.allocator.free(table);
        var done: usize = 0;
        errdefer for (table[0..done]) |nc| {
            self.allocator.free(nc.leading);
            self.allocator.free(nc.dangling);
        };
        for (self.comments.items, table) |*src, *dst| {
            const leading = try src.leading.toOwnedSlice(self.allocator);
            errdefer self.allocator.free(leading);
            const dangling = try src.dangling.toOwnedSlice(self.allocator);
            dst.* = .{ .leading = leading, .trailing = src.trailing, .dangling = dangling };
            done += 1;
        }
        ast.node_comments = table;
    }
    if (self.any_tags) {
        ast.node_tags = try self.node_tags.toOwnedSlice(self.allocator);
        self.node_tags = .empty;
    }
    return ast;
}

/// A non-owning `AST` over the builder's current nodes, rooted at `root`.
/// The returned AST *borrows* the builder's storage: it is valid only while
/// the builder lives and stays unmodified, and must NOT be `deinit`ed (the
/// builder owns the memory). Use it to serialize or inspect an in-progress
/// build without consuming it; use `finish` when you want an owned AST.
///
/// Takes `*Builder` (not `*const`) and may fail: when the build carries
/// comments it rebuilds the `view_comments` scratch table (borrowing each
/// pending run's `.items`) so the AST sees plain `[]const NodeComments`.
pub fn view(self: *Builder, root: Node.Id) Allocator.Error!AST {
    var node_comments: []const NodeComments = &.{};
    if (self.any_comments) {
        self.view_comments.clearRetainingCapacity();
        try self.view_comments.ensureTotalCapacity(self.allocator, self.comments.items.len);
        for (self.comments.items) |*c|
            self.view_comments.appendAssumeCapacity(.{
                .leading = c.leading.items,
                .trailing = c.trailing,
                .dangling = c.dangling.items,
            });
        node_comments = self.view_comments.items;
    }
    const node_tags: []const ?AST.Tag = if (self.any_tags) self.node_tags.items else &.{};
    return .{
        .allocator = self.allocator,
        .owned_strings = self.owned_strings.items,
        .root = root,
        .nodes = self.nodes.items,
        .node_comments = node_comments,
        .node_tags = node_tags,
    };
}

// ── internals ───────────────────────────────────────────────────────────────

fn append(self: *Builder, kind: Node.Kind) Allocator.Error!Node.Id {
    const id: Node.Id = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{ .id = id, .kind = kind, .next_sibling = null });
    errdefer _ = self.nodes.pop();
    // Keep the comment/span tables the same length as `nodes` so `setComments`/
    // `setSpan` can index them directly. Costs one empty struct + one zero span
    // per node on every build.
    try self.comments.append(self.allocator, .{});
    try self.spans.append(self.allocator, Span.init(0, 0));
    return id;
}

/// Take ownership of an already-allocated string so the AST frees it on
/// `deinit`. On registration failure the string is freed, not leaked.
fn own(self: *Builder, owned: []const u8) Allocator.Error![]const u8 {
    errdefer self.allocator.free(owned);
    try self.owned_strings.append(self.allocator, owned);
    return owned;
}

/// Copy `s` into owned storage.
fn dupe(self: *Builder, s: []const u8) Allocator.Error![]const u8 {
    return self.own(try self.allocator.dupe(u8, s));
}

/// Chain `ids` as siblings (each `next_sibling` points to the next; the last
/// is terminated). The ids must already be in `nodes`.
fn link(self: *Builder, ids: []const Node.Id) void {
    if (ids.len == 0) return;
    for (ids[0 .. ids.len - 1], ids[1..]) |cur, next_id| {
        self.nodes.items[cur].next_sibling = next_id;
    }
    self.nodes.items[ids[ids.len - 1]].next_sibling = null;
}

test "Builder constructs an AST that serializes" {
    if (comptime !build_options.lang_json) return error.SkipZigTest;
    const testing = std.testing;
    var b = Builder.init(testing.allocator);
    defer b.deinit();

    // Build { "name": "fig", "nums": [1, 2] } bottom-up.
    const v_name = try b.addString("fig");
    const n1 = try b.addInt(1);
    const n2 = try b.addInt(2);
    const v_nums = try b.addSequence(&.{ n1, n2 });
    const k_name = try b.addString("name");
    const k_nums = try b.addString("nums");
    const root = try b.addMapping(&.{
        .{ .key = k_name, .value = v_name },
        .{ .key = k_nums, .value = v_nums },
    });

    var ast = try b.finish(root);
    defer ast.deinit();

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try ast.serialize(&w, .json);
    try testing.expectEqualStrings(
        \\{
        \\  "name": "fig",
        \\  "nums": [
        \\    1,
        \\    2
        \\  ]
        \\}
        \\
    , w.buffered());

    // Same AST, YAML — exercises the empty side-table (anchor/tag) guard path.
    if (comptime build_options.lang_yaml) {
        var ybuf: [256]u8 = undefined;
        var yw = std.Io.Writer.fixed(&ybuf);
        try ast.serialize(&yw, .yaml);
        try testing.expectEqualStrings(
            \\name: fig
            \\nums:
            \\- 1
            \\- 2
            \\
        , yw.buffered());
    }
}

test "Builder.setTag surfaces a normalized kind tag as a YAML core tag" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const testing = std.testing;
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const v = try b.addNumberRaw("09", false); // integer lexeme kept verbatim
    try b.setTag(v, .{ .kind = .integer });
    const k = try b.addString("id");
    const root = try b.addMapping(&.{.{ .key = k, .value = v }});
    var ast = try b.finish(root);
    defer ast.deinit();
    try testing.expect(ast.node_tags[v].?.kind == .integer);

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try ast.serialize(&w, .yaml);
    // A `.kind` tag renders as its YAML core-schema shorthand; the lexeme is kept.
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "!!int") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "09") != null);
}

test "strip_comments drops carried comments across formats" {
    if (comptime !build_options.lang_json) return error.SkipZigTest;
    var b = Builder.init(std.testing.allocator);
    defer b.deinit();
    const v = try b.addString("fig");
    const k = try b.addString("name");
    try b.setComments(k, .{ .leading = &.{.{ .text = "hi", .style = .line }} });
    const root = try b.addMapping(&.{.{ .key = k, .value = v }});
    var ast = try b.finish(root);
    defer ast.deinit();

    // Default: comment preserved (JSON5).
    var kept: Writer.Allocating = .init(std.testing.allocator);
    defer kept.deinit();
    try ast.serializeWith(&kept.writer, .json5, .{});
    try std.testing.expect(std.mem.indexOf(u8, kept.written(), "// hi") != null);

    // Stripped: same AST, no comment, in JSON5 and (an options-less printer) YAML.
    var stripped: Writer.Allocating = .init(std.testing.allocator);
    defer stripped.deinit();
    try ast.serializeWith(&stripped.writer, .json5, .{ .strip_comments = true });
    try std.testing.expect(std.mem.indexOf(u8, stripped.written(), "hi") == null);

    if (comptime build_options.lang_yaml) {
        var y: Writer.Allocating = .init(std.testing.allocator);
        defer y.deinit();
        try ast.serializeWith(&y.writer, .yaml, .{ .strip_comments = true });
        try std.testing.expectEqualStrings("name: fig\n", y.written());
    }
}

test "Builder incremental comment helpers append and serialize" {
    if (comptime !build_options.lang_json) return error.SkipZigTest;
    var b = Builder.init(std.testing.allocator);
    defer b.deinit();

    const v = try b.addNumberRaw("1", false);
    const k = try b.addString("a");
    // Two leading comments accumulate in call order; a trailing rides the value.
    try b.addLeadingComment(k, .{ .text = "first" });
    try b.addLeadingComment(k, .{ .text = "second" });
    try b.setTrailingComment(v, .{ .text = "tail" });
    const root = try b.addMapping(&.{.{ .key = k, .value = v }});
    // A dangling comment sits at the end of the mapping body.
    try b.addDanglingComment(root, .{ .text = "end" });

    var ast = try b.finish(root);
    defer ast.deinit();

    // The leading run kept insertion order and the trailing/dangling bound too.
    const kc = ast.comments(k);
    try std.testing.expectEqual(@as(usize, 2), kc.leading.len);
    try std.testing.expectEqualStrings("first", kc.leading[0].text);
    try std.testing.expectEqualStrings("second", kc.leading[1].text);
    try std.testing.expectEqualStrings("tail", ast.comments(v).trailing.?.text);
    try std.testing.expectEqualStrings("end", ast.comments(root).dangling[0].text);

    // A comment-bearing format renders them; this also proves the runs are valid.
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try ast.serializeWith(&out.writer, .json5, .{});
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "// first") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "// second") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "// tail") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "// end") != null);
}
