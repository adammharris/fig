const std = @import("std");
const Value = @import("value.zig");
const log = std.log.scoped(.tokenizer);
const testing = std.testing;

pub const JsonToken = union(enum) {
  // Structural

  /// {
  left_brace,
  /// }
  right_brace,
  /// [
  left_bracket,
  /// ]
  right_bracket,
  /// :
  colon,
  /// ,
  comma,
  end_of_file,

  // Word literals

  true_,
  false_,
  null_,

  // variable-length

  string: []const u8,
  number: []const u8,
  comment: []const u8,
  whitespace: []const u8,

};

pub const documentKind = union(enum) {
  JSON,
  JSONC,
  //TODO: JSON5
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


const Tokenizer = struct {
  // State
  recursion_depth: usize = 0,
  tokens: std.ArrayListUnmanaged(JsonToken) = .empty,
  index: usize = 0,

  // Initial fields
  allocator: std.mem.Allocator,
  str: []const u8 = "",
  kind: documentKind = documentKind.JSONC,

  /// Given a JSON string, returns token array
  pub fn tokenize(self: *Tokenizer) TokenizeError![]const JsonToken {
    // Prefer provided string over struct string
    //if (self.str.len == 0 and str != null) {
    //  self.str = str;
    //}
    errdefer self.tokens.deinit(self.allocator);
    try self.tokens.ensureTotalCapacity(self.allocator, self.str.len + 1);
    try self.tokenizeValue();
    return try self.tokens.toOwnedSlice(self.allocator);
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
  fn addToken(self: *Tokenizer, token: JsonToken) TokenizeError!void {
    try self.tokens.append(self.allocator, token);
    switch (token) {
      .left_bracket, .right_bracket, .left_brace, .right_brace,
      .colon, .comma => self.index += 1,
      .true_, .null_ => self.index += 4,
      .false_ => self.index += 5,
      // string, comment, number, and whitespace all move the index
      // as they are detected. end_of_file does nothing.
      else => {}
    }
  }

  /// Checks if the index is on a given sequence of characters.
  fn matches(self: *const Tokenizer, str: []const u8) bool {
    var local_index = self.index;
    for (str) |c| {
      if (self.str[local_index] != c) return false;
      local_index += 1;
    }
    return true;
  }

  /// Used to tokenize areas that can optionally have whitespace.
  /// Indempotent. Does nothing if self.whitespace errors.
  fn optionalWhitespace(self: *Tokenizer) void {
    if (self.index >= self.str.len) return;
    const returned_token = self.whitespace() catch return;

    if (returned_token) |token| {
      self.addToken(token) catch return;
    }
  }

  // ========================
  // TERMINAL TOKEN FUNCTIONS
  // ========================

  /// Collects all whitespace and returns it as a token.
  /// Can return null. `addToken` checks for null.
  fn whitespace(self: *Tokenizer) TokenizeError!?JsonToken {
    const start = self.index;
    while (self.char()) |c| {
      if (!std.ascii.isWhitespace(c)) break;
      self.index += 1;
    }
    const end = self.index;
    if (start == end) return null;
    return .{ .whitespace = self.str[start..end]};
  }

  /// Collects all the bytes of a string and returns a JsonToken.string
  /// Never returns null, but can be an empty string.
  /// Respects escaped values.
  fn string(self: *Tokenizer) TokenizeError!JsonToken {
    self.index += 1; // skip first `"`
    const start = self.index;

    while (self.char()) |c| {
      switch (c) {
        '"' => {
          const end = self.index;
          self.index += 1; // skip final `"`
          return .{ .string = self.str[start..end] };
        },
        '\\' => {
          self.index += 1; // skip backslash
          if (self.char() == null) return error.UnclosedString;
          self.index += 1; // skip escaped character
        },
        else => self.index += 1,
      }
    }
    return error.UnclosedString;
  }

  fn number(self: *Tokenizer) TokenizeError!JsonToken {
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

    return .{ .number = self.str[start..end] };
  }

  /// Collects all bytes until arriving at a newline
  /// Never returns null, but can be empty
  fn comment(self: *Tokenizer) TokenizeError!JsonToken {
    // Comments are not supported in the canonical JSON format
    if (self.kind == documentKind.JSON) return error.UnexpectedSlash;
    const start = self.index;
    self.index += 2; // Skip the '//' characters
    while (self.char()) |c| {
      if (c == '\n') break;
      self.index += 1;
    }
    const end = self.index;
    return .{ .comment = self.str[start..end] };
  }

  // ============================
  // RECURSIVE TOKENIZE FUNCTIONS
  // ============================

  /// Turns a value into tokens.
  /// A value could be any of the following:
  /// array, object, string, number, true, false, null
  /// A value can also be surrounded by whitespace
  fn tokenizeValue(self: *Tokenizer) TokenizeError!void {
    self.optionalWhitespace();
    switch (self.char() orelse return error.UnexpectedEndOfInput) {
      '{' => try self.tokenizeObject(),
      '[' => try self.tokenizeArray(),
      '"' => try self.addToken(try self.string()),
      '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '-' => {
        try self.addToken(try self.number());
      },
      else => {
        if (self.matches("true")) {
          try self.addToken(.true_);
        } else if (self.matches("false")) {
          try self.addToken(.false_);
        } else if (self.matches("null")) {
          try self.addToken(.null_);
        } else if (self.matches("//")) {
          try self.addToken(try self.comment());
        } else {
          log.err("Unexpected token: {c}", .{self.char() orelse return error.UnexpectedEndOfInput});
          return error.UnexpectedToken;
        }
      },
    }
    self.optionalWhitespace();
  }

  fn tokenizeObject(self: *Tokenizer) TokenizeError!void {
    // Presence of left bracket already confirmed by `tokenizeValue()`
    try self.addToken(.left_brace);
    self.optionalWhitespace();
    if (
      (self.char() orelse return error.UnexpectedEndOfInput)
      == '}'
    ) {
      try self.addToken(.right_brace);
      return;
    }

    // Parse each key-value in the object.
    while (true) {
      try self.tokenizeKeyvalue();
      if ((self.char() orelse return error.UnexpectedEndOfInput) != ',') break;
      try self.addToken(.comma);
      self.optionalWhitespace();

      // Allow trailing commas for JSONC/JSON5
      if (self.kind != .JSON and (self.char() orelse return error.UnexpectedEndOfInput) == '}') {
        try self.addToken(.right_brace);
        return;
      }
    }

    if ((self.char() orelse return error.UnexpectedEndOfInput) == '}') {
      try self.addToken(.right_brace);
    } else return error.MissingCloseBrace;
  }

  /// Used in `tokenizeObject`, mirrors `tokenizeValue`
  /// A key-value is a component of an object that goes like this:
  /// whitespace, string, whitespace, colon, value
  fn tokenizeKeyvalue(self: *Tokenizer) TokenizeError!void {
    self.optionalWhitespace();

    // Guarantee quote before extracting string
    if ((self.char() orelse return error.UnexpectedEndOfInput) != '"') return error.MissingOpenQuote;
    try self.addToken(try self.string());

    self.optionalWhitespace();

    if ((self.char() orelse return error.UnexpectedEndOfInput) != ':') return error.MissingColon;
    try self.addToken(.colon);

    try self.tokenizeValue();
  }

  fn tokenizeArray(self: *Tokenizer) TokenizeError!void {
    // Presence of left brace already confirmed by `tokenizeValue()`
    try self.addToken(.left_bracket);

    self.optionalWhitespace(); // Possibly redundant if array is not empty

    if ((self.char() orelse return error.UnexpectedEndOfInput) == ']'){
      // Empty array detected. Return early.
      try self.addToken(.right_bracket);
      return;
    }

    // Parse each element of the array.
    while (true) {
      try self.tokenizeValue();
      if ((self.char() orelse return error.UnexpectedEndOfInput) != ',') {
        break;
      }
      try self.addToken(.comma);
    }

    if ((self.char() orelse return error.UnexpectedEndOfInput) == ']') {
      try self.addToken(.right_bracket);
    } else return error.MissingCloseBracket;
  }

};

// =======
// Testing
// =======

fn expectEqualToken(expected: JsonToken, actual: JsonToken) !void {
  try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));

  switch (expected) {
    .string => |expected_string| {
      try testing.expectEqualStrings(expected_string, actual.string);
    },
    .number => |expected_number| {
      try testing.expectEqualStrings(expected_number, actual.number);
    },
    .comment => |expected_comment| {
      try testing.expectEqualStrings(expected_comment, actual.comment);
    },
    .whitespace => |expected_whitespace| {
      try testing.expectEqualStrings(expected_whitespace, actual.whitespace);
    },
    else => {},
  }
}

