//! Editor module, generic over Language.
//! TODO: make API accessible via object notation instead of spans

const std = @import("std");

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

    fn getDoc(self: *const Self) !Document {
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

    /// Replace a span with a new span. Keeps self.document valid if parsing succeeds.
    pub fn replaceAtSpan(self: *Self, span: Span, replacement: []const u8) !void {
      try self.replaceSource(span, replacement);
      try self.reparse();
    }

    pub fn replaceValAtPath(self: *Self, path: []const Document.PathSegment, replacement: []const u8) !void {
      const doc = try self.getDoc();
      const span = (try doc.getNodeVal(path)).span;
      try self.replaceAtSpan(span, replacement);
    }

    pub fn replaceKeyAtPath(self: *Self, path: []const Document.PathSegment, replacement: []const u8) !void {
      const doc = try self.getDoc();
      const span = (try doc.getNodeKey(path)).span;
      try self.replaceAtSpan(span, replacement);
    }

    /// Replace a span of bytes with a new span of bytes.
    /// Not aware of self.document.format. Invalidates self.document until reparsed.
    fn replaceSource(self: *Self, old_span: Span, text: []const u8) !void {
      if (old_span.end < old_span.start or old_span.end > self.source.items.len) {
        return error.InvalidSpan;
      }
      try self.source.replaceRange(self.allocator, old_span.start, old_span.len(), text);
    }

    /// After an edit, restores self.document so node spans are valid again.
    fn reparse(self: *Self) !void {
      const doc = try self.parseSource();
      self.freeDocument();
      self.document = doc;
    }

    fn parseSource(self: *Self) !Document {
      return Language.Parser.parse(self.allocator, self.source.items, self.format);
    }

    fn freeDocument(self: *Self) void {
      if (self.document) |doc| {
        self.allocator.free(doc.nodes);
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

fn testEditor(input: []const u8, path: []const Document.PathSegment, text: []const u8, expected: []const u8, key_or_val: enum { key, val }) !void {
  var editor: Editor(json.Language) = .{ .allocator = std.testing.allocator };
  try editor.init(input);
  defer editor.deinit();
  switch (key_or_val) {
    .key => try editor.replaceKeyAtPath(path, text),
    .val => try editor.replaceValAtPath(path, text),
  }
  const actual = editor.document.?.source;
  errdefer log.err("actual: {s}", .{actual});
  errdefer log.err("expected: {s}", .{expected});
  try std.testing.expect(std.mem.eql(u8, expected, actual));
}

test "simple value edit" {
  try testEditor(
    "[{\"hello\":\"world\"}]",
    &[_]Document.PathSegment{ .{ .index = 0 }, .{ .key = "\"hello\""} },
    "\"person!\"",
    "[{\"hello\":\"person!\"}]",
    .val
  );
}

test "simple key edit" {
  try testEditor(
    "[{\"hello\":\"world\"}]",
    &[_]Document.PathSegment{ .{ .index = 0 }, .{ .key = "\"hello\""} },
    "\"greetings\"",
    "[{\"greetings\":\"world\"}]",
    .key
  );
}
