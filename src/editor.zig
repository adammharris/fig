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

    pub fn replaceAtPath(self: *Self, path: []const Document.PathSegment, replacement: []const u8) !void {
      if (self.document) |doc| {
        const span = (try doc.getNode(path)).span;
        try self.replaceAtSpan(span, replacement);
      } else {
        log.err("Not initialized!", .{});
        return error.NotInitialized;
      }
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

fn testEditor(input: []const u8, path: []const Document.PathSegment, text: []const u8, expected: []const u8) !void {
  var editor: Editor(json.Language) = .{ .allocator = std.testing.allocator };
  try editor.init(input);
  defer editor.deinit();
  try editor.replaceAtPath(path, text);
  try std.testing.expect(std.mem.eql(u8, expected, editor.document.?.source));
}

test "simple edit" {
  try testEditor(
    "[{\"hello\":\"world\"}]",
    &[_]Document.PathSegment{ .{ .index = 0 }, .{ .field = "\"hello\""} },
    "\"person!\"",
    "[{\"hello\":\"person!\"}]",
  );
}
