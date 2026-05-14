const std = @import("std");
const log = std.log.scoped(.tokenizer);
const testing = std.testing;
const JsonFormat = @import("json.zig").JsonFormat;
const Span = @import("../util/span.zig");

pub const Token = @import("../token.zig").Token(Kind);

pub const Kind = enum {
  // Structural
  /// {
  open_brace,
  /// }
  close_brace,
  /// [
  open_bracket,
  /// ]
  close_bracket,

  colon,
  comma,
  end_of_file,

  // Literals
  true_,
  false_,
  null_,

  // variable-length
  string,
  number,
  comment,
  whitespace,

  /// Find length of token kind. Returns null for variable-length tokens.
  pub fn len(self: Kind) ?usize {
    return switch (self) {
      .end_of_file => 0,
      .open_brace, .close_brace, .open_bracket, .close_bracket,
      .colon, .comma => 1,
      .true_, .null_ => 4,
      .false_ => 5,
      else => null
    };
  }
};

const TokenizeError = error{
  UnexpectedToken,
  MissingToken,
  OutOfMemory,
  UnexpectedSlash,
  MissingCloseBrace,
  MissingOpenQuote,
  MissingColon,
  MissingCloseBracket,
  LeadingZero,
  UnclosedString,
  UnexpectedEndOfInput
};


