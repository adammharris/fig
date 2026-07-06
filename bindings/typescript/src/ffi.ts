// Low-level bridge to the fig wasm module.
//
// This file owns the single WebAssembly instance and the marshalling between
// JavaScript values and fig's C ABI: allocating in linear memory, encoding the
// path / key / id arrays the editor takes, and reading back the borrowed
// `(ptr, len)` slices the read and serialize paths return. Everything above it
// (Document, Editor, Embed, serialize) speaks in JS types and never touches a
// pointer.
//
// The module imports nothing and exports its memory. Instantiation is lazy: the
// first FFI call compiles it synchronously (fine under Node and Web Workers). A
// browser main thread forbids synchronous compilation of modules >4 KB, so
// there a caller must `await init()` once before any other call — see `init`.
import { WASM_BASE64 } from "./wasm-bytes.ts";
import type { SerializeOptions } from "./types.ts";

/** A fig C ABI status code. `Ok` is 0; everything else is a failure. */
export enum Status {
  Ok = 0,
  InvalidArgument = 1,
  ParseError = 2,
  OutOfMemory = 3,
  UnsupportedFormat = 4,
  NotFound = 5,
  InternalError = 255,
}

/** The exported fig symbols. All pointers and lengths are wasm32 `i32`; the two
 *  `fig_value_int`/`fig_value_uint` amounts cross as `i64` and so are `bigint`. */
interface Exports {
  memory: WebAssembly.Memory;
  fig_alloc(len: number): number;
  fig_free(ptr: number, len: number): void;

  fig_version(): number;
  fig_version_string(): number;
  fig_format_capabilities(format: number): number;

  fig_parse(input: number, input_len: number, format: number, out_doc: number): number;
  fig_parse_ex(input: number, input_len: number, format: number, out_doc: number, out_err: number): number;
  fig_document_destroy(doc: number): void;
  fig_document_serialize(doc: number, format: number, options: number, out_ptr: number, out_len: number): number;
  fig_document_diagnose(doc: number, format: number, options: number, out_count: number): number;
  fig_document_warning(doc: number, index: number, out: number): number;
  fig_value_diagnose(value: number, root: number, format: number, options: number, out_count: number): number;
  fig_value_warning(value: number, index: number, out: number): number;
  fig_document_root(doc: number): number;
  fig_node_kind(doc: number, node: number): number;
  fig_node_first_child(doc: number, node: number): number;
  fig_node_next_sibling(doc: number, node: number): number;
  fig_node_child_count(doc: number, node: number): number;
  fig_keyvalue_key(doc: number, node: number): number;
  fig_keyvalue_value(doc: number, node: number): number;
  fig_node_bool(doc: number, node: number, out: number): number;
  fig_node_number(doc: number, node: number, out_ptr: number, out_len: number): number;
  fig_node_string(doc: number, node: number, out_ptr: number, out_len: number): number;
  fig_node_extended(doc: number, node: number, out_kind: number, out_ptr: number, out_len: number): number;

  fig_editor_create(input: number, input_len: number, format: number, out: number): number;
  fig_editor_destroy(ed: number): void;
  fig_editor_replace_val(ed: number, path: number, path_len: number, repl: number, repl_len: number): number;
  fig_editor_replace_key(ed: number, path: number, path_len: number, repl: number, repl_len: number): number;
  fig_editor_set(ed: number, path: number, path_len: number, val: number, val_len: number): number;
  fig_editor_add_leading_comment(ed: number, path: number, path_len: number, text: number, text_len: number): number;
  fig_editor_set_trailing_comment(ed: number, path: number, path_len: number, text: number, text_len: number): number;
  fig_editor_delete_leading_comments(ed: number, path: number, path_len: number): number;
  fig_editor_delete_trailing_comment(ed: number, path: number, path_len: number): number;
  fig_editor_get_leading_comment(ed: number, path: number, path_len: number, out_ptr: number, out_len: number): number;
  fig_editor_get_trailing_comment(ed: number, path: number, path_len: number, out_ptr: number, out_len: number): number;
  fig_editor_insert_key(ed: number, path: number, path_len: number, key: number, key_len: number, val: number, val_len: number): number;
  fig_editor_delete_key(ed: number, path: number, path_len: number): number;
  fig_editor_append_seq(ed: number, path: number, path_len: number, val: number, val_len: number): number;
  fig_editor_prepend_seq(ed: number, path: number, path_len: number, val: number, val_len: number): number;
  fig_editor_remove_seq_item(ed: number, path: number, path_len: number, index: number): number;
  fig_editor_move_key(ed: number, src: number, src_len: number, dest: number, dest_len: number): number;
  fig_editor_reorder_keys(ed: number, path: number, path_len: number, keys: number, keys_len: number): number;
  fig_editor_move_item(ed: number, path: number, path_len: number, from: number, to: number): number;
  fig_editor_reorder_items(ed: number, path: number, path_len: number, indices: number, indices_len: number): number;
  fig_editor_set_sequence(ed: number, path: number, path_len: number, items: number, items_len: number): number;
  fig_editor_source(ed: number, out_ptr: number, out_len: number): number;

