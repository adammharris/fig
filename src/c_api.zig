//! C ABI for `fig`
//!
//! This file is the entry point for programs accessing `fig` outside of the Zig language.

const std = @import("std");
const builtin = @import("builtin");
const Document = @import("document.zig");
const AST = @import("ast/ast.zig");
const Span = @import("util/span.zig");
const Embed = @import("embed.zig");
const Editor = @import("editor.zig").Editor;
const build_options = @import("build_options");
const JsonParser = @import("json/parser.zig");
const JsonType = @import("json/json.zig").Type;
const JsonLang = @import("json/json.zig").Language;
// Gated formats collapse to `void`; every reference below is behind the matching
// `build_options.lang_*` comptime guard so the parser/printer never compiles in.
const YamlParser = if (build_options.lang_yaml) @import("yaml/parser.zig") else void;
const YamlType = if (build_options.lang_yaml) @import("yaml/yaml.zig").Type else void;
const YamlLang = if (build_options.lang_yaml) @import("yaml/yaml.zig").Language else void;
const TomlParser = if (build_options.lang_toml) @import("toml/parser.zig") else void;
const TomlType = if (build_options.lang_toml) @import("toml/toml.zig").Type else void;
const ZonParser = if (build_options.lang_zon) @import("zon/parser.zig") else void;
const ZonType = if (build_options.lang_zon) @import("zon/zon.zig").Type else void;
const XmlParser = if (build_options.lang_xml) @import("xml/parser.zig") else void;
const XmlType = if (build_options.lang_xml) @import("xml/xml.zig").Type else void;
// Cross-format conversion helpers used by `fig_document_serialize`. `Lossless` is
// format-agnostic (always compiled in); `materialize` is YAML-only, so it follows
// the gated-import pattern above (collapses to `void` when YAML is off, and every
// reference to it sits behind the matching comptime guard).
const Lossless = @import("lossless.zig");
const Diagnostics = @import("diagnostics.zig");
const YamlMaterialize = if (build_options.lang_yaml) @import("yaml/materialize.zig") else void;

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
/// member: `fig_parse` accepts all of them; the editor (`fig_editor_*`) supports
/// `json`/`jsonc`/`json5`/`yaml` only (others return `unsupported_format`); the
/// serializer (`fig_value_serialize`) accepts `json`/`jsonc`/`json5`/`yaml`/
/// `toml`/`zon` (JSONC = plain-JSON syntax with comments).
pub const FigFormat = enum(c_int) {
    json = 1,
    jsonc = 2,
    yaml = 3,
    toml = 4,
    zon = 5,
    /// Reader-only: accepted by `fig_parse`; rejected by `fig_editor_*` and
    /// `fig_value_serialize` (no XML writer yet) with `unsupported_format`.
    xml = 6,
    /// JSON5: read, written, and edited (via `fig_editor_*`). Appended (not
    /// inserted) to keep the ABI values of the existing members stable.
    json5 = 7,
};

// ==================
// VERSION + CAPABILITIES
// ==================
//
// The stable query surface a host uses to interrogate the linked library before
// trusting it: which version it is, and what it can actually do in THIS build
// (formats can be compiled out — see `build_options.lang_*`). Both are pure
// functions: no handle, no allocation, safe to call from any thread at any time.

/// Packed library version `(major << 16) | (minor << 8) | patch`. A host can
/// compare this against the `FIG_VERSION_*` macros it compiled with to detect a
/// header/library skew. Sourced from `build.zig` (kept in sync with build.zig.zon).
pub export fn fig_version() u32 {
    return (@as(u32, build_options.version_major) << 16) |
        (@as(u32, build_options.version_minor) << 8) |
        @as(u32, build_options.version_patch);
}

/// Null-terminated semantic version string of the linked library (e.g. "0.0.0").
/// Static storage — the caller must NOT free the returned pointer.
pub export fn fig_version_string() [*:0]const u8 {
    const s = std.fmt.comptimePrint("{d}.{d}.{d}", .{
        build_options.version_major,
        build_options.version_minor,
        build_options.version_patch,
    });
    return s;
}

/// Capability bits returned (OR-combined) by `fig_format_capabilities`.
pub const FigCapability = enum(u32) {
    /// `fig_parse` accepts this format.
    read = 1 << 0,
    /// `fig_editor_*` / `fig_embed_*` accept this format.
    edit = 1 << 1,
    /// `fig_*_serialize` can write this format.
    serialize = 1 << 2,
    _,
};

/// Report what `fig` can do with `format` in THIS build as a bitmask of
/// `FigCapability` (read | edit | serialize). Reflects both the format's inherent
/// support (XML is reader-only; TOML/ZON parse and serialize but are not editable)
/// and build-time gating: a format compiled out reports 0, as does an unknown
/// `format` value. JSON/JSONC/JSON5 are always fully supported. Lets a host pick a
/// working format up front instead of probing via `unsupported_format` returns.
pub export fn fig_format_capabilities(format: c_int) u32 {
    const read = @intFromEnum(FigCapability.read);
    const edit = @intFromEnum(FigCapability.edit);
    const serialize = @intFromEnum(FigCapability.serialize);
    return switch (format) {
        @intFromEnum(FigFormat.json),
        @intFromEnum(FigFormat.jsonc),
        @intFromEnum(FigFormat.json5),
        => read | edit | serialize,
        @intFromEnum(FigFormat.yaml) => if (comptime build_options.lang_yaml) read | edit | serialize else 0,
        @intFromEnum(FigFormat.toml) => if (comptime build_options.lang_toml) read | serialize else 0,
        @intFromEnum(FigFormat.zon) => if (comptime build_options.lang_zon) read | serialize else 0,
        @intFromEnum(FigFormat.xml) => if (comptime build_options.lang_xml) read else 0,
        else => 0,
    };
}

/// A handle to a `fig` document. (See `DocumentHandle` and `handle.*` declaration in `fig_parse`)
pub const FigDocument = opaque {};
const DocumentHandle = struct {
    allocator: std.mem.Allocator,
    source: []u8,
    document: Document,
    /// The format `source` was parsed as. `fig_document_serialize` consults it to
    /// decide whether to collapse YAML's reference layer before printing.
    format: FigFormat,
    /// Reused across `fig_document_serialize` calls; holds the bytes the most
    /// recent call returned (cleared and refilled each time). Mirrors
    /// `ValueHandle.rendered`.
    rendered: std.Io.Writer.Allocating,
    /// Backs the warnings (and their path strings) the most recent
    /// `fig_document_diagnose` produced; reset (not freed) each call, so the
    /// `path`/`note` bytes a `FigWarning` borrows are valid only until the next
    /// diagnose on this handle or `fig_document_destroy`.
    diag_arena: std.heap.ArenaAllocator,
    /// The warning set the most recent `fig_document_diagnose` computed (stored
    /// in `diag_arena`); `fig_document_warning` indexes into it. Empty until the
    /// first diagnose. Replaced (not appended) each diagnose call.
    diag_warnings: []const Diagnostics.Warning = &.{},
};

fn activeAllocator() std.mem.Allocator {
    return if (builtin.cpu.arch.isWasm())
        std.heap.wasm_allocator
    else
        std.heap.c_allocator;
}

// ==================
// RAW MEMORY (for hosts without a shared allocator)
// ==================
//
// A caller that does not share this library's address space — chiefly the
// WebAssembly bindings — cannot otherwise place input bytes where the API can
// read them, nor read borrowed output without first copying it into a buffer it
// owns. These two entry points expose `activeAllocator()` for exactly that: in
// the wasm build they let JavaScript allocate inside linear memory, write the
// input, hand the pointer to `fig_parse`/`fig_editor_*`/…, then release it.
// Buffers obtained here MUST be released with `fig_free`, passing the same
// length that was requested.

/// Allocate `len` bytes and return a pointer to them, or null on failure / a
/// zero-length request. Bytes are uninitialized. Release with `fig_free`.
pub export fn fig_alloc(len: usize) ?[*]u8 {
    if (len == 0) return null;
    const mem = activeAllocator().alloc(u8, len) catch return null;
    return mem.ptr;
}

/// Release a buffer obtained from `fig_alloc`. `len` must equal the length that
/// was requested. A null pointer or zero length is a no-op.
pub export fn fig_free(ptr: ?[*]u8, len: usize) void {
    const p = ptr orelse return;
    if (len == 0) return;
    activeAllocator().free(p[0..len]);
}

/// Caller-allocated parse diagnostic. Mirrors `FigError` in `include/fig.h`.
/// Caller-allocated + size-versioned for the same reason `FigSerializeOptions`
/// is: the library writes only the fields the caller's `size` covers, so fields
/// may be appended later without breaking an older layout. Caller-owned (no
/// allocation, no handle lifetime) is what lets it carry a message for a failure
/// that happens *before* any document handle exists.
pub const FigError = extern struct {
    size: u32,
    code: c_int,
    byte_offset: usize,
    line: u32,
    column: u32,
    message_len: usize,
    message: [256]u8,
};

/// Whether the caller-reported `FigError.size` covers `field` (same rule as
/// `optionCovers`). A field past `size` is absent in the caller's layout and
/// must not be written.
fn errCovers(size: u32, comptime field: []const u8) bool {
    const end = @offsetOf(FigError, field) + @sizeOf(@FieldType(FigError, field));
    return size >= end;
}

/// Fill `out_err` (if non-null) with `status` + `message`, then return `status`
/// so a failure path can `return fillError(...)`. Every field is gated on the
/// caller's `size`, so an older/smaller struct receives only the fields it
/// declared. `byte_offset`/`line`/`column` are 0 ("unknown") in this release —
/// surfacing the failing span from each parser is a planned follow-up.
fn fillError(out_err: ?*FigError, status: FigStatus, message: []const u8) FigStatus {
    const e = out_err orelse return status;
    const size = e.size;
    if (errCovers(size, "code")) e.code = @intFromEnum(status);
    if (errCovers(size, "byte_offset")) e.byte_offset = 0;
    if (errCovers(size, "line")) e.line = 0;
    if (errCovers(size, "column")) e.column = 0;
    // `message_len` and `message` are written together, and only when `size`
    // covers the whole inline array — a partially-covered buffer gets nothing
    // rather than a string truncated without its NUL terminator.
    if (errCovers(size, "message")) {
        const n = @min(message.len, e.message.len - 1);
        @memcpy(e.message[0..n], message[0..n]);
        e.message[n] = 0;
        e.message_len = n;
    }
    return status;
}

pub export fn fig_parse(
    input_ptr: ?[*]const u8,
    input_len: usize,
    format: c_int,
    out_doc: ?*?*FigDocument,
) FigStatus {
    return fig_parse_ex(input_ptr, input_len, format, out_doc, null);
}

