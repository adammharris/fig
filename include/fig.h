#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Version
//
// FIG_VERSION_* are the version of THIS header (compile-time). fig_version()
// returns the version of the linked library at runtime, packed identically; a
// host can compare the two to detect a header/library skew. The components are
// also exposed as a string by fig_version_string().
// ============================================================================
#define FIG_VERSION_MAJOR 1
#define FIG_VERSION_MINOR 1
#define FIG_VERSION_PATCH 0
#define FIG_VERSION_NUM (((uint32_t)FIG_VERSION_MAJOR << 16) | \
                         ((uint32_t)FIG_VERSION_MINOR << 8)  | \
                         (uint32_t)FIG_VERSION_PATCH)

// Binary C ABI contract version — a monotonic counter, distinct from the
// marketing FIG_VERSION_* above. It identifies the *shape* of this header's ABI
// (symbols, struct layouts, enum values) the way an ELF SONAME does, and is
// bumped ONLY when that shape changes incompatibly. fig's forward-compat policy
// (size-gated structs, decode-unknown enums, add-never-remove functions) is
// designed so additions are non-breaking, so this stays put across feature
// releases and moves only on a true break. A host that dynamically loads libfig
// can compare fig_abi_version() against the FIG_ABI_VERSION it compiled with: a
// runtime value LOWER than the compile-time one means missing ABI it may rely
// on; a HIGHER value is an incompatible ABI it was not built for. (`zig build
// abi-check` pins this macro to the library; `zig build semver-check` requires
// it to increment whenever the ABI diff against the last release is breaking.)
#define FIG_ABI_VERSION 1

// Linked-library version, packed as (major << 16) | (minor << 8) | patch.
uint32_t fig_version(void);
// Linked-library version as a null-terminated "major.minor.patch" string. Static
// storage owned by the library; do not free.
const char *fig_version_string(void);
// Binary C ABI contract version of the linked library (see FIG_ABI_VERSION).
uint32_t fig_abi_version(void);

// ============================================================================
// Threading and memory ownership
//
// Threading: fig keeps no shared mutable global state, so calls that touch
// DIFFERENT handles (or no handle, e.g. fig_parse, fig_version,
// fig_format_capabilities) may run concurrently on different threads. A SINGLE
// handle — FigDocument, FigEditor, FigEmbed, or FigValue — is NOT internally
// synchronized: never call two functions on the same handle concurrently;
// serialize access externally if you must share one across threads.
//
// Borrowed buffers: functions that return bytes through (out_ptr, out_len) do
// not transfer ownership — the bytes are borrowed from the handle. There are two
// lifetime classes:
//   * Source-borrowing reads (fig_node_string/_number/_extended,
//     fig_keyvalue_*): valid until fig_document_destroy on that document.
//   * Rendered-buffer borrows (fig_document_serialize, fig_value_serialize[_opts],
//     fig_editor_source, fig_embed_render): each handle holds ONE reused output
//     buffer, so the returned pointer is invalidated by the next call that
//     rewrites it — the next serialize/render on that handle, or (for the editor/
//     embed) the next mutation — and by destroying the handle. Copy the bytes
//     out before that point if you need to keep them.
// Buffers from fig_alloc are the only ones the caller owns; release them (only
// them) with fig_free.
//
// fig_alloc/fig_free exist chiefly to bridge an address-space boundary: a caller
// that does not share the library's memory (the WebAssembly build, driven from
// JavaScript) cannot otherwise place input bytes where the API can read them, nor
// hold output past the next call without copying it somewhere it owns. A host in
// the same address space (the usual native C case) can just use its own
// allocator instead — every API input is copied internally and every output is
// borrowed, so nothing here returns a caller-owned buffer on its own.
//
// fig_free takes the length back: it is a SIZED free, so pass the exact `len` you
// requested from fig_alloc (the (out_ptr,out_len) reads give you that length for
// any bytes you copied into a fig_alloc buffer). A null pointer or zero length is
// a no-op on both.
// ============================================================================

// Allocate `len` bytes from the library's allocator, or return NULL on failure
// or a zero-length request. The bytes are uninitialized. Release with fig_free.
uint8_t *fig_alloc(size_t len);
// Release a buffer obtained from fig_alloc. `len` MUST equal the length passed to
// fig_alloc. A null pointer or zero length is a no-op.
void fig_free(uint8_t *ptr, size_t len);

