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
const diff = @import("cli/diff.zig");

// Logging for the CLI binary. `std.log`'s default handler (`std.log.defaultLog`)
// writes to stderr through `std.Options.debug_io` — a statically initialized,
// globally-shared `Io.Threaded` singleton, deliberately independent from the
// application's own `Io` instance (see the doc comment on `debug_io`). That
// means it opens its own positional `Io.File.Writer` over fd 2, separate from
// `stderr_terminal` below, each tracking its own `pos` from 0. When stderr is a
// regular file (redirected to disk rather than a tty), both writers do
// `pwrite`-style positional writes, so whichever one flushes second overwrites
// bytes the other already wrote instead of appending after them — corrupting
// the output. (Interleaving on a tty is harmless because tty writes are
// non-positional appends; the corruption only bites on redirection, which is
// why this was easy to miss.) Route `std.log` through `stderr_terminal` once
// `main` has constructed it, so there is only ever one `Io.File.Writer`/one
// `pos` counter over stderr.
pub const std_options: std.Options = .{ .logFn = logFn };

/// Set by `main` right after `stderr_terminal` is constructed. `null` before
/// that point (there are no `std.log` call sites that early), in which case we
/// fall back to the stdlib default.
var g_log_terminal: ?*Io.Terminal = null;

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const t = g_log_terminal orelse return std.log.defaultLog(level, scope, format, args);
    std.log.defaultLogFileTerminal(level, scope, format, args, t.*) catch return;
    // `std.log.defaultLog` flushes before returning (its `unlockStderr` does
    // so implicitly); match that so a log line right before `process.exit`
    // isn't lost sitting in `stderr_terminal`'s buffer.
    t.writer.flush() catch {};
}

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
// `canonical` (formerly `native`) is the AST's 1:1 oracle encoding, selectable
// only via `--input/--output canonical` — it owns no file extension. `fig` is
// the human-facing authoring dialect: it owns `.figl` (with `.fig` still
// accepted for back-compat), has a reader + `fig fmt`
// printer (see `get`), and `Editor(fig.Language.FIG)` wires `edit`/`set`/
// `insert`/`delete`/`comment` through the same span-splice engine as
// TOML/YAML/ZON (see `fig/editor_helper.zig`, which also carries the
// whole-container structural ops — `deleteContainer`/`moveContainer`/
// `reorderContainers`, fig's twins of TOML's `deleteTable`/`moveTable`/
// `reorderTables` — library-level only, same as TOML's). `gron` is a CLI-only
// echo format with no
// `AST.SerializeFormat` counterpart.
const Format = enum { json, jsonc, json5, yaml, yml, toml, zon, xml, canonical, fig, gron };

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
    fmt,
    convert,
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
        /// Set when `embed` couldn't be pinned by the extension (e.g. `.md`
        /// implies SOME embedded region but not which archetype): the handler
        /// sniffs the host content with `Embed.detect` (see `resolveEmbedType`).
        detect_embed: bool = false,
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
        /// As in `edit`: set when `embed` needs a runtime content sniff
        /// (`resolveEmbedType`) rather than being pinned by `--embed`.
        detect_embed: bool = false,
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
        /// As in `edit`: set when `embed` needs a runtime content sniff.
        detect_embed: bool = false,
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
        /// As in `edit`: set when `embed` needs a runtime content sniff.
        detect_embed: bool = false,
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
        /// As in `edit`: set when `embed` needs a runtime content sniff
        /// (`resolveEmbedType`) rather than being pinned by `--embed`.
        detect_embed: bool = false,
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
        /// As in `edit`: set when `embed` needs a runtime content sniff.
        detect_embed: bool = false,
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
    fmt: struct {
        /// The file to reformat in place. `-` reads stdin — only valid with
        /// `dry_run` (there is nowhere to write an in-place result back to).
        file: []const u8,
        /// The single format `fmt` parses AND re-emits — unlike `get`, there is
        /// no `--output`: reformatting never changes the document's format.
        from: Format,
        requested_help: bool = false,
        /// Set when `from` could not be inferred from the file extension and no
        /// `--input` was given: the handler sniffs the contents with
        /// `Language.detect`.
        detect: bool = false,
        /// Output style — see `get`'s twin field.
        serialize: fig.AST.SerializeOptions = .{},
        /// Suppress the lossy-conversion (e.g. `--strip-comments`) and fig
        /// authoring-lint warnings normally written to stderr.
        quiet: bool = false,
        /// Treat any warning as an error (exit non-zero without writing).
        strict: bool = false,
        /// Print the reformatted result to stdout instead of writing it back,
        /// and exit 1 if reformatting would change the file (0 if already
        /// clean) — the CI-friendly "would this file's formatting change" gate.
        dry_run: bool = false,
        /// Like `dry_run`, but print a unified diff of the change instead of
        /// the whole reformatted file (nothing is written either way).
        diff: bool = false,
        /// When set, `file` is a host document (e.g. markdown) and only its
        /// embedded region is reformatted, spliced back in place.
        embed: ?fig.Embed.Type = null,
        /// As in `get`: set when `embed` needs a runtime content sniff
        /// (`resolveEmbedTypeFromContent`) rather than being pinned by `--embed`.
        detect_embed: bool = false,
    },
    convert: struct {
        /// The file to convert in place. `-` reads stdin — only valid with
        /// `dry_run`/`diff`, same restriction as `fmt`.
        file: []const u8,
        requested_help: bool = false,
        /// Whole-file mode (`--output`): parse as `from`, re-emit as `to`.
        /// Mutually exclusive with the embed-archetype mode (`to_embed`) — one
        /// of the two must be set, checked in `parseConfig`.
        from: Format = .json,
        to: Format = .json,
        /// Set when `from` couldn't be pinned by `--input`/the file extension:
        /// the handler sniffs the contents with `Language.detect`, mirroring
        /// `fmt`/`get`.
        detect: bool = false,
        /// Embed-archetype mode (`--to-embed <archetype>`): rehouse a host
        /// document's embedded region from one archetype's fence-and-format
        /// convention to another's (e.g. YAML frontmatter → JSON frontmatter),
        /// splicing the new fences + re-serialized content in place while
        /// leaving the host prose (`Embed.Region.body`) byte-identical. `to`/
        /// `from`/`detect` are unused in this mode; the archetypes fix both
        /// formats.
        to_embed: ?fig.Embed.Type = null,
        /// The source archetype for embed-archetype mode: `--embed`, else —
        /// when `detect_embed` is set — sniffed from the content with
        /// `Embed.detect` (the extension alone, e.g. `.md`, only tells us an
        /// embed is likely present, never which archetype it is).
        embed: ?fig.Embed.Type = null,
        /// Set when `embed` couldn't be pinned by `--embed` and `to_embed` is
        /// set: the handler sniffs the host content with `Embed.detect`.
        detect_embed: bool = false,
        /// As in `get`: drop unknown/custom YAML tags instead of erroring,
        /// when converting away from YAML.
        lax_tags: bool = false,
        /// As in `get`: preserve values the target can't represent natively
        /// through a `$fig` envelope, and decode any such envelope on input.
        lossless: bool = false,
        serialize: fig.AST.SerializeOptions = .{},
        quiet: bool = false,
        strict: bool = false,
        /// Print the converted result to stdout instead of writing it back,
        /// and exit 1 if the conversion would change the file's bytes.
        dry_run: bool = false,
        /// Like `dry_run`, but print a unified diff instead of the whole
        /// converted file.
        diff: bool = false,
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
            \\  set: upsert a value (create the key, embed block, or file, if absent)
            \\  insert: add a new key or list item to a file
            \\  delete: remove a key or list item from a file
            \\  get: print a file or a specific part of a file to stdout
            \\  comment: add or edit a comment on part of a file
            \\  check: validate that one or more files parse cleanly
            \\  fmt: reformat a file in place (house style; gofmt-style)
            \\  convert: convert a file (or a host document's embedded region)
            \\    from one format/archetype to another, in place
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
            \\  .md/.markdown files: edits the frontmatter/endmatter in place —
            \\    its archetype (YAML/JSON/fig frontmatter, YAML endmatter) is
            \\    sniffed from the file, defaulting to YAML when none is found
            \\
        , .{binary_name});
        try term.writer.flush();
    }

    fn set(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage: {s} set [--embed <archetype>] <file> <path> <value>
            \\       {s} set [--embed <archetype>] --seq <file> <path> <item>...
            \\  Upsert: replace the value at <path>, or create it when absent —
            \\    one verb for `edit`+`insert`. Missing parent maps along <path>
            \\    are auto-created (`mkdir -p`); a segment that is an existing
            \\    non-map scalar is a type error and left untouched.
            \\  When <file> itself does not exist, it is CREATED and seeded with
            \\    <path>: <value>; `fig get <file>` then prints what was written.
            \\    The format comes from the extension, so a new file needs a known
            \\    one — .figl (.fig also accepted)/.json/.jsonc/.yaml/.yml/.toml (or a .md host, via
            \\    --embed). .zon/.json5 have no from-scratch seed and must already
            \\    exist.
            \\  --seq: reconcile the sequence at <path> to exactly <item>..., keeping
            \\    the comments on items that survive (only new items are inserted,
            \\    only dropped ones removed; result order matches the arguments).
            \\  --embed <archetype>: target an embedded region of a host file —
            \\    `frontmatter` (---/YAML), `frontmatter-json`
            \\    (;;;/JSON), `frontmatter-fig` (```fig fenced block), or
            \\    `endmatter` (trailing ```endmatter block). When the host has no
            \\    such block, it is CREATED (frontmatter at the top, endmatter at
            \\    the bottom) and seeded with <path>: <value>.
            \\  value: a literal in the target format (YAML/TOML/ZON verbatim; JSON
            \\    is quoted as a string, as with `edit`). A created key is rendered
            \\    in the target syntax too, so new keys work for strict JSON.
            \\  path format: dot syntax for keys, bracket syntax for indices
            \\    example: school.class[0].student[3]
            \\  .md/.markdown files: upserts the frontmatter/endmatter, creating
            \\    it (as YAML) if absent — the archetype is otherwise sniffed
            \\    from the file, not assumed from the extension.
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
            \\  .md/.markdown files: edits the frontmatter/endmatter in place —
            \\    its archetype is sniffed from the file (YAML by default).
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
            \\    a.list[-]    -> remove the last item of the sequence a.list
            \\  path format: dot syntax for keys, bracket syntax for indices
            \\    example: school.class[0].student[3]
            \\    [-] or [$] in place of an index means "the last item"
            \\  .md/.markdown files: edits the frontmatter/endmatter in place —
            \\    its archetype is sniffed from the file (YAML by default).
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
            \\  .md/.markdown files: comments the frontmatter/endmatter in
            \\    place — its archetype is sniffed from the file (YAML by
            \\    default).
            \\
        , .{binary_name});
        try term.writer.flush();
    }

    fn get(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage: {s} get [--input json|json5|yaml|toml|zon|xml|canonical|fig|gron] [--output json|json5|yaml|toml|zon|xml|canonical|fig|gron] <file> [path]
            \\  -i, --input: input format of file (defaults to the file extension,
            \\    then to sniffing the file's contents if the extension is unknown)
            \\  -o, --output:   output format (defaults to the input format)
            \\  canonical: the AST's 1:1 oracle text encoding; usable as input or
            \\    output, e.g. to inspect how any document parses. (Owns no file
            \\    extension — select it explicitly.)
            \\  fig: the human-facing authoring dialect (`.figl`; `.fig` still
            \\    accepted); lossy at the edges (non-string keys, YAML refs) —
            \\    use `canonical`/`--lossless` for those. `-o fig` prints in
            \\    house style; use `fig fmt` to
            \\    rewrite a file in place instead of printing to stdout.
            \\  xml: config-oriented, not a general XML tool — an element becomes
            \\    a mapping, `@name` attributes and `#text` mixed content fold
            \\    into it, repeated children become an array. `-o xml` requires
            \\    the document to have exactly one root key; every scalar
            \\    (numbers, booleans, ...) prints as plain text, since XML has no
            \\    other type. Compiled in only with `-Dxml=true` (opt-in, off by
            \\    default). No in-place editor yet (`edit`/`comment` reject it).
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
            \\  -q, --quiet: suppress warnings on stderr — lossy conversions, and
            \\    fig authoring lints (`Yes`-style strings, a likely missing comma
            \\    in a flow value, indent/marker-count disagreement, ...).
            \\  --strict: treat any warning as an error (exit non-zero).
            \\  --embed <archetype>: read an embedded region of a host file —
            \\    `frontmatter`, `frontmatter-json`, `frontmatter-fig`, or
            \\    `endmatter`. Without this flag, a `.md`/`.markdown` file has
            \\    its archetype sniffed from the content (falling back to
            \\    `frontmatter`/YAML when none is found).
            \\  --body: print the host prose OUTSIDE the fences (the body span) instead
            \\    of the embed content; the whole file when there is no such region.
            \\  path format: dot syntax for keys, bracket syntax for indices
            \\    example: school.class[0].student[3]
            \\  .md/.markdown files: reads the frontmatter/endmatter, whichever
            \\    archetype it turns out to be
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
            \\    yaml, toml, zon, xml, canonical). Default: infer from each
            \\    file's extension, then by sniffing its contents.
            \\  -s, --spec: validate against a specific language version, where one
            \\    is selectable: TOML `1.0`/`1.1` (default 1.1), YAML `1.2.2`/`1.1`
            \\    (default 1.2.2).
            \\    JSON strictness is the format itself (json vs jsonc vs json5).
            \\  -q, --quiet: suppress the per-file `ok` lines and fig authoring
            \\    warnings; errors still print.
            \\  reads stdin when <file> is `-`.
            \\  .md/.markdown files: validates the frontmatter/endmatter,
            \\    whichever archetype it turns out to be (YAML by default).
            \\
        , .{binary_name});
        try term.writer.flush();
    }

    fn fmt(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage: {s} fmt [--input <format>] [--dry-run | --diff] <file>
            \\  Reformat a file in place: parse then re-emit in the format's house
            \\  style — `.figl`'s printer applies the style DESIGN.md describes
            \\  (spaced marker runs, `[]`/`+` list sigils, ...); other formats get
            \\  their own printer's canonical layout. Unlike `get`, the output
            \\  format always matches the input — reformatting never converts.
            \\  A file already in house style is left byte-identical (no-op write).
            \\  --dry-run: print the reformatted result to stdout instead of
            \\    writing it back; exit 1 if reformatting would change the file,
            \\    0 if it's already clean — a check gate for pre-commit/CI.
            \\  --diff: like --dry-run, but print a unified diff of the change to
            \\    stdout instead of the whole reformatted file; nothing is printed
            \\    (and exit is 0) when the file is already clean.
            \\  -i, --input: input format (defaults to the file extension, then
            \\    to sniffing the file's contents if the extension is unknown).
            \\  --compact: single-line output with minimal whitespace (JSON, JSON5, ZON).
            \\  --pretty: multi-line, indented output (the default).
            \\  --indent N: spaces per indent level for pretty JSON, and for TOML's
            \\    wrapped arrays (default 2).
            \\  --width N: TOML column budget (default 80); a mapping/array that fits
            \\    stays inline, a wider one expands to a [section] / wrapped array.
            \\  --strip-comments: drop comments instead of re-emitting them.
            \\  -q, --quiet: suppress warnings on stderr.
            \\  --strict: treat any warning as an error (exit non-zero, no write).
            \\  --embed <archetype>: reformat an embedded region of a host file —
            \\    `frontmatter`, `frontmatter-json`, `frontmatter-fig`, or
            \\    `endmatter` — instead of the whole file. Without this flag, a
            \\    `.md`/`.markdown` file has its archetype sniffed from the
            \\    content (falling back to `frontmatter`/YAML when none is found).
            \\  reads stdin when <file> is `-`, but only with --dry-run/--diff:
            \\    there is nowhere to write an in-place result back to.
            \\  .md/.markdown files: reformats the frontmatter/endmatter in
            \\    place, whichever archetype it turns out to be.
            \\
        , .{binary_name});
        try term.writer.flush();
    }

    fn convert(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage: {s} convert --output <format> [--input <format>] [--dry-run | --diff] <file>
            \\       {s} convert --to-embed <archetype> [--embed <archetype>] [--dry-run | --diff] <file>
            \\  Convert a file in place — `fmt`'s twin for when the target format
            \\  differs from the source. Exactly one of --output/--to-embed picks
            \\  the target; the other flag group is unused (rejected together).
            \\
            \\  Whole-file mode (--output): parse the whole file as --input (else the
            \\    extension, else sniffed from its contents) and re-emit it as
            \\    --output, in the target format's house style. A host document
            \\    whose extension implies an embedded region (`.md`/`.markdown`) is
            \\    rejected here — use embed-archetype mode, or pass --input to force
            \\    whole-file conversion anyway.
            \\  -i, --input, -o, --output: json, json5, yaml, toml, zon, xml, canonical,
            \\    fig. `-o xml` requires the document to convert to have exactly one
            \\    root key (see `get --help`'s `xml:` entry); xml is compiled in only
            \\    with `-Dxml=true`.
            \\
            \\  Embed-archetype mode (--to-embed): rehouse a host document's
            \\    embedded region from one archetype's fence-and-content convention
            \\    to another's — e.g. turn YAML frontmatter into JSON frontmatter —
            \\    splicing the new fences and re-serialized content in place while
            \\    leaving the surrounding prose byte-identical. The source archetype
            \\    is --embed, else sniffed from the file's own fences (falling back
            \\    to frontmatter/YAML when none is found).
            \\  --embed, --to-embed <archetype>: frontmatter (---/YAML), frontmatter-json
            \\    (;;;/JSON), frontmatter-fig (```fig fenced block), or endmatter
            \\    (trailing ```endmatter block).
            \\
            \\  --dry-run: print the converted result to stdout instead of writing
            \\    it back; exit 1 if conversion would change the file, 0 if it's
            \\    already in the target format.
            \\  --diff: like --dry-run, but print a unified diff instead of the
            \\    whole converted file.
            \\  --compact / --pretty: single-line vs multi-line output (default pretty).
            \\  --indent N / --width N: as in `get`/`fmt`.
            \\  --strip-comments: drop comments instead of carrying them across formats.
            \\  --lossless / --lossy: preserve values the target can't represent
            \\    natively via a $fig envelope (default --lossy).
            \\  --lax-tags: drop unknown/custom YAML tags instead of erroring, when
            \\    converting away from YAML.
            \\  -q, --quiet: suppress warnings on stderr.
            \\  --strict: treat any warning as an error (exit non-zero, no write).
            \\  reads stdin when <file> is `-`, but only with --dry-run/--diff.
            \\
        , .{ binary_name, binary_name });
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
    // From here on, route `std.log` through this same writer (see `logFn`) so
    // it can't clobber `stderr_terminal`'s bytes when stderr is redirected.
    g_log_terminal = &stderr_terminal;

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
        ArgError.MissingFmtArgument => {
            try Help.fmt(&stderr_terminal, "fig");
            std.process.exit(2);
        },
        ArgError.MissingConvertArgument => {
            try Help.convert(&stderr_terminal, "fig");
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
            if (try resolveEmbedType(io, init.arena.allocator(), input, opts.embed, opts.detect_embed)) |embed_type| {
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
                // The canonical form is a parse/print pair with no span-splicing
                // editor; convert via `get` instead of editing in place.
                .canonical => return error.UnsupportedCanonicalEdit,
                // fig value/key replacement: `Editor(Fig)` splices the exact
                // node span (`Fig.Parser` now tracks real spans — see
                // `fig/parser.zig`'s "AST assembly" section), same as TOML.
                // The replacement is taken verbatim as a fig literal.
                .fig => if (comptime build_options.lang_fig)
                    try applyToFile(fig.Language.FIG, init.arena.allocator(), io, input, opts.path, opts.replacement, op, fig.Language.FIG.default_type)
                else
                    return error.FormatDisabled,
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
            if (opts.path.len == 0) {
                try stderr_terminal.writer.print("error: set needs a path to the key (or, with --seq, the sequence) to upsert.\n", .{});
                try stderr_terminal.writer.flush();
                std.process.exit(2);
            }
            // `set` upserts, so it may target a file that doesn't exist yet:
            // create it and seed a minimal valid empty document (see
            // `createSeededFile`/`emptyDocSeed`) so the editor lands the first
            // key into a parseable buffer. The other structural actions keep the
            // plain open — they edit what's already there and have nothing to
            // seed into a blank file. Two cases refuse the create up front,
            // before any file lands on disk:
            //   - a freshly created file is empty, so its format can't be sniffed
            //     (`--detect`): it must carry a known extension;
            //   - a format with no empty-document form (`emptyDocSeed` == null,
            //     e.g. fig) has nothing valid to seed.
            // When targeting an embed, the host is seeded empty ("") and the
            // embed machinery (`initRegion`) synthesizes the inner block itself.
            var created = false;
            const input = getInput(io, opts.file, .read_write) catch |err| switch (err) {
                error.FileNotFound => blk: {
                    if (std.mem.eql(u8, opts.file, "-")) return err;
                    if (opts.detect) {
                        try stderr_terminal.writer.print("error: cannot create {s}: an unrecognized extension gives no format to seed. Use a known extension (.json/.jsonc/.yaml/.toml/.zon) or an existing file.\n", .{opts.file});
                        try stderr_terminal.writer.flush();
                        std.process.exit(2);
                    }
                    const seed: []const u8 = if (opts.embed != null or opts.detect_embed) "" else emptyDocSeed(opts.format) orelse {
                        try stderr_terminal.writer.print("error: cannot create {s}: {s} has no empty-document form to seed a new file. Start from an existing file.\n", .{ opts.file, @tagName(opts.format) });
                        try stderr_terminal.writer.flush();
                        std.process.exit(2);
                    };
                    created = true;
                    break :blk try createSeededFile(io, opts.file, seed);
                },
                else => return err,
            };
            defer if (!std.mem.eql(u8, opts.file, "-")) input.close(io);

            const resolved = if (opts.detect) try detectFileFormat(io, a, opts.file) else opts.format;
            // `--seq` reconciles the sequence at `path`; otherwise upsert a scalar.
            // Both flow through the shared structural-edit router, so the embed
            // path (which open-or-inits a missing block) is reused for free.
            const op: EditOp = if (opts.seq) .{ .set_sequence = opts.values } else .set;
            const text: []const u8 = if (opts.seq) "" else opts.value;
            // On a from-scratch create, roll the new file back if the edit fails
            // (e.g. a path whose parent segment resolves to a scalar, which `set`
            // refuses rather than clobber) so a failed `set` leaves no bare seed
            // behind — matching how it leaves an existing file untouched on
            // failure. A merely-missing parent map is no longer a failure: `set`
            // auto-vivifies it (see `Editor.set`).
            const embed = try resolveEmbedType(io, a, input, opts.embed, opts.detect_embed);
            applyStructuralEdit(a, io, input, resolved, embed, opts.path, text, op) catch |err| {
                if (created) deleteCreatedFile(io, opts.file);
                return err;
            };
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
            const embed = try resolveEmbedType(io, a, input, opts.embed, opts.detect_embed);
            switch (opts.path[opts.path.len - 1]) {
                .key => |key| try applyStructuralEdit(a, io, input, resolved, embed, parent, opts.value, .{ .insert_key = key }),
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
                    try applyStructuralEdit(a, io, input, resolved, embed, parent, opts.value, op);
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
            const embed = try resolveEmbedType(io, a, input, opts.embed, opts.detect_embed);
            // A trailing index removes that item from the parent sequence; a
            // trailing key deletes the mapping entry named by the full path.
            switch (opts.path[opts.path.len - 1]) {
                .index => |index| try applyStructuralEdit(a, io, input, resolved, embed, opts.path[0 .. opts.path.len - 1], "", .{ .remove_seq_item = index }),
                .key => try applyStructuralEdit(a, io, input, resolved, embed, opts.path, "", .delete_key),
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
                const content = try readAll(init.arena.allocator(), io, input);
                const embed_type = resolveEmbedTypeFromContent(content, opts.embed, opts.detect_embed) orelse fig.Embed.Type.FrontmatterYaml;
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

            const doc = if (try resolveEmbedType(io, init.arena.allocator(), input, opts.embed, opts.detect_embed)) |embed_type| blk_embed: {
                // `embed_type` may have just been sniffed at runtime
                // (`detect_embed`), in which case the parse-time
                // placeholder `from`/`to` (the extension's guess, not the
                // real archetype) needs correcting: the inner format
                // always follows the archetype outright, and — same as
                // the whole-file `detect` echo below — an unpinned
                // output follows it too rather than silently defaulting
                // to something else (e.g. `.yaml` for a `.md` file whose
                // actual frontmatter turned out to be fig or JSON).
                from = embedFormat(embed_type);
                if (!opts.output_explicit) to = from;
                break :blk_embed try parseEmbeddedFromFile(init.arena.allocator(), io, input, embed_type);
            } else blk: {
                // Read once so detection and parsing share the same bytes — a
                // piped stdin can only be consumed a single time.
                const content = try readAll(init.arena.allocator(), io, input);
                if (opts.detect) {
                    from = try resolveFormatFromContent(init.arena.allocator(), content, opts.file);
                    if (!opts.output_explicit) to = from;
                }
                var fig_report: fig.Language.FIG.Parser.Report = .{};
                var json_report: fig.Language.JSON.Parser.Report = .{};
                var toml_report: fig.Language.TOML.Parser.Report = .{};
                const parsed = parseSliceAs(from, .{}, init.arena.allocator(), content, false, .{ .fig = &fig_report, .json = &json_report, .toml = &toml_report }) catch |err| {
                    // A parse failure renders as a `file:line:col` teaching
                    // message (DESIGN.md: every diagnostic names the fix) and
                    // exits cleanly — no error-return trace for a user typo.
                    // Only fig/JSON/TOML fill a report so far; every other
                    // format still falls through to the bare `return err`.
                    if (fig_report.diag) |d|
                        try reportParseError(&stderr_terminal, content, opts.file, d.offset, d.end, fig.Language.FIG.Parser.describe(d.code), fig.Language.FIG.Parser.shortLabel(d.code));
                    if (json_report.diag) |d|
                        try reportParseError(&stderr_terminal, content, opts.file, d.offset, d.end, fig.Language.JSON.Parser.describe(d.code), fig.Language.JSON.Parser.shortLabel(d.code));
                    if (toml_report.diag) |d|
                        try reportParseError(&stderr_terminal, content, opts.file, d.offset, d.end, fig.Language.TOML.Parser.describe(d.code), fig.Language.TOML.Parser.shortLabel(d.code));
                    return err;
                };
                // Authoring-time lints (parse-time warnings) ride the same
                // `--quiet`/`--strict` contract as the serialize-side
                // diagnostics below: quiet silences, strict aborts.
                try handleParseWarnings(&stderr_terminal, content, opts.file, "fig authoring", fig_report.warnings, fig.Language.FIG.Parser.Warning.describeWarning, fig.Language.FIG.Parser.Warning.shortLabel, opts.quiet, opts.strict);
                try handleParseWarnings(&stderr_terminal, content, opts.file, "JSON authoring", json_report.warnings, fig.Language.JSON.Parser.Warning.describeWarning, fig.Language.JSON.Parser.Warning.shortLabel, opts.quiet, opts.strict);
                try handleParseWarnings(&stderr_terminal, content, opts.file, "TOML authoring", toml_report.warnings, fig.Language.TOML.Parser.Warning.describeWarning, fig.Language.TOML.Parser.Warning.shortLabel, opts.quiet, opts.strict);
                break :blk parsed;
            };

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
                    // Canonical encodes every node kind directly, so no envelope
                    // is needed on output — only decode envelopes found in input.
                    // fig shares canonical's node model (same AST, no distinct
                    // envelope value-space of its own), so it gets the same
                    // decode-only treatment; a node fig can't natively spell
                    // (non-string key, YAML alias, scalar root) is the
                    // documented "no authoring spelling" gap — fall to
                    // `canonical`/`--lossless` with a different `--to` instead.
                    // (A scalar root specifically makes the fig printer hard-error
                    // with `FigUnrepresentableRoot` rather than emit non-conforming
                    // text — see `languages/fig/printer.zig`'s `root`.)
                    // XML has no envelope of its own either: every scalar
                    // collapses to element/attribute text regardless (see
                    // `languages/xml/printer.zig`), so an envelope couldn't
                    // preserve anything a plain print doesn't already lose.
                    .canonical, .fig, .xml => null,
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
                .canonical => .canonical,
                .fig => .fig,
                .xml => .xml,
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
                        try stderr_terminal.setColor(.yellow);
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
                ast.serializeWith(stdout_terminal.writer, target, opts.serialize) catch |err| switch (err) {
                    error.FigUnrepresentableRoot => reportFigUnrepresentableRoot(&stderr_terminal),
                    else => return err,
                };
            } else {
                ast.serializeNodeWith(stdout_terminal.writer, target, node_id, opts.serialize) catch |err| switch (err) {
                    error.FigUnrepresentableRoot => reportFigUnrepresentableRoot(&stderr_terminal),
                    else => return err,
                };
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
                const comment = if (try resolveEmbedType(io, a, input, opts.embed, opts.detect_embed)) |embed_type|
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
                    .canonical => return error.UnsupportedCanonicalEdit,
                    .fig => if (comptime build_options.lang_fig)
                        try getCommentFromFile(fig.Language.FIG, a, io, input, opts.path, opts.inline_comment, fig.Language.FIG.default_type)
                    else
                        return error.FormatDisabled,
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

            if (try resolveEmbedType(io, a, input, opts.embed, opts.detect_embed)) |embed_type| {
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
                .canonical => return error.UnsupportedCanonicalEdit,
                .fig => if (comptime build_options.lang_fig)
                    try applyToFile(fig.Language.FIG, a, io, input, opts.path, opts.text, op, fig.Language.FIG.default_type)
                else
                    return error.FormatDisabled,
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
                var diag_source: ?[]const u8 = null;
                var diag_errors: ?[]const fig.ParseDiagnostic.Rendered = null;
                var diag_warnings: ?[]const fig.ParseDiagnostic.Rendered = null;
                if (checkOne(a, io, file, opts.format, opts.spec, &diag_source, &diag_errors, &diag_warnings)) |fmt| {
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
                        // Authoring-time lints: the file is valid (still `ok`),
                        // but likely-mistake lines print right below it. Rendered
                        // live against the real terminal (not buffered into a
                        // string — see `printDiag`), then flushed immediately so
                        // it can't interleave with the next file's logging.
                        if (diag_warnings) |ws| {
                            for (ws) |w| try printDiag(&stderr_terminal, diag_source.?, file, w.offset, w.end, "warning", .yellow, w.message, w.short_label);
                            try stderr_terminal.writer.flush();
                        }
                    }
                } else |err| {
                    any_failed = true;
                    // A covered-language failure renders as a full
                    // `file:line:col: error: …` teaching report per error
                    // (recovery collects every error in the file, not just the
                    // first) instead of the generic `file: ErrorName` line.
                    if (diag_errors) |errs| {
                        for (errs) |d| try printDiag(&stderr_terminal, diag_source.?, file, d.offset, d.end, "error", .red, d.message, d.short_label);
                        try stderr_terminal.writer.flush();
                        continue;
                    }
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
        .fmt => {
            const opts = config.options.fmt;
            if (opts.requested_help) {
                try Help.fmt(&stdout_terminal, config.binary_name);
                return;
            }
            // `--diff` is a preview mode just like `--dry-run` — nothing is
            // ever written to `file` under either.
            const preview_only = opts.dry_run or opts.diff;
            const is_stdin = std.mem.eql(u8, opts.file, "-");
            if (!preview_only and is_stdin) {
                try stderr_terminal.writer.print(
                    "error: cannot format stdin in place; pass --dry-run or --diff to print the formatted result instead.\n",
                    .{},
                );
                try stderr_terminal.writer.flush();
                std.process.exit(2);
            }

            // Read-only when only previewing (`--dry-run`/`--diff`): no need to
            // open for writing what will never be written. Otherwise read_write,
            // like `edit`/`set`/`insert`/`delete` — read the whole file first,
            // then splice the same handle in place (never via shell redirection,
            // which truncates a `> file` target before this process ever runs).
            const input = try getInput(io, opts.file, if (preview_only) .read_only else .read_write);
            defer if (!is_stdin) input.close(io);

            const a = init.arena.allocator();
            const content = try readAll(a, io, input);

            // `--embed`: only the region between the fences is reformatted; the
            // rest of the host document is carried through byte-identical.
            if (resolveEmbedTypeFromContent(content, opts.embed, opts.detect_embed)) |embed_type| {
                const region = try fig.Embed.locateRegion(content, embed_type);
                const inner = content[region.content.start..region.content.end];
                const reformatted_inner = try reformatSlice(a, &stderr_terminal, opts.file, embedFormat(embed_type), inner, opts.serialize, opts.quiet, opts.strict);

                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(a);
                try out.appendSlice(a, content[0..region.content.start]);
                try out.appendSlice(a, reformatted_inner);
                try out.appendSlice(a, content[region.content.end..]);

                const changed = !std.mem.eql(u8, content, out.items);
                if (opts.diff) {
                    try diff.unifiedDiff(a, stdout_terminal.writer, opts.file, content, out.items, 3);
                    try stdout_terminal.writer.flush();
                    if (changed) std.process.exit(1);
                } else if (opts.dry_run) {
                    try stdout_terminal.writer.writeAll(out.items);
                    try stdout_terminal.writer.flush();
                    if (changed) std.process.exit(1);
                } else if (changed) {
                    try input.writePositionalAll(io, out.items, 0);
                    try input.setLength(io, out.items.len);
                }
                return;
            }

            var from = opts.from;
            if (opts.detect) from = try resolveFormatFromContent(a, content, opts.file);

            const reformatted = try reformatSlice(a, &stderr_terminal, opts.file, from, content, opts.serialize, opts.quiet, opts.strict);
            const changed = !std.mem.eql(u8, content, reformatted);

            if (opts.diff) {
                try diff.unifiedDiff(a, stdout_terminal.writer, opts.file, content, reformatted, 3);
                try stdout_terminal.writer.flush();
                if (changed) std.process.exit(1);
            } else if (opts.dry_run) {
                try stdout_terminal.writer.writeAll(reformatted);
                try stdout_terminal.writer.flush();
                if (changed) std.process.exit(1);
            } else if (changed) {
                // Read-then-splice-same-handle (never shell redirection): the
                // in-memory `content` above was read before this write touches
                // the file, so there is no truncate-before-read race.
                try input.writePositionalAll(io, reformatted, 0);
                try input.setLength(io, reformatted.len);
            }
        },
        .convert => {
            const opts = config.options.convert;
            if (opts.requested_help) {
                try Help.convert(&stdout_terminal, config.binary_name);
                return;
            }
            const preview_only = opts.dry_run or opts.diff;
            const is_stdin = std.mem.eql(u8, opts.file, "-");
            if (!preview_only and is_stdin) {
                try stderr_terminal.writer.print(
                    "error: cannot convert stdin in place; pass --dry-run or --diff to print the converted result instead.\n",
                    .{},
                );
                try stderr_terminal.writer.flush();
                std.process.exit(2);
            }

            const input = try getInput(io, opts.file, if (preview_only) .read_only else .read_write);
            defer if (!is_stdin) input.close(io);

            const a = init.arena.allocator();
            const content = try readAll(a, io, input);

            if (opts.to_embed) |to_embed_type| {
                // Embed-archetype mode: resolve the SOURCE archetype (--embed,
                // else content-sniffed with `Embed.detect` — extension-derived
                // defaults were already folded into `opts.embed` at parse time),
                // convert the region's inner content, then rehouse it under the
                // target archetype's fences, preserving the host prose exactly.
                const source_type = opts.embed orelse (if (opts.detect_embed) fig.Embed.detect(content) else null) orelse {
                    try stderr_terminal.writer.print(
                        "error: could not detect an embedded region in `{s}`; pass --embed explicitly.\n",
                        .{opts.file},
                    );
                    try stderr_terminal.writer.flush();
                    std.process.exit(2);
                };
                const region = try fig.Embed.locateRegion(content, source_type);
                const inner = content[region.content.start..region.content.end];
                const converted_inner = try convertSlice(
                    a,
                    &stderr_terminal,
                    opts.file,
                    embedFormat(source_type),
                    embedFormat(to_embed_type),
                    inner,
                    opts.serialize,
                    opts.lossless,
                    opts.lax_tags,
                    opts.quiet,
                    opts.strict,
                );
                const out = try fig.Embed.retype(a, content, region, to_embed_type, converted_inner);

                const changed = !std.mem.eql(u8, content, out);
                if (opts.diff) {
                    try diff.unifiedDiff(a, stdout_terminal.writer, opts.file, content, out, 3);
                    try stdout_terminal.writer.flush();
                    if (changed) std.process.exit(1);
                } else if (opts.dry_run) {
                    try stdout_terminal.writer.writeAll(out);
                    try stdout_terminal.writer.flush();
                    if (changed) std.process.exit(1);
                } else if (changed) {
                    try input.writePositionalAll(io, out, 0);
                    try input.setLength(io, out.len);
                }
                return;
            }

            var from = opts.from;
            if (opts.detect) from = try resolveFormatFromContent(a, content, opts.file);

            const converted = try convertSlice(
                a,
                &stderr_terminal,
                opts.file,
                from,
                opts.to,
                content,
                opts.serialize,
                opts.lossless,
                opts.lax_tags,
                opts.quiet,
                opts.strict,
            );
            const changed = !std.mem.eql(u8, content, converted);

            if (opts.diff) {
                try diff.unifiedDiff(a, stdout_terminal.writer, opts.file, content, converted, 3);
                try stdout_terminal.writer.flush();
                if (changed) std.process.exit(1);
            } else if (opts.dry_run) {
                try stdout_terminal.writer.writeAll(converted);
                try stdout_terminal.writer.flush();
                if (changed) std.process.exit(1);
            } else if (changed) {
                try input.writePositionalAll(io, converted, 0);
                try input.setLength(io, converted.len);
            }
        },
    };
}

/// Print a teaching report straight to `term`, cargo/rustc-style:
///   <label>: <message>
///   --> <file>:<line>:<col>
///    |
///   7 | <source line>
///    |          ~~~~ <short_label>
/// highlighting the reported `[offset, end)` span (a `~~~~` underline, or a
/// single `^` when `end` is null or the span is one byte), coloring the label
/// word and the highlight+`short_label` in `color`, and the `-->` pointer plus
/// the `N |` gutter in blue. Language-agnostic (every field is plain data —
/// see `fig.ParseDiagnostic.Rendered`), so every covered language (fig, JSON,
/// TOML/YAML to come) renders through this one function; only `renderAll`'s
/// per-language `describe`/`shortLabel` calls differ. This is a CLI-only
/// sibling of a language's own `Diagnostic.renderAlloc`/`Warning.renderAlloc`
/// (see `languages/fig/parser.zig`'s private `renderReportAlloc`, which still
/// produces its own plain `file:line:col: <label>: <message>` shape) — not a
/// replacement: the library's `renderAlloc` stays a plain, colorless string for
/// every other caller (the LSP reads the structured `code`/`offset` fields
/// directly and never calls it; the C ABI's `FigWarning`/`FigError` are plain
/// data too), so nothing outside this binary is affected by adding color or
/// reshaping the layout here.
///
/// Deliberately never buffered into an intermediate string: under
/// `Io.Terminal.Mode.windows_api`, `setColor` sets the real console's text
/// attributes via a direct syscall rather than writing escape bytes into the
/// stream, so it only works called live against the real terminal — see
/// `std.Io.Terminal.setColor`.
fn printDiag(term: *Io.Terminal, source: []const u8, file: []const u8, offset: usize, end: ?usize, label: []const u8, color: Io.Terminal.Color, message: []const u8, short_label: []const u8) !void {
    const loc = fig.ParseDiagnostic.locateOffset(source, offset);
    try term.setColor(color);
    try term.writer.writeAll(label);
    try term.setColor(.reset);
    try term.writer.print(": {s}\n", .{message});
    try term.setColor(.blue);
    try term.writer.writeAll("--> ");
    try term.setColor(.reset);
    try term.writer.print("{s}:{d}:{d}\n", .{ file, loc.line, loc.column });

    // Mirrors `renderReport`'s source-line + caret, but in the cargo/rustc
    // gutter shape: a blank `|` line, the numbered source line, then a
    // highlight line under the offending span carrying `short_label`. Capped
    // so a pathological line can't flood the terminal; the highlight mirrors
    // tabs in the source to stay aligned under them. The gutter's width
    // tracks the line number's digit count so the blank/highlight `|` lines
    // up under the source line's `|`.
    const max_shown = 160;
    const shown = loc.line_text[0..@min(loc.line_text.len, max_shown)];
    if (shown.len == 0) return; // EOF/blank line: nothing to point into

    var line_num_buf: [20]u8 = undefined;
    const line_num = std.fmt.bufPrint(&line_num_buf, "{d}", .{loc.line}) catch unreachable;

    try term.setColor(.blue);
    try term.writer.splatByteAll(' ', line_num.len);
    try term.writer.writeAll(" |\n");
    try term.writer.print("{s} | ", .{line_num});
    try term.setColor(.reset);
    try term.writer.print("{s}{s}\n", .{ shown, if (shown.len < loc.line_text.len) "…" else "" });

    if (loc.column - 1 <= shown.len) {
        try term.setColor(.blue);
        try term.writer.splatByteAll(' ', line_num.len);
        try term.writer.writeAll(" | ");
        try term.setColor(.reset);
        for (shown[0 .. loc.column - 1]) |c| try term.writer.writeByte(if (c == '\t') '\t' else ' ');
        try term.setColor(color);
        // Highlight the reported `[offset, end)` span rather than a single
        // point: a `~~~~` underline when the parser gave a real multi-byte
        // extent (`end`), a single `^` when it didn't (fall back to "just the
        // start") or when the span is exactly one byte — matching how a `^`
        // and a `~~~~` read identically for a one-character span anyway.
        // Never runs past the portion of the line actually printed above.
        const span_len = if (end) |e| (if (e > offset) e - offset else 1) else 1;
        const draw_len = @max(1, @min(span_len, shown.len - (loc.column - 1)));
        if (draw_len <= 1) {
            try term.writer.writeAll("^");
        } else {
            try term.writer.splatByteAll('~', draw_len);
        }
        try term.writer.print(" {s}\n", .{short_label});
        try term.setColor(.reset);
    }
}

/// Convert a language's own `Diagnostic`/`Warning` slice (each carries a typed
/// `code` that only that language's `describe`/`shortLabel`-shaped functions
/// know how to read) into the language-agnostic `fig.ParseDiagnostic.Rendered`
/// shape `printDiag` and the `check` action work with — computed once, right
/// after parsing, so nothing downstream needs per-language knowledge. `items`
/// is any `[]const T` for a `T` with `{ code, offset, end }` fields (a
/// language's `Diagnostic` or `Warning`); `describeFn`/`labelFn` are that
/// type's own `describe`/`shortLabel`-shaped functions. Allocates with `a`
/// (the CLI's arena — never freed individually, same as the reports this
/// replaces).
fn renderAll(a: std.mem.Allocator, items: anytype, comptime describeFn: anytype, comptime labelFn: anytype) ![]const fig.ParseDiagnostic.Rendered {
    const out = try a.alloc(fig.ParseDiagnostic.Rendered, items.len);
    for (items, 0..) |it, i| out[i] = .{ .offset = it.offset, .end = it.end, .message = describeFn(it.code), .short_label = labelFn(it.code) };
    return out;
}

/// Render one parse failure as a `printDiag` teaching report and exit(2) — the
/// `get`-time twin of `check`'s per-error loop, for the single diagnostic a
/// non-recovering parse produces. Shared by every language with a `Report`
/// (fig, JSON; TOML/YAML to come) so `get`'s error path doesn't repeat this
/// print-flush-exit sequence per language.
fn reportParseError(term: *Io.Terminal, source: []const u8, file: []const u8, offset: usize, end: ?usize, message: []const u8, short_label: []const u8) !void {
    try printDiag(term, source, file, offset, end, "error", .red, message, short_label);
    try term.writer.flush();
    std.process.exit(2);
}

/// A scalar/null value reaching the fig printer as a document root has no
/// authoring spelling there (`languages/fig/printer.zig`'s `root` hard-errors
/// with `FigUnrepresentableRoot` rather than emit non-conforming output) — print
/// the teaching message and exit(1) here rather than let the raw error escape
/// to `main`'s top level. Letting it escape would still work, but would print
/// nothing but a bare Zig stack trace: `main`'s return-error path and this
/// function share one positional writer over stderr's fd, while an escaping
/// error is reported through the Zig runtime's OWN separate stderr writer (the
/// same `debug_io`-vs-`stderr_terminal` split documented at the top of this
/// file for `std.log`) — on redirection, whichever writes second silently
/// clobbers the first from byte 0, so any warning already printed disappears
/// too. Exiting here, like every other user-facing CLI failure in this file,
/// sidesteps that entirely.
fn reportFigUnrepresentableRoot(term: *Io.Terminal) noreturn {
    term.writer.writeAll("error: a scalar value cannot be the root of a .fig/.figl document; use canonical form or another output format instead (see docs/spec.md § 2).\n") catch {};
    term.writer.flush() catch {};
    std.process.exit(1);
}

/// Print every parse-time authoring warning in `warnings` (unless `--quiet`),
/// then exit(2) if `--strict` and any fired — `get`'s shared `--quiet`/
/// `--strict` contract for a language's authoring-time lints (fig's, JSON's
/// `duplicate_key`, …), so each language's call site is one line instead of
/// repeating the print/flush/strict-abort sequence.
fn handleParseWarnings(term: *Io.Terminal, source: []const u8, file: []const u8, kind_name: []const u8, warnings: anytype, comptime describeFn: anytype, comptime labelFn: anytype, quiet: bool, strict: bool) !void {
    if (warnings.len == 0) return;
    if (!quiet) {
        for (warnings) |w| try printDiag(term, source, file, w.offset, w.end, "warning", .yellow, describeFn(w.code), labelFn(w.code));
        try term.writer.flush();
    }
    if (strict) {
        try term.writer.print("error: {d} {s} warning(s); --strict aborts.\n", .{ warnings.len, kind_name });
        try term.writer.flush();
        std.process.exit(2);
    }
}

/// Validate that `file` parses cleanly, returning the resolved format on success.
/// Format precedence mirrors `get`: an explicit `--input` `override`, else the
/// file extension, else sniffing the contents. `spec_str` (from `--spec`) pins
/// the language version to validate against and is resolved once the format is
/// known — an unknown/inapplicable version is reported like a parse error. When
/// the extension implies an embedded region (e.g. markdown frontmatter) the
/// inner document is extracted and parsed. Any IO/parse/spec error propagates to
/// the caller, which reports it — except fig and JSON: a parse failure fills
/// `diag_errors` with every diagnostic rendered into the language-agnostic
/// `ParseDiagnostic.Rendered` shape, and a clean parse may fill `diag_warnings`
/// the same way (both borrow `diag_source`, which is set alongside them). The
/// caller renders these live against the real terminal via `printDiag` rather
/// than a pre-rendered string, so it can color the label — see `printDiag`'s
/// doc comment for why that can't happen in here instead.
fn checkOne(allocator: std.mem.Allocator, io: Io, file: []const u8, override: ?Format, spec_str: ?[]const u8, diag_source: *?[]const u8, diag_errors: *?[]const fig.ParseDiagnostic.Rendered, diag_warnings: *?[]const fig.ParseDiagnostic.Rendered) !Format {
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
        embed = resolveEmbedTypeFromContent(content, null, d.embed_detect);
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
        diag_source.* = content;
        var fig_report: fig.Language.FIG.Parser.Report = .{};
        var json_report: fig.Language.JSON.Parser.Report = .{};
        var toml_report: fig.Language.TOML.Parser.Report = .{};
        // `recover` so a file reports EVERY error in one pass (a language
        // server squiggles them all; `check` shouldn't hide errors 2..N behind
        // the first). Formats without a report yet stop at their first error
        // and fall back to the generic `file: ErrorName` line below.
        _ = parseSliceAs(format, spec, allocator, content, true, .{ .fig = &fig_report, .json = &json_report, .toml = &toml_report }) catch |err| {
            if (fig_report.errors.len > 0) {
                diag_errors.* = try renderAll(allocator, fig_report.errors, fig.Language.FIG.Parser.describe, fig.Language.FIG.Parser.shortLabel);
            } else if (fig_report.diag) |d| {
                diag_errors.* = try renderAll(allocator, &[_]fig.Language.FIG.Parser.Diagnostic{d}, fig.Language.FIG.Parser.describe, fig.Language.FIG.Parser.shortLabel);
            } else if (json_report.errors.len > 0) {
                diag_errors.* = try renderAll(allocator, json_report.errors, fig.Language.JSON.Parser.describe, fig.Language.JSON.Parser.shortLabel);
            } else if (json_report.diag) |d| {
                diag_errors.* = try renderAll(allocator, &[_]fig.Language.JSON.Parser.Diagnostic{d}, fig.Language.JSON.Parser.describe, fig.Language.JSON.Parser.shortLabel);
            } else if (toml_report.errors.len > 0) {
                diag_errors.* = try renderAll(allocator, toml_report.errors, fig.Language.TOML.Parser.describe, fig.Language.TOML.Parser.shortLabel);
            } else if (toml_report.diag) |d| {
                diag_errors.* = try renderAll(allocator, &[_]fig.Language.TOML.Parser.Diagnostic{d}, fig.Language.TOML.Parser.describe, fig.Language.TOML.Parser.shortLabel);
            }
            return err;
        };
        if (fig_report.warnings.len > 0) {
            diag_warnings.* = try renderAll(allocator, fig_report.warnings, fig.Language.FIG.Parser.Warning.describeWarning, fig.Language.FIG.Parser.Warning.shortLabel);
        } else if (json_report.warnings.len > 0) {
            diag_warnings.* = try renderAll(allocator, json_report.warnings, fig.Language.JSON.Parser.Warning.describeWarning, fig.Language.JSON.Parser.Warning.shortLabel);
        } else if (toml_report.warnings.len > 0) {
            diag_warnings.* = try renderAll(allocator, toml_report.warnings, fig.Language.TOML.Parser.Warning.describeWarning, fig.Language.TOML.Parser.Warning.shortLabel);
        }
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
        .json, .jsonc, .json5, .zon, .xml, .canonical, .fig, .gron => error.UnsupportedSpec,
    };
}

/// Per-language parse-report out-parameters for `parseSliceAs` — one optional
/// pointer per language that has grown the rich diagnostic layer (position +
/// teaching messages, authoring-time warnings; see `languages/fig/parser.zig`'s
/// `Report` and `languages/json/parser.zig`'s twin). Grows by one field as
/// YAML gains its own `Report` type; every existing caller is unaffected (each
/// field defaults to `null`, meaning "don't collect this language's report").
const ParseReports = struct {
    fig: ?*fig.Language.FIG.Parser.Report = null,
    json: ?*fig.Language.JSON.Parser.Report = null,
    toml: ?*fig.Language.TOML.Parser.Report = null,
};

/// Parse already-read `content` as the CLI `format` under `spec`. The
/// content-based parser the `get` and `check` actions use: reading the input
/// once means detection and parsing share the same bytes, so a piped stdin is
/// consumed only once. `.jsonc`/`.json5` select the JSON dialect; `.yml` aliases
/// YAML; `.canonical` is the AST's 1:1 oracle grammar. `spec` picks the version
/// where one is selectable (TOML 1.0 vs 1.1, YAML version).
///
/// `reports` (fields optional) receives each covered language's own parse
/// report — `diag` on failure (position + teaching message), `warnings`
/// (authoring-time lints) always; `errors` (every failure, source order) when
/// `recover`. Only the `.fig`, `.json`/`.jsonc`/`.json5`, and `.toml` branches
/// fill one; the other formats keep their bare error-name reporting for now.
fn parseSliceAs(format: Format, spec: Spec, allocator: std.mem.Allocator, content: []const u8, recover: bool, reports: ParseReports) !fig.Document {
    return switch (format) {
        .json => if (comptime build_options.lang_json) parseJson(allocator, content, .JSON, recover, reports.json) else error.FormatDisabled,
        .jsonc => if (comptime build_options.lang_json) parseJson(allocator, content, .JSONC, recover, reports.json) else error.FormatDisabled,
        .json5 => if (comptime build_options.lang_json) parseJson(allocator, content, .JSON5, recover, reports.json) else error.FormatDisabled,
        .yaml, .yml => if (comptime build_options.lang_yaml) fig.Language.YAML.Parser.parse(allocator, content, spec.yaml) else error.FormatDisabled,
        .toml => if (comptime build_options.lang_toml) blk: {
            var local: fig.Language.TOML.Parser.Report = .{};
            const r = reports.toml orelse &local;
            break :blk if (recover)
                fig.Language.TOML.Parser.parseCollecting(allocator, content, spec.toml, r)
            else
                fig.Language.TOML.Parser.parseWithReport(allocator, content, spec.toml, r);
        } else error.FormatDisabled,
        .zon => if (comptime build_options.lang_zon) fig.Language.ZON.Parser.parse(allocator, content, fig.Language.ZON.default_type) else error.FormatDisabled,
        .xml => if (comptime build_options.lang_xml) fig.Language.XML.Parser.parse(allocator, content, fig.Language.XML.default_type) else error.FormatDisabled,
        .canonical => fig.Canonical.parse(allocator, content),
        .fig => if (comptime build_options.lang_fig) blk: {
            var local: fig.Language.FIG.Parser.Report = .{};
            const r = reports.fig orelse &local;
            // `recover` collects the whole file's errors (`check`); otherwise
            // stop at the first (`get`/convert only needs to fail once).
            break :blk if (recover)
                fig.Language.FIG.Parser.parseCollecting(allocator, content, fig.Language.FIG.default_type, r)
            else
                fig.Language.FIG.Parser.parseWithReport(allocator, content, fig.Language.FIG.default_type, r);
        } else error.FormatDisabled,
        // gron ("ungron") reconstructs the AST from its `path = value` lines,
        // reusing the JSON parser for each RHS — so it needs JSON compiled in.
        .gron => if (comptime build_options.lang_json) gron.parseDocument(allocator, content) else error.FormatDisabled,
    };
}

/// The three JSON dialects share one parser/`Report` type, differing only in
/// `jtype` — factored out of `parseSliceAs` so its `.json`/`.jsonc`/`.json5`
/// arms don't triplicate the recover-vs-single-shot dispatch.
fn parseJson(allocator: std.mem.Allocator, content: []const u8, jtype: fig.Language.JSON.Type, recover: bool, report: ?*fig.Language.JSON.Parser.Report) !fig.Document {
    var local: fig.Language.JSON.Parser.Report = .{};
    const r = report orelse &local;
    return if (recover)
        fig.Language.JSON.Parser.parseCollecting(allocator, content, jtype, r)
    else
        fig.Language.JSON.Parser.parseWithReport(allocator, content, jtype, r);
}

/// Map a `Language.detect` result to the CLI `Format`. `Detected` has no
/// `jsonc` or `canonical` (neither is content-sniffed), so the mapping is
/// total.
fn mapDetected(d: fig.Language.Detected) Format {
    return switch (d) {
        .json => .json,
        .json5 => .json5,
        .yaml => .yaml,
        .toml => .toml,
        .zon => .zon,
        .xml => .xml,
        .fig => .fig,
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

/// Parse `content` as `format` and re-emit it in the *same* format — the `fmt`
/// action's core, and `get`'s twin minus the cross-format machinery: since the
/// output format always equals the input, there's no YAML reference-layer
/// materialization and no `--lossless` envelope pass to consider (those only
/// matter when `from != to`). Shares `get`'s parse-error/authoring-warning
/// reporting and lossy-conversion diagnostics so `fmt`'s stderr output matches
/// `get`'s for the same file. Returns the reformatted bytes (caller-owned).
fn reformatSlice(
    allocator: std.mem.Allocator,
    term: *Io.Terminal,
    file_path: []const u8,
    format: Format,
    content: []const u8,
    serialize: fig.AST.SerializeOptions,
    quiet: bool,
    strict: bool,
) !([]u8) {
    if (format == .gron) {
        try term.writer.print("error: cannot format gron (a CLI projection, not a stored document format).\n", .{});
        try term.writer.flush();
        return error.UnsupportedGronFmt;
    }

    var fig_report: fig.Language.FIG.Parser.Report = .{};
    var json_report: fig.Language.JSON.Parser.Report = .{};
    var toml_report: fig.Language.TOML.Parser.Report = .{};
    const doc = parseSliceAs(format, .{}, allocator, content, false, .{ .fig = &fig_report, .json = &json_report, .toml = &toml_report }) catch |err| {
        if (fig_report.diag) |d|
            try reportParseError(term, content, file_path, d.offset, d.end, fig.Language.FIG.Parser.describe(d.code), fig.Language.FIG.Parser.shortLabel(d.code));
        if (json_report.diag) |d|
            try reportParseError(term, content, file_path, d.offset, d.end, fig.Language.JSON.Parser.describe(d.code), fig.Language.JSON.Parser.shortLabel(d.code));
        if (toml_report.diag) |d|
            try reportParseError(term, content, file_path, d.offset, d.end, fig.Language.TOML.Parser.describe(d.code), fig.Language.TOML.Parser.shortLabel(d.code));
        return err;
    };
    try handleParseWarnings(term, content, file_path, "fig authoring", fig_report.warnings, fig.Language.FIG.Parser.Warning.describeWarning, fig.Language.FIG.Parser.Warning.shortLabel, quiet, strict);
    try handleParseWarnings(term, content, file_path, "JSON authoring", json_report.warnings, fig.Language.JSON.Parser.Warning.describeWarning, fig.Language.JSON.Parser.Warning.shortLabel, quiet, strict);
    try handleParseWarnings(term, content, file_path, "TOML authoring", toml_report.warnings, fig.Language.TOML.Parser.Warning.describeWarning, fig.Language.TOML.Parser.Warning.shortLabel, quiet, strict);

    const target: fig.AST.SerializeFormat = switch (format) {
        .json => .json,
        .jsonc => .jsonc,
        .json5 => .json5,
        .yaml, .yml => .yaml,
        .toml => .toml,
        .zon => .zon,
        .canonical => .canonical,
        .fig => .fig,
        .xml => .xml,
        .gron => unreachable, // rejected up front above
    };

    if (!quiet or strict) {
        const warnings = try fig.Diagnostics.analyze(allocator, &doc.ast, doc.ast.root, target, .{
            .pretty = serialize.pretty,
            .strip_comments = serialize.strip_comments,
            .lossless = false,
        });
        var surfaced: usize = 0;
        for (warnings) |w| {
            if (w.cause != .format_limitation) continue;
            surfaced += 1;
            if (!quiet) {
                try term.setColor(.yellow);
                try term.writer.writeAll("warning: ");
                try term.setColor(.reset);
                try w.render(term.writer, target);
                try term.writer.writeByte('\n');
            }
        }
        if (!quiet) try term.writer.flush();
        if (strict and surfaced > 0) {
            try term.writer.print("error: {d} lossy conversion warning(s); --strict aborts.\n", .{surfaced});
            try term.writer.flush();
            std.process.exit(1);
        }
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (target == .toml) {
        // Same lossy-strip-then-print path `get` uses for a lossy TOML target:
        // TOML has no null, so an unrepresentable value is dropped up front
        // (already reported above) rather than aborting mid-print.
        const result = try fig.Lossless.lossyStrip(allocator, &doc.ast, doc.ast.root, .toml);
        if (result.ast) |stripped| try stripped.serializeWith(&out.writer, .toml, serialize);
    } else {
        doc.ast.serializeWith(&out.writer, target, serialize) catch |err| switch (err) {
            error.FigUnrepresentableRoot => reportFigUnrepresentableRoot(term),
            else => return err,
        };
    }
    return out.toOwnedSlice();
}

/// Parse `content` as `from` and re-emit it as `to` — `convert`'s core, and the
/// in-place-writeback twin of `get`'s cross-format pipeline: materializing
/// YAML's reference layer when leaving YAML (aliases/merges/tags resolved),
/// the optional `--lossless` envelope round-trip, the same lossy-conversion
/// diagnostics, and TOML's lossy null-strip when serializing without
/// `--lossless`. Unlike `get` there is no `--path`/gron/`--body` projection —
/// `convert` always converts the whole document (or, under embed-archetype
/// mode, the whole embedded region's content). Returns the converted bytes
/// (caller-owned).
fn convertSlice(
    allocator: std.mem.Allocator,
    term: *Io.Terminal,
    file_path: []const u8,
    from: Format,
    to: Format,
    content: []const u8,
    serialize: fig.AST.SerializeOptions,
    lossless: bool,
    lax_tags: bool,
    quiet: bool,
    strict: bool,
) !([]u8) {
    if (to == .gron) {
        try term.writer.print("error: cannot convert to gron (a CLI projection, not a stored document format).\n", .{});
        try term.writer.flush();
        return error.UnsupportedGronFmt;
    }

    var fig_report: fig.Language.FIG.Parser.Report = .{};
    var json_report: fig.Language.JSON.Parser.Report = .{};
    var toml_report: fig.Language.TOML.Parser.Report = .{};
    const doc = parseSliceAs(from, .{}, allocator, content, false, .{ .fig = &fig_report, .json = &json_report, .toml = &toml_report }) catch |err| {
        if (fig_report.diag) |d|
            try reportParseError(term, content, file_path, d.offset, d.end, fig.Language.FIG.Parser.describe(d.code), fig.Language.FIG.Parser.shortLabel(d.code));
        if (json_report.diag) |d|
            try reportParseError(term, content, file_path, d.offset, d.end, fig.Language.JSON.Parser.describe(d.code), fig.Language.JSON.Parser.shortLabel(d.code));
        if (toml_report.diag) |d|
            try reportParseError(term, content, file_path, d.offset, d.end, fig.Language.TOML.Parser.describe(d.code), fig.Language.TOML.Parser.shortLabel(d.code));
        return err;
    };
    try handleParseWarnings(term, content, file_path, "fig authoring", fig_report.warnings, fig.Language.FIG.Parser.Warning.describeWarning, fig.Language.FIG.Parser.Warning.shortLabel, quiet, strict);
    try handleParseWarnings(term, content, file_path, "JSON authoring", json_report.warnings, fig.Language.JSON.Parser.Warning.describeWarning, fig.Language.JSON.Parser.Warning.shortLabel, quiet, strict);
    try handleParseWarnings(term, content, file_path, "TOML authoring", toml_report.warnings, fig.Language.TOML.Parser.Warning.describeWarning, fig.Language.TOML.Parser.Warning.shortLabel, quiet, strict);

    // Converting YAML to a non-YAML format resolves the reference layer first
    // (aliases → copies, merges → flattened, tags applied/dropped). YAML→YAML
    // keeps it intact for round-trip; JSON never has it. Mirrors `get`.
    const src_is_yaml = from == .yaml or from == .yml;
    const dst_is_yaml = to == .yaml or to == .yml;
    const base_ast: *const fig.AST = if (src_is_yaml and !dst_is_yaml) blk: {
        if (comptime build_options.lang_yaml) {
            const mode: fig.Language.YAML.TagMode = if (lax_tags) .lax else .strict;
            const mat = try allocator.create(fig.AST);
            mat.* = try fig.Language.YAML.materialize(allocator, &doc.ast, mode);
            break :blk mat;
        } else unreachable;
    } else &doc.ast;

    const ast: *const fig.AST = if (lossless and !(src_is_yaml and dst_is_yaml)) blk: {
        const maybe_target: ?fig.Lossless.Target = switch (to) {
            .json, .jsonc, .json5, .gron => .json,
            .yaml, .yml => .yaml,
            .toml => .toml,
            .zon => .zon,
            // XML has no envelope of its own — see the matching comment on the
            // `.get` action's twin switch above.
            .canonical, .fig, .xml => null,
        };
        const decoded = try allocator.create(fig.AST);
        decoded.* = try fig.Lossless.decode(allocator, base_ast);
        const target = maybe_target orelse break :blk decoded;
        const encoded = try allocator.create(fig.AST);
        encoded.* = try fig.Lossless.encode(allocator, decoded, target);
        break :blk encoded;
    } else base_ast;

    const target: fig.AST.SerializeFormat = switch (to) {
        .json => .json,
        .jsonc => .jsonc,
        .json5 => .json5,
        .yaml, .yml => .yaml,
        .toml => .toml,
        .zon => .zon,
        .canonical => .canonical,
        .fig => .fig,
        .xml => .xml,
        .gron => unreachable, // rejected up front above
    };

    if (!quiet or strict) {
        const warnings = try fig.Diagnostics.analyze(allocator, ast, ast.root, target, .{
            .pretty = serialize.pretty,
            .strip_comments = serialize.strip_comments,
            .lossless = lossless,
        });
        var surfaced: usize = 0;
        for (warnings) |w| {
            if (w.cause != .format_limitation) continue;
            surfaced += 1;
            if (!quiet) {
                try term.setColor(.yellow);
                try term.writer.writeAll("warning: ");
                try term.setColor(.reset);
                try w.render(term.writer, target);
                try term.writer.writeByte('\n');
            }
        }
        if (!quiet) try term.writer.flush();
        if (strict and surfaced > 0) {
            try term.writer.print("error: {d} lossy conversion warning(s); --strict aborts.\n", .{surfaced});
            try term.writer.flush();
            std.process.exit(1);
        }
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    if (target == .toml and !lossless) {
        // Same lossy-strip-then-print path `get` uses for a lossy TOML target:
        // TOML has no null, so an unrepresentable value is dropped up front
        // (already reported above) rather than aborting mid-print.
        const result = try fig.Lossless.lossyStrip(allocator, ast, ast.root, .toml);
        if (result.ast) |stripped| try stripped.serializeWith(&out.writer, .toml, serialize);
    } else {
        ast.serializeWith(&out.writer, target, serialize) catch |err| switch (err) {
            error.FigUnrepresentableRoot => reportFigUnrepresentableRoot(term),
            else => return err,
        };
    }
    return out.toOwnedSlice();
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
        .FrontmatterFig => if (comptime build_options.lang_fig)
            try getComment(fig.Language.FIG, allocator, inner, path, inline_comment, fig.Language.FIG.default_type)
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
        .FrontmatterFig => if (comptime build_options.lang_fig)
            try applyEdit(fig.Language.FIG, allocator, inner, path, text, op, fig.Language.FIG.default_type)
        else
            return error.FormatDisabled,
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
        .canonical => return error.UnsupportedCanonicalEdit,
        .fig => if (comptime build_options.lang_fig)
            try applyToFile(fig.Language.FIG, allocator, io, input, path, text, op, fig.Language.FIG.default_type)
        else
            return error.FormatDisabled,
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

/// Create `file_path` for read+write and seed it with `seed` — the `set`
/// action's "upsert into nothing" path (a `touch` folded into the existing
/// upsert verb). Most editors can't parse a truly empty buffer, so the file is
/// primed with a minimal valid empty document for its format (`{}` for JSON,
/// `.{}` for ZON, nothing for YAML/TOML — see `emptyDocSeed`); the subsequent
/// `set` then lands the first key into a parseable document, exactly as an
/// absent embed block is seeded before its first key. Writing is positional and
/// leaves the read cursor at 0, so `applyToFile`'s `readAll` reads the seed back.
fn createSeededFile(io: Io, file_path: []const u8, seed: []const u8) !Io.File {
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_path = try std.process.currentPath(io, &cwd_buf);
    const dir = try std.Io.Dir.cwd().openDir(io, cwd_buf[0..cwd_path], .{});
    defer dir.close(io);
    const file = try dir.createFile(io, file_path, .{ .read = true });
    if (seed.len > 0) try file.writePositionalAll(io, seed, 0);
    return file;
}

/// Best-effort unlink of a file `set` just created, used to roll back a
/// from-scratch create when the edit that followed it failed — so a failed
/// `set` never leaves a bare seed document (`{}`, `.{}`, …) littering the tree.
/// Silent on failure: this is cleanup on an already-failing path, and the edit
/// error is what the user needs to see.
fn deleteCreatedFile(io: Io, file_path: []const u8) void {
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_path = std.process.currentPath(io, &cwd_buf) catch return;
    const dir = std.Io.Dir.cwd().openDir(io, cwd_buf[0..cwd_path], .{}) catch return;
    defer dir.close(io);
    dir.deleteFile(io, file_path) catch {};
}

/// The minimal valid empty document for `format`, used to seed a file `set`
/// creates from scratch before landing its first key. `null` means the format
/// has no empty-document form to seed into — the non-editable/projection formats
/// (XML/canonical/gron) — so a from-scratch `set` on it is refused before any
/// file is created. fig, like YAML/TOML, seeds from an empty file: an empty fig
/// document parses as an empty map (see `buildRoot`), so the first `set` lands
/// its key into it. JSON5 shares JSON's `{}` seed even though its in-place edit
/// is unsupported: the clearer `UnsupportedJson5Edit` error then fires at edit
/// time rather than a confusing "cannot seed" here.
fn emptyDocSeed(format: Format) ?[]const u8 {
    return switch (format) {
        .json, .jsonc, .json5 => "{}\n",
        .yaml, .yml, .toml, .fig => "",
        .zon => ".{}\n",
        .xml, .canonical, .gron => null,
    };
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

                // `[-]` and `[$]` are the "end" tokens: `insert` reads the
                // sentinel as "append", and `delete` reads it as "the last
                // item" (`editor.removeSeqItem` special-cases it). Any other
                // caller that walks the path literally (e.g. `get`) just
                // sees an out-of-range index and surfaces NotFound.
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

/// Result of mapping a file extension to a parse strategy. `embed_detect` is
/// set when the file is a host document whose config lives in an embedded
/// region (currently only `.md`/`.markdown`) — but the extension alone can't
/// say which archetype it is (YAML/JSON/fig frontmatter, YAML endmatter all
/// use different fences), so the caller still has to sniff the actual bytes
/// with `Embed.detect` (see `resolveEmbedType`/`resolveEmbedTypeFromContent`)
/// rather than assuming one outright. `format` describes the whole-file parse
/// strategy for the (rarer) case where there turns out to be no embed at all.
const Detected = struct {
    format: Format,
    embed_detect: bool = false,
};

/// Infer the parse strategy from a file's extension, or null when the extension
/// is missing/unrecognized — the caller then falls back to content sniffing
/// (`Language.detect`) rather than failing outright.
fn detectLanguageFromFileEnding(file_path: []const u8) ?Detected {
    const dot = std.mem.findLast(u8, file_path, ".");
    const ext = file_path[(dot orelse 0) + 1 .. file_path.len];

    // Markdown conventionally carries an embedded region (frontmatter, or
    // endmatter), but which archetype it is still has to be sniffed from the
    // actual bytes — a `` ```fig ``` ``-fenced or JSON frontmatter block (or a
    // YAML endmatter fence) must not be mistaken for `---` YAML frontmatter
    // just because the file ends in `.md`.
    if (std.mem.eql(u8, ext, "md") or std.mem.eql(u8, ext, "markdown")) {
        return .{ .format = .yaml, .embed_detect = true };
    }

    // `.figl` is the authoring dialect's canonical extension; `.fig` is
    // still accepted for back-compat. (The canonical form deliberately owns
    // no extension; select it with `--input canonical`.)
    if (std.mem.eql(u8, ext, "figl")) return .{ .format = .fig };
    if (std.mem.eql(u8, ext, "fig")) return .{ .format = .fig };

    const format = std.meta.stringToEnum(Format, ext) orelse return null;
    return .{ .format = format };
}

/// Map a `--embed <archetype>` flag value to its `Embed.Type`. Lets any
/// embed-capable action target a region explicitly — overriding whatever
/// `resolveEmbedType`/`resolveEmbedTypeFromContent` would otherwise sniff —
/// so endmatter and JSON frontmatter are reachable. Returns null for an
/// unknown name.
fn embedTypeFromName(name: []const u8) ?fig.Embed.Type {
    if (std.mem.eql(u8, name, "frontmatter") or std.mem.eql(u8, name, "frontmatter-yaml"))
        return .FrontmatterYaml;
    if (std.mem.eql(u8, name, "frontmatter-json")) return .FrontmatterJson;
    if (std.mem.eql(u8, name, "frontmatter-fig")) return .FrontmatterFig;
    if (std.mem.eql(u8, name, "endmatter") or std.mem.eql(u8, name, "endmatter-yaml"))
        return .EndmatterYaml;
    return null;
}

/// The CLI `Format` an embed archetype's content is written in — the `get`
/// action's `--input`/`--output` twin of `Embed.innerFormat`. Lets an explicit
/// `--embed <archetype>` pick the right parser/printer on its own, without
/// also requiring a redundant `--input`/`--output` (or, worse, silently
/// keeping a same-named-extension guess that doesn't match the archetype —
/// e.g. `--embed frontmatter-fig` on a `.md` file, whose extension alone
/// says nothing about which archetype it actually is).
fn embedFormat(t: fig.Embed.Type) Format {
    return switch (fig.Embed.innerFormat(t)) {
        .yaml => .yaml,
        .json => .json,
        .fig => .fig,
    };
}

/// Resolve the embed archetype an action should operate on, given
/// already-read `content`. An explicit `embed` (a `--embed` flag, or a format
/// pinned outright some other way) always wins. Otherwise, when the file's
/// extension only implied "there's probably an embedded region here" without
/// saying which archetype (`detect_embed` — today only `.md`/`.markdown`,
/// via `Detected.embed_detect`), sniff the real bytes with `Embed.detect` so
/// a `` ```fig ``` ``-fenced or JSON frontmatter block (or a YAML endmatter
/// fence) isn't silently mistaken for `---` YAML frontmatter. Falls back to
/// the conventional `FrontmatterYaml` default when nothing is found at all —
/// e.g. a brand-new host file with no frontmatter yet — so `set`'s
/// open-or-init still seeds the same archetype it always has. Returns `null`
/// when this isn't an embed operation at all (no override, and the extension
/// implies no embed).
fn resolveEmbedTypeFromContent(content: []const u8, embed: ?fig.Embed.Type, detect_embed: bool) ?fig.Embed.Type {
    if (embed) |e| return e;
    if (!detect_embed) return null;
    return fig.Embed.detect(content) orelse .FrontmatterYaml;
}

/// Same as `resolveEmbedTypeFromContent`, but reads `input` itself first, for
/// call sites that haven't already buffered the file's bytes at the point
/// they need to decide. This only performs that read when a sniff is
/// actually needed (`embed == null and detect_embed`) — which today only
/// happens for a real `.md`/`.markdown` path, never stdin (`-`), so the extra
/// positional read is always safe: it's a second read of a regular, seekable
/// file, not a second (and empty) read of a pipe.
fn resolveEmbedType(io: Io, allocator: std.mem.Allocator, input: Io.File, embed: ?fig.Embed.Type, detect_embed: bool) !?fig.Embed.Type {
    if (embed) |e| return e;
    if (!detect_embed) return null;
    const content = try readAll(allocator, io, input);
    defer allocator.free(content);
    return fig.Embed.detect(content) orelse .FrontmatterYaml;
}

const ArgError = error{ UnsupportedFileFormat, MissingEditArgument, MissingSetArgument, MissingInsertArgument, MissingDeleteArgument, MissingGetArgument, MissingCommentArgument, MissingCheckArgument, MissingFmtArgument, MissingConvertArgument, OutOfMemory, Overflow, InvalidCharacter, InvalidPath };

/// Map a `--input`/`-i` format name to a `Format`. The enum member names cover
/// every accepted token (including `canonical` and `fig`) directly. Returns null
/// for an unknown name so callers can emit a tailored error.
fn parseFormatName(name: []const u8) ?Format {
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
            .embed = null,
            .detect_embed = if (ext) |d| d.embed_detect else false,
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
            const embed = embed_override;
            config.options = .{
                .set = .{
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
                    .detect_embed = embed == null and (if (ext) |d| d.embed_detect else false),
                },
            };
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
            .embed = null,
            .detect_embed = if (ext) |d| d.embed_detect else false,
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
            .embed = null,
            .detect_embed = if (ext) |d| d.embed_detect else false,
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
            .embed = null,
            .detect_embed = if (ext) |d| d.embed_detect else false,
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
                // fig has no `pretty` gate of its own to read `indent`'s value
                // against (see `SerializeOptions.fig_indent`'s doc comment), so
                // an explicit `--indent` is fig's own on/off signal, independent
                // of the numeric width other formats use it for.
                serialize.fig_indent = true;
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
                } else if (std.mem.eql(u8, fmt, "canonical")) {
                    input_override = .canonical;
                } else if (std.mem.eql(u8, fmt, "fig")) {
                    input_override = .fig;
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
                } else if (std.mem.eql(u8, fmt, "xml")) {
                    output_override = .xml;
                } else if (std.mem.eql(u8, fmt, "canonical")) {
                    output_override = .canonical;
                } else if (std.mem.eql(u8, fmt, "fig")) {
                    output_override = .fig;
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
        // An explicit `--embed` archetype wins outright; otherwise, when the
        // extension implies SOME embedded region (`.md`), the handler sniffs
        // which archetype it actually is at runtime (`resolveEmbedType`).
        const embed = embed_override;
        // No `--input` and an unrecognized extension ⇒ sniff the contents in the
        // handler. `.json` here is a placeholder `from`/`to`, overwritten once the
        // real format is known. An explicit `--embed` is never sniffed: its
        // archetype fixes the inner format outright (`embedFormat`), and that
        // wins over a same-named extension guess — e.g. `--embed frontmatter-fig`
        // on a `.md` file (whose extension alone says nothing about which
        // archetype it actually is) must read/render the embed as fig, not YAML.
        const needs_detect = !requested_help and input_override == null and embed_override == null and detected_input == null;
        const input_format = input_override orelse
            (if (embed_override) |et| embedFormat(et) else null) orelse
            (if (detected_input) |d| d.format else null) orelse .json;

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
            .detect_embed = embed == null and (if (detected_input) |d| d.embed_detect else false),
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

        config.options = .{
            .check = .{
                // toOwnedSlice: the whole slice (allocated in the arena passed to
                // parseConfig) outlives this function, unlike `get` which only keeps
                // copies of individual positional headers.
                .files = try files.toOwnedSlice(allocator),
                .format = input_override,
                .spec = spec,
                .quiet = quiet,
                .requested_help = requested_help,
            },
        };
    } else if (std.mem.eql(u8, action_str, "fmt") or std.mem.eql(u8, action_str, "f")) {
        config.action = .fmt;

        var input_override: ?Format = null;
        var quiet = false;
        var strict = false;
        var dry_run = false;
        var diff_mode = false;
        var requested_help = false;
        var embed_override: ?fig.Embed.Type = null;
        var serialize: fig.AST.SerializeOptions = .{};
        var positionals: std.ArrayList([]const u8) = .empty;
        defer positionals.deinit(allocator);

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                requested_help = true;
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, arg, "--diff")) {
                diff_mode = true;
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
                    return ArgError.MissingFmtArgument;
                };
                embed_override = embedTypeFromName(name) orelse {
                    log.err("Unknown --embed archetype: {s} (frontmatter, frontmatter-json, frontmatter-fig, endmatter)\n", .{name});
                    return ArgError.UnsupportedFileFormat;
                };
            } else if (std.mem.eql(u8, arg, "--indent")) {
                const n = args.next() orelse {
                    log.err("Missing value after {s}\n", .{arg});
                    return ArgError.MissingFmtArgument;
                };
                serialize.indent = std.fmt.parseInt(u8, n, 10) catch {
                    log.err("Invalid --indent value: {s}\n", .{n});
                    return ArgError.MissingFmtArgument;
                };
                // See the matching comment on `get`'s `--indent` handling above.
                serialize.fig_indent = true;
            } else if (std.mem.eql(u8, arg, "--width")) {
                const n = args.next() orelse {
                    log.err("Missing value after {s}\n", .{arg});
                    return ArgError.MissingFmtArgument;
                };
                serialize.width = std.fmt.parseInt(u16, n, 10) catch {
                    log.err("Invalid --width value: {s}\n", .{n});
                    return ArgError.MissingFmtArgument;
                };
            } else if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
                const fmt_name = args.next() orelse {
                    log.err("Missing format value after {s}\n", .{arg});
                    return ArgError.MissingFmtArgument;
                };
                input_override = parseFormatName(fmt_name) orelse {
                    log.err("Unsupported format: {s}\n", .{fmt_name});
                    return ArgError.UnsupportedFileFormat;
                };
            } else {
                try positionals.append(allocator, arg);
            }
        }

        if (!requested_help and positionals.items.len == 0) {
            log.err("No file provided.\n", .{});
            return ArgError.MissingFmtArgument;
        }
        // `fmt` reformats a whole file (or a whole embedded region) — there is no
        // sub-document path argument the way `get`/`edit`/etc. take one.
        if (!requested_help and positionals.items.len > 1) {
            log.err("fmt takes a single file, not a path within it: {s}\n", .{positionals.items[1]});
            return ArgError.MissingFmtArgument;
        }
        if (!requested_help and dry_run and diff_mode) {
            log.err("--dry-run and --diff are mutually exclusive.\n", .{});
            return ArgError.MissingFmtArgument;
        }

        const file_path = if (positionals.items.len > 0) positionals.items[0] else "-";

        const detected_input: ?Detected = if (!requested_help and input_override == null)
            detectLanguageFromFileEnding(file_path)
        else
            null;
        // An explicit `--embed` archetype wins outright; otherwise, when the
        // extension implies SOME embedded region (`.md`), the handler sniffs
        // which archetype it actually is at runtime.
        const embed = embed_override;
        const needs_detect = !requested_help and input_override == null and embed_override == null and detected_input == null;
        const from = input_override orelse
            (if (embed_override) |et| embedFormat(et) else null) orelse
            (if (detected_input) |d| d.format else null) orelse .json;

        config.options = .{ .fmt = .{
            .file = file_path,
            .from = from,
            .requested_help = requested_help,
            .detect = needs_detect,
            .serialize = serialize,
            .quiet = quiet,
            .strict = strict,
            .dry_run = dry_run,
            .diff = diff_mode,
            .embed = embed,
            .detect_embed = embed == null and (if (detected_input) |d| d.embed_detect else false),
        } };
    } else if (std.mem.eql(u8, action_str, "convert") or std.mem.eql(u8, action_str, "cv")) {
        config.action = .convert;

        var input_override: ?Format = null;
        var output_override: ?Format = null;
        var embed_override: ?fig.Embed.Type = null;
        var to_embed_override: ?fig.Embed.Type = null;
        var lax_tags = false;
        var lossless = false;
        var quiet = false;
        var strict = false;
        var dry_run = false;
        var diff_mode = false;
        var requested_help = false;
        var serialize: fig.AST.SerializeOptions = .{};
        var positionals: std.ArrayList([]const u8) = .empty;
        defer positionals.deinit(allocator);

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                requested_help = true;
            } else if (std.mem.eql(u8, arg, "--dry-run")) {
                dry_run = true;
            } else if (std.mem.eql(u8, arg, "--diff")) {
                diff_mode = true;
            } else if (std.mem.eql(u8, arg, "--compact")) {
                serialize.pretty = false;
            } else if (std.mem.eql(u8, arg, "--pretty")) {
                serialize.pretty = true;
            } else if (std.mem.eql(u8, arg, "--strip-comments")) {
                serialize.strip_comments = true;
            } else if (std.mem.eql(u8, arg, "--lax-tags")) {
                lax_tags = true;
            } else if (std.mem.eql(u8, arg, "--lossless")) {
                lossless = true;
            } else if (std.mem.eql(u8, arg, "--lossy")) {
                lossless = false;
            } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--no-warnings")) {
                quiet = true;
            } else if (std.mem.eql(u8, arg, "--strict")) {
                strict = true;
            } else if (std.mem.eql(u8, arg, "--embed")) {
                const name = args.next() orelse {
                    log.err("Missing archetype after {s}\n", .{arg});
                    return ArgError.MissingConvertArgument;
                };
                embed_override = embedTypeFromName(name) orelse {
                    log.err("Unknown --embed archetype: {s} (frontmatter, frontmatter-json, frontmatter-fig, endmatter)\n", .{name});
                    return ArgError.UnsupportedFileFormat;
                };
            } else if (std.mem.eql(u8, arg, "--to-embed")) {
                const name = args.next() orelse {
                    log.err("Missing archetype after {s}\n", .{arg});
                    return ArgError.MissingConvertArgument;
                };
                to_embed_override = embedTypeFromName(name) orelse {
                    log.err("Unknown --to-embed archetype: {s} (frontmatter, frontmatter-json, frontmatter-fig, endmatter)\n", .{name});
                    return ArgError.UnsupportedFileFormat;
                };
            } else if (std.mem.eql(u8, arg, "--indent")) {
                const n = args.next() orelse {
                    log.err("Missing value after {s}\n", .{arg});
                    return ArgError.MissingConvertArgument;
                };
                serialize.indent = std.fmt.parseInt(u8, n, 10) catch {
                    log.err("Invalid --indent value: {s}\n", .{n});
                    return ArgError.MissingConvertArgument;
                };
                // See the matching comment on `get`'s `--indent` handling above.
                serialize.fig_indent = true;
            } else if (std.mem.eql(u8, arg, "--width")) {
                const n = args.next() orelse {
                    log.err("Missing value after {s}\n", .{arg});
                    return ArgError.MissingConvertArgument;
                };
                serialize.width = std.fmt.parseInt(u16, n, 10) catch {
                    log.err("Invalid --width value: {s}\n", .{n});
                    return ArgError.MissingConvertArgument;
                };
            } else if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
                const fmt_name = args.next() orelse {
                    log.err("Missing format value after {s}\n", .{arg});
                    return ArgError.MissingConvertArgument;
                };
                input_override = parseFormatName(fmt_name) orelse {
                    log.err("Unsupported format: {s}\n", .{fmt_name});
                    return ArgError.UnsupportedFileFormat;
                };
            } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
                const fmt_name = args.next() orelse {
                    log.err("Missing format value after {s}\n", .{arg});
                    return ArgError.MissingConvertArgument;
                };
                output_override = parseFormatName(fmt_name) orelse {
                    log.err("Unsupported format: {s}\n", .{fmt_name});
                    return ArgError.UnsupportedFileFormat;
                };
            } else {
                try positionals.append(allocator, arg);
            }
        }

        if (!requested_help and positionals.items.len == 0) {
            log.err("No file provided.\n", .{});
            return ArgError.MissingConvertArgument;
        }
        if (!requested_help and positionals.items.len > 1) {
            log.err("convert takes a single file, not a path within it: {s}\n", .{positionals.items[1]});
            return ArgError.MissingConvertArgument;
        }
        if (!requested_help and dry_run and diff_mode) {
            log.err("--dry-run and --diff are mutually exclusive.\n", .{});
            return ArgError.MissingConvertArgument;
        }
        if (!requested_help and output_override != null and to_embed_override != null) {
            log.err("--output and --to-embed are mutually exclusive: whole-file conversion picks the target format directly, embed-archetype conversion picks it via the archetype.\n", .{});
            return ArgError.MissingConvertArgument;
        }
        if (!requested_help and output_override == null and to_embed_override == null) {
            log.err("convert needs a target: pass --output <format> to convert the whole file, or --to-embed <archetype> to rehouse an embedded region.\n", .{});
            return ArgError.MissingConvertArgument;
        }
        if (!requested_help and input_override != null and to_embed_override != null) {
            log.err("--input is not used with --to-embed: the source archetype (--embed, else detected) fixes the input format.\n", .{});
            return ArgError.MissingConvertArgument;
        }
        if (!requested_help and embed_override != null and to_embed_override == null) {
            log.err("--embed requires --to-embed (embed-archetype conversion always changes the archetype); use `fmt --embed` to reformat without changing format.\n", .{});
            return ArgError.MissingConvertArgument;
        }

        const file_path = if (positionals.items.len > 0) positionals.items[0] else "-";

        const detected_input: ?Detected = if (!requested_help) detectLanguageFromFileEnding(file_path) else null;

        if (!requested_help and to_embed_override != null) {
            // Embed-archetype mode: `from`/`to`/`detect` are unused — the
            // source and target archetypes fix both formats. The source
            // archetype is never pinned by the extension alone (`.md` only
            // implies SOME embed, not which one) — an explicit `--embed`
            // wins, else `detect_embed` sniffs it from the content at runtime.
            const embed = embed_override;
            config.options = .{ .convert = .{
                .file = file_path,
                .requested_help = requested_help,
                .to_embed = to_embed_override,
                .embed = embed,
                .detect_embed = embed == null,
                .lax_tags = lax_tags,
                .lossless = lossless,
                .serialize = serialize,
                .quiet = quiet,
                .strict = strict,
                .dry_run = dry_run,
                .diff = diff_mode,
            } };
        } else {
            // Whole-file mode. A host document whose extension implies an
            // embed (currently only `.md`/`.markdown`) can't be converted
            // whole without either destroying its prose or guessing at a
            // fence convention for `--output`'s format — point the user at
            // `--to-embed` instead, unless they passed an explicit `--input`
            // that overrides the extension's guess entirely.
            if (!requested_help and input_override == null) {
                if (detected_input) |d| if (d.embed_detect) {
                    log.err("{s} is a host document (embedded config detected); use --to-embed <archetype> to convert its embedded region, or pass --input explicitly to force whole-file conversion.\n", .{file_path});
                    return ArgError.MissingConvertArgument;
                };
            }
            const needs_detect = !requested_help and input_override == null and detected_input == null;
            const from = input_override orelse (if (detected_input) |d| d.format else null) orelse .json;
            config.options = .{ .convert = .{
                .file = file_path,
                .requested_help = requested_help,
                .from = from,
                .to = output_override orelse .json,
                .detect = needs_detect,
                .lax_tags = lax_tags,
                .lossless = lossless,
                .serialize = serialize,
                .quiet = quiet,
                .strict = strict,
                .dry_run = dry_run,
                .diff = diff_mode,
            } };
        }
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

