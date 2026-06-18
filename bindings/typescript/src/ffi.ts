// Low-level bridge to the fig wasm module.
//
// This file owns the single WebAssembly instance and the marshalling between
// JavaScript values and fig's C ABI: allocating in linear memory, encoding the
// path / key / id arrays the editor takes, and reading back the borrowed
// `(ptr, len)` slices the read and serialize paths return. Everything above it
// (Document, Editor, Embed, serialize) speaks in JS types and never touches a
// pointer.
//
// The module imports nothing and exports its memory, so it instantiates
// synchronously and works identically under Node and in the browser.
import { WASM_BASE64 } from "./wasm-bytes.ts";

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

  fig_parse(input: number, input_len: number, format: number, out_doc: number): number;
  fig_document_destroy(doc: number): void;
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

  fig_editor_create(input: number, input_len: number, format: number, out: number): number;
  fig_editor_destroy(ed: number): void;
  fig_editor_replace_val(ed: number, path: number, path_len: number, repl: number, repl_len: number): number;
  fig_editor_replace_key(ed: number, path: number, path_len: number, repl: number, repl_len: number): number;
  fig_editor_insert_key(ed: number, path: number, path_len: number, key: number, key_len: number, val: number, val_len: number): number;
  fig_editor_delete_key(ed: number, path: number, path_len: number): number;
  fig_editor_append_seq(ed: number, path: number, path_len: number, val: number, val_len: number): number;
  fig_editor_prepend_seq(ed: number, path: number, path_len: number, val: number, val_len: number): number;
  fig_editor_remove_seq_item(ed: number, path: number, path_len: number, index: number): number;
  fig_editor_move_key(ed: number, src: number, src_len: number, dest: number, dest_len: number): number;
  fig_editor_reorder_keys(ed: number, path: number, path_len: number, keys: number, keys_len: number): number;
  fig_editor_move_item(ed: number, path: number, path_len: number, from: number, to: number): number;
  fig_editor_reorder_items(ed: number, path: number, path_len: number, indices: number, indices_len: number): number;
  fig_editor_source(ed: number, out_ptr: number, out_len: number): number;

  fig_embed_extract(input: number, input_len: number, embed_type: number, out_region: number): number;
  fig_embed_open(input: number, input_len: number, embed_type: number, out: number): number;
  fig_embed_destroy(em: number): void;
  fig_embed_replace_val(em: number, path: number, path_len: number, repl: number, repl_len: number): number;
  fig_embed_replace_key(em: number, path: number, path_len: number, repl: number, repl_len: number): number;
  fig_embed_insert_key(em: number, path: number, path_len: number, key: number, key_len: number, val: number, val_len: number): number;
  fig_embed_delete_key(em: number, path: number, path_len: number): number;
  fig_embed_append_seq(em: number, path: number, path_len: number, val: number, val_len: number): number;
  fig_embed_prepend_seq(em: number, path: number, path_len: number, val: number, val_len: number): number;
  fig_embed_remove_seq_item(em: number, path: number, path_len: number, index: number): number;
  fig_embed_move_key(em: number, src: number, src_len: number, dest: number, dest_len: number): number;
  fig_embed_reorder_keys(em: number, path: number, path_len: number, keys: number, keys_len: number): number;
  fig_embed_move_item(em: number, path: number, path_len: number, from: number, to: number): number;
  fig_embed_reorder_items(em: number, path: number, path_len: number, indices: number, indices_len: number): number;
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

const instance = new WebAssembly.Instance(new WebAssembly.Module(decodeBase64(WASM_BASE64)));
const exports = instance.exports as unknown as Exports;

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: false });

/** A fresh view over linear memory. `memory.grow` detaches the old buffer, so a
 *  view must be re-derived after any allocation rather than cached. */
function u8(): Uint8Array {
  return new Uint8Array(exports.memory.buffer);
}
function dv(): DataView {
  return new DataView(exports.memory.buffer);
}

/** A scratch arena: every allocation made through a frame is freed together by
 *  `dispose`, so an FFI call's transient buffers never leak even on a throw. */
export class Frame {
  private allocs: Array<[number, number]> = [];

  /** Allocate `len` uninitialized bytes (no-op pointer 0 for an empty request). */
  alloc(len: number): number {
    if (len === 0) return 0;
    const ptr = exports.fig_alloc(len);
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
    for (const [ptr, len] of this.allocs) exports.fig_free(ptr, len);
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

export { exports as fig };
