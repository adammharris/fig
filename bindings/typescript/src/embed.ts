// Comment-preserving editing of a config embedded in a host file — markdown
// YAML/JSON frontmatter or YAML endmatter.
//
// `Embed.open` locates the region, edits its content in the region's inner
// format (YAML or JSON, fixed by the archetype), and `render` re-assembles the
// host file with the fences and surrounding text byte-identical. The edit
// methods are inherited from `Editable`. `extract` is a parse-free locator that
// just reports the fence/content byte spans. Release with `dispose`.
import { check, EmbedType, FigError, Format, Status } from "./types.ts";
import { fig, Frame, handleRegistry, readOutSlice, readU32, writeU32 } from "./ffi.ts";
import { Editable, type EditFns } from "./edit-ops.ts";

const encoder = new TextEncoder();

// Frees the handle of an Embed dropped without dispose() (leak backstop only).
const REGISTRY = handleRegistry((handle) => fig.fig_embed_destroy(handle));

// Thunks, not direct `fig.fig_embed_*` references: a direct reference would read
// off the lazy `fig` proxy at module load and force wasm instantiation on
// import (which throws on a browser main thread). See editor.ts / ffi.ts `init`.
const EMBED_FNS: EditFns = {
  replaceVal: (...a) => fig.fig_embed_replace_val(...a),
  replaceKey: (...a) => fig.fig_embed_replace_key(...a),
  set: (...a) => fig.fig_embed_set(...a),
  insertKey: (...a) => fig.fig_embed_insert_key(...a),
  deleteKey: (...a) => fig.fig_embed_delete_key(...a),
  appendSeq: (...a) => fig.fig_embed_append_seq(...a),
  prependSeq: (...a) => fig.fig_embed_prepend_seq(...a),
  removeSeqItem: (...a) => fig.fig_embed_remove_seq_item(...a),
  moveKey: (...a) => fig.fig_embed_move_key(...a),
  reorderKeys: (...a) => fig.fig_embed_reorder_keys(...a),
  moveItem: (...a) => fig.fig_embed_move_item(...a),
  reorderItems: (...a) => fig.fig_embed_reorder_items(...a),
  setSequence: (...a) => fig.fig_embed_set_sequence(...a),
  addLeadingComment: (...a) => fig.fig_embed_add_leading_comment(...a),
  setTrailingComment: (...a) => fig.fig_embed_set_trailing_comment(...a),
  deleteLeadingComments: (...a) => fig.fig_embed_delete_leading_comments(...a),
  deleteTrailingComment: (...a) => fig.fig_embed_delete_trailing_comment(...a),
  getLeadingComment: (...a) => fig.fig_embed_get_leading_comment(...a),
  getTrailingComment: (...a) => fig.fig_embed_get_trailing_comment(...a),
};

/** A half-open `[start, end)` byte span within the host file. */
export interface Span {
  start: number;
  end: number;
}

/** The fence/content/body byte spans of a located embedded region. `body` is the
 *  host prose outside the fences (suffix for frontmatter, prefix for endmatter). */
export interface Region {
  openFence: Span;
  content: Span;
  closeFence: Span;
  body: Span;
}

/** The inner editing format an embed archetype carries (`---`/endmatter ⇒ YAML,
 *  `;;;` ⇒ JSON, ```fig ⇒ the fig authoring dialect). */
function innerFormat(kind: EmbedType): Format {
  switch (kind) {
    case EmbedType.FrontmatterJson:
      return Format.Json;
    case EmbedType.FrontmatterFig:
      return Format.Fig;
    default:
      return Format.Yaml;
  }
}

export class Embed extends Editable {
  private constructor(handle: number, kind: EmbedType) {
    super(handle, EMBED_FNS, innerFormat(kind));
    REGISTRY?.register(this, handle, this);
  }

  private static openWith(
    host: string | Uint8Array,
    kind: EmbedType,
    fn: (input: number, inputLen: number, embedType: number, out: number) => number,
    name: string,
  ): Embed {
    const bytes = typeof host === "string" ? encoder.encode(host) : host;
    const frame = new Frame();
    const out = frame.alloc(4);
    try {
      const ptr = frame.bytes(bytes);
      check(fn(ptr, bytes.length, kind, out), name);
      const handle = new DataView(fig.memory.buffer).getUint32(out, true);
      if (handle === 0) throw new FigError(Status.InternalError, name);
      return new Embed(handle, kind);
    } finally {
      frame.dispose();
    }
  }

