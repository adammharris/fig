const std = @import("std");

const Document = @import("document.zig");
const Span = @import("util/span.zig");
const json = @import("json/json.zig");
const JsonParser = @import("json/parser.zig").Parser;

pub const JsonLanguage = struct {
  pub const Parser = JsonParser;
  pub const Format = json.JsonFormat;
  pub const default_format: Format = .JSON;

  pub fn parse(parser: *Parser, input: []const u8, format: Format) !Document {
    return parser.parse(input, format);
  }
};

pub const JsonEditor = Editor(JsonLanguage);

pub fn Editor(comptime Language: type) type {
  return struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    source: std.ArrayList(u8) = .empty,
    document: ?Document = null,
    format: Language.Format = Language.default_format,

    pub fn init(self: *Self, input: []const u8) !void {
      if (self.source.items.len != 0 or self.document != null) return error.MultipleInit;
      try self.source.appendSlice(self.allocator, input);
      self.document = try self.parseSource();
    }

    /// Replace a span with a new span. Keeps self.document valid if parsing succeeds.
    pub fn replaceNode(self: *Self, span: Span, text: []const u8) !void {
      try self.replaceSource(span, text);
      try self.reparse();
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
      var parser: Language.Parser = .{ .allocator = self.allocator };
      defer parser.deinit();
      return Language.parse(&parser, self.source.items, self.format);
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

fn testEditor(input: []const u8, span: Span, text: []const u8, expected: []const u8) !void {
  var editor: JsonEditor = .{ .allocator = std.testing.allocator };
  try editor.init(input);
  defer editor.deinit();
  try editor.replaceNode(span, text);
  try std.testing.expect(std.mem.eql(u8, expected, editor.document.?.source));
}

test "simple edit" {
  try testEditor(
    "[{\"hello\":\"world\"}]",
    .{ .start = 11, .end = 16 },
    "person!",
    "[{\"hello\":\"person!\"}]",
  );
}
