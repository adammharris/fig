// fig — JSON / JSONC / YAML / TOML / ZON parsing, comment-preserving editing,
// and serialization, backed by the fig core compiled to WebAssembly.
//
// The module loads synchronously and imports nothing host-specific, so it works
// identically in Node and the browser.
export {
  Format,
  NodeKind,
  ExtKind,
  EmbedType,
  Status,
  FigError,
  WarningCode,
  WarningCause,
  type SerializeOptions,
  type Warning,
  type ParseDetail,
} from "./types.ts";
export { Document } from "./document.ts";
export { Editor } from "./editor.ts";
export { Embed, split, type Region, type Span } from "./embed.ts";
export { type Segment } from "./edit-ops.ts";
export { V, fromJS, toJS, serialize, valueText, diagnose, type Value, type JsValue } from "./value.ts";
export { version, versionString, capabilities, type Version, type Capabilities } from "./meta.ts";

import { Document } from "./document.ts";
import { serialize as serializeValue } from "./value.ts";
import { Format, type SerializeOptions } from "./types.ts";
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

/** Render a plain JS value (or `Value` tree) to `format`. Alias of `serialize`;
 *  `options` controls output style such as compact vs. pretty-printed JSON. */
export function stringify(value: JsValue, format: Format, options?: SerializeOptions): string {
  return serializeValue(value, format, options);
}
