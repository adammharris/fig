//! gron — a CLI-only, line-oriented projection of the AST.
//!
//! `gron` "explodes" a document into one `path = value` assignment per leaf, so
//! arbitrarily nested data becomes greppable, line-addressable text:
//!
//!     json = {};
//!     json.tags = [];
//!     json.tags[0] = "zig";
//!     json.name = "fig";
//!
//! and `-i gron` reverses it ("ungron"), reconstructing the AST — so a value can
//! be exploded, filtered with `grep`/`sed`, and converted back (to gron or any
//! other format) with no structural loss. Fidelity equals JSON's: the RHS of
//! every line is a JSON value, so comments and the YAML reference layer
//! (anchors/tags) do not survive, exactly as a JSON round-trip would drop them.
//!
//! This format lives entirely in the CLI binary. It is NOT a core
//! `AST.SerializeFormat`, is absent from the C ABI / language bindings, and is
//! never content-sniffed by `Language.detect` (a flat `a = 1` is ambiguous with
//! TOML, so gron must be selected explicitly). It derives straight from the
//! public AST + `AST.Builder`, which is the whole point: it demonstrates that a
//! new format convertible to/from every other fig format needs only a
//! parse(bytes → AST) / print(AST → bytes) pair over the public surface — no
//! changes to the core enums, dispatch, or ABI.
//!
//! gron is "exploded JSON", so it reuses fig's JSON parser (for each RHS value)
//! and JSON printer (to render each RHS) verbatim. It is therefore available
//! only when JSON support is compiled in (`build_options.lang_json`); callers
//! guard on that and surface `error.FormatDisabled` otherwise.

const std = @import("std");
const fig = @import("fig");
const build_options = @import("build_options");

const AST = fig.AST;
const Document = fig.Document;
const Builder = AST.Builder;
const Node = AST.Node;
const Writer = std.Io.Writer;
const activeTag = std.meta.activeTag;

/// JSON is gron's value layer; resolves to `void` when JSON is gated out, in
/// which case every call site below is comptime-pruned to `unreachable` and the
/// public entry points are unreachable behind a caller's `lang_json` guard.
const JSON = if (build_options.lang_json) fig.Language.JSON else void;

/// The customizable surface of the projection. The field defaults reproduce
/// gron's exact syntax (also exposed as the `Projection.gron` preset); overrides
/// change only the *printed* form. Note what is deliberately **not** here: the
/// newline between records. Line-orientation is the whole point of the format
/// (greppable, line-addressable), and the parser hard-splits on `\n`, so the
/// record separator is structural, not a knob.
///
/// Because ungron stays maximally tolerant — it discards whatever leading
/// identifier it sees and strips an optional trailing `;` — `root_name` and
/// `terminator` round-trip for free under the default parser. `assign` is the
/// one load-bearing knob: ungron always splits on the default ` = `, so a custom
/// separator is a one-way (print-only) projection unless it matches the default.
pub const Projection = struct {
    /// The identifier every path hangs off (`json` in gron). Free-form: ungron
    /// skips whatever leading token it finds, so any root reverses — except one
    /// containing a `.` or `[`, which would be misread as path structure.
    root_name: []const u8 = "json",
    /// What separates a path from its value (` = ` in gron). Print-only; see the
    /// struct doc — ungron always splits on ` = `.
    assign: []const u8 = " = ",
    /// Trailing punctuation after each value, before the newline (`;` in gron).
    /// May be empty. Cosmetic: ungron strips an optional `;` regardless.
    terminator: []const u8 = ";",

    /// The gron preset: upstream gron's exact syntax. Equal to the field
    /// defaults, named so call sites read intentionally (`.gron`).
    pub const gron: Projection = .{};
};

// ── Printing (AST → gron) ───────────────────────────────────────────────────

pub const Error = Writer.Error || error{UnresolvedAlias};

/// A path segment, built one link per nesting level on the call stack — the same
/// linked-list-on-the-stack the TOML printer uses for its `[header.path]`s. The
/// full path is re-rendered on demand at each leaf, so no buffer is allocated.
const Path = struct {
    seg: Seg,
    parent: ?*const Path,

    const Seg = union(enum) { root, key: Node.Id, index: usize };
};

