//! Reflection-based deserialization: parse a config format straight into a
//! native Zig type, à la `std.json.parseFromSlice`.
//!
//! The format is parsed to a `fig` AST, then mapped onto `T` by `@typeInfo`
//! reflection — structs from mappings, slices/arrays from sequences, enums from
//! string (or ZON enum-literal) scalars, and so on. It is deliberately a
//! *convenience* layer: by default it ignores mapping keys with no matching
//! field (`Options.ignore_unknown_fields`), so it is tolerant ("lossy") of extra
//! data the way frontmatter readers usually want.
//!
//! For comment-preserving edits or full structural access, use `Editor` /
//! `Document` / `AST` directly; this is the one-shot "give me my struct" path.

const std = @import("std");
const AST = @import("ast.zig");

const Json = @import("json/parser.zig");
const Yaml = @import("yaml/parser.zig");
const Toml = @import("toml/parser.zig");
const Zon = @import("zon/parser.zig");

/// The source format to parse before mapping onto `T`.
pub const Format = enum { json, jsonc, yaml, toml, zon };

pub const Options = struct {
    /// Mapping keys with no matching struct field are ignored when true (the
    /// tolerant default), or an `error.UnknownField` when false.
    ignore_unknown_fields: bool = true,
};

/// Ways the mapping onto `T` can fail (parser errors are surfaced separately by
/// the entry points).
pub const Error = error{
    /// A node's kind doesn't match the target type (e.g. a string for an `i64`).
    UnexpectedType,
    /// A required struct field (no default, not optional) was absent.
    MissingField,
    /// A mapping key matched no field and `ignore_unknown_fields` was false.
    UnknownField,
    /// A numeric scalar didn't parse into the target integer/float type.
    InvalidNumber,
    /// A scalar didn't match any tag of the target enum.
    InvalidEnum,
} || std.mem.Allocator.Error || AST.ResolveError;

/// An owned deserialization result: `value` and the arena backing all of its
/// allocations. Free both with `deinit`. Mirrors `std.json.Parsed`.
pub fn Parsed(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: @This()) void {
            const child = self.arena.child_allocator;
            self.arena.deinit();
            child.destroy(self.arena);
        }
    };
}

/// Parse `source` as `format` and deserialize it into a `T`, returning a value
/// that owns its allocations via an internal arena (`Parsed(T).deinit`).
pub fn parseFromSlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    source: []const u8,
    format: Format,
    options: Options,
) !Parsed(T) {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = .init(allocator);
    errdefer arena.deinit();

    const value = try parseFromSliceLeaky(T, arena.allocator(), source, format, options);
    return .{ .arena = arena, .value = value };
}

/// Like `parseFromSlice`, but every allocation is made in `allocator` with no
/// cleanup of its own — pass an arena and free it yourself. The intermediate
/// AST is freed before returning; only `T`'s own data is left allocated.
pub fn parseFromSliceLeaky(
    comptime T: type,
    allocator: std.mem.Allocator,
    source: []const u8,
    format: Format,
    options: Options,
) !T {
    var ast = try parseToAst(allocator, source, format);
    defer ast.deinit();
    return parseValue(T, allocator, &ast, ast.root, options);
}

fn parseToAst(allocator: std.mem.Allocator, source: []const u8, format: Format) !AST {
    return switch (format) {
        .json => Json.parseAbstract(allocator, source, .JSON),
        .jsonc => Json.parseAbstract(allocator, source, .JSONC),
        .yaml => Yaml.parseAbstract(allocator, source, .v1_2_2),
        .toml => Toml.parseAbstract(allocator, source, .TOML_1_1),
        .zon => Zon.parseAbstract(allocator, source, .ZON),
    };
}

fn parseValue(comptime T: type, allocator: std.mem.Allocator, ast: *const AST, id: AST.Node.Id, options: Options) Error!T {
    // Resolve a YAML alias to its target (a no-op for every other node/format).
    const node = ast.nodes[try ast.resolveDeep(ast.nodes[id])];
    return switch (@typeInfo(T)) {
        .bool => switch (node.kind) {
            .boolean => |b| b,
            else => error.UnexpectedType,
        },
        .int => parseInt(T, node),
        .float => parseFloat(T, node),
        .optional => |opt| if (node.kind == .null_)
            null
        else
            try parseValue(opt.child, allocator, ast, node.id, options),
        .@"enum" => parseEnum(T, node),
        .@"struct" => parseStruct(T, allocator, ast, node, options),
        .pointer => parseSlice(T, allocator, ast, node, options),
        .array => parseArray(T, allocator, ast, node, options),
        else => @compileError("fig.deserialize: cannot deserialize into " ++ @typeName(T)),
    };
}

