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
import { check, Format, type SerializeOptions } from "./types.ts";
import { Frame, encodePath, encodeKeyList, encodeIndexList, readOutSlice, Status, type Segment } from "./ffi.ts";
import { V, valueText, valueTextWith, type JsInput, type Value } from "./value.ts";

/** The bound C ABI edit functions a concrete editor supplies. */
export interface EditFns {
  replaceVal(h: number, path: number, pathLen: number, repl: number, replLen: number): number;
  replaceKey(h: number, path: number, pathLen: number, repl: number, replLen: number): number;
  set(h: number, path: number, pathLen: number, val: number, valLen: number): number;
  insertKey(h: number, path: number, pathLen: number, key: number, keyLen: number, val: number, valLen: number): number;
  deleteKey(h: number, path: number, pathLen: number): number;
  appendSeq(h: number, path: number, pathLen: number, val: number, valLen: number): number;
  prependSeq(h: number, path: number, pathLen: number, val: number, valLen: number): number;
  removeSeqItem(h: number, path: number, pathLen: number, index: number): number;
  moveKey(h: number, src: number, srcLen: number, dest: number, destLen: number): number;
  reorderKeys(h: number, path: number, pathLen: number, keys: number, keysLen: number): number;
  moveItem(h: number, path: number, pathLen: number, from: number, to: number): number;
  reorderItems(h: number, path: number, pathLen: number, indices: number, indicesLen: number): number;
  setSequence(h: number, path: number, pathLen: number, items: number, itemsLen: number): number;
  addLeadingComment(h: number, path: number, pathLen: number, text: number, textLen: number): number;
  setTrailingComment(h: number, path: number, pathLen: number, text: number, textLen: number): number;
  deleteLeadingComments(h: number, path: number, pathLen: number): number;
  deleteTrailingComment(h: number, path: number, pathLen: number): number;
  getLeadingComment(h: number, path: number, pathLen: number, outPtr: number, outLen: number): number;
  getTrailingComment(h: number, path: number, pathLen: number, outPtr: number, outLen: number): number;
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
  replaceValue(path: readonly Segment[], value: Value | JsInput): void {
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
  insertValue(path: readonly Segment[], key: string, value: Value | JsInput): void {
    this.insertValueRaw(path, key, valueText(value, this.textFormat));
  }

  /** Upsert a mapping value: replace the value at `path`, or insert it when only
   *  the trailing key is absent. Folds the `replaceValue` → (on `NotFound`)
   *  `insertValue` two-step into one call. `path` must end in a key; a missing
   *  intermediate container throws `NotFound`. */
  set(path: readonly Segment[], value: Value | JsInput): void {
    this.setRaw(path, valueText(value, this.textFormat));
  }

  // ── value edits with a layout knob (block-vs-inline containers) ─────────
  //
  // The plain methods above render a fig container value as inline flow
  // (`k = { … }`) — the only spelling a bare inline splice can carry. These
  // `*With` twins honor `options` (notably `width`): a map/sequence that does
  // not fit renders as a BLOCK section, which the core editor re-frames under
  // the target key (`key` header + `> …` body). The width knob for splices —
  // e.g. landing a short map one-record-per-line instead of frozen inline.

  /** Replace the value at `path`, rendering `value` with `options` (a block
   *  map/sequence lands as a nested section). */
  replaceValueWith(path: readonly Segment[], value: Value | JsInput, options?: SerializeOptions): void {
    this.replaceValueRaw(path, valueTextWith(value, this.textFormat, options));
  }

  /** Insert `key: value` into the mapping at `path`, rendering `value` with
   *  `options` (a block map/sequence lands as a nested section). */
  insertValueWith(path: readonly Segment[], key: string, value: Value | JsInput, options?: SerializeOptions): void {
    this.insertValueRaw(path, key, valueTextWith(value, this.textFormat, options));
  }

  /** Upsert the value at `path`, rendering `value` with `options` (a block
   *  map/sequence lands as a nested section). The width-aware twin of `set`. */
  setWith(path: readonly Segment[], value: Value | JsInput, options?: SerializeOptions): void {
    this.setRaw(path, valueTextWith(value, this.textFormat, options));
  }

  /** Append `value` to the sequence at `path`. */
  appendValue(path: readonly Segment[], value: Value | JsInput): void {
    this.appendValueRaw(path, valueText(value, this.textFormat));
  }

  /** Prepend `value` to the sequence at `path`. */
  prependValue(path: readonly Segment[], value: Value | JsInput): void {
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

  /** Upsert `path` to already-serialized `text` (replace, else insert the
   *  trailing key). See `set`. */
  setRaw(path: readonly Segment[], text: string): void {
    const frame = new Frame();
    try {
      const p = encodePath(frame, path);
      const t = frame.str(text);
      check(this.fns.set(this.live(), p.ptr, p.len, t.ptr, t.len), "set");
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

  /** Reconcile the sequence at `path` so its items are exactly `items`, while
   *  preserving the comments on items that survive. Items are matched to the
   *  current ones by value (kind + value, honoring multiplicity), so a kept or
   *  merely reordered item keeps its leading and trailing comments; only
   *  genuinely new values are inserted and only dropped values are deleted. The
   *  result order matches `items`. Throws (invalid argument) when the shape
   *  can't be safely diffed — an empty list, an empty current list, a non-scalar
   *  item on either side, a non-sequence target, or a format whose scalars can't
   *  stand alone (TOML); the caller should then replace the whole value. */
  setSequence(path: readonly Segment[], items: readonly (Value | JsInput)[]): void {
    const frame = new Frame();
    try {
      const p = encodePath(frame, path);
      const texts = items.map((v) => valueText(v, this.textFormat));
      const it = encodeKeyList(frame, texts);
      check(this.fns.setSequence(this.live(), p.ptr, p.len, it.ptr, it.len), "setSequence");
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

  // ── comment reading ─────────────────────────────────────────────────────

  /** Read the own-line comment block above the node at `path` (lines joined by
   *  `\n`, markers and indentation stripped). Returns `null` when there is no
   *  such block, and `""` for a present-but-empty bare marker. Strict JSON
   *  throws `UnsupportedFormat`. */
  getLeadingComment(path: readonly Segment[]): string | null {
    return this.commentRead(path, this.fns.getLeadingComment, "getLeadingComment");
  }

  /** Read the same-line trailing comment on the value at `path` (marker
   *  stripped). Returns `null` when there is none, `""` for a bare marker. */
  getTrailingComment(path: readonly Segment[]): string | null {
    return this.commentRead(path, this.fns.getTrailingComment, "getTrailingComment");
  }

  private commentRead(path: readonly Segment[], fn: EditFns["getLeadingComment"], op: string): string | null {
    const frame = new Frame();
    try {
      const p = encodePath(frame, path);
      const scratch = frame.alloc(8);
      // `NotFound` means the comment is absent (→ null); any other non-OK status
      // is a real error. An OK with len 0 is a present-but-empty comment.
      const status = fn(this.live(), p.ptr, p.len, scratch, scratch + 4);
      if (status === Status.NotFound) return null;
      check(status, op);
      return readOutSlice(scratch);
    } finally {
      frame.dispose();
    }
  }

  abstract dispose(): void;

  [Symbol.dispose](): void {
    this.dispose();
  }
}
