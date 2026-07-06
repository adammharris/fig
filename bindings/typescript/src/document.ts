// The read path: parse a document, then traverse its node graph.
//
// `Document` owns a parsed handle and must be released with `dispose` (or a
// `using` declaration). Nodes are addressed by numeric id; `null` stands in for
// the C ABI's "no such node" sentinel. `toValue`/`toJS` walk the whole tree in
// one call for the common case.
import {
  check,
  ExtKind,
  FigError,
  Format,
  NodeKind,
  Status,
  WarningCause,
  WarningCode,
  type SerializeOptions,
  type Warning,
} from "./types.ts";
import {
  allocFigError,
  encodeOptions,
  fig,
  FIG_WARNING_SIZE,
  Frame,
  handleRegistry,
  readFigError,
  readFigWarning,
  readOutSlice,
  readU32,
  writeWarningSize,
  type Segment,
} from "./ffi.ts";
import { numberFromRaw, toJS, V, type JsValue, type Value } from "./value.ts";

const NODE_NONE = 0xffffffff;
const encoder = new TextEncoder();

// Frees the handle of a Document that was dropped without dispose(). A backstop
// only — `using`/`dispose()` remains the deterministic path.
const REGISTRY = handleRegistry((handle) => fig.fig_document_destroy(handle));

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
    REGISTRY?.register(this, handle, this);
  }

  /** Parse `input` in `format`. Accepts a string or raw bytes. On a parse
   *  failure the thrown {@link FigError} carries the core's message (and source
   *  location when the core reports one). */
  static parse(input: string | Uint8Array, format: Format): Document {
    const bytes = typeof input === "string" ? encoder.encode(input) : input;
    const frame = new Frame();
    const outDoc = frame.alloc(4);
    const errPtr = allocFigError(frame);
    try {
      const ptr = frame.bytes(bytes);
      const status = fig.fig_parse_ex(ptr, bytes.length, format, outDoc, errPtr);
      if (status !== Status.Ok) {
        // Read the diagnostic AFTER the call (an internal alloc may have grown —
        // and detached — the buffer the views are derived from).
        const e = readFigError(errPtr);
        throw new FigError(status, "fig_parse", {
          message: e.message,
          byteOffset: e.byteOffset,
          line: e.line,
          column: e.column,
        });
      }
      const handle = readU32(outDoc);
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

  /** If `id` is a format-specific extended scalar (TOML datetime, ZON enum/char
   *  literal), its {@link ExtKind} and source text; otherwise `null`. The plain
   *  {@link Document#kind} still reports these as `String`/`Int`, so traversal
   *  checks this first to recover them faithfully. */
  asExtended(id: number): { ext: ExtKind; text: string } | null {
    const frame = new Frame();
    try {
      // out_kind (i32), then the out_ptr/out_len slice pair.
      const scratch = frame.alloc(12);
      if (fig.fig_node_extended(this.live(), id, scratch, scratch + 4, scratch + 8) === 0) return null;
      const ext = new DataView(fig.memory.buffer).getInt32(scratch, true) as ExtKind;
      return { ext, text: readOutSlice(scratch + 4) };
    } finally {
      frame.dispose();
    }
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

  /** Resolve `path` (mapping keys as strings, sequence indices as numbers) to a
   *  node id, or `null` if any segment is missing or lands on the wrong kind. An
   *  empty path returns the {@link Document#root}. */
  nodeAt(path: readonly Segment[]): number | null {
    let current = this.root();
    for (const seg of path) {
      if (current === null) return null;
      if (typeof seg === "number") {
        if (this.kind(current) !== NodeKind.Sequence || seg < 0) return null;
        let i = 0;
        let found: number | null = null;
        for (const child of this.children(current)) {
          if (i++ === seg) {
            found = child;
            break;
          }
        }
        current = found;
      } else {
        if (this.kind(current) !== NodeKind.Mapping) return null;
        let found: number | null = null;
        for (const kv of this.children(current)) {
          const key = this.keyOf(kv);
          if (key !== null && this.asString(key) === seg) {
            found = this.valueOf(kv);
            break;
          }
        }
        current = found;
      }
    }
    return current;
  }

  /** Pluck a single value out of the document by `path`, as a plain JS value, or
   *  `undefined` if the path does not resolve. Convenience over manual
   *  {@link Document#nodeAt} traversal — `doc.get(["server", "port"])`. */
  get(path: readonly Segment[]): JsValue | undefined {
    const node = this.nodeAt(path);
    return node === null ? undefined : toJS(this.nodeToValue(node));
  }

  /** Whether `path` resolves to a node in the document. */
  has(path: readonly Segment[]): boolean {
    return this.nodeAt(path) !== null;
  }

  private nodeToValue(id: number): Value {
    const kind = this.kind(id);
    // A format-specific scalar reports as String/Int at the `kind` ABI; recover
    // it faithfully here (mirrors the Rust binding's `to_value`). Only scalars
    // can be extended, so skip the extra FFI call for containers.
    if (kind === NodeKind.String || kind === NodeKind.Int) {
      const ext = this.asExtended(id);
      if (ext !== null) return V.extended(ext.ext, ext.text);
    }
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

  /** Render the whole document to `format` — the cross-format conversion
   *  primitive (e.g. parse YAML, emit JSON). Unlike `toValue()` + `serialize`,
   *  this preserves source comments where the target allows and collapses YAML's
   *  reference layer when leaving YAML. A value the target cannot represent
   *  throws `UnsupportedFormat` unless `options.lossless` is set. */
  serialize(format: Format, options?: SerializeOptions): string {
    const frame = new Frame();
    try {
      const optsPtr = encodeOptions(frame, options);
      const scratch = frame.alloc(8); // out_ptr + out_len
      check(
        fig.fig_document_serialize(this.live(), format, optsPtr, scratch, scratch + 4),
        "fig_document_serialize",
      );
      return readOutSlice(scratch);
    } finally {
      frame.dispose();
    }
  }

  /** Report what serializing the whole document to `format` would silently lose
   *  (comments/values dropped or degraded), using the same pipeline
   *  {@link Document#serialize} prints from. Returns one {@link Warning} per
   *  lossy event (empty if nothing is lost). */
  diagnose(format: Format, options?: SerializeOptions): Warning[] {
    const frame = new Frame();
    try {
      const optsPtr = encodeOptions(frame, options);
      const countPtr = frame.alloc(4);
      check(fig.fig_document_diagnose(this.live(), format, optsPtr, countPtr), "fig_document_diagnose");
      const count = readU32(countPtr);
      const warnPtr = frame.alloc(FIG_WARNING_SIZE);
      const out: Warning[] = [];
      for (let i = 0; i < count; i++) {
        writeWarningSize(warnPtr);
        check(fig.fig_document_warning(this.live(), i, warnPtr), "fig_document_warning");
        const w = readFigWarning(warnPtr);
        out.push({ code: w.code as WarningCode, cause: w.cause as WarningCause, path: w.path, note: w.note });
      }
      return out;
    } finally {
      frame.dispose();
    }
  }

  /** Release the underlying handle. Idempotent. */
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    REGISTRY?.unregister(this);
    fig.fig_document_destroy(this.handle);
  }

  /** `using doc = Document.parse(...)` releases the handle at scope exit. */
  [Symbol.dispose](): void {
    this.dispose();
  }
}
