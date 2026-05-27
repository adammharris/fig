//! Helper functions for parsing Unicode sequences.
const Unicode = @This();
pub fn isHighSurrogate(p: u21) bool {
    return p >= 0xD800 and p <= 0xDBFF;
}
pub fn isLowSurrogate(p: u21) bool {
    return p >= 0xDC00 and p <= 0xDFFF;
}
