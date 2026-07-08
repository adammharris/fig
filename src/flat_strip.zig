//! Lossy-mode stripping for fig's three flat/shallow-only output formats —
//! INI, dotenv, `.properties`: drop whatever their capability model can't
//! hold at all before printing, so the printer never aborts a document
//! partway through. Same warn-then-strip-then-print contract as
//! `lossless.zig`'s `lossyStrip` (the CLI runs `diagnostics.analyze` first to
//! warn, then this, exactly mirroring TOML's existing `null`-stripping path in
//! `cli/actions.zig`'s `runGet`).
//!
//! Kept as its own small pass rather than folded into `Lossless.Target`/
//! `lossyStrip` because the capability rule here is DEPTH-based (a mapping
//! nested past some per-format limit) rather than scalar-kind-based —
//! bolting a depth parameter onto `Lossless.isUnrepresentable` for the sake of
//! three formats would complicate it for the other four (json/yaml/toml/zon),
//! which have no nesting-depth limit at all. Reuses `lossless.zig`'s
//! `emit`/`carry`/`link` node-building primitives (`pub` there for exactly
//! this) rather than a third copy of that plumbing.
//!
//! MUST stay in sync with `diagnostics.zig`'s matching `.ini`/`.dotenv`/
//! `.properties` `valueLoss` arms: that pass reports exactly what this one
//! removes (a `null` or a `sequence` at any depth; a `mapping` nested past
//! `maxMappingDepth`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("ast/ast.zig");
const Lossless = @import("lossless.zig");
const Id = AST.Node.Id;

pub const Error = Allocator.Error;

pub const Format = enum { ini, dotenv, properties };

/// How many levels of mapping nesting `format` can still represent: INI holds
/// a root mapping plus one level of `[section]`s; dotenv/`.properties` are
/// flat (the root mapping itself, nothing nested under it).
fn maxMappingDepth(format: Format) usize {
    return switch (format) {
        .ini => 1,
        .dotenv, .properties => 0,
    };
}

/// `depth` is the node's OWN depth (0 = document root), matching
/// `diagnostics.zig`'s `valueLoss` exactly.
fn isUnrepresentable(kind: AST.Node.Kind, depth: usize, max_mapping_depth: usize) bool {
    return switch (kind) {
        .null_, .sequence => true,
        .mapping => depth > max_mapping_depth,
        else => false,
    };
}

/// The result of a `lossyStrip`: a new AST with every node `format` can't
/// represent removed, plus the dot/`[i]` paths of what was dropped (for
/// warnings — though the CLI's `diagnostics.analyze` pass, run first, already
/// covers that). `ast` is null only when `root_id` ITSELF is unrepresentable
/// (a bare array/`null` root, or a root mapping if `format` somehow limited
/// depth to less than 0 — never happens today, kept for shape parity with
/// `Lossless.StripResult`).
pub const StripResult = struct {
    ast: ?AST,
    dropped: []const []const u8,
};

/// Build a fresh AST in `arena` rooted at the subtree `root_id`, dropping
/// every mapping entry/sequence element `format` can't represent at all.
/// Dropped paths are reported relative to `root_id`.
pub fn lossyStrip(arena: Allocator, ast: *const AST, root_id: Id, format: Format) Error!StripResult {
    const max_depth = maxMappingDepth(format);
    var s = Stripper{ .src = ast, .arena = arena, .max_mapping_depth = max_depth };
    if (isUnrepresentable(ast.nodes[root_id].kind, 0, max_depth)) {
        try s.dropped.append(arena, "(value)");
        return .{ .ast = null, .dropped = try s.dropped.toOwnedSlice(arena) };
    }
    const root = try s.copy(ast.nodes[root_id], "", 0);
    var stripped: AST = .{ .allocator = arena, .root = root, .nodes = try s.out.toOwnedSlice(arena) };
    if (s.any_comments) stripped.node_comments = try s.out_comments.toOwnedSlice(arena);
    return .{ .ast = stripped, .dropped = try s.dropped.toOwnedSlice(arena) };
}