  fig_embed_extract(input: number, input_len: number, embed_type: number, out_region: number): number;
  fig_embed_open(input: number, input_len: number, embed_type: number, out: number): number;
  fig_embed_open_or_init(input: number, input_len: number, embed_type: number, out: number): number;
  fig_embed_destroy(em: number): void;
  fig_embed_replace_val(em: number, path: number, path_len: number, repl: number, repl_len: number): number;
  fig_embed_replace_key(em: number, path: number, path_len: number, repl: number, repl_len: number): number;
  fig_embed_set(em: number, path: number, path_len: number, val: number, val_len: number): number;
  fig_embed_add_leading_comment(em: number, path: number, path_len: number, text: number, text_len: number): number;
  fig_embed_set_trailing_comment(em: number, path: number, path_len: number, text: number, text_len: number): number;
  fig_embed_delete_leading_comments(em: number, path: number, path_len: number): number;
  fig_embed_delete_trailing_comment(em: number, path: number, path_len: number): number;
  fig_embed_get_leading_comment(em: number, path: number, path_len: number, out_ptr: number, out_len: number): number;
  fig_embed_get_trailing_comment(em: number, path: number, path_len: number, out_ptr: number, out_len: number): number;
  fig_embed_insert_key(em: number, path: number, path_len: number, key: number, key_len: number, val: number, val_len: number): number;
  fig_embed_delete_key(em: number, path: number, path_len: number): number;
  fig_embed_append_seq(em: number, path: number, path_len: number, val: number, val_len: number): number;
  fig_embed_prepend_seq(em: number, path: number, path_len: number, val: number, val_len: number): number;
  fig_embed_remove_seq_item(em: number, path: number, path_len: number, index: number): number;
  fig_embed_move_key(em: number, src: number, src_len: number, dest: number, dest_len: number): number;
  fig_embed_reorder_keys(em: number, path: number, path_len: number, keys: number, keys_len: number): number;
  fig_embed_move_item(em: number, path: number, path_len: number, from: number, to: number): number;
  fig_embed_reorder_items(em: number, path: number, path_len: number, indices: number, indices_len: number): number;
  fig_embed_set_sequence(em: number, path: number, path_len: number, items: number, items_len: number): number;
  fig_embed_replace_body(em: number, body: number, body_len: number): number;
  fig_embed_render(em: number, out_ptr: number, out_len: number): number;

  fig_value_create(out: number): number;
  fig_value_destroy(value: number): void;
  fig_value_null(value: number, out_id: number): number;
  fig_value_bool(value: number, b: number, out_id: number): number;
  fig_value_int(value: number, n: bigint, out_id: number): number;
  fig_value_uint(value: number, n: bigint, out_id: number): number;
  fig_value_number(value: number, raw: number, raw_len: number, is_float: number, out_id: number): number;
  fig_value_string(value: number, ptr: number, len: number, out_id: number): number;
  fig_value_extended(value: number, kind: number, text: number, text_len: number, out_id: number): number;
  fig_value_seq(value: number, items: number, items_len: number, out_id: number): number;
  fig_value_map(value: number, entries: number, entries_len: number, out_id: number): number;
  fig_value_serialize(value: number, root: number, format: number, out_ptr: number, out_len: number): number;
  fig_value_serialize_opts(value: number, root: number, format: number, options: number, out_ptr: number, out_len: number): number;
}

