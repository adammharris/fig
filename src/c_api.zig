//! C ABI for `fig`
//!
//! This file is the entry point for programs accessing `fig` outside of the Zig language.

const std = @import("std");
const builtin = @import("builtin");
const Document = @import("document.zig");
const AST = @import("ast.zig");
const Span = @import("util/span.zig");
const Embed = @import("embed.zig");
const Editor = @import("editor.zig").Editor;
const JsonParser = @import("json/parser.zig");
const JsonType = @import("json/json.zig").Type;
const JsonLang = @import("json/json.zig").Language;
const YamlParser = @import("yaml/parser.zig");
const YamlType = @import("yaml/yaml.zig").Type;
const YamlLang = @import("yaml/yaml.zig").Language;

/// Logging for the C ABI build (this file is the static-lib root, so its
/// `std_options` wins). The default `std.log` handler writes to stderr via
/// `std.Io.Threaded`, which does not exist on `wasm32-freestanding` (no posix
/// I/O) — referencing it fails to compile. A library has no business writing to
/// stderr regardless, so drop logs on wasm and defer to the default elsewhere.
pub const std_options: std.Options = .{ .logFn = figLogFn };

fn figLogFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (builtin.cpu.arch.isWasm()) return;
    std.log.defaultLog(level, scope, format, args);
}

/// Translation of `fig` errors to C ABI.
pub const FigStatus = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    parse_error = 2,
    out_of_memory = 3,
    unsupported_format = 4,
    not_found = 5,
    internal_error = 255,
};

/// Translation of fig.Language.Type to C ABI. Not every function accepts every
/// member: the parse/edit entry points support `json`/`jsonc`/`yaml` (others
/// return `unsupported_format`), while the serializer (`fig_value_serialize`)
/// additionally accepts `toml`/`zon` and treats `jsonc` as `json`.
pub const FigFormat = enum(c_int) {
    json = 1,
    jsonc = 2,
    yaml = 3,
    toml = 4,
    zon = 5,
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
        // Filtered out by the format switch above; parsing these is not yet wired.
        .toml, .zon => unreachable,
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
    alias = 8,
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
        // C has no type for these. Datetimes and enum literals surface as string
        // scalars (fig_node_string returns the text); a char literal surfaces as
        // an int (fig_node_number returns its codepoint). Dedicated ABI kinds are
        // deferred until these formats reach the bindings.
        .extended => |ext| switch (ext.kind) {
            .char_literal => .int,
            else => .string,
        },
        .sequence => .sequence,
        .mapping => .mapping,
        .keyvalue => .keyvalue,
        .alias => .alias,
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
        // A char literal reads out as its decimal codepoint (see fig_node_kind).
        .extended => |ext| switch (ext.kind) {
            .char_literal => {
                p.* = ext.text.ptr;
                l.* = ext.text.len;
                return true;
            },
            else => return false,
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
        // Datetimes and enum literals read out as their text (see fig_node_kind);
        // a char literal is a number, handled by fig_node_number instead.
        .extended => |ext| switch (ext.kind) {
            .char_literal => return false,
            else => {
                p.* = ext.text.ptr;
                l.* = ext.text.len;
                return true;
            },
        },
        else => return false,
    }
}

// ======
// EDITING
// ======
//
// The write path mirrors the read path: an opaque handle owns the source +
// parse, and edits splice bytes in place (preserving comments/formatting) then
// reparse. `fig_editor_*` works on a whole document; `fig_fm_*` is a thin
// frontmatter-aware layer that edits the YAML between markdown `---` fences and
// re-assembles the host file. Path segments cross the boundary as an array of
// `FigPathSegment` (key string | sequence index), mirroring `AST.PathSegment`.

/// One step of a path: `kind == 0` selects mapping key `key_ptr[0..key_len]`;
/// `kind == 1` selects sequence element `index`.
pub const FigPathSegment = extern struct {
    kind: i32,
    key_ptr: ?[*]const u8,
    key_len: usize,
    index: usize,
};

const max_path_len = 128;
const max_keys_len = 512;

/// A borrowed UTF-8 string slice passed across the C ABI: `ptr[0..len]`. Used
/// for the key list of `fig_*_reorder_keys`.
pub const FigStr = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

/// Decode a C array of `FigStr` into `buf`. Returns the populated slice, or
/// null on a malformed entry / over-long list. A zero-length entry decodes to
/// an empty key regardless of its (possibly null) pointer.
fn decodeKeys(
    keys_ptr: ?[*]const FigStr,
    keys_len: usize,
    buf: [][]const u8,
) ?[][]const u8 {
    if (keys_len == 0) return buf[0..0];
    if (keys_len > buf.len) return null;
    const ks = keys_ptr orelse return null;
    for (0..keys_len) |i| {
        buf[i] = if (ks[i].len == 0) &.{} else (ks[i].ptr orelse return null)[0..ks[i].len];
    }
    return buf[0..keys_len];
}

/// View a C `usize` array as a Zig slice. Returns null only when the pointer is
/// null for a non-empty length (a zero length is a valid empty list).
fn decodeIndices(ptr: ?[*]const usize, len: usize) ?[]const usize {
    if (len == 0) return &.{};
    const p = ptr orelse return null;
    return p[0..len];
}

