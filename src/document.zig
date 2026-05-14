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
  };

  /// IDs are arbitrary, but should be deterministic.
  id: Id,
  kind: Kind,
  /// Refers to string slice in Document.source
  span: Span,

  /// Indicates "next" value when inside a sequence/mapping.
  /// Null indicates that this is the last node in the sequence/mapping.
  next_sibling: ?Id = null,
};

format: Format,
root: Node.Id,
nodes: []Node,
source: []const u8,