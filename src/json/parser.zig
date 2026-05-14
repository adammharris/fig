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
  const OpenContainer = struct {
    id: Document.Node.Id,
    kind: enum { array, object },
    first_child: ?Document.Node.Id = null,
    last_child: ?Document.Node.Id = null,
    pending_key: ?Document.Node.Id = null,
  };


  // State
  state: State = .ExpectValue,
  nodes: std.ArrayList(Document.Node) = .empty,
  container_stack: std.ArrayList(OpenContainer) = .empty,

  // Initial fields
  allocator: std.mem.Allocator,

  const ParseError = error{
    UnclosedObject,
    UnclosedArray,
    UnclosedString,

    InvalidBool,
    InvalidNumber,
    UnexpectedToken
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
      if (char == '"' and index != 0 and index != 1) {
        // OK if they are escaped.
        if (json[index - 1] == '\\' and json[index - 2] != '\\') continue;
        // If not escaped, json is invalid.
        break;
      }
      // String needs to end with a double quote
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
          // TODO: update state
          switch (token.kind) {
            .open_brace => {
              self.addNode(.mapping, token.span);
              self.state = .ExpectObjectKeyOrEnd;
            },
            .open_bracket => {
              self.addNode(.sequence, token.span);
              self.state = .ExpectArrayValueOrEnd;
            },
            .null_ => {
              self.addNode(.null_, token.span);
              self.state = self.nextStateAfterValue();
            },
            .true_, .false_ => {
              self.addNode(.boolean, token.span);
              self.state = self.nextStateAfterValue();
            },
            .string => {
              self.addNode(.string, token.span);
              self.state = self.nextStateAfterValue();
            },
            .number => {
              self.addNumber(.number, token.span);
              self.state = self.nextStateAfterValue();
            },
            else => return ParseError.UnexpectedToken,
          }
        },

        .ExpectArrayValueOrEnd => {
          switch (token.kind) {
            //.open_brace => self.addNode(.mapping, token.span),
            .open_bracket => self.addNode(.sequence, token.span),
            .null_ => {
              self.addNode(.null_, token.span);
              self.state = .ExpectArrayCommaOrEnd;
            },
            .true_, .false_ => {
              self.addNode(.boolean, token.span);
              self.state = .ExpectArrayCommaOrEnd;
            },
            .string => {
              self.addNode(.string, token.span);
              self.state = .ExpectArrayCommaOrEnd;
            },
            .number => {
              self.addNumber(.number, token.span);
              self.state = .ExpectArrayCommaOrEnd;
            },
            .close_bracket => {
              // TODO: update span of node
            },
            else => return ParseError.UnexpectedToken,
          }
        },
        .ExpectArrayCommaOrEnd => {
          switch (token.kind) {
            .close_bracket => {
              // TODO: update span of beginning token
              // TODO: check stack to know what state is next
            },
            .comma => {
              self.state = .ExpectValue;
            },
            else => return ParseError.UnexpectedToken
          }
        },

        .ExpectObjectKeyOrEnd => {
          .string => {
            const id = try self.addNode(.string, token.span);
            try self.finishValue(id);
          },
          .close_brace => self.addNode(.mapping, token.span),
          else => return ParseError.UnexpectedToken
        },
        .ExpectObjectColon => {
          switch (token.kind) {
            .colon => {
              // TODO: change state to ExpectObjectValue
            },
            else => return ParseError.UnexpectedToken
          }
        },
        .ExpectObjectValue => {
          switch (token.kind) {
            .open_brace => {
              self.addNode(.{.mapping = null}, token.span);
              self.state = .ExpectObjectKeyOrEnd;
            },
            .open_bracket => {
              self.addNode(.sequence, token.span);
              self.state = .ExpectArrayValueOrEnd;
            },
            .null_ => {
              self.addNode(.null_, token.span);
              self.state = .ExpectObjectCommaOrEnd;
            },
            .true_, .false_ => {
              self.addNode(.boolean, token.span);
              self.state = .ExpectObjectCommaOrEnd;
            },
            .string => {
              self.addNode(.string, token.span);
              self.state = .ExpectObjectCommaOrEnd;
            },
            .number => {
              self.addNumber(.number, token.span);
              self.state = .ExpectObjectCommaOrEnd;
            }
            else => return ParseError.UnexpectedToken,
          }
        },
        .ExpectObjectCommaOrEnd => {
          switch (token.kind) {
            .close_brace => {
              // TODO: update span of beginning token
              // TODO: check stack to know what state is next
            },
            .comma => {
              self.state = .ExpectObjectKeyOrEnd; // TODO: allow trailing comma?
            },
            else => return ParseError.UnexpectedToken
          }
        },

        .ExpectEndOfFile => {
          // TODO: end
        },
      }

    }
  }

  pub fn deinit(self: *Parser) void {
    self.allocator.free(self.nodes);
  }

  // ===============
  // PARSING HELPERS
  // ===============

  /// Add an incomplete node to self.nodes. Called as soon as `[` or `{` is found.
  fn addNode(self: *Parser, kind: Document.Node.Kind, span: Span) !Document.Node.Id {
    const id: Document.Node.Id = @intCast(self.nodes.items.len);
    try self.nodes.append(self.allocator, .{
      .id = id,
      .kind = kind,
      .span = span, // Update when you find the closing token
      .next_sibling = null, // Update if there is a next sibling
    });
    return id;
  }

  /// Attaches a completed child to the current open container.
  fn attachChild(self: *Parser, child_id: Document.Node.Id) !void {
    // TODO: attach directly if array, attach completed keyvalues if object
  }

  fn nextStateAfterValue(self: *Parser) ParseState {
    if (self.frames.items.len == 0) {
      return .ExpectEndOfFile;
    },

    return switch (self.frames.items[self.frames.items.len - 1]) {
      .array => .ExpectArrayCommaOrEnd,
      .object => .ExpectObjectCommaOrEnd,
    },
  }

  fn finishValue(self: *Parser, value_id: Document.Node.Id) !void {
    // If there is no parent, the parsing is complete
    if (self.container_stack.items.len == 0) {
      self.root = value_id;
      self.state = .ExpectEndOfFile;
      return;
    }

    const parent = &self.container_stack.items[self.container_stack.items.len - 1];

    switch (parent.kind) {
      .array => {
        try self.attachChildToOpenContainer(parent, value_id);
        self.state = .ExpectArrayCommaOrEnd;
      },
      .object => {
        const key_id = parent.pending_key orelse return ParseError.UnexpectedToken;
        parent.pending_key = null;

        const key_span = self.nodes.items[key_id].span;
        const value_span = self.nodes.items[value_id].span;

        const pair_id = try self.addNode(.{ .keyvalue = .{
            .key = key_id,
            .value = value_id,
        } }, .{
            .start = key_span.start,
            .end = value_span.end,
        });

        try self.attachChildToOpenContainer(parent, pair_id);
        self.state = .ExpectObjectCommaOrEnd;
      },
    }
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
          .kind = .string,
          .span = .{ .start = 2, .end = 9 },
          .next_sibling = null,
        },
        .{
          .id = 4,
          .kind = .string,
          .span = .{ .start = 10, .end = 17 },
          .next_sibling = null,
        }
      }
    }
  );
}