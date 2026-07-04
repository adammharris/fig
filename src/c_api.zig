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
// Gated formats collapse to `void`; every reference below is behind the matching
// `build_options.lang_*` comptime guard so the parser/printer never compiles in.
// JSON is gateable too — the editor union and the parse/capability switches all
// guard their JSON-family arms.
const JsonParser = if (build_options.lang_json) @import("languages/json/parser.zig") else void;
const JsonType = if (build_options.lang_json) @import("languages/json/json.zig").Type else void;
const JsonLang = if (build_options.lang_json) @import("languages/json/json.zig").Language else void;
const YamlParser = if (build_options.lang_yaml) @import("languages/yaml/parser.zig") else void;
const YamlType = if (build_options.lang_yaml) @import("languages/yaml/yaml.zig").Type else void;
const YamlLang = if (build_options.lang_yaml) @import("languages/yaml/yaml.zig").Language else void;
const TomlParser = if (build_options.lang_toml) @import("languages/toml/parser.zig") else void;
const TomlType = if (build_options.lang_toml) @import("languages/toml/toml.zig").Type else void;
const TomlLang = if (build_options.lang_toml) @import("languages/toml/toml.zig").Language else void;
const ZonParser = if (build_options.lang_zon) @import("languages/zon/parser.zig") else void;
const ZonType = if (build_options.lang_zon) @import("languages/zon/zon.zig").Type else void;
const XmlParser = if (build_options.lang_xml) @import("languages/xml/parser.zig") else void;
const XmlType = if (build_options.lang_xml) @import("languages/xml/xml.zig").Type else void;
const FigDialectParser = if (build_options.lang_fig) @import("languages/fig/parser.zig") else void;
const FigDialectType = if (build_options.lang_fig) @import("languages/fig/fig.zig").Type else void;
const FigDialectLang = if (build_options.lang_fig) @import("languages/fig/fig.zig").Language else void;
// Cross-format conversion helpers used by `fig_document_serialize`. `Lossless` is
// format-agnostic (always compiled in); `materialize` is YAML-only, so it follows
// the gated-import pattern above (collapses to `void` when YAML is off, and every
// reference to it sits behind the matching comptime guard).
const Lossless = @import("lossless.zig");
const Diagnostics = @import("diagnostics.zig");
const YamlMaterialize = if (build_options.lang_yaml) @import("languages/yaml/materialize.zig") else void;

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
/// `json`/`jsonc`/`json5`/`yaml`/`toml`/`fig` (others return `unsupported_format`);
/// the serializer (`fig_value_serialize`) accepts `json`/`jsonc`/`json5`/`yaml`/
/// `toml`/`zon`/`fig` (JSONC = plain-JSON syntax with comments).
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
    /// The native `fig` authoring dialect (see src/languages/fig/DESIGN.md).
    /// Read, written, and edited (via `fig_editor_*`). Appended, same as JSON5.
    fig = 8,
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

