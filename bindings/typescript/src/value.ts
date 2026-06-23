// The format-independent value tree, plus the build/serialize path.
//
// `Value` mirrors fig's AST scalar kinds with full fidelity (i64 vs u64 vs
// float, ordered map entries, non-string keys, format-specific `extended`
// scalars). For everyday use, `fromJS`/`toJS` bridge to plain JavaScript values,
// and `serialize` accepts either form. Like the Rust binding, the tree is built
// through the C value API and rendered by fig's own serializer — this file
// emits no JSON/YAML/TOML/ZON text itself.
import {
  check,
  ExtKind,
  Format,
  WarningCause,
  WarningCode,
  type SerializeOptions,
  type Warning,
} from "./types.ts";
import {
  encodeEntries,
  encodeNodeIds,
  encodeOptions,
  fig,
  FIG_WARNING_SIZE,
  Frame,
  readFigWarning,
  readOutSlice,
  writeWarningSize,
} from "./ffi.ts";

const I64_MIN = -(2n ** 63n);
const I64_MAX = 2n ** 63n - 1n;
const U64_MAX = 2n ** 64n - 1n;

/** A format-independent value. Construct via {@link V} or {@link fromJS}. */
export type Value =
  | { kind: "null" }
  | { kind: "bool"; value: boolean }
  | { kind: "int"; value: bigint }
  | { kind: "uint"; value: bigint }
  | { kind: "float"; value: number }
  | { kind: "string"; value: string }
  | { kind: "extended"; ext: ExtKind; text: string }
  | { kind: "seq"; items: Value[] }
  | { kind: "map"; entries: Array<[Value, Value]> };

/** Constructors for {@link Value} nodes. */
export const V = {
  null: (): Value => ({ kind: "null" }),
  bool: (value: boolean): Value => ({ kind: "bool", value }),
  int: (value: bigint | number): Value => ({ kind: "int", value: BigInt(value) }),
  uint: (value: bigint | number): Value => ({ kind: "uint", value: BigInt(value) }),
  float: (value: number): Value => ({ kind: "float", value }),
  string: (value: string): Value => ({ kind: "string", value }),
  extended: (ext: ExtKind, text: string): Value => ({ kind: "extended", ext, text }),
  seq: (items: Value[]): Value => ({ kind: "seq", items }),
  map: (entries: Array<[Value, Value]>): Value => ({ kind: "map", entries }),
};

/** A plain JavaScript value `fromJS` accepts and `toJS` produces. */
export type JsValue =
  | null
  | undefined
  | boolean
  | number
  | bigint
  | string
  | JsValue[]
  | Map<JsValue, JsValue>
  | { [key: string]: JsValue };

/** Convert a plain JavaScript value into a {@link Value} tree. Integers map to
 *  `int` (or `uint` past the i64 range), other numbers to `float`; a `Map`
 *  preserves entry order and non-string keys, a plain object becomes a string-
 *  keyed map in insertion order. */
export function fromJS(input: JsValue): Value {
  if (input === null || input === undefined) return V.null();
  switch (typeof input) {
    case "boolean":
      return V.bool(input);
    case "string":
      return V.string(input);
    case "number":
      return Number.isInteger(input) ? V.int(BigInt(input)) : V.float(input);
    case "bigint":
      return input >= 0n && input > I64_MAX ? V.uint(input) : V.int(input);
    case "object":
      break;
    default:
      throw new TypeError(`cannot convert ${typeof input} to a fig value`);
  }
  if (Array.isArray(input)) return V.seq(input.map(fromJS));
  if (input instanceof Map) {
    return V.map(Array.from(input, ([k, v]) => [fromJS(k), fromJS(v)] as [Value, Value]));
  }
  return V.map(Object.entries(input).map(([k, v]) => [V.string(k), fromJS(v)] as [Value, Value]));
}

/** Convert a {@link Value} tree into a plain JavaScript value. Integers that fit
 *  a safe JS number become a `number`, otherwise a `bigint`. A map with all
 *  string keys becomes a plain object; otherwise a `Map`. */
