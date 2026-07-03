//! fig-lsp — a minimal Language Server for the fig authoring dialect.
//!
//! This is a thin shell around the Zig parser (`src/languages/fig/parser.zig`). It speaks
//! LSP JSON-RPC over stdio and, for now, does exactly one job well: on every
//! open/change it re-parses the document and publishes the parser's teaching
//! diagnostics (DESIGN.md's "every diagnostic names the fix") as squiggles.
//!
//! The parser stays the single source of truth — the Tree-sitter grammar under
//! editors/ colors the text, this server is what makes the editor understand it.
//! Formatting (`fig fmt`), hover, and completion are deliberately out of scope
//! for this first cut; the didChange→parse→publish loop is the spine everything
//! else hangs off of.

const std = @import("std");
const fig = @import("fig");

const Io = std.Io;
const Parser = fig.Language.FIG.Parser;

const max_body = 64 * 1024 * 1024; // hard cap on one JSON-RPC message

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdin = Io.File.stdin().reader(io, &stdin_buf);
    const r = &stdin.interface;

    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout.interface;

    var server = Server{ .gpa = gpa, .w = w };
    defer server.deinit();

    // One arena reused per message: parse JSON + build the reply in it, then
    // reset. Anything that must outlive the message (the doc store) is duped
    // into `gpa` instead.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    while (true) {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();

        // Any read error (EOF, broken pipe, …) means the client is gone — exit.
        const body = (readMessage(r, a) catch break) orelse break;

        const parsed = std.json.parseFromSlice(std.json.Value, a, body, .{}) catch continue;
        server.handle(a, parsed.value) catch |err| switch (err) {
            error.Exit => break,
            else => return err,
        };
    }
}

/// Read one `Content-Length`-framed JSON-RPC message. Returns the raw body
/// bytes (owned by `a`), or null on a clean end-of-headers EOF.
fn readMessage(r: *Io.Reader, a: std.mem.Allocator) !?[]u8 {
    var content_length: ?usize = null;
    while (true) {
        const line = r.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => if (content_length == null) return null else return error.EndOfStream,
            else => return err,
        };
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (trimmed.len == 0) break; // blank line ends the header block
        if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
            const num = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, num, 10) catch null;
        }
        // Other headers (Content-Type, …) are ignored.
    }
    const len = content_length orelse return error.EndOfStream;
    if (len > max_body) return error.EndOfStream;
    const body = try a.alloc(u8, len);
    try r.readSliceAll(body);
    return body;
}

const Server = struct {
    gpa: std.mem.Allocator,
    w: *Io.Writer,
    /// uri -> latest full text. Both key and value owned by `gpa`.
    docs: std.StringHashMapUnmanaged([]u8) = .empty,

    fn deinit(self: *Server) void {
        var it = self.docs.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.docs.deinit(self.gpa);
    }

    fn handle(self: *Server, a: std.mem.Allocator, msg: std.json.Value) !void {
        if (msg != .object) return;
        const obj = msg.object;
        const method = (obj.get("method") orelse return).string;
        const id = obj.get("id");
        const params = obj.get("params");

        if (std.mem.eql(u8, method, "initialize")) {
            try self.respondInitialize(id.?);
        } else if (std.mem.eql(u8, method, "shutdown")) {
            try self.respondNull(id.?);
        } else if (std.mem.eql(u8, method, "exit")) {
            return error.Exit;
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try self.didOpen(a, params);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try self.didChange(a, params);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            try self.didClose(params);
        } else if (id) |req_id| {
            // Any other REQUEST (has an id) must get a reply so the client
            // isn't left hanging; notifications we don't know are ignored.
            try self.respondNull(req_id);
        }
    }

    // ─── lifecycle ───

    fn respondInitialize(self: *Server, id: std.json.Value) !void {
        // textDocumentSync = 1 (Full): each didChange carries the whole document.
        var buf = std.Io.Writer.Allocating.init(self.gpa);
        defer buf.deinit();
        const b = &buf.writer;
        try b.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try writeId(b, id);
        try b.writeAll(",\"result\":{\"capabilities\":{\"textDocumentSync\":1}," ++
            "\"serverInfo\":{\"name\":\"fig-lsp\",\"version\":\"0.0.1\"}}}");
        try self.send(buf.written());
    }

    fn respondNull(self: *Server, id: std.json.Value) !void {
        var buf = std.Io.Writer.Allocating.init(self.gpa);
        defer buf.deinit();
        const b = &buf.writer;
        try b.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try writeId(b, id);
        try b.writeAll(",\"result\":null}");
        try self.send(buf.written());
    }

    // ─── text sync ───

    fn didOpen(self: *Server, a: std.mem.Allocator, params: ?std.json.Value) !void {
        const p = (params orelse return).object;
        const td = (p.get("textDocument") orelse return).object;
        const uri = (td.get("uri") orelse return).string;
        const text = (td.get("text") orelse return).string;
        try self.store(uri, text);
        try self.publish(a, uri, text);
    }

    fn didChange(self: *Server, a: std.mem.Allocator, params: ?std.json.Value) !void {
        const p = (params orelse return).object;
        const td = (p.get("textDocument") orelse return).object;
        const uri = (td.get("uri") orelse return).string;
        const changes = (p.get("contentChanges") orelse return).array;
        if (changes.items.len == 0) return;
        // Full sync: the last change holds the entire new document.
        const text = changes.items[changes.items.len - 1].object.get("text").?.string;
        try self.store(uri, text);
        try self.publish(a, uri, text);
    }

    fn didClose(self: *Server, params: ?std.json.Value) !void {
        const p = (params orelse return).object;
        const td = (p.get("textDocument") orelse return).object;
        const uri = (td.get("uri") orelse return).string;
        if (self.docs.fetchRemove(uri)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value);
        }
        // Clear any squiggles the client is still showing for this file.
        try self.publishEmpty(uri);
    }

    /// Replace the stored text for `uri` (keys/values owned by `gpa`).
    fn store(self: *Server, uri: []const u8, text: []const u8) !void {
        const gop = try self.docs.getOrPut(self.gpa, uri);
        if (gop.found_existing) {
            self.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.gpa.dupe(u8, uri);
        }
        gop.value_ptr.* = try self.gpa.dupe(u8, text);
    }

    // ─── diagnostics ───

    /// Parse `text`; publish the parser's report — the hard error (if any) as
    /// severity 1 (Error) plus the authoring warnings as severity 2 (Warning),
    /// or clear everything on a clean, lint-free parse. Warnings collected
    /// before a failure still publish alongside the error.
    fn publish(self: *Server, a: std.mem.Allocator, uri: []const u8, text: []const u8) !void {
        const report = diagnose(a, text);

        var buf = std.Io.Writer.Allocating.init(self.gpa);
        defer buf.deinit();
        const b = &buf.writer;

        try b.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":");
        try writeJsonString(b, uri);
        try b.writeAll(",\"diagnostics\":[");
        var first = true;
        if (report.diag) |d| {
            try writeDiagnostic(b, text, d.offset, 1, @errorName(d.code), Parser.describe(d.code));
            first = false;
        }
        for (report.warnings) |wn| {
            if (!first) try b.writeAll(",");
            first = false;
            try writeDiagnostic(b, text, wn.offset, 2, @tagName(wn.code), Parser.Warning.describeWarning(wn.code));
        }
        try b.writeAll("]}}");
        try self.send(buf.written());
    }

    fn publishEmpty(self: *Server, uri: []const u8) !void {
        var buf = std.Io.Writer.Allocating.init(self.gpa);
        defer buf.deinit();
        const b = &buf.writer;
        try b.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":");
        try writeJsonString(b, uri);
        try b.writeAll(",\"diagnostics\":[]}}");
        try self.send(buf.written());
    }

    // ─── framing ───

    fn send(self: *Server, body: []const u8) !void {
        try self.w.print("Content-Length: {d}\r\n\r\n", .{body.len});
        try self.w.writeAll(body);
        try self.w.flush();
    }
};

