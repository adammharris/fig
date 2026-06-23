// Shared comment-preserving edit operations for the document editor and the
// embed editor.
//
// The two write paths are identical apart from the C symbol prefix
// (`fig_editor_*` vs `fig_embed_*`) and the format a `Value` is serialized to
// before splicing. `Editable` captures that: a subclass hands it the bound FFI
// functions and its text format, and inherits every path-addressed edit. Each
// value-taking edit renders its `Value` through fig's serializer (stripping the
// trailing newline) and lets the Zig editor re-frame indentation at the splice
// site; the `*Raw` variants pass already-serialized text straight through.
import { check, Format } from "./types.ts";
import { Frame, encodePath, encodeKeyList, encodeIndexList, type Segment } from "./ffi.ts";
import { V, valueText, type JsValue, type Value } from "./value.ts";

/** The bound C ABI edit functions a concrete editor supplies. */
export interface EditFns {
  replaceVal(h: number, path: number, pathLen: number, repl: number, replLen: number): number;
  replaceKey(h: number, path: number, pathLen: number, repl: number, replLen: number): number;
  insertKey(h: number, path: number, pathLen: number, key: number, keyLen: number, val: number, valLen: number): number;
  deleteKey(h: number, path: number, pathLen: number): number;
  appendSeq(h: number, path: number, pathLen: number, val: number, valLen: number): number;
  prependSeq(h: number, path: number, pathLen: number, val: number, valLen: number): number;
  removeSeqItem(h: number, path: number, pathLen: number, index: number): number;
  moveKey(h: number, src: number, srcLen: number, dest: number, destLen: number): number;
  reorderKeys(h: number, path: number, pathLen: number, keys: number, keysLen: number): number;
  moveItem(h: number, path: number, pathLen: number, from: number, to: number): number;
  reorderItems(h: number, path: number, pathLen: number, indices: number, indicesLen: number): number;
  addLeadingComment(h: number, path: number, pathLen: number, text: number, textLen: number): number;
  setTrailingComment(h: number, path: number, pathLen: number, text: number, textLen: number): number;
  deleteLeadingComments(h: number, path: number, pathLen: number): number;
  deleteTrailingComment(h: number, path: number, pathLen: number): number;
}

export { type Segment };

export abstract class Editable {
  protected disposed = false;
  protected constructor(protected handle: number, private fns: EditFns, private textFormat: Format) {}

  protected live(): number {
    if (this.disposed) throw new Error(`${this.constructor.name} already disposed`);
    return this.handle;
  }

  // ── value edits (over Value / plain JS) ─────────────────────────────────

  /** Replace the value at `path` with `value`. */
  replaceValue(path: readonly Segment[], value: Value | JsValue): void {
    this.replaceValueRaw(path, valueText(value, this.textFormat));
  }

  /** Replace the key at `path` with `key`. */
  replaceKey(path: readonly Segment[], key: string): void {
    const frame = new Frame();
    try {
      const p = encodePath(frame, path);
      const t = frame.str(valueText(V.string(key), this.textFormat));
      check(this.fns.replaceKey(this.live(), p.ptr, p.len, t.ptr, t.len), "replaceKey");
    } finally {
      frame.dispose();
    }
  }

  /** Insert `key: value` into the mapping at `path` (empty path = root). */
  insertValue(path: readonly Segment[], key: string, value: Value | JsValue): void {
    this.insertValueRaw(path, key, valueText(value, this.textFormat));
  }

  /** Append `value` to the sequence at `path`. */
  appendValue(path: readonly Segment[], value: Value | JsValue): void {
    this.appendValueRaw(path, valueText(value, this.textFormat));
  }

  /** Prepend `value` to the sequence at `path`. */
  prependValue(path: readonly Segment[], value: Value | JsValue): void {
    this.prependValueRaw(path, valueText(value, this.textFormat));
  }

  // ── raw edits (caller supplies serialized text) ─────────────────────────

  /** Replace the value at `path` with already-serialized `text`. */
  replaceValueRaw(path: readonly Segment[], text: string): void {
    const frame = new Frame();
    try {
      const p = encodePath(frame, path);
      const t = frame.str(text);
      check(this.fns.replaceVal(this.live(), p.ptr, p.len, t.ptr, t.len), "replaceValue");
    } finally {
      frame.dispose();
    }
  }

  /** Insert `key:` mapped to already-serialized `text` at `path`. */
  insertValueRaw(path: readonly Segment[], key: string, text: string): void {
    const frame = new Frame();
    try {
      const p = encodePath(frame, path);
      const k = frame.str(valueText(V.string(key), this.textFormat));
      const t = frame.str(text);
      check(this.fns.insertKey(this.live(), p.ptr, p.len, k.ptr, k.len, t.ptr, t.len), "insertValue");
    } finally {
      frame.dispose();
    }
  }

  /** Append already-serialized `text` to the sequence at `path`. */
  appendValueRaw(path: readonly Segment[], text: string): void {
    this.seqEdit(path, text, this.fns.appendSeq, "appendValue");
  }