// Forward compatibility: later fig releases may add enumerators to the enums
// below (status codes, node kinds, extended-scalar kinds, formats). Treat any
// value you do not recognize as opaque — for FigStatus, as a generic failure;
// for the kind enums, as "unknown" — rather than asserting the set is closed.
// Language bindings must not decode a returned value into a fixed enum type
// without a fallback, since an out-of-range discriminant is undefined behavior
// in some languages.
typedef enum FigStatus {
    FIG_STATUS_OK = 0,
    FIG_STATUS_INVALID_ARGUMENT = 1,
    FIG_STATUS_PARSE_ERROR = 2,
    FIG_STATUS_OUT_OF_MEMORY = 3,
    FIG_STATUS_UNSUPPORTED_FORMAT = 4,
    FIG_STATUS_NOT_FOUND = 5,
    FIG_STATUS_INTERNAL_ERROR = 255,
} FigStatus;

// Not every function accepts every member. fig_parse accepts all of them; the
// editor (fig_editor_*) supports JSON/JSONC/JSON5/YAML/TOML (others return
// FIG_STATUS_UNSUPPORTED_FORMAT); fig_value_serialize accepts
// JSON/JSONC/JSON5/YAML/TOML/ZON (JSONC = plain-JSON syntax with comments). XML
// is reader-only: accepted by fig_parse, rejected by the editor and serializer.
// To query this matrix programmatically (it also depends on which formats this
// build compiled in), call fig_format_capabilities below.
typedef enum FigFormat {
    FIG_FORMAT_JSON = 1,
    FIG_FORMAT_JSONC = 2,
    FIG_FORMAT_YAML = 3,
    FIG_FORMAT_TOML = 4,
    FIG_FORMAT_ZON = 5,
    FIG_FORMAT_XML = 6,
    FIG_FORMAT_JSON5 = 7,
} FigFormat;

// Capability bits, OR-combined in the return of fig_format_capabilities.
typedef enum FigCapability {
    FIG_CAP_READ      = 1u << 0, // fig_parse accepts this format
    FIG_CAP_EDIT      = 1u << 1, // fig_editor_*/fig_embed_* accept this format
    FIG_CAP_SERIALIZE = 1u << 2, // fig_*_serialize can write this format
} FigCapability;

// Bitmask of FIG_CAP_* describing what this build can do with `format`. Reflects
// both inherent support (XML is reader-only; ZON parses and serializes but is not
// editable) and build-time gating: a format compiled out of this build, or an
// unknown `format` value, reports 0. JSON/JSONC/JSON5 are always fully supported.
uint32_t fig_format_capabilities(int format);

typedef struct FigDocument FigDocument;

// Parse `input[0..input_len]` as `format` into a new document (released with
// fig_document_destroy). Empty input (input_len == 0, with or without a null
// `input`) is handed to the parser and judged per format, NOT rejected up front:
// YAML treats it as a null document and TOML as an empty table (both succeed),
// while JSON/JSON5/ZON/XML require a value/root and return FIG_STATUS_PARSE_ERROR.
// A null `input` with a nonzero `input_len` is FIG_STATUS_INVALID_ARGUMENT.
FigStatus fig_parse(
    const uint8_t *input,
    size_t input_len,
    int format,
    FigDocument **out_doc
);

// Caller-allocated diagnostic for a parse failure. Because the caller owns it
// (on the stack, one per thread), it needs no allocation and has no lifetime
// tied to a handle — which is the whole point: a parse failure happens BEFORE a
// document handle exists, so there is nothing to borrow a message from.
//
// `size` is the version tag, exactly like FigSerializeOptions: set it to
// sizeof(FigError) and the library writes only the fields `size` covers, so the
// struct can gain fields in later releases without breaking an older caller's
// layout. The one frozen dimension is `message` — its capacity cannot grow
// without breaking the ABI — but 256 bytes is ample for a one-line diagnostic,
// and new fields may be appended after it.
//
// On a failed fig_parse_ex the library fills the covered fields; `code` repeats
// the returned FigStatus, `message` is a NUL-terminated human-readable string
// (truncated to fit, `message_len` excludes the NUL). `byte_offset`/`line`/
// `column` locate the failure when known and are 0 ("unknown") otherwise — in
// this release they are always 0 (offset plumbing is a planned follow-up).
typedef struct FigError {
    uint32_t size;          // caller sets sizeof(FigError); see note above
    int      code;          // a FigStatus value (decode unknown as failure)
    size_t   byte_offset;   // offset into input of the failure (0 = unknown)
    uint32_t line;          // 1-based line; 0 = unknown
    uint32_t column;        // 1-based column; 0 = unknown
    size_t   message_len;   // bytes in `message`, excluding the NUL terminator
    char     message[256];  // NUL-terminated, truncated to fit
} FigError;

// As fig_parse, but on failure also fills `out_err` (caller-allocated; set its
// `size` to sizeof(FigError) first) with a diagnostic. `out_err` is nullable:
// passing NULL makes this behave exactly like fig_parse. On FIG_STATUS_OK the
// contents of `out_err` are unspecified — read it only on a nonzero return.
FigStatus fig_parse_ex(
    const uint8_t *input,
    size_t input_len,
    int format,
    FigDocument **out_doc,
    FigError *out_err
);

