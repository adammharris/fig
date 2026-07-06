```fig
title = Using fig in Typescript
author = adammharris
created = 2026-07-05T21:35:14-06:00
part_of = [docs](docs.md)
```

### `fig` in TypeScript

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