export function toJS(value: Value): JsValue {
  switch (value.kind) {
    case "null":
      return null;
    case "bool":
      return value.value;
    case "int":
    case "uint":
      return value.value >= BigInt(Number.MIN_SAFE_INTEGER) && value.value <= BigInt(Number.MAX_SAFE_INTEGER)
        ? Number(value.value)
        : value.value;
    case "float":
      return value.value;
    case "string":
      return value.value;
    case "extended":
      return value.text;
    case "seq":
      return value.items.map(toJS);
    case "map": {
      if (value.entries.every(([k]) => k.kind === "string")) {
        const obj: { [key: string]: JsValue } = {};
        for (const [k, v] of value.entries) obj[(k as { value: string }).value] = toJS(v);
        return obj;
      }
      return new Map(value.entries.map(([k, v]) => [toJS(k), toJS(v)]));
    }
  }
}

/** Format a float the way fig's serializer reads it back: `.nan`/`.inf`, and a
 *  trailing `.0` so an integer-valued float stays a float. Mirrors the Rust
 *  binding's `format_float`. */
function formatFloat(f: number): string {
  if (Number.isNaN(f)) return ".nan";
  if (!Number.isFinite(f)) return f < 0 ? "-.inf" : ".inf";
  const s = String(f);
  return /^-?\d+$/.test(s) ? `${s}.0` : s;
}

/** Build `value` into the open value handle bottom-up (children first),
 *  returning the new root node's id. */
function build(handle: number, value: Value, frame: Frame, scratch: number): number {
  const emit = (status: number): number => {
    check(status, "fig_value");
    return readU32(scratch);
  };

  switch (value.kind) {
    case "null":
      return emit(fig.fig_value_null(handle, scratch));
    case "bool":
      return emit(fig.fig_value_bool(handle, value.value ? 1 : 0, scratch));
    case "int":
      if (value.value >= I64_MIN && value.value <= I64_MAX) return emit(fig.fig_value_int(handle, value.value, scratch));
      return emitNumber(handle, value.value.toString(), false, frame, scratch, emit);
    case "uint":
      if (value.value >= 0n && value.value <= U64_MAX) return emit(fig.fig_value_uint(handle, value.value, scratch));
      return emitNumber(handle, value.value.toString(), false, frame, scratch, emit);
    case "float":
      return emitNumber(handle, formatFloat(value.value), true, frame, scratch, emit);
    case "string": {
      const s = frame.str(value.value);
      return emit(fig.fig_value_string(handle, s.ptr, s.len, scratch));
    }
    case "extended": {
      const t = frame.str(value.text);
      return emit(fig.fig_value_extended(handle, value.ext, t.ptr, t.len, scratch));
    }
    case "seq": {
      const ids = value.items.map((it) => build(handle, it, frame, scratch));
      const arr = encodeNodeIds(frame, ids);
      return emit(fig.fig_value_seq(handle, arr.ptr, arr.len, scratch));
    }
    case "map": {
      const entries = value.entries.map(([k, v]) => [build(handle, k, frame, scratch), build(handle, v, frame, scratch)] as [number, number]);
      const arr = encodeEntries(frame, entries);
      return emit(fig.fig_value_map(handle, arr.ptr, arr.len, scratch));
    }
  }
  throw new Error("unreachable value kind");
}

function emitNumber(handle: number, text: string, isFloat: boolean, frame: Frame, scratch: number, emit: (s: number) => number): number {
  const t = frame.str(text);
  return emit(fig.fig_value_number(handle, t.ptr, t.len, isFloat ? 1 : 0, scratch));
}

/** Render a value to `format` via fig's serializer. Accepts a {@link Value} tree
 *  or any plain JS value (converted with {@link fromJS}). `options` controls
 *  output style such as compact vs. pretty-printed JSON. */
