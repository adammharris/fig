//! Lossless cross-format conversion via a reserved "$fig" envelope.
//!
//! Converting between formats normally degrades any value the target format has
//! no native form for: a `null` bound for TOML, a TOML datetime bound for JSON,
//! a ZON enum/char literal bound for anything else. Lossless mode preserves these
//! by wrapping the value in an ordinary mapping carrying a reserved sentinel key,
//! which a later fig run recognizes and reconstructs.
//!
//! Two AST passes implement it, both format-agnostic:
//!   - `encode` runs BEFORE printing. It rewrites every node the *target* format
//!     can't represent natively (`needsEnvelope`) into a `{ "$fig": { … } }`
//!     mapping. Nodes the target can hold (a `null` for JSON, a datetime for
//!     TOML) are left untouched, so idiomatic output is preserved where possible.
//!   - `decode` runs AFTER parsing. It recognizes the envelope shape in the
//!     parsed AST and rebuilds the original node kind.
//!
//! The CLI gates BOTH on `--lossless` (symmetric): a round-trip is `--lossless`
//! on each leg. By default neither runs, so a literal `$fig` key in real data is
//! treated as ordinary data both ways.
//!
//! A third pass, `lossyStrip`, is the LOSSY counterpart used when `--lossless` is
//! off: rather than the printer aborting mid-document on a value the target can't
//! represent at all (a `null` for TOML — datetimes/enums merely degrade, they
//! don't error), it removes that value up front and returns the dropped paths so
//! the CLI can warn. Output stays valid and complete; nothing is half-written.
//!
//! SCOPE (this pass): `null` and the `extended` scalars (TOML datetimes, ZON
//! enum/char literals). The YAML reference layer (custom tags, anchors, aliases)
//! is a separate future pass — those need side-table reconstruction; these are
//! pure node-kind transforms.
//!
//! Envelope schema, as it appears once parsed back into an AST:
//!   { "$fig": { "t": "<type>" } }            // a null
//!   { "$fig": { "t": "<extkind>", "v": "<text>" } }   // an extended scalar
//! where `<type>` is `"null"` and `<extkind>` is the `ExtKind` field name
//! (`offset_datetime`, `enum_literal`, …). `v` carries the scalar's intrinsic
//! text verbatim (for a char literal, its decimal codepoint, as fig stores it).

const std = @import("std");
const Allocator = std.mem.Allocator;
const AST = @import("ast/ast.zig");

const Id = AST.Node.Id;
const ExtKind = AST.Node.Kind.Extended.ExtKind;

/// The reserved key marking a lossless envelope. Chosen to be unlikely in real
/// config data; a real mapping that exactly mimics the envelope shape would be
/// mis-decoded (a documented limitation — escaping is a future concern).
const sentinel = "$fig";

/// The output format an `encode` pass targets. `jsonc` collapses to `json` and
/// `yml` to `yaml` for capability purposes (same type system).
pub const Target = enum { json, yaml, toml, zon };

pub const Error = Allocator.Error;

/// Does `target` need the lossless envelope to represent `kind` without loss?
/// True only for the scalar kinds the target can't hold natively; every other
/// kind (and any container) is copied through verbatim.
pub fn needsEnvelope(target: Target, kind: AST.Node.Kind) bool {
    return switch (kind) {
        // Only TOML lacks a null. JSON/YAML/ZON all have one.
        .null_ => target == .toml,
        .extended => |e| switch (target) {
            // TOML has the four datetimes and inf/nan floats natively;
            // enum/char it does not.
            .toml => switch (e.kind) {
                .offset_datetime, .local_datetime, .local_date, .local_time => false,
                .number_special => false,
                .enum_literal, .char_literal => true,
            },
            // ZON has enum and char literals natively; datetimes and the
            // non-finite floats it does not.
            .zon => switch (e.kind) {
                .enum_literal, .char_literal => false,
                .offset_datetime, .local_datetime, .local_date, .local_time => true,
                .number_special => true,
            },
            // Neither JSON nor YAML's core schema has any of these.
            .json, .yaml => true,
        },
        else => false,
    };
}

