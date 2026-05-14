//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test {
  _ = @import("json/tokenizer.zig");
  _ = @import("json/parser.zig");
}