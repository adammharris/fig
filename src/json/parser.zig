//! The parser turns JSON tokens into a concrete syntax tree.
//! Depends on the tokenizer and the abstract Document struct

const std = @import("std");
const Document = @import("../document.zig");
const testing = std.testing;
const log = std.log.scoped(.parser);
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const JsonFormat = @import("json.zig");

// TODO: This file is WIP and does not yet compile
//



const Parser = struct {
  /// Either an array or object in the process of being parsed.
  const Frame = union(enum) {
    array: std.ArrayList(Document.Node),
    object: struct {
      map: std.StringHashMap(Document.Node),
      pending_key: ?[]const u8 = null,
    },
  };

  // State
  state: State = .ExpectValue,
  nodes: std.ArrayList(Document.Node) = .empty,
  in_progress_stack: std.ArrayList(Frame) = .empty,

  // Initial fields
  allocator: std.mem.Allocator,

  const ParseError = error{
    UnclosedObject,
    UnclosedArray,
    UnclosedString,

    InvalidBool,
    InvalidNumber,
  };

  const State = enum {
    ExpectValue,

    ExpectArrayValueOrEnd,
    ExpectArrayCommaOrEnd,

    ExpectObjectKeyOrEnd,
    ExpectObjectColon,
    ExpectObjectValue,
    ExpectObjectCommaOrEnd,

    ExpectEndOfFile,
  };

  /// Expects "true" or "false", translates to boolean
  pub fn getBool(json: []const u8) ParseError!bool {
    if (std.mem.eql(json, "true")) return true;
    if (std.mem.eql(json, "false")) return false;
    log.err("Tried to parse invalid value as boolean: `{s}`", .{json});
    return .InvalidBool;
  }

  /// Simply removes double quotes from a JSON string.
  pub fn getString(json: []const u8) ParseError![]const u8 {
    // Loop through string.
    var isValid = false;
    for (json, 0..) |char, index| {
      // If string doesn't start with a double quote, it is invalid.
      if (index == 0 and char != '"') break;
      // Check if any middle characters are double quotes.
      if (char == '"') {
        // OK if they are escaped.
        if (json[index - 1] == '\\' and json[index - 2] != '\\') continue;
        // If not escaped, json is invalid.
        break;
      }
      // If string ends with a double quote, it is invalid.
      if (index == json.len - 1 and json[index] == '"') isValid = true;
    }
    if (isValid) return json[1..json.len - 1];
    log.err("Tried to parse invalid value as string: `{s}`", .{json});
    return .UnclosedString;
  }

  const Number = struct {
    raw: []const u8,
    kind: Kind,
    pub const Kind = enum { Integer, Float };

    pub fn parseInt(self: Number, comptime T: type) !T {
      return std.fmt.parseInt(T, self.raw, 10);
    }
    pub fn parseFloat(self: Number, comptime T: type) !T {
      return std.fmt.parseFloat(T, self.raw);
    }
  };

  /// Returns lossless struct representation of a number
  pub fn getNumber(json: []const u8) ParseError!Number {
    var numDots = 0;
    for (json) |char| {
      if (char == '.') numDots += 1;
    }
    return .{
      .raw = json,
      .kind = switch (numDots) {
        0 => .Integer,
        1 => .Float,
        else => return .InvalidNumber
      }
    };
  }

  pub fn parse(self: *Parser, input: []const u8, kind: JsonFormat) ParseError!Document {
    // A document needs format, slice of nodes, root node ID, and source text.
    // const source = input;
    // const format = Document.Format(kind);

    var tokenizer: Tokenizer = .{
      .allocator = self.allocator,
      .str = input,
      .kind = kind,
    };

    const tokens = tokenizer.tokenize();
    defer self.allocator.free(tokens);

    var iterator = tokens.iterator();

    // Each Document.Node has an id, a kind, a span, and a next_sibling ID.
    // We produce them from the tokens.

    //TODO: parse tokens
    while (iterator.next()) |token| {
      if (token.kind == .whitespace) continue;
      if (token.kind == .comment) continue;

      switch (self.state) {
        .ExpectValue => {
          //const value = try self.consumeValueOrOpenContainer();
        },

        .ExpectArrayValueOrEnd => {},
        .ExpectArrayCommaOrEnd => {},

        .ExpectObjectKeyOrEnd => {},
        .ExpectObjectColon => {},
        .ExpectObjectValue => {},
        .ExpectObjectCommaOrEnd => {},

        .ExpectEndOfFile => {},
      }

      break;
    }
  }

  pub fn deinit(self: *Parser) void {
    self.allocator.free(self.nodes);
  }

  // ===============
  // PARSING HELPERS
  // ===============

  fn consumeValueOrOpenContainer(self: *Parser) !?Document.Node {
    // TODO
  }


  fn finishNode(self: *Parser ) !void {
    // If there are no more items, it is the final root value.
    if (self.frames.items.len == 0) {
      //self.result = value;
      return;
    }

    switch (&self.frames.items[self.frames.items.len - 1]) {
      // If parent is an array, append to the parent array.
      .array => |*array| {
        //try array.append(self.allocator, value);
      },
      // If parent is an object, append to the object.
      .object => |*object| {
        const key = object.pending_key orelse return error.MissingObjectKey;
        object.pending_key = null;
        //try object.map.put(key, value);
      },
    }

    fn nextStateAfterValue(self: *Parser) ParseState {
      if (self.frames.items.len == 0) return .ExpectEndOfFile;

      return switch (self.frames.items[self.frames.items.len - 1]) {
        .array => .ExpectArrayCommaOrEnd,
        .object => .ExpectObjectCommaOrEnd,
      };
    }

  }


};

// =======
// Testing
// =======

fn testParser(input: []const u8, expected: Document) !void {
  var parser: Parser = .{ .allocator = testing.allocator, };
  const doc = try parser.parse(input, .JSON);
  defer parser.deinit();
  try testing.expectEqualDocument(expected, doc);
}

fn expectEqualDocument(expected: Document, actual: Document) !void {
  try testing.expectEqual(expected.format, actual.format);
  try testing.expectEqual(expected.root, actual.root);
  try testing.expectEqualStrings(expected.source, actual.source);
  try testing.expectEqual(expected.nodes.len, actual.nodes.len);

  for (expected.nodes, actual.nodes, 0..) |expected_node, actual_node, i| {
    errdefer std.log.err("node {d}: expected {any}, actual {any}", .{
      i, expected_node, actual_node,
    });
    try testing.expectEqual(expected_node, actual_node);
  }
}


test "simple JSON document" {
  try testParser(
    \\[{"hello":"world"}]
    , .{
      .format = .{ .json = .JSON },
      .root = 0,
      .source = \\[{"hello":"world"}]
      , .nodes = [_]Document.Node {
        .{
          .id = 0,
          .kind = .sequence(.Id(1)),
          .span = .{ .start = 0, .end = 19 },
          .next_sibling = null
        },
        .{
          .id = 1,
          .kind = .mapping(.Id(2)),
          .span = .{ .start = 1, .end = 18 },
          .next_sibling = null,
        },
        .{
          .id = 2,
          .kind = .keyvalue(.{ .key = 3, .value = 4}),
          .span = .{ .start = 2, .end = 17 },
          .next_sibling = null,
        },
        .{
          .id = 3,
          .kind = .string("hello"),
          .span = .{ .start = 2, .end = 9 },
          .next_sibling = null,
        },
        .{
          .id = 4,
          .kind = .string("world"),
          .span = .{ .start = 10, .end = 17 },
          .next_sibling = null,
        }
      }
    }
  );
}