test "emptyDocSeed: seedable formats round-trip a first `set`, others refuse" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The seed a from-scratch `set` writes must parse and accept the first key,
    // reproducing on-disk `createSeededFile` + `applyStructuralEdit` in memory.
    var path = [_]fig.AST.PathSegment{.{ .key = "hello" }};

    // YAML: empty seed, bare value.
    const yaml = try applyEdit(fig.Language.YAML, a, emptyDocSeed(.yaml).?, &path, "world", .set, fig.Language.YAML.default_type);
    try t.expectEqualStrings("hello: world\n", yaml);

    // JSON: `{}` seed, value requoted through the JSON path like the CLI does.
    const jv = try jsonifyEdit(a, .set, "world");
    const json = try applyEdit(fig.Language.JSON, a, emptyDocSeed(.json).?, &path, jv.text, jv.op, .JSON);
    try t.expect(std.mem.indexOf(u8, json, "\"hello\"") != null);
    try t.expect(std.mem.indexOf(u8, json, "\"world\"") != null);

    // TOML: empty seed, value already a TOML literal.
    const toml = try applyEdit(fig.Language.TOML, a, emptyDocSeed(.toml).?, &path, "\"world\"", .set, fig.Language.TOML.default_type);
    try t.expectEqualStrings("hello = \"world\"\n", toml);

    // fig: empty seed (an empty document parses as an empty map), bare value.
    const figc = try applyEdit(fig.Language.FIG, a, emptyDocSeed(.fig).?, &path, "world", .set, fig.Language.FIG.default_type);
    try t.expectEqualStrings("hello = world\n", figc);

    // Projection/non-stored formats (gron, canonical, xml) have no empty-document
    // form, so the create is refused before a file lands.
    try t.expectEqual(@as(?[]const u8, null), emptyDocSeed(.gron));
    try t.expectEqual(@as(?[]const u8, null), emptyDocSeed(.canonical));
}