void fig_document_destroy(FigDocument *doc);

// ============================================================================
// Document traversal (read-only)
//
// Nodes are addressed by id. The sentinel FIG_NODE_NONE means "no such node".
// Pointers returned by the scalar accessors borrow memory owned by the
// document; they remain valid until fig_document_destroy is called on it.
//
// To render a parsed document back out (in its own or another format), see
// fig_document_serialize near the end of this header.
// ============================================================================

typedef uint32_t FigNodeId;
#define FIG_NODE_NONE ((FigNodeId)0xFFFFFFFFu)

typedef enum FigNodeKind {
    FIG_NODE_INVALID  = -1, // null document or out-of-range id
    FIG_NODE_NULL     = 0,
    FIG_NODE_BOOL     = 1,
    FIG_NODE_INT      = 2,
    FIG_NODE_FLOAT    = 3,
    FIG_NODE_STRING   = 4,
    FIG_NODE_SEQUENCE = 5,
    FIG_NODE_MAPPING  = 6,
    FIG_NODE_KEYVALUE = 7,
    FIG_NODE_ALIAS    = 8, // a YAML `*name` alias node (unresolved reference)
} FigNodeKind;

// The node that contains all others. FIG_NODE_NONE for an empty document.
FigNodeId fig_document_root(const FigDocument *doc);

FigNodeKind fig_node_kind(const FigDocument *doc, FigNodeId node);

// Sequence: first element. Mapping: first keyvalue. Otherwise FIG_NODE_NONE.
FigNodeId fig_node_first_child(const FigDocument *doc, FigNodeId node);

// Next element/entry within the containing sequence/mapping, or FIG_NODE_NONE.
FigNodeId fig_node_next_sibling(const FigDocument *doc, FigNodeId node);

// Number of elements (sequence) or entries (mapping); 0 for any other kind.
size_t fig_node_child_count(const FigDocument *doc, FigNodeId node);

// Key/value of a keyvalue node; FIG_NODE_NONE if node is not a keyvalue.
FigNodeId fig_keyvalue_key(const FigDocument *doc, FigNodeId node);
FigNodeId fig_keyvalue_value(const FigDocument *doc, FigNodeId node);

// Scalar accessors. Each returns true and writes its out-param(s) when the
// node has the matching kind; otherwise returns false and leaves them
// untouched. The number accessor yields the raw source text (use
// fig_node_kind to distinguish integer from float).
bool fig_node_bool(const FigDocument *doc, FigNodeId node, bool *out);
bool fig_node_number(const FigDocument *doc, FigNodeId node,
                     const uint8_t **out_ptr, size_t *out_len);
bool fig_node_string(const FigDocument *doc, FigNodeId node,
                     const uint8_t **out_ptr, size_t *out_len);

// Format-specific extended scalar (TOML datetime, ZON enum/char literal).
// Returns true and writes its FigExtKind to *out_kind and source text to
// *out_ptr/*out_len when node is extended; otherwise returns false. Note that
// fig_node_kind still reports such nodes as STRING (datetime / enum literal) or
// INT (char literal), and fig_node_string/fig_node_number still yield the text;
// use this accessor to tell a true string/int apart from an extended scalar.
bool fig_node_extended(const FigDocument *doc, FigNodeId node, int *out_kind,
                       const uint8_t **out_ptr, size_t *out_len);

// ============================================================================
// Editing (write path)
//
// Edits splice only the bytes of the targeted node, preserving comments,
// formatting, and key order everywhere else. A node is addressed by a path: an
// array of segments, each either a mapping key (kind 0) or a sequence index
// (kind 1). Replacement/value bytes are supplied already serialized (e.g. a
// scalar, or multi-line block text indented from column 0); the editor
// re-frames indentation and flow/block context at the splice site.
// ============================================================================

typedef struct FigPathSegment {
    int kind;              // 0 = mapping key, 1 = sequence index
    const uint8_t *key_ptr; // key bytes when kind == 0
    size_t key_len;
    size_t index;          // element index when kind == 1
} FigPathSegment;

// A borrowed UTF-8 string slice: ptr[0..len]. Used for the key list of the
// *_reorder_keys functions.
typedef struct FigStr {
    const uint8_t *ptr;
    size_t len;
} FigStr;

typedef struct FigEditor FigEditor;

// Create an editor over a copy of `input` in the given format. The handle owns
// the source and must be released with fig_editor_destroy.
FigStatus fig_editor_create(const uint8_t *input, size_t input_len,
                            int format, FigEditor **out_editor);
