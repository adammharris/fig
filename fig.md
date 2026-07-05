```fig
title = fig
author = adammharris
created = 2026-05-08
updated = 2026-07-04T11:19:34-06:00
contents = [[fig docs](docs/docs.md)]
```

# `fig`

`fig` is a Zig library for parsing and editing config files.

Originally made for [Diaryx](https://diaryx.org), `fig` allows editing frontmatter in markdown files without reserializing the data, preserving comments and other trivia. `fig` has since been expanded to include many different kinds of configuration formats and different kinds of embedding.

It currently supports the following formats:

- YAML (1.2.2 and 1.1)
- JSON (strict, JSONC, JSON5)
- TOML (1.1 and 1.2)
- ZON (Zig Object Notation) (read, write, but no editing yet)
- XML (experimental, read-only)
- Fig, an in-house authoring dialect.

## Usage

`fig` has a feature-complete C ABI as well as bindings in Rust and Typescript. Use `fig.Language.detect()` to discover the kind of format a document is — including the fig dialect itself, when nothing stricter (JSON/ZON/XML/TOML) claims it and it isn't so plain that YAML would. Use the language's parser (for example, `fig.Language.JSON.parse()`) to convert the document to an AST. Or use `fig.Embed.extract(allocator, content, .FrontmatterYaml)` to extract a document from a markdown file's frontmatter — `fig.Embed.detect(content)` sniffs which archetype (YAML/JSON/fig frontmatter, YAML endmatter) a host document actually uses. Then, edit with `fig.Editor(fig.Language.YAML)` or convert with `document.ast.serialize(&writer, .<format>)`.

The CLI mirrors both: `fig get`/`fig fmt`/etc. fall back to content-sniffing when a file's extension doesn't pin its format, and `fig convert <file> --output <format>` (or `--to-embed <archetype>` to rehouse a host document's embedded region — e.g. YAML frontmatter → JSON frontmatter — in place) converts a file from one format to another, in place, the cross-format twin of `fig fmt`. Run `fig convert --help` for the full flag set.

There are no docs at the moment, but I have endeavored to make the code readable and well-organized. Don't be scared to take a peek! (Unless it is the YAML parser! 😵‍💫)

### Zig

To add `fig` as a dependency, run `zig fetch --save https://github.com/adammharris/fig`. Then you can reference it in `build.zig`: `exe.root_module.addImport("fig", fig_dep.module("fig"))`

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

    // Convert to YAML
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try doc.ast.serialize(&out.writer, .yaml);
    std.debug.print("{s}", .{out.written()}); // name: fig\nnums:\n- 1\n- 2\n
}
```

### Rust

`fig` can be compiled without certain languages as features. Note that you need Zig installed in order to install `fig` into your project. `fig`'s Rust bindings also carry a `serde` feature. Alternatively, `fig` has `serde`-like features and may be able to replace `serde` in your project. Diaryx currently uses `fig` in production as a `serde` replacement.

```toml
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

## Planned features

- Expand editor to include ZON
- Publish Rust crate
- Publish NPM package

## Fine print

**Contibutions**

Contributions are welcome, subject to my approval.

**AI Use**

`fig`, like many deceptively simple systems-level codebases, require careful thought and intention. AI tools can generate code rapidly, often at the cost of this important design thinking. Therefore, I have chosen to limit the use of AI code generation in this codebase.

I started writing this library by hand (no AI) for my own education, and for use in my larger project, [Diaryx](https://diaryx.org). After writing a JSON tokenizer and parser by hand, and designing the Document, Token, and Language abstractions, I decided to make use of the Codex AI tool to generate specific portions of the code that would otherwise require hours of tedious, repetitive work.

Using Codex, I was able to make a compliant YAML parser much faster than I would have been able to otherwise. Later, I used Claude Code to do the same for TOML, ZON, and JSON5. For each of these, I made a conformance suite in order to ensure a correct implementation.

All of the code generated was carefully reviewed and edited according to my taste before being accepted. I take full responsibility and ownership of the code in this repository. If you have any questions or concerns about AI use in this project, [please contact me!](<#Contact Me>)

**License**

MIT or Apache 2.0, at your discretion. If you use fig in your work, I would love to hear from you and feature you here! [Please contact me!](<#Contact Me>)

**Credits**

I took the JSON test suite at `testdata/json` from [Nicolas Seriot's JSONTestSuite repository](https://github.com/nst/JSONTestSuite). I'm grateful that it is licensed under the MIT license, so I am allowed to use it for `fig`. A copy of the license is included in this repository at `testdata/json/LICENSE`.

Likewise, test suite licenses are included for JSON5, TOML, and YAML. I am thankful for each of them.

I am also thankful for the `toml-edit` Rust crate, which provided inspiration for the complex structural edits required by any format-preserving TOML editor.

## Contact Me

<adam@diaryx.org>, or leave an issue.