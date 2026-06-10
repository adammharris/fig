//! Embedded config extraction: pull a config document out of a host file
//! (e.g. YAML frontmatter inside markdown) and parse it correctly.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Language = @import("language.zig");
const Document = @import("document.zig");
const Span = @import("util/span.zig");

const Embed = @This();

const Delimiter = struct {
    tokens: []const []const u8,
    match: enum { whole_line, prefix },
};

const Archetype = struct {
    open: Delimiter,
    close: Delimiter,
    location: enum { start, end, middle },
    inner: enum { yaml, json },
};

fn archetypeOf(t: Type) Archetype {
    return switch (t) {
        .FrontmatterYaml => .{
            .open  = .{ .tokens = &.{"---"},        .match = .whole_line },
            .close = .{ .tokens = &.{ "---", "..." }, .match = .whole_line },
            .location = .start,
            .inner = .yaml,
        },
        .FrontmatterJson => .{
            .open = .{ .tokens = &.{";;;"}, .match = .whole_line },
            .close = .{ .tokens = &.{";;;"}, .match = .whole_line },
            .location = .start,
            .inner = .json,
        },
        .EndmatterYaml => .{
            .open = .{ .tokens = &.{"```endmatter"}, .match = .whole_line },
            .close = .{ .tokens = &.{"```"}, .match = .whole_line },
            .location = .end,
            .inner = .yaml,
        },
    };
}

/// An archetypal "config embedded in a host file" pattern. Each variant fixes
/// both *where* the config lives (the host's delimiter convention) and *what*
/// inner format it is — `---` fences imply YAML, by convention. This coupling
/// is deliberate: it keeps invalid (delimiter, format) combinations unspellable.
pub const Type = enum {
    /// `---` … `---`/`...` YAML frontmatter at the top of a markdown file.
    FrontmatterYaml,
    /// `;;;` … `;;;` JSON frontmatter at the top of a markdown file.
    FrontmatterJson,
    /// For Stephen Deken. YAML in an ending codeblock.
    EndmatterYaml,
};

/// A located region, in *outer-source* byte coordinates. The fence spans are
/// retained so an editor can splice a replacement into `content` while leaving
/// everything else byte-identical.
pub const Region = struct {
    open_fence: Span,
    content: Span,
    close_fence: Span,
};

/// Extraction result. `source` is the borrowed *outer* file; `region` indexes
/// into it. `document`'s node spans are relative to `region.content` — call
/// `outerSpan` to lift them back into outer-file coordinates.
pub const Embedded = struct {
    source: []const u8,
    type: Type,
    region: Region,
    document: Document,

    pub fn deinit(self: Embedded, allocator: Allocator) void {
        self.document.deinit(allocator);
    }

    pub fn outerSpan(self: Embedded, s: Span) Span {
        const base = self.region.content.start;
        return Span.init(s.start + base, s.end + base);
    }
};

pub const Error = error{
    /// No region of this archetype exists (plain markdown, no frontmatter).
    /// Distinct from a region that exists but is malformed.
    NotFound,
    /// An opening delimiter with no matching close.
    Unterminated,
};

/// Locate + parse the embedded document of type `t` in `source`.
pub fn extract(allocator: Allocator, source: []const u8, t: Type) !Embedded {
    const region = try locate(source, archetypeOf(t));
    const document = try parseSpan(allocator, source, region.content, t);
    return .{ .source = source, .type = t, .region = region, .document = document };
}

/// Parse an explicit content span as `t`'s inner format, no host scanning.
pub fn parseSpan(allocator: Allocator, source: []const u8, content: Span, t: Type) !Document {
    const slice = Span.of(u8, content, source);
    return switch (archetypeOf(t).inner) {
        .yaml => blk: {
            var parser = Language.YAML.Parser{ .allocator = allocator };
            break :blk Language.YAML.parse(&parser, slice, Language.YAML.default_type);
        },
        .json => blk: {
            var parser = Language.JSON.Parser{ .allocator = allocator };
            break :blk Language.JSON.parse(&parser, slice, Language.JSON.default_type);
        },
    };
}

// --- markdown frontmatter locator ---------------------------------------

fn locate(source: []const u8, a: Archetype) Error!Region {
    var i: usize = 0;
    if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) i += 3; // UTF-8 BOM

    const open = if (a.location == .start)
        matchDelim(source, i, a.open) orelse return Error.NotFound
    else
        scanForDelim(source, i, a.open) orelse return Error.NotFound;

    var line = open.end;
    while (line < source.len) {
        if (matchDelim(source, line, a.close)) |close|
            return .{ .open_fence = open,
                      .content = Span.init(open.end, close.start),
                      .close_fence = close };
        line = lineEnd(source, line);
    }
    return Error.Unterminated;
}

fn lineEnd(source: []const u8, from: usize) usize {
    return if (std.mem.findScalarPos(u8, source, from, '\n')) |nl| nl + 1 else source.len;
}

/// One line vs a Delimiter; returns the line's span (incl. newline) or null.
fn matchDelim(source: []const u8, start: usize, d: Delimiter) ?Span {
    const eol = lineEnd(source, start);
    const line = std.mem.trimEnd(u8, source[start..eol], "\r\n");
    const trimmed = std.mem.trimEnd(u8, line, " \t");
    for (d.tokens) |tok| {
        const ok = switch (d.match) {
            .whole_line => std.mem.eql(u8, trimmed, tok),
            .prefix => std.mem.startsWith(u8, line, tok),
        };
        if (ok) return Span.init(start, eol);
    }
    return null;
}

/// Scan forward line-by-line for the first line matching `d`; null at EOF.
fn scanForDelim(source: []const u8, start: usize, d: Delimiter) ?Span {
    var line = start;
    while (line < source.len) {
        if (matchDelim(source, line, d)) |span| return span;
        line = lineEnd(source, line);
    }
    return null;
}