  /** Prepend already-serialized `text` to the sequence at `path`. */
  prependValueRaw(path: readonly Segment[], text: string): void {
    this.seqEdit(path, text, this.fns.prependSeq, "prependValue");
  }

  private seqEdit(path: readonly Segment[], text: string, fn: EditFns["appendSeq"], op: string): void {
    const frame = new Frame();
    try {
      const p = encodePath(frame, path);
      const t = frame.str(text);
      check(fn(this.live(), p.ptr, p.len, t.ptr, t.len), op);
    } finally {
      frame.dispose();
    }
  }

  // ── structural edits ────────────────────────────────────────────────────

  /** Delete the mapping entry named by `path`. */
  delete(path: readonly Segment[]): void {
    const frame = new Frame();
    try {
      const p = encodePath(frame, path);
      check(this.fns.deleteKey(this.live(), p.ptr, p.len), "delete");
    } finally {
      frame.dispose();
    }
  }

  /** Remove the item at `index` from the sequence at `path`. */
  removeItem(path: readonly Segment[], index: number): void {
    const frame = new Frame();
    try {
      const p = encodePath(frame, path);
      check(this.fns.removeSeqItem(this.live(), p.ptr, p.len, index), "removeItem");
    } finally {
      frame.dispose();
    }
  }

  /** Move the entry at `src` to immediately before the entry at `dest` (same mapping). */
  moveKey(src: readonly Segment[], dest: readonly Segment[]): void {
    const frame = new Frame();
    try {
      const s = encodePath(frame, src);
      const d = encodePath(frame, dest);
      check(this.fns.moveKey(this.live(), s.ptr, s.len, d.ptr, d.len), "moveKey");
    } finally {
      frame.dispose();
    }
  }

  /** Reorder the mapping at `path` so `keys` come first, in order; the rest
   *  follow in their original order (unknown keys ignored). */
  reorderKeys(path: readonly Segment[], keys: readonly string[]): void {
    const frame = new Frame();
    try {
      const p = encodePath(frame, path);
      const k = encodeKeyList(frame, keys);
      check(this.fns.reorderKeys(this.live(), p.ptr, p.len, k.ptr, k.len), "reorderKeys");
    } finally {
      frame.dispose();
    }
  }

  /** Move the sequence item at index `from` to index `to`. */
  moveItem(path: readonly Segment[], from: number, to: number): void {
    const frame = new Frame();
    try {
      const p = encodePath(frame, path);
      check(this.fns.moveItem(this.live(), p.ptr, p.len, from, to), "moveItem");
    } finally {
      frame.dispose();
    }
  }

  /** Reorder the sequence at `path` so `indices` come first, in order; the rest
   *  follow in their original order (out-of-range indices ignored). */
  reorderItems(path: readonly Segment[], indices: readonly number[]): void {
    const frame = new Frame();
    try {
      const p = encodePath(frame, path);
      const idx = encodeIndexList(frame, indices);
      check(this.fns.reorderItems(this.live(), p.ptr, p.len, idx.ptr, idx.len), "reorderItems");
    } finally {
      frame.dispose();
    }
  }

  // ── comment editing ─────────────────────────────────────────────────────

  /** Add an own-line comment ABOVE the node at `path` (the key's line for a
   *  mapping entry), at its indentation, nearest the node. `text` may be
   *  multi-line (one comment line each). The marker (`#` for YAML, `//` for
   *  JSONC/JSON5) is added for you; strict JSON throws `UnsupportedFormat`. */
  addLeadingComment(path: readonly Segment[], text: string): void {
    this.commentEdit(path, text, this.fns.addLeadingComment, "addLeadingComment");
  }

  /** Set the same-line trailing comment on the value at `path`, replacing an
   *  existing one or appending if absent. `text` must be single-line. */
  setTrailingComment(path: readonly Segment[], text: string): void {
    this.commentEdit(path, text, this.fns.setTrailingComment, "setTrailingComment");
  }

  /** Remove the own-line comment block above the node at `path` (no-op if none). */
  deleteLeadingComments(path: readonly Segment[]): void {
    const frame = new Frame();
    try {
      const p = encodePath(frame, path);
      check(this.fns.deleteLeadingComments(this.live(), p.ptr, p.len), "deleteLeadingComments");
    } finally {
      frame.dispose();
    }
  }

  /** Remove the same-line trailing comment on the value at `path` (no-op if none). */
  deleteTrailingComment(path: readonly Segment[]): void {
    const frame = new Frame();
    try {
      const p = encodePath(frame, path);
      check(this.fns.deleteTrailingComment(this.live(), p.ptr, p.len), "deleteTrailingComment");
    } finally {
      frame.dispose();
    }
  }

  private commentEdit(path: readonly Segment[], text: string, fn: EditFns["addLeadingComment"], op: string): void {
    const frame = new Frame();
    try {
      const p = encodePath(frame, path);
      const t = frame.str(text);
      check(fn(this.live(), p.ptr, p.len, t.ptr, t.len), op);
    } finally {
      frame.dispose();
    }
  }

  abstract dispose(): void;

  [Symbol.dispose](): void {
    this.dispose();
  }
}
