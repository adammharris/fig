//! ZON-specific editing helpers for `Editor(Zon)`, plus its editor tests.
//!
//! ZON's editing needs are small parameter swaps on the generic engine, not the
//! structural logic TOML (multi-region tables)/YAML (reference layer)/Fig
//! (marker-prefix copying) delegate out to their own helper modules:
//!   * every ZON struct/array literal opens `.{` — `editor.isFlow` treats that
//!     as flow, so ZON routes through the same flow-entry splice engine JSON
//!     does (see `editor.zig`'s `kv_sep`/`flowOpenEnd`);
//!   * struct fields separate key and value with ` = `, not `: ` (`kv_sep`);
//!   * a struct-field key logically needs a leading `.` (`.name`), quoted as
//!     `.@"..."` when it isn't a bare identifier — the one piece of real
//!     ZON-specific rendering, factored out here as `appendFieldName` so
//!     `editor.zig`'s `set`-insert path (`formatInsertKey`) can call it without
//!     hosting ZON's identifier/quoting rule itself.
//!
//! `appendFieldName` intentionally duplicates `zon/printer.zig`'s small
//! `isBareIdentifier`/dotted-name-quoting rule rather than importing it: the
//! printer's version writes to a `std.Io.Writer`, while `insertKey`'s callers
//! build `std.ArrayList(u8)` text — not worth a shared abstraction for ~15
//! lines with no room to drift (both must agree with what `std.zig.Ast`
//! accepts as a bare identifier, which is exactly `[A-Za-z_][A-Za-z0-9_]*`
//! minus keywords).

const std = @import("std");

const AST = @import("../../ast/ast.zig");
const editor = @import("../../editor.zig");
const Zon = @import("zon.zig").Language;
const log = std.log.scoped(.editor);

/// Whether `name` is a legal bare Zig field name — mirrors `zon/printer.zig`'s
/// `isBareIdentifier` (`[A-Za-z_][A-Za-z0-9_]*`, and not a keyword).
fn isBareIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| {
        const ok = c == '_' or std.ascii.isAlphabetic(c) or (i > 0 and std.ascii.isDigit(c));
        if (!ok) return false;
    }
    return std.zig.Token.getKeyword(name) == null;
}

/// Render a logical mapping key as ZON struct-field syntax: `.name` when it's a
/// bare identifier, else the quoted form `.@"name with spaces"`. This is the
/// syntax `insertKey`'s `key_text` expects verbatim, so `editor.zig`'s
/// `formatInsertKey` (the `set`-insert path, which only has a *logical* key
/// name) calls this to render one.
pub fn appendFieldName(out: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8) !void {
    try out.append(allocator, '.');
    if (isBareIdentifier(name)) {
        try out.appendSlice(allocator, name);
        return;
    }
    try out.appendSlice(allocator, "@\"");
    for (name) |ch| switch (ch) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        else => try out.append(allocator, ch),
    };
    try out.append(allocator, '"');
}

// =======
// TESTS
// =======
//
// Like `json/editor_helper.zig`, most of ZON's coverage is the generic engine
// exercised through `Editor(Zon)` — these tests double as engine smoke tests
// for the `.{`-is-flow / ` = ` / dotted-key behavior above.

fn newZonEditor(input: []const u8) !editor.Editor(Zon) {
    var ed: editor.Editor(Zon) = .{ .allocator = std.testing.allocator };
    try ed.init(input);
    return ed;
}

fn expectZonSource(ed: *const editor.Editor(Zon), expected: []const u8) !void {
    errdefer log.err("actual:   \"{s}\"", .{ed.source.items});
    errdefer log.err("expected: \"{s}\"", .{expected});
    try std.testing.expectEqualStrings(expected, ed.source.items);
}

test "zon replace a scalar value" {
    var ed = try newZonEditor(".{ .name = \"Ada\", .age = 36 }");
    defer ed.deinit();
    try ed.replaceValAtPath(&.{.{ .key = "age" }}, "37");
    try expectZonSource(&ed, ".{ .name = \"Ada\", .age = 37 }");
}

test "zon rename a leaf key (bare identifier span excludes the dot)" {
    var ed = try newZonEditor(".{ .age = 36 }");
    defer ed.deinit();
    try ed.replaceKeyAtPath(&.{.{ .key = "age" }}, "years");
    try expectZonSource(&ed, ".{ .years = 36 }");
}

test "zon insert key into a compact struct" {
    var ed = try newZonEditor(".{ .a = 1 }");
    defer ed.deinit();
    try ed.insertKey(&.{}, ".b", "2");
    try expectZonSource(&ed, ".{ .a = 1, .b = 2 }");
}

test "zon insert key into an empty struct" {
    // Tight, unpadded splice — matching the pre-existing JSON/YAML convention
    // for a freshly-created single member (see `insertFlowEntry`).
    var ed = try newZonEditor(".{}");
    defer ed.deinit();
    try ed.insertKey(&.{}, ".a", "1");
    try expectZonSource(&ed, ".{.a = 1}");
}

test "zon insert key into a pretty-printed struct lands on its own line" {
    var ed = try newZonEditor(
        \\.{
        \\    .a = 1,
        \\    .b = 2,
        \\}
    );
    defer ed.deinit();
    try ed.insertKey(&.{}, ".c", "3");
    try expectZonSource(&ed,
        \\.{
        \\    .a = 1,
        \\    .b = 2,
        \\    .c = 3,
        \\}
    );
}