  /** Open the embed of `kind` in `host`. Throws {@link FigError} `NotFound` if
   *  no such region exists. */
  static open(host: string | Uint8Array, kind: EmbedType): Embed {
    return Embed.openWith(host, kind, fig.fig_embed_open, "fig_embed_open");
  }

  /** Open the embed of `kind` in `host`, creating an empty region when none
   *  exists (frontmatter at the top, endmatter at the bottom) instead of throwing
   *  `NotFound` — so a subsequent {@link set}/{@link insertValue} lands the first
   *  entry. An existing region is opened unchanged; a malformed one still throws. */
  static openOrInit(host: string | Uint8Array, kind: EmbedType): Embed {
    return Embed.openWith(host, kind, fig.fig_embed_open_or_init, "fig_embed_open_or_init");
  }

  /** Locate an embedded region and report its fence/content spans without
   *  parsing the content. Throws {@link FigError} `NotFound` if absent. */
  static extract(input: string | Uint8Array, kind: EmbedType): Region {
    const bytes = typeof input === "string" ? encoder.encode(input) : input;
    const frame = new Frame();
    try {
      const ptr = frame.bytes(bytes);
      // FigRegion (wasm32): u32 size + 4 × FigSpan(u32 start, u32 end) = 36 bytes.
      // The caller must set `size` before the call so the size-gated library
      // fills the fields this layout declares.
      const REGION_SIZE = 36;
      const region = frame.alloc(REGION_SIZE);
      writeU32(region, REGION_SIZE);
      check(fig.fig_embed_extract(ptr, bytes.length, kind, region), "fig_embed_extract");
      // Spans start after the 4-byte `size` field: offsets 4, 12, 20, 28.
      const span = (off: number): Span => ({ start: readU32(region + off), end: readU32(region + off + 4) });
      return { openFence: span(4), content: span(12), closeFence: span(20), body: span(28) };
    } finally {
      frame.dispose();
    }
  }

  /** Replace the host body — the prose the config is embedded in — with `body`,
   *  keeping the fences and the current (possibly edited) content byte-identical.
   *  The body is the suffix after the close fence (frontmatter) or the prefix
   *  before the open fence (endmatter); only that side is swapped. `body` is
   *  taken verbatim (not parsed); an empty string clears it. Composes with the
   *  value edits — change keys, replace the body, then `render` once. */
  replaceBody(body: string): void {
    const frame = new Frame();
    try {
      const b = frame.str(body);
      check(fig.fig_embed_replace_body(this.live(), b.ptr, b.len), "replaceBody");
    } finally {
      frame.dispose();
    }
  }

  /** Render the full host file with the edited embed spliced back between the
   *  original fences. */
  render(): string {
    const frame = new Frame();
    try {
      const scratch = frame.alloc(8);
      check(fig.fig_embed_render(this.live(), scratch, scratch + 4), "fig_embed_render");
      return readOutSlice(scratch);
    } finally {
      frame.dispose();
    }
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    REGISTRY?.unregister(this);
    fig.fig_embed_destroy(this.handle);
  }
}

const decoder = new TextDecoder();

/** Split an embedded region of `kind` from its host body without parsing — the
 *  read-only `[content, body]` twin of opening an {@link Embed}. Returns `null`
 *  when `content` has no such region (or its opening fence has no close). The
 *  first item is the text between the fences (no fences); the second is the host
 *  prose outside them. Slicing is done on UTF-8 bytes, so multi-byte content is
 *  handled correctly. */
export function split(content: string, kind: EmbedType): [string, string] | null {
  const bytes = encoder.encode(content);
  let region: Region;
  try {
    region = Embed.extract(bytes, kind);
  } catch {
    return null; // NotFound / unterminated fence
  }
  const inner = decoder.decode(bytes.subarray(region.content.start, region.content.end));
  const body = decoder.decode(bytes.subarray(region.body.start, region.body.end));
  return [inner, body];
}
