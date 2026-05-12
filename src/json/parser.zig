const std = @import("std");
const Document = @import("../document.zig");

// TODO: This file is WIP and does not yet compile

const ValueNode = struct {
    value: Value,
    token_start: usize,
    token_end: usize,
};

const Parser = struct {
  const Frame = union(enum) {
    array: struct {
      values: std.ArrayList(Value),
    },
    object: struct {
      map: std.StringHashMap(Value),
      pending_key: ?[]const u8,
    },
  };

  // State
  state: ParseState = .ExpectValue,
  frames: std.ArrayList(Frame) = .empty,
  result: ?Document = null,

  // Initial fields
  allocator: std.mem.Allocator,

  const ParseError = error{
    UnclosedObject,
    UnclosedArray,
    UnclosedString
  };

  const ParseState = enum {
    ExpectValue,
    ExpectArray,
    ExpectEndOfFile,
  };

  pub fn parse(self: *Parser, input: []const u8, kind: JsonKind) ParseError!Document {
    var tokenizer: Tokenizer = .{
      .allocator = self.allocator,
      .str = input,
      .kind = kind,
    };
    const tokens: []AbstractToken = try tokenizer.abstractTokenize();
    defer self.allocator.free(tokens);

    var iterator = tokens.iterator();

    //TODO: parse tokens
    while (iterator.next()) |token| {
      //TODO:
      switch (token) {
        .whitespace => continue,
        else => {}
      }

      switch (self.state) {
        .ExpectValue => {},
        .ExpectArray => {},
        .ExpectEndOfFile => {},
      }
      break;
    }
  }

  fn finishValue(self: *Parser, value: Value) !void {
    // If there are no more frames, it is the final root value.
    if (self.frames.items.len == 0) {
      self.result = value;
      return;
    }
    // If there is a parent frame...
    switch (&self.frames.items[self.frames.items.len - 1]) {
      .array => |*array| {
        // Append to array frame.
        try array.append(self.allocator, value);
      },
      .object => |*object| {
        // Or insert into object frame with pending_key
        const key = object.pending_key orelse return error.MissingObjectKey;
        object.pending_key = null;
        try object.map.put(key, value);
      },
    }
  }

};

// =======
// Testing
// =======

fn testParser(input: []const u8, expected: []const JsonToken) !void {
  var parser: Parser = .{ .allocator = testing.allocator, };
  const doc = try parser.parse();
  defer testing.allocator.free(tokens);
  errdefer log.err("expected: {any}", .{expected});
  errdefer log.err("actual: {any}", .{tokens});
  try testing.expectEqual(expected.len, tokens.len);
  for (expected, tokens) |expected_token, actual_token| {
    try expectEqualToken(expected_token, actual_token);
  }
}