/// Emit the subtree rooted at `node_id` as gron, one assignment per line
/// (trailing newline on each). `proj` selects the printed syntax — pass
/// `.gron` for upstream gron. Does not flush — the caller owns the writer.
pub fn printNode(writer: *Writer, ast: *const AST, node_id: Node.Id, proj: Projection) Error!void {
    try emit(writer, ast, node_id, .{ .seg = .root, .parent = null }, proj);
}

fn emit(writer: *Writer, ast: *const AST, id: Node.Id, path: Path, proj: Projection) Error!void {
    switch (ast.nodes[id].kind) {
        // A container emits its own `= {}` / `= []` line first (so ungron can
        // create the empty container before its children populate it), then
        // recurses with the child's path appended.
        .mapping => |first| {
            try emitLine(writer, ast, &path, "{}", proj);
            var cur = first;
            while (cur) |kv_id| {
                const kv = ast.nodes[kv_id].kind.keyvalue;
                try emit(writer, ast, kv.value, .{ .seg = .{ .key = kv.key }, .parent = &path }, proj);
                cur = ast.nodes[kv_id].next_sibling;
            }
        },
        .sequence => |first| {
            try emitLine(writer, ast, &path, "[]", proj);
            var index: usize = 0;
            var cur = first;
            while (cur) |el_id| : (index += 1) {
                try emit(writer, ast, el_id, .{ .seg = .{ .index = index }, .parent = &path }, proj);
                cur = ast.nodes[el_id].next_sibling;
            }
        },
        // Any leaf (scalar, extended, alias) renders its RHS via the JSON
        // printer, so escaping, number normalization, and the JSON degradation
        // of extended scalars (datetimes → string, etc.) all stay in lockstep
        // with the `json` format — and the line reparses as JSON on ungron.
        else => {
            try renderPath(writer, ast, &path, proj);
            try writer.writeAll(proj.assign);
            try emitValue(writer, ast, id);
            try writer.writeAll(proj.terminator);
            try writer.writeByte('\n');
        },
    }
}

/// Emit one `<path><assign><rhs><terminator>\n` line whose RHS is a literal
/// (the empty-container `{}` / `[]` markers). Leaves render their RHS through the
/// JSON printer instead and so write the pieces inline above.
fn emitLine(writer: *Writer, ast: *const AST, path: *const Path, rhs: []const u8, proj: Projection) Error!void {
    try renderPath(writer, ast, path, proj);
    try writer.writeAll(proj.assign);
    try writer.writeAll(rhs);
    try writer.writeAll(proj.terminator);
    try writer.writeByte('\n');
}

/// Walk to the root link, then unwind, writing each segment in path order.
fn renderPath(writer: *Writer, ast: *const AST, path: *const Path, proj: Projection) Error!void {
    if (path.parent) |p| try renderPath(writer, ast, p, proj);
    switch (path.seg) {
        .root => try writer.writeAll(proj.root_name),
        .index => |i| try writer.print("[{d}]", .{i}),
        .key => |key_id| try keySegment(writer, ast, key_id),
    }
}

/// A string key that is a bare identifier prints as `.key`; anything else
/// (a key needing escapes, or a non-string key) prints as a bracketed,
/// JSON-quoted `["key"]` — the inverse of what `parsePath` accepts.
fn keySegment(writer: *Writer, ast: *const AST, key_id: Node.Id) Error!void {
    const k = ast.nodes[key_id].kind;
    if (k == .string and isBareIdentifier(k.string)) {
        try writer.writeByte('.');
        try writer.writeAll(k.string);
    } else {
        try writer.writeByte('[');
        try emitValue(writer, ast, key_id);
        try writer.writeByte(']');
    }
}

/// Render a single node as a compact JSON value (the gron RHS / bracket key).
fn emitValue(writer: *Writer, ast: *const AST, id: Node.Id) Error!void {
    if (comptime build_options.lang_json) {
        try JSON.printNode(writer, ast, id, 0, .{ .pretty = false });
    } else unreachable;
}