/// Whether `target` cannot represent `kind` AT ALL (even degraded) — the values
/// the lossy `lossyStrip` pass removes. Distinct from `needsEnvelope`: a TOML
/// datetime → JSON is a `needsEnvelope` case (degrades to a string in lossy mode,
/// no data type lost beyond the tag) but NOT unrepresentable. Only a `null`
/// bound for TOML is genuinely unrepresentable today.
pub fn isUnrepresentable(target: Target, kind: AST.Node.Kind) bool {
    return target == .toml and kind == .null_;
}

// ── Public entry points ─────────────────────────────────────────────────────

/// Build a fresh AST in `arena` where every node `target` can't represent
/// natively is wrapped in a `$fig` envelope. Strings borrow from `ast` (and its
/// source), so the result must not outlive them.
pub fn encode(arena: Allocator, ast: *const AST, target: Target) Error!AST {
    var e = Encoder{ .src = ast, .arena = arena, .target = target };
    const root = try e.copy(ast.nodes[ast.root]);
    var result: AST = .{ .allocator = arena, .root = root, .nodes = try e.out.toOwnedSlice(arena) };
    if (e.any_comments) result.node_comments = try e.out_comments.toOwnedSlice(arena);
    return result;
}

/// Build a fresh AST in `arena` where every `$fig` envelope is reconstructed to
/// the node kind it encodes. A mapping that doesn't match the envelope shape (or
/// carries an unknown type tag) is copied through as ordinary data.
pub fn decode(arena: Allocator, ast: *const AST) Error!AST {
    var d = Decoder{ .src = ast, .arena = arena };
    const root = try d.copy(ast.nodes[ast.root]);
    var result: AST = .{ .allocator = arena, .root = root, .nodes = try d.out.toOwnedSlice(arena) };
    if (d.any_comments) result.node_comments = try d.out_comments.toOwnedSlice(arena);
    return result;
}

/// The result of a `lossyStrip`: a new AST with every node the target can't
/// represent removed, plus the dot/bracket paths of what was dropped (for
/// warnings). `ast` is null only when the navigated root node was ITSELF
/// unrepresentable (a bare `null` → TOML), in which case there is nothing to
/// print and `dropped` names it.
pub const StripResult = struct {
    ast: ?AST,
    dropped: []const []const u8,
};

/// Build a fresh AST in `arena` rooted at the subtree `root_id`, dropping every
/// mapping entry and sequence element the target can't represent at all (today:
/// a `null` for TOML). Used in lossy mode so the printer never aborts a document
/// partway through. Dropped paths are reported relative to `root_id`.
pub fn lossyStrip(arena: Allocator, ast: *const AST, root_id: Id, target: Target) Error!StripResult {
    var s = Stripper{ .src = ast, .arena = arena, .target = target };
    if (isUnrepresentable(target, ast.nodes[root_id].kind)) {
        try s.dropped.append(arena, "(value)");
        return .{ .ast = null, .dropped = try s.dropped.toOwnedSlice(arena) };
    }
    const root = try s.copy(ast.nodes[root_id], "");
    var stripped: AST = .{ .allocator = arena, .root = root, .nodes = try s.out.toOwnedSlice(arena) };
    if (s.any_comments) stripped.node_comments = try s.out_comments.toOwnedSlice(arena);
    return .{
        .ast = stripped,
        .dropped = try s.dropped.toOwnedSlice(arena),
    };
}

// ── Encoder ─────────────────────────────────────────────────────────────────

