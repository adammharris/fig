// src/token.zig
const token = @This();
const Span = @import("util/span.zig");

pub fn Token(comptime KindType: type) type {
  comptime {
    if (!@hasDecl(KindType, "len")) {
      @compileError("Token KindType must define pub fn len(self: Kind) ?usize");
    }
  }

  return struct {
    const Self = @This();

    pub const Kind = KindType;

    kind: Kind,
    span: Span,

    pub fn init(kind: Kind, span: Span) Self {
      return .{ .kind = kind, .span = span };
    }

    pub fn source(self: Self, bytes: []const u8) []const u8 {
      return bytes[self.span.start..self.span.end];
    }

    pub fn fixed(kind: Kind, start: usize) Self {
      const len = kind.len() orelse unreachable;
      return .{ .kind = kind, .span = Span.init(start, start + len) };
    }
  };
}