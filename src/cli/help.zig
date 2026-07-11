//! `--help`/usage text for the `fig` CLI, one function per action plus the
//! top-level `general` summary. Pure output — no parsing or state.
const std = @import("std");
const Io = std.Io;

pub const title_string = "\n=========\n   FIG\n=========\n\n";

pub const Help = struct {
    pub fn general(term: *Io.Terminal, binary_name: []const u8) !void {
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

    pub fn edit(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage: {s} edit [--key] <file> <path> <replacement>
            \\  --key: edit the object key at path instead of the value
            \\  path format: dot syntax for keys, bracket syntax for indices
            \\    example: school.class[0].student[3]
            \\  .md/.markdown files: edits the frontmatter/endmatter in place —
            \\    its archetype (YAML/JSON/TOML/fig frontmatter, fenced ```lang
            \\    frontmatter, YAML endmatter) is sniffed from the file,
            \\    defaulting to YAML when none is found
            \\
        , .{binary_name});
        try term.writer.flush();
    }

    pub fn set(term: *Io.Terminal, binary_name: []const u8) !void {
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
            \\  --embed <archetype>: target an embedded region of a host file.
            \\    Three parametric families take a language: `md-<lang>` (---<lang>
            \\    frontmatter; bare `frontmatter` is ---/YAML), `fenced-<lang>`
            \\    (```lang code block), and `html-script[-<lang>]` (<script
            \\    type="application/<lang>"> data island). Plus the fixed presets
            \\    `frontmatter-json` (;;;), `frontmatter-toml` (+++), and
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

    pub fn insert(term: *Io.Terminal, binary_name: []const u8) !void {
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

    pub fn delete(term: *Io.Terminal, binary_name: []const u8) !void {
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

    pub fn comment(term: *Io.Terminal, binary_name: []const u8) !void {
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

    pub fn get(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage: {s} get [--input json|json5|yaml|toml|zon|xml|canonical|fig|ini|dotenv|properties|nestedtext|gron] [--output json|json5|yaml|toml|zon|xml|canonical|fig|ini|dotenv|properties|nestedtext|gron] <file> [path]
            \\  -i, --input: input format of file (defaults to the file extension,
            \\    then to sniffing the file's contents if the extension is unknown)
            \\  -o, --output:   output format (defaults to the input format)
            \\  canonical: the AST's 1:1 oracle text encoding; usable as input or
            \\    output, e.g. to inspect how any document parses. (Owns no file
            \\    extension — select it explicitly.) Compiled in only with
            \\    `-Dcanonical=true` (opt-in, off by default — it is a
            \\    test/debugging oracle, not exposed through the C ABI or bindings).
            \\  fig: the human-facing authoring dialect (`.figl`; `.fig` still
            \\    accepted); lossy at the edges (non-string keys, YAML refs) —
            \\    use `canonical`/`--lossless` for those. `-o fig` prints in
            \\    house style; use `fig fmt` to
            \\    rewrite a file in place instead of printing to stdout.
            \\  xml: a best-effort fold, not a general XML tool and not a
            \\    first-class format — an element becomes a mapping, `@name`
            \\    attributes and `#text` mixed content fold into it, repeated
            \\    children become an array. `-o xml` requires the document to have
            \\    exactly one root key; every scalar (numbers, booleans, ...)
            \\    prints as plain text, since XML has no other type. Compiled in
            \\    only with `-Dxml=true` (opt-in, off by default), has no in-place
            \\    editor (`edit`/`comment` reject it), and is slated for removal in
            \\    a future major (see docs/BREAKING-CHANGES.md) — use `plist` for
            \\    structured XML config.
            \\  ini: `[section]` headers + `key = value` lines, `;`/`#` full-line
            \\    comments; every value is plain text (no typed scalars). Holds a
            \\    root mapping and one level of section nesting only — a value
            \\    nested any deeper, or an array anywhere, has no INI spelling.
            \\    No in-place editor yet (`edit`/`comment` reject it, like xml).
            \\  dotenv (.env): flat `KEY=value` only, no sections/nesting; keys
            \\    are bash identifiers, an optional `export ` prefix is accepted
            \\    and discarded, and `"`/`'` quoting is real (escapes, multi-line
            \\    values) — no `$VAR` interpolation is performed. No in-place
            \\    editor yet, same as ini/xml.
            \\  properties (Java .properties): flat `key=value` only (also
            \\    accepts `key: value`/`key value`); backslash escapes on both
            \\    key and value (`\t \n \r \f \\ \uXXXX`, plus `\` at end-of-line
            \\    as a line continuation); `#`/`!` full-line comments. No
            \\    in-place editor yet, same as ini/dotenv.
            \\  nestedtext (.nt, nestedtext.org): indentation-nested `key: value`/
            \\    `- item`/`> multiline string` lines, arbitrary nesting depth;
            \\    every value is plain text (no typed scalars, like ini). `#`
            \\    full-line comments. Detected from content only as a last
            \\    resort (after every other format, including yaml, since plain
            \\    `key: value`/`- item` text is valid in both) — select it with
            \\    `-i nestedtext` or a `.nt` extension. No in-place editor yet,
            \\    same as ini/dotenv/properties.
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

    pub fn check(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage: {s} check [--input <format>] [-q|--quiet] <file>...
            \\  Validate that each file parses cleanly as its format. Prints an
            \\  `ok` line per file and exits 0 when all parse; prints an error
            \\  line to stderr for each failing file and exits 1 if any fail.
            \\  -i, --input: parse every file as this format (json, jsonc, json5,
            \\    yaml, toml, zon, xml, canonical, ini, dotenv, properties,
            \\    nestedtext).
            \\    Default: infer from each file's extension, then by sniffing
            \\    its contents.
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

    pub fn fmt(term: *Io.Terminal, binary_name: []const u8) !void {
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

    pub fn convert(term: *Io.Terminal, binary_name: []const u8) !void {
        try term.writer.print(
            \\Usage: {s} convert --output <format> [--input <format>] [--write | --diff] <file>
            \\       {s} convert --to-embed <archetype> [--embed <archetype>] [--write | --diff] <file>
            \\  Convert a file — `fmt`'s twin for when the target format differs
            \\  from the source. Exactly one of --output/--to-embed picks the
            \\  target; the other flag group is unused (rejected together).
            \\  Like `get`, it prints the converted result to stdout by default;
            \\  pass --write to write it back to <file> in place instead.
            \\
            \\  Whole-file mode (--output): parse the whole file as --input (else the
            \\    extension, else sniffed from its contents) and re-emit it as
            \\    --output, in the target format's house style. A host document
            \\    whose extension implies an embedded region (`.md`/`.markdown`) is
            \\    rejected here — use embed-archetype mode, or pass --input to force
            \\    whole-file conversion anyway.
            \\  -i, --input, -o, --output: json, json5, yaml, toml, zon, xml, canonical,
            \\    fig, ini, dotenv, properties, nestedtext. `-o xml` requires the
            \\    document to convert to have exactly one root key (see `get --help`'s
            \\    `xml:` entry); xml is compiled in only with `-Dxml=true`, and canonical
            \\    only with `-Dcanonical=true`. ini/dotenv/properties/nestedtext have no
            \\    in-place editor yet (`edit`/`set`/`comment` reject them, same as
            \\    xml) — convert to/from them here instead.
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
            \\  -w, --write: write the converted result back to <file> in place
            \\    (skipped if it's already byte-identical) instead of printing it.
            \\  --diff: print a unified diff of the change instead of the whole
            \\    converted file. Combine with --write to write AND see what changed.
            \\  --compact / --pretty: single-line vs multi-line output (default pretty).
            \\  --indent N / --width N: as in `get`/`fmt`.
            \\  --strip-comments: drop comments instead of carrying them across formats.
            \\  --lossless / --lossy: preserve values the target can't represent
            \\    natively via a $fig envelope (default --lossy).
            \\  --lax-tags: drop unknown/custom YAML tags instead of erroring, when
            \\    converting away from YAML.
            \\  -q, --quiet: suppress warnings on stderr.
            \\  --strict: treat any warning as an error (exit non-zero, no write).
            \\  reads stdin when <file> is `-`, but only without --write.
            \\
        , .{ binary_name, binary_name });
        try term.writer.flush();
    }
};
