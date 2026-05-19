//! The parser turns JSON tokens into a concrete syntax tree.
//! Depends on the tokenizer and the abstract Document struct

const std = @import("std");
const Document = @import("../document.zig");
const testing = std.testing;
const log = std.log.scoped(.parser);
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Type = @import("json.zig").Language.Type;
const Span = @import("../util/span.zig");

const Parser = @This();

const ContainerKind = enum { array, object };
/// Either an array or object in the process of being parsed.
const OpenContainer = struct {
  id: Document.Node.Id,
  kind: ContainerKind,
  first_child: ?Document.Node.Id = null,
  last_child: ?Document.Node.Id = null,
  pending_key: ?Document.Node.Id = null,
};


// State
state: State = .ExpectValue,
nodes: std.ArrayList(Document.Node) = .empty,
container_stack: std.ArrayList(OpenContainer) = .empty,

root: ?Document.Node.Id = null,

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
pub fn getBool(slice: []const u8) ParseError!bool {
  if (std.mem.eql(slice, "true")) return true;
  if (std.mem.eql(slice, "false")) return false;
  log.err("Tried to parse invalid value as boolean: `{s}`", .{slice});
  return .InvalidBool;
}

/// Simply removes double quotes from a JSON string.
pub fn getString(slice: []const u8) ParseError![]const u8 {
  // Loop through string.
  var isValid = false;
  for (slice, 0..) |char, index| {
    // If string doesn't start with a double quote, it is invalid.
    if (index == 0 and char != '"') break;
    // Check if any middle characters are double quotes.
    if (char == '"' and index != 0 and index != 1) {
      // OK if they are escaped.
      if (slice[index - 1] == '\\' and slice[index - 2] != '\\') continue;
      // If not escaped, json is invalid.
      break;
    }
    // String needs to end with a double quote
    if (index == slice.len - 1 and slice[index] == '"') isValid = true;
  }
  if (isValid) return slice[1..slice.len - 1];
  log.err("Tried to parse invalid value as string: `{s}`", .{slice});
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
pub fn getNumber(slice: []const u8) ParseError!Number {
  var numDots = 0;
  for (slice) |char| {
    if (char == '.') numDots += 1;
  }
  return .{
    .raw = slice,
    .kind = switch (numDots) {
      0 => .Integer,
      1 => .Float,
      else => return .InvalidNumber
    }
  };
}

pub fn parse(allocator: std.mem.Allocator, input: []const u8, format: Type) !Document {
  var parser: Parser = .{ .allocator = allocator };
  defer parser.deinit();
  return parser.parse_once(input, format);
}

fn parse_once(self: *Parser, input: []const u8, kind: Type) !Document {
  // A document needs format, slice of nodes, root node ID, and source text.
  const source = input;

  var tokenizer: Tokenizer = .{
    .allocator = self.allocator,
    .str = input,
    .kind = kind,
  };

  const tokens = try tokenizer.tokenize();
  defer self.allocator.free(tokens);

  // Each Document.Node has an id, a kind, a span, and a next_sibling ID.
  // We produce them from the tokens.

  //TODO: parse tokens
  for (tokens) |token| {
    if (token.kind == .whitespace) continue;
    if (token.kind == .comment) continue;

    switch (self.state) {
      .ExpectValue => {
        // TODO: update state
        switch (token.kind) {
          .open_brace => {
            const id = try self.addNode(.{ .mapping = null}, token.span);
            try self.openContainer(.object, id);
            self.state = .ExpectObjectKeyOrEnd;
          },
          .open_bracket => {
            const id = try self.addNode(.{ .sequence = null}, token.span);
            try self.openContainer(.array, id);
            self.state = .ExpectArrayValueOrEnd;
          },
          .null_ => {
            const id = try self.addNode(.null_, token.span);
            try self.finishValue(id);
          },
          .true_, .false_ => {
            const id = try self.addNode(.boolean, token.span);
            try self.finishValue(id);
          },
          .string => {
            const id = try self.addNode(.string, token.span);
            try self.finishValue(id);
          },
          .number => {
            const id = try self.addNode(.number, token.span);
            try self.finishValue(id);
          },
          else => return ParseError.UnexpectedToken,
        }
      },

      .ExpectArrayValueOrEnd => {
        switch (token.kind) {
          .open_bracket => {
            const id = try self.addNode(.{ .sequence = null}, token.span);
            try self.openContainer(.array, id);
            self.state = .ExpectArrayValueOrEnd;
          },
          .open_brace => {
            const id = try self.addNode(.{ .mapping = null }, token.span);
            try self.openContainer(.object, id);
            self.state = .ExpectObjectKeyOrEnd;
          },
          .null_ => {
            const id = try self.addNode(.null_, token.span);
            try self.finishValue(id);
          },
          .true_, .false_ => {
            const id = try self.addNode(.boolean, token.span);
            try self.finishValue(id);
          },
          .string => {
            const id = try self.addNode(.string, token.span);
            try self.finishValue(id);
          },
          .number => {
            const id = try self.addNode(.number, token.span);
            try self.finishValue(id);
          },
          .close_bracket => {
            const id = try self.closeContainer(token.span.end);
            try self.finishValue(id);
          },
          else => return ParseError.UnexpectedToken,
        }
      },
      .ExpectArrayCommaOrEnd => {
        switch (token.kind) {
          .close_bracket => {
            const id = try self.closeContainer(token.span.end);
            try self.finishValue(id);
          },
          .comma => {
            self.state = .ExpectValue;
          },
          else => return ParseError.UnexpectedToken,
        }
      },

      .ExpectObjectKeyOrEnd => {
        switch (token.kind) {
          .string => {
            const key_id = try self.addNode(.string, token.span);
            const parent = &self.container_stack.items[self.container_stack.items.len - 1];
            parent.pending_key = key_id;
            self.state = .ExpectObjectColon;
          },
          .close_brace => {
            const id = try self.closeContainer(token.span.end);
            try self.finishValue(id);
          },
          else => return ParseError.UnexpectedToken,
        }
      },
      .ExpectObjectColon => {
        switch (token.kind) {
          .colon => {
            self.state = .ExpectObjectValue;
          },
          else => return ParseError.UnexpectedToken,
        }
      },
      .ExpectObjectValue => {
        switch (token.kind) {
          .open_brace => {
            const id = try self.addNode(.{ .mapping = null}, token.span);
            try self.openContainer(.object, id);
            self.state = .ExpectObjectKeyOrEnd;
          },
          .open_bracket => {
            const id = try self.addNode(.{ .sequence = null}, token.span);
            try self.openContainer(.array, id);
            self.state = .ExpectArrayValueOrEnd;
          },
          .null_ => {
            const id = try self.addNode(.null_, token.span);
            try self.finishValue(id);
          },
          .true_, .false_ => {
            const id = try self.addNode(.boolean, token.span);
            try self.finishValue(id);
          },
          .string => {
            const id = try self.addNode(.string, token.span);
            try self.finishValue(id);
          },
          .number => {
            const id = try self.addNode(.number, token.span);
            try self.finishValue(id);
          },
          else => return ParseError.UnexpectedToken,
        }
      },
      .ExpectObjectCommaOrEnd => {
        switch (token.kind) {
          .close_brace => {
            const id = try self.closeContainer(token.span.end);
            try self.finishValue(id);
          },
          .comma => {
            self.state = .ExpectObjectKeyOrEnd; // TODO: allow trailing comma?
          },
          else => return ParseError.UnexpectedToken
        }
      },

      .ExpectEndOfFile => {
        switch (token.kind) {
          .end_of_file => continue,
          else => return ParseError.UnexpectedToken,
        }
      },
    }

  }

  // while loop completed.
  // Ready to return a Document!
  const nodes = try self.nodes.toOwnedSlice(self.allocator);
  self.nodes = .empty;
  return .{
    .source = source,
    .root = nodes[0].id,
    .nodes = nodes,
  };
}

pub fn deinit(self: *Parser) void {
  self.container_stack.deinit(self.allocator);
  self.nodes.deinit(self.allocator);
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
fn attachChild(self: *Parser, parent: *OpenContainer, child_id: Document.Node.Id) void {
  if (parent.first_child != null) {
    self.nodes.items[parent.last_child.?].next_sibling = child_id;
  } else {
    parent.first_child = child_id;
    switch (parent.kind) {
      .array => self.nodes.items[parent.id].kind = .{ .sequence = child_id },
      .object => self.nodes.items[parent.id].kind = .{ .mapping = child_id },
    }
  }
  parent.last_child = child_id;
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
      self.attachChild(parent, value_id);
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

      self.attachChild(parent, pair_id);
      self.state = .ExpectObjectCommaOrEnd;
    },
  }
}

