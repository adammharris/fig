---
title: CHANGELOG
part_of: "[fig](/fig.md)"
---

# CHANGELOG

Here are the release notes for each `fig` release.

## 1.0.0

Initial release! Support for YAML, TOML, JSON(C,5), experimental support for XML, and Rust and Typescript bindings.

## 2.0.0

Breaking ABI changes (the `1.1.0` development line accumulated these before any
release, so it ships as a major bump):

- **Renamed the `fig_fm_*` frontmatter C ABI to `fig_embed_*`** and generalized
  it to any embedded region (frontmatter, endmatter). The old `fig_fm_*` symbols
  are removed.
- **`FigRegion` is now size-versioned**: set `out_region->size = sizeof(FigRegion)`
  before `fig_embed_extract`. Gained a `body` span (the host text outside the
  fences). Future fields can be appended without another major bump.
- **Embed API is fully generic over `EmbedType`** — no operation is tied to
  "frontmatter". The frontmatter-named convenience sugar is gone: in the Rust and
  TypeScript bindings, `Embed::frontmatter(md)` is replaced by
  `Embed::open(md, EmbedType::FrontmatterYaml)`, and the free function
  `split_frontmatter(content)` by `split(content, kind)`. The Rust
  `Extracted::frontmatter()` accessor is renamed to `content()`.

New:

- `fig_editor_set` / `fig_embed_set` (and `Editor.set` / `Embed.set` in the
  bindings): upsert a mapping value — replace at the path, or insert the trailing
  key when only it is absent.
- `fig_embed_open_or_init` (and `Embed::open_or_init` / `Embed.openOrInit`):
  open an embedded region, or create an empty one — placed per the archetype
  (frontmatter at the top, endmatter at the bottom) — when the host has none, so
  the first `set`/`insert` lands the opening entry without a separate
  reserialize. Generic over `EmbedType`.
- CLI: `fig set <file> <path> <value>` — upsert (replace, or create the key when
  absent); on a host document with `--embed`, it creates the block too
  (open-or-init). `--seq <item>...` reconciles a sequence in place, preserving
  comments on survivors. `--embed <frontmatter|frontmatter-json|endmatter>` makes
  the embed archetype explicit (not just the `.md` frontmatter default) for both
  `set` and `get`. `fig get --body` prints the host prose outside the fences.
- Support for YAML 1.1
- `fig check` command for validating config files
- Versioning policy with `zig build check`
- Support for reading comments attached to nodes programmatically
- Update CLI with missing insert and delete operations