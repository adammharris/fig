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

New:

- `fig_editor_set` / `fig_embed_set` (and `Editor.set`): upsert a mapping value —
  replace at the path, or insert the trailing key when only it is absent.
- Support for YAML 1.1
- `fig check` command for validating config files
- Versioning policy with `zig build check`
- Support for reading comments attached to nodes programmatically
- Update CLI with missing insert and delete operations