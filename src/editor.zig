//! Editor module, generic over Language.

const std = @import("std");

const AST = @import("ast.zig");
const Document = @import("document.zig");
const Span = @import("util/span.zig");
const json = @import("json/json.zig");
const log = std.log.scoped(.editor);

pub fn Editor(comptime Language: type) type {
    @import("language.zig").validate(Language);
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        source: std.ArrayList(u8) = .empty,
        document: ?Document = null,
        format: Language.Type = Language.default_type,

        fn getParsed(self: *const Self) !Document {
            return self.document orelse {
                log.err("Not initialized!", .{});
                return error.NotInitialized;
            };
        }

        pub fn init(self: *Self, input: []const u8) !void {
            if (self.source.items.len != 0 or self.document != null) return error.MultipleInit;
            try self.source.appendSlice(self.allocator, input);
            self.document = try self.parseSource();
        }

        /// Replace a span with a new span. Keeps self.parsed valid if parsing succeeds.
        pub fn replaceAtSpan(self: *Self, span: Span, replacement: []const u8) !void {
            try self.replaceSource(span, replacement);
            try self.reparse();
        }

        pub fn replaceValAtPath(self: *Self, path: []const AST.PathSegment, replacement: []const u8) !void {
            const parsed = try self.getParsed();
            const node = try parsed.document.getValByPath(path);
            const span = parsed.span(node);
            try self.replaceAtSpan(span, replacement);
        }

        pub fn replaceKeyAtPath(self: *Self, path: []const AST.PathSegment, replacement: []const u8) !void {
            const parsed = try self.getParsed();
            const node = try parsed.document.getKeyByPath(path);
            const span = parsed.span(node);
            try self.replaceAtSpan(span, replacement);
        }

        /// Replace a span of bytes with a new span of bytes.
        /// Not aware of self.format. Invalidates self.parsed until reparsed.
        fn replaceSource(self: *Self, old_span: Span, text: []const u8) !void {
            if (old_span.end < old_span.start or old_span.end > self.source.items.len) {
                return error.InvalidSpan;
            }
            try self.source.replaceRange(self.allocator, old_span.start, old_span.len(), text);
        }

        /// After an edit, restores self.parsed so node spans are valid again.
        fn reparse(self: *Self) !void {
            const parsed = try self.parseSource();
            self.freeDocument();
            self.document = parsed;
        }

        fn parseSource(self: *Self) !Document {
            var parser: Language.Parser = .{ .allocator = self.allocator };
            return Language.parse(&parser, self.source.items, self.format);
        }

        fn freeDocument(self: *Self) void {
            if (self.document) |parsed| {
                parsed.deinit(self.allocator);
                self.document = null;
            }
        }

        pub fn deinit(self: *Self) void {
            self.freeDocument();
            self.source.deinit(self.allocator);
        }
    };
}

// =======
// TESTING
// =======

fn testEditor(input: []const u8, path: []const AST.PathSegment, key_or_val: enum { key, val }, text: []const u8, expected: []const u8) !void {
    var editor: Editor(json.Language) = .{ .allocator = std.testing.allocator };
    try editor.init(input);
    defer editor.deinit();
    switch (key_or_val) {
        .key => try editor.replaceKeyAtPath(path, text),
        .val => try editor.replaceValAtPath(path, text),
    }
    const actual = editor.source.items;
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