test "embedTypeFromName maps archetype names" {
    const t = std.testing;
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterYaml), embedTypeFromName("frontmatter"));
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterYaml), embedTypeFromName("frontmatter-yaml"));
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterJson), embedTypeFromName("frontmatter-json"));
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterFig), embedTypeFromName("frontmatter-fig"));
    try t.expectEqual(@as(?fig.Embed.Type, .EndmatterYaml), embedTypeFromName("endmatter"));
    try t.expectEqual(@as(?fig.Embed.Type, null), embedTypeFromName("bogus"));
}

test "detectLanguageFromFileEnding: .md/.markdown defer the archetype to a runtime sniff" {
    const t = std.testing;
    const md = detectLanguageFromFileEnding("post.md").?;
    try t.expectEqual(Format.yaml, md.format);
    try t.expect(md.embed_detect);

    const markdown = detectLanguageFromFileEnding("post.markdown").?;
    try t.expect(markdown.embed_detect);

    // Other extensions imply no embed at all.
    const yaml = detectLanguageFromFileEnding("f.yaml").?;
    try t.expect(!yaml.embed_detect);

    const figl_ext = detectLanguageFromFileEnding("f.figl").?;
    try t.expectEqual(Format.fig, figl_ext.format);
    try t.expect(!figl_ext.embed_detect);

    // `.fig` remains accepted for back-compat.
    const fig_ext = detectLanguageFromFileEnding("f.fig").?;
    try t.expectEqual(Format.fig, fig_ext.format);
    try t.expect(!fig_ext.embed_detect);
}

