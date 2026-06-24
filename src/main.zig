//! Main entrypoint for `fig` CLI
//! Design:
//! fig <action> [action options] [--flags]

const std = @import("std");
const fig = @import("fig");
const build_options = @import("build_options");
const Io = std.Io;

const title_string = "\n=========\n   FIG\n=========\n\n";
// The version of the linked fig core, so the CLI never drifts from the library
// it ships. Sourced from `build.zig` (the same numbers `fig_version` exposes).
const version = std.fmt.comptimePrint("{d}.{d}.{d}", .{
    build_options.version_major,
    build_options.version_minor,
    build_options.version_patch,
});

/// Currently, `fig` CLI only supports up to 10MB files.
const max_size = Io.Limit.limited(10 * 1024 * 1024);
const Format = enum { json, jsonc, json5, yaml, yml, toml, zon, xml, native };

const CliAction = enum {
    help,
    version,
    edit,
    get,
    comment,
    check,
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
        /// Set when the format could not be inferred from the file extension:
        /// the handler then sniffs the file's contents with `Language.detect`.
        detect: bool = false,
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
        /// Set when `from` could not be inferred from the file extension and no
        /// `--input` was given: the handler sniffs the contents with
        /// `Language.detect`. When `to` was also left to default (`output_explicit`
        /// is false), the detected format flows through to the output too.
        detect: bool = false,
        /// Whether `--output`/`-o` was given. When false and `detect` fires, the
        /// detected input format becomes the output format (echo round-trip).
        output_explicit: bool = false,
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
        /// `--indent N` sets the indent width; `--width N` sets TOML's inline-vs-
        /// expanded column budget. Honored by JSON (pretty + indent), ZON (pretty),
        /// and TOML (pretty gates array wrapping; indent/width drive its layout);
        /// YAML renders with its own fixed layout.
        serialize: fig.AST.SerializeOptions = .{},
        /// Suppress the lossy-conversion warnings normally written to stderr.
        quiet: bool = false,
        /// Treat any lossy conversion as an error: print the warnings, then exit
        /// non-zero without writing output.
        strict: bool = false,
    },
    comment: struct {
        file: []const u8,
        path: []fig.AST.PathSegment,
        text: []const u8,
        /// When set, target the same-line trailing comment on the value at
        /// `path`; otherwise the own-line comment block above the node.
        inline_comment: bool = false,
        /// When set, delete the targeted comment instead of adding/setting it
        /// (then `text` is unused).
        delete: bool = false,
        /// When set, print the targeted comment to stdout instead of editing it
        /// (then `text` is unused, and the file is opened read-only).
        get: bool = false,
        requested_help: bool = false,
        format: Format,
        /// Set when the format could not be inferred from the file extension:
        /// the handler then sniffs the file's contents with `Language.detect`.
        detect: bool = false,
        /// As in `edit`: when set, `file` is a host document and the comment is
        /// applied to the embedded config of this archetype, spliced back.
        embed: ?fig.Embed.Type = null,
    },
    check: struct {
        /// One or more files to validate. `-` reads stdin (single document).
        files: [][]const u8,
        /// Explicit `--input` format applied to every file. When null, each
        /// file's format is resolved from its extension, then by sniffing its
        /// contents — the same precedence `get` uses.
        format: ?Format = null,
        /// `--spec` version string (e.g. "1.0" for TOML). Resolved per file
        /// against the resolved format; null validates against the default
        /// version of each format.
        spec: ?[]const u8 = null,
        /// Suppress the per-file `ok` lines on success; errors still print.
        quiet: bool = false,
        requested_help: bool = false,
    },
};

