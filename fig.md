---
title: fig
author: adammharris
created: 2026-05-08
updated: 2026-05-13T23:34:56-07:00
---

# `fig`

`fig` is a Zig library and CLI intended to make parsing config files, whether standalone or embedded within another document (such as a markdown file) easy.

`fig` is currently in early alpha. Most features are not implemented yet.

Progress so far:

- [x] Design token, parser, document architecture
- [ ] Design cross-config interface
- [ ] Ability to access embedded config
- [ ] CLI
- [ ] C ABI
- [ ] Quality check
- [ ] Published

***

Planned features:
- JSON, JSONC, JSON5, YAML (1.2.2), TOML (1.1)
- Rust bindings + publish as crate
- CLI
- Round-trip byte matching
- Edit in place, sorting, both in files and in other plain text files
- Optimized especially for the markdown frontmatter YAML convention
- Swap between different config flavors

Out of scope:
- Many advanced config language features
- References
- Multi-document files