/// Binary C ABI contract version (see `FIG_ABI_VERSION` in fig.h) — a monotonic
/// counter that moves only on a breaking ABI change, distinct from the marketing
/// version. Sourced from `build.zig`; `zig build abi-check` asserts the fig.h
/// macro matches this, and `semver-check` requires it to increment on any
/// breaking ABI diff.
pub export fn fig_abi_version() u32 {
    return build_options.abi_version;
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
/// support (XML is reader-only; ZON parses and serializes but is not editable)
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
        => if (comptime build_options.lang_json) read | edit | serialize else 0,
        @intFromEnum(FigFormat.yaml) => if (comptime build_options.lang_yaml) read | edit | serialize else 0,
        @intFromEnum(FigFormat.toml) => if (comptime build_options.lang_toml) read | edit | serialize else 0,
        @intFromEnum(FigFormat.zon) => if (comptime build_options.lang_zon) read | serialize else 0,
        @intFromEnum(FigFormat.xml) => if (comptime build_options.lang_xml) read else 0,
        @intFromEnum(FigFormat.fig) => if (comptime build_options.lang_fig) read | edit | serialize else 0,
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
        @intFromEnum(FigFormat.fig) => .fig,
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
        .json => if (comptime build_options.lang_json)
            JsonParser.parse(allocator, source, JsonType.JSON) catch |err|
                return parseFailed(out_err, err, source, handle)
        else
            return formatDisabled(out_err, source, handle),
        .jsonc => if (comptime build_options.lang_json)
            JsonParser.parse(allocator, source, JsonType.JSONC) catch |err|
                return parseFailed(out_err, err, source, handle)
        else
            return formatDisabled(out_err, source, handle),
        .json5 => if (comptime build_options.lang_json)
            JsonParser.parse(allocator, source, JsonType.JSON5) catch |err|
                return parseFailed(out_err, err, source, handle)
        else
            return formatDisabled(out_err, source, handle),
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
        .fig => if (comptime build_options.lang_fig)
            FigDialectParser.parse(allocator, source, FigDialectType.Fig) catch |err|
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
        // `setSequence` declines a shape it can't safely diff (empty target,
        // empty/non-scalar list, a format whose scalars can't stand alone).
        error.UnsupportedShape => .invalid_argument,
        // TOML structural edits reject a request that doesn't match the document
        // shape (e.g. appending to a non-array-of-tables, deleting a table by the
        // scalar ops, inserting a key/table that already exists). These are caller
        // errors, not malformed-source reparse failures.
        error.NotATable, error.NotAnInlineArray, error.NotAnArrayOfTables, error.TableExists, error.DuplicateKey, error.CannotDeleteTable, error.MergeOnlyKey => .invalid_argument,
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

// The editor backends, shared by the document editor and the embed editor: a
// tagged union with one variant per editable language COMPILED INTO THIS BUILD
// (json/yaml/toml/fig; zon/xml are not editable). The type is assembled from
// only the enabled languages — rather than carrying `void` placeholder fields —
// so the `inline else` switches over `handle.inner` stay valid: every variant
// has a real `Editor` payload to act on. Building it from a list (instead of
// enumerating the 2^4 enable combinations by hand) is what keeps adding a gate
// cheap.
const editor_variants = blk: {
    const Variant = struct { name: [:0]const u8, Lang: type };
    var variants: []const Variant = &.{};
    if (build_options.lang_json) variants = variants ++ &[_]Variant{.{ .name = "json", .Lang = JsonLang }};
    if (build_options.lang_yaml) variants = variants ++ &[_]Variant{.{ .name = "yaml", .Lang = YamlLang }};
    if (build_options.lang_toml) variants = variants ++ &[_]Variant{.{ .name = "toml", .Lang = TomlLang }};
    if (build_options.lang_fig) variants = variants ++ &[_]Variant{.{ .name = "fig", .Lang = FigDialectLang }};
    break :blk variants;
};

const EditorUnion = blk: {
    if (editor_variants.len == 0)
        @compileError("fig C ABI: no editable language enabled; build with at least one of -Djson/-Dyaml/-Dtoml");
    const n = editor_variants.len;
    const IntTag = std.math.IntFittingRange(0, n - 1);
    var names: [n][:0]const u8 = undefined;
    var types: [n]type = undefined;
    var values: [n]IntTag = undefined;
    var attrs: [n]std.builtin.Type.UnionField.Attributes = undefined;
    for (editor_variants, 0..) |v, i| {
        names[i] = v.name;
        types[i] = Editor(v.Lang);
        values[i] = @intCast(i);
        attrs[i] = .{};
    }
    // This Zig spells type reification as granular builtins (`@Enum`/`@Union`)
    // rather than `@Type(.{...})`.
    const Tag = @Enum(IntTag, .exhaustive, &names, &values);
    break :blk @Union(.auto, Tag, &names, &types, &attrs);
};

const EditorHandle = struct {
    allocator: std.mem.Allocator,
    inner: EditorUnion,
    /// Reused buffer backing the borrowed bytes returned by the comment-read
    /// exports (`fig_editor_get_*_comment`). Refilled per call; valid until the
    /// next read call on this handle or `fig_editor_destroy`.
    scratch: std.ArrayList(u8) = .empty,

    fn deinit(self: *EditorHandle) void {
        switch (self.inner) {
            inline else => |*e| e.deinit(),
        }
        self.scratch.deinit(self.allocator);
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
        @intFromEnum(FigFormat.json) => if (comptime build_options.lang_json) .json else return .unsupported_format,
        @intFromEnum(FigFormat.jsonc) => if (comptime build_options.lang_json) .jsonc else return .unsupported_format,
        @intFromEnum(FigFormat.json5) => if (comptime build_options.lang_json) .json5 else return .unsupported_format,
        @intFromEnum(FigFormat.yaml) => if (comptime build_options.lang_yaml) .yaml else return .unsupported_format,
        @intFromEnum(FigFormat.toml) => if (comptime build_options.lang_toml) .toml else return .unsupported_format,
        @intFromEnum(FigFormat.fig) => if (comptime build_options.lang_fig) .fig else return .unsupported_format,
        else => return .unsupported_format,
    };

    const allocator = activeAllocator();
    const handle = allocator.create(EditorHandle) catch return .out_of_memory;
    handle.allocator = allocator;
    // Field-by-field init (not a struct literal), so set the read scratch buffer's
    // default explicitly — otherwise destroy frees uninitialized memory.
    handle.scratch = .empty;
    handle.inner = switch (fig_format) {
        .yaml => if (comptime build_options.lang_yaml) .{ .yaml = .{ .allocator = allocator } } else unreachable,
        .json => if (comptime build_options.lang_json) .{ .json = .{ .allocator = allocator } } else unreachable,
        .jsonc => if (comptime build_options.lang_json) .{ .json = .{ .allocator = allocator, .format = .JSONC } } else unreachable,
        // JSON5 edits route through the same generic JSON editor, just in the
        // JSON5 dialect (unquoted keys, trailing commas, `//` comments). The
        // editor splices source in place, so all of that survives untouched
        // outside the edited span.
        .json5 => if (comptime build_options.lang_json) .{ .json = .{ .allocator = allocator, .format = .JSON5 } } else unreachable,
        .toml => if (comptime build_options.lang_toml) .{ .toml = .{ .allocator = allocator } } else unreachable,
        .fig => if (comptime build_options.lang_fig) .{ .fig = .{ .allocator = allocator } } else unreachable,
        // Filtered out by the format switch above; editing these is not yet wired.
        .zon, .xml => unreachable,
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

/// Upsert: replace the value at `path`, or insert it when only the trailing key
/// is absent (the `path` must end in a key). Folds replace-or-insert into one
/// op; see `Editor.set`.
pub export fn fig_editor_set(
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
        inline else => |*e| if (e.set(path, val)) .ok else |err| editStatus(err),
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

// ── Comment reading ─────────────────────────────────────────────────────────
// Read back a comment without mutating the document. The returned bytes (marker
// stripped) are BORROWED from the editor handle's scratch buffer: valid until the
// next read call on this handle or `fig_editor_destroy`. The distinction between
// an ABSENT comment and a PRESENT-BUT-EMPTY one (a bare `#`/`//`) is carried by
// the status: `not_found` means absent; `ok` with `out_len == 0` means present and
// empty. Strict JSON (no comment syntax) returns `unsupported_format`.

fn editorGetComment(
    handle: *EditorHandle,
    path: []const AST.PathSegment,
    trailing: bool,
    out_ptr: ?*[*c]const u8,
    out_len: ?*usize,
) FigStatus {
    const p = out_ptr orelse return .invalid_argument;
    const l = out_len orelse return .invalid_argument;
    const maybe = (switch (handle.inner) {
        inline else => |*e| if (trailing) e.getTrailingComment(path) else e.getLeadingComment(path),
    }) catch |err| return editStatus(err);
    const bytes = maybe orelse return .not_found;
    defer handle.allocator.free(bytes);
    handle.scratch.clearRetainingCapacity();
    // Keep a valid (non-dangling) pointer even for a zero-length present comment.
    handle.scratch.ensureTotalCapacity(handle.allocator, bytes.len + 1) catch return .out_of_memory;
    handle.scratch.appendSliceAssumeCapacity(bytes);
    p.* = handle.scratch.items.ptr;
    l.* = handle.scratch.items.len;
    return .ok;
}

/// Read the own-line comment block immediately ABOVE the node at `path`, joined by
/// '\n' with markers and indentation stripped. `not_found` when there is no block.
pub export fn fig_editor_get_leading_comment(
    ed: ?*FigEditor,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    out_ptr: ?*[*c]const u8,
    out_len: ?*usize,
) FigStatus {
    const handle = editorFrom(ed) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    return editorGetComment(handle, path, false, out_ptr, out_len);
}

/// Read the same-line trailing comment on the value at `path`, marker stripped.
/// `not_found` when there is none.
pub export fn fig_editor_get_trailing_comment(
    ed: ?*FigEditor,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    out_ptr: ?*[*c]const u8,
    out_len: ?*usize,
) FigStatus {
    const handle = editorFrom(ed) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    return editorGetComment(handle, path, true, out_ptr, out_len);
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

pub export fn fig_editor_set_sequence(
    ed: ?*FigEditor,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    items_ptr: ?[*]const FigStr,
    items_len: usize,
) FigStatus {
    const handle = editorFrom(ed) orelse return .invalid_argument;
    var path_buf: [max_path_len]AST.PathSegment = undefined;
    var items_buf: [max_keys_len][]const u8 = undefined;
    const path = decodePath(path_ptr, path_len, &path_buf) orelse return .invalid_argument;
    const items = decodeKeys(items_ptr, items_len, &items_buf) orelse return .invalid_argument;
    return switch (handle.inner) {
        inline else => |*e| if (e.setSequence(path, items)) .ok else |err| editStatus(err),
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
/// Caller-allocated, size-versioned like `FigError`: the caller sets `size` to
/// `@sizeOf(FigRegion)` and the library writes only the fields it covers, so
/// trailing fields may be appended later without breaking an older layout.
pub const FigRegion = extern struct {
    size: u32,
    open_fence: FigSpan,
    content: FigSpan,
    close_fence: FigSpan,
    /// The host body outside the fences (suffix for frontmatter, prefix for
    /// endmatter) — the read-side twin of `content`.
    body: FigSpan,
};

/// Whether the caller-reported `FigRegion.size` covers `field` (same rule as
/// `errCovers`). A field past `size` is absent in the caller's layout and must
/// not be written.
fn regionCovers(size: u32, comptime field: []const u8) bool {
    const end = @offsetOf(FigRegion, field) + @sizeOf(@FieldType(FigRegion, field));
    return size >= end;
}

/// Mirrors `Embed.Type`.
pub const FigEmbedType = enum(c_int) {
    frontmatter_yaml = 0,
    frontmatter_json = 1,
    endmatter_yaml = 2,
    /// A ```fig fenced frontmatter block, in the native `fig` authoring dialect.
    frontmatter_fig = 3,
};

fn embedTypeOf(t: c_int) ?Embed.Type {
    return switch (t) {
        @intFromEnum(FigEmbedType.frontmatter_yaml) => .FrontmatterYaml,
        @intFromEnum(FigEmbedType.frontmatter_json) => .FrontmatterJson,
        @intFromEnum(FigEmbedType.endmatter_yaml) => .EndmatterYaml,
        @intFromEnum(FigEmbedType.frontmatter_fig) => .FrontmatterFig,
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
    // Gate every write on the caller's declared `size`, so a smaller (older)
    // FigRegion receives only the fields it has room for — see `regionCovers`.
    const size = out.size;
    if (regionCovers(size, "open_fence")) out.open_fence = toFigSpan(region.open_fence);
    if (regionCovers(size, "content")) out.content = toFigSpan(region.content);
    if (regionCovers(size, "close_fence")) out.close_fence = toFigSpan(region.close_fence);
    if (regionCovers(size, "body")) out.body = toFigSpan(region.body);
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
    /// The located region in host coordinates. The full region (not just
    /// `content`) is kept so `replace_body` knows the fence boundaries and which
    /// side of the fences the body sits on.
    region: Embed.Region,
    /// True when the body is the PREFIX before the open fence (endmatter); false
    /// when it is the suffix after the close fence (frontmatter).
    body_before: bool,
    /// A replacement body installed by `fig_embed_replace_body`, owned. When set,
    /// `render` emits it in place of the original host body slice; the fences and
    /// (edited) content are untouched. Null means "keep the original body".
    body_override: ?[]u8 = null,
    editor: EditorUnion,
    rendered: std.ArrayList(u8) = .empty,
    /// Reused buffer backing the borrowed bytes returned by the comment-read
    /// exports (`fig_embed_get_*_comment`); see the editor-handle twin.
    scratch: std.ArrayList(u8) = .empty,

    fn deinit(self: *EmbedHandle) void {
        switch (self.editor) {
            inline else => |*e| e.deinit(),
        }
        if (self.body_override) |b| self.allocator.free(b);
        self.rendered.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
        self.allocator.free(self.host);
    }
};

fn embedFrom(em: ?*FigEmbed) ?*EmbedHandle {
    const p = em orelse return null;
    return @ptrCast(@alignCast(p));
}

/// Whether this build can edit `t`'s inner format (YAML frontmatter needs YAML,
/// JSON frontmatter needs JSON, fig frontmatter needs the fig dialect). Gated
/// formats are compiled out: `fig_embed_open`/`fig_embed_open_or_init` report
/// `unsupported_format` for one, while `fig_embed_extract` (locate-only, no
/// editor) still works regardless.
fn embedInnerSupported(t: Embed.Type) bool {
    return switch (Embed.innerFormat(t)) {
        .yaml => build_options.lang_yaml,
        .json => build_options.lang_json,
        .fig => build_options.lang_fig,
    };
}

/// Build an `EmbedHandle` over an already-owned `host` with a known `region`,
/// initializing the inner editor over the region's content. Takes ownership of
/// `host` (frees it on any failure). Shared by `fig_embed_open` and
/// `fig_embed_open_or_init`; the caller has already validated the format —
/// specifically, both callers check `embedInnerSupported(t)` first, so a
/// gated-out inner format never reaches the switch below.
fn embedHandleFromHost(
    allocator: std.mem.Allocator,
    host: []u8,
    region: Embed.Region,
    t: Embed.Type,
    out: *?*FigEmbed,
) FigStatus {
    const handle = allocator.create(EmbedHandle) catch {
        allocator.free(host);
        return .out_of_memory;
    };
    handle.* = .{
        .allocator = allocator,
        .host = host,
        .region = region,
        .body_before = Embed.bodyIsBefore(t),
        .editor = switch (Embed.innerFormat(t)) {
            .yaml => if (comptime build_options.lang_yaml) .{ .yaml = .{ .allocator = allocator } } else unreachable,
            .json => if (comptime build_options.lang_json) .{ .json = .{ .allocator = allocator } } else unreachable,
            .fig => if (comptime build_options.lang_fig) .{ .fig = .{ .allocator = allocator } } else unreachable,
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
    if (!embedInnerSupported(t)) return .unsupported_format;

    const region = Embed.locateRegion(input, t) catch |err| return switch (err) {
        error.NotFound => .not_found,
        else => .parse_error,
    };

    const allocator = activeAllocator();
    const host = allocator.dupe(u8, input) catch return .out_of_memory;
    return embedHandleFromHost(allocator, host, region, t, out);
}

/// Like `fig_embed_open`, but when no region of `embed_type` exists, create an
/// empty one (placed per the archetype: frontmatter at the top, endmatter at the
/// bottom) instead of returning `not_found` — so a subsequent `fig_embed_set` /
/// `fig_embed_insert_key` lands the first entry. An existing region is opened
/// unchanged. A malformed region (open fence with no close) still fails.
pub export fn fig_embed_open_or_init(
    input_ptr: ?[*]const u8,
    input_len: usize,
    embed_type: c_int,
    out_embed: ?*?*FigEmbed,
) FigStatus {
    const out = out_embed orelse return .invalid_argument;
    out.* = null;
    const input = sliceOf(input_ptr, input_len) orelse return .invalid_argument;
    const t = embedTypeOf(embed_type) orelse return .invalid_argument;
    if (!embedInnerSupported(t)) return .unsupported_format;

    const allocator = activeAllocator();
    if (Embed.locateRegion(input, t)) |region| {
        const host = allocator.dupe(u8, input) catch return .out_of_memory;
        return embedHandleFromHost(allocator, host, region, t, out);
    } else |err| switch (err) {
        error.NotFound => {
            const created = Embed.initRegion(allocator, input, t) catch return .out_of_memory;
            return embedHandleFromHost(allocator, created.host, created.region, t, out);
        },
        else => return .parse_error,
    }
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

/// Upsert on the embedded config: replace the value at `path`, or insert it when
/// only the trailing key is absent (the `path` must end in a key). Mirrors
/// `fig_editor_set`.
pub export fn fig_embed_set(
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
        inline else => |*e| if (e.set(path, val)) .ok else |err| editStatus(err),
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

// ── Comment reading (embed mirror of fig_editor_get_*) ──────────────────────
// Same borrowed-bytes + `not_found`-means-absent contract as the editor reads;
// the scratch buffer here lives on the embed handle.

fn embedGetComment(
    handle: *EmbedHandle,
    path: []const AST.PathSegment,
    trailing: bool,
    out_ptr: ?*[*c]const u8,
    out_len: ?*usize,
) FigStatus {
    const p = out_ptr orelse return .invalid_argument;
    const l = out_len orelse return .invalid_argument;
    const maybe = (switch (handle.editor) {
        inline else => |*e| if (trailing) e.getTrailingComment(path) else e.getLeadingComment(path),
    }) catch |err| return editStatus(err);
    const bytes = maybe orelse return .not_found;
    defer handle.allocator.free(bytes);
    handle.scratch.clearRetainingCapacity();
    handle.scratch.ensureTotalCapacity(handle.allocator, bytes.len + 1) catch return .out_of_memory;
    handle.scratch.appendSliceAssumeCapacity(bytes);
    p.* = handle.scratch.items.ptr;
    l.* = handle.scratch.items.len;
    return .ok;
}

pub export fn fig_embed_get_leading_comment(
    em: ?*FigEmbed,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    out_ptr: ?*[*c]const u8,
    out_len: ?*usize,
) FigStatus {
    const handle = embedFrom(em) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    return embedGetComment(handle, path, false, out_ptr, out_len);
}

pub export fn fig_embed_get_trailing_comment(
    em: ?*FigEmbed,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    out_ptr: ?*[*c]const u8,
    out_len: ?*usize,
) FigStatus {
    const handle = embedFrom(em) orelse return .invalid_argument;
    var buf: [max_path_len]AST.PathSegment = undefined;
    const path = decodePath(path_ptr, path_len, &buf) orelse return .invalid_argument;
    return embedGetComment(handle, path, true, out_ptr, out_len);
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

pub export fn fig_embed_set_sequence(
    em: ?*FigEmbed,
    path_ptr: ?[*]const FigPathSegment,
    path_len: usize,
    items_ptr: ?[*]const FigStr,
    items_len: usize,
) FigStatus {
    const handle = embedFrom(em) orelse return .invalid_argument;
    var path_buf: [max_path_len]AST.PathSegment = undefined;
    var items_buf: [max_keys_len][]const u8 = undefined;
    const path = decodePath(path_ptr, path_len, &path_buf) orelse return .invalid_argument;
    const items = decodeKeys(items_ptr, items_len, &items_buf) orelse return .invalid_argument;
    return switch (handle.editor) {
        inline else => |*e| if (e.setSequence(path, items)) .ok else |err| editStatus(err),
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
    const region = handle.region;
    const append = struct {
        fn f(h: *EmbedHandle, bytes: []const u8) FigStatus {
            h.rendered.appendSlice(h.allocator, bytes) catch return .out_of_memory;
            return .ok;
        }
    }.f;
    // Reassemble the host file with the edited content (and, if installed, the
    // replacement body) spliced into the located region; the fences and the
    // untouched side stay byte-identical. The body sits before the open fence
    // (endmatter) or after the close fence (frontmatter); `body_override` swaps
    // just that side, leaving everything between the fences in place. With no
    // override the two fence-side slices rejoin into the original host text.
    if (handle.body_before) {
        // [ body ][ open_fence … content … close_fence ][ tail ]
        if (handle.body_override) |b| {
            if (append(handle, b) != .ok) return .out_of_memory;
            if (append(handle, host[region.open_fence.start..region.content.start]) != .ok) return .out_of_memory;
        } else {
            if (append(handle, host[0..region.content.start]) != .ok) return .out_of_memory;
        }
        if (append(handle, src) != .ok) return .out_of_memory;
        if (append(handle, host[region.content.end..]) != .ok) return .out_of_memory;
    } else {
        // [ head ][ open_fence … content … close_fence ][ body ]
        if (append(handle, host[0..region.content.start]) != .ok) return .out_of_memory;
        if (append(handle, src) != .ok) return .out_of_memory;
        if (handle.body_override) |b| {
            if (append(handle, host[region.content.end..region.close_fence.end]) != .ok) return .out_of_memory;
            if (append(handle, b) != .ok) return .out_of_memory;
        } else {
            if (append(handle, host[region.content.end..]) != .ok) return .out_of_memory;
        }
    }

    p.* = handle.rendered.items.ptr;
    l.* = handle.rendered.items.len;
    return .ok;
}

/// Replace the host BODY (the prose the config is embedded in) with `body`,
/// keeping the fences and the current (possibly edited) content byte-identical.
/// The body is the suffix after the close fence (frontmatter) or the prefix
/// before the open fence (endmatter); `replace_body` swaps only that side. The
/// new body is taken verbatim — fig does not parse it. Composes with the value
/// edits: edit keys, replace the body, then `render` once. An empty `body`
/// clears it. Takes effect at the next `render`.
pub export fn fig_embed_replace_body(
    em: ?*FigEmbed,
    body_ptr: ?[*]const u8,
    body_len: usize,
) FigStatus {
    const handle = embedFrom(em) orelse return .invalid_argument;
    const body = if (body_len == 0) "" else (body_ptr orelse return .invalid_argument)[0..body_len];
    const owned = handle.allocator.dupe(u8, body) catch return .out_of_memory;
    if (handle.body_override) |old| handle.allocator.free(old);
    handle.body_override = owned;
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
        @intFromEnum(FigFormat.json) => if (comptime build_options.lang_json) .json else null,
        // JSONC writes plain-JSON syntax plus `//`/`/* */` comments.
        @intFromEnum(FigFormat.jsonc) => if (comptime build_options.lang_json) .jsonc else null,
        @intFromEnum(FigFormat.json5) => if (comptime build_options.lang_json) .json5 else null,
        @intFromEnum(FigFormat.yaml) => if (comptime build_options.lang_yaml) .yaml else null,
        @intFromEnum(FigFormat.toml) => if (comptime build_options.lang_toml) .toml else null,
        @intFromEnum(FigFormat.zon) => if (comptime build_options.lang_zon) .zon else null,
        @intFromEnum(FigFormat.fig) => if (comptime build_options.lang_fig) .fig else null,
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
/// honored by JSON, ZON, and TOML (array wrapping); `indent` by JSON and TOML's
/// wrapped arrays; `width` by TOML's inline-vs-section layout. YAML renders with
/// its own fixed layout.
pub const FigSerializeOptions = extern struct {
    /// The caller-reported size of this struct (set to `sizeof`). Acts as a
    /// version tag: fields may be appended in later releases, and a given field
    /// is read only when `size` covers it (see `serializeOptionsOf`), so a
    /// struct laid out by an older caller stays valid with new fields defaulted.
    size: u32 = @sizeOf(FigSerializeOptions),
    /// Nonzero (default): multi-line, indented output. Zero: compact single-line.
    /// For TOML, zero keeps every array on one line; nonzero lets a wide array
    /// wrap (see `width`).
    pretty: u8 = 1,
    /// Spaces per indent level when `pretty` is nonzero (JSON, and TOML's wrapped
    /// arrays). 0 is treated as the default (2).
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
    /// TOML only: the column budget driving its inline-vs-expanded layout. A
    /// mapping/array that renders within `width` columns stays inline
    /// (`k = { ... }` / `[a, b]`); a wider one expands to a `[section]` / a
    /// wrapped array. 0 is treated as the default (80). Appended after `lossless`,
    /// so older callers (smaller `size`) keep the 80-column default. Two bytes, so
    /// the struct gains trailing padding to a 12-byte size.
    width: u16 = 80,
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
    if (optionCovers(o.size, "width")) out.width = if (o.width == 0) 80 else o.width;
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
            // Neither has a `Lossless.Target` counterpart: `.canonical` is never
            // yielded by `serializeFormatOf` (not a member of the C ABI's
            // `FigFormat`), and `.fig` has no envelope encoding of its own yet.
            // Both fall through to decode-only (no envelope on output).
            .canonical, .fig => null,
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
    if (comptime !build_options.lang_json) return error.SkipZigTest;
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
    if (comptime !build_options.lang_json) return error.SkipZigTest;
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
    if (comptime !build_options.lang_json) return error.SkipZigTest;
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
    if (comptime !build_options.lang_json) return error.SkipZigTest;
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
    if (comptime !build_options.lang_json) return error.SkipZigTest;
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
    if (comptime !build_options.lang_json) return error.SkipZigTest;
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
    if (comptime !build_options.lang_json) return error.SkipZigTest;
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

test "toml editor c abi insert + replace + delete round-trip" {
    if (comptime !build_options.lang_toml) return error.SkipZigTest;
    const src = "[server]\nhost = \"a\"\nport = 1\n";
    var ed: ?*FigEditor = null;
    try std.testing.expectEqual(FigStatus.ok, fig_editor_create(src.ptr, src.len, @intFromEnum(FigFormat.toml), &ed));
    defer fig_editor_destroy(ed);

    // Insert a key into the [server] table (lands at the end of the table region).
    const server = [_]FigPathSegment{keySeg("server")};
    const tls = "tls";
    const tval = "true";
    try std.testing.expectEqual(FigStatus.ok, fig_editor_insert_key(ed, &server, 1, tls.ptr, tls.len, tval.ptr, tval.len));

    // Replace a nested value through a multi-segment C path.
    const port = [_]FigPathSegment{ keySeg("server"), keySeg("port") };
    const nine = "9090";
    try std.testing.expectEqual(FigStatus.ok, fig_editor_replace_val(ed, &port, 2, nine.ptr, nine.len));

    // Delete a key.
    const host = [_]FigPathSegment{ keySeg("server"), keySeg("host") };
    try std.testing.expectEqual(FigStatus.ok, fig_editor_delete_key(ed, &host, 2));

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_editor_source(ed, &ptr, &len));
    try std.testing.expectEqualStrings("[server]\nport = 9090\ntls = true\n", ptr[0..len]);
}

test "toml editor c abi add leading comment uses the # marker" {
    if (comptime !build_options.lang_toml) return error.SkipZigTest;
    const src = "a = 1\nb = 2\n";
    var ed: ?*FigEditor = null;
    try std.testing.expectEqual(FigStatus.ok, fig_editor_create(src.ptr, src.len, @intFromEnum(FigFormat.toml), &ed));
    defer fig_editor_destroy(ed);

    const b = [_]FigPathSegment{keySeg("b")};
    const note = "note";
    try std.testing.expectEqual(FigStatus.ok, fig_editor_add_leading_comment(ed, &b, 1, note.ptr, note.len));

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_editor_source(ed, &ptr, &len));
    try std.testing.expectEqualStrings("a = 1\n# note\nb = 2\n", ptr[0..len]);
}

test "toml editor c abi maps a shape-mismatch edit to invalid_argument" {
    if (comptime !build_options.lang_toml) return error.SkipZigTest;
    const src = "a = 1\n";
    var ed: ?*FigEditor = null;
    try std.testing.expectEqual(FigStatus.ok, fig_editor_create(src.ptr, src.len, @intFromEnum(FigFormat.toml), &ed));
    defer fig_editor_destroy(ed);

    // Inserting a key that already exists rolls back with error.DuplicateKey,
    // which must surface as invalid_argument (a caller error), NOT parse_error.
    const a = "a";
    const two = "2";
    try std.testing.expectEqual(FigStatus.invalid_argument, fig_editor_insert_key(ed, null, 0, a.ptr, a.len, two.ptr, two.len));
    // The editor is still usable after the rolled-back edit.
    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_editor_source(ed, &ptr, &len));
    try std.testing.expectEqualStrings("a = 1\n", ptr[0..len]);
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

test "embed c abi locates region with content and body spans" {
    const md = "---\nk: v\n---\nbody\n";
    var region: FigRegion = .{ .size = @sizeOf(FigRegion), .open_fence = undefined, .content = undefined, .close_fence = undefined, .body = undefined };
    try std.testing.expectEqual(FigStatus.ok, fig_embed_extract(md.ptr, md.len, @intFromEnum(FigEmbedType.frontmatter_yaml), &region));
    try std.testing.expectEqualStrings("k: v\n", md[region.content.start..region.content.end]);
    // The body is the suffix after the close fence.
    try std.testing.expectEqualStrings("body\n", md[region.body.start..region.body.end]);
}

test "embed c abi locates a ```fig fenced frontmatter block (extract-only)" {
    if (comptime !build_options.lang_fig) return error.SkipZigTest;
    const md = "```fig\nk = v\n```\nbody\n";
    var region: FigRegion = .{ .size = @sizeOf(FigRegion), .open_fence = undefined, .content = undefined, .close_fence = undefined, .body = undefined };
    try std.testing.expectEqual(FigStatus.ok, fig_embed_extract(md.ptr, md.len, @intFromEnum(FigEmbedType.frontmatter_fig), &region));
    try std.testing.expectEqualStrings("k = v\n", md[region.content.start..region.content.end]);
    try std.testing.expectEqualStrings("body\n", md[region.body.start..region.body.end]);
}

test "embed c abi fig_embed_open edits a ```fig fenced frontmatter block" {
    if (comptime !build_options.lang_fig) return error.SkipZigTest;
    const md = "```fig\nk = v\n```\nbody\n";
    var out_fm: ?*FigEmbed = null;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_open(md.ptr, md.len, @intFromEnum(FigEmbedType.frontmatter_fig), &out_fm));
    defer fig_embed_destroy(out_fm);

    const path = [_]FigPathSegment{keySeg("k")};
    try std.testing.expectEqual(FigStatus.ok, fig_embed_replace_val(out_fm, &path, 1, "w", 1));

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_render(out_fm, &ptr, &len));
    try std.testing.expectEqualStrings("```fig\nk = w\n```\nbody\n", ptr[0..len]);
}

test "embed c abi region size-gate leaves uncovered fields untouched" {
    const md = "---\nk: v\n---\nbody\n";
    // A caller whose `size` reaches only through `content` must not have its
    // `close_fence`/`body` (past `size`) overwritten — they keep their sentinels.
    const partial_size: u32 = @offsetOf(FigRegion, "content") + @sizeOf(FigSpan);
    var region: FigRegion = .{
        .size = partial_size,
        .open_fence = undefined,
        .content = undefined,
        .close_fence = .{ .start = 111, .end = 222 },
        .body = .{ .start = 333, .end = 444 },
    };
    try std.testing.expectEqual(FigStatus.ok, fig_embed_extract(md.ptr, md.len, @intFromEnum(FigEmbedType.frontmatter_yaml), &region));
    try std.testing.expectEqualStrings("k: v\n", md[region.content.start..region.content.end]);
    try std.testing.expectEqual(@as(usize, 111), region.close_fence.start);
    try std.testing.expectEqual(@as(usize, 333), region.body.start);
}

test "fig_embed_replace_body swaps the body, keeps fences + edited content" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const md = "---\ntitle: Hi\n---\nold body\n";
    var out_fm: ?*FigEmbed = null;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_open(md.ptr, md.len, @intFromEnum(FigEmbedType.frontmatter_yaml), &out_fm));
    defer fig_embed_destroy(out_fm);

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;

    // Body-only swap leaves the frontmatter byte-identical.
    const body = "new body\n";
    try std.testing.expectEqual(FigStatus.ok, fig_embed_replace_body(out_fm, body.ptr, body.len));
    try std.testing.expectEqual(FigStatus.ok, fig_embed_render(out_fm, &ptr, &len));
    try std.testing.expectEqualStrings("---\ntitle: Hi\n---\nnew body\n", ptr[0..len]);

    // Composes with a frontmatter edit, in one render.
    const title = [_]FigPathSegment{keySeg("title")};
    const hello = "Hello";
    try std.testing.expectEqual(FigStatus.ok, fig_embed_replace_val(out_fm, &title, 1, hello.ptr, hello.len));
    try std.testing.expectEqual(FigStatus.ok, fig_embed_render(out_fm, &ptr, &len));
    try std.testing.expectEqualStrings("---\ntitle: Hello\n---\nnew body\n", ptr[0..len]);
}

test "fig_embed_open_or_init creates a frontmatter block where none exists" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const md = "# Just a body\n\nprose\n";
    var out_fm: ?*FigEmbed = null;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_open_or_init(md.ptr, md.len, @intFromEnum(FigEmbedType.frontmatter_yaml), &out_fm));
    defer fig_embed_destroy(out_fm);
    // The synthesized block is empty; the first set lands the opening key.
    const title = [_]FigPathSegment{keySeg("title")};
    const hi = "Hi";
    try std.testing.expectEqual(FigStatus.ok, fig_embed_set(out_fm, &title, 1, hi.ptr, hi.len));
    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_render(out_fm, &ptr, &len));
    try std.testing.expectEqualStrings("---\ntitle: Hi\n---\n# Just a body\n\nprose\n", ptr[0..len]);
}

test "fig_embed_open_or_init opens an existing region unchanged" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const md = "---\ntitle: Old # c\n---\nbody\n";
    var out_fm: ?*FigEmbed = null;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_open_or_init(md.ptr, md.len, @intFromEnum(FigEmbedType.frontmatter_yaml), &out_fm));
    defer fig_embed_destroy(out_fm);
    // Behaves like open: edits the existing region, comment + body preserved.
    const title = [_]FigPathSegment{keySeg("title")};
    const new = "New";
    try std.testing.expectEqual(FigStatus.ok, fig_embed_set(out_fm, &title, 1, new.ptr, new.len));
    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_render(out_fm, &ptr, &len));
    try std.testing.expectEqualStrings("---\ntitle: New # c\n---\nbody\n", ptr[0..len]);
}

test "fig_embed_open_or_init creates a JSON (;;;) frontmatter block" {
    if (comptime !build_options.lang_json) return error.SkipZigTest;
    const md = "# Doc\n";
    var out_fm: ?*FigEmbed = null;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_open_or_init(md.ptr, md.len, @intFromEnum(FigEmbedType.frontmatter_json), &out_fm));
    defer fig_embed_destroy(out_fm);
    const title = [_]FigPathSegment{keySeg("title")};
    const hi = "\"Hi\""; // strict JSON value: a quoted string
    try std.testing.expectEqual(FigStatus.ok, fig_embed_set(out_fm, &title, 1, hi.ptr, hi.len));
    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_render(out_fm, &ptr, &len));
    // The key is quoted for JSON, and the close fence stays on its own line.
    try std.testing.expectEqualStrings(";;;\n{\"title\": \"Hi\"}\n;;;\n# Doc\n", ptr[0..len]);
}

test "fig_embed_open_or_init appends an endmatter block at the bottom" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const md = "# Title\n\nbody text\n";
    var out_fm: ?*FigEmbed = null;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_open_or_init(md.ptr, md.len, @intFromEnum(FigEmbedType.endmatter_yaml), &out_fm));
    defer fig_embed_destroy(out_fm);
    const k = [_]FigPathSegment{keySeg("k")};
    const v = "v";
    try std.testing.expectEqual(FigStatus.ok, fig_embed_set(out_fm, &k, 1, v.ptr, v.len));
    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_embed_render(out_fm, &ptr, &len));
    try std.testing.expectEqualStrings("# Title\n\nbody text\n```endmatter\nk: v\n```\n", ptr[0..len]);
}

