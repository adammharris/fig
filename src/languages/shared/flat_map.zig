//! Shared "flat mapping" builder for line-oriented `key = value` formats —
//! INI, dotenv, `.properties`. Each of those parsers needs exactly the glue
//! TOML's parser (`languages/toml/parser.zig`) hand-rolls for itself
//! (`addNode`/`appendKeyValue`/`lookupChild`), minus everything TOML needs
//! that they don't: dotted keys, arrays, inline tables, typed scalars. This
//! module factors out the part that's actually identical — node allocation and
//! "does this mapping already have a child keyed X" — so the three new
//! parsers (and INI's one-level section nesting) share it instead of each
//! re-copying TOML's copy a fourth/fifth/sixth time.
//!
//! What's deliberately NOT here: comment capture (each parser's leading/
//! trailing rules differ enough — see each tokenizer's module doc — to stay
//! bespoke) and value decoding (escape sets conflict across the three
//! formats). Only the tree-shape plumbing is shared.

const std = @import("std");
const AST = @import("../../ast/ast.zig");
const Span = @import("../../util/span.zig");

/// Owns the three parallel node-indexed arrays every fig parser builds
/// (`nodes`, `spans`, `node_comments`) and the one operation that allocates a
/// new node id across all three in lockstep. Mirrors TOML's `Parser.addNode`
/// exactly, pulled out so it isn't a fourth private copy.
pub const NodeArena = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(AST.Node) = .empty,
    spans: std.ArrayList(Span) = .empty,
    node_comments: std.ArrayList(AST.NodeComments) = .empty,

    pub fn addNode(self: *NodeArena, kind: AST.Node.Kind, span: Span) std.mem.Allocator.Error!AST.Node.Id {
        const id: AST.Node.Id = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{ .id = id, .kind = kind });
        try self.spans.append(self.allocator, span);
        try self.node_comments.append(self.allocator, .{});
        return id;
    }

    /// Release all three arrays. Does NOT free `owned_strings` or comment
    /// slices — those stay the caller's responsibility (same split TOML's
    /// parser makes between its node arrays and `owned_strings`), since a
    /// caller building toward a `Document` may still want those on a
    /// successful return.
    pub fn deinit(self: *NodeArena) void {
        self.nodes.deinit(self.allocator);
        self.spans.deinit(self.allocator);
        self.node_comments.deinit(self.allocator);
    }
};

/// The keyvalue child of `map_id` keyed `key`, or null. Linear scan of the
/// sibling chain: these formats produce flat (INI: one level deep) tables, so
/// there's no scale where this needs to be better than O(n).
pub fn lookupChild(nodes: []const AST.Node, map_id: AST.Node.Id, key: []const u8) ?AST.Node.Id {
    var cur = nodes[map_id].kind.mapping;
    while (cur) |id| : (cur = nodes[id].next_sibling) {
        const kv = nodes[id].kind.keyvalue;
        if (std.mem.eql(u8, nodes[kv.key].kind.string, key)) return id;
    }
    return null;
}

/// How a repeated key is handled. Every INI/dotenv/`.properties` implementation
/// in the wild silently lets the later assignment win — unlike TOML, which
/// hard-errors — so `.overwrite` is what all three callers actually want;
/// `.err` is kept for symmetry / a future strict dialect.
pub const DuplicatePolicy = enum { overwrite, err };
pub const DuplicateError = error{DuplicateKey};

/// Add (or, on a repeat with `.overwrite`, update) a `key = value` entry in
/// mapping `map_id`. `key_id` must already be a `.string` node (each caller
/// allocates it via its own `arena.addNode` so it can attach leading comments
/// first, same as TOML's `appendKeyValue`).
///
/// `.overwrite` keeps the FIRST-SEEN position but the LAST-ASSIGNED value —
/// repointing the existing keyvalue node's `value` in place — which is the one
/// substantive behavioral difference from TOML's `appendKeyValue` this module
/// exists to capture. Returns whether this was a fresh entry or a repeat, so a
/// caller can turn a repeat into a `DuplicateKey` warning (real content, likely
/// a mistake) without it being a parse *error*.
pub const PutResult = enum { added, overwrote };

