//! The universal document representation.
//! Lower-level modules such as json/parser.zig depend on this,
//! taking in a string and returning a Document.

const Document = @This();
const std = @import("std");
const Span = @import("util/span.zig");

pub const Node = struct {
  pub const Id = u32;
  pub const Kind = union(enum) {
    // TODO: trivia,
    null_,
    boolean,
    string,
    number,
    sequence: ?Id,
    mapping: ?Id,
    keyvalue: struct { key: Id, value: Id },
    pub fn equals(self: Kind, other: Kind) bool {
      return switch (self) {
        .keyvalue => |value, tag| {
          return tag == std.meta.activeTag(other)
            and value.key == other.keyvalue.key
            and value.value == other.keyvalue.value;
        },
        inline else => |value, tag| {
          return tag == std.meta.activeTag(other)
            and value == @field(other, @tagName(tag));
        },
      };
    }
  };

  /// IDs are arbitrary, but should be deterministic.
  id: Id,
  kind: Kind,
  /// Refers to string slice in Document.source
  span: Span,

  /// Indicates "next" value when inside a sequence/mapping.
  /// Null indicates that this is the last node in the sequence/mapping.
  next_sibling: ?Id = null,
  pub fn equals(self: Node, other: Node) bool {
    if (self.id != other.id) return false;
    if (!self.span.equals(other.span)) return false;
    if (self.next_sibling != other.next_sibling) return false;
    if (!self.kind.equals(other.kind)) return false;
    return true;
  }
};

root: Node.Id,
nodes: []const Node,
source: []const u8,

/// function to tell if two documents are equal
pub fn equals(self: Document, b: Document) bool {
  if (self.root != b.root) return false;
  //if (!std.mem.eql(u8, self.source, b.source)) return false;
  if (self.nodes.len != b.nodes.len) return false;

  for (self.nodes, b.nodes) |na, nb| {
    if (!na.equals(nb)) return false;
  }
  return true;
}

pub fn deinit(self: Document, allocator: std.mem.Allocator) void {
  allocator.free(self.nodes);
}

// Document Path Helpers

/// Represents part of a path in the Document structure.
/// Elements can only be nested in either mappings or
pub const PathSegment = union(enum) {
  field: []const u8,
  index: usize,
};

// Used like:
// &[_]Document.PathSegment{
//   .{ .index = 0 },
//   .{ .field = "hello" }
// }

pub fn getNode(self: *const Document, path: []const PathSegment) !Node {
  return self.nodes[try self.getId(path)];
}

fn getId(self: *const Document, path: []const PathSegment) !Node.Id {
  var current_node = self.root;
  for (path) |segment| {
    current_node = try self.getChildNodeId(current_node, segment);
  }
  return current_node;
}

fn getChildNodeId(self: *const Document, parent_id: Node.Id, segment: PathSegment) !Node.Id {
  var current_node = parent_id;
  switch (segment) {
    .field => {
      // node is a mapping. Find the first child keyvalue
      current_node = self.nodes[current_node].kind.mapping orelse return error.NotFound;
      // Loop through keyvalue siblings to find matching key
      while (true) {
        const span = self.nodes[self.nodes[current_node].kind.keyvalue.key].span;
        const node_key = self.source[span.start..span.end];
        if (std.mem.eql(u8, segment.field, node_key)) break;
        current_node = self.nodes[current_node].next_sibling orelse return error.NotFound;
      }
      // We found the right keyvalue node! Return the value node
      return self.nodes[current_node].kind.keyvalue.value;
    },
    .index => {
      // node is a sequence. Find first value.
      current_node = self.nodes[current_node].kind.sequence orelse return error.NotFound;
      for (0..segment.index) |_| {
        current_node = self.nodes[current_node].next_sibling orelse return error.NotFound;
      }
      return current_node;
    }
  }
}