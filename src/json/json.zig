const json = @This();
const Document = @import("../document.zig");

pub const Parser = @import("parser.zig");
pub const Tokenizer = @import("tokenizer.zig");

pub const Language = struct {
  pub const Type = enum {
    JSON,
    JSONC,
    // TODO: JSON5
  };
  pub const Parser = json.Parser;
  pub const default_type: Type = .JSON;
  pub fn parse(parser: *json.Parser, input: []const u8, format: Type) !Document {
    return parser.parse(input, format);
  }
};