//! C ABI for `fig`
//!
//! This file is the entry point for programs accessing `fig` outside of the Zig language.

const std = @import("std");
const builtin = @import("builtin");
const Document = @import("document.zig");
const AST = @import("ast.zig");
const JsonParser = @import("json/parser.zig");
const JsonType = @import("json/json.zig").Type;
const YamlParser = @import("yaml/parser.zig");
const YamlType = @import("yaml/yaml.zig").Type;

/// Translation of `fig` errors to C ABI.
pub const FigStatus = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    parse_error = 2,
    out_of_memory = 3,
    unsupported_format = 4,
    internal_error = 255,
};

/// Translation of fig.Language.Type to C ABI.
pub const FigFormat = enum(c_int) {
    json = 1,
    jsonc = 2,
    yaml = 3,
};

/// A handle to a `fig` document. (See `DocumentHandle` and `handle.*` declaration in `fig_parse`)
pub const FigDocument = opaque {};
const DocumentHandle = struct {
    allocator: std.mem.Allocator,
    source: []u8,
    document: Document,
};

fn activeAllocator() std.mem.Allocator {
    return if (builtin.cpu.arch.isWasm())
        std.heap.wasm_allocator
    else
        std.heap.c_allocator;
}

pub export fn fig_parse(
    input_ptr: ?[*]const u8,
    input_len: usize,
    format: c_int,
    out_doc: ?*?*FigDocument,
) FigStatus {
    const out = out_doc orelse return .invalid_argument;
    out.* = null;

    const input = input_ptr orelse {
        if (input_len == 0) return .parse_error;
        return .invalid_argument;
    };

    const fig_format: FigFormat = switch (format) {
        @intFromEnum(FigFormat.json) => .json,
        @intFromEnum(FigFormat.jsonc) => .jsonc,
        @intFromEnum(FigFormat.yaml) => .yaml,
        else => return .unsupported_format,
    };

    const allocator = activeAllocator();

    const source = allocator.dupe(u8, input[0..input_len]) catch return .out_of_memory;
    const handle = allocator.create(DocumentHandle) catch {
        allocator.free(source);
        return .out_of_memory;
    };

    const doc = switch (fig_format) {
        .json => blk: {
            break :blk JsonParser.parse(allocator, source, JsonType.JSON) catch |err| {
                allocator.free(source);
                allocator.destroy(handle);
                return parseFailureStatus(err);
            };
        },
        .jsonc => blk: {
            break :blk JsonParser.parse(allocator, source, JsonType.JSONC) catch |err| {
                allocator.free(source);
                allocator.destroy(handle);
                return parseFailureStatus(err);
            };
        },
        .yaml => blk: {
            break :blk YamlParser.parse(allocator, source, YamlType.v1_2_2) catch |err| {
                allocator.free(source);
                allocator.destroy(handle);
                return parseFailureStatus(err);
            };
        },
    };

    handle.* = .{
        .allocator = allocator,
        .source = source,
        .document = doc,
    };

    out.* = @ptrCast(handle);
    return .ok;
}

fn parseFailureStatus(err: anyerror) FigStatus {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        else => .parse_error,
    };
}

/// Memory allocated by this API should be freed by this API.
pub export fn fig_document_destroy(doc: ?*FigDocument) void {
    const public_doc = doc orelse return;
    const handle: *DocumentHandle = @ptrCast(@alignCast(public_doc));
    handle.document.deinit(handle.allocator);
    handle.allocator.free(handle.source);
    handle.allocator.destroy(handle);
}

// ==================
// DOCUMENT TRAVERSAL
// ==================

pub const FigNodeId = u32;
const fig_node_none: FigNodeId = 0xFFFFFFFF;

/// Translation of an AST node's kind to the C ABI. Mirrors `FigNodeKind` in
/// `include/fig.h`.
pub const FigNodeKind = enum(c_int) {
    invalid = -1,
    null_ = 0,
    bool_ = 1,
    int = 2,
    float = 3,
    string = 4,
    sequence = 5,
    mapping = 6,
    keyvalue = 7,
};

fn handleFrom(doc: ?*const FigDocument) ?*const DocumentHandle {
    const public_doc = doc orelse return null;
    return @ptrCast(@alignCast(public_doc));
}

/// Returns the node at `id`, or null if `doc` is null or `id` is out of range.
fn nodeAt(doc: ?*const FigDocument, id: FigNodeId) ?AST.Node {
    const handle = handleFrom(doc) orelse return null;
    const nodes = handle.document.ast.nodes;
    if (id >= nodes.len) return null;
    return nodes[id];
}

pub export fn fig_document_root(doc: ?*const FigDocument) FigNodeId {
    const handle = handleFrom(doc) orelse return fig_node_none;
    const ast = handle.document.ast;
    if (ast.root >= ast.nodes.len) return fig_node_none;
    return ast.root;
}

pub export fn fig_node_kind(doc: ?*const FigDocument, node: FigNodeId) FigNodeKind {
    const n = nodeAt(doc, node) orelse return .invalid;
    return switch (n.kind) {
        .null_ => .null_,
        .boolean => .bool_,
        .string => .string,
        .number => |num| switch (num.kind) {
            .integer => .int,
            .float => .float,
        },
        .sequence => .sequence,
        .mapping => .mapping,
        .keyvalue => .keyvalue,
    };
}

