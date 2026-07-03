const zon = @This();
const Document = @import("../../document.zig");
const AST = @import("../../ast/ast.zig");

pub const Parser = @import("parser.zig");
pub const Printer = @import("printer.zig");

pub const Type = enum {
    /// ZON as accepted by the Zig 0.16 `std.zig` parser. There is no versioned
    /// ZON spec; the grammar tracks whatever the pinned compiler accepts.
    ZON,
};

pub const Language = struct {
    pub const Type = zon.Type;
    pub const Parser = zon.Parser;
    pub const default_type: zon.Type = .ZON;
    pub fn parse(parser: *zon.Parser, input: []const u8, format: zon.Type) !Document {
        return zon.Parser.parse(parser.allocator, input, format);
    }
    pub const print = Printer.print;
    pub const printNode = Printer.printNode;
};

// Test discovery: importing `zon.zig` (from root.zig) pulls in every ZON
// submodule's tests, so the module owns its own test surface.
test {
    _ = @import("parser.zig");
    _ = @import("printer.zig");
}
