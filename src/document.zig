//! The universal document representation.
//! Lower-level modules such as json/parser.zig depend on this,
//! taking in a string and returning a Document.
//!
//! ...

const Document = @This();
const std = @import("std");
const Span = @import("util/span.zig");

pub const Format = union(enum) {
  json: @import("json/json.zig").JsonFormat,
  // TODO: support more formats
  // yaml: YamlFormat,
  // toml: TomlFormat,
  // others
  pub fn equals(self: Format, other: Format) bool {
    return switch (self) {
      inline else => |value, tag| tag == std.meta.activeTag(other) and value == @field(other, @tagName(tag)),
    };
  }
};

pub const Node = struct {
  pub const Id = u32;
  pub const Kind = union(enum) {
    null_,
    boolean,
    string,
    number,
    sequence: ?Id,
    mapping: ?Id,
    keyvalue: struct { key: Id, value: Id },
    pub fn equals(self: Kind, other: Kind) bool {
      return switch (self) {
        .keyvalue => |value, tag| tag == std.meta.activeTag(other) and value.key == other.keyvalue.key and value.value == other.keyvalue.value,
        inline else => |value, tag| tag == std.meta.activeTag(other) and value == @field(other, @tagName(tag)),
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

format: Format,
root: Node.Id,
nodes: []const Node,
source: []const u8,

/// function to tell if two documents are equal
pub fn equals(self: Document, b: Document) bool {
  if (!self.format.equals(b.format)) return false;
  if (self.root != b.root) return false;
  if (!std.mem.eql(u8, self.source, b.source)) return false;
  if (self.nodes.len != b.nodes.len) return false;

  for (self.nodes, b.nodes) |na, nb| {
    if (!na.equals(nb)) return false;
  }
  return true;
}