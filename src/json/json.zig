const json = @This();
const AST = @import("../ast.zig");
const Document = @import("../document.zig");

pub const Parser = @import("parser.zig");
pub const Tokenizer = @import("tokenizer.zig");
pub const Printer = @import("printer.zig");

pub const Language = struct {
    pub const Type = enum {
        JSON,
        JSONC,
        // TODO: JSON5
    };
    pub const Parser = json.Parser;
    pub const default_type: Type = .JSON;
    pub fn parse(parser: *json.Parser, input: []const u8, format: Type) !Document {
        return json.Parser.parse(parser.allocator, input, format);
    }
    pub fn print(writer: *@import("std").Io.Writer, document: *const AST) !void {
        return json.Printer.print(writer, document);
    }
};