test "embed c abi edits json frontmatter (`;;;` fences, JSON inner editor)" {
    if (comptime !build_options.lang_json) return error.SkipZigTest;
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
    if (comptime !build_options.lang_json) return error.SkipZigTest;
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
    if (comptime !build_options.lang_json) return error.SkipZigTest;
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
    if (comptime !build_options.lang_json) return error.SkipZigTest;
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

test "value c abi serialize options carry TOML width through to the inline/section choice" {
    if (comptime !build_options.lang_toml) return error.SkipZigTest;
    var out_value: ?*FigValue = null;
    try std.testing.expectEqual(FigStatus.ok, fig_value_create(&out_value));
    defer fig_value_destroy(out_value);

    // { point: { x = 1, y = 2 } } — a small mapping value whose layout flips on
    // the width budget.
    var id: FigNodeId = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_value_int(out_value, 1, &id));
    const x_val = id;
    try std.testing.expectEqual(FigStatus.ok, fig_value_int(out_value, 2, &id));
    const y_val = id;
    try std.testing.expectEqual(FigStatus.ok, fig_value_string(out_value, "x", 1, &id));
    const x_key = id;
    try std.testing.expectEqual(FigStatus.ok, fig_value_string(out_value, "y", 1, &id));
    const y_key = id;
    const inner = [_]FigKeyValue{ .{ .key = x_key, .value = x_val }, .{ .key = y_key, .value = y_val } };
    try std.testing.expectEqual(FigStatus.ok, fig_value_map(out_value, &inner, inner.len, &id));
    const point_val = id;
    try std.testing.expectEqual(FigStatus.ok, fig_value_string(out_value, "point", 5, &id));
    const point_key = id;
    const outer = [_]FigKeyValue{.{ .key = point_key, .value = point_val }};
    try std.testing.expectEqual(FigStatus.ok, fig_value_map(out_value, &outer, outer.len, &id));
    const root = id;

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;

    // Default width (80): the mapping fits, so it stays an inline table.
    try std.testing.expectEqual(FigStatus.ok, fig_value_serialize(out_value, root, @intFromEnum(FigFormat.toml), &ptr, &len));
    try std.testing.expectEqualStrings("point = { x = 1, y = 2 }\n", ptr[0..len]);

    // A tight width budget forces it to expand to a [section].
    const opts: FigSerializeOptions = .{ .width = 8 };
    try std.testing.expectEqual(FigStatus.ok, fig_value_serialize_opts(out_value, root, @intFromEnum(FigFormat.toml), &opts, &ptr, &len));
    try std.testing.expectEqualStrings("[point]\nx = 1\ny = 2\n", ptr[0..len]);
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
    if (comptime !build_options.lang_json) return error.SkipZigTest;
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
    if (comptime !build_options.lang_json) return error.SkipZigTest;
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

test "fig_parse parses the fig authoring dialect" {
    if (comptime !build_options.lang_fig) return error.SkipZigTest;
    const src = "title = Hello\ncount = 42\n";
    var out_doc: ?*FigDocument = null;
    try std.testing.expectEqual(FigStatus.ok, fig_parse(src.ptr, src.len, @intFromEnum(FigFormat.fig), &out_doc));
    defer fig_document_destroy(out_doc);

    if (comptime build_options.lang_json) {
        var ptr: [*c]const u8 = undefined;
        var len: usize = undefined;
        try std.testing.expectEqual(FigStatus.ok, fig_document_serialize(out_doc, @intFromEnum(FigFormat.json), null, &ptr, &len));
        try std.testing.expectEqualStrings("{\n  \"title\": \"Hello\",\n  \"count\": 42\n}\n", ptr[0..len]);
    }
}

test "fig_document_serialize converts JSON to the fig authoring dialect" {
    if (comptime !build_options.lang_json) return error.SkipZigTest;
    if (comptime !build_options.lang_fig) return error.SkipZigTest;
    const src = "{\"name\":\"fig\",\"nums\":[1,2]}";
    var out_doc: ?*FigDocument = null;
    try std.testing.expectEqual(FigStatus.ok, fig_parse(src.ptr, src.len, @intFromEnum(FigFormat.json), &out_doc));
    defer fig_document_destroy(out_doc);

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_document_serialize(out_doc, @intFromEnum(FigFormat.fig), null, &ptr, &len));
    try std.testing.expectEqualStrings("name = fig\nnums = [1, 2]\n", ptr[0..len]);
}

