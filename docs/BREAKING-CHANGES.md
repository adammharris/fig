```fig
title = Upcoming breaking changes
description = Breaking changes slated for a future major release of `fig`
author = adammharris
created = 2026-07-08
updated = 2026-07-08
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