/// The ASCII identifier shape printed unquoted as `.key` and accepted unquoted
/// by `parsePath` — the two MUST agree, so the predicate is defined once here.
fn isBareIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| {
        if (!(if (i == 0) isIdentStart(c) else isIdentPart(c))) return false;
    }
    return true;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

fn isIdentPart(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

// ── Parsing (gron → AST, "ungron") ──────────────────────────────────────────

pub const ParseError = error{InvalidGron};

/// Parse gron text into a `Document`. `allocator` is expected to be an arena
/// (the CLI's): the intermediate tree and the per-RHS JSON sub-parses are left
/// for it to reclaim. The returned document borrows `input` as its source and
/// carries placeholder spans (gron has no source-coupled editing).
pub fn parseDocument(allocator: std.mem.Allocator, input: []const u8) !Document {
    // Build a mutable tree top-down (gron emits parents before children), then
    // freeze it bottom-up through the Builder.
    var root = GNode{};
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        try applyLine(allocator, &root, line);
    }

    var b = Builder.init(allocator);
    defer b.deinit();
    const root_id = try buildNode(&b, allocator, &root);
    const ast = try b.finish(root_id);

    // gron carries no source spans; hand back a zeroed table sized to the AST so
    // any span lookup stays in bounds and `Document.deinit` frees a real slice.
    const Span = std.meta.Elem(@FieldType(Document, "node_spans"));
    const spans = try allocator.alloc(Span, ast.nodes.len);
    @memset(spans, .{ .start = 0, .end = 0 });
    return .{ .source = input, .ast = ast, .node_spans = spans };
}

/// The intermediate tree node. `unset` is a container slot created while
/// descending a path before its own `= {}` / `= []` line has been seen.
const GNode = struct {
    value: union(enum) {
        unset,
        leaf: []const u8, // verbatim RHS text, JSON-parsed at build time
        object: std.ArrayList(Member),
        array: std.ArrayList(*GNode),
    } = .unset,
};

const Member = struct { key: []const u8, node: *GNode };

const PSeg = union(enum) { key: []const u8, index: usize };

fn applyLine(allocator: std.mem.Allocator, root: *GNode, line: []const u8) !void {
    // Drop one optional trailing `;`, then split on the first ` = `.
    var stmt = line;
    if (stmt.len > 0 and stmt[stmt.len - 1] == ';') stmt = std.mem.trim(u8, stmt[0 .. stmt.len - 1], " \t\r");
    const eq = std.mem.indexOf(u8, stmt, " = ") orelse return ParseError.InvalidGron;
    const lhs = std.mem.trim(u8, stmt[0..eq], " \t\r");
    const rhs = std.mem.trim(u8, stmt[eq + 3 ..], " \t\r");

    var segs: std.ArrayList(PSeg) = .empty;
    defer segs.deinit(allocator);
    try parsePath(allocator, lhs, &segs);

    // Navigate from the root through the descend segments, creating containers
    // as needed, then assign the value at the destination node.
    var node = root;
    for (segs.items) |seg| node = try descend(allocator, node, seg);
    try setValue(node, rhs);
}

