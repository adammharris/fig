//! Shared RFC-3339-style date/time validation and classification.
//!
//! TOML datetimes and YAML 1.1 `!!timestamp` scalars share the same lexical
//! core — `YYYY-MM-DD`, an optional `T`/`t`/space separator, `HH:MM:SS[.frac]`,
//! and a `Z`/`±HH:MM` zone — so the validation lives here once. Callers map the
//! returned `Kind` onto their own scalar type (both use the AST `ExtKind`, whose
//! first four members line up with `Kind`); this module stays AST-free so it
//! remains a leaf utility.
//!
//! `classify` is total: it returns `error.InvalidDatetime` for anything that is
//! not a well-formed datetime. That lets a parser use it two ways — to validate
//! a token it already believes is a datetime (TOML), or to *probe* an arbitrary
//! plain scalar and treat the error as "not a timestamp" (YAML). Because of the
//! probe use, every field is digit-checked here rather than trusting a tokenizer
//! to have done it.

const std = @import("std");
const ascii = @import("ascii.zig");

pub const Error = error{InvalidDatetime};

/// Which datetime shape a string resolved to. Mirrors the first four members of
/// the AST `ExtKind`, kept independent so this leaf utility doesn't depend on
/// the AST.
pub const Kind = enum { offset_datetime, local_datetime, local_date, local_time };

pub const Options = struct {
    /// Accept `HH:MM` with the seconds omitted. TOML 1.0 requires seconds (pass
    /// false); TOML 1.1 and YAML are lenient.
    allow_minute_precision: bool = true,
    /// Accept a bare `HH:MM:SS[.frac]` with no date as a `local_time`. TOML
    /// allows it; YAML 1.1 does not (there a `:`-run with no date is a
    /// sexagesimal number), so YAML passes false.
    allow_time_only: bool = true,
};

pub fn classify(raw: []const u8, opts: Options) Error!Kind {
    // Time-only: HH:MM...
    if (opts.allow_time_only and raw.len >= 3 and raw[2] == ':') {
        try validateTime(raw, opts);
        return .local_time;
    }
    // Date present: YYYY-MM-DD.
    if (raw.len < 10) return error.InvalidDatetime;
    try validateDate(raw[0..10]);
    if (raw.len == 10) return .local_date;

    // Separator, then time (+ optional zone).
    const sep = raw[10];
    if (sep != 'T' and sep != 't' and sep != ' ') return error.InvalidDatetime;
    const rest = raw[11..];

    // Zone: trailing Z/z, or ±HH:MM at the end.
    var time_str = rest;
    var has_offset = false;
    if (rest.len > 0 and (rest[rest.len - 1] == 'Z' or rest[rest.len - 1] == 'z')) {
        time_str = rest[0 .. rest.len - 1];
        has_offset = true;
    } else if (rest.len >= 6 and (rest[rest.len - 6] == '+' or rest[rest.len - 6] == '-') and rest[rest.len - 3] == ':') {
        try validateOffset(rest[rest.len - 6 ..]);
        time_str = rest[0 .. rest.len - 6];
        has_offset = true;
    }
    try validateTime(time_str, opts);
    return if (has_offset) .offset_datetime else .local_datetime;
}

fn twoDigit(s: []const u8, at: usize) u8 {
    return (s[at] - '0') * 10 + (s[at + 1] - '0');
}

/// Both bytes at `s[at..at+2]` are ASCII digits.
fn bothDigits(s: []const u8, at: usize) bool {
    return at + 1 < s.len and ascii.isDigit(s[at]) and ascii.isDigit(s[at + 1]);
}

pub fn validateDate(s: []const u8) Error!void {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return error.InvalidDatetime;
    if (!bothDigits(s, 0) or !bothDigits(s, 2) or !bothDigits(s, 5) or !bothDigits(s, 8)) return error.InvalidDatetime;
    const year = @as(u16, twoDigit(s, 0)) * 100 + twoDigit(s, 2);
    const month = twoDigit(s, 5);
    const day = twoDigit(s, 8);
    if (month < 1 or month > 12) return error.InvalidDatetime;
    if (day < 1 or day > daysInMonth(year, month)) return error.InvalidDatetime;
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) @as(u8, 29) else 28,
        else => 0,
    };
}

fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
}

/// `HH:MM[:SS[.fraction]]`; seconds 00-60 (leap second allowed). With
/// `allow_minute_precision` false the seconds are mandatory.
pub fn validateTime(s: []const u8, opts: Options) Error!void {
    if (s.len < 5 or s[2] != ':') return error.InvalidDatetime;
    if (!bothDigits(s, 0) or !bothDigits(s, 3)) return error.InvalidDatetime;
    if (twoDigit(s, 0) > 23 or twoDigit(s, 3) > 59) return error.InvalidDatetime;
    if (s.len == 5) {
        if (!opts.allow_minute_precision) return error.InvalidDatetime;
        return;
    }
    if (s[5] != ':' or s.len < 8) return error.InvalidDatetime;
    if (!bothDigits(s, 6) or twoDigit(s, 6) > 60) return error.InvalidDatetime;
    if (s.len == 8) return;
    if (s[8] != '.' or s.len < 10) return error.InvalidDatetime;
    for (s[9..]) |c| if (!ascii.isDigit(c)) return error.InvalidDatetime;
}

/// `±HH:MM` zone offset; hour 00-23, minute 00-59.
pub fn validateOffset(s: []const u8) Error!void {
    if (s.len != 6 or s[3] != ':') return error.InvalidDatetime;
    if (!bothDigits(s, 1) or !bothDigits(s, 4)) return error.InvalidDatetime;
    if (twoDigit(s, 1) > 23 or twoDigit(s, 4) > 59) return error.InvalidDatetime;
}

test "classify shapes" {
    const t = std.testing;
    const cases = [_]struct { src: []const u8, kind: Kind }{
        .{ .src = "1979-05-27T07:32:00Z", .kind = .offset_datetime },
        .{ .src = "1979-05-27T07:32:00.999-07:00", .kind = .offset_datetime },
        .{ .src = "1979-05-27T07:32:00", .kind = .local_datetime },
        .{ .src = "1979-05-27 07:32:00", .kind = .local_datetime },
        .{ .src = "1979-05-27", .kind = .local_date },
        .{ .src = "07:32:00", .kind = .local_time },
        .{ .src = "00:32:00.999999", .kind = .local_time },
    };
    for (cases) |c| try t.expectEqual(c.kind, try classify(c.src, .{}));
}

test "rejects malformed datetimes" {
    const t = std.testing;
    const bad = [_][]const u8{ "", "hello", "2002-13-01", "2002-02-30", "20A2-12-14", "1979-05-27X07:32:00", "1979-05-27T07:60:00", "2002-12-14T12:30" };
    for (bad) |s| try t.expectError(error.InvalidDatetime, classify(s, .{ .allow_minute_precision = false }));
}

test "options gate time-only and minute precision" {
    const t = std.testing;
    // Time-only refused when disallowed (YAML).
    try t.expectError(error.InvalidDatetime, classify("07:32:00", .{ .allow_time_only = false }));
    // Minute precision refused when disallowed (TOML 1.0).
    try t.expectError(error.InvalidDatetime, classify("1979-05-27T07:32", .{ .allow_minute_precision = false }));
    try t.expectEqual(Kind.local_datetime, try classify("1979-05-27T07:32", .{ .allow_minute_precision = true }));
}
