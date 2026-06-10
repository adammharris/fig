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

test "embed c abi locates region" {
    const md = "---\nk: v\n---\nbody\n";
    var region: FigRegion = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_extract(md.ptr, md.len, @intFromEnum(FigEmbedType.frontmatter_yaml), &region));
    try std.testing.expectEqualStrings("k: v\n", md[region.content.start..region.content.end]);
}