const Encoder = struct {
    src: *const AST,
    arena: Allocator,
    target: Target,
    out: std.ArrayList(AST.Node) = .empty,
    out_comments: std.ArrayList(AST.NodeComments) = .empty,
    any_comments: bool = false,

    fn copy(self: *Encoder, node: AST.Node) Error!Id {
        switch (node.kind) {
            .sequence => return copySeq(self, node),
            .mapping => return copyMap(self, node),
            .keyvalue => unreachable, // keyvalues are only reached inside copyMap
            else => {},
        }
        // A leaf scalar. If it needs enveloping, the value's comments ride on the
        // wrapping mapping; otherwise they ride on the copied scalar.
        const id = if ((node.kind == .null_ or node.kind == .extended) and needsEnvelope(self.target, node.kind))
            try self.envelope(node.kind)
        else
            try emit(self, node.kind);
        try carry(self, node.id, id);
        return id;
    }

    /// Emit `{ "$fig": { "t": <type>, ["v": <text>] } }` for a null/extended
    /// node, leaves first so child ids precede their containers.
    fn envelope(self: *Encoder, kind: AST.Node.Kind) Error!Id {
        const type_name: []const u8 = switch (kind) {
            .null_ => "null",
            .extended => |e| @tagName(e.kind),
            else => unreachable,
        };
        const text: ?[]const u8 = switch (kind) {
            .extended => |e| e.text,
            else => null,
        };

        const t_key = try emit(self, .{ .string = "t" });
        const t_val = try emit(self, .{ .string = type_name });
        const t_kv = try emit(self, .{ .keyvalue = .{ .key = t_key, .value = t_val } });
        if (text) |vt| {
            const v_key = try emit(self, .{ .string = "v" });
            const v_val = try emit(self, .{ .string = vt });
            const v_kv = try emit(self, .{ .keyvalue = .{ .key = v_key, .value = v_val } });
            self.out.items[t_kv].next_sibling = v_kv;
        }
        const inner = try emit(self, .{ .mapping = t_kv });
        const s_key = try emit(self, .{ .string = sentinel });
        const fig_kv = try emit(self, .{ .keyvalue = .{ .key = s_key, .value = inner } });
        return emit(self, .{ .mapping = fig_kv });
    }
};

// ── Decoder ─────────────────────────────────────────────────────────────────

const Decoder = struct {
    src: *const AST,
    arena: Allocator,
    out: std.ArrayList(AST.Node) = .empty,
    out_comments: std.ArrayList(AST.NodeComments) = .empty,
    any_comments: bool = false,

    fn copy(self: *Decoder, node: AST.Node) Error!Id {
        switch (node.kind) {
            .mapping => {
                // A decoded envelope collapses the wrapper mapping back to a
                // scalar; the wrapper's comments move onto that scalar.
                if (self.envelopeKind(node)) |kind| {
                    const id = try emit(self, kind);
                    try carry(self, node.id, id);
                    return id;
                }
                return copyMap(self, node);
            },
            .sequence => return copySeq(self, node),
            .keyvalue => unreachable,
            else => {
                const id = try emit(self, node.kind);
                try carry(self, node.id, id);
                return id;
            },
        }
    }

    /// If `node` is a well-formed `$fig` envelope, return the node kind it
    /// encodes; otherwise null (so it is copied through as ordinary data). The
    /// envelope must be a mapping whose ONLY entry is the sentinel key mapping to
    /// an inner mapping carrying a string `t` (and, for extended scalars, `v`).
    fn envelopeKind(self: *Decoder, node: AST.Node) ?AST.Node.Kind {
        const first = node.kind.mapping orelse return null;
        const entry = self.src.nodes[first];
        if (entry.next_sibling != null) return null; // more than one key → not an envelope
        const kv = entry.kind.keyvalue;
        const key = self.src.nodes[kv.key];
        if (key.kind != .string or !std.mem.eql(u8, key.kind.string, sentinel)) return null;
        const inner = self.src.nodes[kv.value];
        if (inner.kind != .mapping) return null;

        var type_name: ?[]const u8 = null;
        var text: ?[]const u8 = null;
        var c = inner.kind.mapping;
        while (c) |cid| : (c = self.src.nodes[cid].next_sibling) {
            const ikv = self.src.nodes[cid].kind.keyvalue;
            const ik = self.src.nodes[ikv.key];
            if (ik.kind != .string) continue;
            const val: ?[]const u8 = switch (self.src.nodes[ikv.value].kind) {
                .string => |s| s,
                else => null,
            };
            if (std.mem.eql(u8, ik.kind.string, "t")) {
                type_name = val;
            } else if (std.mem.eql(u8, ik.kind.string, "v")) {
                text = val;
            }
        }

        const t = type_name orelse return null;
        if (std.mem.eql(u8, t, "null")) return .null_;
        if (std.meta.stringToEnum(ExtKind, t)) |ek|
            return .{ .extended = .{ .kind = ek, .text = text orelse "" } };
        return null; // unknown type tag → leave as ordinary mapping
    }
};

