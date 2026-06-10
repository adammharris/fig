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

#ifdef __cplusplus
}
#endif
