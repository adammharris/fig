//! Main entrypoint for `fig` CLI
//! Design:
//! fig <action> [action options] [--flags]

const std = @import("std");
const fig = @import("fig");
const build_options = @import("build_options");
const Io = std.Io;

const title_string = "\n=========\n   FIG\n=========\n\n";
const version = "0.0.0-alpha";

/// Currently, `fig` CLI only supports up to 10MB files.
const max_size = Io.Limit.limited(10 * 1024 * 1024);
const Format = enum { json, jsonc, json5, yaml, yml, toml, zon, xml, native };

const CliAction = enum {
    help,
    version,
    edit,
    get,
};

const CliActionOptions = union(CliAction) {
    help: struct {
        requested_help: bool = false,
    },
    version: struct {},
    edit: struct {
        file: []const u8,
        path: []fig.AST.PathSegment,
        replacement: []const u8,
        key: bool = false,
        requested_help: bool = false,
        format: Format,
        /// When set, `file` is a host document (e.g. markdown) and edits apply
        /// to the embedded config of this archetype, spliced back in place.
        embed: ?fig.Embed.Type = null,
    },
    get: struct {
        file: []const u8,
        path: ?[]fig.AST.PathSegment = null,
        from: Format,
        to: Format,
        requested_help: bool = false,
        /// When converting YAML to another format, drop unknown/custom tags
        /// instead of erroring on them. Has no effect on parsing or YAML→YAML.
        lax_tags: bool = false,
        /// Lossless conversion: preserve values the target format can't represent
        /// natively (a null in TOML, a TOML datetime in JSON, …) through a `$fig`
        /// envelope, and reconstruct any such envelope found in the input. Gates
        /// both the encode (output) and decode (input) passes; default is lossy.
        lossless: bool = false,
        /// When set, the input is extracted from a host document of this
        /// archetype (e.g. YAML frontmatter inside markdown) before parsing.
        embed: ?fig.Embed.Type = null,
        /// Output style. `--compact` clears `pretty` for a single-line render;
        /// `--indent N` sets the JSON indent width. Honored by JSON (pretty +
        /// indent) and ZON (pretty only); YAML/TOML render with their own layout.
        serialize: fig.AST.SerializeOptions = .{},
        /// Suppress the lossy-conversion warnings normally written to stderr.
        quiet: bool = false,
        /// Treat any lossy conversion as an error: print the warnings, then exit
        /// non-zero without writing output.
        strict: bool = false,
    },
};

const CliConfig = struct {
    action: CliAction = .help,
    options: CliActionOptions = .{ .help = .{} },
    binary_name: []const u8 = "fig",
    requested_help: bool = false,
};

const Help = struct {
    fn general(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage:
            \\  {s} <action> [action options] --[flags]
            \\Possible actions:
            \\  help: prints this text (default action)
            \\  version: prints version number
            \\  edit: edits part of file
            \\  get: print a file or a specific part of a file to stdout
            \\
            \\For information on action options, pass --help or -h
            \\to the action you would like to learn about.
            \\
        , .{binary_name});
        try term.writer.flush();
    }

    fn edit(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage: {s} edit [--key] <file> <path> <replacement>
            \\  --key: edit the object key at path instead of the value
            \\  path format: dot syntax for keys, bracket syntax for indices
            \\    example: school.class[0].student[3]
            \\  .md/.markdown files: edits the YAML frontmatter in place
            \\
        , .{binary_name});
        try term.writer.flush();
    }

    fn get(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage: {s} get [--input json|json5|yaml|toml|zon|native] [--output json|json5|yaml|toml|zon|native] <file> [path]
            \\  -i, --input: input format of file (defaults to matching the file extension)
            \\  -o, --output:   output format (defaults to the input format)
            \\  native ("fig"): the AST's 1:1 canonical text encoding (.fig files);
            \\    usable as input or output, e.g. to inspect how any document parses.
            \\  --compact: single-line output with minimal whitespace (JSON, JSON5, ZON).
            \\  --pretty: multi-line, indented output (the default).
            \\  --indent N: spaces per indent level for pretty JSON (default 2).
            \\  --strip-comments: drop comments instead of carrying them across formats.
            \\  --lossless: preserve values the target can't represent natively
            \\    (e.g. a null in TOML, a TOML datetime in JSON) via a $fig
            \\    envelope, and reconstruct any such envelope in the input.
            \\    --lossy (the default) emits clean, idiomatic output instead.
            \\  -q, --quiet: suppress the lossy-conversion warnings on stderr.
            \\  --strict: treat any lossy conversion as an error (exit non-zero).
            \\  path format: dot syntax for keys, bracket syntax for indices
            \\    example: school.class[0].student[3]
            \\  .md/.markdown files: reads the YAML frontmatter
            \\
        , .{binary_name});
        try term.writer.flush();
    }
};

