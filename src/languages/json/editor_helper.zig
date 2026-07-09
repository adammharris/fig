//! Editor tests for the JSON family (`Editor(json.Language)`) — both the generic
//! span-splice engine (plain JSON) and the JSON5 dialect.
//!
//! Like `toml/` and `yaml/editor_helper.zig`, each language's editor tests live
//! next to that language's concerns rather than in `editor.zig`. JSON needs no
//! format-specific editing logic (it routes straight through the generic engine),
//! so this module is tests only — they double as the engine's own smoke tests.

const std = @import("std");

const AST = @import("../../ast/ast.zig");
const editor = @import("../../editor.zig");
const json = @import("json.zig");
const log = std.log.scoped(.editor);

fn testEditor(input: []const u8, path: []const AST.PathSegment, key_or_val: enum { key, val }, text: []const u8, expected: []const u8) !void {
    var ed: editor.Editor(json.Language) = .{ .allocator = std.testing.allocator };
    try ed.init(input);
    defer ed.deinit();
    switch (key_or_val) {
        .key => try ed.replaceKeyAtPath(path, text),
        .val => try ed.replaceValAtPath(path, text),
    }
    const actual = ed.source.items;
    errdefer log.err("actual: {s}", .{actual});
    errdefer log.err("expected: {s}", .{expected});
    try std.testing.expect(std.mem.eql(u8, expected, actual));
}

test "simple value edit" {
    try testEditor(
        "[{\"hello\":\"world\"}]",
        &[_]AST.PathSegment{ .{ .index = 0 }, .{ .key = "hello" } },
        .val,
        "\"person!\"",
        "[{\"hello\":\"person!\"}]",
    );
}

test "simple key edit" {
    try testEditor("[{\"hello\":\"world\"}]", &[_]AST.PathSegment{ .{ .index = 0 }, .{ .key = "hello" } }, .key, "\"greetings\"", "[{\"greetings\":\"world\"}]");
}

// --- JSON5 editing ---
//
// JSON5 is a dialect of the JSON language, so it routes through the same generic
// editor. The editor splices source bytes in place (it never reprints), so every
// JSON5-ism outside the edited span — unquoted keys, trailing commas, single
// quotes, `//` and `/* */` comments — survives byte-for-byte. The owned-comment
// scan on delete is `//`/`/* */`-aware so a deleted key carries its own comment.

fn newJson5Editor(input: []const u8) !editor.Editor(json.Language) {
    var ed: editor.Editor(json.Language) = .{ .allocator = std.testing.allocator, .format = .JSON5 };
    try ed.init(input);
    return ed;
}

fn expectJson5Source(ed: *const editor.Editor(json.Language), expected: []const u8) !void {
    errdefer log.err("actual:   \"{s}\"", .{ed.source.items});
    errdefer log.err("expected: \"{s}\"", .{expected});
    try std.testing.expectEqualStrings(expected, ed.source.items);
}

test "json5 value edit preserves unquoted keys, comments, trailing comma" {
    var ed = try newJson5Editor(
        \\{
        \\  // server config
        \\  host: 'localhost',
        \\  port: 8080, // default
        \\}
    );
    defer ed.deinit();
    try ed.replaceValAtPath(&.{.{ .key = "port" }}, "9090");
    try expectJson5Source(&ed,
        \\{
        \\  // server config
        \\  host: 'localhost',
        \\  port: 9090, // default
        \\}
    );
}

test "json5 key rename keeps it unquoted" {
    var ed = try newJson5Editor("{ host: 'localhost', port: 8080 }");
    defer ed.deinit();
    try ed.replaceKeyAtPath(&.{.{ .key = "port" }}, "listen");
    try expectJson5Source(&ed, "{ host: 'localhost', listen: 8080 }");
}

test "json5 delete key carries its owned // comment" {
    var ed = try newJson5Editor(
        \\{
        \\  host: 'localhost',
        \\  // the listening port
        \\  port: 8080,
        \\}
    );
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "port" }});
    try expectJson5Source(&ed,
        \\{
        \\  host: 'localhost',
        \\}
    );
}

test "json5 delete key carries an owned /* */ block comment" {
    var ed = try newJson5Editor(
        \\{
        \\  host: 'localhost',
        \\  /* the listening
        \\     port number */
        \\  port: 8080,
        \\}
    );
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "port" }});
    try expectJson5Source(&ed,
        \\{
        \\  host: 'localhost',
        \\}
    );
}

