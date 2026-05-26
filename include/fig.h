#pragma once

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

#ifdef __cplusplus
}
#endif