fn parseInt(comptime T: type, node: AST.Node) Error!T {
    const raw = switch (node.kind) {
        .number => |n| n.raw,
        else => return error.UnexpectedType,
    };
    return std.fmt.parseInt(T, raw, 0) catch error.InvalidNumber;
}

fn parseFloat(comptime T: type, node: AST.Node) Error!T {
    const raw = switch (node.kind) {
        .number => |n| n.raw,
        else => return error.UnexpectedType,
    };
    if (specialFloat(T, raw)) |f| return f;
    return std.fmt.parseFloat(T, raw) catch error.InvalidNumber;
}

/// YAML's `.inf`/`.nan` spellings, which `std.fmt.parseFloat` rejects.
fn specialFloat(comptime T: type, raw: []const u8) ?T {
    const eql = std.mem.eql;
    if (eql(u8, raw, ".inf") or eql(u8, raw, ".Inf") or eql(u8, raw, ".INF") or
        eql(u8, raw, "+.inf") or eql(u8, raw, "+.Inf") or eql(u8, raw, "+.INF"))
        return std.math.inf(T);
    if (eql(u8, raw, "-.inf") or eql(u8, raw, "-.Inf") or eql(u8, raw, "-.INF"))
        return -std.math.inf(T);
    if (eql(u8, raw, ".nan") or eql(u8, raw, ".NaN") or eql(u8, raw, ".NAN"))
        return std.math.nan(T);
    return null;
}

fn parseEnum(comptime T: type, node: AST.Node) Error!T {
    const name = switch (node.kind) {
        .string => |s| s,
        // A ZON enum literal (`.foo`) carries the bare name in `text`.
        .extended => |e| if (e.kind == .enum_literal) e.text else return error.UnexpectedType,
        else => return error.UnexpectedType,
    };
    return std.meta.stringToEnum(T, name) orelse error.InvalidEnum;
}

fn parseStruct(comptime T: type, allocator: std.mem.Allocator, ast: *const AST, node: AST.Node, options: Options) Error!T {
    const first = switch (node.kind) {
        .mapping => |m| m,
        else => return error.UnexpectedType,
    };
    const fields = @typeInfo(T).@"struct".fields;

    var result: T = undefined;
    var seen = [_]bool{false} ** fields.len;

    var cur = first;
    while (cur) |kvid| : (cur = ast.nodes[kvid].next_sibling) {
        const kv = ast.nodes[kvid].kind.keyvalue;
        const key = switch (ast.nodes[kv.key].kind) {
            .string => |s| s,
            else => continue, // non-string keys can't name a Zig field
        };
        var matched = false;
        inline for (fields, 0..) |field, i| {
            if (!matched and std.mem.eql(u8, field.name, key)) {
                @field(result, field.name) = try parseValue(field.type, allocator, ast, kv.value, options);
                seen[i] = true;
                matched = true;
            }
        }
        if (!matched and !options.ignore_unknown_fields) return error.UnknownField;
    }

    // Fill fields the mapping didn't provide: a default, else null for an
    // optional, else it's missing.
    inline for (fields, 0..) |field, i| {
        if (!seen[i]) {
            if (field.default_value_ptr) |ptr| {
                @field(result, field.name) = @as(*const field.type, @ptrCast(@alignCast(ptr))).*;
            } else if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
            } else {
                return error.MissingField;
            }
        }
    }
    return result;
}

fn parseSlice(comptime T: type, allocator: std.mem.Allocator, ast: *const AST, node: AST.Node, options: Options) Error!T {
    const ptr = @typeInfo(T).pointer;
    if (ptr.size != .slice) @compileError("fig.deserialize: unsupported pointer type " ++ @typeName(T));

    // `[]const u8` / `[:0]const u8` are strings, not byte sequences.
    if (ptr.child == u8) {
        const s = switch (node.kind) {
            .string => |str| str,
            else => return error.UnexpectedType,
        };
        if (comptime ptr.sentinel_ptr != null) return allocator.dupeZ(u8, s);
        return allocator.dupe(u8, s);
    }

    const first = switch (node.kind) {
        .sequence => |seq| seq,
        else => return error.UnexpectedType,
    };
    var count: usize = 0;
    var c = first;
    while (c) |cid| : (c = ast.nodes[cid].next_sibling) count += 1;

    const out = try allocator.alloc(ptr.child, count);
    c = first;
    var i: usize = 0;
    while (c) |cid| : (c = ast.nodes[cid].next_sibling) {
        out[i] = try parseValue(ptr.child, allocator, ast, cid, options);
        i += 1;
    }
    return out;
}

