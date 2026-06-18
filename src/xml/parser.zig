//! XML reader: parses XML into the shared fig AST.
//!
//! Data model (config-oriented, reader-only):
//!   * An element becomes a `mapping`; a text-only element with no attributes
//!     becomes a bare `string`; an empty element becomes `null`.
//!   * Attributes are folded into the element's mapping under `@`-prefixed keys,
//!     and mixed text under `#text`. This is collision-proof: `@` and `#` are
//!     illegal as the first character of an XML name, so these synthetic keys can
//!     never clash with a real element/attribute name.
//!   * Repeated child elements of the same name collapse into a `sequence`.
//!   * The document's single root element yields a one-entry root mapping
//!     `{ rootName: ... }`.
//!   * Values stay raw strings — no type inference.
//!
//! Phase 1 SCAFFOLD: the parser is stubbed and returns `error.NotImplemented`.
//! The element-tree walk, entity decoding, and well-formedness checks land in
//! Phases 3–4.

const Parser = @This();

const std = @import("std");
const AST = @import("../ast.zig");
const Document = @import("../document.zig");
const Type = @import("xml.zig").Type;
const Span = @import("../util/span.zig");
const Tokenizer = @import("tokenizer.zig");

allocator: std.mem.Allocator,
version: Type = .XML_1_0,
source: []const u8 = "",
nodes: std.ArrayList(AST.Node) = .empty,
spans: std.ArrayList(Span) = .empty,
owned_strings: std.ArrayList([]const u8) = .empty,

pub const ParseError = error{
    OutOfMemory,
    /// Phase 1 placeholder; replaced by the real well-formedness error set
    /// (MismatchedTag, DuplicateAttribute, UnsupportedEntity,
    /// MultipleRootElements, MissingRootElement, UnsupportedDoctype, …) in
    /// Phases 3–4.
    NotImplemented,
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8, format: Type) ParseError!Document {
    _ = allocator;
    _ = input;
    _ = format;
    return error.NotImplemented;
}

test "xml parser scaffold returns NotImplemented" {
    try std.testing.expectError(
        error.NotImplemented,
        parse(std.testing.allocator, "<a/>", .XML_1_0),
    );
}
