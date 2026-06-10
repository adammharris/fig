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

typedef enum FigFormat {
    FIG_FORMAT_JSON = 1,
    FIG_FORMAT_JSONC = 2,
    FIG_FORMAT_YAML = 3,
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
// Frontmatter editor (combined): edits the YAML between markdown `---` fences
// and re-assembles the host file, leaving fences and body byte-identical.
// ============================================================================

typedef struct FigFrontmatter FigFrontmatter;

FigStatus fig_fm_open(const uint8_t *markdown, size_t markdown_len, FigFrontmatter **out_fm);
void fig_fm_destroy(FigFrontmatter *fm);

FigStatus fig_fm_replace_val(FigFrontmatter *fm, const FigPathSegment *path,
                             size_t path_len, const uint8_t *repl, size_t repl_len);
FigStatus fig_fm_replace_key(FigFrontmatter *fm, const FigPathSegment *path,
                             size_t path_len, const uint8_t *repl, size_t repl_len);
FigStatus fig_fm_insert_key(FigFrontmatter *fm, const FigPathSegment *path, size_t path_len,
                            const uint8_t *key, size_t key_len,
                            const uint8_t *val, size_t val_len);
FigStatus fig_fm_delete_key(FigFrontmatter *fm, const FigPathSegment *path, size_t path_len);
FigStatus fig_fm_append_seq(FigFrontmatter *fm, const FigPathSegment *path, size_t path_len,
                            const uint8_t *val, size_t val_len);
FigStatus fig_fm_prepend_seq(FigFrontmatter *fm, const FigPathSegment *path, size_t path_len,
                             const uint8_t *val, size_t val_len);
FigStatus fig_fm_remove_seq_item(FigFrontmatter *fm, const FigPathSegment *path,
                                 size_t path_len, size_t index);

// Render the full host file with edited frontmatter. Borrowed bytes, valid
// until the next call or fig_fm_destroy.
FigStatus fig_fm_render(FigFrontmatter *fm, const uint8_t **out_ptr, size_t *out_len);

#ifdef __cplusplus
}
#endif