/// Decode a C path array into `buf`. Returns the populated slice, or null on a
/// malformed segment / over-long path.
fn decodePath(
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    buf: []AST.PathSegment,
) ?[]AST.PathSegment {
    if (path_len == 0) return buf[0..0];
    if (path_len > buf.len) return null;
    const segs = path_ptr orelse return null;
    for (0..path_len) |i| {
        buf[i] = switch (segs[i].kind) {
            0 => .{ .key = (segs[i].key_ptr orelse return null)[0..segs[i].key_len] },
            1 => .{ .index = segs[i].index },
            else => return null,
        };
    }
    return buf[0..path_len];
}

/// Translate the editor/AST error set onto `FigStatus`.
fn editStatus(err: anyerror) FigStatus {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.NotFound => .not_found,
        error.NotAMapping, error.NotASequence, error.NotAContainer, error.InvalidDocument => .invalid_argument,
        error.NotInitialized, error.MultipleInit, error.InvalidSpan => .internal_error,
        // A reparse after a malformed edit lands here.
        else => .parse_error,
    };
}

pub const FigEditor = opaque {};

const EditorHandle = struct {
    allocator: std.mem.Allocator,
    inner: union(enum) {
        yaml: Editor(YamlLang),
        json: Editor(JsonLang),
    },

    fn deinit(self: *EditorHandle) void {
        switch (self.inner) {
            inline else => |*e| e.deinit(),
        }
    }
};

fn editorFrom(ed: ?*FigEditor) ?*EditorHandle {
    const p = ed orelse return null;
    return @ptrCast(@alignCast(p));
}

pub export fn fig_editor_create(
    input_ptr: ?[*]const u8,
    input_len: usize,
    format: c_int,
    out_editor: ?*?*FigEditor,
) FigStatus {
    const out = out_editor orelse return .invalid_argument;
    out.* = null;

    // Empty input (len 0, with or without a null pointer) is a valid empty
    // document; a non-null pointer with a length is read as-is.
    const slice = sliceOf(input_ptr, input_len) orelse return .invalid_argument;

    const fig_format: FigFormat = switch (format) {
        @intFromEnum(FigFormat.json) => .json,
        @intFromEnum(FigFormat.jsonc) => .jsonc,
        @intFromEnum(FigFormat.yaml) => .yaml,
        else => return .unsupported_format,
    };

    const allocator = activeAllocator();
    const handle = allocator.create(EditorHandle) catch return .out_of_memory;
    handle.allocator = allocator;
    handle.inner = switch (fig_format) {
        .yaml => .{ .yaml = .{ .allocator = allocator } },
        .json => .{ .json = .{ .allocator = allocator } },
        .jsonc => .{ .json = .{ .allocator = allocator, .format = .JSONC } },
        // Filtered out by the format switch above; editing these is not yet wired.
        .toml, .zon => unreachable,
    };

    switch (handle.inner) {
        inline else => |*e| e.init(slice) catch |err| {
            e.deinit();
            allocator.destroy(handle);
            return editStatus(err);
        },
    }

    out.* = @ptrCast(handle);
    return .ok;
}

pub export fn fig_editor_destroy(ed: ?*FigEditor) void {
    const handle = editorFrom(ed) orelse return;
    const allocator = handle.allocator;
    handle.deinit();
    allocator.destroy(handle);
}