fn parseArray(comptime T: type, allocator: std.mem.Allocator, ast: *const AST, node: AST.Node, options: Options) Error!T {
    const arr = @typeInfo(T).array;
    const first = switch (node.kind) {
        .sequence => |seq| seq,
        else => return error.UnexpectedType,
    };
    var result: T = undefined;
    var c = first;
    var i: usize = 0;
    while (c) |cid| : (c = ast.nodes[cid].next_sibling) {
        if (i >= arr.len) return error.UnexpectedType; // too many elements
        result[i] = try parseValue(arr.child, allocator, ast, cid, options);
        i += 1;
    }
    if (i != arr.len) return error.UnexpectedType; // too few elements
    return result;
}

// --- tests ---------------------------------------------------------------

const testing = std.testing;

test "deserialize: yaml into a struct (defaults, optionals, unknown ignored)" {
    const Config = struct {
        title: []const u8,
        count: i64,
        ratio: f64,
        enabled: bool,
        tags: []const []const u8,
        nickname: ?[]const u8 = null,
        retries: u8 = 7,
    };
    const src =
        \\title: Hi
        \\count: 42
        \\ratio: 1.5
        \\enabled: true
        \\tags:
        \\- a
        \\- b
        \\extra: ignored
        \\
    ;
    const parsed = try parseFromSlice(Config, testing.allocator, src, .yaml, .{});
    defer parsed.deinit();

    try testing.expectEqualStrings("Hi", parsed.value.title);
    try testing.expectEqual(@as(i64, 42), parsed.value.count);
    try testing.expectEqual(@as(f64, 1.5), parsed.value.ratio);
    try testing.expect(parsed.value.enabled);
    try testing.expectEqual(@as(usize, 2), parsed.value.tags.len);
    try testing.expectEqualStrings("a", parsed.value.tags[0]);
    try testing.expectEqualStrings("b", parsed.value.tags[1]);
    try testing.expect(parsed.value.nickname == null);
    try testing.expectEqual(@as(u8, 7), parsed.value.retries);
}

test "deserialize: json into a struct" {
    const S = struct { name: []const u8, n: u32 };
    const parsed = try parseFromSlice(S, testing.allocator, "{\"name\": \"x\", \"n\": 5}", .json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("x", parsed.value.name);
    try testing.expectEqual(@as(u32, 5), parsed.value.n);
}

test "deserialize: enums from string scalars" {
    const Color = enum { red, green, blue };
    const S = struct { c: Color };
    const parsed = try parseFromSlice(S, testing.allocator, "c: green\n", .yaml, .{});
    defer parsed.deinit();
    try testing.expectEqual(Color.green, parsed.value.c);

    try testing.expectError(error.InvalidEnum, parseFromSlice(S, testing.allocator, "c: mauve\n", .yaml, .{}));
}

test "deserialize: strict unknown fields and missing required fields error" {
    const S = struct { a: u8, b: u8 };
    try testing.expectError(
        error.UnknownField,
        parseFromSlice(S, testing.allocator, "a: 1\nb: 2\nx: 3\n", .yaml, .{ .ignore_unknown_fields = false }),
    );
    try testing.expectError(
        error.MissingField,
        parseFromSlice(S, testing.allocator, "a: 1\n", .yaml, .{}),
    );
}

test "deserialize: zon enum literals and toml scalars" {
    const Mode = enum { fast, slow };
    const S = struct { mode: Mode, n: u32 };

    // ZON: a `.field = value` struct, `.fast` an enum literal.
    const z = try parseFromSlice(S, testing.allocator, ".{ .mode = .fast, .n = 3 }", .zon, .{});
    defer z.deinit();
    try testing.expectEqual(Mode.fast, z.value.mode);
    try testing.expectEqual(@as(u32, 3), z.value.n);

    // TOML: enums come from string scalars.
    const t = try parseFromSlice(S, testing.allocator, "mode = \"slow\"\nn = 9\n", .toml, .{});
    defer t.deinit();
    try testing.expectEqual(Mode.slow, t.value.mode);
    try testing.expectEqual(@as(u32, 9), t.value.n);
}

test "deserialize: fixed-size array requires an exact-length sequence" {
    const S = struct { rgb: [3]u8 };
    const ok = try parseFromSlice(S, testing.allocator, "rgb: [1, 2, 3]\n", .yaml, .{});
    defer ok.deinit();
    try testing.expectEqual([3]u8{ 1, 2, 3 }, ok.value.rgb);

    try testing.expectError(error.UnexpectedType, parseFromSlice(S, testing.allocator, "rgb: [1, 2]\n", .yaml, .{}));
}