test "fig_editor_create edits the fig authoring dialect" {
    if (comptime !build_options.lang_fig) return error.SkipZigTest;
    const src = "title = old\nport = 8080\n";
    var ed: ?*FigEditor = null;
    try std.testing.expectEqual(FigStatus.ok, fig_editor_create(src.ptr, src.len, @intFromEnum(FigFormat.fig), &ed));
    defer fig_editor_destroy(ed);

    const path = [_]FigPathSegment{keySeg("port")};
    const repl = "9090";
    try std.testing.expectEqual(FigStatus.ok, fig_editor_replace_val(ed, &path, 1, repl.ptr, repl.len));

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_editor_source(ed, &ptr, &len));
    try std.testing.expectEqualStrings("title = old\nport = 9090\n", ptr[0..len]);
}

test "fig_document_serialize materializes the YAML reference layer when leaving YAML" {
    if (comptime !build_options.lang_json) return error.SkipZigTest;
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
    if (comptime !build_options.lang_json) return error.SkipZigTest;
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
    if (comptime !build_options.lang_json) return error.SkipZigTest;
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
    if (comptime !build_options.lang_json) return error.SkipZigTest;
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
        if (build_options.lang_toml) read | edit | serialize else 0,
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
    try std.testing.expectEqual(
        if (build_options.lang_fig) read | edit | serialize else 0,
        fig_format_capabilities(@intFromEnum(FigFormat.fig)),
    );

    // Unknown / out-of-range format values report no capabilities.
    try std.testing.expectEqual(@as(u32, 0), fig_format_capabilities(0));
    try std.testing.expectEqual(@as(u32, 0), fig_format_capabilities(9999));
    try std.testing.expectEqual(@as(u32, 0), fig_format_capabilities(-1));
}