/// The in-place editing operation `applyEdit` performs. Generalizes the editor's
/// span-splice surface so `edit` and `comment` share one code path.
const EditOp = union(enum) {
    replace_value,
    replace_key,
    add_leading_comment,
    set_trailing_comment,
    delete_leading_comments,
    delete_trailing_comment,
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
            \\  comment: add or edit a comment on part of a file
            \\  check: validate that one or more files parse cleanly
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

    fn comment(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage: {s} comment [--inline] [--delete | --get] <file> <path> [<text>]
            \\  default: add an own-line comment ABOVE the node at <path>
            \\  --inline: target the same-line trailing comment on the value at
            \\    <path> instead (set replaces any existing one on that line)
            \\  --delete: remove the targeted comment instead of adding it; <text>
            \\    is then omitted (a no-op when there is no such comment)
            \\  --get: print the targeted comment to stdout (markers stripped) and
            \\    make no change; <text> is then omitted (prints a blank line when
            \\    there is no such comment)
            \\  the comment marker is added for you: # for YAML/TOML, // for
            \\    JSONC/JSON5/ZON. Strict JSON has no comments (rejected).
            \\  <text> may span multiple lines (leading only): one comment line each.
            \\  path format: dot syntax for keys, bracket syntax for indices
            \\    example: school.class[0].student[3]
            \\  .md/.markdown files: comments the YAML frontmatter in place
            \\
        , .{binary_name});
        try term.writer.flush();
    }

    fn get(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage: {s} get [--input json|json5|yaml|toml|zon|native] [--output json|json5|yaml|toml|zon|native] <file> [path]
            \\  -i, --input: input format of file (defaults to the file extension,
            \\    then to sniffing the file's contents if the extension is unknown)
            \\  -o, --output:   output format (defaults to the input format)
            \\  native ("fig"): the AST's 1:1 canonical text encoding (.fig files);
            \\    usable as input or output, e.g. to inspect how any document parses.
            \\  --compact: single-line output with minimal whitespace (JSON, JSON5, ZON).
            \\  --pretty: multi-line, indented output (the default).
            \\  --indent N: spaces per indent level for pretty JSON, and for TOML's
            \\    wrapped arrays (default 2).
            \\  --width N: TOML column budget (default 80); a mapping/array that fits
            \\    stays inline, a wider one expands to a [section] / wrapped array.
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

    fn check(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage: {s} check [--input <format>] [-q|--quiet] <file>...
            \\  Validate that each file parses cleanly as its format. Prints an
            \\  `ok` line per file and exits 0 when all parse; prints an error
            \\  line to stderr for each failing file and exits 1 if any fail.
            \\  -i, --input: parse every file as this format (json, jsonc, json5,
            \\    yaml, toml, zon, xml, native/fig). Default: infer from each
            \\    file's extension, then by sniffing its contents.
            \\  -s, --spec: validate against a specific language version, where one
            \\    is selectable: TOML `1.0`/`1.1` (default 1.1), YAML `1.2.2`.
            \\    JSON strictness is the format itself (json vs jsonc vs json5).
            \\  -q, --quiet: suppress the per-file `ok` lines; errors still print.
            \\  reads stdin when <file> is `-`.
            \\  .md/.markdown files: validates the YAML frontmatter.
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
        ArgError.MissingCommentArgument => {
            try Help.comment(&stderr_terminal, "fig");
            std.process.exit(2);
        },
        ArgError.MissingCheckArgument => {
            try Help.check(&stderr_terminal, "fig");
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

            const op: EditOp = if (opts.key) .replace_key else .replace_value;
            if (opts.embed) |embed_type| {
                try applyToEmbed(init.arena.allocator(), io, input, embed_type, opts.path, opts.replacement, op);
            } else switch (if (opts.detect) try detectFileFormat(io, init.arena.allocator(), opts.file) else opts.format) {
                .json, .jsonc => |f| if (comptime build_options.lang_json) {
                    const replacement = try std.fmt.allocPrint(init.arena.allocator(), "\"{s}\"", .{opts.replacement});
                    try applyToFile(fig.Language.JSON, init.arena.allocator(), io, input, opts.path, replacement, op, jsonDialect(f));
                } else return error.FormatDisabled,
                .yaml, .yml => if (comptime build_options.lang_yaml) {
                    try applyToFile(fig.Language.YAML, init.arena.allocator(), io, input, opts.path, opts.replacement, op, fig.Language.YAML.default_type);
                } else return error.FormatDisabled,
                // TOML value/key replacement: a value or key node has a tight,
                // contiguous span (the parser's node_spans point at the original
                // source bytes), so the generic span-splice editor handles it
                // even when the owning table is assembled from scattered headers.
                // The replacement is taken verbatim as a TOML literal, like YAML
                // and ZON. (Structural inserts/deletes that must place text
                // relative to a scattered table are still unsupported.)
                .toml => if (comptime build_options.lang_toml)
                    try applyToFile(fig.Language.TOML, init.arena.allocator(), io, input, opts.path, opts.replacement, op, fig.Language.TOML.default_type)
                else
                    return error.FormatDisabled,
                // ZON edits take the replacement verbatim (a literal ZON value),
                // like YAML — the editor splices and reparses it.
                .zon => if (comptime build_options.lang_zon)
                    try applyToFile(fig.Language.ZON, init.arena.allocator(), io, input, opts.path, opts.replacement, op, fig.Language.ZON.default_type)
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
            const input = try getInput(io, opts.file, .read_only);
            defer if (!std.mem.eql(u8, opts.file, "-")) input.close(io);

            // Resolved input/output formats. They equal the parsed options unless
            // the input format has to be sniffed from the file's contents (no
            // `--input`, unrecognized extension): detection overwrites `from`, and
            // — when no `--output` was given — `to` follows it (an echo round-trip
            // rather than a silent convert-to-JSON).
            var from = opts.from;
            var to = opts.to;

            const doc = if (opts.embed) |embed_type|
                try parseEmbeddedFromFile(init.arena.allocator(), io, input, embed_type)
            else blk: {
                // Read once so detection and parsing share the same bytes — a
                // piped stdin can only be consumed a single time.
                const content = try readAll(init.arena.allocator(), io, input);
                if (opts.detect) {
                    from = try resolveFormatFromContent(init.arena.allocator(), content, opts.file);
                    if (!opts.output_explicit) to = from;
                }
                break :blk try parseSliceAs(from, .{}, init.arena.allocator(), content);
            };

            // XML is reader-only: a `--from`/detected source but never a `--to`
            // target. Checked after detection so a sniffed-or-echoed `to` is caught
            // too, keeping the serialize switches below total.
            if (to == .xml) {
                try stderr_terminal.writer.print("error: XML output is not yet supported (reader-only); XML may only be a `--from` source.\n", .{});
                try stderr_terminal.writer.flush();
                return error.UnsupportedOutputFormat;
            }

            // Converting YAML to a non-YAML format resolves the reference layer
            // first (aliases → copies, merges → flattened, tags applied/dropped).
            // YAML→YAML keeps it intact for round-trip; JSON never has it.
            const src_is_yaml = from == .yaml or from == .yml;
            const dst_is_yaml = to == .yaml or to == .yml;
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
                const maybe_target: ?fig.Lossless.Target = switch (to) {
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

            const target: fig.AST.SerializeFormat = switch (to) {
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
        .comment => {
            const opts = config.options.comment;
            if (opts.requested_help) {
                try Help.comment(&stdout_terminal, config.binary_name);
                return;
            }
            const a = init.arena.allocator();
            // `--get` only reads: open read-only and never write back.
            const input = try getInput(io, opts.file, if (opts.get) .read_only else .read_write);
            defer if (!std.mem.eql(u8, opts.file, "-")) input.close(io);

            const resolved = if (opts.detect) try detectFileFormat(io, a, opts.file) else opts.format;

            if (opts.get) {
                const comment = if (opts.embed) |embed_type|
                    try getCommentFromEmbed(a, io, input, embed_type, opts.path, opts.inline_comment)
                else switch (resolved) {
                    // Strict JSON has no comment syntax: there can be nothing to get.
                    .json => {
                        try stderr_terminal.writer.print("error: strict JSON has no comments; use a .jsonc or .json5 file instead.\n", .{});
                        try stderr_terminal.writer.flush();
                        std.process.exit(2);
                    },
                    .jsonc, .json5 => |f| if (comptime build_options.lang_json) try getCommentFromFile(fig.Language.JSON, a, io, input, opts.path, opts.inline_comment, jsonDialect(f)) else return error.FormatDisabled,
                    .yaml, .yml => if (comptime build_options.lang_yaml)
                        try getCommentFromFile(fig.Language.YAML, a, io, input, opts.path, opts.inline_comment, fig.Language.YAML.default_type)
                    else
                        return error.FormatDisabled,
                    .toml => if (comptime build_options.lang_toml)
                        try getCommentFromFile(fig.Language.TOML, a, io, input, opts.path, opts.inline_comment, fig.Language.TOML.default_type)
                    else
                        return error.FormatDisabled,
                    .zon => if (comptime build_options.lang_zon)
                        try getCommentFromFile(fig.Language.ZON, a, io, input, opts.path, opts.inline_comment, fig.Language.ZON.default_type)
                    else
                        return error.FormatDisabled,
                    .xml => return error.UnsupportedXmlEdit,
                    .native => return error.UnsupportedNativeEdit,
                };
                // Print the comment followed by a newline. An absent comment (null)
                // and a present-but-empty one both print just the newline — the CLI
                // can't distinguish them, but the bindings can (Option / null).
                try stdout_terminal.writer.print("{s}\n", .{comment orelse ""});
                try stdout_terminal.writer.flush();
                return;
            }

            // Pick the op from the two flags: `--inline` selects the trailing
            // (same-line) comment vs the leading block; `--delete` removes it
            // rather than adding/setting. The marker (`#`, `//`) is the editor's
            // job.
            const op: EditOp = if (opts.delete)
                (if (opts.inline_comment) .delete_trailing_comment else .delete_leading_comments)
            else
                (if (opts.inline_comment) .set_trailing_comment else .add_leading_comment);

            if (opts.embed) |embed_type| {
                try applyToEmbed(a, io, input, embed_type, opts.path, opts.text, op);
            } else switch (resolved) {
                // Strict JSON has no comment syntax: fail with a clear message
                // rather than letting the editor surface a bare error.
                .json => {
                    try stderr_terminal.writer.print("error: strict JSON has no comments; use a .jsonc or .json5 file instead.\n", .{});
                    try stderr_terminal.writer.flush();
                    std.process.exit(2);
                },
                // JSONC/JSON5 accept `//` comments (reparsed under the dialect).
                .jsonc, .json5 => |f| if (comptime build_options.lang_json) try applyToFile(fig.Language.JSON, a, io, input, opts.path, opts.text, op, jsonDialect(f)) else return error.FormatDisabled,
                .yaml, .yml => if (comptime build_options.lang_yaml)
                    try applyToFile(fig.Language.YAML, a, io, input, opts.path, opts.text, op, fig.Language.YAML.default_type)
                else
                    return error.FormatDisabled,
                .toml => if (comptime build_options.lang_toml)
                    try applyToFile(fig.Language.TOML, a, io, input, opts.path, opts.text, op, fig.Language.TOML.default_type)
                else
                    return error.FormatDisabled,
                .zon => if (comptime build_options.lang_zon)
                    try applyToFile(fig.Language.ZON, a, io, input, opts.path, opts.text, op, fig.Language.ZON.default_type)
                else
                    return error.FormatDisabled,
                .xml => return error.UnsupportedXmlEdit,
                .native => return error.UnsupportedNativeEdit,
            }
        },
        .check => {
            const opts = config.options.check;
            if (opts.requested_help) {
                try Help.check(&stdout_terminal, config.binary_name);
                return;
            }
            const a = init.arena.allocator();

            // Validate every file, reporting each independently, so one bad file
            // doesn't hide the status of the rest. Success lines go to stdout
            // (silenced by `--quiet`); failures always go to stderr. A single
            // bad file makes the whole run exit non-zero — the CI contract.
            var any_failed = false;
            for (opts.files) |file| {
                if (checkOne(a, io, file, opts.format, opts.spec)) |fmt| {
                    if (!opts.quiet) {
                        try stdout_terminal.setColor(.green);
                        try stdout_terminal.writer.writeAll("ok");
                        try stdout_terminal.setColor(.reset);
                        // Echo the pinned version alongside the format when one
                        // was requested, so `ok` states exactly what was checked.
                        if (opts.spec) |spec|
                            try stdout_terminal.writer.print(": {s} ({s} {s})\n", .{ file, @tagName(fmt), spec })
                        else
                            try stdout_terminal.writer.print(": {s} ({s})\n", .{ file, @tagName(fmt) });
                    }
                } else |err| {
                    any_failed = true;
                    try stderr_terminal.setColor(.red);
                    try stderr_terminal.writer.writeAll("error");
                    try stderr_terminal.setColor(.reset);
                    switch (err) {
                        // A spec mismatch is a CLI usage error, not a malformed
                        // document — say so plainly with the offending version.
                        error.UnsupportedSpec => try stderr_terminal.writer.print(
                            ": {s}: --spec '{s}' is not valid for this format\n",
                            .{ file, opts.spec.? },
                        ),
                        else => try stderr_terminal.writer.print(": {s}: {s}\n", .{ file, @errorName(err) }),
                    }
                }
            }
            try stdout_terminal.writer.flush();
            try stderr_terminal.writer.flush();
            if (any_failed) std.process.exit(1);
        },
    };
}

/// Validate that `file` parses cleanly, returning the resolved format on success.
/// Format precedence mirrors `get`: an explicit `--input` `override`, else the
/// file extension, else sniffing the contents. `spec_str` (from `--spec`) pins
/// the language version to validate against and is resolved once the format is
/// known — an unknown/inapplicable version is reported like a parse error. When
/// the extension implies an embedded region (e.g. markdown frontmatter) the
/// inner document is extracted and parsed. Any IO/parse/spec error propagates to
/// the caller, which reports it.
fn checkOne(allocator: std.mem.Allocator, io: Io, file: []const u8, override: ?Format, spec_str: ?[]const u8) !Format {
    const input = try getInput(io, file, .read_only);
    defer if (!std.mem.eql(u8, file, "-")) input.close(io);
    const content = try readAll(allocator, io, input);

    var format: Format = undefined;
    var embed: ?fig.Embed.Type = null;
    if (override) |f| {
        // An explicit format is taken at face value: no extension-driven embed
        // extraction, so `--input yaml file.md` parses the whole file as YAML.
        format = f;
    } else if (detectLanguageFromFileEnding(file)) |d| {
        format = d.format;
        embed = d.embed;
    } else {
        format = try resolveFormatFromContent(allocator, content, file);
    }

    // Resolve `--spec` against the now-known format. This rejects a nonsense
    // version (e.g. `--spec 1.0` on a JSON or markdown file) before parsing.
    const spec = try resolveSpec(format, spec_str);

    // `Embed.extract` parses the inner region; `parseSliceAs` parses the whole
    // file. Either surfaces a parse error — all we need to validate. The parsed
    // result is discarded; we only care that it parsed. (Embed extraction uses
    // the inner format's default version; `spec` was still validated above.)
    if (embed) |embed_type| {
        _ = try fig.Embed.extract(allocator, content, embed_type);
    } else {
        _ = try parseSliceAs(format, spec, allocator, content);
    }
    return format;
}

fn readAll(allocator: std.mem.Allocator, io: Io, file: Io.File) ![]u8 {
    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    return file_reader.interface.allocRemaining(allocator, max_size);
}

/// Per-language version/dialect to parse under. Each field defaults to its
/// language's `default_type`, so `parseSliceAs(fmt, .{}, …)` behaves exactly as
/// before — only `check --spec` overrides a field. JSON strictness is carried by
/// the `Format` itself (json/jsonc/json5); ZON/XML/native have one grammar each,
/// so they need no field here.
const Spec = struct {
    toml: fig.Language.TOML.Type = fig.Language.TOML.default_type,
    yaml: fig.Language.YAML.Type = fig.Language.YAML.default_type,
};

/// Resolve a `--spec` version string against the format it will parse. Null
/// `spec_str` yields the default spec. Errors when the version is unknown for
/// that format, or when the format exposes no selectable version (then `--spec`
/// doesn't apply — JSON strictness is the format name, ZON/XML/native are
/// single-grammar). YAML currently has only 1.2.2; 1.1 is not yet implemented.
fn resolveSpec(format: Format, spec_str: ?[]const u8) error{UnsupportedSpec}!Spec {
    const s = spec_str orelse return .{};
    const eq = std.mem.eql;
    return switch (format) {
        .toml => if (eq(u8, s, "1.0") or eq(u8, s, "1.0.0"))
            .{ .toml = .TOML_1_0 }
        else if (eq(u8, s, "1.1") or eq(u8, s, "1.1.0"))
            .{ .toml = .TOML_1_1 }
        else
            error.UnsupportedSpec,
        .yaml, .yml => if (eq(u8, s, "1.2") or eq(u8, s, "1.2.2"))
            .{ .yaml = .v1_2_2 }
        else
            error.UnsupportedSpec,
        .json, .jsonc, .json5, .zon, .xml, .native => error.UnsupportedSpec,
    };
}

/// Parse already-read `content` as the CLI `format` under `spec`. The
/// content-based parser the `get` and `check` actions use: reading the input
/// once means detection and parsing share the same bytes, so a piped stdin is
/// consumed only once. `.jsonc`/`.json5` select the JSON dialect; `.yml` aliases
/// YAML; `.native` is the `.fig` grammar. `spec` picks the language version
/// where one is selectable (TOML 1.0 vs 1.1, YAML version).
fn parseSliceAs(format: Format, spec: Spec, allocator: std.mem.Allocator, content: []const u8) !fig.Document {
    return switch (format) {
        .json => if (comptime build_options.lang_json) fig.Language.JSON.Parser.parse(allocator, content, .JSON) else error.FormatDisabled,
        .jsonc => if (comptime build_options.lang_json) fig.Language.JSON.Parser.parse(allocator, content, .JSONC) else error.FormatDisabled,
        .json5 => if (comptime build_options.lang_json) fig.Language.JSON.Parser.parse(allocator, content, .JSON5) else error.FormatDisabled,
        .yaml, .yml => if (comptime build_options.lang_yaml) fig.Language.YAML.Parser.parse(allocator, content, spec.yaml) else error.FormatDisabled,
        .toml => if (comptime build_options.lang_toml) fig.Language.TOML.Parser.parse(allocator, content, spec.toml) else error.FormatDisabled,
        .zon => if (comptime build_options.lang_zon) fig.Language.ZON.Parser.parse(allocator, content, fig.Language.ZON.default_type) else error.FormatDisabled,
        .xml => if (comptime build_options.lang_xml) fig.Language.XML.Parser.parse(allocator, content, fig.Language.XML.default_type) else error.FormatDisabled,
        .native => fig.Native.parse(allocator, content),
    };
}

/// Map a `Language.detect` result to the CLI `Format`. `Detected` has no `jsonc`
/// or `native` (neither is content-sniffed), so the mapping is total.
fn mapDetected(d: fig.Language.Detected) Format {
    return switch (d) {
        .json => .json,
        .json5 => .json5,
        .yaml => .yaml,
        .toml => .toml,
        .zon => .zon,
        .xml => .xml,
    };
}

/// Sniff `content` with `Language.detect`, emit an info-level log of what was
/// inferred, and return it — the fallback when neither `--input` nor the file
/// extension pinned the format. Errors (after a clear message) if nothing matches.
fn resolveFormatFromContent(allocator: std.mem.Allocator, content: []const u8, file_path: []const u8) !Format {
    const detected = fig.Language.detect(allocator, content) orelse {
        std.log.scoped(.detect).err("could not infer the format of `{s}` from its contents; pass an explicit format", .{file_path});
        return error.UnsupportedFileFormat;
    };
    const format = mapDetected(detected);
    std.log.scoped(.detect).info("inferred format `{s}` for `{s}` from its contents", .{ @tagName(format), file_path });
    return format;
}

/// Open `file_path` read-only and sniff its contents. For the in-place edit paths
/// (`edit`/`comment`), which then re-open the file read-write to splice it — so
/// detection reads through a separate handle and never disturbs the edit read.
fn detectFileFormat(io: Io, allocator: std.mem.Allocator, file_path: []const u8) !Format {
    const probe = try getInput(io, file_path, .read_only);
    defer if (!std.mem.eql(u8, file_path, "-")) probe.close(io);
    const content = try readAll(allocator, io, probe);
    return resolveFormatFromContent(allocator, content, file_path);
}

/// Extract the embedded config of `embed_type` from a host file and parse it.
/// The returned document's node spans are relative to the embedded region.
fn parseEmbeddedFromFile(allocator: std.mem.Allocator, io: Io, file: Io.File, embed_type: fig.Embed.Type) !fig.Document {
    const content = try readAll(allocator, io, file);
    const embedded = try fig.Embed.extract(allocator, content, embed_type);
    return embedded.document;
}

/// Apply one in-place edit to `content` (a complete document parsed under
/// `dialect`) and return the new bytes. The single span-splice path behind both
/// the `edit` and `comment` actions.
fn applyEdit(
    comptime Lang: type,
    allocator: std.mem.Allocator,
    content: []const u8,
    path: []fig.AST.PathSegment,
    text: []const u8,
    op: EditOp,
    dialect: Lang.Type,
) ![]u8 {
    var editor: fig.Editor(Lang) = .{ .allocator = allocator, .format = dialect };
    try editor.init(content);
    defer editor.deinit();
    switch (op) {
        .replace_value => try editor.replaceValAtPath(path, text),
        .replace_key => try editor.replaceKeyAtPath(path, text),
        .add_leading_comment => try editor.addLeadingComment(path, text),
        .set_trailing_comment => try editor.setTrailingComment(path, text),
        .delete_leading_comments => try editor.deleteLeadingComments(path),
        .delete_trailing_comment => try editor.deleteTrailingComment(path),
    }
    return allocator.dupe(u8, editor.source.items);
}

fn applyToFile(
    comptime Lang: type,
    allocator: std.mem.Allocator,
    io: Io,
    file: Io.File,
    path: []fig.AST.PathSegment,
    text: []const u8,
    op: EditOp,
    dialect: Lang.Type,
) !void {
    const content = try readAll(allocator, io, file);
    defer allocator.free(content);

    const edited = try applyEdit(Lang, allocator, content, path, text, op, dialect);
    try file.writePositionalAll(io, edited, 0);
    try file.setLength(io, edited.len);
}

/// Read back a comment from `content` (parsed under `dialect`) without writing:
/// the trailing (same-line) comment on the value at `path` when `inline_comment`,
/// else the own-line block above the node. Returns `null` when there is no such
/// comment (the CLI then prints a blank line). The read-only twin of `applyEdit`'s
/// comment ops.
fn getComment(
    comptime Lang: type,
    allocator: std.mem.Allocator,
    content: []const u8,
    path: []fig.AST.PathSegment,
    inline_comment: bool,
    dialect: Lang.Type,
) !?[]u8 {
    var editor: fig.Editor(Lang) = .{ .allocator = allocator, .format = dialect };
    try editor.init(content);
    defer editor.deinit();
    return if (inline_comment)
        editor.getTrailingComment(path)
    else
        editor.getLeadingComment(path);
}

fn getCommentFromFile(
    comptime Lang: type,
    allocator: std.mem.Allocator,
    io: Io,
    file: Io.File,
    path: []fig.AST.PathSegment,
    inline_comment: bool,
    dialect: Lang.Type,
) !?[]u8 {
    const content = try readAll(allocator, io, file);
    defer allocator.free(content);
    return getComment(Lang, allocator, content, path, inline_comment, dialect);
}

/// Read a comment from the embedded config of a host file: extract the region,
/// parse only that slice as its inner format, and read the comment from it. The
/// read-only twin of `applyToEmbed`.
fn getCommentFromEmbed(
    allocator: std.mem.Allocator,
    io: Io,
    file: Io.File,
    embed_type: fig.Embed.Type,
    path: []fig.AST.PathSegment,
    inline_comment: bool,
) !?[]u8 {
    const content = try readAll(allocator, io, file);
    defer allocator.free(content);

    const embedded = try fig.Embed.extract(allocator, content, embed_type);
    defer embedded.deinit(allocator);
    const region = embedded.region;
    const inner = content[region.content.start..region.content.end];

    return switch (embed_type) {
        .FrontmatterYaml, .EndmatterYaml => if (comptime build_options.lang_yaml)
            try getComment(fig.Language.YAML, allocator, inner, path, inline_comment, fig.Language.YAML.default_type)
        else
            return error.FormatDisabled,
        // Strict JSON frontmatter has no comment syntax: nothing to read.
        .FrontmatterJson => if (comptime build_options.lang_json)
            try getComment(fig.Language.JSON, allocator, inner, path, inline_comment, .JSON)
        else
            return error.FormatDisabled,
    };
}

/// Apply an edit to the embedded config of a host file in place: extract the
/// region, edit only that slice as its inner format, then splice it back between
/// the retained fences so the rest of the host file is byte-identical.
fn applyToEmbed(
    allocator: std.mem.Allocator,
    io: Io,
    file: Io.File,
    embed_type: fig.Embed.Type,
    path: []fig.AST.PathSegment,
    text: []const u8,
    op: EditOp,
) !void {
    const content = try readAll(allocator, io, file);
    defer allocator.free(content);

    const embedded = try fig.Embed.extract(allocator, content, embed_type);
    defer embedded.deinit(allocator);
    const region = embedded.region;
    const inner = content[region.content.start..region.content.end];

    const edited_inner = switch (embed_type) {
        .FrontmatterYaml, .EndmatterYaml => if (comptime build_options.lang_yaml)
            try applyEdit(fig.Language.YAML, allocator, inner, path, text, op, fig.Language.YAML.default_type)
        else
            return error.FormatDisabled,
        // JSON frontmatter is plain (strict) JSON: a replacement value is quoted
        // as a JSON string, while a comment op rides through unquoted and the
        // editor rejects it (strict JSON has no comment syntax).
        .FrontmatterJson => if (comptime build_options.lang_json) blk: {
            const value_text = switch (op) {
                .replace_value, .replace_key => try std.fmt.allocPrint(allocator, "\"{s}\"", .{text}),
                // Comment ops pass their text (or none, for deletes) through as-is.
                .add_leading_comment, .set_trailing_comment, .delete_leading_comments, .delete_trailing_comment => text,
            };
            break :blk try applyEdit(fig.Language.JSON, allocator, inner, path, value_text, op, .JSON);
        } else return error.FormatDisabled,
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, content[0..region.content.start]);
    try out.appendSlice(allocator, edited_inner);
    try out.appendSlice(allocator, content[region.content.end..]);

    try file.writePositionalAll(io, out.items, 0);
    try file.setLength(io, out.items.len);
}

/// Map the CLI's JSON-family `Format` to the parser dialect the editor reparses
/// under, so editing a JSONC/JSON5 file keeps its comments valid on reparse.
fn jsonDialect(format: Format) fig.Language.JSON.Type {
    return switch (format) {
        .jsonc => .JSONC,
        .json5 => .JSON5,
        else => .JSON,
    };
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

/// Infer the parse strategy from a file's extension, or null when the extension
/// is missing/unrecognized — the caller then falls back to content sniffing
/// (`Language.detect`) rather than failing outright.
fn detectLanguageFromFileEnding(file_path: []const u8) ?Detected {
    const dot = std.mem.findLast(u8, file_path, ".");
    const ext = file_path[(dot orelse 0) + 1 .. file_path.len];

    // Markdown carries YAML frontmatter by default.
    if (std.mem.eql(u8, ext, "md") or std.mem.eql(u8, ext, "markdown")) {
        return .{ .format = .yaml, .embed = .FrontmatterYaml };
    }

    // `.fig` is the native format's file extension (`.native` maps via the enum).
    if (std.mem.eql(u8, ext, "fig")) return .{ .format = .native, .embed = null };

    const format = std.meta.stringToEnum(Format, ext) orelse return null;
    return .{ .format = format, .embed = null };
}

const ArgError = error{ UnsupportedFileFormat, MissingEditArgument, MissingGetArgument, MissingCommentArgument, MissingCheckArgument, OutOfMemory, Overflow, InvalidCharacter, InvalidPath };

/// Map a `--input`/`-i` format name to a `Format`. Accepts every CLI format
/// plus the `fig` alias for the native grammar. Returns null for an unknown
/// name so callers can emit a tailored error.
fn parseFormatName(name: []const u8) ?Format {
    if (std.mem.eql(u8, name, "fig")) return .native;
    return std.meta.stringToEnum(Format, name);
}

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

        // Skip extension detection when the user only asked for help (the
        // "file" is then `--help`, which has no real format). An unrecognized
        // extension is not an error here: `detect = true` defers to content
        // sniffing in the handler.
        const ext = if (requested_help) null else detectLanguageFromFileEnding(file_path);
        config.options = .{ .edit = .{
            .file = file_path,
            .path = path,
            .replacement = replacement,
            .key = edit_key,
            .requested_help = requested_help,
            .format = if (ext) |d| d.format else .json,
            .detect = !requested_help and ext == null,
            .embed = if (ext) |d| d.embed else null,
        } };
    } else if (std.mem.eql(u8, action_str, "comment") or std.mem.eql(u8, action_str, "c")) {
        config.action = .comment;

        // Leading flags, in any order: `--inline`, `--delete`, `--get`. Consume
        // them until the first non-flag token (the file).
        var inline_comment = false;
        var delete = false;
        var get = false;
        var file_path_arg = args.next();
        while (file_path_arg) |arg| {
            if (std.mem.eql(u8, arg, "--inline")) {
                inline_comment = true;
            } else if (std.mem.eql(u8, arg, "--delete")) {
                delete = true;
            } else if (std.mem.eql(u8, arg, "--get")) {
                get = true;
            } else break;
            file_path_arg = args.next();
        }
        const file_path = file_path_arg orelse {
            log.err("No file provided.\n", .{});
            return ArgError.MissingCommentArgument;
        };

        const requested_help = std.mem.eql(u8, file_path, "--help") or std.mem.eql(u8, file_path, "-h");

        var path: []fig.AST.PathSegment = &.{};
        var text: []const u8 = "";
        if (!requested_help) {
            const path_str = args.next() orelse {
                log.err("No path provided.\n", .{});
                return ArgError.MissingCommentArgument;
            };
            path = try parsePath(allocator, path_str);

            // Delete/get need no text; add/set requires it.
            if (!delete and !get) {
                text = args.next() orelse {
                    log.err("No comment text provided.\n", .{});
                    return ArgError.MissingCommentArgument;
                };
            }
        }

        const ext = if (requested_help) null else detectLanguageFromFileEnding(file_path);
        config.options = .{ .comment = .{
            .file = file_path,
            .path = path,
            .text = text,
            .inline_comment = inline_comment,
            .delete = delete,
            .get = get,
            .requested_help = requested_help,
            .format = if (ext) |d| d.format else .json,
            .detect = !requested_help and ext == null,
            .embed = if (ext) |d| d.embed else null,
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
            } else if (std.mem.eql(u8, arg, "--width")) {
                const n = args.next() orelse {
                    log.err("Missing value after {s}\n", .{arg});
                    return ArgError.MissingGetArgument;
                };
                serialize.width = std.fmt.parseInt(u16, n, 10) catch {
                    log.err("Invalid --width value: {s}\n", .{n});
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
            detectLanguageFromFileEnding(file_path)
        else
            null;
        // No `--input` and an unrecognized extension ⇒ sniff the contents in the
        // handler. `.json` here is a placeholder `from`/`to`, overwritten once the
        // real format is known.
        const needs_detect = !requested_help and input_override == null and detected_input == null;
        const input_format = input_override orelse (if (detected_input) |d| d.format else null) orelse .json;
        const embed = if (detected_input) |d| d.embed else null;

        config.options = .{ .get = .{
            .file = file_path,
            .path = path,
            .from = input_format,
            .to = output_override orelse input_format,
            .requested_help = requested_help,
            .detect = needs_detect,
            .output_explicit = output_override != null,
            .lax_tags = lax_tags,
            .lossless = lossless,
            .embed = embed,
            .serialize = serialize,
            .quiet = quiet,
            .strict = strict,
        } };
    } else if (std.mem.eql(u8, action_str, "check") or std.mem.eql(u8, action_str, "ck")) {
        config.action = .check;

        var input_override: ?Format = null;
        var spec: ?[]const u8 = null;
        var quiet = false;
        var requested_help = false;
        var files: std.ArrayList([]const u8) = .empty;
        defer files.deinit(allocator);

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                requested_help = true;
            } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--no-warnings")) {
                quiet = true;
            } else if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
                const fmt = args.next() orelse {
                    log.err("Missing format value after {s}\n", .{arg});
                    return ArgError.MissingCheckArgument;
                };
                input_override = parseFormatName(fmt) orelse {
                    log.err("Unsupported format: {s}\n", .{fmt});
                    return ArgError.UnsupportedFileFormat;
                };
            } else if (std.mem.eql(u8, arg, "--spec") or std.mem.eql(u8, arg, "-s")) {
                spec = args.next() orelse {
                    log.err("Missing version value after {s}\n", .{arg});
                    return ArgError.MissingCheckArgument;
                };
            } else {
                try files.append(allocator, arg);
            }
        }

        if (!requested_help and files.items.len == 0) {
            log.err("No file provided.\n", .{});
            return ArgError.MissingCheckArgument;
        }

        config.options = .{ .check = .{
            // toOwnedSlice: the whole slice (allocated in the arena passed to
            // parseConfig) outlives this function, unlike `get` which only keeps
            // copies of individual positional headers.
            .files = try files.toOwnedSlice(allocator),
            .format = input_override,
            .spec = spec,
            .quiet = quiet,
            .requested_help = requested_help,
        } };
    } else {
        log.err("Action not recognized: {s}", .{action_str});
        config.action = .help;
        config.options = .{ .help = .{ .requested_help = true } };
    }

    return config;
}
