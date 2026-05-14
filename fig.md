---
title: fig
author: adammharris
created: 2026-05-08
updated: 2026-05-13T23:34:56-07:00
---

# `fig`

`fig` is a Zig library for parsing and editing config files.

It intends to support editing frontmatter in markdown files, as well as other kinds of embedded metadata.

It is currently in early alpha. Most features are not implemented yet.

I am writing this library by hand (no AI) for my own education, and for use in my larger project, [Diaryx](https://diaryx.org).

Any contributions are welcome, subject to my approval.

Progress so far:

- [x] Design token, parser, document architecture
- [ ] Design cross-config interface (public Zig API)
- [ ] Embedded config (i.e. markdown frontmatter)
- [ ] Command-line interface
- [ ] C ABI
- [ ] Quality check
- [ ] Publish

***

Other planned features:
- JSONC, JSON5, YAML (1.2.2), TOML (1.1)
- Rust bindings + publish as crate
- Round-trip byte matching
- Edit in place + sorting, both in files and in other plain text files
- Conversion between different config formats

Out of scope:
- Many advanced config language features, like anchors and multi-documents

***

License: Either MIT or Apache 2.0, at your discretion