const Stripper = struct {
    src: *const AST,
    arena: Allocator,
    max_mapping_depth: usize,
    out: std.ArrayList(AST.Node) = .empty,
    out_comments: std.ArrayList(AST.NodeComments) = .empty,
    any_comments: bool = false,
    dropped: std.ArrayList([]const u8) = .empty,

    /// `node` is never itself unrepresentable here — the caller (`lossyStrip`
    /// for the root, `copyMap` for every child) always checks
    /// `isUnrepresentable` before recursing into a node, so a `.sequence` (or
    /// a `.mapping` past the depth limit) is skipped/dropped at the PARENT
    /// and this is never reached with one.
    fn copy(self: *Stripper, node: AST.Node, path: []const u8, depth: usize) Error!Id {
        switch (node.kind) {
            .mapping => return self.copyMap(node, path, depth),
            .sequence => unreachable, // always unrepresentable — see the doc above
            .keyvalue => unreachable, // never a value position
            else => {
                const id = try Lossless.emit(self, node.kind);
                try Lossless.carry(self, node.id, id);
                return id;
            },
        }
    }

    fn copyMap(self: *Stripper, src_node: AST.Node, path: []const u8, depth: usize) Error!Id {
        const id = try Lossless.emit(self, .{ .mapping = null });
        try Lossless.carry(self, src_node.id, id);
        var last: ?Id = null;
        var c = src_node.kind.mapping;
        while (c) |cid| : (c = self.src.nodes[cid].next_sibling) {
            const kv = self.src.nodes[cid].kind.keyvalue;
            const child_path = try self.keyPath(path, kv.key);
            if (isUnrepresentable(self.src.nodes[kv.value].kind, depth + 1, self.max_mapping_depth)) {
                try self.dropped.append(self.arena, child_path);
                continue;
            }
            const new_key = try self.copy(self.src.nodes[kv.key], path, depth);
            const new_val = try self.copy(self.src.nodes[kv.value], child_path, depth + 1);
            const kvid = try Lossless.emit(self, .{ .keyvalue = .{ .key = new_key, .value = new_val } });
            Lossless.link(&self.out, id, &last, kvid, .mapping);
        }
        return id;
    }

    fn keyPath(self: *Stripper, parent: []const u8, key_id: Id) Error![]const u8 {
        const name = switch (self.src.nodes[key_id].kind) {
            .string => |s| s,
            else => "?",
        };
        if (parent.len == 0) return self.arena.dupe(u8, name);
        return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ parent, name });
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "drops an array at any depth, keeps everything else" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = AST.Builder.init(a);
    defer b.deinit();
    const arr = try b.addSequence(&.{try b.addInt(1)});
    const arr_key = try b.addString("list");
    const scalar_key = try b.addString("name");
    const scalar_val = try b.addString("fig");
    const root = try b.addMapping(&.{ .{ .key = scalar_key, .value = scalar_val }, .{ .key = arr_key, .value = arr } });
    var ast = try b.finish(root);
    defer ast.deinit();

    const result = try lossyStrip(arena, &ast, ast.root, .dotenv);
    try testing.expectEqual(@as(usize, 1), result.dropped.len);
    try testing.expectEqualStrings("list", result.dropped[0]);
    const stripped = result.ast.?;
    const v = try AST.getValByPath(&stripped, &.{.{ .key = "name" }});
    try testing.expectEqualStrings("fig", v.kind.string);
    try testing.expectError(error.NotFound, AST.getValByPath(&stripped, &.{.{ .key = "list" }}));
}

test "INI keeps one level of mapping nesting, drops the next" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = AST.Builder.init(a);
    defer b.deinit();
    const inner_key = try b.addString("deep");
    const inner_val = try b.addString("x");
    const inner = try b.addMapping(&.{.{ .key = inner_key, .value = inner_val }});
    const section_key = try b.addString("server");
    const host_key = try b.addString("host");
    const host_val = try b.addString("localhost");
    const nested_key = try b.addString("nested");
    const section = try b.addMapping(&.{ .{ .key = host_key, .value = host_val }, .{ .key = nested_key, .value = inner } });
    const root = try b.addMapping(&.{.{ .key = section_key, .value = section }});
    var ast = try b.finish(root);
    defer ast.deinit();

    const result = try lossyStrip(arena, &ast, ast.root, .ini);
    try testing.expectEqual(@as(usize, 1), result.dropped.len);
    try testing.expectEqualStrings("server.nested", result.dropped[0]);
    const stripped = result.ast.?;
    const host = try AST.getValByPath(&stripped, &.{ .{ .key = "server" }, .{ .key = "host" } });
    try testing.expectEqualStrings("localhost", host.kind.string);
    try testing.expectError(error.NotFound, AST.getValByPath(&stripped, &.{ .{ .key = "server" }, .{ .key = "nested" } }));
}

test "a bare array root has nothing to print" {
    const a = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var b = AST.Builder.init(a);
    defer b.deinit();
    const root = try b.addSequence(&.{try b.addInt(1)});
    var ast = try b.finish(root);
    defer ast.deinit();

    const result = try lossyStrip(arena, &ast, ast.root, .properties);
    try testing.expectEqual(@as(?AST, null), result.ast);
    try testing.expectEqual(@as(usize, 1), result.dropped.len);
}
