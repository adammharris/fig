//! Editor tests for the JSON family (`Editor(json.Language)`) — both the generic
//! span-splice engine (plain JSON) and the JSON5 dialect.
//!
//! Like `toml/` and `yaml/editor_helper.zig`, each language's editor tests live
//! next to that language's concerns rather than in `editor.zig`. JSON needs no
//! format-specific editing logic (it routes straight through the generic engine),
//! so this module is tests only — they double as the engine's own smoke tests.

const std = @import("std");

const AST = @import("../ast/ast.zig");
const editor = @import("../editor.zig");
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