export function serialize(value: Value | JsValue, format: Format, options?: SerializeOptions): string {
  const node: Value = isValue(value) ? value : fromJS(value as JsValue);
  const frame = new Frame();
  const outValue = frame.alloc(4); // *FigValue out-pointer
  try {
    check(fig.fig_value_create(outValue), "fig_value_create");
    const handle = readU32(outValue);
    try {
      const scratch = frame.alloc(8); // out_id / out_ptr+out_len
      const root = build(handle, node, frame, scratch);
      const optsPtr = encodeOptions(frame, options);
      check(fig.fig_value_serialize_opts(handle, root, format, optsPtr, scratch, scratch + 4), "fig_value_serialize_opts");
      return readOutSlice(scratch);
    } finally {
      fig.fig_value_destroy(handle);
    }
  } finally {
    frame.dispose();
  }
}

/** Serialize a value for splicing into an editor: the rendered form with a
 *  single trailing newline stripped (the editor re-frames context at the site).
 *  Mirrors the Rust binding's `value_text`. */
export function valueText(value: Value | JsValue, format: Format, options?: SerializeOptions): string {
  const s = serialize(value, format, options);
  return s.endsWith("\n") ? s.slice(0, -1) : s;
}

/** Report what serializing `value` to `format` would silently lose (values/
 *  comments dropped or degraded). The built value has no source envelopes, so
 *  `options.lossless` is ignored. Returns one {@link Warning} per lossy event
 *  (empty if nothing is lost). The build/serialize mirror of {@link serialize}. */
export function diagnose(value: Value | JsValue, format: Format, options?: SerializeOptions): Warning[] {
  const node: Value = isValue(value) ? value : fromJS(value as JsValue);
  const frame = new Frame();
  const outValue = frame.alloc(4);
  try {
    check(fig.fig_value_create(outValue), "fig_value_create");
    const handle = readU32(outValue);
    try {
      const scratch = frame.alloc(8);
      const root = build(handle, node, frame, scratch);
      const optsPtr = encodeOptions(frame, options);
      const countPtr = frame.alloc(4);
      check(fig.fig_value_diagnose(handle, root, format, optsPtr, countPtr), "fig_value_diagnose");
      const count = readU32(countPtr);
      const warnPtr = frame.alloc(FIG_WARNING_SIZE);
      const out: Warning[] = [];
      for (let i = 0; i < count; i++) {
        writeWarningSize(warnPtr);
        check(fig.fig_value_warning(handle, i, warnPtr), "fig_value_warning");
        const w = readFigWarning(warnPtr);
        out.push({ code: w.code as WarningCode, cause: w.cause as WarningCause, path: w.path, note: w.note });
      }
      return out;
    } finally {
      fig.fig_value_destroy(handle);
    }
  } finally {
    frame.dispose();
  }
}

function readU32(ptr: number): number {
  return new DataView(fig.memory.buffer).getUint32(ptr, true);
}

function isValue(v: unknown): v is Value {
  return typeof v === "object" && v !== null && typeof (v as { kind?: unknown }).kind === "string" &&
    ["null", "bool", "int", "uint", "float", "string", "extended", "seq", "map"].includes((v as { kind: string }).kind);
}

/** Reconstruct a {@link Value} from a number's raw source text and float flag —
 *  the read-path mirror of the builder's number handling (i64, then u64, then
 *  float). Used by Document traversal. */
export function numberFromRaw(raw: string, isFloat: boolean): Value {
  if (!isFloat && /^[+-]?\d+$/.test(raw)) {
    const n = BigInt(raw);
    if (n >= I64_MIN && n <= I64_MAX) return V.int(n);
    if (n >= 0n && n <= U64_MAX) return V.uint(n);
  }
  const lower = raw.toLowerCase();
  if (lower === ".nan" || lower === "nan" || lower === "+.nan") return V.float(NaN);
  if (lower === ".inf" || lower === "+.inf" || lower === "inf") return V.float(Infinity);
  if (lower === "-.inf" || lower === "-inf") return V.float(-Infinity);
  return V.float(Number(raw));
}