pub const Tokenizer = struct {
  // State
  tokens: std.ArrayList(Token) = .empty,
  index: usize = 0,

  // Initial fields
  allocator: std.mem.Allocator,
  str: []const u8 = "",
  kind: JsonFormat = JsonFormat.JSONC,

  pub fn tokenize(self: *Tokenizer) ![]const Token {
    errdefer self.tokens.deinit(self.allocator);
    try self.tokens.ensureTotalCapacity(self.allocator, self.str.len + 1);

    while(self.char()) |c| {
      try self.addToken(switch (c) {
        '{' => .init(.open_brace, .init(self.index, self.index + 1)),
        '}' => .init(.close_brace, .init(self.index, self.index + 1)),
        '[' => .init(.open_bracket, .init(self.index, self.index + 1)),
        ']' => .init(.close_bracket, .init(self.index, self.index + 1)),
        ':' => .init(.colon, .init(self.index, self.index + 1)),
        ',' => .init(.comma, .init(self.index, self.index + 1)),
        't' => try self.findLiteral(.true_),
        'f' => try self.findLiteral(.false_),
        'n' => try self.findLiteral(.null_),
        '"' => try self.string(),
        '/' => try self.comment(),
        '0','1','2','3','4','5','6','7','8','9','-' => try self.number(),
        ' ', '\t', '\n', '\r' => try self.getWhitespace(),
        else => {
          log.err("Found: {c}", .{c});
          return TokenizeError.UnexpectedToken;
        }
      });
    }

    try self.addToken(.fixed(.end_of_file, self.index));
    return try self.tokens.toOwnedSlice(self.allocator);
  }

  fn findLiteral(self: *const Tokenizer, kind: Token.Kind) TokenizeError!Token {
    switch (kind) {
      .null_ => { if (self.matches("null")) return .fixed(.null_, self.index); },
      .true_ => { if (self.matches("true")) return .fixed(.true_, self.index); },
      .false_ => { if (self.matches("false")) return .fixed(.false_, self.index); },
      else => return error.UnexpectedToken,
    }
    log.err("Broken literal", .{});
    return TokenizeError.UnexpectedToken;
  }

  /// Collects all whitespace and returns it as a token.
  /// Can return null. `addToken` checks for null.
  fn getWhitespace(self: *Tokenizer) TokenizeError!Token {
    const start = self.index;
    while (self.char()) |c| {
      if (!std.ascii.isWhitespace(c)) break;
      self.index += 1;
    }
    const end = self.index;
    if (start == end) unreachable;
    return .init(.whitespace, .init(start, end));
  }

  // =====================
  // CONVENIENCE FUNCTIONS
  // =====================

  /// Convenience function for accessing current character
  fn char(self: *const Tokenizer) ?u8 {
    if (self.index >= self.str.len) return null;
    return self.str[self.index];
  }

  /// Convenience function for adding a token to the tokens array
  fn addToken(self: *Tokenizer, token: Token) TokenizeError!void {
    try self.tokens.append(self.allocator, token);
    self.index = token.span.end;
  }

  /// Checks if the index is on a given sequence of characters.
  fn matches(self: *const Tokenizer, str: []const u8) bool {
    // TODO: can read out of bounds in `matches()` for truncated literals like `tru`, `fals`, or `n`. Check `self.index + str.len <= self.str.len` before indexing.
    var local_index = self.index;
    for (str) |c| {
      if (self.str[local_index] != c) return false;
      local_index += 1;
    }
    return true;
  }

  // ========================
  // TERMINAL TOKEN FUNCTIONS
  // ========================

  /// Collects all whitespace and returns it as a token.
  /// Can return null. `addToken` checks for null.
  fn whitespace(self: *Tokenizer) TokenizeError!?Token {
    const start = self.index;
    while (self.char()) |c| {
      if (!std.ascii.isWhitespace(c)) break;
      self.index += 1;
    }
    const end = self.index;
    if (start == end) return null;
    return .init(.whitespace, .init(start, end));
  }

  /// Collects all the bytes of a string and returns a JsonToken.string
  /// Never returns null, but can be an empty string.
  /// Respects escaped values.
  fn string(self: *Tokenizer) TokenizeError!Token {
    const start = self.index;
    self.index += 1; // skip first `"`

    while (self.char()) |c| {
      switch (c) {
        '"' => {
          self.index += 1; // skip final `"`
          const end = self.index;
          return .init(.string, .init(start, end));
        },
        '\\' => {
          //TODO: accepts invalid escapes like `\x`, raw
          // newlines/control bytes, and incomplete `\u` escapes
          self.index += 1; // skip backslash
          if (self.char() == null) return error.UnclosedString;
          self.index += 1; // skip escaped character
        },
        else => self.index += 1,
      }
    }
    return error.UnclosedString;
  }

  /// Collects various kinds of numbers.
  /// Negative, decimal, exponent
  /// Checks for leading zero as well.
  fn number(self: *Tokenizer) TokenizeError!Token {
    // TODO: accepts several invalid JSON numbers: `-`, `-.2`, `1.`, `1e+`; it also accepts `-012` but rejects valid forms like `0e1`. Number scanning needs a stricter grammar: optional `-`, integer part, optional fraction with at least one digit, optional exponent with optional sign and at least one digit.
    const start = self.index;

    var isDecimal = false;
    var leadingZero = false;
    var isExponent = false;
    var isNegative = false;

    // Check for negativity
    if (self.char() == '-') {
      self.index += 1;
      isNegative = true;
    }

    // Check for leading zero
    if (self.char() == '0') {
      self.index += 1;
      leadingZero = true;
    }

    // Start collecting numbers.
    // Watch out for: `.`, `e`, `E`
    while (true) {
      switch (self.char() orelse return error.UnexpectedEndOfInput) {
        '0','1','2','3','4','5','6','7','8','9' => self.index += 1,
        '.' => {
          if (isDecimal) {
            log.err("Already found a period. Slice: {s}", .{self.str[start..self.index]});
            return TokenizeError.UnexpectedToken;
          }
          isDecimal = true;
          self.index += 1;
        },
        'e', 'E' => {
          if (isExponent) {
            log.err("Already found an e/E. Slice: {s}", .{self.str[start..self.index]});
            return TokenizeError.UnexpectedToken;
          }
          isExponent = true;
          self.index += 1;
          switch (self.char() orelse return error.UnexpectedEndOfInput) {
            '0','1','2','3','4','5','6','7','8','9','+','-' => self.index += 1,
            else => {
              log.err("Invalid exponent. Expected +/- or digit, found {c}", .{ self.char() orelse 0 });
              return TokenizeError.UnexpectedToken;
            }
          }
        },
        else => break,
      }
    }

    const end = self.index;

    // Error if number has inappropriate leading zero, like "0123"
    if (
      leadingZero
      and !isDecimal
      and (!isNegative and end - start != 1))
    {
      log.err(
        "Leading zero detected: {s}"
        ++ "\nleadingZero: {any}"
        ++ "\nisDecimal: {any}"
        ++ "\nisNegative: {any}"
        ++ "\nisExponent: {any}"
        ++ "\nstart: {any}, end: {any}",
        .{ self.str[start..end],
          leadingZero, isDecimal, isNegative, isExponent, start, end
      });
      return TokenizeError.LeadingZero;
    }

    return .init(.number, .init(start, end));
  }

  /// Collects all bytes until arriving at a newline
  /// Never returns null, but can be empty
  fn comment(self: *Tokenizer) TokenizeError!Token {
    //TODO: treats any `/` as a JSONC line comment and skips two bytes without confirming the second byte is `/`. Bare `/` can produce a span past the input length.
    // Comments are not supported in the canonical JSON format
    if (self.kind == JsonFormat.JSON) return error.UnexpectedSlash;
    const start = self.index;
    self.index += 2; // Skip the '//' characters
    while (self.char()) |c| {
      if (c == '\n') break;
      self.index += 1;
    }
    const end = self.index;
    return .init(.comment, .init(start, end));
  }

};

// =======
// Testing
// =======

// Run tests standalone with
// `zig build test -Dtest-filter=tokenizer --summary all`