pub fn main(init: std.process.Init) !void {
    // Respected environment variables
    const NO_COLOR = init.environ_map.contains("NO_COLOR");
    const CLICOLOR_FORCE = init.environ_map.contains("CLICOLOR_FORCE");

    // Setting up arena allocator, io, terminal/stderr writer
    const io = init.io;
    const stderr_color_mode = try Io.Terminal.Mode.detect(io, Io.File.stderr(), NO_COLOR, CLICOLOR_FORCE);
    const stdout_color_mode = try Io.Terminal.Mode.detect(io, Io.File.stdout(), NO_COLOR, CLICOLOR_FORCE);
    var stdout_buf: [512]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buf);
    var stderr = Io.File.stderr().writer(io, &stderr_buf);
    var stderr_terminal = std.Io.Terminal{ .writer = &stderr.interface, .mode = stderr_color_mode };
    var stdout_terminal = std.Io.Terminal{ .writer = &stdout.interface, .mode = stdout_color_mode };

    // Accessing command line arguments:
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    const config = parseConfig(init.arena.allocator(), &args) catch |err| switch (err) {
        ArgError.UnsupportedFileFormat => {
            try stderr_terminal.writer.print("Try using `--input <format>` to manually specify a format.\n", .{});
            comptime var supported_formats: []const u8 = "";
            inline for (@typeInfo(Format).@"enum".fields) |field|
                supported_formats = supported_formats ++ std.fmt.comptimePrint("\n- {s}", .{field.name});
            try stderr_terminal.writer.print("Supported formats:{s}\n", .{supported_formats});
            try stderr_terminal.writer.flush();
            std.process.exit(2);
        },
        ArgError.MissingEditArgument => {
            try Help.edit(&stderr_terminal, "fig");
            std.process.exit(2);
        },
        ArgError.MissingGetArgument => {
            try Help.get(&stderr_terminal, "fig");
            std.process.exit(2);
        },
        else => return err,
    };

    // Now, act on config
    return switch (config.action) {
        .help => {
            try stderr_terminal.writer.print(title_string, .{});
            try Help.general(&stderr_terminal, config.binary_name);
        },
        .version => {
            try stdout_terminal.writer.print("{s}\n", .{version});
            try stdout_terminal.writer.flush();
        },
        .edit => {
            const opts = config.options.edit;
            if (opts.requested_help) {
                try Help.edit(&stdout_terminal, config.binary_name);
                return;
            }
            const input = try getInput(io, opts.file, .read_write);
            defer if (!std.mem.eql(u8, opts.file, "-")) input.close(io);

            if (opts.embed) |embed_type| {
                try editEmbedded(init.arena.allocator(), io, input, embed_type, opts.path, opts.replacement, opts.key);
            } else switch (opts.format) {
                .json, .jsonc => {
                    const replacement = try std.fmt.allocPrint(init.arena.allocator(), "\"{s}\"", .{opts.replacement});
                    try editDocument(fig.Language.JSON, init.arena.allocator(), io, input, opts.path, replacement, opts.key);
                },
                .yaml, .yml => if (comptime build_options.lang_yaml) {
                    try editDocument(fig.Language.YAML, init.arena.allocator(), io, input, opts.path, opts.replacement, opts.key);
                } else return error.FormatDisabled,
                // TOML value/key replacement: a value or key node has a tight,
                // contiguous span (the parser's node_spans point at the original
                // source bytes), so the generic span-splice editor handles it
                // even when the owning table is assembled from scattered headers.
                // The replacement is taken verbatim as a TOML literal, like YAML
                // and ZON. (Structural inserts/deletes that must place text
                // relative to a scattered table are still unsupported.)
                .toml => if (comptime build_options.lang_toml)
                    try editDocument(fig.Language.TOML, init.arena.allocator(), io, input, opts.path, opts.replacement, opts.key)
                else
                    return error.FormatDisabled,
                // ZON edits take the replacement verbatim (a literal ZON value),
                // like YAML — the editor splices and reparses it.
                .zon => if (comptime build_options.lang_zon)
                    try editDocument(fig.Language.ZON, init.arena.allocator(), io, input, opts.path, opts.replacement, opts.key)
                else
                    return error.FormatDisabled,
                // XML is reader-only: no in-place editor yet.
                .xml => return error.UnsupportedXmlEdit,
                // JSON5 is read/serialize only so far; comment-preserving
                // in-place editing of it is not wired yet.
                .json5 => return error.UnsupportedJson5Edit,
                // The native format is a parse/print pair with no span-splicing
                // editor; convert via `get` instead of editing in place.
                .native => return error.UnsupportedNativeEdit,
            }
        },
        .get => {
            const opts = config.options.get;
            if (opts.requested_help) {
                try Help.get(&stdout_terminal, config.binary_name);
                return;
            }
            // XML is reader-only: it can be a `--from` source but not a `--to`
            // target. Reject early so the serialize switches below stay total.
            if (opts.to == .xml) {
                try stderr_terminal.writer.print("error: XML output is not yet supported (reader-only); XML may only be a `--from` source.\n", .{});
                try stderr_terminal.writer.flush();
                return error.UnsupportedOutputFormat;
            }
            const input = try getInput(io, opts.file, .read_only);
            defer if (!std.mem.eql(u8, opts.file, "-")) input.close(io);

            const doc = if (opts.embed) |embed_type|
                try parseEmbeddedFromFile(init.arena.allocator(), io, input, embed_type)
            else switch (opts.from) {
                .json => try parseFromFile(fig.Language.JSON, init.arena.allocator(), io, input),
                // JSONC shares JSON's grammar plus `//` and `/* */` comments, so
                // it needs the dialect passed through (the default is strict JSON).
                .jsonc => try parseJsonTypeFromFile(init.arena.allocator(), io, input, .JSONC),
                .json5 => try parseJsonTypeFromFile(init.arena.allocator(), io, input, .JSON5),
                .yaml, .yml => if (comptime build_options.lang_yaml) try parseFromFile(fig.Language.YAML, init.arena.allocator(), io, input) else return error.FormatDisabled,
                .toml => if (comptime build_options.lang_toml) try parseFromFile(fig.Language.TOML, init.arena.allocator(), io, input) else return error.FormatDisabled,
                .zon => if (comptime build_options.lang_zon) try parseFromFile(fig.Language.ZON, init.arena.allocator(), io, input) else return error.FormatDisabled,
                .xml => if (comptime build_options.lang_xml) try parseFromFile(fig.Language.XML, init.arena.allocator(), io, input) else return error.FormatDisabled,
                .native => try parseNativeFromFile(init.arena.allocator(), io, input),
            };

            // Converting YAML to a non-YAML format resolves the reference layer
            // first (aliases → copies, merges → flattened, tags applied/dropped).
            // YAML→YAML keeps it intact for round-trip; JSON never has it.
            const src_is_yaml = opts.from == .yaml or opts.from == .yml;
            const dst_is_yaml = opts.to == .yaml or opts.to == .yml;
            const base_ast: *const fig.AST = if (src_is_yaml and !dst_is_yaml) blk: {
                // Reachable only when the source is YAML, so YAML is compiled in;
                // the comptime guard keeps `Language.YAML` out of the gated build.
                if (comptime build_options.lang_yaml) {
                    const mode: fig.Language.YAML.TagMode = if (opts.lax_tags) .lax else .strict;
                    const mat = try init.arena.allocator().create(fig.AST);
                    mat.* = try fig.Language.YAML.materialize(init.arena.allocator(), &doc.ast, mode);
                    break :blk mat;
                } else unreachable;
            } else &doc.ast;

            // Lossless mode: decode any `$fig` envelopes in the input back to
            // their real node kinds, then re-encode for the target format. Skipped
            // for YAML→YAML, whose reference layer (anchors/tags) lives in
            // side-tables the core-AST passes would strip — and which round-trips
            // losslessly already. The passes operate on a core AST, so any
            // non-YAML source (or a materialized YAML source) is safe.
            const ast: *const fig.AST = if (opts.lossless and !(src_is_yaml and dst_is_yaml)) blk: {
                const maybe_target: ?fig.Lossless.Target = switch (opts.to) {
                    // JSON5 reuses the JSON envelope target. It could hold
                    // Infinity/NaN natively, so this is conservative (those ride
                    // in a `$fig` envelope) but still fully lossless.
                    .json, .jsonc, .json5 => .json,
                    .yaml, .yml => .yaml,
                    .toml => .toml,
                    .zon => .zon,
                    // Native encodes every node kind directly, so no envelope is
                    // needed on output — only decode envelopes found in the input.
                    .native => null,
                    .xml => unreachable, // rejected up front (reader-only)
                };
                const decoded = try init.arena.allocator().create(fig.AST);
                decoded.* = try fig.Lossless.decode(init.arena.allocator(), base_ast);
                const target = maybe_target orelse break :blk decoded;
                const encoded = try init.arena.allocator().create(fig.AST);
                encoded.* = try fig.Lossless.encode(init.arena.allocator(), decoded, target);
                break :blk encoded;
            } else base_ast;

            const node_id = if (opts.path) |p| (try ast.getValByPath(p)).id else ast.root;

            const target: fig.AST.SerializeFormat = switch (opts.to) {
                .json => .json,
                .jsonc => .jsonc,
                .json5 => .json5,
                .yaml, .yml => .yaml,
                .toml => .toml,
                .zon => .zon,
                .native => .native,
                .xml => unreachable, // rejected up front (reader-only)
            };

            // Surface everything the conversion would silently lose (comments
            // dropped/degraded, values dropped/degraded) — unless `--quiet`. The
            // pass is read-only and runs on the AST as it will be printed: under
            // `--lossless` the lossy nodes are already enveloped, so no value
            // warnings fire. `--strict` turns any warning into a hard failure.
            if (!opts.quiet or opts.strict) {
                const warnings = try fig.Diagnostics.analyze(init.arena.allocator(), ast, node_id, target, .{
                    .pretty = opts.serialize.pretty,
                    .strip_comments = opts.serialize.strip_comments,
                    .lossless = opts.lossless,
                });
                // The CLI only surfaces losses the FORMAT forced. A loss the user
                // explicitly asked for (e.g. `--strip-comments`) carries
                // `explicit_option` and is not surprising, so it neither warns nor
                // trips `--strict` — it just rides through on the warning layer for
                // a library consumer that wants it.
                var surfaced: usize = 0;
                for (warnings) |w| {
                    if (w.cause != .format_limitation) continue;
                    surfaced += 1;
                    if (!opts.quiet) {
                        try stderr_terminal.setColor(.red);
                        try stderr_terminal.writer.writeAll("warning: ");
                        try stderr_terminal.setColor(.reset);
                        try w.render(stderr_terminal.writer, target);
                        try stderr_terminal.writer.writeByte('\n');
                    }
                }
                if (!opts.quiet) try stderr_terminal.writer.flush();
                if (opts.strict and surfaced > 0) {
                    try stderr_terminal.writer.print("error: {d} lossy conversion warning(s); --strict aborts.\n", .{surfaced});
                    try stderr_terminal.writer.flush();
                    std.process.exit(1);
                }
            }

            if (target == .toml and !opts.lossless) {
                // TOML has no null. In lossy mode, rather than the printer
                // aborting mid-document on one, strip unrepresentable values up
                // front so output stays valid and complete (the warnings above
                // already reported them). `lossyStrip` re-roots at `node_id`, so
                // the result serializes whole.
                const result = try fig.Lossless.lossyStrip(init.arena.allocator(), ast, node_id, .toml);
                if (result.ast) |stripped| {
                    try stripped.serializeWith(stdout_terminal.writer, .toml, opts.serialize);
                }
            } else if (opts.path == null) {
                try ast.serializeWith(stdout_terminal.writer, target, opts.serialize);
            } else {
                try ast.serializeNodeWith(stdout_terminal.writer, target, node_id, opts.serialize);
            }
            try stdout_terminal.writer.flush();
        },
    };
}