pub export fn fig_editor_replace_val(
    ed: ?*FigEditor,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    repl_ptr: ?[*]const u8,
    repl_len: usize,
) FigStatus {
    const handle = editorFrom(ed) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const repl = sliceOf(repl_ptr, repl_len) orelse return .invalid_argument;
    return switch (handle.inner) {
        inline else => |*e| if (e.replaceValAtPath(path, repl)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_editor_replace_key(
    ed: ?*FigEditor,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    repl_ptr: ?[*]const u8,
    repl_len: usize,
) FigStatus {
    const handle = editorFrom(ed) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const repl = sliceOf(repl_ptr, repl_len) orelse return .invalid_argument;
    return switch (handle.inner) {
        inline else => |*e| if (e.replaceKeyAtPath(path, repl)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_editor_insert_key(
    ed: ?*FigEditor,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    key_ptr: ?[*]const u8,
    key_len: usize,
    val_ptr: ?[*]const u8,
    val_len: usize,
) FigStatus {
    const handle = editorFrom(ed) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const key = sliceOf(key_ptr, key_len) orelse return .invalid_argument;
    const val = sliceOf(val_ptr, val_len) orelse return .invalid_argument;
    return switch (handle.inner) {
        inline else => |*e| if (e.insertKey(path, key, val)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_editor_delete_key(
    ed: ?*FigEditor,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
) FigStatus {
    const handle = editorFrom(ed) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    return switch (handle.inner) {
        inline else => |*e| if (e.deleteKey(path)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_editor_append_seq(
    ed: ?*FigEditor,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    val_ptr: ?[*]const u8,
    val_len: usize,
) FigStatus {
    const handle = editorFrom(ed) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const val = sliceOf(val_ptr, val_len) orelse return .invalid_argument;
    return switch (handle.inner) {
        inline else => |*e| if (e.appendToSeq(path, val)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_editor_prepend_seq(
    ed: ?*FigEditor,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    val_ptr: ?[*]const u8,
    val_len: usize,
) FigStatus {
    const handle = editorFrom(ed) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const val = sliceOf(val_ptr, val_len) orelse return .invalid_argument;
    return switch (handle.inner) {
        inline else => |*e| if (e.prependToSeq(path, val)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_editor_remove_seq_item(
    ed: ?*FigEditor,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    index: usize,
) FigStatus {
    const handle = editorFrom(ed) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    return switch (handle.inner) {
        inline else => |*e| if (e.removeSeqItem(path, index)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_editor_move_key(
    ed: ?*FigEditor,
    src_ptr: ?[*]const FigPathSegment,
    src_len: usize,
    dest_ptr: ?[*]const FigPathSegment,
    dest_len: usize,
) FigStatus {
    const handle = editorFrom(ed) orelse return .invalid_argument;
    var src_buf: [max_path_len]AST.PathSegment = undefined;
    var dest_buf: [max_path_len]AST.PathSegment = undefined;
    const src = decodePath(src_ptr, src_len, &src_buf) orelse return .invalid_argument;
    const dest = decodePath(dest_ptr, dest_len, &dest_buf) orelse return .invalid_argument;
    return switch (handle.inner) {
        inline else => |*e| if (e.moveKey(src, dest)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_editor_reorder_keys(
    ed: ?*FigEditor,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    keys_ptr: ?[*]const FigStr,
    keys_len: usize,
) FigStatus {
    const handle = editorFrom(ed) orelse return .invalid_argument;
    var path_buf: [max_path_len]AST.PathSegment = undefined;
    var keys_buf: [max_keys_len][]const u8 = undefined;
    const path = decodePath(path_ptr, path_len, &path_buf) orelse return .invalid_argument;
    const keys = decodeKeys(keys_ptr, keys_len, &keys_buf) orelse return .invalid_argument;
    return switch (handle.inner) {
        inline else => |*e| if (e.reorderKeys(path, keys)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_editor_move_item(
    ed: ?*FigEditor,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    from: usize,
    to: usize,
) FigStatus {
    const handle = editorFrom(ed) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    return switch (handle.inner) {
        inline else => |*e| if (e.moveItem(path, from, to)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_editor_reorder_items(
    ed: ?*FigEditor,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    indices_ptr: ?[*]const usize,
    indices_len: usize,
) FigStatus {
    const handle = editorFrom(ed) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const indices = decodeIndices(indices_ptr, indices_len) orelse return .invalid_argument;
    return switch (handle.inner) {
        inline else => |*e| if (e.reorderItems(path, indices)) .ok else |err| editStatus(err),
    };
}

/// Borrow the editor's current source bytes. Valid until the next mutation or
/// `fig_editor_destroy`.
pub export fn fig_editor_source(
    ed: ?*const FigEditor,
    out_ptr: ?*[*c]const u8,
    out_len: ?*usize,
) FigStatus {
    const p = out_ptr orelse return .invalid_argument;
    const l = out_len orelse return .invalid_argument;
    const handle: *const EditorHandle = @ptrCast(@alignCast(ed orelse return .invalid_argument));
    switch (handle.inner) {
        inline else => |*e| {
            p.* = e.source.items.ptr;
            l.* = e.source.items.len;
        },
    }
    return .ok;
}

fn sliceOf(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0) return &.{};
    const p = ptr orelse return null;
    return p[0..len];
}

// ============
// EMBED (LOW-LEVEL)
// ============

pub const FigSpan = extern struct { start: usize, end: usize };
pub const FigRegion = extern struct {
    open_fence: FigSpan,
    content: FigSpan,
    close_fence: FigSpan,
};

/// Mirrors `Embed.Type`.
pub const FigEmbedType = enum(c_int) {
    frontmatter_yaml = 0,
    frontmatter_json = 1,
    endmatter_yaml = 2,
};

fn embedTypeOf(t: c_int) ?Embed.Type {
    return switch (t) {
        @intFromEnum(FigEmbedType.frontmatter_yaml) => .FrontmatterYaml,
        @intFromEnum(FigEmbedType.frontmatter_json) => .FrontmatterJson,
        @intFromEnum(FigEmbedType.endmatter_yaml) => .EndmatterYaml,
        else => null,
    };
}

fn toFigSpan(s: Span) FigSpan {
    return .{ .start = s.start, .end = s.end };
}

/// Locate an embedded region (e.g. markdown frontmatter) and report its
/// fence/content spans in host-file coordinates. Does not parse the content.
pub export fn fig_embed_extract(
    input_ptr: ?[*]const u8,
    input_len: usize,
    embed_type: c_int,
    out_region: ?*FigRegion,
) FigStatus {
    const out = out_region orelse return .invalid_argument;
    const input = sliceOf(input_ptr, input_len) orelse return .invalid_argument;
    const t = embedTypeOf(embed_type) orelse return .invalid_argument;
    const region = Embed.locateRegion(input, t) catch |err| return switch (err) {
        error.NotFound => .not_found,
        else => .parse_error,
    };
    out.* = .{
        .open_fence = toFigSpan(region.open_fence),
        .content = toFigSpan(region.content),
        .close_fence = toFigSpan(region.close_fence),
    };
    return .ok;
}

// ====================
// FRONTMATTER (COMBINED)
// ====================
//
// Holds an owned copy of the host markdown plus a YAML editor over the
// frontmatter content. Edits delegate to the editor; `fig_fm_render`
// re-splices the edited content between the (untouched) fences + body.

pub const FigFrontmatter = opaque {};

const FrontmatterHandle = struct {
    allocator: std.mem.Allocator,
    markdown: []u8,
    content: Span,
    editor: Editor(YamlLang),
    rendered: std.ArrayList(u8) = .empty,
};

fn fmFrom(fm: ?*FigFrontmatter) ?*FrontmatterHandle {
    const p = fm orelse return null;
    return @ptrCast(@alignCast(p));
}

pub export fn fig_fm_open(
    input_ptr: ?[*]const u8,
    input_len: usize,
    out_fm: ?*?*FigFrontmatter,
) FigStatus {
    const out = out_fm orelse return .invalid_argument;
    out.* = null;
    const input = sliceOf(input_ptr, input_len) orelse return .invalid_argument;

    const region = Embed.locateRegion(input, .FrontmatterYaml) catch |err| return switch (err) {
        error.NotFound => .not_found,
        else => .parse_error,
    };

    const allocator = activeAllocator();
    const markdown = allocator.dupe(u8, input) catch return .out_of_memory;
    const handle = allocator.create(FrontmatterHandle) catch {
        allocator.free(markdown);
        return .out_of_memory;
    };
    handle.* = .{
        .allocator = allocator,
        .markdown = markdown,
        .content = region.content,
        .editor = .{ .allocator = allocator },
    };
    handle.editor.init(markdown[region.content.start..region.content.end]) catch |err| {
        allocator.free(markdown);
        allocator.destroy(handle);
        return editStatus(err);
    };

    out.* = @ptrCast(handle);
    return .ok;
}

pub export fn fig_fm_destroy(fm: ?*FigFrontmatter) void {
    const handle = fmFrom(fm) orelse return;
    const allocator = handle.allocator;
    handle.editor.deinit();
    handle.rendered.deinit(allocator);
    allocator.free(handle.markdown);
    allocator.destroy(handle);
}

pub export fn fig_fm_replace_val(
    fm: ?*FigFrontmatter,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    repl_ptr: ?[*]const u8,
    repl_len: usize,
) FigStatus {
    const handle = fmFrom(fm) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const repl = sliceOf(repl_ptr, repl_len) orelse return .invalid_argument;
    handle.editor.replaceValAtPath(path, repl) catch |err| return editStatus(err);
    return .ok;
}

pub export fn fig_fm_replace_key(
    fm: ?*FigFrontmatter,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    repl_ptr: ?[*]const u8,
    repl_len: usize,
) FigStatus {
    const handle = fmFrom(fm) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const repl = sliceOf(repl_ptr, repl_len) orelse return .invalid_argument;
    handle.editor.replaceKeyAtPath(path, repl) catch |err| return editStatus(err);
    return .ok;
}

pub export fn fig_fm_insert_key(
    fm: ?*FigFrontmatter,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    key_ptr: ?[*]const u8,
    key_len: usize,
    val_ptr: ?[*]const u8,
    val_len: usize,
) FigStatus {
    const handle = fmFrom(fm) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const key = sliceOf(key_ptr, key_len) orelse return .invalid_argument;
    const val = sliceOf(val_ptr, val_len) orelse return .invalid_argument;
    handle.editor.insertKey(path, key, val) catch |err| return editStatus(err);
    return .ok;
}

pub export fn fig_fm_delete_key(
    fm: ?*FigFrontmatter,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
) FigStatus {
    const handle = fmFrom(fm) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    handle.editor.deleteKey(path) catch |err| return editStatus(err);
    return .ok;
}

pub export fn fig_fm_append_seq(
    fm: ?*FigFrontmatter,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    val_ptr: ?[*]const u8,
    val_len: usize,
) FigStatus {
    const handle = fmFrom(fm) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const val = sliceOf(val_ptr, val_len) orelse return .invalid_argument;
    handle.editor.appendToSeq(path, val) catch |err| return editStatus(err);
    return .ok;
}

pub export fn fig_fm_prepend_seq(
    fm: ?*FigFrontmatter,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    val_ptr: ?[*]const u8,
    val_len: usize,
) FigStatus {
    const handle = fmFrom(fm) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const val = sliceOf(val_ptr, val_len) orelse return .invalid_argument;
    handle.editor.prependToSeq(path, val) catch |err| return editStatus(err);
    return .ok;
}

pub export fn fig_fm_remove_seq_item(
    fm: ?*FigFrontmatter,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    index: usize,
) FigStatus {
    const handle = fmFrom(fm) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    handle.editor.removeSeqItem(path, index) catch |err| return editStatus(err);
    return .ok;
}

pub export fn fig_fm_move_key(
    fm: ?*FigFrontmatter,
    src_ptr: ?[*]const FigPathSegment,
    src_len: usize,
    dest_ptr: ?[*]const FigPathSegment,
    dest_len: usize,
) FigStatus {
    const handle = fmFrom(fm) orelse return .invalid_argument;
    var src_buf: [max_path_len]AST.PathSegment = undefined;
    var dest_buf: [max_path_len]AST.PathSegment = undefined;
    const src = decodePath(src_ptr, src_len, &src_buf) orelse return .invalid_argument;
    const dest = decodePath(dest_ptr, dest_len, &dest_buf) orelse return .invalid_argument;
    handle.editor.moveKey(src, dest) catch |err| return editStatus(err);
    return .ok;
}

pub export fn fig_fm_reorder_keys(
    fm: ?*FigFrontmatter,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    keys_ptr: ?[*]const FigStr,
    keys_len: usize,
) FigStatus {
    const handle = fmFrom(fm) orelse return .invalid_argument;
    var path_buf: [max_path_len]AST.PathSegment = undefined;
    var keys_buf: [max_keys_len][]const u8 = undefined;
    const path = decodePath(path_ptr, path_len, &path_buf) orelse return .invalid_argument;
    const keys = decodeKeys(keys_ptr, keys_len, &keys_buf) orelse return .invalid_argument;
    handle.editor.reorderKeys(path, keys) catch |err| return editStatus(err);
    return .ok;
}

pub export fn fig_fm_move_item(
    fm: ?*FigFrontmatter,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    from: usize,
    to: usize,
) FigStatus {
    const handle = fmFrom(fm) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    handle.editor.moveItem(path, from, to) catch |err| return editStatus(err);
    return .ok;
}

pub export fn fig_fm_reorder_items(
    fm: ?*FigFrontmatter,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    indices_ptr: ?[*]const usize,
    indices_len: usize,
) FigStatus {
    const handle = fmFrom(fm) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const indices = decodeIndices(indices_ptr, indices_len) orelse return .invalid_argument;
    handle.editor.reorderItems(path, indices) catch |err| return editStatus(err);
    return .ok;
}

/// Render the full host file with the edited frontmatter spliced back between
/// the original fences. Borrowed bytes, valid until the next call or destroy.
pub export fn fig_fm_render(
    fm: ?*FigFrontmatter,
    out_ptr: ?*[*c]const u8,
    out_len: ?*usize,
) FigStatus {
    const p = out_ptr orelse return .invalid_argument;
    const l = out_len orelse return .invalid_argument;
    const handle = fmFrom(fm) orelse return .invalid_argument;

    handle.rendered.clearRetainingCapacity();
    const md = handle.markdown;
    handle.rendered.appendSlice(handle.allocator, md[0..handle.content.start]) catch return .out_of_memory;
    handle.rendered.appendSlice(handle.allocator, handle.editor.source.items) catch return .out_of_memory;
    handle.rendered.appendSlice(handle.allocator, md[handle.content.end..]) catch return .out_of_memory;

    p.* = handle.rendered.items.ptr;
    l.* = handle.rendered.items.len;
    return .ok;
}

// ==============================
// VALUE CONSTRUCTION + SERIALIZE
// ==============================
//
// The build/serialize counterpart to the read-side traversal API: construct a
// fresh value tree node-by-node (the mirror of `AST.Builder`), then render it to
// any supported format. Construction is bottom-up — build children, then the
// container from their ids — and every `fig_value_*` builder call returns the new
// node's id through `out_id`. A built value owns no source, so all input bytes
// are copied; the rendered output is borrowed (valid until the next
// `fig_value_serialize` or `fig_value_destroy`), so callers copy it out.

pub const FigValue = opaque {};

/// A `key: value` entry for `fig_value_map`; both are ids returned by earlier
/// `fig_value_*` calls. Mirrors `AST.Builder.Entry`.
pub const FigKeyValue = extern struct {
    key: FigNodeId,
    value: FigNodeId,
};

/// The format-specific scalar kinds, mirroring `AST.Node.Kind.Extended.ExtKind`.
pub const FigExtKind = enum(c_int) {
    offset_datetime = 0,
    local_datetime = 1,
    local_date = 2,
    local_time = 3,
    enum_literal = 4,
    char_literal = 5,
};

const ValueHandle = struct {
    allocator: std.mem.Allocator,
    builder: AST.Builder,
    /// Reused across `fig_value_serialize` calls; holds the bytes the most recent
    /// call returned (cleared and refilled each time).
    rendered: std.Io.Writer.Allocating,
};

fn valueFrom(value: ?*FigValue) ?*ValueHandle {
    const p = value orelse return null;
    return @ptrCast(@alignCast(p));
}

fn extKindOf(kind: c_int) ?AST.Node.Kind.Extended.ExtKind {
    return switch (kind) {
        @intFromEnum(FigExtKind.offset_datetime) => .offset_datetime,
        @intFromEnum(FigExtKind.local_datetime) => .local_datetime,
        @intFromEnum(FigExtKind.local_date) => .local_date,
        @intFromEnum(FigExtKind.local_time) => .local_time,
        @intFromEnum(FigExtKind.enum_literal) => .enum_literal,
        @intFromEnum(FigExtKind.char_literal) => .char_literal,
        else => null,
    };
}

fn serializeFormatOf(format: c_int) ?AST.SerializeFormat {
    return switch (format) {
        @intFromEnum(FigFormat.json), @intFromEnum(FigFormat.jsonc) => .json,
        @intFromEnum(FigFormat.yaml) => .yaml,
        @intFromEnum(FigFormat.toml) => .toml,
        @intFromEnum(FigFormat.zon) => .zon,
        else => null,
    };
}

/// Translate the canonical serialize error set onto `FigStatus`. Exhaustive over
/// `AST.SerializeError`: a representability failure (alias/null/non-string key in
/// a format that cannot hold it) maps to `unsupported_format`; the writer's only
/// other failure is allocation, surfaced as `WriteFailed`.
fn serializeStatus(err: AST.SerializeError) FigStatus {
    return switch (err) {
        error.UnresolvedAlias, error.NullUnsupported, error.NonStringKey => .unsupported_format,
        error.WriteFailed => .out_of_memory,
    };
}

/// Write the id produced by a builder call to `out_id`, mapping allocation
/// failure to a status. Builder construction can only fail on OOM.
fn emitNode(out_id: ?*FigNodeId, result: std.mem.Allocator.Error!AST.Node.Id) FigStatus {
    const out = out_id orelse return .invalid_argument;
    const id = result catch return .out_of_memory;
    out.* = id;
    return .ok;
}

pub export fn fig_value_create(out_value: ?*?*FigValue) FigStatus {
    const out = out_value orelse return .invalid_argument;
    out.* = null;
    const allocator = activeAllocator();
    const handle = allocator.create(ValueHandle) catch return .out_of_memory;
    handle.* = .{
        .allocator = allocator,
        .builder = AST.Builder.init(allocator),
        .rendered = std.Io.Writer.Allocating.init(allocator),
    };
    out.* = @ptrCast(handle);
    return .ok;
}

pub export fn fig_value_destroy(value: ?*FigValue) void {
    const handle = valueFrom(value) orelse return;
    const allocator = handle.allocator;
    handle.builder.deinit();
    handle.rendered.deinit();
    allocator.destroy(handle);
}

pub export fn fig_value_null(value: ?*FigValue, out_id: ?*FigNodeId) FigStatus {
    const handle = valueFrom(value) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addNull());
}

pub export fn fig_value_bool(value: ?*FigValue, b: bool, out_id: ?*FigNodeId) FigStatus {
    const handle = valueFrom(value) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addBool(b));
}

pub export fn fig_value_int(value: ?*FigValue, n: i64, out_id: ?*FigNodeId) FigStatus {
    const handle = valueFrom(value) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addInt(n));
}

pub export fn fig_value_uint(value: ?*FigValue, n: u64, out_id: ?*FigNodeId) FigStatus {
    const handle = valueFrom(value) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addUint(n));
}

/// Add a numeric scalar from already-formatted text. `is_float` records the
/// `number.kind`. This is the float entry point (the canonical float-text policy
/// is the caller's for now — see `AST.Builder.addNumberRaw`) and the escape hatch
/// for integers outside the i64/u64 range.
pub export fn fig_value_number(
    value: ?*FigValue,
    raw_ptr: ?[*]const u8,
    raw_len: usize,
    is_float: bool,
    out_id: ?*FigNodeId,
) FigStatus {
    const handle = valueFrom(value) orelse return .invalid_argument;
    const raw = sliceOf(raw_ptr, raw_len) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addNumberRaw(raw, is_float));
}

pub export fn fig_value_string(
    value: ?*FigValue,
    ptr: ?[*]const u8,
    len: usize,
    out_id: ?*FigNodeId,
) FigStatus {
    const handle = valueFrom(value) orelse return .invalid_argument;
    const s = sliceOf(ptr, len) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addString(s));
}

pub export fn fig_value_extended(
    value: ?*FigValue,
    kind: c_int,
    text_ptr: ?[*]const u8,
    text_len: usize,
    out_id: ?*FigNodeId,
) FigStatus {
    const handle = valueFrom(value) orelse return .invalid_argument;
    const ext_kind = extKindOf(kind) orelse return .invalid_argument;
    const text = sliceOf(text_ptr, text_len) orelse return .invalid_argument;
    return emitNode(out_id, handle.builder.addExtended(ext_kind, text));
}

pub export fn fig_value_seq(
    value: ?*FigValue,
    items_ptr: ?[*]const FigNodeId,
    items_len: usize,
    out_id: ?*FigNodeId,
) FigStatus {
    const handle = valueFrom(value) orelse return .invalid_argument;
    // FigNodeId, AST.Node.Id are both u32, so the C array is already the Zig
    // slice the builder wants — no copy. Every id must name an existing node.
    const items: []const FigNodeId = if (items_len == 0) &.{} else (items_ptr orelse return .invalid_argument)[0..items_len];
    const count = handle.builder.nodes.items.len;
    for (items) |id| if (id >= count) return .invalid_argument;
    return emitNode(out_id, handle.builder.addSequence(items));
}

pub export fn fig_value_map(
    value: ?*FigValue,
    entries_ptr: ?[*]const FigKeyValue,
    entries_len: usize,
    out_id: ?*FigNodeId,
) FigStatus {
    const handle = valueFrom(value) orelse return .invalid_argument;
    if (entries_len == 0) return emitNode(out_id, handle.builder.addMapping(&.{}));
    const c_entries = (entries_ptr orelse return .invalid_argument)[0..entries_len];
    const count = handle.builder.nodes.items.len;
    // FigKeyValue is extern, Builder.Entry is not, so decode rather than cast.
    const entries = handle.allocator.alloc(AST.Builder.Entry, entries_len) catch return .out_of_memory;
    defer handle.allocator.free(entries);
    for (c_entries, entries) |c, *e| {
        if (c.key >= count or c.value >= count) return .invalid_argument;
        e.* = .{ .key = c.key, .value = c.value };
    }
    return emitNode(out_id, handle.builder.addMapping(entries));
}

/// Render the value subtree rooted at `root` in `format`. Output bytes are
/// borrowed from the handle and valid until the next `fig_value_serialize` or
/// `fig_value_destroy`.
pub export fn fig_value_serialize(
    value: ?*FigValue,
    root: FigNodeId,
    format: c_int,
    out_ptr: ?*[*c]const u8,
    out_len: ?*usize,
) FigStatus {
    const p = out_ptr orelse return .invalid_argument;
    const l = out_len orelse return .invalid_argument;
    const handle = valueFrom(value) orelse return .invalid_argument;
    const fmt = serializeFormatOf(format) orelse return .unsupported_format;
    if (root >= handle.builder.nodes.items.len) return .invalid_argument;

    handle.rendered.clearRetainingCapacity();
    const ast = handle.builder.view(root); // borrows the builder; never deinit'd
    ast.serialize(&handle.rendered.writer, fmt) catch |err| return serializeStatus(err);

    const bytes = handle.rendered.written();
    p.* = bytes.ptr;
    l.* = bytes.len;
    return .ok;
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

fn keySeg(s: []const u8) FigPathSegment {
    return .{ .kind = 0, .key_ptr = s.ptr, .key_len = s.len, .index = 0 };
}

test "editor c abi insert + source round-trip" {
    const src = "a: 1\nb: 2\n";
    var out_ed: ?*FigEditor = null;
    try std.testing.expectEqual(FigStatus.ok, fig_editor_create(src.ptr, src.len, @intFromEnum(FigFormat.yaml), &out_ed));
    defer fig_editor_destroy(out_ed);

    const c = "c";
    const three = "3";
    try std.testing.expectEqual(FigStatus.ok, fig_editor_insert_key(out_ed, null, 0, c.ptr, c.len, three.ptr, three.len));

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_editor_source(out_ed, &ptr, &len));
    try std.testing.expectEqualStrings("a: 1\nb: 2\nc: 3\n", ptr[0..len]);
}

test "editor c abi accepts empty input as an empty document" {
    var out_ed: ?*FigEditor = null;
    // Null pointer + zero length is a valid empty document.
    try std.testing.expectEqual(FigStatus.ok, fig_editor_create(null, 0, @intFromEnum(FigFormat.yaml), &out_ed));
    defer fig_editor_destroy(out_ed);

    const k = "k";
    const v = "v";
    try std.testing.expectEqual(FigStatus.ok, fig_editor_insert_key(out_ed, null, 0, k.ptr, k.len, v.ptr, v.len));

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_editor_source(out_ed, &ptr, &len));
    try std.testing.expectEqualStrings("k: v\n", ptr[0..len]);
}

test "frontmatter c abi preserves fences and body" {
    const md = "---\ntitle: Hi\n# keep\ntags:\n- x\n---\n# Body\ntext\n";
    var out_fm: ?*FigFrontmatter = null;
    try std.testing.expectEqual(FigStatus.ok, fig_fm_open(md.ptr, md.len, &out_fm));
    defer fig_fm_destroy(out_fm);

    const author = "author";
    const me = "me";
    try std.testing.expectEqual(FigStatus.ok, fig_fm_insert_key(out_fm, null, 0, author.ptr, author.len, me.ptr, me.len));

    const tags = [_]FigPathSegment{keySeg("tags")};
    const y = "y";
    try std.testing.expectEqual(FigStatus.ok, fig_fm_append_seq(out_fm, &tags, 1, y.ptr, y.len));

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_fm_render(out_fm, &ptr, &len));
    try std.testing.expectEqualStrings(
        "---\ntitle: Hi\n# keep\ntags:\n- x\n- y\nauthor: me\n---\n# Body\ntext\n",
        ptr[0..len],
    );
}

fn figStr(s: []const u8) FigStr {
    return .{ .ptr = s.ptr, .len = s.len };
}

test "frontmatter c abi reorder keys preserves comments, fences, body" {
    const md = "---\ntitle: Hi\n# keep\ntags:\n- x\nauthor: me\n---\n# Body\ntext\n";
    var out_fm: ?*FigFrontmatter = null;
    try std.testing.expectEqual(FigStatus.ok, fig_fm_open(md.ptr, md.len, &out_fm));
    defer fig_fm_destroy(out_fm);

    const keys = [_]FigStr{ figStr("author"), figStr("title") };
    try std.testing.expectEqual(FigStatus.ok, fig_fm_reorder_keys(out_fm, null, 0, &keys, keys.len));

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_fm_render(out_fm, &ptr, &len));
    try std.testing.expectEqualStrings(
        "---\nauthor: me\ntitle: Hi\n# keep\ntags:\n- x\n---\n# Body\ntext\n",
        ptr[0..len],
    );
}

test "frontmatter c abi move key preserves fences and body" {
    const md = "---\na: 1\nb: 2\nc: 3\n---\nbody\n";
    var out_fm: ?*FigFrontmatter = null;
    try std.testing.expectEqual(FigStatus.ok, fig_fm_open(md.ptr, md.len, &out_fm));
    defer fig_fm_destroy(out_fm);

    const src = [_]FigPathSegment{keySeg("c")};
    const dest = [_]FigPathSegment{keySeg("a")};
    try std.testing.expectEqual(FigStatus.ok, fig_fm_move_key(out_fm, &src, 1, &dest, 1));

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_fm_render(out_fm, &ptr, &len));
    try std.testing.expectEqualStrings("---\nc: 3\na: 1\nb: 2\n---\nbody\n", ptr[0..len]);
}

test "frontmatter c abi reorder items in a block sequence value" {
    const md = "---\ntags:\n- x\n- y\n- z\n---\nbody\n";
    var out_fm: ?*FigFrontmatter = null;
    try std.testing.expectEqual(FigStatus.ok, fig_fm_open(md.ptr, md.len, &out_fm));
    defer fig_fm_destroy(out_fm);

    const path = [_]FigPathSegment{keySeg("tags")};
    const indices = [_]usize{ 2, 0 };
    try std.testing.expectEqual(FigStatus.ok, fig_fm_reorder_items(out_fm, &path, 1, &indices, indices.len));

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_fm_render(out_fm, &ptr, &len));
    try std.testing.expectEqualStrings("---\ntags:\n- z\n- x\n- y\n---\nbody\n", ptr[0..len]);
}

test "frontmatter c abi move item in a flow sequence value" {
    const md = "---\ntags: [x, y, z]\n---\nbody\n";
    var out_fm: ?*FigFrontmatter = null;
    try std.testing.expectEqual(FigStatus.ok, fig_fm_open(md.ptr, md.len, &out_fm));
    defer fig_fm_destroy(out_fm);

    const path = [_]FigPathSegment{keySeg("tags")};
    try std.testing.expectEqual(FigStatus.ok, fig_fm_move_item(out_fm, &path, 1, 2, 0));

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_fm_render(out_fm, &ptr, &len));
    try std.testing.expectEqualStrings("---\ntags: [z, x, y]\n---\nbody\n", ptr[0..len]);
}

test "embed c abi locates region" {
    const md = "---\nk: v\n---\nbody\n";
    var region: FigRegion = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_extract(md.ptr, md.len, @intFromEnum(FigEmbedType.frontmatter_yaml), &region));
    try std.testing.expectEqualStrings("k: v\n", md[region.content.start..region.content.end]);
}

test "value c abi builds and serializes to multiple formats" {
    var out_value: ?*FigValue = null;
    try std.testing.expectEqual(FigStatus.ok, fig_value_create(&out_value));
    defer fig_value_destroy(out_value);

    // Build { "name": "fig", "nums": [1, 2] } bottom-up.
    var id: FigNodeId = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_value_string(out_value, "fig", 3, &id));
    const v_name = id;
    try std.testing.expectEqual(FigStatus.ok, fig_value_int(out_value, 1, &id));
    const n1 = id;
    try std.testing.expectEqual(FigStatus.ok, fig_value_int(out_value, 2, &id));
    const n2 = id;
    const items = [_]FigNodeId{ n1, n2 };
    try std.testing.expectEqual(FigStatus.ok, fig_value_seq(out_value, &items, items.len, &id));
    const v_nums = id;
    try std.testing.expectEqual(FigStatus.ok, fig_value_string(out_value, "name", 4, &id));
    const k_name = id;
    try std.testing.expectEqual(FigStatus.ok, fig_value_string(out_value, "nums", 4, &id));
    const k_nums = id;
    const entries = [_]FigKeyValue{ .{ .key = k_name, .value = v_name }, .{ .key = k_nums, .value = v_nums } };
    try std.testing.expectEqual(FigStatus.ok, fig_value_map(out_value, &entries, entries.len, &id));
    const root = id;

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_value_serialize(out_value, root, @intFromEnum(FigFormat.json), &ptr, &len));
    try std.testing.expectEqualStrings("{\n  \"name\": \"fig\",\n  \"nums\": [\n    1,\n    2\n  ]\n}\n", ptr[0..len]);

    // Same value, different format — the borrowed bytes are refreshed in place.
    try std.testing.expectEqual(FigStatus.ok, fig_value_serialize(out_value, root, @intFromEnum(FigFormat.yaml), &ptr, &len));
    try std.testing.expectEqualStrings("name: fig\nnums:\n- 1\n- 2\n", ptr[0..len]);
}

test "value c abi maps an unrepresentable value to unsupported_format" {
    var out_value: ?*FigValue = null;
    try std.testing.expectEqual(FigStatus.ok, fig_value_create(&out_value));
    defer fig_value_destroy(out_value);

    // { "k": null } — TOML has no null, so serializing to TOML must fail cleanly.
    var id: FigNodeId = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_value_null(out_value, &id));
    const v_null = id;
    try std.testing.expectEqual(FigStatus.ok, fig_value_string(out_value, "k", 1, &id));
    const k = id;
    const entries = [_]FigKeyValue{.{ .key = k, .value = v_null }};
    try std.testing.expectEqual(FigStatus.ok, fig_value_map(out_value, &entries, entries.len, &id));
    const root = id;

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.unsupported_format, fig_value_serialize(out_value, root, @intFromEnum(FigFormat.toml), &ptr, &len));
    // The same value serializes fine to a format that has null.
    try std.testing.expectEqual(FigStatus.ok, fig_value_serialize(out_value, root, @intFromEnum(FigFormat.json), &ptr, &len));
    try std.testing.expectEqualStrings("{\n  \"k\": null\n}\n", ptr[0..len]);
}

test "value c abi rejects an out-of-range child id" {
    var out_value: ?*FigValue = null;
    try std.testing.expectEqual(FigStatus.ok, fig_value_create(&out_value));
    defer fig_value_destroy(out_value);

    var id: FigNodeId = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_value_int(out_value, 1, &id));
    // id 99 was never created.
    const items = [_]FigNodeId{ id, 99 };
    try std.testing.expectEqual(FigStatus.invalid_argument, fig_value_seq(out_value, &items, items.len, &id));
}