fn tok(kind: Token.Kind, start: usize, end: usize) Token {
  return Token.init(kind, .init(start, end));
}

fn testTokenizer(input: []const u8, expected: []const Token) !void {
  var tokenizer: Tokenizer = .{
    .allocator = testing.allocator,
    .str = input
  };
  const tokens = try tokenizer.tokenize();
  defer testing.allocator.free(tokens);
  //errdefer log.err("expected: {any}", .{expected});
  //errdefer log.err("actual: {any}", .{tokens});
  try testing.expectEqualSlices(Token, expected, tokens);
}

test "array no whitespace" {
  try testTokenizer(
    \\["hello","there"]
    , &.{
      tok(.open_bracket, 0, 1),
      tok(.string, 1, 8),
      tok(.comma, 8, 9),
      tok(.string, 9, 16),
      tok(.close_bracket, 16, 17),
      tok(.end_of_file, 17, 17),
    }
  );
}

test "whitespace" {
  try testTokenizer(
    " [ \"hello\" ,  \"there\" ] "
    , &.{
      tok(.whitespace, 0, 1),
      tok(.open_bracket, 1, 2),
      tok(.whitespace, 2, 3),
      tok(.string, 3, 10),
      tok(.whitespace, 10, 11),
      tok(.comma, 11, 12),
      tok(.whitespace, 12, 14),
      tok(.string, 14, 21),
      tok(.whitespace, 21, 22),
      tok(.close_bracket, 22, 23),
      tok(.whitespace, 23, 24),
      tok(.end_of_file, 24, 24),
    }
  );
  try testTokenizer(
    " { \"hello\" :  \"there\" } "
    , &.{
      tok(.whitespace, 0, 1),
      tok(.open_brace, 1, 2),
      tok(.whitespace, 2, 3),
      tok(.string, 3, 10),
      tok(.whitespace, 10, 11),
      tok(.colon, 11, 12),
      tok(.whitespace, 12, 14),
      tok(.string, 14, 21),
      tok(.whitespace, 21, 22),
      tok(.close_brace, 22, 23),
      tok(.whitespace, 23, 24),
      tok(.end_of_file, 24, 24),
    }
  );
}

test "object with array" {
  try testTokenizer(
    \\{"array": ["hello" ,  "there"]}
    , &.{
      tok(.open_brace, 0, 1),
      tok(.string, 1, 8),
      tok(.colon, 8, 9),
      tok(.whitespace, 9, 10),
      tok(.open_bracket, 10, 11),
      tok(.string, 11, 18),
      tok(.whitespace, 18, 19),
      tok(.comma, 19, 20),
      tok(.whitespace, 20, 22),
      tok(.string, 22, 29),
      tok(.close_bracket, 29, 30),
      tok(.close_brace, 30, 31),
      tok(.end_of_file, 31, 31),
    }
  );
}

test "primitives" {
  try testTokenizer(
    \\[true, false, null, "string", 40334]
    , &.{
      tok(.open_bracket, 0, 1),
      tok(.true_, 1, 5),
      tok(.comma, 5, 6),
      tok(.whitespace, 6, 7),
      tok(.false_, 7, 12),
      tok(.comma, 12, 13),
      tok(.whitespace, 13, 14),
      tok(.null_, 14, 18),
      tok(.comma, 18, 19),
      tok(.whitespace, 19, 20),
      tok(.string, 20, 28),
      tok(.comma, 28, 29),
      tok(.whitespace, 29, 30),
      tok(.number, 30, 35),
      tok(.close_bracket, 35, 36),
      tok(.end_of_file, 36, 36),
    }
  );
}

test "numbers" {
  try testTokenizer(
    \\[1,-1,0,0.2,12e+3,1e10]
    , &.{
      tok(.open_bracket, 0, 1),
      tok(.number, 1, 2),
      tok(.comma, 2, 3),
      tok(.number, 3, 5),
      tok(.comma, 5, 6),
      tok(.number, 6, 7),
      tok(.comma, 7, 8),
      tok(.number, 8, 11),
      tok(.comma, 11, 12),
      tok(.number, 12, 17),
      tok(.comma, 17, 18),
      tok(.number, 18, 22),
      tok(.close_bracket, 22, 23),
      tok(.end_of_file, 23, 23),
    }
  );
}

test "empty object/array" {
  try testTokenizer(
    \\[]
    , &.{
      tok(.open_bracket, 0, 1),
      tok(.close_bracket, 1, 2),
      tok(.end_of_file, 2, 2),
    }
  );
  try testTokenizer(
    \\{}
    , &.{
      tok(.open_brace, 0, 1),
      tok(.close_brace, 1, 2),
      tok(.end_of_file, 2, 2),
    }
  );
}