function decodeBase64(b64: string): Uint8Array<ArrayBuffer> {
  // `Buffer` under Node; `atob` in the browser. Either way, copy into a fresh
  // ArrayBuffer-backed view so the bytes satisfy `BufferSource` exactly.
  const g = globalThis as { Buffer?: { from(s: string, enc: string): Uint8Array }; atob?(s: string): string };
  if (g.Buffer) return new Uint8Array(g.Buffer.from(b64, "base64"));
  const bin = g.atob!(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// The instance is created lazily so that merely importing the package never
// compiles wasm — which would throw on a browser main thread (sync compile of a
// >4 KB module is disallowed there). `ensure()` does the sync compile on first
// use; `init()` does it asynchronously for the browser.
let exports: Exports | null = null;
let initPromise: Promise<void> | null = null;

/** Compile + instantiate the fig wasm module, synchronously. Return its exports
 *  or throw a guidance error (the browser-main-thread case). */
function ensure(): Exports {
  if (exports) return exports;
  try {
    const instance = new WebAssembly.Instance(new WebAssembly.Module(decodeBase64(WASM_BASE64)));
    exports = instance.exports as unknown as Exports;
  } catch (err) {
    throw new Error(
      "fig: the WebAssembly module failed to initialize synchronously. On a " +
        "browser main thread, call `await init()` once at startup before using " +
        "any fig API (synchronous compilation of modules larger than 4 KB is " +
        "disallowed there). Underlying error: " +
        (err instanceof Error ? err.message : String(err)),
    );
  }
  return exports;
}

/** Asynchronously compile + instantiate the fig wasm module. Safe to call
 *  anywhere — including a browser main thread — and idempotent (concurrent calls
 *  share one instantiation). Optional under Node and in Web Workers, where the
 *  module also initializes lazily on first use. Once it resolves, every fig API
 *  is usable synchronously. */
export function init(): Promise<void> {
  if (exports) return Promise.resolve();
  if (initPromise) return initPromise;
  initPromise = WebAssembly.instantiate(decodeBase64(WASM_BASE64), {}).then(({ instance }) => {
    exports = instance.exports as unknown as Exports;
  });
  return initPromise;
}

/** True once the wasm module is instantiated (after `init()` or a first sync
 *  call). Lets a browser caller check without triggering a sync compile. */
export function isReady(): boolean {
  return exports !== null;
}

// A Proxy so every existing `fig.fig_*` / `fig.memory` call site lazily triggers
// `ensure()` on first property access, with no change to the callers.
const fig: Exports = new Proxy({} as Exports, {
  get(_target, prop) {
    return ensure()[prop as keyof Exports];
  },
}) as Exports;

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: false });

/** A fresh view over linear memory. `memory.grow` detaches the old buffer, so a
 *  view must be re-derived after any allocation rather than cached. */
function u8(): Uint8Array {
  return new Uint8Array(ensure().memory.buffer);
}
function dv(): DataView {
  return new DataView(ensure().memory.buffer);
}

/** A scratch arena: every allocation made through a frame is freed together by
 *  `dispose`, so an FFI call's transient buffers never leak even on a throw. */
export class Frame {
  private allocs: Array<[number, number]> = [];

  /** Allocate `len` uninitialized bytes (no-op pointer 0 for an empty request). */
  alloc(len: number): number {
    if (len === 0) return 0;
    const ptr = ensure().fig_alloc(len);
    if (ptr === 0) throw new Error("fig_alloc: out of memory");
    this.allocs.push([ptr, len]);
    return ptr;
  }

  /** Copy `data` into freshly allocated memory; returns its pointer (0 if empty). */
  bytes(data: Uint8Array): number {
    const ptr = this.alloc(data.length);
    if (ptr !== 0) u8().set(data, ptr);
    return ptr;
  }

  /** UTF-8 encode `s` into memory. */
  str(s: string): { ptr: number; len: number } {
    const data = encoder.encode(s);
    return { ptr: this.bytes(data), len: data.length };
  }

  dispose(): void {
    if (this.allocs.length === 0) return;
    const free = ensure().fig_free;
    for (const [ptr, len] of this.allocs) free(ptr, len);
    this.allocs.length = 0;
  }
}

/** A path segment: a string selects a mapping key, a number a sequence index. */
export type Segment = string | number;
const SEG_SIZE = 16; // FigPathSegment: kind i32, key_ptr, key_len, index (4×4 on wasm32)

/** Encode a path into a `FigPathSegment[]`. All key strings are allocated first
 *  so the struct array is the last allocation — its view stays valid while we
 *  fill it (no `grow` in between). */
