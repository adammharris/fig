```fig
title = Using fig in Typescript
author = adammharris
created = 2026-07-05T21:35:14-06:00
updated = 2026-07-05T22:36:00-06:00
part_of = [docs](docs.md)
```

# fig for TypeScript & JavaScript

`fig` parses, **edits**, and serializes configuration files — JSON, JSONC, JSON5,
YAML, TOML, and the native `fig` dialect — from one small package (ZON too, if
you build your own module — see [Formats](#formats)). Its
distinguishing feature is *comment-preserving editing*: you can change one value
deep in a YAML or TOML file and every comment, blank line, key order, and quoting
style elsewhere stays byte-for-byte identical. It also converts losslessly
between formats and edits config embedded in markdown frontmatter.

The core is a Zig library compiled to WebAssembly and embedded directly in the
package, so there is **no native build step and no separate `.wasm` file to
serve** — it runs in Node, Bun, Deno, and the browser.

- [Install](#install)
- [Loading the module](#loading-the-module)
- [Quick start](#quick-start)
- [Formats](#formats)
- [Reading data](#reading-data)
- [The value tree](#the-value-tree)
- [Editing without reserializing](#editing-without-reserializing)
- [Markdown frontmatter & embeds](#markdown-frontmatter--embeds)
- [Serialization options](#serialization-options)
- [Diagnostics & lossless conversion](#diagnostics--lossless-conversion)
- [Errors](#errors)
- [Managing resources](#managing-resources)
- [API reference](#api-reference)

## Install

```sh
npm install @adammharris/fig
```

Requires Node 20+ (or any runtime with `Symbol.dispose`). The package is ESM-only
and ships its own TypeScript types.

## Loading the module

The WebAssembly core initializes **lazily** — the first call that needs it
compiles it. Under Node, Bun, Deno, and Web Workers that "just works" and you can
call any API directly:

```ts
import { parse, Format } from "@adammharris/fig";

parse('{"ok":true}', Format.Json); // → { ok: true }
```

In the **browser main thread**, synchronous compilation of a module larger than
4 KB is disallowed by the platform, so call `init()` once at startup before any
other fig API:

```ts
import { init, parse, Format } from "@adammharris/fig";

await init();                       // do this once, e.g. during app bootstrap
parse('{"ok":true}', Format.Json);  // now synchronous everywhere
```

`init()` is idempotent and safe to call anywhere; `isReady()` reports whether the
module is already loaded. If you forget it on a browser main thread, the first
call throws a clear error telling you to `await init()`.

## Quick start

```ts
import { parse, stringify, convert, Format } from "@adammharris/fig";

// Parse any format straight to plain JS values.
const cfg = parse('name = "fig"\nport = 8080\n', Format.Toml);
// → { name: "fig", port: 8080 }

// Serialize plain JS values to any format.
stringify({ name: "fig", tags: ["a", "b"] }, Format.Yaml);
// → "name: fig\ntags: [a, b]\n"

// Convert one format to another in a single call (comments preserved where the
// target allows).
convert("name: fig\nport: 8080\n", Format.Yaml, Format.Json);
// → '{\n  "name": "fig",\n  "port": 8080\n}\n'
```

`parse` takes an optional type parameter to assert the shape you expect (no
runtime check is performed):

```ts
interface Config { name: string; port: number }
const cfg = parse<Config>('name = "fig"\nport = 8080\n', Format.Toml);
cfg.port; // typed as number
```

## Formats

| `Format` | Parse | Edit | Serialize | Notes                                |
| -------- | :---: | :--: | :-------: | ------------------------------------ |
| `Json`   |  ✅   |  ✅  |    ✅     | Strict JSON (no comments).           |
| `Jsonc`  |  ✅   |  ✅  |    ✅     | JSON with `//` and `/* */` comments. |
| `Json5`  |  ✅   |  ✅  |    ✅     | Unquoted keys, trailing commas, etc. |
| `Yaml`   |  ✅   |  ✅  |    ✅     | YAML 1.2.2 / 1.1.                    |
| `Toml`   |  ✅   |  ✅  |    ✅     | TOML 1.1 / 1.2, incl. datetimes.     |
| `Zon`    |  ⚠️   |  ⚠️  |    ⚠️     | Zig Object Notation — opt-in build, see below. |
| `Fig`    |  ✅   |  ✅  |    ✅     | The native `fig` authoring dialect.  |

`Zon` is fully editable — full parity with every other format — but it is
**not compiled into the wasm module published to npm**. It's the newest
editable format and the one least likely to be needed by a typical
JSON/YAML/TOML/Fig consumer, so it's left out to keep the inlined base64
payload smaller for everyone else. To get a module with ZON support, build your
own from a checkout:

```sh
FIG_WASM_ZON=1 npm run build:wasm
```

That module parses, edits, and serializes `Format.Zon` exactly like any other
format. Whichever module you're running, don't hard-code the table above — ask
the build at runtime, since a format can be compiled out:

```ts
import { capabilities, Format } from "@adammharris/fig";

capabilities(Format.Toml); // → { read: true, edit: true, serialize: true }
capabilities(Format.Zon);  // → { read: false, edit: false, serialize: false } in the published module
                           // → { read: true, edit: true, serialize: true } after a FIG_WASM_ZON=1 build
```

## Reading data

For most cases, `parse` is all you need. When you want one value out of a large
document without materializing the whole thing, open a `Document` and use `get`:

```ts
import { Document, Format } from "@adammharris/fig";

using doc = Document.parse(
  "[server]\nhost = \"localhost\"\nports = [80, 443]\n",
  Format.Toml,
);

doc.get(["server", "host"]);     // → "localhost"
doc.get(["server", "ports", 1]); // → 443  (numbers index sequences)
doc.has(["server", "tls"]);      // → false
doc.toJS();                      // → the whole document as plain JS
```

`using` (a TC39 explicit-resource-management declaration) releases the native
handle automatically at the end of the scope — see
[Managing resources](#managing-resources).

A lower-level node API (`root()`, `firstChild()`, `nextSibling()`, `kind()`,
`keyOf()`, `valueOf()`, `asString()`, `asNumberRaw()`, `asExtended()`, …) is also
available for walking the tree by hand; `get`/`toJS`/`toValue` are built on top of
it and cover almost every need.

## The value tree

`toJS()`/`parse()` give you plain JavaScript. Because JS can't represent every
config value faithfully, note:

- **Integers** that fit a safe JS number come back as `number`; larger ones come
  back as `bigint`. `fromJS`/`stringify` accept both.
- **Maps** with all-string keys become plain objects — *unless* a key is an
  "array index" string (e.g. `"0"`, `"10"`), in which case you get a `Map`
  instead, because JS objects would silently reorder those keys. Non-string keys
  always yield a `Map`.
- **Format-specific scalars** (TOML datetimes, ZON enum/char literals) round-trip
  as their source text.

When you need full fidelity — distinguishing `int` from `uint`, ordered non-string
keys, or building datetimes — use the `Value` tree and its `V` constructors:

```ts
import { V, serialize, Format } from "@adammharris/fig";

const value = V.map([
  [V.string("name"), V.string("fig")],
  [V.string("nums"), V.seq([V.int(1), V.int(2)])],
]);

serialize(value, Format.Json); // '{\n  "name": "fig",\n  "nums": [\n    1,\n    2\n  ]\n}\n'
```

`fromJS(jsValue)` lifts plain JS into a `Value`; `toJS(value)` lowers it back.

## Editing without reserializing

This is what sets `fig` apart. `Editor` splices only the bytes of the node you
touch — everything else in the file is preserved exactly.

```ts
import { Editor, Format } from "@adammharris/fig";

using ed = Editor.open(
  "# app config\nhost = \"localhost\"  # dev box\nport = 8080\n",
  Format.Toml,
);

ed.replaceValue(["port"], 9090);
ed.set(["debug"], true); // replace if present, else insert

console.log(ed.source());
// # app config
// host = "localhost"  # dev box
// port = 9090
// debug = true
```

Edits are addressed by a **path** — an array of `string` (mapping key) and
`number` (sequence index) `Segment`s. An empty path `[]` is the document root.
Values you pass are rendered in the document's own format automatically (a string
becomes `"x"` for TOML/JSON but a bare `x` for YAML), so pass plain JS or a
`Value` and let fig frame it.

Common operations (available on both `Editor` and `Embed`):

```ts
ed.insertValue([], "key", value);      // add a mapping entry
ed.replaceValue(path, value);          // change a value
ed.set(path, value);                   // upsert (replace or insert)
ed.delete(path);                       // remove a mapping entry
ed.appendValue(["list"], value);       // push onto a sequence
ed.prependValue(["list"], value);
ed.removeItem(["list"], 0);            // remove sequence item by index
ed.moveKey(["a"], ["b"]);              // reorder mapping entries
ed.reorderKeys([], ["title", "body"]); // named keys first, rest follow
ed.moveItem(["list"], 2, 0);           // reorder sequence items
ed.setSequence(["tags"], ["c", "a"]);  // reconcile a list, keeping survivors' comments
```

Comments are first-class:

```ts
ed.addLeadingComment(["port"], "the listening port"); // own-line comment above
ed.setTrailingComment(["port"], "default 8080");      // same-line comment
ed.getLeadingComment(["port"]);   // read it back ("" = bare marker, null = none)
ed.deleteTrailingComment(["port"]);
```

The comment marker (`#`, `//`) is chosen for the format; strict `Json` has no
comments and throws `UnsupportedFormat` if you try.

Need to insert already-serialized text verbatim (e.g. preserving exact quoting)?
Every value method has a `*Raw` twin — `replaceValueRaw`, `insertValueRaw`,
`appendValueRaw`, `setRaw` — that takes a string instead of a `Value`.

## Markdown frontmatter & embeds

`Embed` edits a config block embedded in a host file — YAML/JSON/`fig`
frontmatter, or YAML endmatter — leaving the fences and surrounding prose intact.

```ts
import { Embed, EmbedType } from "@adammharris/fig";

const md = "---\ntitle: Hello\ntags:\n- draft\n---\n# Body\n\ntext\n";

using fm = Embed.open(md, EmbedType.FrontmatterYaml);
fm.set(["title"], "Hello, world");
fm.appendValue(["tags"], "published");

console.log(fm.render());
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

- `Embed.openOrInit(host, kind)` creates the block if none exists, so the first
  `set` lands cleanly.
- `Embed.extract(host, kind)` / `split(host, kind)` locate the region *without*
  parsing — handy for just reading the raw frontmatter and body apart.
- `replaceBody(text)` swaps the prose while keeping the (possibly edited) config.

## Serialization options

`stringify`, `serialize`, `convert`, and `Document.serialize` all take an optional
`SerializeOptions`:

```ts
stringify(value, Format.Json, { pretty: false });   // minified
stringify(value, Format.Json, { indent: 4 });       // 4-space indent
stringify(value, Format.Toml, { width: 40 });       // inline vs [section] budget
convert(src, Format.Yaml, Format.Json, { stripComments: true });
```

| Option          | Applies to           | Meaning                                            |
| --------------- | -------------------- | -------------------------------------------------- |
| `pretty`        | JSON, ZON, TOML      | Multi-line (default) vs. compact.                  |
| `indent`        | JSON, TOML           | Spaces per level (default 2).                      |
| `width`         | TOML                 | Column budget for inline-table vs. `[section]`.    |
| `stripComments` | all                  | Drop carried comments instead of emitting them.    |
| `lossless`      | `Document`/`convert` | Round-trip values the target can't natively hold.  |

## Diagnostics & lossless conversion

Converting between formats can lose information — TOML has no `null`, JSON has no
datetimes or comments. `diagnose` tells you exactly what *would* be lost, without
doing it:

```ts
import { Document, Format, WarningCode } from "@adammharris/fig";

using doc = Document.parse("a: null\nb: 1 # keep\n", Format.Yaml);

// TOML has no null, so `a` would be dropped (its comments would survive).
doc.diagnose(Format.Toml); // → [{ code: ValueDropped, path: "a", ... }]

// Strict JSON has no comments, so the `# keep` comment on `b` would be dropped.
doc.diagnose(Format.Json); // → [{ code: CommentDropped, path: "b", ... }]
```

To *preserve* those values instead, pass `{ lossless: true }` — unrepresentable
values are round-tripped through a `$fig` envelope, and `diagnose` then reports
nothing lost:

```ts
convert("a: null\nb: 1\n", Format.Yaml, Format.Toml, { lossless: true });
```

There's also a top-level `diagnose(value, format, options?)` for a built `Value`.

## Errors

Failures throw a `FigError` carrying a `status` (`Status` enum) and, for parse
failures, the core's diagnostic message and source location when available:

```ts
import { Document, Format, FigError, Status } from "@adammharris/fig";

try {
  Document.parse("{ not valid", Format.Json);
} catch (err) {
  if (err instanceof FigError && err.status === Status.ParseError) {
    console.error(err.message);          // "fig_parse: ..."
    console.error(err.line, err.column); // when the core reports them
  }
}
```

## Managing resources

`Document`, `Editor`, and `Embed` each own a native handle that must be released.
The best way is a `using` declaration, which disposes it at the end of the scope
even on a throw:

```ts
using ed = Editor.open(src, Format.Yaml);
// ...edit...
return ed.source();
// handle released here automatically
```

If you can't use `using`, call `.dispose()` yourself (it's idempotent), ideally in
a `finally`:

```ts
const doc = Document.parse(src, Format.Json);
try {
  return doc.get(["version"]);
} finally {
  doc.dispose();
}
```

As a backstop, each wrapper is also registered with a `FinalizationRegistry`, so a
handle you forget to dispose is still freed when the object is garbage-collected.
**Don't rely on this** — GC timing is unspecified, and holding many live handles
wastes memory. `using`/`dispose()` is the deterministic path.

The one-shot helpers — `parse`, `stringify`, `convert`, `serialize`, `diagnose` —
manage the handle for you, so no cleanup is needed.

## API reference

**Top-level functions**

- `init(): Promise<void>` — async-initialize the wasm module (browser main thread).
- `isReady(): boolean` — whether the module is loaded.
- `parse<T>(input, format): T` — parse to plain JS.
- `stringify(value, format, options?)` — serialize plain JS / `Value` to text.
- `serialize(value, format, options?)` — alias of `stringify`.
- `convert(input, from, to, options?)` — parse `from` and serialize to `to`.
- `fromJS(input)` / `toJS(value)` — bridge plain JS ↔ `Value`.
- `diagnose(value, format, options?)` — lossy-conversion warnings for a `Value`.
- `valueText(value, format, options?)` — serialized form for splicing into edits.
- `version()` / `versionString()` / `capabilities(format)` — introspection.
- `split(host, kind)` — read-only `[content, body]` of an embed.

**Classes**

- `Document` — read path: `parse`, `get`, `has`, `nodeAt`, `toJS`, `toValue`,
  `serialize`, `diagnose`, plus low-level node accessors.
- `Editor` — comment-preserving editor: `open`, `source`, and the edit methods.
- `Embed` — frontmatter/embed editor: `open`, `openOrInit`, `extract`, `render`,
  `replaceBody`, and the edit methods.

**Values & enums**

- `V` — `Value` constructors (`V.null()`, `V.int()`, `V.uint()`, `V.float()`,
  `V.string()`, `V.bool()`, `V.extended()`, `V.seq()`, `V.map()`).
- `Format`, `NodeKind`, `ExtKind`, `EmbedType`, `Status`, `WarningCode`,
  `WarningCause` — enums.
- `FigError` — the thrown error type.
- Types: `Value`, `JsValue` (read side), `JsInput` (write side), `Segment`,
  `SerializeOptions`, `Warning`, `Region`, `Span`, `Version`, `Capabilities`.
