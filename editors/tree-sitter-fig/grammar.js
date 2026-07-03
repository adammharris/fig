/**
 * tree-sitter-fig — grammar for the fig authoring dialect
 *
 * SCOPE: this grammar is deliberately SHALLOW and LEXICAL. It exists only to
 * drive syntax highlighting in editors (Zed, Neovim, Helix, …). It does NOT and
 * should NOT try to be a second source of truth for fig's semantics:
 *
 *   - depth is the `>` COUNT (see DESIGN.md) — this grammar treats a run of `>`
 *     as one opaque `markers` token and never reconstructs the nesting tree.
 *     Indentation is ignored (whitespace is `extras`), exactly matching fig's
 *     "indentation is never load-bearing" rule.
 *   - literal-else-string type SNIFFING, baseline re-anchoring, skipped-level
 *     errors, duplicate-key checks, closed-flow rules — NONE of that lives here.
 *     The Zig parser (src/fig/parser.zig) remains authoritative. If this grammar
 *     and the Zig parser ever disagree, the only consequence is a cosmetic
 *     mis-color, never wrong behavior.
 *
 * Known intentional approximations (all cosmetic):
 *   - a `#` with no leading space inside a bare value (e.g. `url = x#frag`) is
 *     treated as a comment, though fig keeps it in the value. This applies
 *     equally to the tail of a `bracket_led_bare_string`/`flow_bracket_led_bare`
 *     (see `src/scanner.c`).
 *   - a trailing comment on a `'''`/`"""` opener line is absorbed into the
 *     string body.
 *
 * Balanced-then-trailing bare strings (DESIGN.md "Committed values"): a value
 * starting with `[`/`{` is normally flow, but when the balanced bracket group
 * is followed by MORE content on the line — a markdown link `[Blog](/x)`, a
 * glob `[a-z]*.md`, BBCode `[b]x[/b]` — it was never flow, it's a bare string.
 * Telling those two shapes apart needs unbounded lookahead (find the matching
 * close, then check what follows), which isn't expressible as a plain token
 * regex — so `bracket_led_bare_string` (block RHS) and `flow_bracket_led_bare`
 * (flow element) are `externals`, resolved by `src/scanner.c` using the same
 * shape as the Zig parser's `classifyBracketCommit`/`classifyFlowBracket`. The
 * scanner only ever *declines* (never partially consumes then fails) — when it
 * declines, the ordinary `[`/`{` token takes over and `flow` parses normally,
 * so this can't regress plain arrays/objects into runaway bare strings.
 */

