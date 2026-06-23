// Library introspection: version and per-format capabilities of the linked
// (here, bundled-wasm) fig core.
import { fig, readCString } from "./ffi.ts";
import { Format } from "./types.ts";

/** The bundled fig core's version. */
export interface Version {
  major: number;
  minor: number;
  patch: number;
}

/** The bundled fig core's version, decoded from the packed
 *  `(major << 16) | (minor << 8) | patch` that `fig_version` returns. */
export function version(): Version {
  const packed = fig.fig_version() >>> 0;
  return { major: (packed >>> 16) & 0xff, minor: (packed >>> 8) & 0xff, patch: packed & 0xff };
}

/** The bundled fig core's version as a `"major.minor.patch"` string. */
export function versionString(): string {
  return readCString(fig.fig_version_string());
}

/** What this build can do with a format. Reflects inherent support (XML is
 *  reader-only; TOML/ZON parse and serialize but are not editable) and build-time
 *  gating (a format compiled out reports all-`false`). */
export interface Capabilities {
  /** `Document.parse` accepts this format. */
  read: boolean;
  /** The editor / embed APIs accept this format. */
  edit: boolean;
  /** The serializers can write this format. */
  serialize: boolean;
}

/** Query what this build can do with `format` (read / edit / serialize), so a
 *  host can pick a working format up front instead of probing for errors. */
export function capabilities(format: Format): Capabilities {
  const bits = fig.fig_format_capabilities(format) >>> 0;
  return { read: (bits & 1) !== 0, edit: (bits & 2) !== 0, serialize: (bits & 4) !== 0 };
}
