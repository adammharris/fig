// External scanner for tree-sitter-fig.
//
// Resolves the one piece of the grammar that isn't expressible as a plain
// token regex: "balanced-then-trailing" bare strings (DESIGN.md "Committed
// values") — a value starting with `[`/`{` where the balanced bracket group
// is followed by MORE content on the line, e.g. a markdown link
// `[Blog](/x)`, a glob `[a-z]*.md`, BBCode `[b]x[/b]`. Telling that apart
// from genuine flow (`[80, 443]`) needs unbounded lookahead — find the
// matching close, then look at what follows — which mirrors the Zig parser's
// `tok.classifyBracketCommit` (block RHS) / `tok.classifyFlowBracket` (flow
// element) in src/fig/tokenizer.zig.
//
// Both external tokens below are DECLINE-only: if the input doesn't have the
// balanced-then-trailing shape, `scan` returns false having committed no
// token, and tree-sitter falls back to the ordinary `[`/`{` token so `flow`
// parses normally. This is what keeps `tags = [a, b, c]` parsing as a real
// flow_array instead of one giant bare string.

#include "tree_sitter/parser.h"

#include <stdbool.h>
#include <stdint.h>

enum TokenType {
  BRACKET_LED_BARE_STRING,
  FLOW_BRACKET_LED_BARE,
};

void *tree_sitter_fig_external_scanner_create(void) { return NULL; }
void tree_sitter_fig_external_scanner_destroy(void *payload) { (void)payload; }
unsigned tree_sitter_fig_external_scanner_serialize(void *payload, char *buffer) {
  (void)payload;
  (void)buffer;
  return 0; // stateless: nothing to carry across scanner invocations
}
void tree_sitter_fig_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
  (void)payload;
  (void)buffer;
  (void)length;
}

static inline bool is_hspace(int32_t c) {
  return c == ' ' || c == '\t' || c == '\r';
}

// Skip a single-line quoted span starting at the opening quote (the current
// lookahead). Mirrors tok.zig's `skipQuotedSpan`: `'` is raw (no escapes),
// `"` honors backslash escapes. Leaves the lexer just past the closing quote
// on success. Returns false (lexer position thereafter unspecified — caller
// always bails to `return false` itself) if it doesn't close before a
// newline/EOF.
static bool skip_quoted(TSLexer *lexer) {
  int32_t quote = lexer->lookahead;
  lexer->advance(lexer, false); // opening quote
  while (true) {
    if (lexer->eof(lexer) || lexer->lookahead == '\n') return false;
    int32_t c = lexer->lookahead;
    if (quote == '"' && c == '\\') {
      lexer->advance(lexer, false);
      if (lexer->eof(lexer) || lexer->lookahead == '\n') return false;
      lexer->advance(lexer, false);
      continue;
    }
    lexer->advance(lexer, false);
    if (c == quote) return true;
  }
}

// Scan a balanced `[`/`{` … `]`/`}` group starting at the current lookahead
// (must be `[` or `{`). Generic like the Zig scanner: any close decrements
// depth regardless of which open started it. Single-line only — a raw
// newline before the close fails (multi-line flow is the grammar's own
// `_flow_gap`'s job; this scanner only recognizes the single-line
// balanced-then-trailing *bare-string* shape). On success the lexer is
// positioned just past the matching close.
static bool scan_bracket_run(TSLexer *lexer) {
  uint32_t depth = 0;
  while (true) {
    if (lexer->eof(lexer) || lexer->lookahead == '\n') return false;
    int32_t c = lexer->lookahead;
    if (c == '\'' || c == '"') {
      if (!skip_quoted(lexer)) return false;
      continue;
    }
    if (c == '[' || c == '{') {
      depth++;
      lexer->advance(lexer, false);
      continue;
    }
    if (c == ']' || c == '}') {
      depth--;
      lexer->advance(lexer, false);
      if (depth == 0) return true;
      continue;
    }
    lexer->advance(lexer, false);
  }
}