test "fig_format_capabilities agrees with actual READ/EDIT/SERIALIZE behavior" {
    // The capability matrix is only useful if it matches reality. Rather than
    // re-encode the matrix as a hand-maintained constant (which drifts silently
    // when core gains a capability the ABI hasn't surfaced — exactly how TOML
    // editing stayed hidden), assert each advertised bit against what the
    // corresponding entry point actually does on a valid input. This fails the
    // build the moment a format's real capability and its bit diverge — in either
    // direction, and under any build-flag combination.
    const read = @intFromEnum(FigCapability.read);
    const edit = @intFromEnum(FigCapability.edit);
    const serialize = @intFromEnum(FigCapability.serialize);

    const Case = struct { fmt: FigFormat, sample: []const u8 };
    const cases = [_]Case{
        .{ .fmt = .json, .sample = "{\"a\":1}" },
        .{ .fmt = .jsonc, .sample = "{\"a\":1}" },
        .{ .fmt = .json5, .sample = "{a:1}" },
        .{ .fmt = .yaml, .sample = "a: 1\n" },
        .{ .fmt = .toml, .sample = "a = 1\n" },
        .{ .fmt = .zon, .sample = ".{ .a = 1 }" },
        .{ .fmt = .xml, .sample = "<r>x</r>" },
        .{ .fmt = .fig, .sample = "a = 1\n" },
    };

    // A value every writable format can represent ({"a": 1}); used for the
    // SERIALIZE probe so a failure can only mean "format not writable", never
    // "value unrepresentable in this format".
    var value: ?*FigValue = null;
    try std.testing.expectEqual(FigStatus.ok, fig_value_create(&value));
    defer fig_value_destroy(value);
    var id: FigNodeId = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_value_int(value, 1, &id));
    const v_one = id;
    try std.testing.expectEqual(FigStatus.ok, fig_value_string(value, "a", 1, &id));
    const k_a = id;
    const entries = [_]FigKeyValue{.{ .key = k_a, .value = v_one }};
    try std.testing.expectEqual(FigStatus.ok, fig_value_map(value, &entries, entries.len, &id));
    const root = id;

    for (cases) |c| {
        const fmt = @intFromEnum(c.fmt);
        const caps = fig_format_capabilities(fmt);

        // READ: a valid sample parses iff the format is compiled in (which is
        // exactly when the read bit is set).
        var doc: ?*FigDocument = null;
        const parse_status = fig_parse(c.sample.ptr, c.sample.len, fmt, &doc);
        defer if (doc != null) fig_document_destroy(doc);
        try std.testing.expectEqual((caps & read) != 0, parse_status == .ok);

        // EDIT: create rejects a non-editable or gated format with
        // unsupported_format before it ever parses, so a valid sample never
        // yields parse_error here — the only non-ok outcome is unsupported_format.
        var ed: ?*FigEditor = null;
        const edit_status = fig_editor_create(c.sample.ptr, c.sample.len, fmt, &ed);
        defer if (ed != null) fig_editor_destroy(ed);
        try std.testing.expectEqual((caps & edit) != 0, edit_status != .unsupported_format);

        // SERIALIZE: rendering a representable value succeeds iff the format is
        // writable in this build.
        var ptr: [*c]const u8 = undefined;
        var len: usize = undefined;
        const ser_status = fig_value_serialize(value, root, fmt, &ptr, &len);
        try std.testing.expectEqual((caps & serialize) != 0, ser_status != .unsupported_format);
    }
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

