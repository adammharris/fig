//! XML tokenizer.
//!
//! Phase 1 SCAFFOLD: the token vocabulary is defined here so the parser and the
//! rest of the tree can compile against it, but `tokenize` is not implemented
//! yet — real lexing arrives in Phase 2.

const Tokenizer = @This();

const std = @import("std");
const Span = @import("../util/span.zig");

allocator: std.mem.Allocator,
str: []const u8 = "",
pos: usize = 0,

pub const Token = struct {
    kind: Kind,
    span: Span,

    pub const Kind = enum {
        /// `<` opening an element start-tag.
        lt,
        /// `</` opening an element end-tag.
        lt_slash,
        /// `>` closing a tag.
        gt,
        /// `/>` closing an empty-element tag.
        slash_gt,
        /// `=` between an attribute name and its value.
        eq,
        /// An element or attribute name (`span` covers the name bytes).
        name,
        /// A quoted attribute value (`span` covers the bytes *inside* the
        /// quotes; decoding of entities happens in the parser).
        attr_value,
        /// Character data between tags (`span` covers the raw run; whitespace
        /// handling and entity decoding happen in the parser).
        char_data,
        /// End of input.
        eof,
    };
};

pub const TokenizeError = error{
    OutOfMemory,
    /// Placeholder for Phase 1; replaced by specific lexical errors in Phase 2.
    NotImplemented,
};

/// Phase 1 stub. Real lexing arrives in Phase 2.
pub fn tokenize(self: *Tokenizer) TokenizeError![]const Token {
    _ = self;
    return error.NotImplemented;
}

test "xml tokenizer scaffold compiles" {
    try std.testing.expectEqual(Token.Kind.eof, Token.Kind.eof);
}