fn readAll(allocator: std.mem.Allocator, io: Io, file: Io.File) ![]u8 {
    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    return file_reader.interface.allocRemaining(allocator, max_size);
}

fn parseFromFile(comptime Lang: type, allocator: std.mem.Allocator, io: Io, file: Io.File) !fig.Document {
    const content = try readAll(allocator, io, file);
    return try Lang.Parser.parse(allocator, content, Lang.default_type);
}

/// Parse a native ("fig") document. The native parser isn't a `Language` (it has
/// no `Type`/`default_type` — its grammar is fixed), so it needs its own helper.
fn parseNativeFromFile(allocator: std.mem.Allocator, io: Io, file: Io.File) !fig.Document {
    const content = try readAll(allocator, io, file);
    return try fig.Native.parse(allocator, content);
}

/// Parse a JSON-family file with an explicit dialect (the JSON `Language`'s
/// `default_type` is plain JSON, so JSON5 input needs the type passed through).
fn parseJsonTypeFromFile(allocator: std.mem.Allocator, io: Io, file: Io.File, json_type: fig.Language.JSON.Type) !fig.Document {
    const content = try readAll(allocator, io, file);
    return try fig.Language.JSON.Parser.parse(allocator, content, json_type);
}

/// Extract the embedded config of `embed_type` from a host file and parse it.
/// The returned document's node spans are relative to the embedded region.
fn parseEmbeddedFromFile(allocator: std.mem.Allocator, io: Io, file: Io.File, embed_type: fig.Embed.Type) !fig.Document {
    const content = try readAll(allocator, io, file);
    const embedded = try fig.Embed.extract(allocator, content, embed_type);
    return embedded.document;
}

