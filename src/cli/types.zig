//! CLI-only type definitions shared across the `fig` binary: the `Format`
//! enum, the `CliAction`/`CliActionOptions` action model, the in-place
//! `EditOp` union, and the small helper types (`CliConfig`, `ArgError`,
//! `Detected`, `append_index`) threaded through arg parsing and dispatch.
//! Nothing here touches `Io` or does any real work — see `args.zig` for
//! parsing, `actions.zig` for execution.
const std = @import("std");
const fig = @import("fig");

// gron is a CLI-only format: it lives here in the binary, never in the `fig`
// library, the C ABI, or `Language.detect`. It rides the `get` pipeline by
// deriving straight from the public AST (see `cli/gron.zig`).
const gron = @import("gron.zig");

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
pub const Format = enum { json, jsonc, json5, yaml, yml, toml, zon, xml, canonical, fig, gron, ini, dotenv, properties };

pub const CliAction = enum {
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

pub const HelpOptions = struct {
    requested_help: bool = false,
};

pub const VersionOptions = struct {};

pub const EditOptions = struct {
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
};

pub const SetOptions = struct {
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
};

pub const InsertOptions = struct {
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
};

pub const DeleteOptions = struct {
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
};

pub const GetOptions = struct {
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
};

pub const CommentOptions = struct {
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
};

pub const CheckOptions = struct {
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
};

pub const FmtOptions = struct {
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
};

pub const ConvertOptions = struct {
    /// The file to convert. `-` reads stdin — only valid without `--write`
    /// (there is nowhere to write an in-place result back to).
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
    /// Write the converted result back to `file` in place (skipped when the
    /// bytes are already identical). Without this, `convert` never touches
    /// disk — it just prints, like `get`. Combinable with `diff`: writes the
    /// file AND prints the unified diff of what changed.
    write: bool = false,
    /// Print a unified diff of the change instead of the whole converted
    /// file. Independent of `write` — with neither flag, the whole converted
    /// document prints to stdout.
    diff: bool = false,
};

pub const CliActionOptions = union(CliAction) {
    help: HelpOptions,
    version: VersionOptions,
    edit: EditOptions,
    set: SetOptions,
    insert: InsertOptions,
    delete: DeleteOptions,
    get: GetOptions,
    comment: CommentOptions,
    check: CheckOptions,
    fmt: FmtOptions,
    convert: ConvertOptions,
};

/// The in-place editing operation `applyEdit` performs. Generalizes the editor's
/// span-splice surface so `edit` and `comment` share one code path.
pub const EditOp = union(enum) {
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
pub const append_index = std.math.maxInt(usize);

pub const CliConfig = struct {
    action: CliAction = .help,
    options: CliActionOptions = .{ .help = .{} },
    binary_name: []const u8 = "fig",
    requested_help: bool = false,
};

pub const ArgError = error{ UnsupportedFileFormat, MissingEditArgument, MissingSetArgument, MissingInsertArgument, MissingDeleteArgument, MissingGetArgument, MissingCommentArgument, MissingCheckArgument, MissingFmtArgument, MissingConvertArgument, OutOfMemory, Overflow, InvalidCharacter, InvalidPath };

/// Result of mapping a file extension to a parse strategy. `embed_detect` is
/// set when the file is a host document whose config lives in an embedded
/// region (currently only `.md`/`.markdown`) — but the extension alone can't
/// say which archetype it is (YAML/JSON/fig frontmatter, YAML endmatter all
/// use different fences), so the caller still has to sniff the actual bytes
/// with `Embed.detect` (see `resolveEmbedType`/`resolveEmbedTypeFromContent`)
/// rather than assuming one outright. `format` describes the whole-file parse
/// strategy for the (rarer) case where there turns out to be no embed at all.
pub const Detected = struct {
    format: Format,
    embed_detect: bool = false,
};