export function encodePath(frame: Frame, path: readonly Segment[]): { ptr: number; len: number } {
  if (path.length === 0) return { ptr: 0, len: 0 };
  const keys = path.map((seg) => (typeof seg === "string" ? frame.str(seg) : null));
  const ptr = frame.alloc(path.length * SEG_SIZE);
  const view = dv();
  path.forEach((seg, i) => {
    const base = ptr + i * SEG_SIZE;
    const key = keys[i];
    if (typeof seg === "number") {
      view.setInt32(base, 1, true); // kind = index
      view.setUint32(base + 4, 0, true);
      view.setUint32(base + 8, 0, true);
      view.setUint32(base + 12, seg, true);
    } else if (key) {
      view.setInt32(base, 0, true); // kind = key
      view.setUint32(base + 4, key.ptr, true);
      view.setUint32(base + 8, key.len, true);
      view.setUint32(base + 12, 0, true);
    }
  });
  return { ptr, len: path.length };
}

/** Encode a `FigStr[]` (the key list for reorder_keys). */
export function encodeKeyList(frame: Frame, keys: readonly string[]): { ptr: number; len: number } {
  if (keys.length === 0) return { ptr: 0, len: 0 };
  const strs = keys.map((k) => frame.str(k));
  const ptr = frame.alloc(keys.length * 8); // FigStr: ptr, len
  const view = dv();
  strs.forEach((s, i) => {
    view.setUint32(ptr + i * 8, s.ptr, true);
    view.setUint32(ptr + i * 8 + 4, s.len, true);
  });
  return { ptr, len: keys.length };
}

/** Encode a `usize[]` index list (for reorder_items). */
export function encodeIndexList(frame: Frame, indices: readonly number[]): { ptr: number; len: number } {
  if (indices.length === 0) return { ptr: 0, len: 0 };
  const ptr = frame.alloc(indices.length * 4);
  const view = dv();
  indices.forEach((idx, i) => view.setUint32(ptr + i * 4, idx, true));
  return { ptr, len: indices.length };
}

/** Encode a `FigNodeId[]` (u32 each) — the item list for fig_value_seq. */
export function encodeNodeIds(frame: Frame, ids: readonly number[]): { ptr: number; len: number } {
  if (ids.length === 0) return { ptr: 0, len: 0 };
  const ptr = frame.alloc(ids.length * 4);
  const view = dv();
  ids.forEach((id, i) => view.setUint32(ptr + i * 4, id, true));
  return { ptr, len: ids.length };
}

/** Encode a `FigKeyValue[]` ({key, value} u32 pair each) — for fig_value_map. */
export function encodeEntries(frame: Frame, entries: ReadonlyArray<[number, number]>): { ptr: number; len: number } {
  if (entries.length === 0) return { ptr: 0, len: 0 };
  const ptr = frame.alloc(entries.length * 8);
  const view = dv();
  entries.forEach(([key, value], i) => {
    view.setUint32(ptr + i * 8, key, true);
    view.setUint32(ptr + i * 8 + 4, value, true);
  });
  return { ptr, len: entries.length };
}

/** Read the UTF-8 slice that an out-param `(ptr, len)` pair points at. The pair
 *  itself is written into an 8-byte scratch buffer the caller passes. */
export function readOutSlice(scratch: number): string {
  const view = dv();
  const ptr = view.getUint32(scratch, true);
  const len = view.getUint32(scratch + 4, true);
  if (len === 0) return "";
  return decoder.decode(u8().subarray(ptr, ptr + len));
}

export function readU32(ptr: number): number {
  return dv().getUint32(ptr, true);
}

/** Write a little-endian u32 into linear memory (e.g. a size-version tag). */
export function writeU32(ptr: number, value: number): void {
  dv().setUint32(ptr, value, true);
}

/** Read a NUL-terminated C string from linear memory (e.g. fig_version_string). */
export function readCString(ptr: number): string {
  if (ptr === 0) return "";
  const mem = u8();
  let end = ptr;
  while (mem[end] !== 0) end++;
  return decoder.decode(mem.subarray(ptr, end));
}