/// Parse the LHS path: a leading root token (its name discarded), then a run of
/// `.key` / `["key"]` / `[index]` segments. The root segment itself is not
/// emitted — only the descent from it.
///
/// The root is skipped by consuming everything up to the first separator (`.` or
/// `[`), NOT by matching an identifier: the printer's `root_name` is freely
/// customizable (`adams-archive`, etc.) and never round-tripped, so ungron must
/// accept whatever leading token it finds. A root containing a `.` or `[` is the
/// one shape that can't survive (it would be read as path structure).
fn parsePath(allocator: std.mem.Allocator, lhs: []const u8, out: *std.ArrayList(PSeg)) !void {
    var i: usize = 0;
    while (i < lhs.len and lhs[i] != '.' and lhs[i] != '[') i += 1;
    if (i == 0) return ParseError.InvalidGron; // empty LHS, or a leading separator

    while (i < lhs.len) {
        switch (lhs[i]) {
            '.' => {
                i += 1;
                const start = i;
                if (i >= lhs.len or !isIdentStart(lhs[i])) return ParseError.InvalidGron;
                while (i < lhs.len and isIdentPart(lhs[i])) i += 1;
                try out.append(allocator, .{ .key = lhs[start..i] });
            },
            '[' => {
                i += 1;
                if (i < lhs.len and lhs[i] == '"') {
                    // Quoted key: scan to the closing unescaped quote, then JSON
                    // decode the literal (escapes and all) to the real key bytes.
                    const start = i;
                    i += 1;
                    while (i < lhs.len and lhs[i] != '"') : (i += 1) {
                        if (lhs[i] == '\\') i += 1; // skip the escaped byte
                    }
                    if (i >= lhs.len) return ParseError.InvalidGron;
                    i += 1; // past closing quote
                    const literal = lhs[start..i];
                    if (i >= lhs.len or lhs[i] != ']') return ParseError.InvalidGron;
                    i += 1; // past ']'
                    try out.append(allocator, .{ .key = try decodeJsonString(allocator, literal) });
                } else {
                    const start = i;
                    while (i < lhs.len and lhs[i] != ']') i += 1;
                    if (i >= lhs.len) return ParseError.InvalidGron;
                    const digits = lhs[start..i];
                    i += 1; // past ']'
                    const index = std.fmt.parseInt(usize, digits, 10) catch return ParseError.InvalidGron;
                    try out.append(allocator, .{ .index = index });
                }
            },
            else => return ParseError.InvalidGron,
        }
    }
}

/// Decode a JSON string literal (quotes included) to its bytes, reusing the JSON
/// parser so escape handling matches the printer exactly.
fn decodeJsonString(allocator: std.mem.Allocator, literal: []const u8) ![]const u8 {
    if (comptime !build_options.lang_json) unreachable;
    const doc = try JSON.Parser.parse(allocator, literal, .JSON);
    return switch (doc.ast.nodes[doc.ast.root].kind) {
        .string => |s| s,
        else => ParseError.InvalidGron,
    };
}

/// Descend (creating as needed) one level into `node`, auto-vivifying the
/// container kind the segment implies. A key needs an object; an index needs an
/// array, grown with `unset` slots up to that index.
fn descend(allocator: std.mem.Allocator, node: *GNode, seg: PSeg) !*GNode {
    switch (seg) {
        .key => |key| {
            if (activeTag(node.value) == .unset) node.value = .{ .object = .empty };
            if (activeTag(node.value) != .object) return ParseError.InvalidGron;
            for (node.value.object.items) |m| {
                if (std.mem.eql(u8, m.key, key)) return m.node;
            }
            const child = try allocator.create(GNode);
            child.* = .{};
            try node.value.object.append(allocator, .{ .key = key, .node = child });
            return child;
        },
        .index => |index| {
            if (activeTag(node.value) == .unset) node.value = .{ .array = .empty };
            if (activeTag(node.value) != .array) return ParseError.InvalidGron;
            while (node.value.array.items.len <= index) {
                const child = try allocator.create(GNode);
                child.* = .{};
                try node.value.array.append(allocator, child);
            }
            return node.value.array.items[index];
        },
    }
}

/// Assign a line's RHS to its destination node. `{}` / `[]` establish an empty
/// container (preserving any children already vivified into it); anything else
/// is a leaf whose verbatim text is JSON-parsed at build time.
fn setValue(node: *GNode, rhs: []const u8) !void {
    if (std.mem.eql(u8, rhs, "{}")) {
        if (activeTag(node.value) != .object) node.value = .{ .object = .empty };
    } else if (std.mem.eql(u8, rhs, "[]")) {
        if (activeTag(node.value) != .array) node.value = .{ .array = .empty };
    } else {
        node.value = .{ .leaf = rhs };
    }
}

