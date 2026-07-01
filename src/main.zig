//! Main entrypoint for `fig` CLI
//! Design:
//! fig <action> [action options] [--flags]

const std = @import("std");
const fig = @import("fig");
const build_options = @import("build_options");
const Io = std.Io;

// gron is a CLI-only format: it lives here in the binary, never in the `fig`
// library, the C ABI, or `Language.detect`. It rides the `get` pipeline by
// deriving straight from the public AST (see `cli/gron.zig`).
const gron = @import("cli/gron.zig");

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
// `gron` is a CLI-only output/echo format with no `AST.SerializeFormat`
// counterpart; the `get` handler intercepts it before the serializer dispatch.
const Format = enum { json, jsonc, json5, yaml, yml, toml, zon, xml, native, gron };

const CliAction = enum {
    help,
    version,
    edit,
    set,
    insert,
    delete,
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
    set: struct {
        file: []const u8,
        /// The target. For a scalar upsert the last segment is the key to
        /// replace-or-create; for `--seq` it names the sequence to reconcile.
        path: []fig.AST.PathSegment,
        /// The value to upsert (unused when `seq` is set).
        value: []const u8,
        /// When set, reconcile the sequence at `path` to exactly `values`,
        /// preserving comments on survivors (the `set_sequence` primitive),
        /// instead of upserting a single scalar.
        seq: bool = false,
        values: []const []const u8 = &.{},
        requested_help: bool = false,
        format: Format,
        detect: bool = false,
        /// When set, `file` is a host document and the upsert targets the
        /// embedded config of this archetype — creating the block (open-or-init)
        /// when the host has none.
        embed: ?fig.Embed.Type = null,
    },
    insert: struct {
        file: []const u8,
        /// The destination *slot*, not an existing node: the last segment names
        /// what to create. A trailing key (`a.b.newkey`) inserts that key into
        /// the mapping at the parent path; a trailing index (`a.list[0]` /
        /// `a.list[-]`) prepends/appends to the sequence at the parent path. An
        /// empty parent means the root container, so the root's actual kind
        /// (mapping vs sequence) decides which applies — not the file format.
        path: []fig.AST.PathSegment,
        value: []const u8,
        requested_help: bool = false,
        format: Format,
        /// Set when the format could not be inferred from the extension; the
        /// handler then sniffs the contents with `Language.detect`.
        detect: bool = false,
        /// As in `edit`: when set, edit the embedded config of this archetype.
        embed: ?fig.Embed.Type = null,
    },
    delete: struct {
        file: []const u8,
        /// The node to remove. A trailing key deletes that mapping entry (with
        /// its owned leading comments); a trailing index removes that sequence
        /// item from the parent sequence.
        path: []fig.AST.PathSegment,
        requested_help: bool = false,
        format: Format,
        detect: bool = false,
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
        /// When set, print the host *body* (the prose outside the fences) of the
        /// embed archetype instead of converting its content. Demonstrates the
        /// region's `body` span; ignored when there is no embed.
        body: bool = false,
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
        /// Syntax knobs for `-o gron` (root name, key/value separator, terminator).
        /// Defaults reproduce gron exactly; ignored unless the output is gron.
        gron_projection: gron.Projection = .gron,
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
    /// Insert `key: text` into the mapping at `path`. The payload is the new
    /// key's text; the value rides in `applyEdit`'s `text` argument.
    insert_key: []const u8,
    /// Upsert the value at `path`: replace it, or insert the trailing key when
    /// only it is absent. `text` is the value; `path` ends in the key.
    set,
    /// Reconcile the sequence at `path` to exactly `items`, preserving the
    /// comments on items that survive (`text` unused).
    set_sequence: []const []const u8,
    /// Append `text` as a new last item to the sequence at `path`.
    append_seq,
    /// Insert `text` as the new first item of the sequence at `path`.
    prepend_seq,
    /// Delete the mapping entry named by `path` (text unused).
    delete_key,
    /// Remove the item at this index from the sequence at `path` (text unused).
    remove_seq_item: usize,
};

/// Sentinel sequence index meaning "the end" — produced by `parsePath` for the
/// `[-]`/`[$]` append tokens and consumed by the `insert` handler to pick
/// `append_seq` over `prepend_seq`. Out of range for any real index, so it never
/// collides with an addressable item.
const append_index = std.math.maxInt(usize);

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
            \\  set: upsert a value (create the key, or the embed block, if absent)
            \\  insert: add a new key or list item to a file
            \\  delete: remove a key or list item from a file
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

    fn set(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage: {s} set [--embed <archetype>] <file> <path> <value>
            \\       {s} set [--embed <archetype>] --seq <file> <path> <item>...
            \\  Upsert: replace the value at <path>, or create it when only the
            \\    trailing key is absent — one verb for `edit`+`insert`.
            \\  --seq: reconcile the sequence at <path> to exactly <item>..., keeping
            \\    the comments on items that survive (only new items are inserted,
            \\    only dropped ones removed; result order matches the arguments).
            \\  --embed <archetype>: target an embedded region of a host file —
            \\    `frontmatter` (---/YAML, the .md default), `frontmatter-json`
            \\    (;;;/JSON), or `endmatter` (trailing ```endmatter block). When the
            \\    host has no such block, it is CREATED (frontmatter at the top,
            \\    endmatter at the bottom) and seeded with <path>: <value>.
            \\  value: a literal in the target format (YAML/TOML/ZON verbatim; JSON
            \\    is quoted as a string, as with `edit`). A created key is rendered
            \\    in the target syntax too, so new keys work for strict JSON.
            \\  path format: dot syntax for keys, bracket syntax for indices
            \\    example: school.class[0].student[3]
            \\  .md/.markdown files: upserts the YAML frontmatter, creating it if absent.
            \\
        , .{ binary_name, binary_name });
        try term.writer.flush();
    }

    fn insert(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage: {s} insert <file> <path> <value>
            \\  Adds a new entry. The last path segment names the slot to create:
            \\    a.b.newkey   -> insert key `newkey` into the mapping at a.b
            \\    a.list[0]    -> prepend <value> as the first item of a.list
            \\    a.list[-]    -> append <value> as the last item ([$] also works)
            \\  An empty parent targets the root container, so the document's own
            \\    root (mapping vs list) decides which form applies — not the format.
            \\  Mid-sequence insert (e.g. list[2]) is not yet supported.
            \\  value: a literal in the file's format (YAML/TOML/ZON verbatim); for
            \\    JSON it is quoted as a string, as with `edit`.
            \\  path format: dot syntax for keys, bracket syntax for indices.
            \\  .md/.markdown files: edits the YAML frontmatter in place.
            \\
        , .{binary_name});
        try term.writer.flush();
    }

    fn delete(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage: {s} delete <file> <path>
            \\  Removes the entry the path points at. The last path segment decides:
            \\    a.b.key      -> delete that mapping entry (with its own comments)
            \\    a.list[2]    -> remove item 2 from the sequence a.list
            \\  path format: dot syntax for keys, bracket syntax for indices
            \\    example: school.class[0].student[3]
            \\  .md/.markdown files: edits the YAML frontmatter in place.
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
            \\Usage: {s} get [--input json|json5|yaml|toml|zon|native|gron] [--output json|json5|yaml|toml|zon|native|gron] <file> [path]
            \\  -i, --input: input format of file (defaults to the file extension,
            \\    then to sniffing the file's contents if the extension is unknown)
            \\  -o, --output:   output format (defaults to the input format)
            \\  native ("fig"): the AST's 1:1 canonical text encoding (.fig files);
            \\    usable as input or output, e.g. to inspect how any document parses.
            \\  gron: a line-oriented `path = value;` projection (greppable, and
            \\    reversible with `-i gron`); must be selected explicitly, never
            \\    sniffed. Fidelity matches JSON (drops comments/anchors).
            \\  --gron-root NAME: root identifier for `-o gron` (default "json").
            \\  --gron-sep STR: key/value separator for `-o gron` (default " = ").
            \\    Print-only: ungron always splits on " = ", so a custom separator
            \\    is one-way unless it matches the default.
            \\  --gron-term STR: per-line terminator for `-o gron` (default ";");
            \\    pass "" to drop it. ungron strips an optional ";" regardless.
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
            \\  --embed <archetype>: read an embedded region of a host file —
            \\    `frontmatter` (the .md default), `frontmatter-json`, or `endmatter`.
            \\  --body: print the host prose OUTSIDE the fences (the body span) instead
            \\    of the embed content; the whole file when there is no such region.
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
            \\    is selectable: TOML `1.0`/`1.1` (default 1.1), YAML `1.2.2`/`1.1`
            \\    (default 1.2.2).
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
        ArgError.MissingSetArgument => {
            try Help.set(&stderr_terminal, "fig");
            std.process.exit(2);
        },
        ArgError.MissingInsertArgument => {
            try Help.insert(&stderr_terminal, "fig");
            std.process.exit(2);
        },
        ArgError.MissingDeleteArgument => {
            try Help.delete(&stderr_terminal, "fig");
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
                // gron is a CLI-only get/echo format with no in-place editor.
                .gron => return error.UnsupportedGronEdit,
            }
        },
        .set => {
            const opts = config.options.set;
            if (opts.requested_help) {
                try Help.set(&stdout_terminal, config.binary_name);
                return;
            }
            const a = init.arena.allocator();
            const input = try getInput(io, opts.file, .read_write);
            defer if (!std.mem.eql(u8, opts.file, "-")) input.close(io);

            if (opts.path.len == 0) {
                try stderr_terminal.writer.print("error: set needs a path to the key (or, with --seq, the sequence) to upsert.\n", .{});
                try stderr_terminal.writer.flush();
                std.process.exit(2);
            }
            const resolved = if (opts.detect) try detectFileFormat(io, a, opts.file) else opts.format;
            // `--seq` reconciles the sequence at `path`; otherwise upsert a scalar.
            // Both flow through the shared structural-edit router, so the embed
            // path (which open-or-inits a missing block) is reused for free.
            const op: EditOp = if (opts.seq) .{ .set_sequence = opts.values } else .set;
            const text: []const u8 = if (opts.seq) "" else opts.value;
            try applyStructuralEdit(a, io, input, resolved, opts.embed, opts.path, text, op);
        },
        .insert => {
            const opts = config.options.insert;
            if (opts.requested_help) {
                try Help.insert(&stdout_terminal, config.binary_name);
                return;
            }
            const a = init.arena.allocator();
            const input = try getInput(io, opts.file, .read_write);
            defer if (!std.mem.eql(u8, opts.file, "-")) input.close(io);

            // The destination is the *parent* container plus the trailing slot.
            // A trailing key inserts into a mapping; a trailing index pre/appends
            // to a sequence. An empty parent is the root container.
            if (opts.path.len == 0) {
                try stderr_terminal.writer.print("error: insert needs a destination path (e.g. a.b.newkey or list[-]).\n", .{});
                try stderr_terminal.writer.flush();
                std.process.exit(2);
            }
            const parent = opts.path[0 .. opts.path.len - 1];
            const resolved = if (opts.detect) try detectFileFormat(io, a, opts.file) else opts.format;
            switch (opts.path[opts.path.len - 1]) {
                .key => |key| try applyStructuralEdit(a, io, input, resolved, opts.embed, parent, opts.value, .{ .insert_key = key }),
                .index => |index| {
                    // The editor only prepends or appends; an addressable middle
                    // index has no primitive, so reject it rather than guess.
                    const op: EditOp = if (index == 0)
                        .prepend_seq
                    else if (index == append_index)
                        .append_seq
                    else {
                        try stderr_terminal.writer.print("error: sequence insert supports only [0] (prepend) or [-]/[$] (append); mid-sequence insert is not yet available.\n", .{});
                        try stderr_terminal.writer.flush();
                        std.process.exit(2);
                    };
                    try applyStructuralEdit(a, io, input, resolved, opts.embed, parent, opts.value, op);
                },
            }
        },
        .delete => {
            const opts = config.options.delete;
            if (opts.requested_help) {
                try Help.delete(&stdout_terminal, config.binary_name);
                return;
            }
            const a = init.arena.allocator();
            const input = try getInput(io, opts.file, .read_write);
            defer if (!std.mem.eql(u8, opts.file, "-")) input.close(io);

            if (opts.path.len == 0) {
                try stderr_terminal.writer.print("error: delete needs a path to the entry or item to remove.\n", .{});
                try stderr_terminal.writer.flush();
                std.process.exit(2);
            }
            const resolved = if (opts.detect) try detectFileFormat(io, a, opts.file) else opts.format;
            // A trailing index removes that item from the parent sequence; a
            // trailing key deletes the mapping entry named by the full path.
            switch (opts.path[opts.path.len - 1]) {
                .index => |index| try applyStructuralEdit(a, io, input, resolved, opts.embed, opts.path[0 .. opts.path.len - 1], "", .{ .remove_seq_item = index }),
                .key => try applyStructuralEdit(a, io, input, resolved, opts.embed, opts.path, "", .delete_key),
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

            // `--body`: print the host prose OUTSIDE the fences (the region's
            // `body` span) — the complement of extracting the embed content. With
            // no such region the whole file is the body.
            if (opts.body) {
                const embed_type = opts.embed orelse fig.Embed.Type.FrontmatterYaml;
                const content = try readAll(init.arena.allocator(), io, input);
                if (fig.Embed.locateRegion(content, embed_type)) |region| {
                    try stdout_terminal.writer.writeAll(content[region.body.start..region.body.end]);
                } else |err| switch (err) {
                    error.NotFound => try stdout_terminal.writer.writeAll(content),
                    else => return err,
                }
                try stdout_terminal.writer.flush();
                return;
            }

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
                    // gron's value layer is JSON, so it shares the JSON envelope
                    // target: an unrepresentable value (a TOML datetime, etc.)
                    // rides in a `$fig` envelope that prints as a JSON object.
                    .json, .jsonc, .json5, .gron => .json,
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

            // gron is a CLI-only projection that derives straight from the AST,
            // so it has no `SerializeFormat`: print it here and return, bypassing
            // the serializer dispatch, the lossy/lossless diagnostics below, and
            // the C ABI entirely. YAML aliases are already materialized above.
            if (to == .gron) {
                if (comptime build_options.lang_json) {
                    try gron.printNode(stdout_terminal.writer, ast, node_id, opts.gron_projection);
                    try stdout_terminal.writer.flush();
                } else return error.FormatDisabled;
                return;
            }

            const target: fig.AST.SerializeFormat = switch (to) {
                .json => .json,
                .jsonc => .jsonc,
                .json5 => .json5,
                .yaml, .yml => .yaml,
                .toml => .toml,
                .zon => .zon,
                .native => .native,
                .xml => unreachable, // rejected up front (reader-only)
                .gron => unreachable, // handled by the early return above
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
                    .gron => return error.UnsupportedGronEdit,
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
                .gron => return error.UnsupportedGronEdit,
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
/// single-grammar). YAML selects 1.2.2 (default) or 1.1; the versions differ in
/// scalar type resolution (see `scalarKind1_1` in the YAML parser).
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
        else if (eq(u8, s, "1.1") or eq(u8, s, "1.1.0"))
            .{ .yaml = .v1_1 }
        else
            error.UnsupportedSpec,
        .json, .jsonc, .json5, .zon, .xml, .native, .gron => error.UnsupportedSpec,
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
        // gron ("ungron") reconstructs the AST from its `path = value` lines,
        // reusing the JSON parser for each RHS — so it needs JSON compiled in.
        .gron => if (comptime build_options.lang_json) gron.parseDocument(allocator, content) else error.FormatDisabled,
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
        .insert_key => |key| try editor.insertKey(path, key, text),
        .set => try editor.set(path, text),
        .set_sequence => |items| try editor.setSequence(path, items),
        .append_seq => try editor.appendToSeq(path, text),
        .prepend_seq => try editor.prependToSeq(path, text),
        .delete_key => try editor.deleteKey(path),
        .remove_seq_item => |index| try editor.removeSeqItem(path, index),
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

    // Locate the region; when it's absent and the op can seed a fresh block
    // (`set` / insert-a-key), synthesize an empty one — the CLI's open-or-init.
    // `base` is the document the edited content splices back into: the original
    // file, or the synthesized host carrying the new empty block.
    var base: []const u8 = content;
    var created_host: ?[]u8 = null;
    defer if (created_host) |h| allocator.free(h);
    const region = reg: {
        if (fig.Embed.locateRegion(content, embed_type)) |r| {
            break :reg r;
        } else |err| switch (err) {
            error.NotFound => {
                if (!opSeedsEmptyRegion(op)) return err;
                const created = try fig.Embed.initRegion(allocator, content, embed_type);
                created_host = created.host;
                base = created.host;
                break :reg created.region;
            },
            else => return err,
        }
    };
    const inner = base[region.content.start..region.content.end];

    const edited_inner = switch (embed_type) {
        .FrontmatterYaml, .EndmatterYaml => if (comptime build_options.lang_yaml)
            try applyEdit(fig.Language.YAML, allocator, inner, path, text, op, fig.Language.YAML.default_type)
        else
            return error.FormatDisabled,
        // JSON frontmatter is plain (strict) JSON: an inserted/replaced key or
        // value is quoted as a JSON string, while a comment op rides through
        // unquoted and the editor rejects it (strict JSON has no comment syntax).
        .FrontmatterJson => if (comptime build_options.lang_json) blk: {
            const j = try jsonifyEdit(allocator, op, text);
            break :blk try applyEdit(fig.Language.JSON, allocator, inner, path, j.text, j.op, .JSON);
        } else return error.FormatDisabled,
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, base[0..region.content.start]);
    try out.appendSlice(allocator, edited_inner);
    try out.appendSlice(allocator, base[region.content.end..]);

    try file.writePositionalAll(io, out.items, 0);
    try file.setLength(io, out.items.len);
}

/// Whether `op` can seed a freshly-created empty embed region — only the ops
/// that establish a first entry (`set` upserts it; `insert_key` adds it). Other
/// ops (replace/delete/comment/sequence) require an already-present region.
fn opSeedsEmptyRegion(op: EditOp) bool {
    return switch (op) {
        .set, .insert_key => true,
        else => false,
    };
}

/// Recast an edit for a JSON-family target: strict JSON has no bare literals,
/// so an inserted/replaced key or value must be wrapped as a JSON string (parity
/// with `edit`'s value replacement). Comment and delete ops carry no value and
/// pass through untouched. Returns the (possibly requoted) text and op.
fn jsonifyEdit(allocator: std.mem.Allocator, op: EditOp, text: []const u8) !struct { text: []const u8, op: EditOp } {
    const text_out = switch (op) {
        .replace_value, .replace_key, .insert_key, .set, .append_seq, .prepend_seq => try std.fmt.allocPrint(allocator, "\"{s}\"", .{text}),
        // `set_sequence` carries its items in the op payload (requoted below);
        // comment ops and structural deletes carry no value text.
        .set_sequence, .add_leading_comment, .set_trailing_comment, .delete_leading_comments, .delete_trailing_comment, .delete_key, .remove_seq_item => text,
    };
    const op_out: EditOp = switch (op) {
        .insert_key => |key| .{ .insert_key = try std.fmt.allocPrint(allocator, "\"{s}\"", .{key}) },
        .set_sequence => |items| blk: {
            const quoted = try allocator.alloc([]const u8, items.len);
            for (items, 0..) |it, i| quoted[i] = try std.fmt.allocPrint(allocator, "\"{s}\"", .{it});
            break :blk .{ .set_sequence = quoted };
        },
        else => op,
    };
    return .{ .text = text_out, .op = op_out };
}

/// Shared per-format routing for the structural `insert`/`delete` actions —
/// the `edit` handler's format switch, minus the value-replacement specifics.
/// JSON-family inputs requote the inserted key/value via `jsonifyEdit`; YAML,
/// TOML, and ZON take the text verbatim as a literal. `embed` routes through the
/// host-document splicer instead. `op` already encodes which editor primitive
/// runs and `path` is the container path it operates on.
fn applyStructuralEdit(
    allocator: std.mem.Allocator,
    io: Io,
    input: Io.File,
    resolved: Format,
    embed: ?fig.Embed.Type,
    path: []fig.AST.PathSegment,
    text: []const u8,
    op: EditOp,
) !void {
    if (embed) |embed_type| return applyToEmbed(allocator, io, input, embed_type, path, text, op);
    switch (resolved) {
        .json, .jsonc => |f| if (comptime build_options.lang_json) {
            const j = try jsonifyEdit(allocator, op, text);
            try applyToFile(fig.Language.JSON, allocator, io, input, path, j.text, j.op, jsonDialect(f));
        } else return error.FormatDisabled,
        .yaml, .yml => if (comptime build_options.lang_yaml)
            try applyToFile(fig.Language.YAML, allocator, io, input, path, text, op, fig.Language.YAML.default_type)
        else
            return error.FormatDisabled,
        .toml => if (comptime build_options.lang_toml)
            try applyToFile(fig.Language.TOML, allocator, io, input, path, text, op, fig.Language.TOML.default_type)
        else
            return error.FormatDisabled,
        .zon => if (comptime build_options.lang_zon)
            try applyToFile(fig.Language.ZON, allocator, io, input, path, text, op, fig.Language.ZON.default_type)
        else
            return error.FormatDisabled,
        .xml => return error.UnsupportedXmlEdit,
        .json5 => return error.UnsupportedJson5Edit,
        .native => return error.UnsupportedNativeEdit,
        .gron => return error.UnsupportedGronEdit,
    }
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

                // `[-]` and `[$]` are the "end" tokens used by `insert` to append;
                // everything else is a literal index. The sentinel resolves to no
                // real item, so non-insert callers just see a NotFound.
                const inner = path[start..i];
                log.debug("number: {s}", .{inner});
                const seg: fig.AST.PathSegment = if (std.mem.eql(u8, inner, "-") or std.mem.eql(u8, inner, "$"))
                    .{ .index = append_index }
                else
                    .{ .index = try std.fmt.parseInt(usize, inner, 10) };
                try path_in_progress.append(allocator, seg);
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

/// Map a `--embed <archetype>` flag value to its `Embed.Type`. Lets any
/// embed-capable action target a region explicitly — not just the markdown-
/// extension default of YAML frontmatter — so endmatter and JSON frontmatter are
/// reachable. Returns null for an unknown name.
fn embedTypeFromName(name: []const u8) ?fig.Embed.Type {
    if (std.mem.eql(u8, name, "frontmatter") or std.mem.eql(u8, name, "frontmatter-yaml"))
        return .FrontmatterYaml;
    if (std.mem.eql(u8, name, "frontmatter-json")) return .FrontmatterJson;
    if (std.mem.eql(u8, name, "endmatter") or std.mem.eql(u8, name, "endmatter-yaml"))
        return .EndmatterYaml;
    return null;
}

const ArgError = error{ UnsupportedFileFormat, MissingEditArgument, MissingSetArgument, MissingInsertArgument, MissingDeleteArgument, MissingGetArgument, MissingCommentArgument, MissingCheckArgument, OutOfMemory, Overflow, InvalidCharacter, InvalidPath };

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
    } else if (std.mem.eql(u8, action_str, "set") or std.mem.eql(u8, action_str, "s")) {
        config.action = .set;

        // Leading flags in any order: `--seq`, `--embed <archetype>`, `--help`.
        // Positionals follow: file, path, then the value (or, with `--seq`, the
        // sequence items).
        var seq = false;
        var embed_override: ?fig.Embed.Type = null;
        var requested_help = false;
        var positionals: std.ArrayList([]const u8) = .empty;
        defer positionals.deinit(allocator);

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                requested_help = true;
            } else if (std.mem.eql(u8, arg, "--seq")) {
                seq = true;
            } else if (std.mem.eql(u8, arg, "--embed")) {
                const name = args.next() orelse {
                    log.err("Missing archetype after {s}\n", .{arg});
                    return ArgError.MissingSetArgument;
                };
                embed_override = embedTypeFromName(name) orelse {
                    log.err("Unknown --embed archetype: {s} (frontmatter, frontmatter-json, endmatter)\n", .{name});
                    return ArgError.UnsupportedFileFormat;
                };
            } else {
                try positionals.append(allocator, arg);
            }
        }

        if (requested_help) {
            config.options = .{ .set = .{ .file = "", .path = &.{}, .value = "", .requested_help = true, .format = .json } };
        } else {
            // Need file, path, and at least one value (a scalar, or one or more
            // sequence items with `--seq`).
            if (positionals.items.len < 3) {
                log.err("set needs a file, a path, and a value (e.g. `fig set f.yaml a.b 1`).\n", .{});
                return ArgError.MissingSetArgument;
            }
            const file_path = positionals.items[0];
            const path = try parsePath(allocator, positionals.items[1]);
            const ext = detectLanguageFromFileEnding(file_path);
            const embed = embed_override orelse (if (ext) |d| d.embed else null);
            config.options = .{ .set = .{
                .file = file_path,
                .path = path,
                .value = if (seq) "" else positionals.items[2],
                .seq = seq,
                .values = if (seq) try allocator.dupe([]const u8, positionals.items[2..]) else &.{},
                .requested_help = false,
                .format = if (ext) |d| d.format else .json,
                // Skip content sniffing when targeting an embed (the inner format
                // is fixed by the archetype) or when the extension resolved it.
                .detect = ext == null and embed == null,
                .embed = embed,
            } };
        }
    } else if (std.mem.eql(u8, action_str, "insert") or std.mem.eql(u8, action_str, "i")) {
        config.action = .insert;

        const file_path = args.next() orelse {
            log.err("No file provided.\n", .{});
            return ArgError.MissingInsertArgument;
        };
        const requested_help = std.mem.eql(u8, file_path, "--help") or std.mem.eql(u8, file_path, "-h");

        var path: []fig.AST.PathSegment = &.{};
        var value: []const u8 = "";
        if (!requested_help) {
            const path_str = args.next() orelse {
                log.err("No path provided.\n", .{});
                return ArgError.MissingInsertArgument;
            };
            path = try parsePath(allocator, path_str);

            value = args.next() orelse {
                log.err("No value provided.\n", .{});
                return ArgError.MissingInsertArgument;
            };
        }

        const ext = if (requested_help) null else detectLanguageFromFileEnding(file_path);
        config.options = .{ .insert = .{
            .file = file_path,
            .path = path,
            .value = value,
            .requested_help = requested_help,
            .format = if (ext) |d| d.format else .json,
            .detect = !requested_help and ext == null,
            .embed = if (ext) |d| d.embed else null,
        } };
    } else if (std.mem.eql(u8, action_str, "delete") or std.mem.eql(u8, action_str, "d")) {
        config.action = .delete;

        const file_path = args.next() orelse {
            log.err("No file provided.\n", .{});
            return ArgError.MissingDeleteArgument;
        };
        const requested_help = std.mem.eql(u8, file_path, "--help") or std.mem.eql(u8, file_path, "-h");

        var path: []fig.AST.PathSegment = &.{};
        if (!requested_help) {
            const path_str = args.next() orelse {
                log.err("No path provided.\n", .{});
                return ArgError.MissingDeleteArgument;
            };
            path = try parsePath(allocator, path_str);
        }

        const ext = if (requested_help) null else detectLanguageFromFileEnding(file_path);
        config.options = .{ .delete = .{
            .file = file_path,
            .path = path,
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
        // Explicit `--embed <archetype>` override and `--body` projection.
        var embed_override: ?fig.Embed.Type = null;
        var body = false;
        var serialize: fig.AST.SerializeOptions = .{};
        // gron projection overrides; null means "keep the gron default".
        var gron_root: ?[]const u8 = null;
        var gron_sep: ?[]const u8 = null;
        var gron_term: ?[]const u8 = null;
        var positionals: std.ArrayList([]const u8) = .empty;
        defer positionals.deinit(allocator);

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--lax-tags")) {
                lax_tags = true;
            } else if (std.mem.eql(u8, arg, "--gron-root")) {
                gron_root = args.next() orelse {
                    log.err("Missing value after {s}\n", .{arg});
                    return ArgError.MissingGetArgument;
                };
            } else if (std.mem.eql(u8, arg, "--gron-sep")) {
                gron_sep = args.next() orelse {
                    log.err("Missing value after {s}\n", .{arg});
                    return ArgError.MissingGetArgument;
                };
            } else if (std.mem.eql(u8, arg, "--gron-term")) {
                // Empty is allowed (drop the terminator entirely).
                gron_term = args.next() orelse {
                    log.err("Missing value after {s}\n", .{arg});
                    return ArgError.MissingGetArgument;
                };
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
            } else if (std.mem.eql(u8, arg, "--embed")) {
                const name = args.next() orelse {
                    log.err("Missing archetype after {s}\n", .{arg});
                    return ArgError.MissingGetArgument;
                };
                embed_override = embedTypeFromName(name) orelse {
                    log.err("Unknown --embed archetype: {s} (frontmatter, frontmatter-json, endmatter)\n", .{name});
                    return ArgError.UnsupportedFileFormat;
                };
            } else if (std.mem.eql(u8, arg, "--body")) {
                body = true;
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
                } else if (std.mem.eql(u8, fmt, "gron")) {
                    input_override = .gron;
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
                } else if (std.mem.eql(u8, fmt, "gron")) {
                    output_override = .gron;
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
        // An explicit `--embed` archetype wins over the extension-inferred one.
        const embed = embed_override orelse (if (detected_input) |d| d.embed else null);

        var gron_projection: gron.Projection = .gron;
        if (gron_root) |r| gron_projection.root_name = r;
        if (gron_sep) |s| gron_projection.assign = s;
        if (gron_term) |t| gron_projection.terminator = t;

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
            .body = body,
            .serialize = serialize,
            .quiet = quiet,
            .strict = strict,
            .gron_projection = gron_projection,
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

// A slice-backed stand-in for the process arg iterator `parseConfig` consumes.
const TestArgs = struct {
    items: []const []const u8,
    i: usize = 0,
    fn next(self: *TestArgs) ?[]const u8 {
        if (self.i >= self.items.len) return null;
        defer self.i += 1;
        return self.items[self.i];
    }
};

test "parsePath reads the [-]/[$] append sentinel and literal indices" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dash = try parsePath(a, "list[-]");
    try t.expectEqual(@as(usize, 2), dash.len);
    try t.expectEqualStrings("list", dash[0].key);
    try t.expectEqual(append_index, dash[1].index);

    const dollar = try parsePath(a, "list[$]");
    try t.expectEqual(append_index, dollar[1].index);

    const literal = try parsePath(a, "a.b[2]");
    try t.expectEqual(@as(usize, 2), literal[2].index);
}

test "parseConfig routes insert/delete to the right action and path tail" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // insert into a mapping: trailing key, value captured.
    var ins = TestArgs{ .items = &.{ "fig", "insert", "f.yaml", "a.newkey", "42" } };
    const ic = try parseConfig(a, &ins);
    try t.expectEqual(CliAction.insert, ic.action);
    try t.expectEqualStrings("newkey", ic.options.insert.path[1].key);
    try t.expectEqualStrings("42", ic.options.insert.value);
    try t.expectEqual(Format.yaml, ic.options.insert.format);

    // insert append onto a sequence: trailing sentinel index.
    var app = TestArgs{ .items = &.{ "fig", "insert", "f.yaml", "list[-]", "z" } };
    const ac = try parseConfig(a, &app);
    try t.expectEqual(append_index, ac.options.insert.path[1].index);

    // delete by index: format sniffed later, path tail is an index.
    var del = TestArgs{ .items = &.{ "fig", "delete", "f.toml", "list[1]" } };
    const dc = try parseConfig(a, &del);
    try t.expectEqual(CliAction.delete, dc.action);
    try t.expectEqual(@as(usize, 1), dc.options.delete.path[1].index);
    try t.expectEqual(Format.toml, dc.options.delete.format);
}

test "applyEdit performs the structural ops on YAML" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const t = std.testing;
    const Y = fig.Language.YAML;
    const dia = Y.default_type;

    // insert_key appends a mapping entry.
    {
        const out = try applyEdit(Y, t.allocator, "a: 1\n", &.{}, "2", .{ .insert_key = "b" }, dia);
        defer t.allocator.free(out);
        try t.expectEqualStrings("a: 1\nb: 2\n", out);
    }
    // append_seq / prepend_seq on a block sequence.
    {
        const app = try applyEdit(Y, t.allocator, "- x\n- y\n", &.{}, "z", .append_seq, dia);
        defer t.allocator.free(app);
        try t.expectEqualStrings("- x\n- y\n- z\n", app);

        const pre = try applyEdit(Y, t.allocator, "- x\n- y\n", &.{}, "w", .prepend_seq, dia);
        defer t.allocator.free(pre);
        try t.expectEqualStrings("- w\n- x\n- y\n", pre);
    }
    // delete_key removes a mapping entry; remove_seq_item drops an item.
    {
        var dk_path = [_]fig.AST.PathSegment{.{ .key = "a" }};
        const dk = try applyEdit(Y, t.allocator, "a: 1\nb: 2\n", &dk_path, "", .delete_key, dia);
        defer t.allocator.free(dk);
        try t.expectEqualStrings("b: 2\n", dk);

        const ri = try applyEdit(Y, t.allocator, "- x\n- y\n- z\n", &.{}, "", .{ .remove_seq_item = 1 }, dia);
        defer t.allocator.free(ri);
        try t.expectEqualStrings("- x\n- z\n", ri);
    }
}

test "applyEdit set upserts a scalar and reconciles a sequence on YAML" {
    if (comptime !build_options.lang_yaml) return error.SkipZigTest;
    const t = std.testing;
    const Y = fig.Language.YAML;
    const dia = Y.default_type;

    // set replaces an existing key …
    {
        var p = [_]fig.AST.PathSegment{.{ .key = "a" }};
        const out = try applyEdit(Y, t.allocator, "a: 1\nb: 2\n", &p, "9", .set, dia);
        defer t.allocator.free(out);
        try t.expectEqualStrings("a: 9\nb: 2\n", out);
    }
    // … and creates an absent one.
    {
        var p = [_]fig.AST.PathSegment{.{ .key = "c" }};
        const out = try applyEdit(Y, t.allocator, "a: 1\n", &p, "3", .set, dia);
        defer t.allocator.free(out);
        try t.expectEqualStrings("a: 1\nc: 3\n", out);
    }
    // set on an empty document seeds the first key — the open-or-init seed case.
    {
        var p = [_]fig.AST.PathSegment{.{ .key = "k" }};
        const out = try applyEdit(Y, t.allocator, "", &p, "v", .set, dia);
        defer t.allocator.free(out);
        try t.expectEqualStrings("k: v\n", out);
    }
    // set_sequence reconciles to the target list, keeping survivors' comments.
    {
        var p = [_]fig.AST.PathSegment{.{ .key = "tags" }};
        const items = [_][]const u8{ "c", "a", "d" };
        const out = try applyEdit(Y, t.allocator, "tags:\n- a # first\n- b # second\n- c # third\n", &p, "", .{ .set_sequence = &items }, dia);
        defer t.allocator.free(out);
        try t.expectEqualStrings("tags:\n- c # third\n- a # first\n- d\n", out);
    }
}

test "jsonifyEdit quotes inserted key and value, leaves deletes bare" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ins = try jsonifyEdit(a, .{ .insert_key = "k" }, "v");
    try t.expectEqualStrings("\"v\"", ins.text);
    try t.expectEqualStrings("\"k\"", ins.op.insert_key);

    const app = try jsonifyEdit(a, .append_seq, "v");
    try t.expectEqualStrings("\"v\"", app.text);

    const del = try jsonifyEdit(a, .delete_key, "");
    try t.expectEqualStrings("", del.text);
    try t.expectEqual(EditOp.delete_key, del.op);

    // set quotes its value; set_sequence requotes each item.
    const s = try jsonifyEdit(a, .set, "v");
    try t.expectEqualStrings("\"v\"", s.text);
    try t.expectEqual(EditOp.set, s.op);

    const items = [_][]const u8{ "x", "y" };
    const sq = try jsonifyEdit(a, .{ .set_sequence = &items }, "");
    try t.expectEqualStrings("\"x\"", sq.op.set_sequence[0]);
    try t.expectEqualStrings("\"y\"", sq.op.set_sequence[1]);
}

test "embedTypeFromName maps archetype names" {
    const t = std.testing;
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterYaml), embedTypeFromName("frontmatter"));
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterYaml), embedTypeFromName("frontmatter-yaml"));
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterJson), embedTypeFromName("frontmatter-json"));
    try t.expectEqual(@as(?fig.Embed.Type, .EndmatterYaml), embedTypeFromName("endmatter"));
    try t.expectEqual(@as(?fig.Embed.Type, null), embedTypeFromName("bogus"));
}

test "parseConfig routes set, --seq, and --embed" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Scalar upsert: path + value captured, format from extension.
    var s = TestArgs{ .items = &.{ "fig", "set", "f.yaml", "a.b", "1" } };
    const sc = try parseConfig(a, &s);
    try t.expectEqual(CliAction.set, sc.action);
    try t.expectEqualStrings("b", sc.options.set.path[1].key);
    try t.expectEqualStrings("1", sc.options.set.value);
    try t.expect(!sc.options.set.seq);
    try t.expectEqual(Format.yaml, sc.options.set.format);

    // --seq collects the trailing items into `values`.
    var sq = TestArgs{ .items = &.{ "fig", "set", "--seq", "f.yaml", "tags", "x", "y", "z" } };
    const sqc = try parseConfig(a, &sq);
    try t.expect(sqc.options.set.seq);
    try t.expectEqual(@as(usize, 3), sqc.options.set.values.len);
    try t.expectEqualStrings("z", sqc.options.set.values[2]);

    // --embed selects the archetype explicitly (endmatter here).
    var em = TestArgs{ .items = &.{ "fig", "set", "--embed", "endmatter", "post.md", "k", "v" } };
    const emc = try parseConfig(a, &em);
    try t.expectEqual(@as(?fig.Embed.Type, .EndmatterYaml), emc.options.set.embed);
}

test "resolveSpec maps YAML version strings" {
    const t = std.testing;
    // Default (no --spec) yields each language's default; YAML default is 1.2.2.
    try t.expectEqual(fig.Language.YAML.default_type, (try resolveSpec(.yaml, null)).yaml);
    try t.expectEqual(@as(fig.Language.YAML.Type, .v1_2_2), (try resolveSpec(.yaml, "1.2.2")).yaml);
    try t.expectEqual(@as(fig.Language.YAML.Type, .v1_2_2), (try resolveSpec(.yaml, "1.2")).yaml);
    // 1.1 is now selectable (was previously rejected as UnsupportedSpec).
    try t.expectEqual(@as(fig.Language.YAML.Type, .v1_1), (try resolveSpec(.yaml, "1.1")).yaml);
    try t.expectEqual(@as(fig.Language.YAML.Type, .v1_1), (try resolveSpec(.yaml, "1.1.0")).yaml);
    try t.expectEqual(@as(fig.Language.YAML.Type, .v1_1), (try resolveSpec(.yml, "1.1")).yaml);
    // Unknown YAML versions still error.
    try t.expectError(error.UnsupportedSpec, resolveSpec(.yaml, "1.3"));
    try t.expectError(error.UnsupportedSpec, resolveSpec(.yaml, "2"));
}

// Pull the CLI-only gron module's tests into the exe test binary (it is not part
// of the `fig` library, so `root.zig`'s test graph never reaches it).
test {
    _ = gron;
}
