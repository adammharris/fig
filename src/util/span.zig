pub const Span = @This();

start: usize,
end: usize,

pub fn init(start: usize, end: usize) Span {
    return .{ .start = start, .end = end };
}

pub fn len(self: Span) usize {
    return self.end - self.start;
}

pub fn equals(self: Span, other: Span) bool {
    return self.start == other.start and self.end == other.end;
}