/// As `fig_parse`, but on a nonzero return also fills `out_err` (caller-allocated;
/// nullable — NULL makes this identical to `fig_parse`) with a diagnostic. On
/// `.ok` the contents of `out_err` are left unspecified.
pub export fn fig_parse_ex(
    input_ptr: ?[*]const u8,
    input_len: usize,
    format: c_int,
    out_doc: ?*?*FigDocument,
    out_err: ?*FigError,
) FigStatus {
    const out = out_doc orelse return fillError(out_err, .invalid_argument, "out_doc is null");
    out.* = null;

    // Empty input (len 0, null pointer or not) is a valid slice handed to the
    // parser, which judges it per format (YAML → null document, TOML → empty
    // table, JSON/JSON5/ZON/XML → parse_error). Only a null pointer paired with a
    // nonzero length is a malformed argument. This mirrors `fig_editor_create`.
    const input = sliceOf(input_ptr, input_len) orelse
        return fillError(out_err, .invalid_argument, "null input with nonzero length");

    const fig_format: FigFormat = switch (format) {
        @intFromEnum(FigFormat.json) => .json,
        @intFromEnum(FigFormat.jsonc) => .jsonc,
        @intFromEnum(FigFormat.json5) => .json5,
        @intFromEnum(FigFormat.yaml) => .yaml,
        @intFromEnum(FigFormat.toml) => .toml,
        @intFromEnum(FigFormat.zon) => .zon,
        @intFromEnum(FigFormat.xml) => .xml,
        else => return fillError(out_err, .unsupported_format, "unsupported or unknown format"),
    };

    const allocator = activeAllocator();

    const source = allocator.dupe(u8, input) catch
        return fillError(out_err, .out_of_memory, "out of memory");
    const handle = allocator.create(DocumentHandle) catch {
        allocator.free(source);
        return fillError(out_err, .out_of_memory, "out of memory");
    };

    // On any parser error: free the not-yet-installed source/handle and report
    // the error name as the message. The parser error set is payload-free, so the
    // name is the best diagnostic available until per-parser span plumbing lands;
    // `byte_offset`/`line`/`column` stay 0 for now.
    const doc = switch (fig_format) {
        .json => JsonParser.parse(allocator, source, JsonType.JSON) catch |err|
            return parseFailed(out_err, err, source, handle),
        .jsonc => JsonParser.parse(allocator, source, JsonType.JSONC) catch |err|
            return parseFailed(out_err, err, source, handle),
        .json5 => JsonParser.parse(allocator, source, JsonType.JSON5) catch |err|
            return parseFailed(out_err, err, source, handle),
        .yaml => if (comptime build_options.lang_yaml)
            YamlParser.parse(allocator, source, YamlType.v1_2_2) catch |err|
                return parseFailed(out_err, err, source, handle)
        else
            return formatDisabled(out_err, source, handle),
        .toml => if (comptime build_options.lang_toml)
            TomlParser.parse(allocator, source, TomlType.TOML_1_1) catch |err|
                return parseFailed(out_err, err, source, handle)
        else
            return formatDisabled(out_err, source, handle),
        .zon => if (comptime build_options.lang_zon)
            ZonParser.parse(allocator, source, ZonType.ZON) catch |err|
                return parseFailed(out_err, err, source, handle)
        else
            return formatDisabled(out_err, source, handle),
        .xml => if (comptime build_options.lang_xml)
            XmlParser.parse(allocator, source, XmlType.XML_1_0) catch |err|
                return parseFailed(out_err, err, source, handle)
        else
            return formatDisabled(out_err, source, handle),
    };

    handle.* = .{
        .allocator = allocator,
        .source = source,
        .document = doc,
        .format = fig_format,
        .rendered = std.Io.Writer.Allocating.init(allocator),
        .diag_arena = std.heap.ArenaAllocator.init(allocator),
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

/// Shared cleanup + diagnostic for a failed parse: release the not-yet-installed
/// `source`/`handle`, then report the error (its name as the message).
fn parseFailed(out_err: ?*FigError, err: anyerror, source: []u8, handle: *DocumentHandle) FigStatus {
    const allocator = activeAllocator();
    allocator.free(source);
    allocator.destroy(handle);
    return fillError(out_err, parseFailureStatus(err), @errorName(err));
}

/// Cleanup + diagnostic for a format compiled out of this build.
fn formatDisabled(out_err: ?*FigError, source: []u8, handle: *DocumentHandle) FigStatus {
    const allocator = activeAllocator();
    allocator.free(source);
    allocator.destroy(handle);
    return fillError(out_err, .unsupported_format, "format not compiled into this build");
}

/// Memory allocated by this API should be freed by this API.
pub export fn fig_document_destroy(doc: ?*FigDocument) void {
    const public_doc = doc orelse return;
    const handle: *DocumentHandle = @ptrCast(@alignCast(public_doc));
    handle.rendered.deinit();
    handle.diag_arena.deinit();
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

/// Recover the precise kind and text of a format-specific extended scalar (TOML
/// datetime, ZON enum/char literal). Returns true and writes its `FigExtKind` to
/// `out_kind` and source text to `out_ptr`/`out_len` when `node` is extended;
/// otherwise returns false, leaving the out-params untouched.
///
/// `fig_node_kind` still reports these nodes as STRING (datetime / enum literal)
/// or INT (char literal) for ABI compatibility, and `fig_node_string` /
/// `fig_node_number` still yield their text; this accessor is the opt-in way to
/// distinguish a true string/int from an extended scalar.
pub export fn fig_node_extended(
    doc: ?*const FigDocument,
    node: FigNodeId,
    out_kind: ?*c_int,
    out_ptr: ?*[*c]const u8,
    out_len: ?*usize,
) bool {
    const k = out_kind orelse return false;
    const p = out_ptr orelse return false;
    const l = out_len orelse return false;
    const n = nodeAt(doc, node) orelse return false;
    switch (n.kind) {
        .extended => |ext| {
            k.* = @intFromEnum(figExtKindOf(ext.kind));
            p.* = ext.text.ptr;
            l.* = ext.text.len;
            return true;
        },
        else => return false,
    }
}

/// Map an AST extended kind to its C ABI enumerator. The two enums carry the
/// same cases in the same order; the explicit switch keeps them pinned together.
fn figExtKindOf(kind: AST.Node.Kind.Extended.ExtKind) FigExtKind {
    return switch (kind) {
        .offset_datetime => .offset_datetime,
        .local_datetime => .local_datetime,
        .local_date => .local_date,
        .local_time => .local_time,
        .enum_literal => .enum_literal,
        .char_literal => .char_literal,
        .number_special => .number_special,
    };
}

// ======
// EDITING
// ======
//
// The write path mirrors the read path: an opaque handle owns the source +
// parse, and edits splice bytes in place (preserving comments/formatting) then
// reparse. `fig_editor_*` works on a whole document; `fig_embed_*` is a thin
// embed-aware layer that edits the config inside a host file (e.g. markdown
// frontmatter) and re-assembles it. Path segments cross the boundary as an array
// of `FigPathSegment` (key string | sequence index), mirroring `AST.PathSegment`.

/// One step of a path: `kind == 0` selects mapping key `key_ptr[0..key_len]`;
/// `kind == 1` selects sequence element `index`. `kind` is a C `int` (not a
/// fixed-width `int32_t`), matching the other small discriminants crossing this
/// ABI — `format`, `embed_type`, and the `kind` of `fig_value_extended` /
/// `fig_node_extended` — so every enum-like field is the one integer type.
pub const FigPathSegment = extern struct {
    kind: c_int,
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
        // The target dialect has no comment syntax (strict JSON).
        error.CommentsUnsupported => .unsupported_format,
        // A trailing comment was given multi-line text.
        error.MultilineComment => .invalid_argument,
        error.NotInitialized, error.MultipleInit, error.InvalidSpan => .internal_error,
        // A reparse after a malformed edit lands here.
        else => .parse_error,
    };
}

pub const FigEditor = opaque {};

// The editor backends, shared by the document editor and the embed editor. The
// `yaml` variant only exists when YAML is compiled in — gating it out (rather
// than leaving a `void` field) keeps the `inline else` switches below valid.
const EditorUnion = if (build_options.lang_yaml)
    union(enum) {
        yaml: Editor(YamlLang),
        json: Editor(JsonLang),
    }
else
    union(enum) {
        json: Editor(JsonLang),
    };

const EditorHandle = struct {
    allocator: std.mem.Allocator,
    inner: EditorUnion,

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
        @intFromEnum(FigFormat.json5) => .json5,
        @intFromEnum(FigFormat.yaml) => if (comptime build_options.lang_yaml) .yaml else return .unsupported_format,
        else => return .unsupported_format,
    };

    const allocator = activeAllocator();
    const handle = allocator.create(EditorHandle) catch return .out_of_memory;
    handle.allocator = allocator;
    handle.inner = switch (fig_format) {
        .yaml => if (comptime build_options.lang_yaml) .{ .yaml = .{ .allocator = allocator } } else unreachable,
        .json => .{ .json = .{ .allocator = allocator } },
        .jsonc => .{ .json = .{ .allocator = allocator, .format = .JSONC } },
        // JSON5 edits route through the same generic JSON editor, just in the
        // JSON5 dialect (unquoted keys, trailing commas, `//` comments). The
        // editor splices source in place, so all of that survives untouched
        // outside the edited span.
        .json5 => .{ .json = .{ .allocator = allocator, .format = .JSON5 } },
        // Filtered out by the format switch above; editing these is not yet wired.
        .toml, .zon, .xml => unreachable,
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

// ── Comment editing ─────────────────────────────────────────────────────────
// Splice comment trivia around the node at `path`, preserving the rest of the
// document byte-for-byte. The marker (`#`, `//`) is added by the editor; a
// dialect without comment syntax (strict JSON) returns `unsupported_format`.

/// Add an own-line comment ABOVE the node at `path`. `text` may be multi-line
/// (one comment line per row), at the node's indentation, nearest the node.
pub export fn fig_editor_add_leading_comment(
    ed: ?*FigEditor,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
) FigStatus {
    const handle = editorFrom(ed) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const text = sliceOf(text_ptr, text_len) orelse return .invalid_argument;
    return switch (handle.inner) {
        inline else => |*e| if (e.addLeadingComment(path, text)) .ok else |err| editStatus(err),
    };
}

/// Set the same-line trailing comment on the value at `path` (replace existing
/// or append). `text` must be single-line (else `invalid_argument`).
pub export fn fig_editor_set_trailing_comment(
    ed: ?*FigEditor,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
) FigStatus {
    const handle = editorFrom(ed) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const text = sliceOf(text_ptr, text_len) orelse return .invalid_argument;
    return switch (handle.inner) {
        inline else => |*e| if (e.setTrailingComment(path, text)) .ok else |err| editStatus(err),
    };
}

/// Remove the own-line comment block immediately above the node at `path` (no-op
/// when there is none).
pub export fn fig_editor_delete_leading_comments(
    ed: ?*FigEditor,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
) FigStatus {
    const handle = editorFrom(ed) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    return switch (handle.inner) {
        inline else => |*e| if (e.deleteLeadingComments(path)) .ok else |err| editStatus(err),
    };
}

/// Remove the same-line trailing comment on the value at `path` (no-op when
/// there is none).
pub export fn fig_editor_delete_trailing_comment(
    ed: ?*FigEditor,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
) FigStatus {
    const handle = editorFrom(ed) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    return switch (handle.inner) {
        inline else => |*e| if (e.deleteTrailingComment(path)) .ok else |err| editStatus(err),
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
// EMBED (COMBINED EDITOR)
// ====================
//
// A located embed (markdown frontmatter, JSON frontmatter, endmatter) opened as
// an editor: holds an owned copy of the host file plus an editor over the
// embed's *content* in that embed's inner format (YAML or JSON, fixed by the
// archetype). Edits delegate to the editor; `fig_embed_render` re-splices the
// edited content between the (untouched) fences + surrounding host text.
// This generalizes the former YAML-frontmatter-only combined editor.

pub const FigEmbed = opaque {};

const EmbedHandle = struct {
    allocator: std.mem.Allocator,
    host: []u8,
    content: Span,
    editor: EditorUnion,
    rendered: std.ArrayList(u8) = .empty,

    fn deinit(self: *EmbedHandle) void {
        switch (self.editor) {
            inline else => |*e| e.deinit(),
        }
        self.rendered.deinit(self.allocator);
        self.allocator.free(self.host);
    }
};

fn embedFrom(em: ?*FigEmbed) ?*EmbedHandle {
    const p = em orelse return null;
    return @ptrCast(@alignCast(p));
}

/// The inner editor language an embed archetype carries (`---` ⇒ YAML, `;;;` ⇒
/// JSON), mirroring `Embed`'s archetype table.
fn embedInner(t: Embed.Type) enum { yaml, json } {
    return switch (t) {
        .FrontmatterYaml, .EndmatterYaml => .yaml,
        .FrontmatterJson => .json,
    };
}

pub export fn fig_embed_open(
    input_ptr: ?[*]const u8,
    input_len: usize,
    embed_type: c_int,
    out_embed: ?*?*FigEmbed,
) FigStatus {
    const out = out_embed orelse return .invalid_argument;
    out.* = null;
    const input = sliceOf(input_ptr, input_len) orelse return .invalid_argument;
    const t = embedTypeOf(embed_type) orelse return .invalid_argument;
    // A YAML-inner embed needs the YAML editor; reject it when YAML is gated out.
    if (comptime !build_options.lang_yaml) {
        if (embedInner(t) == .yaml) return .unsupported_format;
    }

    const region = Embed.locateRegion(input, t) catch |err| return switch (err) {
        error.NotFound => .not_found,
        else => .parse_error,
    };

    const allocator = activeAllocator();
    const host = allocator.dupe(u8, input) catch return .out_of_memory;
    const handle = allocator.create(EmbedHandle) catch {
        allocator.free(host);
        return .out_of_memory;
    };
    handle.* = .{
        .allocator = allocator,
        .host = host,
        .content = region.content,
        .editor = switch (embedInner(t)) {
            .yaml => if (comptime build_options.lang_yaml) .{ .yaml = .{ .allocator = allocator } } else unreachable,
            .json => .{ .json = .{ .allocator = allocator } },
        },
    };
    const content = host[region.content.start..region.content.end];
    switch (handle.editor) {
        inline else => |*e| e.init(content) catch |err| {
            e.deinit();
            allocator.free(host);
            allocator.destroy(handle);
            return editStatus(err);
        },
    }

    out.* = @ptrCast(handle);
    return .ok;
}

pub export fn fig_embed_destroy(em: ?*FigEmbed) void {
    const handle = embedFrom(em) orelse return;
    const allocator = handle.allocator;
    handle.deinit();
    allocator.destroy(handle);
}

pub export fn fig_embed_replace_val(
    em: ?*FigEmbed,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    repl_ptr: ?[*]const u8,
    repl_len: usize,
) FigStatus {
    const handle = embedFrom(em) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const repl = sliceOf(repl_ptr, repl_len) orelse return .invalid_argument;
    return switch (handle.editor) {
        inline else => |*e| if (e.replaceValAtPath(path, repl)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_embed_replace_key(
    em: ?*FigEmbed,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    repl_ptr: ?[*]const u8,
    repl_len: usize,
) FigStatus {
    const handle = embedFrom(em) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const repl = sliceOf(repl_ptr, repl_len) orelse return .invalid_argument;
    return switch (handle.editor) {
        inline else => |*e| if (e.replaceKeyAtPath(path, repl)) .ok else |err| editStatus(err),
    };
}

// ── Comment editing (embed mirror of fig_editor_*) ──────────────────────────

pub export fn fig_embed_add_leading_comment(
    em: ?*FigEmbed,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
) FigStatus {
    const handle = embedFrom(em) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const text = sliceOf(text_ptr, text_len) orelse return .invalid_argument;
    return switch (handle.editor) {
        inline else => |*e| if (e.addLeadingComment(path, text)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_embed_set_trailing_comment(
    em: ?*FigEmbed,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
) FigStatus {
    const handle = embedFrom(em) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const text = sliceOf(text_ptr, text_len) orelse return .invalid_argument;
    return switch (handle.editor) {
        inline else => |*e| if (e.setTrailingComment(path, text)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_embed_delete_leading_comments(
    em: ?*FigEmbed,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
) FigStatus {
    const handle = embedFrom(em) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    return switch (handle.editor) {
        inline else => |*e| if (e.deleteLeadingComments(path)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_embed_delete_trailing_comment(
    em: ?*FigEmbed,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
) FigStatus {
    const handle = embedFrom(em) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    return switch (handle.editor) {
        inline else => |*e| if (e.deleteTrailingComment(path)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_embed_insert_key(
    em: ?*FigEmbed,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    key_ptr: ?[*]const u8,
    key_len: usize,
    val_ptr: ?[*]const u8,
    val_len: usize,
) FigStatus {
    const handle = embedFrom(em) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const key = sliceOf(key_ptr, key_len) orelse return .invalid_argument;
    const val = sliceOf(val_ptr, val_len) orelse return .invalid_argument;
    return switch (handle.editor) {
        inline else => |*e| if (e.insertKey(path, key, val)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_embed_delete_key(
    em: ?*FigEmbed,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
) FigStatus {
    const handle = embedFrom(em) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    return switch (handle.editor) {
        inline else => |*e| if (e.deleteKey(path)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_embed_append_seq(
    em: ?*FigEmbed,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    val_ptr: ?[*]const u8,
    val_len: usize,
) FigStatus {
    const handle = embedFrom(em) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const val = sliceOf(val_ptr, val_len) orelse return .invalid_argument;
    return switch (handle.editor) {
        inline else => |*e| if (e.appendToSeq(path, val)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_embed_prepend_seq(
    em: ?*FigEmbed,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    val_ptr: ?[*]const u8,
    val_len: usize,
) FigStatus {
    const handle = embedFrom(em) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const val = sliceOf(val_ptr, val_len) orelse return .invalid_argument;
    return switch (handle.editor) {
        inline else => |*e| if (e.prependToSeq(path, val)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_embed_remove_seq_item(
    em: ?*FigEmbed,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    index: usize,
) FigStatus {
    const handle = embedFrom(em) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    return switch (handle.editor) {
        inline else => |*e| if (e.removeSeqItem(path, index)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_embed_move_key(
    em: ?*FigEmbed,
    src_ptr: ?[*]const FigPathSegment,
    src_len: usize,
    dest_ptr: ?[*]const FigPathSegment,
    dest_len: usize,
) FigStatus {
    const handle = embedFrom(em) orelse return .invalid_argument;
    var src_buf: [max_path_len]AST.PathSegment = undefined;
    var dest_buf: [max_path_len]AST.PathSegment = undefined;
    const src = decodePath(src_ptr, src_len, &src_buf) orelse return .invalid_argument;
    const dest = decodePath(dest_ptr, dest_len, &dest_buf) orelse return .invalid_argument;
    return switch (handle.editor) {
        inline else => |*e| if (e.moveKey(src, dest)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_embed_reorder_keys(
    em: ?*FigEmbed,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    keys_ptr: ?[*]const FigStr,
    keys_len: usize,
) FigStatus {
    const handle = embedFrom(em) orelse return .invalid_argument;
    var path_buf: [max_path_len]AST.PathSegment = undefined;
    var keys_buf: [max_keys_len][]const u8 = undefined;
    const path = decodePath(path_ptr, path_len, &path_buf) orelse return .invalid_argument;
    const keys = decodeKeys(keys_ptr, keys_len, &keys_buf) orelse return .invalid_argument;
    return switch (handle.editor) {
        inline else => |*e| if (e.reorderKeys(path, keys)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_embed_move_item(
    em: ?*FigEmbed,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    from: usize,
    to: usize,
) FigStatus {
    const handle = embedFrom(em) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    return switch (handle.editor) {
        inline else => |*e| if (e.moveItem(path, from, to)) .ok else |err| editStatus(err),
    };
}

pub export fn fig_embed_reorder_items(
    em: ?*FigEmbed,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    indices_ptr: ?[*]const usize,
    indices_len: usize,
) FigStatus {
    const handle = embedFrom(em) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    const indices = decodeIndices(indices_ptr, indices_len) orelse return .invalid_argument;
    return switch (handle.editor) {
        inline else => |*e| if (e.reorderItems(path, indices)) .ok else |err| editStatus(err),
    };
}

/// Render the full host file with the edited embed spliced back between the
/// original fences. Borrowed bytes, valid until the next call or destroy.
pub export fn fig_embed_render(
    em: ?*FigEmbed,
    out_ptr: ?*[*c]const u8,
    out_len: ?*usize,
) FigStatus {
    const p = out_ptr orelse return .invalid_argument;
    const l = out_len orelse return .invalid_argument;
    const handle = embedFrom(em) orelse return .invalid_argument;

    const src = switch (handle.editor) {
        inline else => |*e| e.source.items,
    };
    handle.rendered.clearRetainingCapacity();
    const host = handle.host;
    handle.rendered.appendSlice(handle.allocator, host[0..handle.content.start]) catch return .out_of_memory;
    handle.rendered.appendSlice(handle.allocator, src) catch return .out_of_memory;
    handle.rendered.appendSlice(handle.allocator, host[handle.content.end..]) catch return .out_of_memory;

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
    number_special = 6,
};

const ValueHandle = struct {
    allocator: std.mem.Allocator,
    builder: AST.Builder,
    /// Reused across `fig_value_serialize` calls; holds the bytes the most recent
    /// call returned (cleared and refilled each time).
    rendered: std.Io.Writer.Allocating,
    /// Backs the warnings the most recent `fig_value_diagnose` produced; reset
    /// (not freed) each call. Mirrors `DocumentHandle.diag_arena`.
    diag_arena: std.heap.ArenaAllocator,
    /// The warning set the most recent `fig_value_diagnose` computed (stored in
    /// `diag_arena`); `fig_value_warning` indexes into it. Mirrors
    /// `DocumentHandle.diag_warnings`.
    diag_warnings: []const Diagnostics.Warning = &.{},
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
        @intFromEnum(FigExtKind.number_special) => .number_special,
        else => null,
    };
}

/// Map a C `format` to the writable-format set, or null if it cannot be written
/// in THIS build. Gated formats compiled out return null here — the single policy
/// point that keeps `fig_*_serialize`, `fig_*_diagnose`, and
/// `fig_format_capabilities` in agreement (all yield `unsupported_format` for a
/// compiled-out format, rather than serialize rejecting it at print time while
/// diagnose silently accepts it). The `FormatDisabled` arms in the printers
/// remain as defense-in-depth for any path that bypasses this map.
fn serializeFormatOf(format: c_int) ?AST.SerializeFormat {
    return switch (format) {
        @intFromEnum(FigFormat.json) => .json,
        // JSONC writes plain-JSON syntax plus `//`/`/* */` comments.
        @intFromEnum(FigFormat.jsonc) => .jsonc,
        @intFromEnum(FigFormat.json5) => .json5,
        @intFromEnum(FigFormat.yaml) => if (comptime build_options.lang_yaml) .yaml else null,
        @intFromEnum(FigFormat.toml) => if (comptime build_options.lang_toml) .toml else null,
        @intFromEnum(FigFormat.zon) => if (comptime build_options.lang_zon) .zon else null,
        else => null,
    };
}

/// Translate the canonical serialize error set onto `FigStatus`. Exhaustive over
/// `AST.SerializeError`: a representability failure (alias/null/non-string key in
/// a format that cannot hold it) maps to `unsupported_format`; the writer's only
/// other failure is allocation, surfaced as `WriteFailed`.
fn serializeStatus(err: AST.SerializeError) FigStatus {
    return switch (err) {
        error.UnresolvedAlias, error.NullUnsupported, error.NonStringKey, error.FormatDisabled, error.NestingTooDeep => .unsupported_format,
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
        .diag_arena = std.heap.ArenaAllocator.init(allocator),
    };
    out.* = @ptrCast(handle);
    return .ok;
}

pub export fn fig_value_destroy(value: ?*FigValue) void {
    const handle = valueFrom(value) orelse return;
    const allocator = handle.allocator;
    handle.builder.deinit();
    handle.rendered.deinit();
    handle.diag_arena.deinit();
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

/// Controls output style for `fig_value_serialize_opts`. A NULL pointer selects
/// the defaults below (the same output as `fig_value_serialize`). `pretty` is
/// honored by JSON and ZON; `indent` by JSON only. YAML and TOML render with
/// their own fixed layout.
pub const FigSerializeOptions = extern struct {
    /// The caller-reported size of this struct (set to `sizeof`). Acts as a
    /// version tag: fields may be appended in later releases, and a given field
    /// is read only when `size` covers it (see `serializeOptionsOf`), so a
    /// struct laid out by an older caller stays valid with new fields defaulted.
    size: u32 = @sizeOf(FigSerializeOptions),
    /// Nonzero (default): multi-line, indented output. Zero: compact single-line.
    pretty: u8 = 1,
    /// Spaces per indent level when `pretty` is nonzero (JSON only). 0 is treated
    /// as the default (2).
    indent: u8 = 2,
    /// Nonzero: drop comments carried on the value instead of emitting them.
    /// Zero (default): preserve them where the target format allows. Appended
    /// after `indent`, so older callers (whose `size` predates this field) keep
    /// the preserve-comments default.
    strip_comments: u8 = 0,
    /// `fig_document_serialize` only. Nonzero: preserve values the target format
    /// cannot represent natively (a null in TOML, a TOML datetime in JSON, …)
    /// through a `$fig` envelope, and decode any such envelope found in the
    /// source. Zero (default): lossy — an unrepresentable value yields
    /// `unsupported_format`. Ignored by `fig_value_serialize_opts` (the value
    /// builder has no source envelopes to decode). Appended after
    /// `strip_comments`, so older callers keep the lossy default.
    lossless: u8 = 0,
};

/// Whether a caller-reported options `size` fully covers `field`. Fields beyond
/// `size` are absent in the caller's (possibly older) layout and must not be
/// read; they take their defaults instead.
fn optionCovers(size: u32, comptime field: []const u8) bool {
    const end = @offsetOf(FigSerializeOptions, field) + @sizeOf(@FieldType(FigSerializeOptions, field));
    return size >= end;
}

/// Translate the C options struct (NULL ⇒ defaults) into the core options.
/// Each field is honored only when the caller's `size` includes it, so the
/// struct can gain fields without breaking callers compiled against an older
/// layout (and a zeroed/under-sized `size` reads as all-defaults, not garbage).
fn serializeOptionsOf(options: ?*const FigSerializeOptions) AST.SerializeOptions {
    const o = options orelse return .{};
    var out: AST.SerializeOptions = .{};
    if (optionCovers(o.size, "pretty")) out.pretty = o.pretty != 0;
    if (optionCovers(o.size, "indent")) out.indent = if (o.indent == 0) 2 else o.indent;
    if (optionCovers(o.size, "strip_comments")) out.strip_comments = o.strip_comments != 0;
    return out;
}

/// Whether the caller asked for lossless conversion (`fig_document_serialize`).
/// NULL options, or a `size` that predates the `lossless` field, read as lossy —
/// the same forward-compat rule the other option fields follow.
fn losslessRequested(options: ?*const FigSerializeOptions) bool {
    const o = options orelse return false;
    return optionCovers(o.size, "lossless") and o.lossless != 0;
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
    return fig_value_serialize_opts(value, root, format, null, out_ptr, out_len);
}

/// As `fig_value_serialize`, but `options` (NULL ⇒ defaults) controls output
/// style such as compact vs. pretty-printed JSON.
pub export fn fig_value_serialize_opts(
    value: ?*FigValue,
    root: FigNodeId,
    format: c_int,
    options: ?*const FigSerializeOptions,
    out_ptr: ?*[*c]const u8,
    out_len: ?*usize,
) FigStatus {
    const p = out_ptr orelse return .invalid_argument;
    const l = out_len orelse return .invalid_argument;
    const handle = valueFrom(value) orelse return .invalid_argument;
    const fmt = serializeFormatOf(format) orelse return .unsupported_format;
    if (root >= handle.builder.nodes.items.len) return .invalid_argument;

    handle.rendered.clearRetainingCapacity();
    const ast = handle.builder.view(root) catch return .out_of_memory; // borrows the builder; never deinit'd
    ast.serializeWith(&handle.rendered.writer, fmt, serializeOptionsOf(options)) catch |err| return serializeStatus(err);

    const bytes = handle.rendered.written();
    p.* = bytes.ptr;
    l.* = bytes.len;
    return .ok;
}

// ==================
// DOCUMENT SERIALIZE (CONVERT)
// ==================
//
// Render a parsed `FigDocument` to any writable format — the cross-format
// conversion primitive. Unlike `fig_value_serialize` (which prints a value the
// caller built), this runs the same pipeline the CLI's `get` does over a source
// document: when leaving YAML it collapses the reference layer (aliases → copies,
// merges → flattened, tags applied/dropped) so a non-YAML printer never meets one,
// and — when `options->lossless` is set — round-trips values the target cannot
// hold natively through a `$fig` envelope. Comments carried on the source survive
// where the target allows, which the parse→rebuild→`fig_value_serialize` detour
// cannot do.

/// Translate a materialization failure onto `FigStatus`. Allocation failure is
/// `out_of_memory`; every other case is an un-collapsible reference layer
/// (undefined/cyclic alias, unknown/mismatched tag) that the target cannot
/// represent — mirroring the `UnresolvedAlias → unsupported_format` convention in
/// `serializeStatus`.
fn convertStatus(err: anyerror) FigStatus {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        else => .unsupported_format,
    };
}

/// Render the whole parsed document in `format`. `options` (NULL ⇒ defaults)
/// controls output style and, via `lossless`, whether unrepresentable values are
/// preserved through a `$fig` envelope (default: lossy, so such a value yields
/// `unsupported_format`). Output bytes are borrowed from the document handle and
/// valid until the next `fig_document_serialize` on it or `fig_document_destroy`.
pub export fn fig_document_serialize(
    doc: ?*FigDocument,
    format: c_int,
    options: ?*const FigSerializeOptions,
    out_ptr: ?*[*c]const u8,
    out_len: ?*usize,
) FigStatus {
    const p = out_ptr orelse return .invalid_argument;
    const l = out_len orelse return .invalid_argument;
    const public_doc = doc orelse return .invalid_argument;
    const handle: *DocumentHandle = @ptrCast(@alignCast(public_doc));
    const fmt = serializeFormatOf(format) orelse return .unsupported_format;
    const opts = serializeOptionsOf(options);

    // Intermediate ASTs (materialized / lossless-decoded / -encoded) live in this
    // arena. Their string slices borrow from the source AST, which outlives the
    // call; the rendered bytes are copied into `handle.rendered` before the arena
    // is freed, so nothing dangles.
    var arena_state = std.heap.ArenaAllocator.init(handle.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ast = prepareDocumentAst(handle, fmt, options, arena) catch |err| return convertStatus(err);

    handle.rendered.clearRetainingCapacity();
    ast.serializeWith(&handle.rendered.writer, fmt, opts) catch |err| return serializeStatus(err);
    const bytes = handle.rendered.written();
    p.* = bytes.ptr;
    l.* = bytes.len;
    return .ok;
}

/// Run the same source→target AST pipeline `fig_document_serialize` prints from:
/// collapse YAML's reference layer when leaving YAML (strict tags), then — under
/// `lossless` — decode any `$fig` envelopes and re-encode for the target. All
/// intermediate ASTs live in `arena` (their strings borrow the source AST, which
/// outlives the call). Returns the source AST unchanged when no transform applies.
/// Errors: `OutOfMemory`, or an un-collapsible YAML reference layer from
/// `materialize` — both mapped via `convertStatus` at the call site.
fn prepareDocumentAst(handle: *DocumentHandle, fmt: AST.SerializeFormat, options: ?*const FigSerializeOptions, arena: std.mem.Allocator) !*const AST {
    const src_is_yaml = handle.format == .yaml;
    const dst_is_yaml = fmt == .yaml;

    // Leaving YAML: collapse the reference layer first (strict tag mode, matching
    // the CLI default — unknown/custom tags become `unsupported_format`).
    const base_ast: *const AST = if (src_is_yaml and !dst_is_yaml) blk: {
        if (comptime build_options.lang_yaml) {
            const mat = try arena.create(AST);
            mat.* = try YamlMaterialize.materialize(arena, &handle.document.ast, .strict);
            break :blk mat;
        } else unreachable; // src_is_yaml ⇒ YAML was compiled in
    } else &handle.document.ast;

    // Lossless: decode any `$fig` envelopes in the source back to real kinds, then
    // re-encode for the target. Skipped for YAML→YAML (its reference layer already
    // round-trips, and the core-AST passes would strip it).
    if (losslessRequested(options) and !(src_is_yaml and dst_is_yaml)) {
        const target: ?Lossless.Target = switch (fmt) {
            .json, .jsonc, .json5 => .json,
            .yaml => .yaml,
            .toml => .toml,
            .zon => .zon,
            // `serializeFormatOf` never yields `.native`; the arm keeps the switch
            // total. null would mean decode-only (no envelope on output).
            .native => null,
        };
        const decoded = try arena.create(AST);
        decoded.* = try Lossless.decode(arena, base_ast);
        const t = target orelse return decoded;
        const encoded = try arena.create(AST);
        encoded.* = try Lossless.encode(arena, decoded, t);
        return encoded;
    }
    return base_ast;
}

// ==================
// DIAGNOSTICS
// ==================
//
// Report what a conversion would silently lose (comments dropped/degraded,
// values dropped/degraded). It runs the SAME pipeline `*_serialize` prints from,
// so the warnings reflect the actual output. Read-only on the document/value
// *content*, but NOT a const operation: it resets and fills the handle's
// `diag_arena` scratch, so for the threading rules it counts as a mutating call
// on the handle (hence the non-const handle pointer) — do not run it concurrently
// with any other call on the same handle, including the genuinely-const reads.
// The returned array — and its `path` strings — are borrowed from the handle and
// valid only until the next diagnose on it or its destroy.

/// Mirrors `Diagnostics.Warning.Code`.
pub const FigWarningCode = enum(c_int) {
    /// A carried comment is not emitted at all.
    comment_dropped = 0,
    /// A block comment is rendered as a run of line comments.
    comment_style_degraded = 1,
    /// A node is removed entirely (the target cannot represent it even degraded).
    value_dropped = 2,
    /// An extended/non-finite value is rendered as a poorer type.
    type_degraded = 3,
};

/// Mirrors `Diagnostics.Warning.Cause`.
pub const FigWarningCause = enum(c_int) {
    /// The target format inherently cannot represent it.
    format_limitation = 0,
    /// A caller option forced it (e.g. `strip_comments`).
    explicit_option = 1,
};

/// One lossy event, retrieved by index via `fig_*_warning`. Caller-allocated and
/// size-versioned (mirrors `FigError`/`FigSerializeOptions`): the library writes
/// only the fields `out.size` covers, so the struct can gain fields without
/// breaking an older caller's layout. `path`/`note` are NOT null-terminated — use
/// the paired `*_len`. `path` is the dotted/`[i]` location ("" / len 0 = document
/// root); `note` is the degraded-to type for `type_degraded`, else empty. Both
/// borrow the producing handle's diagnostics arena.
pub const FigWarning = extern struct {
    size: u32,
    code: c_int,
    cause: c_int,
    path: [*c]const u8,
    path_len: usize,
    note: [*c]const u8,
    note_len: usize,
};

/// Whether the caller-reported `FigWarning.size` covers `field` (same rule as
/// `optionCovers`/`errCovers`).
fn warnCovers(size: u32, comptime field: []const u8) bool {
    const end = @offsetOf(FigWarning, field) + @sizeOf(@FieldType(FigWarning, field));
    return size >= end;
}

/// Copy `w` into caller-allocated `out`, writing only the fields its `size`
/// covers (preserving `out.size`). The `path`/`note` pointers borrow the same
/// storage `w` does — the producing handle's `diag_arena`.
fn writeWarning(out: *FigWarning, w: Diagnostics.Warning) void {
    const size = out.size;
    if (warnCovers(size, "code")) out.code = warningCodeInt(w.code);
    if (warnCovers(size, "cause")) out.cause = warningCauseInt(w.cause);
    if (warnCovers(size, "path")) out.path = w.path.ptr;
    if (warnCovers(size, "path_len")) out.path_len = w.path.len;
    if (warnCovers(size, "note")) out.note = w.note.ptr;
    if (warnCovers(size, "note_len")) out.note_len = w.note.len;
}

fn warningCodeInt(code: Diagnostics.Warning.Code) c_int {
    return @intFromEnum(@as(FigWarningCode, switch (code) {
        .comment_dropped => .comment_dropped,
        .comment_style_degraded => .comment_style_degraded,
        .value_dropped => .value_dropped,
        .type_degraded => .type_degraded,
    }));
}

fn warningCauseInt(cause: Diagnostics.Warning.Cause) c_int {
    return @intFromEnum(@as(FigWarningCause, switch (cause) {
        .format_limitation => .format_limitation,
        .explicit_option => .explicit_option,
    }));
}

/// Build `Diagnostics.Options` from the serialize options (NULL ⇒ defaults).
fn diagnoseOptionsOf(options: ?*const FigSerializeOptions) Diagnostics.Options {
    const so = serializeOptionsOf(options);
    return .{
        .pretty = so.pretty,
        .strip_comments = so.strip_comments,
        .lossless = losslessRequested(options),
    };
}

/// Report HOW MANY events serializing the parsed document to `format` would
/// produce, using the same pipeline (YAML collapse, lossless envelopes)
/// `fig_document_serialize` would. `options` (NULL ⇒ defaults) supplies
/// `pretty`/`strip_comments`/`lossless`, which change what is lost. On success
/// writes the count to `*out_count` (0 if nothing is lost) and retains the set on
/// the handle for `fig_document_warning` to index, valid until the next
/// `fig_document_diagnose` on `doc` or its destroy.
pub export fn fig_document_diagnose(
    doc: ?*FigDocument,
    format: c_int,
    options: ?*const FigSerializeOptions,
    out_count: ?*usize,
) FigStatus {
    const oc = out_count orelse return .invalid_argument;
    // Clear the out-param up front so an early error return (unsupported_format,
    // out_of_memory) never leaves a caller reading a stale count. Mirrors
    // `fig_parse` nulling its out-handle.
    oc.* = 0;
    const public_doc = doc orelse return .invalid_argument;
    const handle: *DocumentHandle = @ptrCast(@alignCast(public_doc));
    const fmt = serializeFormatOf(format) orelse return .unsupported_format;

    _ = handle.diag_arena.reset(.retain_capacity);
    handle.diag_warnings = &.{}; // a failed analyze must not leave a stale set indexable
    const arena = handle.diag_arena.allocator();
    const ast = prepareDocumentAst(handle, fmt, options, arena) catch |err| return convertStatus(err);
    const warnings = Diagnostics.analyze(arena, ast, ast.root, fmt, diagnoseOptionsOf(options)) catch return .out_of_memory;
    handle.diag_warnings = warnings;
    oc.* = warnings.len;
    return .ok;
}

/// Copy the warning at `index` from the most recent `fig_document_diagnose` on
/// `doc` into caller-allocated `*out` (set `out->size` first). An out-of-range
/// `index`, or a call with no prior diagnose, is `invalid_argument`. The
/// `path`/`note` pointers written borrow `doc` (see `fig_document_diagnose`).
pub export fn fig_document_warning(doc: ?*FigDocument, index: usize, out: ?*FigWarning) FigStatus {
    const o = out orelse return .invalid_argument;
    const public_doc = doc orelse return .invalid_argument;
    const handle: *DocumentHandle = @ptrCast(@alignCast(public_doc));
    if (index >= handle.diag_warnings.len) return .invalid_argument;
    writeWarning(o, handle.diag_warnings[index]);
    return .ok;
}

/// Report how many events serializing the built value subtree rooted at `root` to
/// `format` would produce. The value builder has no source envelopes, so
/// `lossless` in `options` is ignored here (it only affects
/// `fig_document_diagnose`). Retention rules match `fig_document_diagnose`.
pub export fn fig_value_diagnose(
    value: ?*FigValue,
    root: FigNodeId,
    format: c_int,
    options: ?*const FigSerializeOptions,
    out_count: ?*usize,
) FigStatus {
    const oc = out_count orelse return .invalid_argument;
    // Clear up front so an early error return never leaves a stale count exposed
    // (see `fig_document_diagnose`).
    oc.* = 0;
    const handle = valueFrom(value) orelse return .invalid_argument;
    const fmt = serializeFormatOf(format) orelse return .unsupported_format;
    if (root >= handle.builder.nodes.items.len) return .invalid_argument;

    _ = handle.diag_arena.reset(.retain_capacity);
    handle.diag_warnings = &.{};
    const arena = handle.diag_arena.allocator();
    const ast = handle.builder.view(root) catch return .out_of_memory; // borrows the builder; never deinit'd
    const warnings = Diagnostics.analyze(arena, &ast, root, fmt, diagnoseOptionsOf(options)) catch return .out_of_memory;
    handle.diag_warnings = warnings;
    oc.* = warnings.len;
    return .ok;
}

/// Copy the warning at `index` from the most recent `fig_value_diagnose` on
/// `value` into caller-allocated `*out` (set `out->size` first). Out-of-range
/// `index` or no prior diagnose is `invalid_argument`.
pub export fn fig_value_warning(value: ?*FigValue, index: usize, out: ?*FigWarning) FigStatus {
    const o = out orelse return .invalid_argument;
    const handle = valueFrom(value) orelse return .invalid_argument;
    if (index >= handle.diag_warnings.len) return .invalid_argument;
    writeWarning(o, handle.diag_warnings[index]);
    return .ok;
}

test "traversal over a parsed mapping" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
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

test "fig_document_diagnose reports a dropped null for TOML" {
    if (comptime !(build_options.lang_yaml and build_options.lang_toml)) return error.SkipZigTest;
    const src = "a: null\nb: 1\n";

    var out_doc: ?*FigDocument = null;
    try std.testing.expectEqual(FigStatus.ok, fig_parse(src.ptr, src.len, @intFromEnum(FigFormat.yaml), &out_doc));
    defer fig_document_destroy(out_doc);

    var count: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_document_diagnose(out_doc, @intFromEnum(FigFormat.toml), null, &count));
    try std.testing.expectEqual(@as(usize, 1), count);
    var w: FigWarning = undefined;
    w.size = @sizeOf(FigWarning);
    try std.testing.expectEqual(FigStatus.ok, fig_document_warning(out_doc, 0, &w));
    try std.testing.expectEqual(@intFromEnum(FigWarningCode.value_dropped), w.code);
    try std.testing.expectEqual(@intFromEnum(FigWarningCause.format_limitation), w.cause);
    try std.testing.expectEqualStrings("a", w.path[0..w.path_len]);
    // An out-of-range index is rejected.
    try std.testing.expectEqual(FigStatus.invalid_argument, fig_document_warning(out_doc, 1, &w));

    // Lossless preserves the null → no warnings.
    var opts: FigSerializeOptions = .{ .lossless = 1 };
    try std.testing.expectEqual(FigStatus.ok, fig_document_diagnose(out_doc, @intFromEnum(FigFormat.toml), &opts, &count));
    try std.testing.expectEqual(@as(usize, 0), count);
    // With nothing reported, even index 0 is out of range.
    try std.testing.expectEqual(FigStatus.invalid_argument, fig_document_warning(out_doc, 0, &w));

    // A representable target loses nothing.
    try std.testing.expectEqual(FigStatus.ok, fig_document_diagnose(out_doc, @intFromEnum(FigFormat.json), null, &count));
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "fig_value_diagnose reports a degraded datetime" {
    var v: ?*FigValue = null;
    try std.testing.expectEqual(FigStatus.ok, fig_value_create(&v));
    defer fig_value_destroy(v);

    const ts = "1979-05-27T07:32:00Z";
    var dt: FigNodeId = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_value_extended(v, @intFromEnum(FigExtKind.offset_datetime), ts.ptr, ts.len, &dt));

    var count: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_value_diagnose(v, dt, @intFromEnum(FigFormat.json), null, &count));
    try std.testing.expectEqual(@as(usize, 1), count);
    var w: FigWarning = undefined;
    w.size = @sizeOf(FigWarning);
    try std.testing.expectEqual(FigStatus.ok, fig_value_warning(v, 0, &w));
    try std.testing.expectEqual(@intFromEnum(FigWarningCode.type_degraded), w.code);
    try std.testing.expectEqualStrings("string", w.note[0..w.note_len]);

    // TOML holds datetimes natively → no warning.
    if (comptime build_options.lang_toml) {
        try std.testing.expectEqual(FigStatus.ok, fig_value_diagnose(v, dt, @intFromEnum(FigFormat.toml), null, &count));
        try std.testing.expectEqual(@as(usize, 0), count);
    }
}

test "fig_value_warning honors a truncated (size-gated) FigWarning" {
    var v: ?*FigValue = null;
    try std.testing.expectEqual(FigStatus.ok, fig_value_create(&v));
    defer fig_value_destroy(v);

    const ts = "1979-05-27T07:32:00Z";
    var dt: FigNodeId = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_value_extended(v, @intFromEnum(FigExtKind.offset_datetime), ts.ptr, ts.len, &dt));

    var count: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_value_diagnose(v, dt, @intFromEnum(FigFormat.json), null, &count));
    try std.testing.expectEqual(@as(usize, 1), count);

    // A caller whose layout stops after `cause` (an older/smaller struct) gets
    // code+cause but not the path/note fields, which keep their prior contents.
    var w: FigWarning = undefined;
    w.size = @offsetOf(FigWarning, "cause") + @sizeOf(c_int);
    w.path = null;
    w.path_len = 12345;
    try std.testing.expectEqual(FigStatus.ok, fig_value_warning(v, 0, &w));
    try std.testing.expectEqual(@intFromEnum(FigWarningCode.type_degraded), w.code);
    try std.testing.expectEqual(@as(usize, 12345), w.path_len); // beyond `size`: untouched
}

test "fig_parse_ex fills FigError on a parse failure" {
    const bad = "{ \"a\":"; // truncated JSON object

    // No out_err: behaves exactly like fig_parse.
    var out_doc: ?*FigDocument = null;
    try std.testing.expectEqual(
        FigStatus.parse_error,
        fig_parse_ex(bad.ptr, bad.len, @intFromEnum(FigFormat.json), &out_doc, null),
    );
    try std.testing.expectEqual(@as(?*FigDocument, null), out_doc);

    // With out_err: code mirrors the status, a non-empty NUL-terminated message
    // is written, and the (unimplemented) offset fields are 0.
    var err: FigError = undefined;
    err.size = @sizeOf(FigError);
    try std.testing.expectEqual(
        FigStatus.parse_error,
        fig_parse_ex(bad.ptr, bad.len, @intFromEnum(FigFormat.json), &out_doc, &err),
    );
    try std.testing.expectEqual(@intFromEnum(FigStatus.parse_error), err.code);
    try std.testing.expect(err.message_len > 0);
    try std.testing.expectEqual(@as(u8, 0), err.message[err.message_len]); // NUL-terminated
    try std.testing.expectEqual(@as(usize, 0), err.byte_offset);
    try std.testing.expectEqual(@as(u32, 0), err.line);

    // An unsupported format reports through the same struct.
    err.size = @sizeOf(FigError);
    try std.testing.expectEqual(
        FigStatus.unsupported_format,
        fig_parse_ex(bad.ptr, bad.len, 0xBEEF, &out_doc, &err),
    );
    try std.testing.expectEqual(@intFromEnum(FigStatus.unsupported_format), err.code);
}

test "fig_parse_ex honors a truncated (size-gated) FigError" {
    const bad = "[1,";

    // A caller whose layout stops before `message` gets `code` filled but the
    // message fields left as they were — no out-of-bounds write into a struct
    // that does not declare them.
    var err: FigError = undefined;
    err.size = @offsetOf(FigError, "byte_offset"); // covers size+code only
    err.message_len = 999;
    var out_doc: ?*FigDocument = null;
    try std.testing.expectEqual(
        FigStatus.parse_error,
        fig_parse_ex(bad.ptr, bad.len, @intFromEnum(FigFormat.json), &out_doc, &err),
    );
    try std.testing.expectEqual(@intFromEnum(FigStatus.parse_error), err.code);
    try std.testing.expectEqual(@as(usize, 999), err.message_len); // beyond `size`: untouched
}

test "fig_parse_ex leaves out_doc null and succeeds on a valid parse" {
    const src = "{\"a\":1}";
    var out_doc: ?*FigDocument = null;
    var err: FigError = undefined;
    err.size = @sizeOf(FigError);
    try std.testing.expectEqual(
        FigStatus.ok,
        fig_parse_ex(src.ptr, src.len, @intFromEnum(FigFormat.json), &out_doc, &err),
    );
    defer fig_document_destroy(out_doc);
    try std.testing.expect(out_doc != null);
}

test "a compiled-out format is unsupported in serialize and diagnose alike" {
    // Only meaningful when a writable format is gated out of this build; the
    // default all-on build has nothing to probe. TOML is the stand-in.
    if (comptime build_options.lang_toml) return error.SkipZigTest;

    const src = "{\"a\": 1}"; // JSON is always compiled in, so the parse succeeds.
    var out_doc: ?*FigDocument = null;
    try std.testing.expectEqual(FigStatus.ok, fig_parse(src.ptr, src.len, @intFromEnum(FigFormat.json), &out_doc));
    defer fig_document_destroy(out_doc);

    // Serialize rejects the gated-out target...
    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(
        FigStatus.unsupported_format,
        fig_document_serialize(out_doc, @intFromEnum(FigFormat.toml), null, &ptr, &len),
    );

    // ...and diagnose agrees, instead of silently accepting it. The count is
    // cleared on the error path (pre-initialized up front).
    var count: usize = 999;
    try std.testing.expectEqual(
        FigStatus.unsupported_format,
        fig_document_diagnose(out_doc, @intFromEnum(FigFormat.toml), null, &count),
    );
    try std.testing.expectEqual(@as(usize, 0), count);

    // Capabilities report the same verdict: nothing for a compiled-out format.
    try std.testing.expectEqual(@as(u32, 0), fig_format_capabilities(@intFromEnum(FigFormat.toml)));
}

test "parse c abi reads toml and zon" {
    if (comptime !(build_options.lang_toml and build_options.lang_zon)) return error.SkipZigTest;
    // TOML
    {
        var out_doc: ?*FigDocument = null;
        const src = "name = \"fig\"\ncount = 42\n";
        try std.testing.expectEqual(FigStatus.ok, fig_parse(src.ptr, src.len, @intFromEnum(FigFormat.toml), &out_doc));
        defer fig_document_destroy(out_doc);
        const root = fig_document_root(out_doc);
        try std.testing.expectEqual(FigNodeKind.mapping, fig_node_kind(out_doc, root));
        try std.testing.expectEqual(@as(usize, 2), fig_node_child_count(out_doc, root));
    }
    // ZON
    {
        var out_doc: ?*FigDocument = null;
        const src = ".{ .name = \"fig\", .count = 42 }";
        try std.testing.expectEqual(FigStatus.ok, fig_parse(src.ptr, src.len, @intFromEnum(FigFormat.zon), &out_doc));
        defer fig_document_destroy(out_doc);
        const root = fig_document_root(out_doc);
        try std.testing.expectEqual(FigNodeKind.mapping, fig_node_kind(out_doc, root));
    }
}

test "parse c abi reads json5 and rejects it under strict json" {
    // Regression: the `fig_parse` format switch once dropped `json5`, so the
    // `.json5` reader arm was dead and every JSON5 parse returned
    // `unsupported_format`. JSON5-only syntax (unquoted keys, trailing comma,
    // `//` comment) must parse under `.json5` and fail under strict `.json`.
    const src = "{\n  // c\n  host: 'localhost',\n  port: 8080,\n}\n";

    var out_doc: ?*FigDocument = null;
    try std.testing.expectEqual(FigStatus.ok, fig_parse(src.ptr, src.len, @intFromEnum(FigFormat.json5), &out_doc));
    defer fig_document_destroy(out_doc);
    const root = fig_document_root(out_doc);
    try std.testing.expectEqual(FigNodeKind.mapping, fig_node_kind(out_doc, root));
    try std.testing.expectEqual(@as(usize, 2), fig_node_child_count(out_doc, root));

    var strict_doc: ?*FigDocument = null;
    try std.testing.expectEqual(FigStatus.parse_error, fig_parse(src.ptr, src.len, @intFromEnum(FigFormat.json), &strict_doc));
}

test "fig_node_extended recovers datetime and char-literal scalars" {
    if (comptime !(build_options.lang_toml and build_options.lang_zon)) return error.SkipZigTest;

    var kind: c_int = undefined;
    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;

    // TOML local date: kind still reports STRING; fig_node_extended recovers it.
    {
        var out_doc: ?*FigDocument = null;
        const src = "d = 2026-06-18\n";
        try std.testing.expectEqual(FigStatus.ok, fig_parse(src.ptr, src.len, @intFromEnum(FigFormat.toml), &out_doc));
        defer fig_document_destroy(out_doc);
        const val = fig_keyvalue_value(out_doc, fig_node_first_child(out_doc, fig_document_root(out_doc)));
        try std.testing.expectEqual(FigNodeKind.string, fig_node_kind(out_doc, val));
        try std.testing.expect(fig_node_extended(out_doc, val, &kind, &ptr, &len));
        try std.testing.expectEqual(@intFromEnum(FigExtKind.local_date), kind);
        try std.testing.expectEqualStrings("2026-06-18", ptr[0..len]);
    }

    // ZON char literal: kind reports INT; fig_node_extended recovers the codepoint.
    {
        var out_doc: ?*FigDocument = null;
        const src = ".{ .c = 'a' }";
        try std.testing.expectEqual(FigStatus.ok, fig_parse(src.ptr, src.len, @intFromEnum(FigFormat.zon), &out_doc));
        defer fig_document_destroy(out_doc);
        const val = fig_keyvalue_value(out_doc, fig_node_first_child(out_doc, fig_document_root(out_doc)));
        try std.testing.expectEqual(FigNodeKind.int, fig_node_kind(out_doc, val));
        try std.testing.expect(fig_node_extended(out_doc, val, &kind, &ptr, &len));
        try std.testing.expectEqual(@intFromEnum(FigExtKind.char_literal), kind);
        try std.testing.expectEqualStrings("97", ptr[0..len]);
    }

    // A plain string is not extended.
    {
        var out_doc: ?*FigDocument = null;
        const src = "s = \"hi\"\n";
        try std.testing.expectEqual(FigStatus.ok, fig_parse(src.ptr, src.len, @intFromEnum(FigFormat.toml), &out_doc));
        defer fig_document_destroy(out_doc);
        const val = fig_keyvalue_value(out_doc, fig_node_first_child(out_doc, fig_document_root(out_doc)));
        try std.testing.expect(!fig_node_extended(out_doc, val, &kind, &ptr, &len));
    }
}

fn keySeg(s: []const u8) FigPathSegment {
    return .{ .kind = 0, .key_ptr = s.ptr, .key_len = s.len, .index = 0 };
}

test "editor c abi insert + source round-trip" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
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
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
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
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const md = "---\ntitle: Hi\n# keep\ntags:\n- x\n---\n# Body\ntext\n";
    var out_fm: ?*FigEmbed = null;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_open(md.ptr, md.len, @intFromEnum(FigEmbedType.frontmatter_yaml), &out_fm));
    defer fig_embed_destroy(out_fm);

    const author = "author";
    const me = "me";
    try std.testing.expectEqual(FigStatus.ok, fig_embed_insert_key(out_fm, null, 0, author.ptr, author.len, me.ptr, me.len));

    const tags = [_]FigPathSegment{keySeg("tags")};
    const y = "y";
    try std.testing.expectEqual(FigStatus.ok, fig_embed_append_seq(out_fm, &tags, 1, y.ptr, y.len));

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_render(out_fm, &ptr, &len));
    try std.testing.expectEqualStrings(
        "---\ntitle: Hi\n# keep\ntags:\n- x\n- y\nauthor: me\n---\n# Body\ntext\n",
        ptr[0..len],
    );
}

fn figStr(s: []const u8) FigStr {
    return .{ .ptr = s.ptr, .len = s.len };
}

test "frontmatter c abi reorder keys preserves comments, fences, body" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const md = "---\ntitle: Hi\n# keep\ntags:\n- x\nauthor: me\n---\n# Body\ntext\n";
    var out_fm: ?*FigEmbed = null;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_open(md.ptr, md.len, @intFromEnum(FigEmbedType.frontmatter_yaml), &out_fm));
    defer fig_embed_destroy(out_fm);

    const keys = [_]FigStr{ figStr("author"), figStr("title") };
    try std.testing.expectEqual(FigStatus.ok, fig_embed_reorder_keys(out_fm, null, 0, &keys, keys.len));

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_render(out_fm, &ptr, &len));
    try std.testing.expectEqualStrings(
        "---\nauthor: me\ntitle: Hi\n# keep\ntags:\n- x\n---\n# Body\ntext\n",
        ptr[0..len],
    );
}

test "frontmatter c abi move key preserves fences and body" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const md = "---\na: 1\nb: 2\nc: 3\n---\nbody\n";
    var out_fm: ?*FigEmbed = null;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_open(md.ptr, md.len, @intFromEnum(FigEmbedType.frontmatter_yaml), &out_fm));
    defer fig_embed_destroy(out_fm);

    const src = [_]FigPathSegment{keySeg("c")};
    const dest = [_]FigPathSegment{keySeg("a")};
    try std.testing.expectEqual(FigStatus.ok, fig_embed_move_key(out_fm, &src, 1, &dest, 1));

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_render(out_fm, &ptr, &len));
    try std.testing.expectEqualStrings("---\nc: 3\na: 1\nb: 2\n---\nbody\n", ptr[0..len]);
}

test "frontmatter c abi reorder items in a block sequence value" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const md = "---\ntags:\n- x\n- y\n- z\n---\nbody\n";
    var out_fm: ?*FigEmbed = null;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_open(md.ptr, md.len, @intFromEnum(FigEmbedType.frontmatter_yaml), &out_fm));
    defer fig_embed_destroy(out_fm);

    const path = [_]FigPathSegment{keySeg("tags")};
    const indices = [_]usize{ 2, 0 };
    try std.testing.expectEqual(FigStatus.ok, fig_embed_reorder_items(out_fm, &path, 1, &indices, indices.len));

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_render(out_fm, &ptr, &len));
    try std.testing.expectEqualStrings("---\ntags:\n- z\n- x\n- y\n---\nbody\n", ptr[0..len]);
}

test "frontmatter c abi move item in a flow sequence value" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const md = "---\ntags: [x, y, z]\n---\nbody\n";
    var out_fm: ?*FigEmbed = null;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_open(md.ptr, md.len, @intFromEnum(FigEmbedType.frontmatter_yaml), &out_fm));
    defer fig_embed_destroy(out_fm);

    const path = [_]FigPathSegment{keySeg("tags")};
    try std.testing.expectEqual(FigStatus.ok, fig_embed_move_item(out_fm, &path, 1, 2, 0));

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_render(out_fm, &ptr, &len));
    try std.testing.expectEqualStrings("---\ntags: [z, x, y]\n---\nbody\n", ptr[0..len]);
}

test "embed c abi locates region" {
    const md = "---\nk: v\n---\nbody\n";
    var region: FigRegion = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_extract(md.ptr, md.len, @intFromEnum(FigEmbedType.frontmatter_yaml), &region));
    try std.testing.expectEqualStrings("k: v\n", md[region.content.start..region.content.end]);
}

test "embed c abi edits json frontmatter (`;;;` fences, JSON inner editor)" {
    const md = ";;;\n{\"title\": \"Hi\", \"draft\": true}\n;;;\n# Body\n";
    var out_fm: ?*FigEmbed = null;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_open(md.ptr, md.len, @intFromEnum(FigEmbedType.frontmatter_json), &out_fm));
    defer fig_embed_destroy(out_fm);

    // The replacement crosses the ABI already serialized — JSON value text here.
    const title = [_]FigPathSegment{keySeg("title")};
    const hello = "\"Hello\"";
    try std.testing.expectEqual(FigStatus.ok, fig_embed_replace_val(out_fm, &title, 1, hello.ptr, hello.len));

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_render(out_fm, &ptr, &len));
    try std.testing.expectEqualStrings(";;;\n{\"title\": \"Hello\", \"draft\": true}\n;;;\n# Body\n", ptr[0..len]);
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
    if (comptime build_options.lang_yaml) {
        try std.testing.expectEqual(FigStatus.ok, fig_value_serialize(out_value, root, @intFromEnum(FigFormat.yaml), &ptr, &len));
        try std.testing.expectEqualStrings("name: fig\nnums:\n- 1\n- 2\n", ptr[0..len]);
    }
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

test "value c abi serialize options honor the size/version field" {
    var out_value: ?*FigValue = null;
    try std.testing.expectEqual(FigStatus.ok, fig_value_create(&out_value));
    defer fig_value_destroy(out_value);

    // [ 1, 2 ] — exercise pretty on/off via the options struct.
    var id: FigNodeId = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_value_int(out_value, 1, &id));
    const a = id;
    try std.testing.expectEqual(FigStatus.ok, fig_value_int(out_value, 2, &id));
    const b = id;
    const items = [_]FigNodeId{ a, b };
    try std.testing.expectEqual(FigStatus.ok, fig_value_seq(out_value, &items, items.len, &id));
    const root = id;

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;

    // A fully-populated options struct: compact output.
    var opts: FigSerializeOptions = .{ .pretty = 0 };
    try std.testing.expectEqual(FigStatus.ok, fig_value_serialize_opts(out_value, root, @intFromEnum(FigFormat.json), &opts, &ptr, &len));
    try std.testing.expectEqualStrings("[1,2]\n", ptr[0..len]);

    // A `size` that does not reach `pretty` must leave it (and `indent`) at the
    // default — i.e. behave as if those fields were absent, not read as garbage.
    // This is the forward-compat contract: an older/under-sized layout defaults.
    opts.size = @offsetOf(FigSerializeOptions, "pretty"); // covers only `size`
    try std.testing.expectEqual(FigStatus.ok, fig_value_serialize_opts(out_value, root, @intFromEnum(FigFormat.json), &opts, &ptr, &len));
    try std.testing.expectEqualStrings("[\n  1,\n  2\n]\n", ptr[0..len]);
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

test "fig_parse empty input is judged per format" {
    // (null ptr, len 0) reaches the parser — same as (ptr, len 0). YAML treats
    // an empty stream as a null document and TOML as an empty table (both ok);
    // JSON requires a value (parse_error). A null ptr with a nonzero len is a
    // malformed argument regardless of format.
    {
        var out_doc: ?*FigDocument = null;
        try std.testing.expectEqual(FigStatus.parse_error, fig_parse(null, 0, @intFromEnum(FigFormat.json), &out_doc));
        try std.testing.expect(out_doc == null);
    }
    {
        var out_doc: ?*FigDocument = null;
        try std.testing.expectEqual(FigStatus.invalid_argument, fig_parse(null, 5, @intFromEnum(FigFormat.json), &out_doc));
        try std.testing.expect(out_doc == null);
    }
    if (comptime build_options.lang_yaml) {
        var out_doc: ?*FigDocument = null;
        try std.testing.expectEqual(FigStatus.ok, fig_parse(null, 0, @intFromEnum(FigFormat.yaml), &out_doc));
        defer fig_document_destroy(out_doc);
        try std.testing.expectEqual(FigNodeKind.null_, fig_node_kind(out_doc, fig_document_root(out_doc)));
    }
    if (comptime build_options.lang_toml) {
        var out_doc: ?*FigDocument = null;
        try std.testing.expectEqual(FigStatus.ok, fig_parse(null, 0, @intFromEnum(FigFormat.toml), &out_doc));
        defer fig_document_destroy(out_doc);
        try std.testing.expectEqual(FigNodeKind.mapping, fig_node_kind(out_doc, fig_document_root(out_doc)));
        try std.testing.expectEqual(@as(usize, 0), fig_node_child_count(out_doc, fig_document_root(out_doc)));
    }
}

test "fig_document_serialize converts JSON to YAML" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const src = "{\"name\":\"fig\",\"nums\":[1,2]}";
    var out_doc: ?*FigDocument = null;
    try std.testing.expectEqual(FigStatus.ok, fig_parse(src.ptr, src.len, @intFromEnum(FigFormat.json), &out_doc));
    defer fig_document_destroy(out_doc);

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_document_serialize(out_doc, @intFromEnum(FigFormat.yaml), null, &ptr, &len));
    try std.testing.expectEqualStrings("name: fig\nnums:\n- 1\n- 2\n", ptr[0..len]);

    // Same handle, re-serialize to TOML — the borrowed bytes refresh in place.
    if (comptime build_options.lang_toml) {
        try std.testing.expectEqual(FigStatus.ok, fig_document_serialize(out_doc, @intFromEnum(FigFormat.toml), null, &ptr, &len));
        try std.testing.expectEqualStrings("name = \"fig\"\nnums = [1, 2]\n", ptr[0..len]);
    }
}

test "fig_document_serialize materializes the YAML reference layer when leaving YAML" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    // `b` aliases the anchor defined on `a`; converting to JSON must expand it to
    // a copied value, not leak `*x` or fail with unsupported_format.
    const src = "a: &x 1\nb: *x\n";
    var out_doc: ?*FigDocument = null;
    try std.testing.expectEqual(FigStatus.ok, fig_parse(src.ptr, src.len, @intFromEnum(FigFormat.yaml), &out_doc));
    defer fig_document_destroy(out_doc);

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_document_serialize(out_doc, @intFromEnum(FigFormat.json), null, &ptr, &len));
    try std.testing.expectEqualStrings("{\n  \"a\": 1,\n  \"b\": 1\n}\n", ptr[0..len]);

    // YAML→YAML keeps the reference layer intact (no materialize).
    try std.testing.expectEqual(FigStatus.ok, fig_document_serialize(out_doc, @intFromEnum(FigFormat.yaml), null, &ptr, &len));
    try std.testing.expect(std.mem.indexOf(u8, ptr[0..len], "*x") != null);
}

test "fig_document_serialize honors the lossless option for TOML null" {
    if (comptime !build_options.lang_toml) return error.SkipZigTest;
    // A JSON null has no TOML representation. Lossy (default) reports it; lossless
    // wraps it in a `$fig` envelope so the document still serializes.
    const src = "{\"k\":null}";
    var out_doc: ?*FigDocument = null;
    try std.testing.expectEqual(FigStatus.ok, fig_parse(src.ptr, src.len, @intFromEnum(FigFormat.json), &out_doc));
    defer fig_document_destroy(out_doc);

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.unsupported_format, fig_document_serialize(out_doc, @intFromEnum(FigFormat.toml), null, &ptr, &len));

    var opts: FigSerializeOptions = .{ .lossless = 1 };
    try std.testing.expectEqual(FigStatus.ok, fig_document_serialize(out_doc, @intFromEnum(FigFormat.toml), &opts, &ptr, &len));
    try std.testing.expect(std.mem.indexOf(u8, ptr[0..len], "$fig") != null);
}

test "fig_document_serialize preserves comments across formats" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    // The motivating case the parse→rebuild→fig_value_serialize detour could not
    // serve: a comment captured from JSON5 re-emitted into YAML.
    const src = "{\n  // hello\n  a: 1,\n}\n";
    var out_doc: ?*FigDocument = null;
    try std.testing.expectEqual(FigStatus.ok, fig_parse(src.ptr, src.len, @intFromEnum(FigFormat.json5), &out_doc));
    defer fig_document_destroy(out_doc);

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_document_serialize(out_doc, @intFromEnum(FigFormat.yaml), null, &ptr, &len));
    try std.testing.expect(std.mem.indexOf(u8, ptr[0..len], "# hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, ptr[0..len], "a: 1") != null);

    // strip_comments drops it.
    var opts: FigSerializeOptions = .{ .strip_comments = 1 };
    try std.testing.expectEqual(FigStatus.ok, fig_document_serialize(out_doc, @intFromEnum(FigFormat.yaml), &opts, &ptr, &len));
    try std.testing.expect(std.mem.indexOf(u8, ptr[0..len], "hello") == null);
}

test "fig_version matches build options and string form" {
    const v = fig_version();
    try std.testing.expectEqual(@as(u32, build_options.version_major), v >> 16);
    try std.testing.expectEqual(@as(u32, build_options.version_minor), (v >> 8) & 0xFF);
    try std.testing.expectEqual(@as(u32, build_options.version_patch), v & 0xFF);

    const s = fig_version_string();
    const expected = std.fmt.comptimePrint("{d}.{d}.{d}", .{
        build_options.version_major,
        build_options.version_minor,
        build_options.version_patch,
    });
    try std.testing.expectEqualStrings(expected, std.mem.span(s));
}

test "fig_format_capabilities reports the per-format matrix" {
    const read = @intFromEnum(FigCapability.read);
    const edit = @intFromEnum(FigCapability.edit);
    const serialize = @intFromEnum(FigCapability.serialize);

    // JSON family: always fully supported, regardless of build options.
    for ([_]FigFormat{ .json, .jsonc, .json5 }) |f| {
        try std.testing.expectEqual(read | edit | serialize, fig_format_capabilities(@intFromEnum(f)));
    }

    // Gated formats: capabilities track both inherent support and the build gate.
    try std.testing.expectEqual(
        if (build_options.lang_yaml) read | edit | serialize else 0,
        fig_format_capabilities(@intFromEnum(FigFormat.yaml)),
    );
    try std.testing.expectEqual(
        if (build_options.lang_toml) read | serialize else 0, // no edit
        fig_format_capabilities(@intFromEnum(FigFormat.toml)),
    );
    try std.testing.expectEqual(
        if (build_options.lang_zon) read | serialize else 0, // no edit
        fig_format_capabilities(@intFromEnum(FigFormat.zon)),
    );
    try std.testing.expectEqual(
        if (build_options.lang_xml) read else 0, // reader-only
        fig_format_capabilities(@intFromEnum(FigFormat.xml)),
    );

    // Unknown / out-of-range format values report no capabilities.
    try std.testing.expectEqual(@as(u32, 0), fig_format_capabilities(0));
    try std.testing.expectEqual(@as(u32, 0), fig_format_capabilities(9999));
    try std.testing.expectEqual(@as(u32, 0), fig_format_capabilities(-1));
}

test "fig_editor comment ops add, set, and delete through the C ABI" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const src = "a: 1\nb: 2\n";
    var ed: ?*FigEditor = null;
    try std.testing.expectEqual(FigStatus.ok, fig_editor_create(src.ptr, src.len, @intFromEnum(FigFormat.yaml), &ed));
    defer fig_editor_destroy(ed);

    // path = ["b"]
    var key = [_]u8{'b'};
    const path = [_]FigPathSegment{.{ .kind = 0, .key_ptr = &key, .key_len = 1, .index = 0 }};

    const leading = "why";
    try std.testing.expectEqual(FigStatus.ok, fig_editor_add_leading_comment(ed, &path, 1, leading.ptr, leading.len));
    const trailing = "two";
    try std.testing.expectEqual(FigStatus.ok, fig_editor_set_trailing_comment(ed, &path, 1, trailing.ptr, trailing.len));

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_editor_source(ed, &ptr, &len));
    try std.testing.expectEqualStrings("a: 1\n# why\nb: 2 # two\n", ptr[0..len]);

    // Delete both back out.
    try std.testing.expectEqual(FigStatus.ok, fig_editor_delete_trailing_comment(ed, &path, 1));
    try std.testing.expectEqual(FigStatus.ok, fig_editor_delete_leading_comments(ed, &path, 1));
    try std.testing.expectEqual(FigStatus.ok, fig_editor_source(ed, &ptr, &len));
    try std.testing.expectEqualStrings("a: 1\nb: 2\n", ptr[0..len]);
}

test "fig_editor comment ops reject strict JSON with unsupported_format" {
    const src = "{\"a\":1}";
    var ed: ?*FigEditor = null;
    try std.testing.expectEqual(FigStatus.ok, fig_editor_create(src.ptr, src.len, @intFromEnum(FigFormat.json), &ed));
    defer fig_editor_destroy(ed);
    var key = [_]u8{'a'};
    const path = [_]FigPathSegment{.{ .kind = 0, .key_ptr = &key, .key_len = 1, .index = 0 }};
    const text = "x";
    try std.testing.expectEqual(FigStatus.unsupported_format, fig_editor_add_leading_comment(ed, &path, 1, text.ptr, text.len));
    try std.testing.expectEqual(FigStatus.unsupported_format, fig_editor_delete_trailing_comment(ed, &path, 1));
}