fn testTokenizer(input: []const u8, expected: []const JsonToken) !void {
  var tokenizer: Tokenizer = .{
    .allocator = testing.allocator,
    .str = input
  };
  const tokens = try tokenizer.tokenize();
  defer testing.allocator.free(tokens);
  errdefer log.err("expected: {any}", .{expected});
  errdefer log.err("actual: {any}", .{tokens});
  try testing.expectEqual(expected.len, tokens.len);
  for (expected, tokens) |expected_token, actual_token| {
    try expectEqualToken(expected_token, actual_token);
  }
}

test "Tokenizer: array no whitespace" {
  try testTokenizer(
    \\["hello","there"]
    , &.{
      .left_bracket,
      .{ .string = "hello" },
      .comma,
      .{ .string = "there" },
      .right_bracket,
    }
  );
}

test "Tokenizer: whitespace" {
  try testTokenizer(
    " [ \"hello\" ,  \"there\" ] "
    , &.{
      .{ .whitespace = " "},
      .left_bracket,
      .{ .whitespace = " "},
      .{ .string = "hello" },
      .{ .whitespace = " "},
      .comma,
      .{ .whitespace = "  "},
      .{ .string = "there" },
      .{ .whitespace = " "},
      .right_bracket,
      .{ .whitespace = " "},
    }
  );
  try testTokenizer(
    " { \"hello\" :  \"there\" } "
    , &.{
      .{ .whitespace = " "},
      .left_brace,
      .{ .whitespace = " "},
      .{ .string = "hello" },
      .{ .whitespace = " "},
      .colon,
      .{ .whitespace = "  "},
      .{ .string = "there" },
      .{ .whitespace = " "},
      .right_brace,
      .{ .whitespace = " "},
    }
  );
}

