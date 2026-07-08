const nestedtext = @This();
const Document = @import("../../document.zig");

pub const Parser = @import("parser.zig");
pub const Tokenizer = @import("tokenizer.zig");
pub const Printer = @import("printer.zig");

pub const Type = enum {
    /// NestedText (https://nestedtext.org) — the one dialect this parser
    /// accepts (the format has no versioned spec the way TOML does; recent
    /// releases (3.x) haven't changed the on-disk grammar this reads).
    NESTEDTEXT,
};

pub const Language = struct {
    pub const Type = nestedtext.Type;
    pub const Parser = nestedtext.Parser;
    pub const default_type: nestedtext.Type = .NESTEDTEXT;
    pub fn parse(parser: *nestedtext.Parser, input: []const u8, format: nestedtext.Type) !Document {
        return nestedtext.Parser.parse(parser.allocator, input, format);
    }
    pub const print = Printer.print;
    pub const printNode = Printer.printNode;
};

// Test discovery: importing `nestedtext.zig` (from root.zig) pulls in every
// submodule's tests, so the module owns its own test surface.
test {
    _ = @import("tokenizer.zig");
    _ = @import("parser.zig");
    _ = @import("printer.zig");
    _ = @import("editor_helper.zig");
}
