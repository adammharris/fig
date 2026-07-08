const plist = @This();
const std = @import("std");
const AST = @import("../../ast/ast.zig");
const Document = @import("../../document.zig");
const Writer = std.Io.Writer;

pub const Parser = @import("parser.zig");
pub const Printer = @import("printer.zig");

pub const Type = enum {
    /// Apple's XML property list — `<plist><dict>...</dict></plist>`, the
    /// only variant this reader/printer supports so far. Old-style ASCII
    /// (NeXTSTEP/OpenStep `{ key = value; }`) and binary plist (`bplist00…`)
    /// are separate, larger efforts (a different grammar, and for binary, a
    /// wholly different byte-level format) — see `parser.zig`'s module doc.
    XML,
};

/// plist reads into the shared AST (so plist converts *into* JSON/YAML/TOML/
/// ZON/…) and writes back out via `Printer` — the documented inverse mapping
/// described in `parser.zig`'s header (a `dict` is a real mapping, an `array`
/// a real sequence, `date`/`data` ride the `extended` scalar). It IS an
/// `AST.SerializeFormat` member (`.plist`), so `ast.serialize` routes here like
/// every other format. It also HAS an in-place (span-splicing) editor —
/// `Editor(Plist)` via `editor_helper.zig` — so `fig edit`/`set`/`insert`/
/// `delete`/`comment` work on a `.plist`; unlike the line-oriented formats it
/// renders typed value elements (fig `sniffBare` typing) and uses `<!-- -->`
/// comments. The generic XML format (`.xml`) still has none — a document syntax
/// whose ambiguous edit surface (attributes vs text vs mixed content) is a
/// separate, deferred effort; plist works because its DTD gives every element a
/// fixed, unambiguous typed meaning.
pub const Language = struct {
    pub const Type = plist.Type;
    pub const Parser = plist.Parser;
    pub const default_type: plist.Type = .XML;

    pub fn parse(parser: *plist.Parser, input: []const u8, format: plist.Type) !Document {
        return plist.Parser.parse(parser.allocator, input, format);
    }

    pub fn print(writer: *Writer, ast: *const AST) !void {
        return plist.Printer.print(writer, ast, .{});
    }
};

// Test discovery: importing `plist.zig` (from root.zig) pulls in every plist
// submodule's tests, so the module owns its own test surface.
test {
    _ = @import("parser.zig");
    _ = @import("printer.zig");
    _ = @import("editor_helper.zig");
}
