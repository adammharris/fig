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

/// This module has two roles, and they are NOT equally permanent:
///
///   1. `Tokenizer` — the shared XML *lexing substrate*. This is the durable
///      part. It is a plain XML lexer with no config-format opinions, and typed
///      XML flavors are built on top of it: `plist` already delegates all lexing
///      here (`../plist/parser.zig`), and future flavors (`.csproj`,
///      `AndroidManifest.xml`, …) are meant to as well. It lives under
///      `languages/xml/` as a neutral home precisely so no single flavor owns it.
///
///   2. `Parser`/`Printer` — the generic XML *fold*, a DEMOTED, best-effort
///      convenience, not a first-class config format. It reads into the shared
///      AST (root is a one-entry mapping, `@`-keys are attributes, `#text` is
///      text content, repeated children round-trip through a `sequence`) and
///      writes back via `Printer`. It is lossy at the edges (no typed scalars —
///      every value prints as text) and shape-constrained (`-o xml` needs a
///      single root key). It IS an `AST.SerializeFormat` member (`.xml`) so
///      `ast.serialize` still routes here, but it is **opt-in and off by default**
///      (`-Dxml=true`), has no in-place editor (`fig edit`/`fig comment` error
///      with `UnsupportedXmlEdit` — deliberately, not "not yet": generic XML's
///      attributes-vs-text-vs-mixed-content edit surface is fundamentally
///      ambiguous in a way a fixed DTD like plist's is not), and is slated for
///      removal as a selectable format in a future major (see
///      `docs/BREAKING-CHANGES.md`). Reach for `plist` (typed, round-trips,
///      editable) for structured XML; the generic fold is only for ad-hoc
///      "get arbitrary XML into JSON" conversions.
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