// Consume a tail run up to (not including) any byte in `stop` (plus `\n`/EOF,
// always implicit stops), trimming trailing horizontal whitespace by only
// advancing `mark_end` on non-whitespace bytes. Returns false (no token) if
// the tail turns out to be empty. Every byte before the first stop byte has
// already been confirmed non-whitespace by the caller, so the first
// iteration always commits at least one byte.
//
// `#` in `stop` is special-cased: it only stops the run when preceded by
// whitespace *within this run* — a `#` glued to non-whitespace (a URL
// fragment like `v1#stable`) stays literal, mirroring `scanBareRestOfLine`/
// `scanFlowBareValue`/`scanFlowBareBracket`'s `prev_space` tracking. Every
// other byte in `stop` (`,`/`]`/`}`) always stops unconditionally. `prev_space`
// seeds that tracking with whatever whitespace the caller already consumed
// just before this call, so a `#` glued to the run's own start (e.g.
// `[80]#glued`) is still recognized as glued.
static bool scan_tail(TSLexer *lexer, const char *stop, bool prev_space) {
  bool any = false;
  while (!lexer->eof(lexer) && lexer->lookahead != '\n') {
    int32_t c = lexer->lookahead;
    bool stop_here = false;
    for (const char *s = stop; *s; s++) {
      unsigned char sc = (unsigned char)*s;
      if (sc == '#') {
        if (c == '#' && prev_space) { stop_here = true; break; }
      } else if (c == sc) {
        stop_here = true;
        break;
      }
    }
    if (stop_here) break;
    bool ws = is_hspace(c);
    lexer->advance(lexer, false);
    if (!ws) {
      any = true;
      lexer->mark_end(lexer);
    }
    prev_space = (c == ' ' || c == '\t'); // matches prev_space's own `\r`-excluding check
  }
  return any;
}

static bool scan(TSLexer *lexer, const bool *valid_symbols) {
  bool want_block = valid_symbols[BRACKET_LED_BARE_STRING];
  bool want_flow = valid_symbols[FLOW_BRACKET_LED_BARE];
  if (!want_block && !want_flow) return false;

  // Unlike the internal DFA, external tokens are tried BEFORE `extras` are
  // skipped — do that ourselves (space/tab only, matching the grammar's own
  // `extras`; a leading newline is never ours to consume). `advance(..,
  // true)` marks these bytes as skipped/extra so declining afterward still
  // leaves them available to the normal extras handling.
  while (!lexer->eof(lexer) && (lexer->lookahead == ' ' || lexer->lookahead == '\t')) {
    lexer->advance(lexer, true);
  }

  if (lexer->lookahead != '[' && lexer->lookahead != '{') return false;

  // Unclosed on this line → hand it to the `flow` grammar (multi-line flow
  // or a hard "unclosed" error), never a bare string.
  if (!scan_bracket_run(lexer)) return false;

  // Horizontal whitespace after the close — track whether we saw any, for
  // the `#`-glued-vs-spaced distinction below (DESIGN.md "Committed values").
  bool saw_space = false;
  while (is_hspace(lexer->lookahead)) {
    saw_space = true;
    lexer->advance(lexer, false);
  }

  if (want_block) {
    // Nothing (or only a comment) trailing the close → genuine flow.
    if (lexer->eof(lexer) || lexer->lookahead == '\n') return false;
    if (saw_space && lexer->lookahead == '#') return false;

    // Balanced-then-trailing: the rest of the line (to a whitespace-preceded
    // `#`, or EOL) is the tail, same shape/trim as `bare_string` itself.
    if (!scan_tail(lexer, "#", saw_space)) return false;
    lexer->result_symbol = BRACKET_LED_BARE_STRING;
    return true;
  }

  // Flow-element position: `,` `]` `}` `#` (or newline/EOF) terminate the
  // element — DESIGN.md `classifyFlowBracket`/`flowRestIsTerminator`.
  if (lexer->eof(lexer) || lexer->lookahead == '\n') return false;
  switch (lexer->lookahead) {
    case ',':
    case ']':
    case '}':
    case '#':
      return false; // genuine nested flow element, e.g. `[1, 2]` inside a list
    default:
      break;
  }

  if (!scan_tail(lexer, ",]}#", false)) return false;
  lexer->result_symbol = FLOW_BRACKET_LED_BARE;
  return true;
}

bool tree_sitter_fig_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
  (void)payload;
  return scan(lexer, valid_symbols);
}
