const properties = @This();
const Document = @import("../../document.zig");

pub const Parser = @import("parser.zig");
pub const Tokenizer = @import("tokenizer.zig");
pub const Printer = @import("printer.zig");

pub const Type = enum {
    /// The one dialect this parser accepts — see `tokenizer.zig`'s module doc
    /// for the full grammar (three interchangeable separators, backslash
    /// escapes on both key and value, line continuation, `#`/`!` comments).
    PROPERTIES,
};

pub const Language = struct {
    pub const Type = properties.Type;
    pub const Parser = properties.Parser;
    pub const default_type: properties.Type = .PROPERTIES;
    pub fn parse(parser: *properties.Parser, input: []const u8, format: properties.Type) !Document {
        return properties.Parser.parse(parser.allocator, input, format);
    }
    pub const print = Printer.print;
    pub const printNode = Printer.printNode;
};

// Test discovery: importing `properties.zig` (from root.zig) pulls in every
// `.properties` submodule's tests, so the module owns its own test surface.
test {
    _ = @import("tokenizer.zig");
    _ = @import("parser.zig");
    _ = @import("printer.zig");
}