/// Run the parser purely for its report (error diagnostic + warnings). The AST
/// is thrown away (this is a validity check), so everything — including the
/// warning list — lands in the caller's per-message arena `a`.
fn diagnose(a: std.mem.Allocator, text: []const u8) Parser.Report {
    var report: Parser.Report = .{};
    _ = Parser.parseWithReport(a, text, fig.Language.FIG.default_type, &report) catch {};
    return report;
}

// ─── position math (LSP positions are 0-based, UTF-16 code units) ───

const Position = struct { line: usize, character: usize };
const Range = struct { start: Position, end: Position };

fn utf16Len(bytes: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < bytes.len) {
        const seq = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            i += 1;
            n += 1;
            continue;
        };
        if (i + seq > bytes.len) break;
        const cp = std.unicode.utf8Decode(bytes[i .. i + seq]) catch {
            i += 1;
            n += 1;
            continue;
        };
        n += if (cp >= 0x10000) @as(usize, 2) else 1;
        i += seq;
    }
    return n;
}

fn positionAt(source: []const u8, at: usize) Position {
    var line: usize = 0;
    var line_start: usize = 0;
    for (source[0..at], 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .character = utf16Len(source[line_start..at]) };
}

/// A range covering the offending token: from the failure offset to end-of-line.
/// Mirrors `Diagnostic.locate`'s "resting past a newline means the previous
/// line" backtrack so the squiggle lands on the line the author sees.
fn errorRange(source: []const u8, offset: usize) Range {
    var at = @min(offset, source.len);
    if (at > 0 and source[at - 1] == '\n') at -= 1;
    const line_end = std.mem.indexOfScalarPos(u8, source, at, '\n') orelse source.len;
    var start = positionAt(source, at);
    const end = positionAt(source, line_end);
    // Guarantee a non-empty range so every client renders something.
    if (start.line == end.line and start.character == end.character) {
        if (start.character > 0) start.character -= 1;
    }
    return .{ .start = start, .end = end };
}

// ─── tiny JSON writers (output only; input uses std.json) ───

/// One LSP Diagnostic object: range (via `errorRange`), severity (1 Error /
/// 2 Warning), code, and the parser's teaching message.
fn writeDiagnostic(w: *Io.Writer, source: []const u8, offset: usize, severity: u8, code: []const u8, message: []const u8) !void {
    try w.writeAll("{\"range\":");
    try writeRange(w, errorRange(source, offset));
    try w.print(",\"severity\":{d},\"source\":\"fig\",\"code\":", .{severity});
    try writeJsonString(w, code);
    try w.writeAll(",\"message\":");
    try writeJsonString(w, message);
    try w.writeAll("}");
}

fn writeRange(w: *Io.Writer, rng: Range) !void {
    try w.print(
        "{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ rng.start.line, rng.start.character, rng.end.line, rng.end.character },
    );
}

fn writeId(w: *Io.Writer, id: std.json.Value) !void {
    switch (id) {
        .integer => |n| try w.print("{d}", .{n}),
        .string => |s| try writeJsonString(w, s),
        else => try w.writeAll("null"),
    }
}

fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0C => try w.writeAll("\\f"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}
