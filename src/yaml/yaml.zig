const yaml = @This();
const Document = @import("../document.zig");

pub const Parser = @import("parser.zig");
pub const Tokenizer = @import("tokenizer.zig");
pub const Printer = @import("printer.zig");

pub const Language = struct {
    pub const Type = enum {
        v1_2,
        // TODO: earlier versions of YAML spec?
    };
    pub const Parser = yaml.Parser;
    pub const default_type: Type = .v1_2;
    pub fn parse(parser: *yaml.Parser, input: []const u8, format: Type) !Document {
        return parser.parseOnce(input, format);
    }
    pub fn print(writer: *@import("std").Io.Writer, document: *const Document) !void {
        return yaml.Printer.print(writer, document);
    }
};