/// Edit `content` (a complete document) and return the new bytes.
fn editSlice(
    comptime Lang: type,
    allocator: std.mem.Allocator,
    content: []const u8,
    path: []fig.AST.PathSegment,
    replacement: []const u8,
    edit_key: bool,
) ![]u8 {
    var editor: fig.Editor(Lang) = .{ .allocator = allocator };
    try editor.init(content);
    defer editor.deinit();
    if (edit_key) {
        try editor.replaceKeyAtPath(path, replacement);
    } else {
        try editor.replaceValAtPath(path, replacement);
    }
    return allocator.dupe(u8, editor.source.items);
}

fn editDocument(
    comptime Lang: type,
    allocator: std.mem.Allocator,
    io: Io,
    file: Io.File,
    path: []fig.AST.PathSegment,
    replacement: []const u8,
    edit_key: bool,
) !void {
    const content = try readAll(allocator, io, file);
    defer allocator.free(content);

    const edited = try editSlice(Lang, allocator, content, path, replacement, edit_key);
    try file.writePositionalAll(io, edited, 0);
    try file.setLength(io, edited.len);
}

/// Edit the embedded config of a host file in place: extract the region, edit
/// only that slice as its inner format, then splice it back between the
/// retained fences so the rest of the host file is byte-identical.
fn editEmbedded(
    allocator: std.mem.Allocator,
    io: Io,
    file: Io.File,
    embed_type: fig.Embed.Type,
    path: []fig.AST.PathSegment,
    replacement: []const u8,
    edit_key: bool,
) !void {
    const content = try readAll(allocator, io, file);
    defer allocator.free(content);

    const embedded = try fig.Embed.extract(allocator, content, embed_type);
    defer embedded.deinit(allocator);
    const region = embedded.region;
    const inner = content[region.content.start..region.content.end];

    const edited_inner = switch (embed_type) {
        .FrontmatterYaml, .EndmatterYaml => if (comptime build_options.lang_yaml)
            try editSlice(fig.Language.YAML, allocator, inner, path, replacement, edit_key)
        else
            return error.FormatDisabled,
        .FrontmatterJson => blk: {
            const quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{replacement});
            break :blk try editSlice(fig.Language.JSON, allocator, inner, path, quoted, edit_key);
        },
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, content[0..region.content.start]);
    try out.appendSlice(allocator, edited_inner);
    try out.appendSlice(allocator, content[region.content.end..]);

    try file.writePositionalAll(io, out.items, 0);
    try file.setLength(io, out.items.len);
}