// FigSerializeOptions { u32 size; u8 pretty; u8 indent; u8 strip_comments; u8
// lossless; u16 width; } — the u16 sits at offset 8 and the struct pads to a
// 12-byte size (4-byte alignment from `size`). `size` is the version tag (its
// byte size, so the core reads every field we set). All fields are written
// explicitly; passing NULL (ptr 0) instead would select all defaults.
const SERIALIZE_OPTIONS_SIZE = 12;
export function encodeOptions(frame: Frame, options?: SerializeOptions): number {
  const pretty = options?.pretty === false ? 0 : 1;
  const indent = options?.indent ?? 2;
  const strip = options?.stripComments ? 1 : 0;
  const lossless = options?.lossless ? 1 : 0;
  const width = options?.width ?? 80;
  return frame.bytes(
    new Uint8Array([
      SERIALIZE_OPTIONS_SIZE, 0, 0, 0, // u32 size (LE)
      pretty, indent, strip, lossless,
      width & 0xff, (width >> 8) & 0xff, // u16 width (LE) at offset 8
      0, 0, // padding to the 12-byte struct size
    ]),
  );
}

// FigError on wasm32: u32 size; i32 code; usize byte_offset; u32 line; u32
// column; usize message_len; char message[256]. usize is 4 bytes here, so the
// message starts at offset 24 and the struct is 280 bytes.
export const FIG_ERROR_SIZE = 280;
/** Allocate a FigError, write its `size` tag, and return the pointer. */
export function allocFigError(frame: Frame): number {
  const ptr = frame.alloc(FIG_ERROR_SIZE);
  dv().setUint32(ptr, FIG_ERROR_SIZE, true);
  return ptr;
}
/** Decode a filled FigError. `byte_offset`/`line`/`column` of 0 mean "unknown"
 *  and surface as `undefined`. */
export function readFigError(ptr: number): {
  code: number;
  message: string;
  byteOffset?: number | undefined;
  line?: number | undefined;
  column?: number | undefined;
} {
  const view = dv();
  const code = view.getInt32(ptr + 4, true);
  const byteOffset = view.getUint32(ptr + 8, true);
  const line = view.getUint32(ptr + 12, true);
  const column = view.getUint32(ptr + 16, true);
  const messageLen = view.getUint32(ptr + 20, true);
  const message = messageLen === 0 ? "" : decoder.decode(u8().subarray(ptr + 24, ptr + 24 + messageLen));
  return {
    code,
    message,
    byteOffset: byteOffset !== 0 ? byteOffset : undefined,
    line: line !== 0 ? line : undefined,
    column: column !== 0 ? column : undefined,
  };
}

// FigWarning on wasm32: u32 size; i32 code; i32 cause; ptr path; usize path_len;
// ptr note; usize note_len — 28 bytes (all 4-byte fields).
export const FIG_WARNING_SIZE = 28;
/** Allocate a FigWarning and write its `size` tag; reusable across a diagnose
 *  loop (rewrite the tag each iteration since the call overwrites the body). */
export function writeWarningSize(ptr: number): void {
  dv().setUint32(ptr, FIG_WARNING_SIZE, true);
}
/** Decode a filled FigWarning, copying the borrowed path/note slices out now
 *  (they live in the handle's arena until the next diagnose / destroy). */
export function readFigWarning(ptr: number): { code: number; cause: number; path: string; note: string } {
  const view = dv();
  const code = view.getInt32(ptr + 4, true);
  const cause = view.getInt32(ptr + 8, true);
  const pathPtr = view.getUint32(ptr + 12, true);
  const pathLen = view.getUint32(ptr + 16, true);
  const notePtr = view.getUint32(ptr + 20, true);
  const noteLen = view.getUint32(ptr + 24, true);
  const path = pathLen === 0 ? "" : decoder.decode(u8().subarray(pathPtr, pathPtr + pathLen));
  const note = noteLen === 0 ? "" : decoder.decode(u8().subarray(notePtr, notePtr + noteLen));
  return { code, cause, path, note };
}

/** Build a FinalizationRegistry that frees a native handle when its JS wrapper
 *  is garbage-collected without an explicit `dispose()` — a leak backstop, not a
 *  substitute for `using`/`dispose()` (GC timing is unspecified). Returns `null`
 *  on a runtime without FinalizationRegistry, so callers stay a no-op there. */
export function handleRegistry(destroy: (handle: number) => void): FinalizationRegistry<number> | null {
  return typeof FinalizationRegistry !== "undefined" ? new FinalizationRegistry(destroy) : null;
}

export { fig };
