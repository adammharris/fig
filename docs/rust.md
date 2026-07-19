```fig
title = Using fig in Rust
author = adammharris
created = 2026-07-05T21:35:14-06:00
updated = 2026-07-05T22:36:00-06:00
part_of = [docs](docs.md)
```

# `fig` for Rust

`fig` parses, **edits**, and serializes configuration files — JSON, JSONC, JSON5,
YAML, TOML, ZON, and the native `fig` dialect — from one small crate. Its
distinguishing feature is *comment-preserving editing*: you can change one value
deep in a YAML or TOML file and every comment, blank line, key order, and quoting
style elsewhere stays byte-for-byte identical. It also converts losslessly
between formats and edits config embedded in markdown frontmatter.

The core is a Zig library compiled and statically linked into your crate at build
time. It carries an optional `serde` layer, or you can use its own
`serde`-independent `Value` tree and `#[derive(ToValue, FromValue)]` macros —
`fig` can replace `serde` in your project entirely. Diaryx uses `fig` in
production as a `serde` replacement.

- [Install](#install)
- [Quick start](#quick-start)
- [Cargo features](#cargo-features)
- [Formats](#formats)
- [Reading data](#reading-data)
- [The value tree](#the-value-tree)
- [Typed structs: serde or derive](#typed-structs-serde-or-derive)
- [Editing without reserializing](#editing-without-reserializing)
- [Markdown frontmatter & embeds](#markdown-frontmatter--embeds)
- [Serialization options](#serialization-options)
- [Diagnostics & lossless conversion](#diagnostics--lossless-conversion)
- [Errors](#errors)
- [Managing resources](#managing-resources)
- [API reference](#api-reference)

## Install

`fig` builds the Zig core from source, so you need **Zig installed** on the
machine that compiles your crate. Then add the git dependency:

```toml
[dependencies]
fig = { git = "https://github.com/diaryx-org/fig" }
```

There is no separate native library to ship — the core is linked straight into
your binary.

## Quick start

```rust
use fig::{Document, Format};

fn main() -> Result<(), fig::Error> {
    // `Document::serialize` is the cross-format primitive: it preserves comments
    // where the target allows and collapses YAML's reference layer on the way out.
    let doc = Document::parse(br#"{"name":"fig","nums":[1,2]}"#, Format::Json)?;
    println!("{}", doc.serialize(Format::Yaml)?);
    // name: fig
    // nums: [1, 2]

    // Or read the whole document into an owned Value tree.
    let value = doc.to_value()?;
    println!("{value:?}");
    Ok(())
}
```

With the optional `serde` feature (see [Cargo features](#cargo-features)) you also
get `serde_json`-style helpers:

```rust
use fig::Format;

// Parse straight into a typed value…
let cfg: MyConfig = fig::from_slice(input, Format::Toml)?;
// …or a YAML string with the format defaulted.
let cfg: MyConfig = fig::from_str(yaml)?;

// Serialize any `Serialize` type to YAML.
let yaml = fig::to_string(&cfg)?;
```

## Cargo features

Each format and the two typed-mapping layers are Cargo features. The defaults
cover the common case; trim them to shrink the linked core.

| Feature    | Default | What it adds                                                              |
| ---------- | :-----: | ------------------------------------------------------------------------- |
| `serde`    |         | `from_str`/`from_slice`/`to_string`/`to_value` and `serde` impls on `Value`. |
| `derive`   |         | `#[derive(fig::ToValue, fig::FromValue)]` — typed mapping without serde.   |
| `indexmap` |         | `ToValue`/`FromValue` for `IndexMap<String, T>` (insertion order kept).    |
| `json`     |   ✅    | The shared JSON/JSONC/JSON5 core.                                         |
| `yaml`     |   ✅    | YAML parser/printer in the linked core.                                   |
| `toml`     |   ✅    | TOML parser/printer/editor.                                              |
| `zon`      |         | ZON parser/printer/editor.                                              |
| `xml`      |         | Compiles the core's XML reader in (not yet reachable via `Format`).       |
| `fig`      |   ✅    | The native `fig` authoring dialect.                                      |

The default set is `json`, `yaml`, `toml`, `fig`. Enable the rest explicitly —
`serde` for the `serde_json`-style helpers (otherwise the `Value` tree and
`derive` cover typed mapping with no serde dependency), and `zon` / `xml` when you
need those formats. JSON/JSONC/JSON5 share one core behind the `json` gate: on by
default but, like every language, removable (`--no-default-features`). The
`Format` enum keeps *every* variant regardless of features — selecting a format
whose feature is off returns [`Error::UnsupportedFormat`] at runtime, so query
[`capabilities`] if you want to fail up front:

```rust
use fig::{capabilities, Format};

let caps = capabilities(Format::Toml);
// caps.read, caps.edit, caps.serialize — all bools.
```

## Formats

| `Format` | Parse | Edit | Serialize | Notes                                |
| -------- | :---: | :--: | :-------: | ------------------------------------ |
| `Json`   |  ✅   |  ✅  |    ✅     | Strict JSON (no comments).           |
| `Jsonc`  |  ✅   |  ✅  |    ✅     | JSON with `//` and `/* */` comments. |
| `Json5`  |  ✅   |  ✅  |    ✅     | Unquoted keys, trailing commas, etc. |
| `Yaml`   |  ✅   |  ✅  |    ✅     | YAML 1.2.2 / 1.1.                    |
| `Toml`   |  ✅   |  ✅  |    ✅     | TOML 1.1 / 1.2, incl. datetimes.     |
| `Zon`    |  ✅   |  ✅  |    ✅     | Zig Object Notation.                 |
| `Fig`    |  ✅   |  ✅  |    ✅     | The native `fig` authoring dialect.  |

Every format the Rust `Format` enum exposes parses, edits, and serializes. (The
core also has an XML reader, but it is reader-only and not surfaced as a writable
`Format`, so the binding does not expose it — see the `xml` feature below.) Ask
[`capabilities`] at runtime rather than hard-coding the table — a format can also
be compiled out.

## Reading data

For a typed result, reach for the [serde or derive](#typed-structs-serde-or-derive)
paths below. For dynamic structural access, parse a [`Document`] and read it into
an owned [`Value`] tree:

```rust
use fig::{Document, Format};

let doc = Document::parse(b"[server]\nhost = \"localhost\"\nports = [80, 443]\n", Format::Toml)?;
let value = doc.to_value()?; // the whole document as a Value
```

[`Document::serialize`] is the cross-format conversion primitive — unlike
`to_value()?.serialize()`, it preserves comments carried on the source where the
target allows and collapses YAML's reference layer on the way out:

```rust
let json = doc.serialize(Format::Json)?; // TOML in, JSON out, comments kept
```

A lower-level node API backs `to_value` (root/first-child/next-sibling walking),
but it is crate-internal; `to_value` and the typed paths cover reading from
application code.

## The value tree

[`Value`] is an owned, format-independent tree mirroring fig's AST:

```rust
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Uint(u64),
    Float(f64),
    Str(String),
    Extended { kind: ExtKind, text: String }, // format-specific scalar
    Seq(Vec<Value>),
    Map(Vec<(Value, Value)>),                  // ordered entries
}
```

A few things to know:

- **Integers** split into `Int(i64)` and `Uint(u64)` so the full unsigned range
  round-trips; reading widens `i64` → `u64` → `Float` as needed.
- **Maps are ordered `Vec`s of pairs**, not hash maps — key order is preserved,
  and a key can be any `Value` (non-string keys serialize only to formats whose
  printer accepts them).
- **Format-specific scalars** — TOML datetimes, ZON enum/char literals, JSON5
  `Infinity`/`NaN` — read into `Value::Extended { kind, text }` (see [`ExtKind`])
  and serialize back verbatim instead of degrading to strings.

`From` conversions make literals ergonomic (`bool`, `i32`/`i64`, `u64`, `f64`,
`&str`, `String`, `Vec<Value>`), and [`Value::serialize`] renders through fig's
core — no formatting happens in Rust:

```rust
use fig::{Value, Format};

let value = Value::Map(vec![
    ("name".into(), "fig".into()),
    ("nums".into(), Value::Seq(vec![1i64.into(), 2i64.into()])),
]);

value.serialize(Format::Json)?; // {\n  "name": "fig",\n  "nums": [\n    1,\n    2\n  ]\n}\n
```

## Typed structs: serde or derive

Two independent ways to map fig documents onto your own types — the `derive` path
needs no serde, and neither is more capable than the other.

**With the `serde` feature** — use the derive from `serde` and the
`fig::from_*`/`fig::to_*` helpers, exactly like `serde_json`:

```rust
use serde::{Deserialize, Serialize};
use fig::Format;

#[derive(Serialize, Deserialize)]
struct Config { name: String, port: u16 }

let cfg: Config = fig::from_slice(b"name = \"fig\"\nport = 8080\n", Format::Toml)?;
let yaml = fig::to_string(&cfg)?;          // to YAML (the default emit format)
let json = fig::to_value(&cfg)?.serialize(Format::Json)?; // to any format
```

`from_str` defaults to YAML; `from_slice` takes any parsing format
(`Json`/`Jsonc`/`Json5`/`Yaml`/`Toml`/`Zon`). `Value` itself implements
`Serialize`/`Deserialize`, so `from_slice::<Value>` gives you a dynamic tree the
way `serde_json::Value` does.

**Without serde** — enable `derive` instead and map straight onto the concrete
`Value` tree. The generated code is straight-line field extraction with no
format-generic machinery, so it stays small:

```rust
use fig::{FromValue, ToValue};

#[derive(ToValue, FromValue)]
struct Config { name: String, port: u16 }

let value = fig::Document::parse(src, fig::Format::Toml)?.to_value()?;
let cfg = Config::from_value(&value)?;
let back = cfg.to_value();          // -> Value, ready to serialize
```

The macros support the attributes you'd expect from serde:

- Field: `#[fig(rename = "..")]`, `#[fig(skip)]`, `#[fig(flatten)]`,
  `#[fig(default)]` / `#[fig(default = "path")]`,
  `#[fig(skip_serializing_if = "path")]`, `#[fig(alias = "..")]`,
  `#[fig(deserialize_with = "path")]`, and `Option<T>` fields (absent → `None`).
- Container: `#[fig(rename_all = "..")]` (`camelCase`, `snake_case`, …).
- Enums, in all four taggings: external (default), internal
  (`#[fig(tag = "type")]`), adjacent (`#[fig(tag = "type", content = "data")]`),
  and untagged (`#[fig(untagged)]`), across unit/newtype/tuple/struct variants.

## Editing without reserializing

This is what sets `fig` apart. [`Editor`] splices only the bytes of the node you
touch — everything else in the file is preserved exactly.

```rust
use fig::{Editor, Format, Segment};

let mut ed = Editor::open(
    b"# app config\nhost = \"localhost\"  # dev box\nport = 8080\n",
    Format::Toml,
)?;

ed.replace_value(&[Segment::Key("port")], 9090i64)?;
ed.set_value(&[Segment::Key("debug")], true)?; // replace if present, else insert

println!("{}", ed.source()?);
// # app config
// host = "localhost"  # dev box
// port = 9090
// debug = true
```

Edits are addressed by a **path** — a slice of [`Segment`], each a `Key(&str)`
(mapping key) or `Index(usize)` (sequence index). `Segment` has `From` impls, so
`"port".into()` and `0.into()` work; an empty path `&[]` is the document root.
The value methods take any `impl Into<Value>`, so scalars (`9i64`, `"x"`, `true`),
a built [`Value`], or a `&Value` all pass directly. Whatever you pass is rendered
in the document's own format automatically (a string becomes `"x"` for TOML/JSON
but a bare `x` for YAML).

Common operations (identical on [`Editor`] and [`Embed`]):

```rust
ed.insert_value(&[], "key", &value)?;                 // add a mapping entry
ed.replace_value(path, &value)?;                      // change a value
ed.replace_key(path, "new_key")?;                     // rename a key
ed.set_value(path, &value)?;                          // upsert (replace or insert)
ed.delete(path)?;                                     // remove a mapping entry
ed.append_value(&[Segment::Key("list")], &value)?;    // push onto a sequence
ed.prepend_value(&[Segment::Key("list")], &value)?;
ed.remove_item(&[Segment::Key("list")], 0)?;          // remove sequence item by index
ed.move_key(&["a".into()], &["b".into()])?;           // reorder mapping entries
ed.reorder_keys(&[], &["title", "body"])?;            // named keys first, rest follow
ed.move_item(&[Segment::Key("list")], 2, 0)?;         // reorder sequence items
ed.reorder_items(&[Segment::Key("list")], &[2, 0])?;  // bring these indices to the front
ed.set_sequence(&[Segment::Key("tags")], &tags)?;     // reconcile a list, keeping survivors' comments
```

Comments are first-class:

```rust
ed.add_leading_comment(&["port".into()], "the listening port")?; // own-line comment above
ed.set_trailing_comment(&["port".into()], "default 8080")?;      // same-line comment
ed.leading_comment(&["port".into()])?;   // read it back (Some("") = bare marker, None = none)
ed.delete_trailing_comment(&["port".into()])?;
ed.delete_leading_comments(&["port".into()])?;
```

The comment marker (`#`, `//`) is chosen for the format; strict `Json` has no
comments and returns [`Error::UnsupportedFormat`] if you try.

Everything above uses the `*_value` methods, which take `impl Into<Value>` and
need no serde — they are the full API, not a subset. **With the `serde` feature**,
each gains a twin that takes any `T: Serialize` instead: `replace`, `insert`,
`set`, `append`, `prepend`. These add no capability — anything they do, `*_value`
does too (scalars go in directly; the `derive` feature's `to_value()` bridges a
typed struct into a `Value`):

```rust
// serde feature: pass any Serialize value
ed.set(&["debug".into()], &true)?;
ed.append(&["tags".into()], &"published")?;

// no serde: scalars/strings/bools pass straight through (impl Into<Value>)
ed.set_value(&["debug".into()], true)?;
ed.append_value(&["tags".into()], "published")?;
ed.set_value(&["server".into()], server.to_value())?; // server: #[derive(ToValue)]
```

## Markdown frontmatter & embeds

[`Embed`] edits a config block embedded in a host file — YAML/JSON/`fig`
frontmatter, or YAML endmatter — leaving the fences and surrounding prose intact.
It carries the same edit and comment API as [`Editor`].

```rust
use fig::{Embed, EmbedType};

let md = "---\ntitle: Hello\ntags:\n- draft\n---\n# Body\n\ntext\n";

let mut fm = Embed::open(md.as_bytes(), EmbedType::FrontmatterYaml)?;
fm.set_value(&["title".into()], "Hello, world")?;
fm.append_value(&["tags".into()], "published")?;

println!("{}", fm.render()?);
// ---
// title: Hello, world
// tags:
// - draft
// - published
// ---
// # Body
//
// text
```

- [`EmbedType`] selects the region and inner format: `FrontmatterYaml`,
  `FrontmatterJson`, `FrontmatterFig`, or `EndmatterYaml`.
- `Embed::open_or_init(host, kind)` creates the block if none exists, so the
  first `set` lands cleanly.
- `Embed::extract(host, kind)` / `split(content, kind)` locate the region
  *without* parsing — handy for reading the raw frontmatter and body apart.
- `replace_body(text)` swaps the prose while keeping the (possibly edited) config.

## Serialization options

[`Value::serialize_with`], [`Document::serialize_with`], and the `diagnose`
methods take a [`SerializeOptions`]. The [`Default`] is fig's historical style
(pretty, two-space indent), and there are builder helpers:

```rust
use fig::SerializeOptions;

value.serialize_with(Format::Json, SerializeOptions::compact())?;      // minified
value.serialize_with(Format::Json, SerializeOptions::pretty(4))?;      // 4-space indent
value.serialize_with(Format::Yaml, SerializeOptions::default().width(120))?; // wider inline budget
doc.serialize_with(Format::Yaml, SerializeOptions::default().strip_comments())?;
```

| Field            | Applies to           | Meaning                                            |
| ---------------- | -------------------- | -------------------------------------------------- |
| `pretty`         | JSON, ZON, TOML      | Multi-line (default) vs. compact.                  |
| `indent`         | JSON, TOML           | Spaces per level (default 2).                      |
| `width`          | TOML, YAML, Fig      | Column budget for inline (flow) vs. expanded layout. |
| `strip_comments` | all                  | Drop carried comments instead of emitting them.    |
| `lossless`       | `Document`           | Round-trip values the target can't natively hold.  |

`lossless` is honored only on [`Document`] (a built [`Value`] carries no source
envelopes to round-trip).

## Diagnostics & lossless conversion

Converting between formats can lose information — TOML has no `null`, JSON has no
datetimes or comments. `diagnose` tells you exactly what *would* be lost, without
doing it, returning one [`Warning`] per lossy event:

```rust
use fig::{Document, Format, SerializeOptions, WarningCode};

let doc = Document::parse(b"a: null\nb: 1 # keep\n", Format::Yaml)?;

// TOML has no null, so `a` would be dropped.
let warns = doc.diagnose(Format::Toml, SerializeOptions::default())?;
assert_eq!(warns[0].code, WarningCode::ValueDropped);
assert_eq!(warns[0].path, "a");
```

Each [`Warning`] carries a [`WarningCode`] (`CommentDropped`,
`CommentStyleDegraded`, `ValueDropped`, `TypeDegraded`), a [`WarningCause`]
(`FormatLimitation` or `ExplicitOption`), the node `path`, and a `note` (e.g. the
degraded-to type). Both [`Document`] and [`Value`] have `diagnose`.

To *preserve* those values instead, serialize with `lossless` — unrepresentable
values round-trip through a `$fig` envelope, and `diagnose` then reports nothing
lost:

```rust
let toml = doc.serialize_with(Format::Toml, SerializeOptions::default().lossless())?;
```

## Errors

Fallible calls return `Result<_, fig::Error>`. [`Error`] is a plain enum
implementing `std::error::Error` (and, with `serde`, `serde::de/ser::Error`):

```rust
use fig::{Document, Format, Error};

match Document::parse(b"{ not valid", Format::Json) {
    Ok(doc) => { /* … */ }
    Err(Error::Parse(detail)) => {
        eprintln!("{}", detail.message);          // the core's diagnostic
        eprintln!("{:?} {:?}", detail.line, detail.column); // when the core reports them
    }
    Err(e) => eprintln!("{e}"),
}
```

Notable variants: `Parse(ParseError)`, `UnsupportedFormat`, `NotFound` (a path,
key, or region), `InvalidArgument`, `Utf8`, plus serde/derive mapping errors
(`Message`, `MissingField`, `UnknownVariant`, `TypeMismatch`, …).
[`ParseError`] currently carries the core's message; byte offset / line / column
are wired but `None` until the core surfaces them.

## Managing resources

Unlike the TypeScript binding, there is **no manual cleanup**. [`Document`],
[`Editor`], and [`Embed`] each own a native handle freed by their `Drop` impl, so
they release deterministically when they go out of scope — normal Rust RAII:

```rust
{
    let mut ed = Editor::open(src, Format::Yaml)?;
    // …edit…
    let out = ed.source()?.to_owned();
    out
    // handle freed here when `ed` drops
}
```

The one thing to watch is **borrows**: `Editor::source`, `Embed::render`, and the
comment reads return `&str` (or `Option<String>`) that borrow handle memory and
are invalidated by the next mutation. Copy out with `.to_owned()` if you need the
text to outlive the next edit — the borrow checker enforces this for you.

## API reference

**Top-level functions**

- `capabilities(format) -> Capabilities` — what this build can read/edit/serialize.
- `version() -> Version` / `version_string() -> &'static str` — linked core version.
- `split(content, kind) -> Option<(&str, &str)>` — read-only `(content, body)` of an embed.
- *(serde)* `from_str<T>(s) -> Result<T>` — deserialize a YAML string.
- *(serde)* `from_slice<T>(bytes, format) -> Result<T>` — deserialize any format.
- *(serde)* `to_string<T>(&value) -> Result<String>` — serialize to YAML.
- *(serde)* `to_value<T>(&value) -> Result<Value>` — build a `Value` from any `Serialize`.

**Types**

- [`Document`] — read path: `parse`, `to_value`, `serialize`/`serialize_with`, `diagnose`.
- [`Editor`] — comment-preserving editor: `open`, `source`, and the edit/comment methods.
- [`Embed`] — frontmatter/embed editor: `open`, `open_or_init`, `extract`, `render`, `replace_body`, and the edit methods.
- [`Value`] — the owned value tree; `serialize`/`serialize_with`/`diagnose`, plus `From` impls.
- `Segment<'a>` — path step (`Key(&str)` / `Index(usize)`), with `From<&str>`/`From<usize>`.
- `SerializeOptions` — output style (`compact()`, `pretty(n)`, `.width(n)`, `.strip_comments()`, `.lossless()`).
- `Warning` / `Region` / `Span` / `Extracted` / `Version` / `Capabilities` / `ParseError`.

**Enums**

- `Format`, `ExtKind`, `EmbedType`, `WarningCode`, `WarningCause` — plain data enums.
- `Error` — the returned error type.

**Traits** *(the `derive` feature)*

- `ToValue` / `FromValue` — typed mapping to/from `Value`, with
  `#[derive(fig::ToValue, fig::FromValue)]` and `#[fig(...)]` attributes.
