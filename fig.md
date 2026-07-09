```fig
title = fig
version = 2.3.0
author = adammharris
created = 2026-05-08
updated = 2026-07-05T21:46:34-06:00
contents = [[fig docs](docs/docs.md)]
```

<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/fig-banner-dark.svg">
    <img src="assets/fig-banner.svg" width="220" alt="fig">
  </picture>
</h1>

`fig` is a Zig library for parsing and editing config files.

Originally made for [Diaryx](https://diaryx.org), `fig` allows editing frontmatter in markdown files without reserializing the data, preserving comments and other trivia. `fig` has since been expanded to include many different kinds of configuration formats and different kinds of embedding.

It currently supports the following formats:

- YAML (1.2.2 and 1.1)
- JSON (strict, JSONC, JSON5)
- TOML (1.1 and 1.2)
- ZON (Zig Object Notation)
- NestedText (nestedtext.org)
- Java `.properties`
- dotenv `.dotenv`
- INI `.ini`
- Property list `.plist`
- Fig `.figl`, an in-house authoring dialect authored by yours truly!

And has bindings in the following programming languages:

- [Zig](docs/zig.md)
- [Rust](docs/rust.md)
- [Typescript](docs/typescript.md) (experimental)
- C (not tested, but likely works)

## Command-line interface

Download from Github Releases or with Homebrew:

```bash
brew tap adammharris/tap
brew install adammharris/tap/fig
```

Or run it with no install at all (needs Node 20+; experimental — see
[docs/npm-wasi.md](docs/npm-wasi.md)):

```bash
npx @adammharris/fig-wasi get config.yaml
```

Run `fig help` for instructions for how to use it on your files.

## Planned features

- Better testing for the Typescript bindings
- Styling directives (maintain styling across formats, such as mapping TOML inline->YAML inline)
- More distribution options (package managers, etc.)
- More bindings
- Advanced filtering/querying capabilties ("convert to this format, except without this node")

## Fine print

**Contibutions**

Contributions are welcome, subject to my approval.

**AI Use**

`fig`, like many deceptively simple systems-level codebases, require careful thought and intention. AI tools can generate code rapidly, often at the cost of this important design thinking. Therefore, I have chosen to limit the use of AI code generation in this codebase.

I started writing this library by hand (no AI) for my own education, and for use in my larger project, [Diaryx](https://diaryx.org). After writing a JSON tokenizer and parser by hand, and designing the Document, Token, and Language abstractions, I decided to make use of the Codex AI tool to generate specific portions of the code that would otherwise require hours of tedious, repetitive work.

Using Codex, I was able to make a compliant YAML parser much faster than I would have been able to otherwise. Later, I used Claude Code to do the same for TOML, ZON, and JSON5. For each of these, I made a conformance suite in order to ensure a correct implementation.

All of the code generated was carefully reviewed and edited according to my taste before being accepted. I take full responsibility and ownership of the code in this repository. If you have any questions or concerns about AI use in this project, [please contact me!](<#Contact Me>)

**License**

MIT or Apache 2.0, at your discretion. If you use `fig` in your work, I would love to hear from you and feature you here! [Please contact me!](<#Contact Me>)

**Credits**

I took the JSON test suite at `testdata/json` from [Nicolas Seriot's JSONTestSuite repository](https://github.com/nst/JSONTestSuite). I'm grateful that it is licensed under the MIT license, so I am allowed to use it for `fig`. A copy of the license is included in this repository at `testdata/json/LICENSE`.

Likewise, test suite licenses are included for JSON5, TOML, YAML, and NestedText (the latter from [KenKundert/nestedtext_tests](https://github.com/KenKundert/nestedtext_tests), MIT). I am thankful for each of them.

I am also thankful for the `toml-edit` Rust crate, which provided inspiration for the complex structural edits required by any format-preserving TOML editor.

## Contact Me

<amh421@icloud.com>, or leave an issue.