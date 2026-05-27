//! A helper struct for selecting parts of a slice.
pub const Span = @This();

start: usize,
end: usize,

pub fn init(start: usize, end: usize) Span {
    return .{ .start = start, .end = end };
}

pub fn len(self: Span) usize {
    return self.end - self.start;
}

pub fn eql(self: Span, other: Span) bool {
    return self.start == other.start and self.end == other.end;
}

/// Take the span out of a slice.
pub fn of(comptime T: type, self: Span, slice: []const T) []const T {
    return slice[self.start..self.end];
}