fn buildNode(b: *Builder, allocator: std.mem.Allocator, node: *const GNode) !Node.Id {
    switch (node.value) {
        // A path was descended through but never assigned: treat as null.
        .unset => return b.addNull(),
        .leaf => |text| return buildLeaf(b, allocator, text),
        .object => |members| {
            const entries = try allocator.alloc(Builder.Entry, members.items.len);
            for (members.items, entries) |m, *entry| {
                const key_id = try b.addString(m.key);
                const val_id = try buildNode(b, allocator, m.node);
                entry.* = .{ .key = key_id, .value = val_id };
            }
            return b.addMapping(entries);
        },
        .array => |items| {
            const ids = try allocator.alloc(Node.Id, items.items.len);
            for (items.items, ids) |item, *slot| slot.* = try buildNode(b, allocator, item);
            return b.addSequence(ids);
        },
    }
}

/// Parse a leaf's RHS as a JSON value and copy it into the builder. Canonical
/// gron leaves are scalars, but a full JSON value is copied faithfully too, so a
/// hand-written or non-exploding gron stream still ungrons.
fn buildLeaf(b: *Builder, allocator: std.mem.Allocator, text: []const u8) !Node.Id {
    if (comptime !build_options.lang_json) unreachable;
    const doc = try JSON.Parser.parse(allocator, text, .JSON);
    return copyNode(b, allocator, &doc.ast, doc.ast.root);
}

fn copyNode(b: *Builder, allocator: std.mem.Allocator, src: *const AST, id: Node.Id) !Node.Id {
    switch (src.nodes[id].kind) {
        .null_ => return b.addNull(),
        .boolean => |v| return b.addBool(v),
        .number => |n| return b.addNumberRaw(n.raw, n.kind == .float),
        .string => |s| return b.addString(s),
        .extended => |e| return b.addExtended(e.kind, e.text),
        .sequence => |first| {
            var ids: std.ArrayList(Node.Id) = .empty;
            defer ids.deinit(allocator);
            var cur = first;
            while (cur) |c| {
                try ids.append(allocator, try copyNode(b, allocator, src, c));
                cur = src.nodes[c].next_sibling;
            }
            return b.addSequence(ids.items);
        },
        .mapping => |first| {
            var entries: std.ArrayList(Builder.Entry) = .empty;
            defer entries.deinit(allocator);
            var cur = first;
            while (cur) |kv_id| {
                const kv = src.nodes[kv_id].kind.keyvalue;
                const key_id = try copyNode(b, allocator, src, kv.key);
                const val_id = try copyNode(b, allocator, src, kv.value);
                try entries.append(allocator, .{ .key = key_id, .value = val_id });
                cur = src.nodes[kv_id].next_sibling;
            }
            return b.addMapping(entries.items);
        },
        .keyvalue => unreachable, // reached only via mapping, handled above
        .alias => return ParseError.InvalidGron, // JSON never yields one
    }
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Render `ast` from its root to a gron string owned by the caller's arena.
fn gronOf(allocator: std.mem.Allocator, ast: *const AST) ![]const u8 {
    return gronOfWith(allocator, ast, .gron);
}

fn gronOfWith(allocator: std.mem.Allocator, ast: *const AST, proj: Projection) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    try printNode(&out.writer, ast, ast.root, proj);
    return out.written();
}

test "prints nested data as path = value lines" {
    if (comptime !build_options.lang_json) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // { a: 1, b: [ "x", {} ], "weird key": true }
    var b = Builder.init(a);
    const a_v = try b.addInt(1);
    const b0 = try b.addString("x");
    const b1 = try b.addMapping(&.{});
    const b_v = try b.addSequence(&.{ b0, b1 });
    const w_v = try b.addBool(true);
    const root = try b.addMapping(&.{
        .{ .key = try b.addString("a"), .value = a_v },
        .{ .key = try b.addString("b"), .value = b_v },
        .{ .key = try b.addString("weird key"), .value = w_v },
    });
    var ast = try b.finish(root);

    try testing.expectEqualStrings(
        \\json = {};
        \\json.a = 1;
        \\json.b = [];
        \\json.b[0] = "x";
        \\json.b[1] = {};
        \\json["weird key"] = true;
        \\
    , try gronOf(a, &ast));
}