test "zon insert key into a nested pretty-printed struct matches its indent" {
    var ed = try newZonEditor(
        \\.{
        \\    .server = .{
        \\        .host = "a",
        \\    },
        \\}
    );
    defer ed.deinit();
    try ed.insertKey(&.{.{ .key = "server" }}, ".port", "8080");
    try expectZonSource(&ed,
        \\.{
        \\    .server = .{
        \\        .host = "a",
        \\        .port = 8080,
        \\    },
        \\}
    );
}

test "zon delete a key" {
    // `deleteKey` splices whole lines (see its doc comment in `editor.zig`), so —
    // as with every other format's delete tests — the fixture is multi-line, one
    // entry per line; a compact single-line struct has no per-entry line to
    // delete without the whole document being "the line."
    var ed = try newZonEditor(
        \\.{
        \\    .a = 1,
        \\    .b = 2,
        \\    .c = 3,
        \\}
    );
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "b" }});
    try expectZonSource(&ed,
        \\.{
        \\    .a = 1,
        \\    .c = 3,
        \\}
    );
}

test "zon delete a key with an owned leading comment" {
    var ed = try newZonEditor(
        \\.{
        \\    .a = 1,
        \\    // note
        \\    .b = 2,
        \\}
    );
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "b" }});
    try expectZonSource(&ed,
        \\.{
        \\    .a = 1,
        \\}
    );
}

test "zon array append/prepend/remove" {
    var ed = try newZonEditor(".{ 1, 2 }");
    defer ed.deinit();
    try ed.appendToSeq(&.{}, "3");
    try expectZonSource(&ed, ".{ 1, 2, 3 }");
    try ed.prependToSeq(&.{}, "0");
    try expectZonSource(&ed, ".{ 0, 1, 2, 3 }");
    try ed.removeSeqItem(&.{}, 2);
    try expectZonSource(&ed, ".{ 0, 1, 3 }");
}

test "zon appendToSeq on an empty .{} is NotASequence (ZON has no way to tell an empty struct from an empty array)" {
    // Unlike JSON's `[]`/`{}` or YAML's `[]`/`{}`, ZON's struct and array
    // literals share one empty spelling (`.{}`); fig's parser resolves that
    // ambiguity by always treating an empty container as a mapping (see
    // `zon/parser.zig`'s "empty .{} is an empty mapping" test). So there is no
    // ZON source an empty *array* append could target — the caller must seed a
    // non-empty array (or a struct) explicitly.
    var ed = try newZonEditor(".{}");
    defer ed.deinit();
    try std.testing.expectError(error.NotASequence, ed.appendToSeq(&.{}, "1"));
}

test "zon append onto a multi-line one-item-per-line array" {
    var ed = try newZonEditor(
        \\.{
        \\    1,
        \\    2,
        \\}
    );
    defer ed.deinit();
    try ed.appendToSeq(&.{}, "3");
    try expectZonSource(&ed,
        \\.{
        \\    1,
        \\    2,
        \\    3,
        \\}
    );
}

test "zon set replaces an existing key" {
    var ed = try newZonEditor(".{ .a = 1 }");
    defer ed.deinit();
    try ed.set(&.{.{ .key = "a" }}, "2");
    try expectZonSource(&ed, ".{ .a = 2 }");
}

test "zon set creates a missing bare-identifier key with a leading dot" {
    var ed = try newZonEditor(".{ .a = 1 }");
    defer ed.deinit();
    try ed.set(&.{.{ .key = "b" }}, "2");
    try expectZonSource(&ed, ".{ .a = 1, .b = 2 }");
}

test "zon set creates a missing key needing @\"...\" quoting" {
    var ed = try newZonEditor(".{ .a = 1 }");
    defer ed.deinit();
    try ed.set(&.{.{ .key = "has space" }}, "2");
    try expectZonSource(&ed, ".{ .a = 1, .@\"has space\" = 2 }");
}

test "zon set auto-vivifies a missing parent as an empty struct" {
    var ed = try newZonEditor(".{}");
    defer ed.deinit();
    try ed.set(&.{ .{ .key = "server" }, .{ .key = "port" } }, "8080");
    try expectZonSource(&ed, ".{.server = .{.port = 8080}}");
}

test "zon insertKey promotes a null value to a struct" {
    var ed = try newZonEditor(".{ .a = null }");
    defer ed.deinit();
    try ed.insertKey(&.{.{ .key = "a" }}, ".b", "1");
    try expectZonSource(&ed, ".{ .a = .{ .b = 1 } }");
}

test "zon failed edit rolls back and keeps editor usable" {
    var ed = try newZonEditor(".{ .a = 1 }");
    defer ed.deinit();
    if (ed.replaceValAtPath(&.{.{ .key = "a" }}, "[oops")) |_| {
        return error.TestExpectedFailedEdit;
    } else |_| {}
    try expectZonSource(&ed, ".{ .a = 1 }");
    try ed.replaceValAtPath(&.{.{ .key = "a" }}, "9");
    try expectZonSource(&ed, ".{ .a = 9 }");
}
