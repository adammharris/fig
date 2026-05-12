//! The universal document representation.
//! Lower-level modules such as json/parser.zig depend on this,
//! taking in a string and returning a Document.
//!
//! ...

const Document = @This();
const std = @import("std");
const json = @import("json/json.zig");

allocator: std.mem.Allocator,
value: Value,
source: Source,

const Format = union(enum) {
    json: json.JsonFormat,
    // TODO: support more formats
    // yaml: YamlFormat,
    // toml: TomlFormat,
    // others
};

/// The "universal" config value representation.
/// The meaning of a document is contained in nested Values.
const Value = union(enum) {
  // Scalars
  empty,
  boolean: bool,
  integer: i64,
  decimal: f64,
  string: []const u8,
  /// Sequence: a list of other values
  /// Ordered; accessed by index
  /// Implemented here with a simple slice/array
  sequence: []Value,
  /// Mapping: key:value pairs
  /// Unordered; accessed by key string
  /// Implemented here by StringHashMapUnmanaged
  mapping: std.StringHashMapUnmanaged(Value),
};

const Source = struct {
  format: Format,
  raw: []const u8,
  tokens: []Token,
  // Abstract tokens?
};

const Token = struct {
  kind: Format,
  span: Span
};

const Span = struct {
  start: usize,
  end: usize,
};