test "fig_editor_set_sequence reconciles a list, preserving survivors' comments" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const src = "tags:\n- a # first\n- b # second\n- c # third\n";
    var ed: ?*FigEditor = null;
    try std.testing.expectEqual(FigStatus.ok, fig_editor_create(src.ptr, src.len, @intFromEnum(FigFormat.yaml), &ed));
    defer fig_editor_destroy(ed);

    var key = [_]u8{ 't', 'a', 'g', 's' };
    const path = [_]FigPathSegment{.{ .kind = 0, .key_ptr = &key, .key_len = key.len, .index = 0 }};

    // -> [c, a, d]: drop b, add d, reorder. a and c keep their comments.
    const items = [_]FigStr{
        .{ .ptr = "c", .len = 1 },
        .{ .ptr = "a", .len = 1 },
        .{ .ptr = "d", .len = 1 },
    };
    try std.testing.expectEqual(FigStatus.ok, fig_editor_set_sequence(ed, &path, path.len, &items, items.len));

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.ok, fig_editor_source(ed, &ptr, &len));
    try std.testing.expectEqualStrings("tags:\n- c # third\n- a # first\n- d\n", ptr[0..len]);

    // An empty target is declined with invalid_argument (caller falls back).
    try std.testing.expectEqual(FigStatus.invalid_argument, fig_editor_set_sequence(ed, &path, path.len, &items, 0));
}

