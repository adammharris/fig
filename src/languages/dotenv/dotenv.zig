const dotenv = @This();
const Document = @import("../../document.zig");

pub const Parser = @import("parser.zig");
pub const Tokenizer = @import("tokenizer.zig");
pub const Printer = @import("printer.zig");

pub const Type = enum {
    /// The one dialect this parser accepts — see `tokenizer.zig`'s module doc
    /// for exactly what it does and doesn't accept (bash-identifier keys,
    /// optional `export`, real `"`/`'` quoting, no `$VAR` interpolation).
    DOTENV,
};

pub const Language = struct {
    pub const Type = dotenv.Type;
    pub const Parser = dotenv.Parser;
    pub const default_type: dotenv.Type = .DOTENV;
    pub fn parse(parser: *dotenv.Parser, input: []const u8, format: dotenv.Type) !Document {
        return dotenv.Parser.parse(parser.allocator, input, format);
    }
    pub const print = Printer.print;
    pub const printNode = Printer.printNode;
};

// Test discovery: importing `dotenv.zig` (from root.zig) pulls in every
// dotenv submodule's tests, so the module owns its own test surface.
test {
    _ = @import("tokenizer.zig");
    _ = @import("parser.zig");
    _ = @import("printer.zig");
}
