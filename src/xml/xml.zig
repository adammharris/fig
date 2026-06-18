const xml = @This();
const std = @import("std");
const AST = @import("../ast.zig");
const Document = @import("../document.zig");
const Writer = std.Io.Writer;

pub const Parser = @import("parser.zig");
pub const Tokenizer = @import("tokenizer.zig");

pub const Type = enum {
    /// XML 1.0 (Fifth Edition). The only version fig targets — XML 1.1 differs
    /// only in obscure name/character rules and is essentially unused in the wild.
    XML_1_0,
};

/// XML is currently READER-ONLY: it parses into the shared AST (so XML converts
/// *into* JSON/YAML/TOML/ZON), but has no writer yet. It is deliberately NOT an
/// `AST.SerializeFormat` member, so `ast.serialize` never routes here. The
/// `print` decl below exists only to satisfy the `Language` interface
/// (`language.zig:validate` requires it) and always errors.
pub const Language = struct {
    pub const Type = xml.Type;
    pub const Parser = xml.Parser;
    pub const default_type: xml.Type = .XML_1_0;

    pub fn parse(parser: *xml.Parser, input: []const u8, format: xml.Type) !Document {
        return xml.Parser.parse(parser.allocator, input, format);
    }

    /// Reader-only: XML serialization is not implemented. Never reached in
    /// practice (XML is not a `SerializeFormat`); present for interface parity.
    pub fn print(writer: *Writer, ast: *const AST) !void {
        _ = writer;
        _ = ast;
        return error.WriteUnsupported;
    }
};