// ── Stripper (lossy) ─────────────────────────────────────────────────────────

const Stripper = struct {
    src: *const AST,
    arena: Allocator,
    target: Target,
    out: std.ArrayList(AST.Node) = .empty,
    out_comments: std.ArrayList(AST.NodeComments) = .empty,
    any_comments: bool = false,
    dropped: std.ArrayList([]const u8) = .empty,

    fn copy(self: *Stripper, node: AST.Node, path: []const u8) Error!Id {
        switch (node.kind) {
            .mapping => return self.copyMap(node, path),
            .sequence => return self.copySeq(node, path),
            .keyvalue => unreachable,
            else => {
                const id = try emit(self, node.kind);
                try carry(self, node.id, id);
                return id;
            },
        }
    }

    fn copyMap(self: *Stripper, src_node: AST.Node, path: []const u8) Error!Id {
        const id = try emit(self, .{ .mapping = null });
        try carry(self, src_node.id, id);
        var last: ?Id = null;
        var c = src_node.kind.mapping;
        while (c) |cid| : (c = self.src.nodes[cid].next_sibling) {
            const kv = self.src.nodes[cid].kind.keyvalue;
            const child_path = try self.keyPath(path, kv.key);
            if (isUnrepresentable(self.target, self.src.nodes[kv.value].kind)) {
                try self.dropped.append(self.arena, child_path);
                continue;
            }
            const new_key = try self.copy(self.src.nodes[kv.key], path);
            const new_val = try self.copy(self.src.nodes[kv.value], child_path);
            const kvid = try emit(self, .{ .keyvalue = .{ .key = new_key, .value = new_val } });
            link(&self.out, id, &last, kvid, .mapping);
        }
        return id;
    }

    fn copySeq(self: *Stripper, src_node: AST.Node, path: []const u8) Error!Id {
        const id = try emit(self, .{ .sequence = null });
        try carry(self, src_node.id, id);
        var last: ?Id = null;
        var c = src_node.kind.sequence;
        var i: usize = 0;
        while (c) |cid| : (c = self.src.nodes[cid].next_sibling) {
            const child_path = try indexPath(self.arena, path, i);
            i += 1;
            if (isUnrepresentable(self.target, self.src.nodes[cid].kind)) {
                try self.dropped.append(self.arena, child_path);
                continue;
            }
            const new_id = try self.copy(self.src.nodes[cid], child_path);
            link(&self.out, id, &last, new_id, .sequence);
        }
        return id;
    }

    /// `parent.key` (or just `key` at the root). A non-string key shows as `?`
    /// (it can't be a drop target — only its value can — so this is purely a hint).
    fn keyPath(self: *Stripper, parent: []const u8, key_id: Id) Error![]const u8 {
        const name = switch (self.src.nodes[key_id].kind) {
            .string => |s| s,
            else => "?",
        };
        if (parent.len == 0) return self.arena.dupe(u8, name);
        return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ parent, name });
    }
};

fn indexPath(arena: Allocator, parent: []const u8, i: usize) Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}[{d}]", .{ parent, i });
}

// ── Shared node-building helpers (duck-typed over Encoder/Decoder/Stripper) ──

fn emit(self: anytype, kind: AST.Node.Kind) Error!Id {
    const id: Id = @intCast(self.out.items.len);
    try self.out.append(self.arena, .{ .id = id, .kind = kind, .next_sibling = null });
    // Keep the comment table parallel to `out`; synthetic nodes (envelope
    // wrappers, decoded scalars) get the empty default and may be filled by a
    // later `carry`.
    try self.out_comments.append(self.arena, .{});
    return id;
}