test "resolveEmbedTypeFromContent: explicit override wins, else sniffs, else falls back to YAML" {
    const t = std.testing;

    // An explicit override always wins, regardless of content.
    try t.expectEqual(@as(?fig.Embed.Type, .EndmatterYaml), resolveEmbedTypeFromContent("anything", .EndmatterYaml, true));

    // Not a detect_embed case at all (e.g. a plain .json file): no embed.
    try t.expectEqual(@as(?fig.Embed.Type, null), resolveEmbedTypeFromContent("{}", null, false));

    // detect_embed sniffs the real archetype from the bytes — this is the
    // fig-frontmatter regression: a `.md` file whose actual content is a
    // ```fig fenced block must resolve to FrontmatterFig, not be assumed to
    // be YAML just because the extension is `.md`.
    try t.expectEqual(
        @as(?fig.Embed.Type, .FrontmatterFig),
        resolveEmbedTypeFromContent("```fig\ntitle = hi\n```\nbody\n", null, true),
    );
    try t.expectEqual(
        @as(?fig.Embed.Type, .FrontmatterJson),
        resolveEmbedTypeFromContent(";;;\n{\"a\":1}\n;;;\nbody\n", null, true),
    );
    try t.expectEqual(
        @as(?fig.Embed.Type, .FrontmatterYaml),
        resolveEmbedTypeFromContent("---\na: 1\n---\nbody\n", null, true),
    );

    // Nothing detected at all (e.g. a brand-new/plain host file): falls back
    // to the historical FrontmatterYaml default rather than `null`, so `set`'s
    // open-or-init still seeds the same archetype it always has.
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterYaml), resolveEmbedTypeFromContent("just prose\n", null, true));
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterYaml), resolveEmbedTypeFromContent("", null, true));
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

    // --embed frontmatter-fig routes to the fig-fenced archetype.
    var fm = TestArgs{ .items = &.{ "fig", "set", "--embed", "frontmatter-fig", "post.md", "k", "v" } };
    const fmc = try parseConfig(a, &fm);
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterFig), fmc.options.set.embed);

    // No --embed on a `.md` file: the fix for the fig-frontmatter
    // autodetection bug — `embed` stays null and `detect_embed` fires, so
    // the handler sniffs the actual archetype from the file's bytes at
    // runtime instead of the extension alone assuming YAML frontmatter.
    var md = TestArgs{ .items = &.{ "fig", "set", "post.md", "k", "v" } };
    const mdc = try parseConfig(a, &md);
    try t.expectEqual(@as(?fig.Embed.Type, null), mdc.options.set.embed);
    try t.expect(mdc.options.set.detect_embed);
}