void fig_editor_destroy(FigEditor *editor);

// In-place edits. `path`/`path_len` address the target node (empty path = root
// for inserts/appends). For inserts/appends the path names the container; for
// delete it names the key; for sequence ops it names the sequence.
FigStatus fig_editor_replace_val(FigEditor *editor, const FigPathSegment *path,
                                 size_t path_len, const uint8_t *repl, size_t repl_len);
FigStatus fig_editor_replace_key(FigEditor *editor, const FigPathSegment *path,
                                 size_t path_len, const uint8_t *repl, size_t repl_len);
// Comment editing. The marker (`#` for YAML, `//` for JSONC/JSON5) is supplied
// by the editor; strict JSON has no comment syntax and returns
// FIG_STATUS_UNSUPPORTED_FORMAT. `add_leading` inserts an own-line comment above
// the node at `path` (multi-line `text` => one line each); `set_trailing` sets
// the value's same-line comment, replacing any existing one (single-line `text`,
// else FIG_STATUS_INVALID_ARGUMENT). The delete ops remove the leading block /
// the trailing comment, and are a no-op (FIG_STATUS_OK) when there is none.
FigStatus fig_editor_add_leading_comment(FigEditor *editor, const FigPathSegment *path,
                                         size_t path_len, const uint8_t *text, size_t text_len);
FigStatus fig_editor_set_trailing_comment(FigEditor *editor, const FigPathSegment *path,
                                          size_t path_len, const uint8_t *text, size_t text_len);
FigStatus fig_editor_delete_leading_comments(FigEditor *editor, const FigPathSegment *path,
                                             size_t path_len);
FigStatus fig_editor_delete_trailing_comment(FigEditor *editor, const FigPathSegment *path,
                                             size_t path_len);
// Read a comment back without mutating. `get_leading` returns the own-line block
// above `path` (lines joined by '\n'); `get_trailing` returns the value's
// same-line comment. The marker (and one following space) is stripped. On
// FIG_STATUS_OK the bytes are borrowed from the editor handle (valid until the
// next get on this handle or fig_editor_destroy); `out_len == 0` means a present
// but empty comment (a bare `#`/`//`). FIG_STATUS_NOT_FOUND means no such comment
// exists; strict JSON returns FIG_STATUS_UNSUPPORTED_FORMAT.
FigStatus fig_editor_get_leading_comment(FigEditor *editor, const FigPathSegment *path,
                                         size_t path_len,
                                         const uint8_t **out_ptr, size_t *out_len);
FigStatus fig_editor_get_trailing_comment(FigEditor *editor, const FigPathSegment *path,
                                          size_t path_len,
                                          const uint8_t **out_ptr, size_t *out_len);
FigStatus fig_editor_insert_key(FigEditor *editor, const FigPathSegment *path, size_t path_len,
                                const uint8_t *key, size_t key_len,
                                const uint8_t *val, size_t val_len);
FigStatus fig_editor_delete_key(FigEditor *editor, const FigPathSegment *path, size_t path_len);
FigStatus fig_editor_append_seq(FigEditor *editor, const FigPathSegment *path, size_t path_len,
                                const uint8_t *val, size_t val_len);
FigStatus fig_editor_prepend_seq(FigEditor *editor, const FigPathSegment *path, size_t path_len,
                                 const uint8_t *val, size_t val_len);
FigStatus fig_editor_remove_seq_item(FigEditor *editor, const FigPathSegment *path,
                                     size_t path_len, size_t index);
// Move the mapping entry at `src_path` to immediately before the entry at
// `dest_path` (both must name keys in the same mapping). Reorder the entries of
// the mapping at `path` so `keys` come first in order, the rest following in
// original order; unknown keys are ignored. Owned comments travel with entries.
FigStatus fig_editor_move_key(FigEditor *editor,
                              const FigPathSegment *src_path, size_t src_path_len,
                              const FigPathSegment *dest_path, size_t dest_path_len);
FigStatus fig_editor_reorder_keys(FigEditor *editor, const FigPathSegment *path, size_t path_len,
                                  const FigStr *keys, size_t keys_len);
// Move the sequence item at index `from` to index `to` (array-move semantics).
// Reorder the items of the sequence at `path` so the items at `indices` come
// first in order, the rest following in original order; out-of-range indices
// are ignored. Block items carry owned comments; flow sequences keep separators.
FigStatus fig_editor_move_item(FigEditor *editor, const FigPathSegment *path, size_t path_len,
                               size_t from, size_t to);
FigStatus fig_editor_reorder_items(FigEditor *editor, const FigPathSegment *path, size_t path_len,
                                   const size_t *indices, size_t indices_len);
