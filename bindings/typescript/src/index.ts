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
export { Embed, detect, split, type Region, type Span } from "./embed.ts";
export { type Segment } from "./edit-ops.ts";
export { V, fromJS, toJS, serialize, valueText, diagnose, type Value, type JsValue, type JsInput } from "./value.ts";
export { version, versionString, capabilities, type Version, type Capabilities } from "./meta.ts";
export { init, isReady } from "./ffi.ts";

import { Document } from "./document.ts";
import { serialize as serializeValue } from "./value.ts";
import { Format, type SerializeOptions } from "./types.ts";
import type { JsValue, JsInput, Value } from "./value.ts";

/** Parse `input` in `format` directly to plain JavaScript values. Convenience
 *  over `Document.parse(...).toJS()` that releases the handle for you. The
 *  optional type parameter lets you assert the shape you expect —
 *  `parse<Config>(text, Format.Toml)` — with no runtime check. */
export function parse<T = JsValue>(input: string | Uint8Array, format: Format): T {
  const doc = Document.parse(input, format);
  try {
    return doc.toJS() as T;
  } finally {
    doc.dispose();
  }
}

/** Convert `input` from `from` to `to` in one call — the cross-format primitive
 *  (e.g. `convert(yamlText, Format.Yaml, Format.Json)`). Preserves comments where
 *  the target allows and collapses YAML's reference layer, exactly like
 *  {@link Document#serialize}; pass `{ lossless: true }` to round-trip values the
 *  target cannot natively represent. Releases the handle for you. */
export function convert(
  input: string | Uint8Array,
  from: Format,
  to: Format,
  options?: SerializeOptions,
): string {
  const doc = Document.parse(input, from);
  try {
    return doc.serialize(to, options);
  } finally {
    doc.dispose();
  }
}

/** Render a plain JS value (or `Value` tree) to `format`. Alias of `serialize`;
 *  `options` controls output style such as compact vs. pretty-printed JSON. */
export function stringify(value: Value | JsInput, format: Format, options?: SerializeOptions): string {
  return serializeValue(value, format, options);
}
