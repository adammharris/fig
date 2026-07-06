const xml = @This();
const std = @import("std");
const AST = @import("../../ast/ast.zig");
const Document = @import("../../document.zig");
const Writer = std.Io.Writer;

pub const Parser = @import("parser.zig");
pub const Tokenizer = @import("tokenizer.zig");
pub const Printer = @import("printer.zig");

pub const Type = enum {
    /// XML 1.0 (Fifth Edition). The only version fig targets — XML 1.1 differs
    /// only in obscure name/character rules and is essentially unused in the wild.
    XML_1_0,
};

/// XML reads into the shared AST (so XML converts *into* JSON/YAML/TOML/ZON)
/// and writes back out via `Printer` — the documented inverse mapping described
/// in `printer.zig`'s header (root is a one-entry mapping, `@`-keys are
/// attributes, `#text` is text content, repeated children round-trip through a
/// `sequence`). It IS an `AST.SerializeFormat` member (`.xml`), so `ast.serialize`
/// routes here like every other format; unlike the others it currently has no
/// in-place (span-splicing) editor — `fig edit`/`fig comment` on an XML file
/// still error (`UnsupportedXmlEdit`), a separate, larger feature.
pub const Language = struct {
    pub const Type = xml.Type;
    pub const Parser = xml.Parser;
    pub const default_type: xml.Type = .XML_1_0;

    pub fn parse(parser: *xml.Parser, input: []const u8, format: xml.Type) !Document {
        return xml.Parser.parse(parser.allocator, input, format);
    }

    pub fn print(writer: *Writer, ast: *const AST) !void {
        return xml.Printer.print(writer, ast, .{});
    }
};

// Test discovery: importing `xml.zig` (from root.zig) pulls in every XML
// submodule's tests, so the module owns its own test surface. The conformance
// suite is build-option-gated and stays in root.zig.
test {
    _ = @import("tokenizer.zig");
    _ = @import("parser.zig");
    _ = @import("printer.zig");
}