// Reconcile the sequence at `path` so its items are exactly `items` (each an
// already-serialized scalar value in the document's format), preserving the
// comments on items that survive. Items are matched to the current items by
// value (kind + value, honoring multiplicity), so a kept or reordered item
// keeps its comments; only genuinely new values are inserted and only dropped
// values are deleted. The result order matches `items`. The compound edit is
// atomic. Declines with FIG_STATUS_INVALID_ARGUMENT when it cannot safely diff
// the shape (empty `items`, an empty current list, a non-scalar item on either
// side, or a format whose scalars can't stand alone, e.g. TOML); the caller
// should then replace the whole value instead. A non-sequence target is also
// FIG_STATUS_INVALID_ARGUMENT.
FigStatus fig_editor_set_sequence(FigEditor *editor, const FigPathSegment *path, size_t path_len,
                                  const FigStr *items, size_t items_len);

// Borrow the editor's current source bytes. Valid until the next mutation or
// fig_editor_destroy.
FigStatus fig_editor_source(const FigEditor *editor,
                            const uint8_t **out_ptr, size_t *out_len);

// ============================================================================
// Embedded regions (e.g. markdown frontmatter)
// ============================================================================

typedef struct FigSpan { size_t start; size_t end; } FigSpan;
typedef struct FigRegion {
    FigSpan open_fence;
    FigSpan content;
    FigSpan close_fence;
    // The host body outside the fences (in host-file coordinates): the suffix
    // after the close fence for frontmatter, the prefix before the open fence
    // for endmatter. The read-side twin of `content` (frontmatter vs. body).
    FigSpan body;
} FigRegion;

typedef enum FigEmbedType {
    FIG_EMBED_FRONTMATTER_YAML = 0,
    FIG_EMBED_FRONTMATTER_JSON = 1,
    FIG_EMBED_ENDMATTER_YAML   = 2,
} FigEmbedType;

// Locate an embedded region and report its fence/content/body spans (in
// host-file coordinates) without parsing the content. FIG_STATUS_NOT_FOUND when
// no region of that type exists; a region whose open fence has no matching close
// is FIG_STATUS_PARSE_ERROR.
FigStatus fig_embed_extract(const uint8_t *input, size_t input_len,
                            int embed_type, FigRegion *out_region);

// ============================================================================
// Embed editor (combined): opens the config inside a host file — selected by
// FigEmbedType — and edits it in its inner format (YAML or JSON), leaving the
// fences and surrounding host text byte-identical. fig_embed_open picks the
// inner editor from the archetype; the edit ops mirror fig_editor_*.
// ============================================================================

typedef struct FigEmbed FigEmbed;

FigStatus fig_embed_open(const uint8_t *input, size_t input_len, int embed_type, FigEmbed **out_embed);
void fig_embed_destroy(FigEmbed *embed);

FigStatus fig_embed_replace_val(FigEmbed *embed, const FigPathSegment *path,
                                size_t path_len, const uint8_t *repl, size_t repl_len);
FigStatus fig_embed_replace_key(FigEmbed *embed, const FigPathSegment *path,
                                size_t path_len, const uint8_t *repl, size_t repl_len);
// Comment editing on the embedded config (mirrors fig_editor_*; YAML frontmatter
// uses `#`, JSON frontmatter is strict JSON and rejects comments).
FigStatus fig_embed_add_leading_comment(FigEmbed *embed, const FigPathSegment *path,
                                        size_t path_len, const uint8_t *text, size_t text_len);
FigStatus fig_embed_set_trailing_comment(FigEmbed *embed, const FigPathSegment *path,
                                         size_t path_len, const uint8_t *text, size_t text_len);
FigStatus fig_embed_delete_leading_comments(FigEmbed *embed, const FigPathSegment *path,
                                            size_t path_len);
FigStatus fig_embed_delete_trailing_comment(FigEmbed *embed, const FigPathSegment *path,
                                            size_t path_len);
// Read a comment from the embedded config (mirrors fig_editor_get_*): borrowed
// bytes on OK, FIG_STATUS_NOT_FOUND when absent, len 0 when present-but-empty.
FigStatus fig_embed_get_leading_comment(FigEmbed *embed, const FigPathSegment *path,
                                        size_t path_len,
                                        const uint8_t **out_ptr, size_t *out_len);
FigStatus fig_embed_get_trailing_comment(FigEmbed *embed, const FigPathSegment *path,
                                         size_t path_len,
                                         const uint8_t **out_ptr, size_t *out_len);
FigStatus fig_embed_insert_key(FigEmbed *embed, const FigPathSegment *path, size_t path_len,
                               const uint8_t *key, size_t key_len,
                               const uint8_t *val, size_t val_len);
