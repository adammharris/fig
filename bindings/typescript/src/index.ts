// fig — JSON / JSONC / YAML / TOML / ZON parsing, comment-preserving editing,
// and serialization, backed by the fig core compiled to WebAssembly.
//
// The module loads synchronously and imports nothing host-specific, so it works
// identically in Node and the browser.
export { Format, NodeKind, ExtKind, EmbedType, Status, FigError } from "./types.ts";
export { Document } from "./document.ts";
export { Editor } from "./editor.ts";
export { Embed, type Region, type Span } from "./embed.ts";
export { type Segment } from "./edit-ops.ts";
export { V, fromJS, toJS, serialize, valueText, type Value, type JsValue } from "./value.ts";

import { Document } from "./document.ts";
import { serialize as serializeValue } from "./value.ts";
import { Format } from "./types.ts";
import type { JsValue } from "./value.ts";

/** Parse `input` in `format` directly to plain JavaScript values. Convenience
 *  over `Document.parse(...).toJS()` that releases the handle for you. */
export function parse(input: string | Uint8Array, format: Format): JsValue {
  const doc = Document.parse(input, format);
  try {
    return doc.toJS();
  } finally {
    doc.dispose();
  }
}

/** Render a plain JS value (or `Value` tree) to `format`. Alias of `serialize`. */
export function stringify(value: JsValue, format: Format): string {
  return serializeValue(value, format);
}