fn getInput(io: Io, file_path: ?[]const u8, mode: std.Io.Dir.OpenFileOptions.Mode) !Io.File {
    const log = std.log.scoped(.getInput);
    // Get input file descriptor
    if (file_path) |fp| {
        if (std.mem.eql(u8, fp, "-")) {
            return Io.File.stdin();
        } else {
            // Get current working directory
            var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const cwd_path = try std.process.currentPath(io, &cwd_buf);
            const cwd = cwd_buf[0..cwd_path];
            log.debug("opening {s} in {s}", .{ fp, cwd });

            // Open directory (scope to files in this directory)
            const dir = try std.Io.Dir.cwd().openDir(io, cwd, .{});
            defer dir.close(io);

            // Open file, handle if it doesn't exist
            return dir.openFile(io, fp, .{ .mode = mode });
        }
    } else {
        log.err("No file provided.", .{});
        return error.MissingArgument;
    }
}

fn parsePath(allocator: std.mem.Allocator, path: []const u8) ![]fig.AST.PathSegment {
    const log = std.log.scoped(.parsePath);
    var path_in_progress: std.ArrayList(fig.AST.PathSegment) = .empty;
    var i: usize = 0;
    while (i < path.len) {
        switch (path[i]) {
            '.' => {
                // Dot is a separator. Else branch parses the key.
                i += 1;
            },
            '[' => {
                // Skip open bracket
                const start = i + 1;
                i = start;
                // Loop until end or close bracket
                while (i < path.len and path[i] != ']') : (i += 1) {}
                if (i >= path.len or i == start) return error.InvalidPath;

                // Add number to path_in_progress
                log.debug("number: {s}", .{path[start..i]});
                try path_in_progress.append(allocator, .{ .index = try std.fmt.parseInt(usize, path[start..i], 10) });
                // Skip close bracket
                i += 1;
            },
            else => {
                const start = i;
                // Loop until a dot or open bracket
                while (i < path.len and path[i] != '.' and path[i] != '[') : (i += 1) {}
                if (i == start) return ArgError.InvalidPath;
                const key = path[start..i];

                log.debug("key: {s}", .{key});
                try path_in_progress.append(allocator, .{ .key = key });
            },
        }
    }
    return path_in_progress.toOwnedSlice(allocator);
}

