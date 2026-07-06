```fig
title = Using fig in Rust
author = adammharris
created = 2026-07-05T21:35:14-06:00
part_of = [docs](docs.md)
```

# `fig` in Rust

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