/// Copy the comments bound to source node `src_id` onto the freshly emitted node
/// `new_id`. The `leading` slice is re-duped into the arena; comment text borrows
/// the source AST (which the arena outlives). Duck-typed over the three passes.
fn carry(self: anytype, src_id: Id, new_id: Id) Error!void {
    const c = self.src.comments(src_id);
    if (c.isEmpty()) return;
    self.out_comments.items[new_id] = .{
        .leading = try self.arena.dupe(AST.Comment, c.leading),
        .trailing = c.trailing,
        .dangling = try self.arena.dupe(AST.Comment, c.dangling),
    };
    self.any_comments = true;
}

fn copySeq(self: anytype, src_node: AST.Node) Error!Id {
    const id = try emit(self, .{ .sequence = null });
    try carry(self, src_node.id, id);
    var last: ?Id = null;
    var c = src_node.kind.sequence;
    while (c) |cid| : (c = self.src.nodes[cid].next_sibling) {
        const new_id = try self.copy(self.src.nodes[cid]);
        link(&self.out, id, &last, new_id, .sequence);
    }
    return id;
}

fn copyMap(self: anytype, src_node: AST.Node) Error!Id {
    const id = try emit(self, .{ .mapping = null });
    try carry(self, src_node.id, id);
    var last: ?Id = null;
    var c = src_node.kind.mapping;
    while (c) |cid| : (c = self.src.nodes[cid].next_sibling) {
        const kv = self.src.nodes[cid].kind.keyvalue;
        const new_key = try self.copy(self.src.nodes[kv.key]);
        const new_val = try self.copy(self.src.nodes[kv.value]);
        const kvid = try emit(self, .{ .keyvalue = .{ .key = new_key, .value = new_val } });
        link(&self.out, id, &last, kvid, .mapping);
    }
    return id;
}

/// Append `child` to container `container`, threading `next_sibling`.
fn link(out: *std.ArrayList(AST.Node), container: Id, last: *?Id, child: Id, comptime kind: enum { sequence, mapping }) void {
    if (last.*) |p| {
        out.items[p].next_sibling = child;
    } else {
        out.items[container].kind = switch (kind) {
            .sequence => .{ .sequence = child },
            .mapping => .{ .mapping = child },
        };
    }
    last.* = child;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const JsonParser = @import("json/parser.zig");
const JsonPrinter = @import("json/printer.zig");
// The native parser is the AST-literal syntax for tests whose subject isn't a
// particular format (here: null-stripping), so they don't depend on JSON reading.
const NativeParser = @import("native/parser.zig");
const TomlParser = @import("toml/parser.zig");
const TomlPrinter = @import("toml/printer.zig");
const ZonParser = @import("zon/parser.zig");
const ZonPrinter = @import("zon/printer.zig");

/// Parse `input` with `Parser`, run `decode` then `encode(target)`, print with
/// `Printer`, all inside `arena`. Returns the printed bytes (arena-owned).
fn convert(
    arena: Allocator,
    comptime Parser: type,
    src_type: anytype,
    comptime Printer: type,
    target: Target,
    input: []const u8,
) ![]const u8 {
    var ast = try Parser.parseAbstract(arena, input, src_type);
    const decoded = try decode(arena, &ast);
    const encoded = try encode(arena, &decoded, target);
    var out: std.Io.Writer.Allocating = .init(arena);
    // The JSON, ZON, and TOML printers take serialization options; YAML doesn't (yet).
    if (Printer == JsonPrinter or Printer == ZonPrinter or Printer == TomlPrinter) {
        try Printer.print(&out.writer, &encoded, .{});
    } else {
        try Printer.print(&out.writer, &encoded);
    }
    return out.written();
}

test "null round-trips through TOML" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // JSON null → TOML (must wrap; TOML has no null) → JSON (must restore).
    const toml = try convert(arena, JsonParser, .JSON, TomlPrinter, .toml, "{\"k\": null}");
    try testing.expect(std.mem.indexOf(u8, toml, sentinel) != null); // wrapped
    const json = try convert(arena, TomlParser, .TOML_1_1, JsonPrinter, .json, toml);
    try testing.expectEqualStrings("{\n  \"k\": null\n}\n", json);
}