test "fig_editor comment ops reject strict JSON with unsupported_format" {
    if (comptime !build_options.lang_json) return error.SkipZigTest;
    const src = "{\"a\":1}";
    var ed: ?*FigEditor = null;
    try std.testing.expectEqual(FigStatus.ok, fig_editor_create(src.ptr, src.len, @intFromEnum(FigFormat.json), &ed));
    defer fig_editor_destroy(ed);
    var key = [_]u8{'a'};
    const path = [_]FigPathSegment{.{ .kind = 0, .key_ptr = &key, .key_len = 1, .index = 0 }};
    const text = "x";
    try std.testing.expectEqual(FigStatus.unsupported_format, fig_editor_add_leading_comment(ed, &path, 1, text.ptr, text.len));
    try std.testing.expectEqual(FigStatus.unsupported_format, fig_editor_delete_trailing_comment(ed, &path, 1));
    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    try std.testing.expectEqual(FigStatus.unsupported_format, fig_editor_get_leading_comment(ed, &path, 1, &ptr, &len));
    try std.testing.expectEqual(FigStatus.unsupported_format, fig_editor_get_trailing_comment(ed, &path, 1, &ptr, &len));
}

test "fig_editor comment reads return bytes, distinguishing absent from empty" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const src = "# why\na: 1 # two\nb: 2 #\nc: 3\n";
    var ed: ?*FigEditor = null;
    try std.testing.expectEqual(FigStatus.ok, fig_editor_create(src.ptr, src.len, @intFromEnum(FigFormat.yaml), &ed));
    defer fig_editor_destroy(ed);

    var ptr: [*c]const u8 = undefined;
    var len: usize = undefined;
    const at = struct {
        fn key(k: *[1]u8) [1]FigPathSegment {
            return .{.{ .kind = 0, .key_ptr = k, .key_len = 1, .index = 0 }};
        }
    };

    // a: present leading ("why") and present trailing ("two").
    var ka = [_]u8{'a'};
    const pa = at.key(&ka);
    try std.testing.expectEqual(FigStatus.ok, fig_editor_get_leading_comment(ed, &pa, 1, &ptr, &len));
    try std.testing.expectEqualStrings("why", ptr[0..len]);
    try std.testing.expectEqual(FigStatus.ok, fig_editor_get_trailing_comment(ed, &pa, 1, &ptr, &len));
    try std.testing.expectEqualStrings("two", ptr[0..len]);

    // b: a bare `#` trailing → present but EMPTY (ok, len 0), not absent.
    var kb = [_]u8{'b'};
    const pb = at.key(&kb);
    try std.testing.expectEqual(FigStatus.ok, fig_editor_get_trailing_comment(ed, &pb, 1, &ptr, &len));
    try std.testing.expectEqual(@as(usize, 0), len);

    // c: no comment either way → not_found (absent).
    var kc = [_]u8{'c'};
    const pc = at.key(&kc);
    try std.testing.expectEqual(FigStatus.not_found, fig_editor_get_leading_comment(ed, &pc, 1, &ptr, &len));
    try std.testing.expectEqual(FigStatus.not_found, fig_editor_get_trailing_comment(ed, &pc, 1, &ptr, &len));
}
