---
title: fig
author: adammharris
created: 2026-05-08
updated: 2026-06-17T13:47:09-05:00
---

# `fig`

`fig` is a Zig library for parsing and editing config files.

It intends to support editing frontmatter in markdown files, as well as other kinds of embedded metadata.

It is currently in early alpha. Most features are not implemented yet.

## Progress to 1.0

- [x] Design token, parser, document architecture
- [x] Design cross-config interface (public Zig API)
- [x] Embedded config (i.e. markdown frontmatter)
- [x] Command-line interface
- [x] C ABI
- [x] Serialization
- [ ] Standardize/document errors
- [ ] Convenience lossy deserialization layer: Zig, Rust, Typescript
- [ ] Pin C ABI surface

Other planned features:
- JSONC, JSON5
- Publish Rust crate
- [ ] Publish NPM package

## Fine print

**Contibutions**

Contributions are welcome, subject to my approval.

**AI Use**

`fig`, like many deceptively simple systems-level codebases, require careful thought and intention. AI tools can generate code rapidly, often at the cost of this important design thinking. Therefore, I have chosen to limit the use of AI code generation in this codebase.

I started writing this library by hand (no AI) for my own education, and for use in my larger project, [Diaryx](https://diaryx.org). After writing a JSON tokenizer and parser by hand, and designing the Document, Token, and Language abstractions, I have decided to make use of the Codex AI tool to generate specific portions of the code that would otherwise require hours of tedious, repetitive work. So far, this includes:

- Portions of `src/yaml/tokenizer.zig`. (GPT-5.5-medium, [commit 776ca93](https://github.com/adammharris/fig/commit/776ca93de564e146fd31bacdf64448ab8ee1643c))
- Most of `src/yaml/parser.zig`. (GPT-5.5-medium, [commit a6dceb2](https://github.com/adammharris/fig/commit/a6dceb2a654524ab27f276d27603ff7411344155), [commit 963bfb3](https://github.com/adammharris/fig/commit/963bfb34c95d07ee2efceb0dceb398fb6e986205))
- The Rust bindings (GPT-5.5-medium, [commit fbf4c82](https://github.com/adammharris/fig/commit/fbf4c82eeb5a73937db28745b1ba72037ade0e64)).
- YAML conformance + C ABI + Rust bindings work by Claude Opus 4.8, pending more thorough review, but working and well-tested to far

This code was carefully reviewed and edited according to my taste before being accepted.

**License**

Not licensed for now. Please contact me at amh421@icloud.com if you would like to use this code in your work!

**Credits**

I took the JSON test suite at `testdata/json` from [Nicolas Seriot's JSONTestSuite repository](https://github.com/nst/JSONTestSuite). I'm grateful that it is licensed under the MIT license, so I am allowed to use it for `fig`. A copy of the license is included in this repository at `testdata/json/LICENSE`.