// Regression: a compact single-line object packs multiple entries onto one
// physical line — the *only* shape a minified/compact JSON object ever has —
// so `deleteKey`'s generic line-based delete (built for one-entry-per-line
// layout) used to delete the whole line, i.e. the sole remaining entry's
// deletion wiped the entire document, and a middle/first entry's deletion
// swallowed its neighbor too. Deleting one key from a packed object must
// leave its siblings untouched.
test "json5 delete key from a packed single-line object (regression)" {
    var ed = try newJson5Editor("{ host: 'localhost', port: 8080, tls: true }");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "port" }});
    try expectJson5Source(&ed, "{ host: 'localhost', tls: true }");
}

test "json5 delete first key of a packed single-line object" {
    var ed = try newJson5Editor("{ host: 'localhost', port: 8080 }");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "host" }});
    try expectJson5Source(&ed, "{ port: 8080 }");
}

test "json delete key from a packed single-line object (regression)" {
    var ed: editor.Editor(json.Language) = .{ .allocator = std.testing.allocator };
    try ed.init("{\"a\":1,\"b\":2,\"c\":3}");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "b" }});
    try expectJson5Source(&ed, "{\"a\":1,\"c\":3}");
}

// Regression: deleting the *last* key of a one-entry-per-line (pretty) object
// used to leave the *predecessor's* separator comma dangling before the closing
// brace — the block-shaped line delete removes the last entry's own line but not
// the comma on the line above it. In strict JSON (no trailing comma allowed)
// that produced invalid output that failed to reparse; the flow-aware splice now
// drops the preceding comma instead.
test "json delete last key of a pretty multi-line object (regression)" {
    var ed: editor.Editor(json.Language) = .{ .allocator = std.testing.allocator };
    try ed.init("{\n  \"a\": 1,\n  \"b\": 2\n}\n");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "b" }});
    try expectJson5Source(&ed, "{\n  \"a\": 1\n}\n");
}

test "json delete first key of a pretty multi-line object keeps indentation" {
    var ed: editor.Editor(json.Language) = .{ .allocator = std.testing.allocator };
    try ed.init("{\n  \"a\": 1,\n  \"b\": 2\n}\n");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "a" }});
    try expectJson5Source(&ed, "{\n  \"b\": 2\n}\n");
}

// Regression: deleting the *only* key of a single-entry object must leave an
// empty object `{}`, not delete the braces with the line. A packed single-line
// `{"a":1}` has the braces on the entry's own line, so the block-shaped line
// delete used to wipe the whole document (here: fail to reparse as strict JSON).
test "json delete only key of a single-entry object leaves an empty object" {
    var ed: editor.Editor(json.Language) = .{ .allocator = std.testing.allocator };
    try ed.init("{\"a\":1}");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "a" }});
    try expectJson5Source(&ed, "{}");
}

test "json5 delete only key of a single-entry object leaves an empty object" {
    var ed = try newJson5Editor("{ a: 1 }");
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "a" }});
    try expectJson5Source(&ed, "{ }");
}

test "json5 delete leaves an unrelated earlier comment intact" {
    var ed = try newJson5Editor(
        \\{
        \\  // host comment
        \\  host: 'localhost',
        \\  port: 8080,
        \\}
    );
    defer ed.deinit();
    try ed.deleteKey(&.{.{ .key = "port" }});
    try expectJson5Source(&ed,
        \\{
        \\  // host comment
        \\  host: 'localhost',
        \\}
    );
}

test "json5 array append with pre-existing trailing comma" {
    // JSON5 permits a trailing comma before ']'; appending must not double
    // it into an empty element that fails to reparse.
    var ed = try newJson5Editor("{ ports: [1, 2,] }");
    defer ed.deinit();
    try ed.appendToSeq(&.{.{ .key = "ports" }}, "3");
    try expectJson5Source(&ed, "{ ports: [1, 2, 3,] }");
}

test "json5 array append onto a multi-line one-item-per-line array" {
    var ed = try newJson5Editor(
        \\{
        \\  ports: [
        \\    1,
        \\    2,
        \\  ],
        \\}
    );
    defer ed.deinit();
    try ed.appendToSeq(&.{.{ .key = "ports" }}, "3");
    try expectJson5Source(&ed,
        \\{
        \\  ports: [
        \\    1,
        \\    2,
        \\    3,
        \\  ],
        \\}
    );
}

test "json5 remove last item of a multi-line trailing-comma array (regression)" {
    var ed = try newJson5Editor(
        \\{
        \\  ports: [
        \\    1,
        \\    2,
        \\  ],
        \\}
    );
    defer ed.deinit();
    try ed.removeSeqItem(&.{.{ .key = "ports" }}, std.math.maxInt(usize));
    try expectJson5Source(&ed,
        \\{
        \\  ports: [
        \\    1,
        \\  ],
        \\}
    );
}
