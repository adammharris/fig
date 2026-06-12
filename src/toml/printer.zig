//! TOML printer.
//!
//! Phase 0: a stub satisfying the Language contract (`print` / `printNode`).
//! TOML output (tables, dotted keys, arrays-of-tables) lands in Phase 5; until
//! then printing a TOML document returns error.NotImplemented. Converting a TOML
//! AST *to JSON/YAML* goes through those printers, not this one.

const Printer = @This();
const std = @import("std");
const AST = @import("../ast.zig");
const Writer = std.Io.Writer;

pub const Error = Writer.Error || error{NotImplemented};

pub fn print(writer: *Writer, ast: *const AST) Error!void {
    _ = writer;
    _ = ast;
    return error.NotImplemented;
}

pub fn printNode(writer: *Writer, ast: *const AST, id: AST.Node.Id, depth: usize) Error!void {
    _ = writer;
    _ = ast;
    _ = id;
    _ = depth;
    return error.NotImplemented;
}