test "a custom projection swaps root, separator, and terminator" {
    if (comptime !build_options.lang_json) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var b = Builder.init(a);
    const root = try b.addMapping(&.{
        .{ .key = try b.addString("a"), .value = try b.addInt(1) },
    });
    var ast = try b.finish(root);

    // A non-gron preset: different root name, `: ` separator, no terminator. The
    // newline between records is structural and stays put.
    const proj: Projection = .{ .root_name = "cfg", .assign = ": ", .terminator = "" };
    const out = try gronOfWith(a, &ast, proj);
    try testing.expectEqualStrings(
        \\cfg: {}
        \\cfg.a: 1
        \\
    , out);

    // ungron stays maximally tolerant: it discards the leading root token and
    // strips an optional `;`, so a stream that uses the *default* separator and
    // a different root still reverses without any matching flags.
    const doc = try parseDocument(a,
        \\cfg = {};
        \\cfg.a = 1;
    );
    var json: std.Io.Writer.Allocating = .init(a);
    try doc.ast.serializeWith(&json.writer, .json, .{ .pretty = false });
    try testing.expectEqualStrings("{\"a\":1}\n", json.written());
}

test "ungron tolerates a non-identifier root (hyphens, etc.)" {
    if (comptime !build_options.lang_json) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `adams-archive` is not a bare identifier, but the root is discarded, so it
    // must still ungron. A top-level scalar (no separators after the root) too.
    const doc = try parseDocument(a,
        \\adams-archive = {}
        \\adams-archive.title = "hi"
        \\adams-archive["a-b"] = 2
    );
    var json: std.Io.Writer.Allocating = .init(a);
    try doc.ast.serializeWith(&json.writer, .json, .{ .pretty = false });
    try testing.expectEqualStrings("{\"title\":\"hi\",\"a-b\":2}\n", json.written());

    const scalar = try parseDocument(a, "adams-archive = 7");
    var s2: std.Io.Writer.Allocating = .init(a);
    try scalar.ast.serializeWith(&s2.writer, .json, .{ .pretty = false });
    try testing.expectEqualStrings("7\n", s2.written());
}

test "ungron reconstructs the document" {
    if (comptime !build_options.lang_json) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const input =
        \\json = {};
        \\json.a = 1;
        \\json.b = [];
        \\json.b[0] = "x";
        \\json.b[1] = {};
        \\json["weird key"] = true;
        \\json.n = null;
    ;
    const doc = try parseDocument(a, input);
    var out: std.Io.Writer.Allocating = .init(a);
    try doc.ast.serializeWith(&out.writer, .json, .{ .pretty = false });
    try testing.expectEqualStrings(
        "{\"a\":1,\"b\":[\"x\",{}],\"weird key\":true,\"n\":null}\n",
        out.written(),
    );
}

test "gron round-trips through parse and print" {
    if (comptime !build_options.lang_json) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Keys needing brackets, escapes, a top-level-ish nesting, and every scalar.
    const input =
        \\json = {};
        \\json.tab = "a\tb";
        \\json.q = "she said \"hi\"";
        \\json["dotted.key"] = [];
        \\json["dotted.key"][0] = -2.5;
        \\json.flag = false;
        \\json.nothing = null;
    ;
    const doc = try parseDocument(a, input);
    const reprinted = try gronOf(a, &doc.ast);
    try testing.expectEqualStrings(input ++ "\n", reprinted);
}

test "top-level scalar is a bare assignment" {
    if (comptime !build_options.lang_json) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var b = Builder.init(a);
    const root = try b.addString("hi");
    var ast = try b.finish(root);
    try testing.expectEqualStrings("json = \"hi\";\n", try gronOf(a, &ast));
}

test "malformed lines are rejected" {
    if (comptime !build_options.lang_json) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(ParseError.InvalidGron, parseDocument(a, "no equals here"));
    try testing.expectError(ParseError.InvalidGron, parseDocument(a, "json[ = 1"));
}
