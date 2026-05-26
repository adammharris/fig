//! C ABI for `fig`
//!
//! This file is the entry point for programs accessing `fig` outside of the Zig language.

const std = @import("std");
const builtin = @import("builtin");
const Document = @import("document.zig");
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