test "parseConfig routes convert: whole-file mode, embed mode, and their guards" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Whole-file mode: --input/--output resolve `from`/`to` directly.
    var wf = TestArgs{ .items = &.{ "fig", "convert", "-i", "yaml", "-o", "toml", "f.yaml" } };
    const wfc = try parseConfig(a, &wf);
    try t.expectEqual(CliAction.convert, wfc.action);
    try t.expectEqual(Format.yaml, wfc.options.convert.from);
    try t.expectEqual(Format.toml, wfc.options.convert.to);
    try t.expectEqual(@as(?fig.Embed.Type, null), wfc.options.convert.to_embed);
    try t.expect(!wfc.options.convert.detect);

    // Whole-file mode with an unrecognized extension: `--output` alone still
    // needs `from` sniffed at runtime.
    var det = TestArgs{ .items = &.{ "fig", "convert", "-o", "json", "f.weirdext" } };
    const detc = try parseConfig(a, &det);
    try t.expect(detc.options.convert.detect);

    // Embed mode: --to-embed alone (no --embed) defers source detection to
    // the handler (`detect_embed`); the file extension doesn't imply an
    // archetype here (not .md), so `embed` stays null.
    var em = TestArgs{ .items = &.{ "fig", "convert", "--to-embed", "frontmatter-json", "f.txt" } };
    const emc = try parseConfig(a, &em);
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterJson), emc.options.convert.to_embed);
    try t.expectEqual(@as(?fig.Embed.Type, null), emc.options.convert.embed);
    try t.expect(emc.options.convert.detect_embed);

    // Embed mode on a `.md` file: the extension alone only implies SOME
    // embedded region, never which archetype — `embed` stays null and
    // `detect_embed` fires so the handler sniffs the actual fences at
    // runtime instead of assuming YAML frontmatter outright.
    var md = TestArgs{ .items = &.{ "fig", "convert", "--to-embed", "frontmatter-json", "post.md" } };
    const mdc = try parseConfig(a, &md);
    try t.expectEqual(@as(?fig.Embed.Type, null), mdc.options.convert.embed);
    try t.expect(mdc.options.convert.detect_embed);

    // Embed mode: explicit --embed overrides the extension default.
    var ov = TestArgs{ .items = &.{ "fig", "convert", "--embed", "endmatter", "--to-embed", "frontmatter-fig", "post.md" } };
    const ovc = try parseConfig(a, &ov);
    try t.expectEqual(@as(?fig.Embed.Type, .EndmatterYaml), ovc.options.convert.embed);
    try t.expectEqual(@as(?fig.Embed.Type, .FrontmatterFig), ovc.options.convert.to_embed);

    // The four guard rejections (no target at all; --output+--to-embed
    // together; --embed without --to-embed; whole-file --output on a `.md`
    // host document without an explicit --input) all return
    // `ArgError.MissingConvertArgument` after a `log.err` — verified manually
    // against the built CLI rather than here, since this test binary's
    // default runner (Zig 0.16) fails any test that logs at `.err`
    // regardless of whether the returned error was expected (see
    // `test_runner.zig`'s `log_err_count`), the same reason no other
    // `parseConfig` error path in this file is exercised as a unit test.

    // An explicit --input forces whole-file conversion on a `.md` file anyway.
    var mdforced = TestArgs{ .items = &.{ "fig", "convert", "-i", "yaml", "-o", "toml", "post.md" } };
    const mdforcedc = try parseConfig(a, &mdforced);
    try t.expectEqual(Format.yaml, mdforcedc.options.convert.from);
    try t.expect(!mdforcedc.options.convert.detect);
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
