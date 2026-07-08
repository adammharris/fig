const ini = @This();
const Document = @import("../../document.zig");

pub const Parser = @import("parser.zig");
pub const Tokenizer = @import("tokenizer.zig");
pub const Printer = @import("printer.zig");

pub const Type = enum {
    /// The one dialect this parser accepts: `=`-separated `key = value`
    /// lines, `[section]` headers, `;`/`#` full-line comments. See
    /// `tokenizer.zig`'s module doc for exactly what's deliberately excluded
    /// from the many incompatible things "INI" means in the wild.
    INI,
};

pub const Language = struct {
    pub const Type = ini.Type;
    pub const Parser = ini.Parser;
    pub const default_type: ini.Type = .INI;
    pub fn parse(parser: *ini.Parser, input: []const u8, format: ini.Type) !Document {
        return ini.Parser.parse(parser.allocator, input, format);
    }
    pub const print = Printer.print;
    pub const printNode = Printer.printNode;
};

// Test discovery: importing `ini.zig` (from root.zig) pulls in every INI
// submodule's tests, so the module owns its own test surface.
test {
    _ = @import("tokenizer.zig");
    _ = @import("parser.zig");
    _ = @import("printer.zig");
}