pub fn putEntry(
    arena: *NodeArena,
    map_id: AST.Node.Id,
    key_id: AST.Node.Id,
    value_id: AST.Node.Id,
    policy: DuplicatePolicy,
) (DuplicateError || std.mem.Allocator.Error)!PutResult {
    const key = arena.nodes.items[key_id].kind.string;
    if (lookupChild(arena.nodes.items, map_id, key)) |existing_kv| {
        switch (policy) {
            .err => return error.DuplicateKey,
            .overwrite => {
                arena.nodes.items[existing_kv].kind.keyvalue.value = value_id;
                return .overwrote;
            },
        }
    }
    const kv_id = try arena.addNode(
        .{ .keyvalue = .{ .key = key_id, .value = value_id } },
        Span.init(arena.spans.items[key_id].start, arena.spans.items[value_id].end),
    );
    if (arena.nodes.items[map_id].kind.mapping) |first| {
        var last = first;
        while (arena.nodes.items[last].next_sibling) |n| last = n;
        arena.nodes.items[last].next_sibling = kv_id;
    } else {
        arena.nodes.items[map_id].kind = .{ .mapping = kv_id };
    }
    return .added;
}

test "putEntry appends in order and reports fresh vs. repeat" {
    const a = std.testing.allocator;
    var arena: NodeArena = .{ .allocator = a };
    defer arena.deinit();

    const root = try arena.addNode(.{ .mapping = null }, Span.init(0, 0));
    const k1 = try arena.addNode(.{ .string = "a" }, Span.init(0, 1));
    const v1 = try arena.addNode(.{ .string = "1" }, Span.init(2, 3));
    try std.testing.expectEqual(PutResult.added, try putEntry(&arena, root, k1, v1, .overwrite));

    const k2 = try arena.addNode(.{ .string = "b" }, Span.init(4, 5));
    const v2 = try arena.addNode(.{ .string = "2" }, Span.init(6, 7));
    try std.testing.expectEqual(PutResult.added, try putEntry(&arena, root, k2, v2, .overwrite));

    // Repeat of "a": overwrites in place, first-seen position preserved.
    const k3 = try arena.addNode(.{ .string = "a" }, Span.init(8, 9));
    const v3 = try arena.addNode(.{ .string = "3" }, Span.init(10, 11));
    try std.testing.expectEqual(PutResult.overwrote, try putEntry(&arena, root, k3, v3, .overwrite));

    const first = arena.nodes.items[root].kind.mapping.?;
    try std.testing.expectEqual(k1, arena.nodes.items[first].kind.keyvalue.key);
    try std.testing.expectEqual(v3, arena.nodes.items[first].kind.keyvalue.value); // last value wins
    const second = arena.nodes.items[first].next_sibling.?;
    try std.testing.expectEqual(k2, arena.nodes.items[second].kind.keyvalue.key);
    try std.testing.expectEqual(null, arena.nodes.items[second].next_sibling); // no 3rd sibling appended
}

test "putEntry .err rejects a repeat" {
    const a = std.testing.allocator;
    var arena: NodeArena = .{ .allocator = a };
    defer arena.deinit();
    const root = try arena.addNode(.{ .mapping = null }, Span.init(0, 0));
    const k1 = try arena.addNode(.{ .string = "a" }, Span.init(0, 1));
    const v1 = try arena.addNode(.{ .string = "1" }, Span.init(2, 3));
    _ = try putEntry(&arena, root, k1, v1, .err);
    const k2 = try arena.addNode(.{ .string = "a" }, Span.init(4, 5));
    const v2 = try arena.addNode(.{ .string = "2" }, Span.init(6, 7));
    try std.testing.expectError(error.DuplicateKey, putEntry(&arena, root, k2, v2, .err));
}