test "null stays native for JSON/YAML/ZON targets" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // JSON → JSON lossless leaves a null bare (JSON has one).
    const json = try convert(arena, JsonParser, .JSON, JsonPrinter, .json, "{\"k\": null}");
    try testing.expectEqualStrings("{\n  \"k\": null\n}\n", json);
    try testing.expect(std.mem.indexOf(u8, json, sentinel) == null);
}

test "TOML datetime round-trips through JSON" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const src = "t = 1979-05-27T07:32:00Z\n";
    const json = try convert(arena, TomlParser, .TOML_1_1, JsonPrinter, .json, src);
    try testing.expect(std.mem.indexOf(u8, json, "offset_datetime") != null);
    const toml = try convert(arena, JsonParser, .JSON, TomlPrinter, .toml, json);
    try testing.expectEqualStrings(src, toml);
}

test "TOML datetime stays native for a TOML target" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const src = "t = 1979-05-27T07:32:00Z\n";
    const toml = try convert(arena, TomlParser, .TOML_1_1, TomlPrinter, .toml, src);
    try testing.expectEqualStrings(src, toml); // not wrapped
}

test "ZON enum and char literals round-trip through JSON" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    const src = ".{ .mode = .fast, .ch = 'A' }";
    const json = try convert(arena, ZonParser, .ZON, JsonPrinter, .json, src);
    try testing.expect(std.mem.indexOf(u8, json, "enum_literal") != null);
    try testing.expect(std.mem.indexOf(u8, json, "char_literal") != null);

    const zon = try convert(arena, JsonParser, .JSON, ZonPrinter, .zon, json);
    try testing.expectEqualStrings(
        \\.{
        \\    .mode = .fast,
        \\    .ch = 'A',
        \\}
        \\
    , zon);
}

test "lossyStrip drops nulls for a TOML target and reports paths" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    var ast = try NativeParser.parseAbstract(arena, "{\"a\": 1, \"b\": null, \"c\": [1, null, 2]}");
    const result = try lossyStrip(arena, &ast, ast.root, .toml);
    try testing.expect(result.ast != null);

    var out: std.Io.Writer.Allocating = .init(arena);
    try TomlPrinter.print(&out.writer, &result.ast.?, .{});
    try testing.expectEqualStrings("a = 1\nc = [1, 2]\n", out.written());

    try testing.expectEqual(@as(usize, 2), result.dropped.len);
    try testing.expectEqualStrings("b", result.dropped[0]);
    try testing.expectEqualStrings("c[1]", result.dropped[1]);
}

test "lossyStrip reports a bare-null root and yields no AST" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    var ast = try NativeParser.parseAbstract(arena, "null");
    const result = try lossyStrip(arena, &ast, ast.root, .toml);
    try testing.expect(result.ast == null);
    try testing.expectEqual(@as(usize, 1), result.dropped.len);
}

test "lossyStrip on a nested null reports a dotted path" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    var ast = try NativeParser.parseAbstract(arena, "{\"outer\": {\"inner\": null, \"keep\": 2}}");
    const result = try lossyStrip(arena, &ast, ast.root, .toml);
    try testing.expect(result.ast != null);
    try testing.expectEqual(@as(usize, 1), result.dropped.len);
    try testing.expectEqualStrings("outer.inner", result.dropped[0]);
}

test "decode leaves a non-envelope $fig mapping untouched" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const arena = a.allocator();

    // value is a number, not the inner mapping shape → ordinary data.
    const json = try convert(arena, JsonParser, .JSON, JsonPrinter, .json, "{\"$fig\": 1}");
    try testing.expectEqualStrings("{\n  \"$fig\": 1\n}\n", json);
}