test "Tokenizer: object with array" {
  try testTokenizer(
    \\{"array": ["hello" ,  "there"]}
    , &.{
      .left_brace,
      .{ .string = "array"},
      .colon,
      .{ .whitespace = " "},
      .left_bracket,
      .{ .string = "hello" },
      .{ .whitespace = " "},
      .comma,
      .{ .whitespace = "  "},
      .{ .string = "there" },
      .right_bracket,
      .right_brace,
    }
  );
}

test "primitives" {
  try testTokenizer(
    \\[true, false, null, "string", 40334]
    , &.{
      .left_bracket,
      .true_,
      .comma,
      .{ .whitespace = " " },
      .false_,
      .comma,
      .{ .whitespace = " " },
      .null_,
      .comma,
      .{ .whitespace = " " },
      .{ .string = "string" },
      .comma,
      .{ .whitespace = " " },
      .{ .number = "40334" },
      .right_bracket,
    }
  );
}

test "numbers" {
  try testTokenizer(
    \\[1,-1,0,0.2,12e+3,1e10]
    , &.{
      .left_bracket,
      .{ .number = "1"},
      .comma,
      .{ .number = "-1"},
      .comma,
      .{ .number = "0"},
      .comma,
      .{ .number = "0.2"},
      .comma,
      .{ .number = "12e+3"},
      .comma,
      .{ .number = "1e10"},
      .right_bracket,
    }
  );
}

test "tokenizer: empty object/array" {
  try testTokenizer(
    \\[]
    , &.{
      .left_bracket,
      .right_bracket,
    }
  );
  try testTokenizer(
    \\{}
    , &.{
      .left_brace,
      .right_brace,
    }
  );
}