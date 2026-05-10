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
  mapping: @import("std").StringHashMap(Value),
};