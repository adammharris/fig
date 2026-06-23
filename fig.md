---
title: fig
author: adammharris
created: 2026-05-08
updated: 2026-06-22T23:47:50-06:00
---

# `fig`

`fig` is a Zig library for parsing and editing config files.

It intends to support editing frontmatter in markdown files, as well as other kinds of embedded metadata.

It currently supports the following formats:

- YAML
- JSON (strict, JSONC, JSON5)
- TOML (1.1 and 1.2)
- ZON (Zig Object Notation) (read, write, but no editing)
- XML (experimental, read-only)

## Usage

The same core — parse into a format-agnostic AST, then re-emit in any format — is exposed natively in Zig and through the C ABI to Rust and TypeScript. Each example below parses JSON and converts it to YAML.

### Zig

Add `fig` as a dependency (`zig fetch --save <url>`), wire the module up in `build.zig`
(`exe.root_module.addImport("fig", fig_dep.module("fig"))`), then:

```zig
const std = @import("std");
const fig = @import("fig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse JSON into a Document (the AST plus source spans).
    const doc = try fig.Language.JSON.Parser.parse(allocator, "{\"name\":\"fig\",\"nums\":[1,2]}", .JSON);
    defer doc.deinit(allocator);

    // Re-emit the same AST as YAML.
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try doc.ast.serialize(&out.writer, .yaml);
    std.debug.print("{s}", .{out.written()}); // name: fig\nnums:\n- 1\n- 2\n
}
```

### Rust

```toml
# Cargo.toml — non-JSON formats are gated by features of the same name
# (yaml, toml, zon, xml), all on by default.
[dependencies]
fig = { git = "https://github.com/adammharris/fig" }
```

```rust
use fig::{Document, Format};

fn main() -> Result<(), fig::Error> {
    // `Document::serialize` is the cross-format primitive: it preserves comments
    // where the target allows and collapses YAML's reference layer on the way out.
    let doc = Document::parse(br#"{"name":"fig","nums":[1,2]}"#, Format::Json)?;
    println!("{}", doc.serialize(Format::Yaml)?);

    // Or read the whole document into an owned Value tree.
    let value = doc.to_value()?;
    println!("{value:?}");
    Ok(())
}
```

### TypeScript

The native core ships compiled to WebAssembly and embedded in the package, so it
loads synchronously and runs identically in Node and the browser.

```ts
import { Document, Format, parse } from "@adammharris/fig";

// A Document owns a native handle — release it with `dispose()`.
const doc = Document.parse('{"name":"fig","nums":[1,2]}', Format.Json);
try {
  console.log(doc.serialize(Format.Yaml)); // name: fig\nnums:\n- 1\n- 2\n
} finally {
  doc.dispose();
}

// Or parse straight to plain JS values; the handle is released for you.
console.log(parse('{"name":"fig"}', Format.Json)); // { name: "fig" }
```

## Progress to 1.0

- [x] Design token, parser, document architecture
- [x] Design cross-config interface (public Zig API)
- [x] Embedded config (i.e. markdown frontmatter)
- [x] Command-line interface
- [x] C ABI
- [x] Serialization
- [x] Standardize/document errors
- [x] Typescript bindings
- [x] Serialization options
- [x] Pin C ABI surface

Other planned features:
- Native `.fig` format
- Expand editor to include ZON
- Publish Rust crate
- Publish NPM package

## Fine print

**Contibutions**

Contributions are welcome, subject to my approval.

**AI Use**

`fig`, like many deceptively simple systems-level codebases, require careful thought and intention. AI tools can generate code rapidly, often at the cost of this important design thinking. Therefore, I have chosen to limit the use of AI code generation in this codebase.

I started writing this library by hand (no AI) for my own education, and for use in my larger project, [Diaryx](https://diaryx.org). After writing a JSON tokenizer and parser by hand, and designing the Document, Token, and Language abstractions, I have decided to make use of the Codex AI tool to generate specific portions of the code that would otherwise require hours of tedious, repetitive work. So far, this includes:

- Portions of `src/yaml/tokenizer.zig`. (GPT-5.5-medium, [commit 776ca93](https://github.com/adammharris/fig/commit/776ca93de564e146fd31bacdf64448ab8ee1643c))
- Most of `src/yaml/parser.zig`. (GPT-5.5-medium, [commit a6dceb2](https://github.com/adammharris/fig/commit/a6dceb2a654524ab27f276d27603ff7411344155), [commit 963bfb3](https://github.com/adammharris/fig/commit/963bfb34c95d07ee2efceb0dceb398fb6e986205), others)
- The Rust bindings (GPT-5.5-medium, [commit fbf4c82](https://github.com/adammharris/fig/commit/fbf4c82eeb5a73937db28745b1ba72037ade0e64), others).
- Easily verifiable work that follows from the core has been implemented by Claude Opus 4.8, including TOML, bindings.

This code was carefully reviewed and edited according to my taste before being accepted.

**License**

Not licensed for now. Please contact me at amh421@icloud.com if you would like to use this code in your work!

**Credits**

I took the JSON test suite at `testdata/json` from [Nicolas Seriot's JSONTestSuite repository](https://github.com/nst/JSONTestSuite). I'm grateful that it is licensed under the MIT license, so I am allowed to use it for `fig`. A copy of the license is included in this repository at `testdata/json/LICENSE`.

Likewise, test suite licenses are included for JSON5, TOML, and YAML. I am thankful for each of them.

I am also thankful for the `toml-edit` Rust crate, which provided inspiration for the complex structural edits required by any format-preserving TOML editor.