FigStatus fig_embed_delete_key(FigEmbed *embed, const FigPathSegment *path, size_t path_len);
FigStatus fig_embed_append_seq(FigEmbed *embed, const FigPathSegment *path, size_t path_len,
                               const uint8_t *val, size_t val_len);
FigStatus fig_embed_prepend_seq(FigEmbed *embed, const FigPathSegment *path, size_t path_len,
                                const uint8_t *val, size_t val_len);
FigStatus fig_embed_remove_seq_item(FigEmbed *embed, const FigPathSegment *path,
                                    size_t path_len, size_t index);
FigStatus fig_embed_move_key(FigEmbed *embed,
                             const FigPathSegment *src_path, size_t src_path_len,
                             const FigPathSegment *dest_path, size_t dest_path_len);
FigStatus fig_embed_reorder_keys(FigEmbed *embed, const FigPathSegment *path, size_t path_len,
                                 const FigStr *keys, size_t keys_len);
FigStatus fig_embed_move_item(FigEmbed *embed, const FigPathSegment *path, size_t path_len,
                              size_t from, size_t to);
FigStatus fig_embed_reorder_items(FigEmbed *embed, const FigPathSegment *path, size_t path_len,
                                  const size_t *indices, size_t indices_len);
// Comment-preserving sequence reconcile (see fig_editor_set_sequence).
FigStatus fig_embed_set_sequence(FigEmbed *embed, const FigPathSegment *path, size_t path_len,
                                 const FigStr *items, size_t items_len);

// Replace the host BODY (the prose the config is embedded in) with `body`,
// keeping the fences and the current (possibly edited) content byte-identical.
// The body is the suffix after the close fence (frontmatter) or the prefix
// before the open fence (endmatter); only that side is swapped. `body` is taken
// verbatim (not parsed) and copied; an empty `body` clears it. Composes with the
// value edits — edit keys, replace the body, then render once. Takes effect at
// the next fig_embed_render.
FigStatus fig_embed_replace_body(FigEmbed *embed, const uint8_t *body, size_t body_len);

// Render the full host file with the edited embed. Borrowed bytes, valid
// until the next call or fig_embed_destroy.
FigStatus fig_embed_render(FigEmbed *embed, const uint8_t **out_ptr, size_t *out_len);

// ============================================================================
// Value construction + serialization
//
// The build/serialize counterpart to the read-side traversal API. Construct a
// fresh value tree node-by-node, then render it to any supported format. A
// built value owns no source, so every input byte is copied — caller buffers
// need not outlive the calls.
//
// Construction is bottom-up: build child nodes first, then the container from
// their ids. Each builder call returns the new node's id via *out_id. A node id
// must be placed in exactly one container (a node carries a single sibling
// link). Ids handed to fig_value_seq/fig_value_map must name already-created
// nodes, else FIG_STATUS_INVALID_ARGUMENT.
// ============================================================================

typedef struct FigValue FigValue;

// A key: value entry for fig_value_map; both name nodes created earlier.
typedef struct FigKeyValue {
    FigNodeId key;
    FigNodeId value;
} FigKeyValue;

// Format-specific scalar kinds (TOML datetimes, ZON enum/char literals, JSON5
// non-finite numbers).
typedef enum FigExtKind {
    FIG_EXT_OFFSET_DATETIME = 0,
    FIG_EXT_LOCAL_DATETIME  = 1,
    FIG_EXT_LOCAL_DATE      = 2,
    FIG_EXT_LOCAL_TIME      = 3,
    FIG_EXT_ENUM_LITERAL    = 4,
    FIG_EXT_CHAR_LITERAL    = 5,
    FIG_EXT_NUMBER_SPECIAL  = 6,
} FigExtKind;

FigStatus fig_value_create(FigValue **out_value);
void fig_value_destroy(FigValue *value);

// Scalars. Each writes the new node's id to *out_id.
FigStatus fig_value_null(FigValue *value, FigNodeId *out_id);
FigStatus fig_value_bool(FigValue *value, bool b, FigNodeId *out_id);
FigStatus fig_value_int(FigValue *value, int64_t n, FigNodeId *out_id);
FigStatus fig_value_uint(FigValue *value, uint64_t n, FigNodeId *out_id);
// A numeric scalar from already-formatted text; is_float records its kind. The
// float entry point (the canonical float-text policy is the caller's for now)
// and the escape hatch for integers outside the int64/uint64 range.
FigStatus fig_value_number(FigValue *value, const uint8_t *raw, size_t raw_len,
                           bool is_float, FigNodeId *out_id);
FigStatus fig_value_string(FigValue *value, const uint8_t *ptr, size_t len, FigNodeId *out_id);
FigStatus fig_value_extended(FigValue *value, int kind, const uint8_t *text, size_t text_len,
                             FigNodeId *out_id);

