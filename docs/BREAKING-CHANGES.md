```fig
title = Upcoming breaking changes
description = Breaking changes slated for a future major release of `fig`
author = adammharris
created = 2026-07-08
updated = 2026-07-10
part_of = [docs](docs.md)
```

# Upcoming breaking changes

This document tracks breaking changes that are **planned but not yet made**, so
consumers can see what is coming before it lands. Nothing here has happened yet —
each entry names the release it is slated for and what it will break.

`fig` follows SemVer strictly (see [VERSIONING](VERSIONING.md)), so every item
below is, by definition, a **major** bump for whichever artifact it touches (core
/ C ABI, CLI, or a binding). Items graduate out of this document when the change
ships; the release notes for that version get the final word.

Being listed here is not a deprecation warning in code. Where a runtime/compile
deprecation notice exists, it is called out in the entry.


## Slated for the next major (core / C ABI)

### Make the embed C ABI parametric (container + format)

**What breaks:** the flat `FigEmbedType` enum and the single-`int embed_type`
selector on the embed entry points.

- Internally, `Embed.Type` is already a parametric union: three families that
  carry a format payload (`frontmatter`/`fenced`/`html_script` — i.e. `---<lang>`,
  ```` ```<lang> ````, and `<script type="application/<lang>">`) plus a few
  fixed-delimiter presets (`;;;`, `+++`, ```` ```endmatter ````). The C ABI can't
  put a payload in an `enum`, so today it projects that union onto a flat
  `FigEmbedType` that lists every `(container, format)` pair (15 values and
  growing as formats are added).
- The plan is to make the C entry points parametric too, mirroring the union: a
  small `FigEmbedContainer` enum (`md_frontmatter`, `fenced`, `html_script`,
  `semicolons_json`, `plus_toml`, `endmatter` — 6 values, no product) plus a
  separate `FigFormat format` argument (ignored by the three nonparametric
  containers). `fig_embed_open` / `fig_embed_open_or_init` / `fig_embed_extract`
  gain the `format` parameter; `fig_embed_detect` writes two out-params
  (container + format) instead of one `int`.
- That is a **signature** change to the released `fig_embed_*` functions
  (`FigEmbedType` values 0–3 and the single-int form shipped in 2.4.0), so it is
  an ABI break — the whole reason it waits for a major.

**What stays:** everything above the C ABI. `Embed.Type` in Zig is already the
parametric model this change makes C match; the CLI (`--embed md-toml`,
`fenced-yaml`, `html-script`, …), the archetype behavior, and round-tripping are
unaffected. The Rust/TS bindings keep working across the change; they either
follow C's new shape or keep a flat mirror internally.

**Why not now:** the embed C ABI is new (2.4.0) and still settling — the C
binding ships marked "not tested" — and for C specifically a flat enum is
idiomatic and ergonomic (one argument at the call site). Churning the signature
mid-minor to save an enum list isn't worth an ABI break; the parametric form
rides the next major that touches the C ABI anyway.

**Migration:** the flat `FigEmbedType` values map one-to-one onto
`(container, format)` pairs — e.g. `FIG_EMBED_FENCED_TOML` →
`(FIG_EMBED_FENCED, FIG_FORMAT_TOML)`, `FIG_EMBED_MD_FRONTMATTER_FIG` →
`(FIG_EMBED_MD_FRONTMATTER, FIG_FORMAT_FIG)`, and the fixed presets
(`FIG_EMBED_FRONTMATTER_JSON` = `;;;`, `FIG_EMBED_PLUS_TOML`, `FIG_EMBED_ENDMATTER_YAML`)
take any `format` (it's ignored). A shim table will ship on the last minor before
the removing major.

### Remove generic XML as a first-class format

**What breaks:** the generic XML *format* surface — not the shared XML lexer, and
not any typed XML flavor (plist, and future ones).

- `AST.SerializeFormat.xml` and the CLI `Format.xml` / `-i xml` / `-o xml`
  selectors go away. Converting *to* generic XML (`-o xml`) is the lossy,
  shape-constrained (single-root-key) path that never earned first-class status.
- The C ABI `FigFormat.xml = 6` slot is retired. Removing an enum value is an
  ABI break (`zig build semver-check` will flag it), which is the whole reason
  this waits for a major.
- The `-Dxml=true` build flag and the generic reader/printer
  (`languages/xml/parser.zig`, `languages/xml/printer.zig`) are removed.

**What stays:** the XML *lexing substrate* — `languages/xml/tokenizer.zig` — which
is a shared low-level layer, not a config format. Typed flavors sit on top of it
(plist already does; `.csproj`, `AndroidManifest.xml`, etc. are the intended
growth path). It keeps living under `languages/xml/` as a neutral home so no
single flavor owns it.

**Why not now:** generic XML is already opt-in and off by default (`-Dxml=false`
in every shipped build), so it costs non-users nothing today. It is left in place
until a major release rather than churning the C ABI for a format nobody is forced
to compile in.

**Migration:** if you actually need generic XML ↔ JSON/YAML conversion, it will
remain available on the last minor before the removing major. For structured
Apple property lists, use `-i plist` / `-o plist`, which is typed, round-trips,
and has an in-place editor.
