// Comment-preserving, in-place editing of a whole JSON/JSONC/JSON5/YAML/TOML
// document.
//
// Unlike `serialize`, which re-renders a whole value, `Editor` splices only the
// bytes of the node you change — comments, key order, blank lines, and quoting
// everywhere else stay byte-identical. Inserted values are rendered by fig's
// serializer (see `Editable`) and re-framed at the splice site. Release with
// `dispose` (or a `using` declaration).
import { check, FigError, Format, Status } from "./types.ts";
import { fig, Frame, handleRegistry, readOutSlice } from "./ffi.ts";
import { Editable, type EditFns } from "./edit-ops.ts";

const encoder = new TextEncoder();

// Frees the handle of an Editor dropped without dispose() (leak backstop only).
const REGISTRY = handleRegistry((handle) => fig.fig_editor_destroy(handle));

// Editor edits are rendered in the document's own format before splicing (a
// `Value` string becomes `"x"` for TOML/JSON but a bare `x` for YAML); the Zig
// editor then re-frames that text into the document's actual context.
//
// Each entry is a thunk rather than a direct `fig.fig_editor_*` reference: a
// direct reference would read the property off the lazy `fig` proxy at module
// load, forcing wasm instantiation the moment the package is imported — which
// throws on a browser main thread. Deferring the read to call time keeps import
// side-effect-free (see ffi.ts `init`).
const EDITOR_FNS: EditFns = {
  replaceVal: (...a) => fig.fig_editor_replace_val(...a),
  replaceKey: (...a) => fig.fig_editor_replace_key(...a),
  set: (...a) => fig.fig_editor_set(...a),
  insertKey: (...a) => fig.fig_editor_insert_key(...a),
  deleteKey: (...a) => fig.fig_editor_delete_key(...a),
  appendSeq: (...a) => fig.fig_editor_append_seq(...a),
  prependSeq: (...a) => fig.fig_editor_prepend_seq(...a),
  removeSeqItem: (...a) => fig.fig_editor_remove_seq_item(...a),
  moveKey: (...a) => fig.fig_editor_move_key(...a),
  reorderKeys: (...a) => fig.fig_editor_reorder_keys(...a),
  moveItem: (...a) => fig.fig_editor_move_item(...a),
  reorderItems: (...a) => fig.fig_editor_reorder_items(...a),
  setSequence: (...a) => fig.fig_editor_set_sequence(...a),
  addLeadingComment: (...a) => fig.fig_editor_add_leading_comment(...a),
  setTrailingComment: (...a) => fig.fig_editor_set_trailing_comment(...a),
  deleteLeadingComments: (...a) => fig.fig_editor_delete_leading_comments(...a),
  deleteTrailingComment: (...a) => fig.fig_editor_delete_trailing_comment(...a),
  getLeadingComment: (...a) => fig.fig_editor_get_leading_comment(...a),
  getTrailingComment: (...a) => fig.fig_editor_get_trailing_comment(...a),
};

export class Editor extends Editable {
  private constructor(handle: number, format: Format) {
    super(handle, EDITOR_FNS, format);
    REGISTRY?.register(this, handle, this);
  }

  /** Open an editor over a copy of `input` in `format`
   *  (Json/Jsonc/Json5/Yaml/Toml). Empty input is a valid empty document. */
  static open(input: string | Uint8Array, format: Format): Editor {
    const bytes = typeof input === "string" ? encoder.encode(input) : input;
    const frame = new Frame();
    const out = frame.alloc(4);
    try {
      const ptr = frame.bytes(bytes);
      check(fig.fig_editor_create(ptr, bytes.length, format, out), "fig_editor_create");
      const handle = new DataView(fig.memory.buffer).getUint32(out, true);
      if (handle === 0) throw new FigError(Status.InternalError, "fig_editor_create");
      return new Editor(handle, format);
    } finally {
      frame.dispose();
    }
  }

  /** The editor's current source text, reflecting all edits so far. */
  source(): string {
    const frame = new Frame();
    try {
      const scratch = frame.alloc(8);
      check(fig.fig_editor_source(this.live(), scratch, scratch + 4), "fig_editor_source");
      return readOutSlice(scratch);
    } finally {
      frame.dispose();
    }
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    REGISTRY?.unregister(this);
    fig.fig_editor_destroy(this.handle);
  }
}