/// Result of mapping a file extension to a parse strategy. `embed` is non-null
/// when the file is a host document whose config lives in an embedded region;
/// `format` then describes that region's inner format.
const Detected = struct {
    format: Format,
    embed: ?fig.Embed.Type = null,
};

fn detectLanguageFromFileEnding(file_path: []const u8) ArgError!Detected {
    const dot = std.mem.findLast(u8, file_path, ".");
    const ext = file_path[(dot orelse 0) + 1 .. file_path.len];

    // Markdown carries YAML frontmatter by default.
    if (std.mem.eql(u8, ext, "md") or std.mem.eql(u8, ext, "markdown")) {
        return .{ .format = .yaml, .embed = .FrontmatterYaml };
    }

    // `.fig` is the native format's file extension (`.native` maps via the enum).
    if (std.mem.eql(u8, ext, "fig")) return .{ .format = .native, .embed = null };

    const format = std.meta.stringToEnum(Format, ext) orelse {
        const recognized_file_format = if (dot) |d| file_path[d..file_path.len] else "(none)";
        std.log.scoped(.detectLanguage).err("File `{s}` had ending: {s}", .{ file_path, recognized_file_format });
        return ArgError.UnsupportedFileFormat;
    };
    return .{ .format = format, .embed = null };
}