module.exports = grammar({
  name: 'fig',

  // Indentation and inline spacing carry no meaning for highlighting.
  extras: $ => [/[ \t]/],

  // Keyword-extraction token: lets the literal type keywords (`int`, `string`,
  // …) win cleanly over the `bare_key` identifier when a `: type` annotation
  // is split by category (see `assignment`) — without it, `: int` is ambiguous
  // between the numeric-annotation branch and the open-type-set `bare_key`.
  word: $ => $.bare_key,

  externals: $ => [
    $.bracket_led_bare_string,
    $.flow_bracket_led_bare,
  ],

  rules: {
    document: $ => repeat($._line),

    _line: $ => seq(
      optional($.markers),
      optional(choice(
        $.element,
        $._key_line,
        $.continuation,
        $.comment,
      )),
      /\r?\n/,
    ),

    // A run of `>` (contiguous `>>>` or spaced `> > >`). The COUNT is the real
    // depth in fig, but for coloring we keep the whole run as one token.
    markers: _ => token(/>([ \t]*>)*/),

    // ─── sequence element line: `> *`, `>* 25565`, `>*: int = 1` ───
    element: $ => seq(
      $.star,
      optional(choice(
        $._typed_body,              // `: type = v` / `= v` (annotation-aware)
        field('value', $._value),   // bare scalar element, no `=`
      )),
      optional($.comment),
    ),
    star: _ => '*',

    // `+` continuation line (re-runs the last `[]` append header).
    continuation: _ => '+',

    // ─── key line: header (no `=`) or assignment (`=`) ───
    _key_line: $ => choice($.assignment, $.header),

    assignment: $ => seq(
      field('key', $.keypath),
      $._typed_body,
      optional($.comment),
    ),

    header: $ => seq(
      field('key', $.keypath),
      optional($.comment),
    ),

    // ─── typed value tail (shared by assignment + element) ───
    // The `: type` annotation is a LEXICALLY EXPLICIT signal (not literal-else-
    // string sniffing), so honoring it in the value grammar is still purely
    // lexical: `: string` makes the RHS a verbatim string even when it looks
    // like flow (`x: string = [ 1 + 2 ]` is ONE string, not a sequence), and
    // `: int` / `: float` colour a leading-zero (`09`) or trailing-dot (`1.`)
    // token as a number — where BARE, those correctly stay strings. Other and
    // untyped values keep the normal value grammar. Mirrors the Zig parser's
    // coercion; a disagreement is only a cosmetic mis-colour (see file header).
    _typed_body: $ => choice(
      seq(alias($._string_ann, $.type_annotation), '=', field('value', $._string_rhs)),
      seq(alias($._number_ann, $.type_annotation), '=', field('value', $._number_rhs)),
      seq(optional($.type_annotation), '=', field('value', $._value)),
    ),

    // The plain/other + untyped path. `int`/`float`/`string` are intentionally
    // NOT in `type` — they route to the dedicated branches above (which is why
    // `word` keyword-extraction is needed: `: int` must select the numeric
    // branch, never a `bare_key` custom type). All three annotation forms alias
    // to a `type_annotation` node wrapping a `type` node, so the highlight query
    // (`(type) @type`) and the tree shape are the same across branches.
    type_annotation: $ => seq(':', $.type),
    type: $ => choice(
      'bool', 'enum', 'datetime', 'date', 'time',
      $.bare_key, // open type set
    ),
    _string_ann: $ => seq(':', alias('string', $.type)),
    _number_ann: $ => seq(':', alias(choice('int', 'float'), $.type)),

    // ─── key paths: dotted segments, each optionally indexed ───
    keypath: $ => seq($._keyseg, repeat(seq('.', $._keyseg))),
    _keyseg: $ => seq($.key, repeat($.index)),
    index: $ => seq('[', optional($.integer), ']'),
    key: $ => choice($.bare_key, $.string_single, $.string_double),

    // ─── values (block RHS) ───
    _value: $ => choice(
      $.boolean,
      $.null,
      $.datetime,
      $.number,
      $.string_single,
      $.string_double,
      $.multiline_single,
      $.multiline_double,
      $.flow,
      $.bracket_led_bare_string,
      $.bare_string,
    ),

    // A `: string` RHS is a verbatim string (the Zig parser's total sink): a
    // quoted/multiline form, or a bracket-inclusive bare run to end-of-line.
    _string_rhs: $ => choice(
      $.string_single,
      $.string_double,
      $.multiline_single,
      $.multiline_double,
      $.string_sink,
    ),
    // A `: int`/`: float` RHS: a real number, a coerced lookalike (`09`, `1.`,
    // `inf`), a quoted string (`: int = "09"` stays a string), else a bare
    // string fallback (`: int = hello`, which the Zig parser rejects — a
    // cosmetic mis-colour, never a wrong tree).
    _number_rhs: $ => choice(
      $.number,
      $.coerced_number,
      $.string_single,
      $.string_double,
      $.bare_string,
    ),

    // ─── flow mode: [ … ] arrays and { … } objects (fig-inline OR JSON) ───
    // Interior whitespace MAY include newlines/comments (DESIGN.md "Multi-line
    // flow for long lists") — the frontmatter surface: `key = [` … one element
    // per line … `]`. `_flow_gap` is the only place raw newlines are allowed to
    // be insignificant; everywhere else in this line-oriented grammar a
    // newline ends the `_line`.
    flow: $ => choice($.flow_array, $.flow_object),
    // NOTE: `_flow_gap` slots are placed so no two are ever directly adjacent
    // (always separated by a mandatory `,` or the leading `_fvalue`/`_fpair`) —
    // two adjacent optional repeats of the same content is ambiguous (however
    // many ways to split one whitespace/comment run across the two slots). The
    // "no elements" body is its own branch for the same reason: an empty body
    // between a leading and a trailing optional gap would itself be two
    // directly-adjacent gap slots.
    flow_array: $ => seq(
      '[',
      optional(choice(
        $._flow_gap,
        seq(
          optional($._flow_gap),
          $._fvalue,
          repeat(seq(optional($._flow_gap), ',', optional($._flow_gap), $._fvalue)),
          optional(seq(optional($._flow_gap), ',')),
          optional($._flow_gap),
        ),
      )),
      ']',
    ),
    flow_object: $ => seq(
      '{',
      optional(choice(
        $._flow_gap,
        seq(
          optional($._flow_gap),
          $._fpair,
          repeat(seq(optional($._flow_gap), ',', optional($._flow_gap), $._fpair)),
          optional(seq(optional($._flow_gap), ',')),
          optional($._flow_gap),
        ),
      )),
      '}',
    ),
    _fpair: $ => seq(
      field('key', choice($.bare_key, $.string_single, $.string_double)),
      optional($._flow_gap),
      choice('=', ':'),
      optional($._flow_gap),
      field('value', $._fvalue),
    ),
    _fvalue: $ => choice(
      $.boolean,
      $.null,
      $.datetime,
      $.number,
      $.string_single,
      $.string_double,
      $.flow,
      $.flow_bracket_led_bare,
      $.flow_bare,
    ),

    // Blank lines and `#`-comments between flow elements once a `[`/`{` has
    // opened a (possibly stacked) flow region.
    _flow_gap: $ => repeat1(choice(/[ \t\r\n]+/, $.comment)),

    // ─── terminals ───
    // NOTE on precedence: in Tree-sitter, token PRECEDENCE dominates match
    // LENGTH. So we give every value terminal EQUAL (default) precedence and let
    // the real rules do the work: longest-match wins (so `12 monkeys` beats the
    // `12` number and becomes one bare_string), and equal-length ties break by
    // DEFINITION ORDER (so `42` → number, `true` → boolean, since those tokens
    // are defined before `bare_string`). Do not add prec() here without re-testing
    // the literal-else-string corpus — a higher prec on `number` re-breaks
    // `12 monkeys`.
    comment: _ => token(/#[^\n]*/),

    boolean: _ => token(choice('true', 'false')),
    null: _ => token('null'),

    datetime: _ => token(
      /[0-9]{4}-[0-9]{2}-[0-9]{2}([Tt ][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})?)?/,
    ),

    // Leading-zero ints intentionally excluded → they fall to bare_string (fig rule).
    number: _ => token(choice(
      /0[xX][0-9a-fA-F]+/,
      /(0|[1-9][0-9]*)\.[0-9]+([eE][+-]?[0-9]+)?/,
      /(0|[1-9][0-9]*)[eE][+-]?[0-9]+/,
      /(0|[1-9][0-9]*)/,
    )),

    // `: int`/`: float` coercion lookalike that `number` rejects: a leading-zero
    // int (`09`), a trailing-dot float (`1.`), or `inf`/`nan`. Reachable ONLY in
    // a numeric-typed value slot (`_number_rhs`); coloured @number. Bare, these
    // stay strings — the leading-zero/trailing-dot rules are value-side.
    coerced_number: _ => token(/[+-]?(inf|nan|[0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?/),

    integer: _ => token(/[0-9]+/), // only used inside `[i]` index addressing

    string_single: _ => token(/'[^'\n]*'/),           // raw, single-line
    string_double: _ => token(/"([^"\\\n]|\\.)*"/),   // escaped, single-line

    // Triple-quoted, spanning newlines. Block-comment-style regex (no lazy quant):
    // the inner alternation can never consume the closing triple.
    multiline_single: _ => token(/'''([^']|'[^']|''[^'])*'''/),
    multiline_double: _ => token(/"""([^"]|"[^"]|""[^"])*"""/),

    // Bare string value: runs to end-of-line or a `#`, trailing space trimmed.
    // Start char excludes structural/opener bytes so quoted/flow/typed forms win.
    bare_string: _ => token(
      /[^\s#\[\]{}"':=][^\n#]*[^\s#]|[^\s#\[\]{}"':=]/,
    ),

    // `: string` sink value: verbatim to end-of-line (or ` #`), with the opener
    // bytes (`[ { " ' : =`) allowed as the FIRST char — so `x: string =
    // [ 1 + 2 ]` captures the whole `[ 1 + 2 ]` as one string instead of flow.
    // Only reachable in `_string_rhs`; the quoted forms precede it in that
    // choice (and in definition order), so `: string = "x"` still wins a quote.
    string_sink: _ => token(/[^\s#][^\n#]*[^\s#]|[^\s#]/),

    // Bare flow value: runs to the next , ] } (spaces kept, trimmed).
    flow_bare: _ => token(
      /[^\s,\[\]{}#"'][^,\[\]{}\n#]*[^\s,\[\]{}#]|[^\s,\[\]{}#"']/,
    ),

    // `bracket_led_bare_string` / `flow_bracket_led_bare`: see the file-level
    // comment and `src/scanner.c`. Declared above in `externals`; both are
    // plain (childless) leaf tokens, same shape as `bare_string`/`flow_bare`.

    // Bare key: letters, digits, `_`, `-` (fig's `isBareKeyChar`). A digit is
    // allowed as the FIRST char (`1_sig_fig`, `007zone`) — the leading-zero /
    // number rules are value-side only, never key-side — but `-` is not (a key
    // may not begin with `-`; DESIGN.md "Keys"). In value position `number`
    // still wins for a pure numeral (`x = 42`): `bare_key` is not a `_value`
    // alternative, so the two never compete outside key position.
    bare_key: _ => token(/[A-Za-z0-9_][A-Za-z0-9_\-]*/),
  },
});
