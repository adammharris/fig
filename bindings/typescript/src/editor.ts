// Comment-preserving, in-place editing of a whole JSON/JSONC/YAML document.
//
// Unlike `serialize`, which re-renders a whole value, `Editor` splices only the
// bytes of the node you change — comments, key order, blank lines, and quoting
// everywhere else stay byte-identical. Inserted values are rendered by fig's
// serializer (see `Editable`) and re-framed at the splice site. Release with
// `dispose` (or a `using` declaration).
import { check, FigError, Format, Status } from "./types.ts";
import { fig, Frame, readOutSlice } from "./ffi.ts";
import { Editable, type EditFns } from "./edit-ops.ts";

const encoder = new TextEncoder();

// Editor edits are rendered as YAML before splicing, matching the Rust binding;
// the Zig editor re-frames the text into the document's actual context.
const EDITOR_FNS: EditFns = {
  replaceVal: fig.fig_editor_replace_val,
  replaceKey: fig.fig_editor_replace_key,
  insertKey: fig.fig_editor_insert_key,
  deleteKey: fig.fig_editor_delete_key,
  appendSeq: fig.fig_editor_append_seq,
  prependSeq: fig.fig_editor_prepend_seq,
  removeSeqItem: fig.fig_editor_remove_seq_item,
  moveKey: fig.fig_editor_move_key,
  reorderKeys: fig.fig_editor_reorder_keys,
  moveItem: fig.fig_editor_move_item,
  reorderItems: fig.fig_editor_reorder_items,
  addLeadingComment: fig.fig_editor_add_leading_comment,
  setTrailingComment: fig.fig_editor_set_trailing_comment,
  deleteLeadingComments: fig.fig_editor_delete_leading_comments,
  deleteTrailingComment: fig.fig_editor_delete_trailing_comment,
};

export class Editor extends Editable {
  private constructor(handle: number) {
    super(handle, EDITOR_FNS, Format.Yaml);
  }

  /** Open an editor over a copy of `input` in `format` (Json/Jsonc/Json5/Yaml).
   *  Empty input is a valid empty document. */
  static open(input: string | Uint8Array, format: Format): Editor {
    const bytes = typeof input === "string" ? encoder.encode(input) : input;
    const frame = new Frame();
    const out = frame.alloc(4);
    try {
      const ptr = frame.bytes(bytes);
      check(fig.fig_editor_create(ptr, bytes.length, format, out), "fig_editor_create");
      const handle = new DataView(fig.memory.buffer).getUint32(out, true);
      if (handle === 0) throw new FigError(Status.InternalError, "fig_editor_create");
      return new Editor(handle);
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
    fig.fig_editor_destroy(this.handle);
  }
}
