// The read path: parse a document, then traverse its node graph.
//
// `Document` owns a parsed handle and must be released with `dispose` (or a
// `using` declaration). Nodes are addressed by numeric id; `null` stands in for
// the C ABI's "no such node" sentinel. `toValue`/`toJS` walk the whole tree in
// one call for the common case.
import { check, FigError, Format, NodeKind, Status } from "./types.ts";
import { fig, Frame, readOutSlice } from "./ffi.ts";
import { numberFromRaw, toJS, V, type JsValue, type Value } from "./value.ts";

const NODE_NONE = 0xffffffff;
const encoder = new TextEncoder();

// fig node ids are `u32`, but a wasm `i32` return arrives in JS sign-extended,
// so `0xFFFFFFFF` (the "no node" sentinel) shows up as -1. Re-widen to unsigned
// before comparing against NODE_NONE or handing the id back to the ABI.
const u32 = (n: number): number => n >>> 0;

/** A parsed, read-only document. Release with {@link Document#dispose}. */
export class Document {
  /** @internal */ private handle: number;
  private disposed = false;

  private constructor(handle: number) {
    this.handle = handle;
  }

  /** Parse `input` in `format`. Accepts a string or raw bytes. */
  static parse(input: string | Uint8Array, format: Format): Document {
    const bytes = typeof input === "string" ? encoder.encode(input) : input;
    const frame = new Frame();
    const outDoc = frame.alloc(4);
    try {
      const ptr = frame.bytes(bytes);
      check(fig.fig_parse(ptr, bytes.length, format, outDoc), "fig_parse");
      const handle = new DataView(fig.memory.buffer).getUint32(outDoc, true);
      if (handle === 0) throw new FigError(Status.InternalError, "fig_parse");
      return new Document(handle);
    } finally {
      frame.dispose();
    }
  }

  private live(): number {
    if (this.disposed) throw new Error("Document already disposed");
    return this.handle;
  }

  /** The root node id, or `null` for an empty document. */
  root(): number | null {
    const id = u32(fig.fig_document_root(this.live()));
    return id === NODE_NONE ? null : id;
  }

  /** The kind of node `id`. */
  kind(id: number): NodeKind {
    return fig.fig_node_kind(this.live(), id) as NodeKind;
  }

  /** First element/entry of a sequence/mapping, else `null`. */
  firstChild(id: number): number | null {
    const c = u32(fig.fig_node_first_child(this.live(), id));
    return c === NODE_NONE ? null : c;
  }

  /** Next sibling within the containing container, else `null`. */
  nextSibling(id: number): number | null {
    const s = u32(fig.fig_node_next_sibling(this.live(), id));
    return s === NODE_NONE ? null : s;
  }

  /** Number of elements/entries; 0 for any non-container node. */
  childCount(id: number): number {
    return u32(fig.fig_node_child_count(this.live(), id));
  }

  /** The key node of a keyvalue, else `null`. */
  keyOf(id: number): number | null {
    const k = u32(fig.fig_keyvalue_key(this.live(), id));
    return k === NODE_NONE ? null : k;
  }

  /** The value node of a keyvalue, else `null`. */
  valueOf(id: number): number | null {
    const v = u32(fig.fig_keyvalue_value(this.live(), id));
    return v === NODE_NONE ? null : v;
  }

  /** The boolean at `id`, or `null` if it is not a bool node. */
  asBool(id: number): boolean | null {
    const frame = new Frame();
    try {
      const out = frame.alloc(1);
      if (fig.fig_node_bool(this.live(), id, out) === 0) return null;
      return new DataView(fig.memory.buffer).getUint8(out) !== 0;
    } finally {
      frame.dispose();
    }
  }

  /** The raw source text of a number (or char-literal) node, or `null`. Use
   *  {@link Document#kind} to tell integer from float. */
  asNumberRaw(id: number): string | null {
    return this.readSlice((scratch) => fig.fig_node_number(this.live(), id, scratch, scratch + 4));
  }

  /** The string at `id` (also datetimes / enum literals as text), or `null`. */
  asString(id: number): string | null {
    return this.readSlice((scratch) => fig.fig_node_string(this.live(), id, scratch, scratch + 4));
  }

  private readSlice(call: (scratch: number) => number): string | null {
    const frame = new Frame();
    try {
      const scratch = frame.alloc(8);
      if (call(scratch) === 0) return null;
      return readOutSlice(scratch);
    } finally {
      frame.dispose();
    }
  }

  /** Iterate the child node ids of a sequence/mapping in order. */
  *children(id: number): Generator<number> {
    let next = this.firstChild(id);
    while (next !== null) {
      yield next;
      next = this.nextSibling(next);
    }
  }

  /** Read the whole document into a {@link Value} tree. An empty document is
   *  `null`. Mirrors the Rust binding's `to_value`. */
  toValue(): Value {
    const root = this.root();
    return root === null ? V.null() : this.nodeToValue(root);
  }

  /** Read the whole document into plain JavaScript values. */
  toJS(): JsValue {
    return toJS(this.toValue());
  }

  private nodeToValue(id: number): Value {
    const kind = this.kind(id);
    switch (kind) {
      case NodeKind.Null:
        return V.null();
      case NodeKind.Bool: {
        const b = this.asBool(id);
        if (b === null) throw new FigError(Status.InternalError, "fig_node_bool");
        return V.bool(b);
      }
      case NodeKind.Int:
      case NodeKind.Float: {
        const raw = this.asNumberRaw(id);
        if (raw === null) throw new FigError(Status.InternalError, "fig_node_number");
        return numberFromRaw(raw, kind === NodeKind.Float);
      }
      case NodeKind.String: {
        const s = this.asString(id);
        if (s === null) throw new FigError(Status.InternalError, "fig_node_string");
        return V.string(s);
      }
      case NodeKind.Sequence:
        return V.seq(Array.from(this.children(id), (child) => this.nodeToValue(child)));
      case NodeKind.Mapping: {
        const entries: Array<[Value, Value]> = [];
        for (const kv of this.children(id)) {
          const key = this.keyOf(kv);
          if (key === null) throw new FigError(Status.InternalError, "fig_keyvalue_key");
          const valueId = this.valueOf(kv);
          entries.push([this.nodeToValue(key), valueId === null ? V.null() : this.nodeToValue(valueId)]);
        }
        return V.map(entries);
      }
      default:
        // A bare keyvalue, an invalid id, or an unresolved alias is not a value.
        throw new FigError(Status.InternalError, `node kind ${NodeKind[kind] ?? kind}`);
    }
  }

  /** Release the underlying handle. Idempotent. */
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    fig.fig_document_destroy(this.handle);
  }

  /** `using doc = Document.parse(...)` releases the handle at scope exit. */
  [Symbol.dispose](): void {
    this.dispose();
  }
}
