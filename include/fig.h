#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum FigStatus {
    FIG_STATUS_OK = 0,
    FIG_STATUS_INVALID_ARGUMENT = 1,
    FIG_STATUS_PARSE_ERROR = 2,
    FIG_STATUS_OUT_OF_MEMORY = 3,
    FIG_STATUS_UNSUPPORTED_FORMAT = 4,
    FIG_STATUS_NOT_FOUND = 5,
    FIG_STATUS_INTERNAL_ERROR = 255,
} FigStatus;

// Not every function accepts every member. fig_parse accepts all six; the
// editor (fig_editor_*) supports JSON/JSONC/YAML only (others return
// FIG_STATUS_UNSUPPORTED_FORMAT); fig_value_serialize accepts JSON/YAML/TOML/ZON
// and treats JSONC as JSON. XML is reader-only: accepted by fig_parse, rejected
// by the editor and serializer.
typedef enum FigFormat {
    FIG_FORMAT_JSON = 1,
    FIG_FORMAT_JSONC = 2,
    FIG_FORMAT_YAML = 3,
    FIG_FORMAT_TOML = 4,
    FIG_FORMAT_ZON = 5,
    FIG_FORMAT_XML = 6,
} FigFormat;

typedef struct FigDocument FigDocument;

FigStatus fig_parse(
    const uint8_t *input,
    size_t input_len,
    int format,
    FigDocument **out_doc
);

void fig_document_destroy(FigDocument *doc);

// ============================================================================
// Document traversal (read-only)
//
// Nodes are addressed by id. The sentinel FIG_NODE_NONE means "no such node".
// Pointers returned by the scalar accessors borrow memory owned by the
// document; they remain valid until fig_document_destroy is called on it.
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
    int32_t kind;          // 0 = mapping key, 1 = sequence index
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
} FigRegion;

typedef enum FigEmbedType {
    FIG_EMBED_FRONTMATTER_YAML = 0,
    FIG_EMBED_FRONTMATTER_JSON = 1,
    FIG_EMBED_ENDMATTER_YAML   = 2,
} FigEmbedType;

// Locate an embedded region and report its fence/content spans (in host-file
// coordinates) without parsing the content.
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

// Format-specific scalar kinds (TOML datetimes, ZON enum/char literals).
typedef enum FigExtKind {
    FIG_EXT_OFFSET_DATETIME = 0,
    FIG_EXT_LOCAL_DATETIME  = 1,
    FIG_EXT_LOCAL_DATE      = 2,
    FIG_EXT_LOCAL_TIME      = 3,
    FIG_EXT_ENUM_LITERAL    = 4,
    FIG_EXT_CHAR_LITERAL    = 5,
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
// defaults shown here (identical output to fig_value_serialize). Honored by the
// JSON format today; other formats ignore it and use their built-in style.
typedef struct FigSerializeOptions {
  // Nonzero (default): multi-line, indented output. Zero: compact single-line.
  uint8_t pretty;
  // Spaces per indent level when `pretty` is nonzero. 0 is treated as default 2.
  uint8_t indent;
} FigSerializeOptions;

// As fig_value_serialize, but `options` (NULL => defaults) controls output style
// such as compact vs. pretty-printed JSON.
FigStatus fig_value_serialize_opts(FigValue *value, FigNodeId root, int format,
                                   const FigSerializeOptions *options,
                                   const uint8_t **out_ptr, size_t *out_len);

#ifdef __cplusplus
}
#endif