// Containers, built from already-created child ids.
FigStatus fig_value_seq(FigValue *value, const FigNodeId *items, size_t items_len, FigNodeId *out_id);
FigStatus fig_value_map(FigValue *value, const FigKeyValue *entries, size_t entries_len, FigNodeId *out_id);

// Render the subtree rooted at `root` in `format`. Output bytes are borrowed
// from the value and valid until the next fig_value_serialize or
// fig_value_destroy. A value the target cannot represent (e.g. a null in TOML)
// returns FIG_STATUS_UNSUPPORTED_FORMAT.
FigStatus fig_value_serialize(FigValue *value, FigNodeId root, int format,
                              const uint8_t **out_ptr, size_t *out_len);

// Output style for fig_value_serialize_opts. A NULL options pointer selects the
// defaults shown here (identical output to fig_value_serialize). `pretty` is
// honored by JSON, ZON, and TOML (array wrapping); `indent` by JSON and TOML's
// wrapped arrays; `width` by TOML's inline-vs-section layout. YAML renders with
// its own fixed layout.
typedef struct FigSerializeOptions {
  // Set this to sizeof(FigSerializeOptions). It is the struct's version tag:
  // fig may append fields in later releases, and reads a given field only when
  // `size` is large enough to cover it — so a struct laid out by an older
  // caller still works, with the new fields taking their defaults. A `size`
  // too small to cover a field (e.g. 0 from a zero-initialized struct that
  // forgot to set it) makes that field read as its default, NOT garbage.
  uint32_t size;
  // Nonzero (default): multi-line, indented output. Zero: compact single-line.
  // For TOML, zero keeps every array on one line; nonzero lets a wide array wrap.
  uint8_t pretty;
  // Spaces per indent level when `pretty` is nonzero (JSON, and TOML's wrapped
  // arrays). 0 => default 2.
  uint8_t indent;
  // Nonzero: drop comments carried on the value instead of emitting them. Zero
  // (default): preserve them where the target format allows. Appended after
  // `indent`; older callers (smaller `size`) keep the preserve default.
  uint8_t strip_comments;
  // fig_document_serialize only. Nonzero: preserve values the target format
  // cannot represent natively (a null in TOML, a TOML datetime in JSON, ...)
  // through a $fig envelope, and decode any such envelope found in the source.
  // Zero (default): lossy -- an unrepresentable value yields
  // FIG_STATUS_UNSUPPORTED_FORMAT. Ignored by fig_value_serialize_opts. Appended
  // after `strip_comments`; older callers keep the lossy default.
  uint8_t lossless;
  // TOML only: the column budget for its inline-vs-expanded layout. A
  // mapping/array that renders within `width` columns stays inline
  // (k = { ... } / [a, b]); a wider one expands to a [section] / a wrapped array.
  // 0 => default 80. Appended after `lossless`; older callers (smaller `size`)
  // keep the 80-column default. uint16_t, so the struct pads to a 12-byte size.
  uint16_t width;
} FigSerializeOptions;

// As fig_value_serialize, but `options` (NULL => defaults) controls output style
// such as compact vs. pretty-printed JSON.
FigStatus fig_value_serialize_opts(FigValue *value, FigNodeId root, int format,
                                   const FigSerializeOptions *options,
                                   const uint8_t **out_ptr, size_t *out_len);

// ============================================================================
// Document serialization (cross-format conversion)
//
// Render a whole parsed FigDocument to a writable format — the conversion
// primitive. `format` is one of JSON/JSONC/JSON5/YAML/TOML/ZON (the writable set;
// any other, including XML, returns FIG_STATUS_UNSUPPORTED_FORMAT). The source may
// be any parsed format, including reader-only XML (e.g. XML in, JSON out).
//
// When the source is YAML and the target is not, the reference layer (anchors,
// aliases, merge keys, tags) is collapsed automatically (strict tag mode: an
// unknown/custom tag yields FIG_STATUS_UNSUPPORTED_FORMAT). Comments carried on
// the source are preserved where the target format allows.
//
// `options` (NULL => defaults) is the same struct as fig_value_serialize_opts.
// With `lossless` zero (default) the conversion is lossy: a value the target
// cannot represent natively (e.g. a null in TOML) returns
// FIG_STATUS_UNSUPPORTED_FORMAT. With `lossless` nonzero, such values round-trip
// through a $fig envelope and any envelope already in the source is decoded back.
//
// Output bytes are borrowed from `doc` and valid until the next
// fig_document_serialize call on it or fig_document_destroy. Serializes the whole
// document (no subtree selection in this version).
FigStatus fig_document_serialize(FigDocument *doc, int format,
                                 const FigSerializeOptions *options,
                                 const uint8_t **out_ptr, size_t *out_len);