/// Pushes stack metadata for a container node that already exists in self.nodes
fn openContainer(self: *Parser, kind: ContainerKind, node_id: Document.Node.Id) !void {
  try self.container_stack.append(self.allocator, .{
    .id = node_id,
    .kind = kind,
  });
}

/// Pops the current container, patches its node span end, and returns the node ID
fn closeContainer(self: *Parser, span_end: usize) !Document.Node.Id {
  if (self.container_stack.items.len == 0) return ParseError.UnexpectedToken;
  const container = self.container_stack.pop().?;
  self.nodes.items[container.id].span.end = span_end;
  return container.id;
}

// =======
// Testing
// =======

fn testParser(input: []const u8, expected: Document) !void {
  const doc = try Parser.parse(testing.allocator, input, .JSON);
  defer doc.deinit(testing.allocator);
  try testing.expect(expected.equals(doc));
}


test "simple JSON document" {
  try testParser(
    \\[{"hello":"world"}]
    , .{
      .root = 0,
      .source = \\[{"hello":"world"}]
      , .nodes = &[_]Document.Node{
        .{
          .id = 0,
          .kind = .{ .sequence = 1 },
          .span = .{ .start = 0, .end = 19 },
          .next_sibling = null
        },
        .{
          .id = 1,
          .kind = .{ .mapping = 4 },
          .span = .{ .start = 1, .end = 18 },
          .next_sibling = null,
        },
        .{
          .id = 2,
          .kind = .string,
          .span = .{ .start = 2, .end = 9 },
          .next_sibling = null,
        },
        .{
          .id = 3,
          .kind = .string,
          .span = .{ .start = 10, .end = 17 },
          .next_sibling = null,
        },
        .{
          .id = 4,
          .kind = .{ .keyvalue = .{ .key = 2, .value = 3} },
          .span = .{ .start = 2, .end = 17 },
          .next_sibling = null,
        },
      }
    }
  );
}