pub export fn fig_node_first_child(doc: ?*const FigDocument, node: FigNodeId) FigNodeId {
    const n = nodeAt(doc, node) orelse return fig_node_none;
    const child_id = switch (n.kind) {
        .sequence, .mapping => |first| first,
        else => return fig_node_none,
    };
    return child_id orelse fig_node_none;
}

pub export fn fig_node_next_sibling(doc: ?*const FigDocument, node: FigNodeId) FigNodeId {
    const n = nodeAt(doc, node) orelse return fig_node_none;
    return n.next_sibling orelse fig_node_none;
}

pub export fn fig_node_child_count(doc: ?*const FigDocument, node: FigNodeId) usize {
    const handle = handleFrom(doc) orelse return 0;
    const nodes = handle.document.ast.nodes;
    if (node >= nodes.len) return 0;
    var current: ?FigNodeId = switch (nodes[node].kind) {
        .sequence, .mapping => |first| first,
        else => return 0,
    };
    var count: usize = 0;
    while (current) |id| {
        if (id >= nodes.len) break;
        count += 1;
        current = nodes[id].next_sibling;
    }
    return count;
}

pub export fn fig_keyvalue_key(doc: ?*const FigDocument, node: FigNodeId) FigNodeId {
    const n = nodeAt(doc, node) orelse return fig_node_none;
    return switch (n.kind) {
        .keyvalue => |kv| kv.key,
        else => fig_node_none,
    };
}

pub export fn fig_keyvalue_value(doc: ?*const FigDocument, node: FigNodeId) FigNodeId {
    const n = nodeAt(doc, node) orelse return fig_node_none;
    return switch (n.kind) {
        .keyvalue => |kv| kv.value,
        else => fig_node_none,
    };
}

pub export fn fig_node_bool(doc: ?*const FigDocument, node: FigNodeId, out: ?*bool) bool {
    const out_ptr = out orelse return false;
    const n = nodeAt(doc, node) orelse return false;
    switch (n.kind) {
        .boolean => |b| {
            out_ptr.* = b;
            return true;
        },
        else => return false,
    }
}

pub export fn fig_node_number(
    doc: ?*const FigDocument,
    node: FigNodeId,
    out_ptr: ?*[*c]const u8,
    out_len: ?*usize,
) bool {
    const p = out_ptr orelse return false;
    const l = out_len orelse return false;
    const n = nodeAt(doc, node) orelse return false;
    switch (n.kind) {
        .number => |num| {
            p.* = num.raw.ptr;
            l.* = num.raw.len;
            return true;
        },
        else => return false,
    }
}

pub export fn fig_node_string(
    doc: ?*const FigDocument,
    node: FigNodeId,
    out_ptr: ?*[*c]const u8,
    out_len: ?*usize,
) bool {
    const p = out_ptr orelse return false;
    const l = out_len orelse return false;
    const n = nodeAt(doc, node) orelse return false;
    switch (n.kind) {
        .string => |s| {
            p.* = s.ptr;
            l.* = s.len;
            return true;
        },
        else => return false,
    }
}

test "traversal over a parsed mapping" {
    const src = "title: Hello\ncount: 42\ntags:\n- a\n- b\n";

    var out_doc: ?*FigDocument = null;
    try std.testing.expectEqual(FigStatus.ok, fig_parse(src.ptr, src.len, @intFromEnum(FigFormat.yaml), &out_doc));
    defer fig_document_destroy(out_doc);

    const doc: ?*const FigDocument = out_doc;
    const root = fig_document_root(doc);
    try std.testing.expect(root != fig_node_none);
    try std.testing.expectEqual(FigNodeKind.mapping, fig_node_kind(doc, root));
    try std.testing.expectEqual(@as(usize, 3), fig_node_child_count(doc, root));

    // First entry: title -> "Hello"
    const first = fig_node_first_child(doc, root);
    try std.testing.expectEqual(FigNodeKind.keyvalue, fig_node_kind(doc, first));
    const key = fig_keyvalue_key(doc, first);
    const val = fig_keyvalue_value(doc, first);

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expect(fig_node_string(doc, key, &ptr, &len));
    try std.testing.expectEqualStrings("title", ptr[0..len]);
    try std.testing.expect(fig_node_string(doc, val, &ptr, &len));
    try std.testing.expectEqualStrings("Hello", ptr[0..len]);

    // Second entry: count -> 42 (integer)
    const second = fig_node_next_sibling(doc, first);
    const count_val = fig_keyvalue_value(doc, second);
    try std.testing.expectEqual(FigNodeKind.int, fig_node_kind(doc, count_val));
    try std.testing.expect(fig_node_number(doc, count_val, &ptr, &len));
    try std.testing.expectEqualStrings("42", ptr[0..len]);

    // Third entry: tags -> [a, b]
    const third = fig_node_next_sibling(doc, second);
    const tags_val = fig_keyvalue_value(doc, third);
    try std.testing.expectEqual(FigNodeKind.sequence, fig_node_kind(doc, tags_val));
    try std.testing.expectEqual(@as(usize, 2), fig_node_child_count(doc, tags_val));
}