const ArgError = error{ UnsupportedFileFormat, MissingEditArgument, MissingGetArgument, OutOfMemory, Overflow, InvalidCharacter, InvalidPath };

fn parseConfig(allocator: std.mem.Allocator, args: anytype) ArgError!CliConfig {
    const log = std.log.scoped(.parseConfig);
    var config = CliConfig{};
    config.binary_name = args.next() orelse "fig";

    const action_str = args.next() orelse {
        config.action = .help;
        config.options = .{ .help = .{} };
        return config;
    };

    if (std.mem.eql(u8, action_str, "help") or std.mem.eql(u8, action_str, "--help") or std.mem.eql(u8, action_str, "-h")) {
        config.action = .help;
        config.options = .{ .help = .{ .requested_help = true } };
    } else if (std.mem.eql(u8, action_str, "version") or std.mem.eql(u8, action_str, "--version") or std.mem.eql(u8, action_str, "-v")) {
        config.action = .version;
        config.options = .{ .version = .{} };
    } else if (std.mem.eql(u8, action_str, "edit") or std.mem.eql(u8, action_str, "e")) {
        config.action = .edit;

        var edit_key = false;
        var file_path_arg = args.next();
        if (file_path_arg) |arg| {
            if (std.mem.eql(u8, arg, "--key")) {
                edit_key = true;
                file_path_arg = args.next();
            }
        }
        const file_path = file_path_arg orelse {
            log.err("No file provided.\n", .{});
            return ArgError.MissingEditArgument;
        };

        const requested_help = std.mem.eql(u8, file_path, "--help") or std.mem.eql(u8, file_path, "-h");

        var path: []fig.AST.PathSegment = &.{};
        var replacement: []const u8 = "";
        if (!requested_help) {
            const path_str = args.next() orelse {
                log.err("No path provided.\n", .{});
                return ArgError.MissingEditArgument;
            };
            path = try parsePath(allocator, path_str);

            replacement = args.next() orelse {
                log.err("No replacement provided.\n", .{});
                return ArgError.MissingEditArgument;
            };
        }

        const detected = try detectLanguageFromFileEnding(file_path);
        config.options = .{ .edit = .{
            .file = file_path,
            .path = path,
            .replacement = replacement,
            .key = edit_key,
            .requested_help = requested_help,
            .format = detected.format,
            .embed = detected.embed,
        } };
    } else if (std.mem.eql(u8, action_str, "get") or std.mem.eql(u8, action_str, "g")) {
        config.action = .get;

        var input_override: ?Format = null;
        var output_override: ?Format = null;
        var lax_tags = false;
        var lossless = false;
        var quiet = false;
        var strict = false;
        var serialize: fig.AST.SerializeOptions = .{};
        var positionals: std.ArrayList([]const u8) = .empty;
        defer positionals.deinit(allocator);

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--lax-tags")) {
                lax_tags = true;
            } else if (std.mem.eql(u8, arg, "--lossless")) {
                lossless = true;
            } else if (std.mem.eql(u8, arg, "--lossy")) {
                lossless = false;
            } else if (std.mem.eql(u8, arg, "--compact")) {
                serialize.pretty = false;
            } else if (std.mem.eql(u8, arg, "--pretty")) {
                serialize.pretty = true;
            } else if (std.mem.eql(u8, arg, "--strip-comments")) {
                serialize.strip_comments = true;
            } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--no-warnings")) {
                quiet = true;
            } else if (std.mem.eql(u8, arg, "--strict")) {
                strict = true;
            } else if (std.mem.eql(u8, arg, "--indent")) {
                const n = args.next() orelse {
                    log.err("Missing value after {s}\n", .{arg});
                    return ArgError.MissingGetArgument;
                };
                serialize.indent = std.fmt.parseInt(u8, n, 10) catch {
                    log.err("Invalid --indent value: {s}\n", .{n});
                    return ArgError.MissingGetArgument;
                };
            } else if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
                const fmt = args.next() orelse {
                    log.err("Missing format value after {s}\n", .{arg});
                    return ArgError.MissingGetArgument;
                };
                if (std.mem.eql(u8, fmt, "json")) {
                    input_override = .json;
                } else if (std.mem.eql(u8, fmt, "jsonc")) {
                    input_override = .jsonc;
                } else if (std.mem.eql(u8, fmt, "json5")) {
                    input_override = .json5;
                } else if (std.mem.eql(u8, fmt, "yaml") or std.mem.eql(u8, fmt, "yml")) {
                    input_override = .yaml;
                } else if (std.mem.eql(u8, fmt, "toml")) {
                    input_override = .toml;
                } else if (std.mem.eql(u8, fmt, "zon")) {
                    input_override = .zon;
                } else if (std.mem.eql(u8, fmt, "xml")) {
                    input_override = .xml;
                } else if (std.mem.eql(u8, fmt, "native") or std.mem.eql(u8, fmt, "fig")) {
                    input_override = .native;
                } else {
                    log.err("Unsupported format: {s}\n", .{fmt});
                    return ArgError.UnsupportedFileFormat;
                }
            } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
                const fmt = args.next() orelse {
                    log.err("Missing format value after {s}\n", .{arg});
                    return ArgError.MissingGetArgument;
                };
                if (std.mem.eql(u8, fmt, "json")) {
                    output_override = .json;
                } else if (std.mem.eql(u8, fmt, "jsonc")) {
                    output_override = .jsonc;
                } else if (std.mem.eql(u8, fmt, "json5")) {
                    output_override = .json5;
                } else if (std.mem.eql(u8, fmt, "yaml") or std.mem.eql(u8, fmt, "yml")) {
                    output_override = .yaml;
                } else if (std.mem.eql(u8, fmt, "toml")) {
                    output_override = .toml;
                } else if (std.mem.eql(u8, fmt, "zon")) {
                    output_override = .zon;
                } else if (std.mem.eql(u8, fmt, "native") or std.mem.eql(u8, fmt, "fig")) {
                    output_override = .native;
                } else {
                    log.err("Unsupported format: {s}\n", .{fmt});
                    return ArgError.UnsupportedFileFormat;
                }
            } else {
                try positionals.append(allocator, arg);
            }
        }

        const file_path = if (positionals.items.len > 0) positionals.items[0] else {
            log.err("No file provided.\n", .{});
            return ArgError.MissingGetArgument;
        };

        const requested_help = std.mem.eql(u8, file_path, "--help") or std.mem.eql(u8, file_path, "-h");

        var path: ?[]fig.AST.PathSegment = null;
        if (!requested_help and positionals.items.len > 1) {
            path = try parsePath(allocator, positionals.items[1]);
        }

        const detected_input: ?Detected = if (!requested_help and input_override == null)
            try detectLanguageFromFileEnding(file_path)
        else
            null;
        const input_format = input_override orelse (if (detected_input) |d| d.format else null) orelse .json;
        const embed = if (detected_input) |d| d.embed else null;

        config.options = .{ .get = .{
            .file = file_path,
            .path = path,
            .from = input_format,
            .to = output_override orelse input_format,
            .requested_help = requested_help,
            .lax_tags = lax_tags,
            .lossless = lossless,
            .embed = embed,
            .serialize = serialize,
            .quiet = quiet,
            .strict = strict,
        } };
    } else {
        log.err("Action not recognized: {s}", .{action_str});
        config.action = .help;
        config.options = .{ .help = .{ .requested_help = true } };
    }

    return config;
}