// ==================
// DIAGNOSTICS
// ==================
//
// Report what a serialization would silently lose, without performing it. fig's
// printers degrade or drop data the target format cannot hold (a TOML null
// vanishes, a datetime becomes a string, a block comment becomes a # run, plain
// JSON drops comments) — all still-valid output, so it happens quietly. These
// calls surface each such event so a host can warn, block, or ignore it.

// What kind of loss a warning describes. Mirrors the producing values exactly.
typedef enum FigWarningCode {
  // A carried comment is not emitted at all (no comment syntax, or stripped).
  FIG_WARNING_COMMENT_DROPPED = 0,
  // A block comment is rendered as a run of line comments.
  FIG_WARNING_COMMENT_STYLE_DEGRADED = 1,
  // A node is removed entirely (the target cannot represent it even degraded).
  FIG_WARNING_VALUE_DROPPED = 2,
  // An extended/non-finite value is rendered as a poorer type.
  FIG_WARNING_TYPE_DEGRADED = 3,
} FigWarningCode;

// Why the loss happens — so a host can keep or ignore each class.
typedef enum FigWarningCause {
  // The target format inherently cannot represent it.
  FIG_WARNING_CAUSE_FORMAT_LIMITATION = 0,
  // A caller option forced it (e.g. strip_comments).
  FIG_WARNING_CAUSE_EXPLICIT_OPTION = 1,
} FigWarningCause;

// One lossy event, retrieved by index via fig_*_warning (the diagnose calls
// below report only the count). `code`/`cause` hold FigWarningCode/
// FigWarningCause values (compared as int for forward-compatibility). `path`/
// `note` are NOT null-terminated — use the paired `*_len`. `path` is the
// dotted/[i] location (path_len == 0 means the document root); `note` is the
// degraded-to type for FIG_WARNING_TYPE_DEGRADED (e.g. "string", "number"),
// empty otherwise. Both pointers borrow the producing handle's storage (see the
// borrowing note below).
//
// FigWarning is caller-allocated and `size` is its version tag, the same policy
// FigSerializeOptions/FigError follow: set `size` to sizeof(FigWarning) and the
// library writes only the fields `size` covers, so the struct can gain fields
// without breaking an older caller's layout. (This replaced an earlier
// library-allocated array, which could not grow this way.)
typedef struct FigWarning {
  uint32_t size;        // caller sets sizeof(FigWarning); see note above
  int code;
  int cause;
  const uint8_t *path;
  size_t path_len;
  const uint8_t *note;
  size_t note_len;
} FigWarning;

// Report HOW MANY events serializing the whole parsed document to `format` would
// produce, using the same pipeline fig_document_serialize prints from (YAML
// collapse and, under `options->lossless`, $fig envelopes — so lossless
// suppresses value losses). `options` (NULL => defaults) supplies
// pretty/strip_comments/lossless, which change what is lost. On FIG_STATUS_OK
// writes the event count to *out_count (0 if nothing is lost); retrieve each
// event with fig_document_warning. The computed set is retained on `doc` and
// stays valid (including the `path`/`note` bytes the warnings borrow) until the
// next fig_document_diagnose on it or fig_document_destroy.
FigStatus fig_document_diagnose(FigDocument *doc, int format,
                                const FigSerializeOptions *options,
                                size_t *out_count);

// Copy the event at `index` from the most recent fig_document_diagnose on `doc`
// into caller-allocated `*out` (set out->size to sizeof(FigWarning) first). An
// `index` >= the reported count, or a call with no prior diagnose, returns
// FIG_STATUS_INVALID_ARGUMENT. The `path`/`note` pointers written into `*out`
// borrow `doc` under the lifetime described on fig_document_diagnose.
FigStatus fig_document_warning(FigDocument *doc, size_t index, FigWarning *out);

// Report how many events serializing the built value subtree rooted at `root` to
// `format` would produce. The value builder has no source envelopes, so
// `options->lossless` is ignored here. Retrieve each event with
// fig_value_warning. Retention/borrowing rules match fig_document_diagnose
// (valid until the next fig_value_diagnose on `value` or fig_value_destroy).
FigStatus fig_value_diagnose(FigValue *value, FigNodeId root, int format,
                             const FigSerializeOptions *options,
                             size_t *out_count);

// Copy the event at `index` from the most recent fig_value_diagnose on `value`
// into caller-allocated `*out` (set out->size to sizeof(FigWarning) first).
// Out-of-range `index` or no prior diagnose returns FIG_STATUS_INVALID_ARGUMENT.
FigStatus fig_value_warning(FigValue *value, size_t index, FigWarning *out);

#ifdef __cplusplus
}
#endif
