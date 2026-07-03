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
 * Known intentional approximations (all cosmetic; fixable later with an external
 * scanner if ever worth it):
 *   - a `#` with no leading space inside a bare value (e.g. `url = x#frag`) is
 *     treated as a comment, though fig keeps it in the value.
 *   - a bare string value that STARTS with `[` or `{` (markdown link, glob) is
 *     not recognized (those bytes always open flow here).
 *   - a trailing comment on a `'''`/`"""` opener line is absorbed into the
 *     string body.
 */

module.exports = grammar({
  name: 'fig',

  // Indentation and inline spacing carry no meaning for highlighting.
  extras: $ => [/[ \t]/],

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
      optional($._elem_tail),
      optional($.comment),
    ),
    star: _ => '*',
    _elem_tail: $ => choice(
      seq(optional($.type_annotation), '=', field('value', $._value)),
      field('value', $._value),
    ),

    // `+` continuation line (re-runs the last `[]` append header).
    continuation: _ => '+',

    // ─── key line: header (no `=`) or assignment (`=`) ───
    _key_line: $ => choice($.assignment, $.header),

    assignment: $ => seq(
      field('key', $.keypath),
      optional($.type_annotation),
      '=',
      field('value', $._value),
      optional($.comment),
    ),

    header: $ => seq(
      field('key', $.keypath),
      optional($.comment),
    ),

    type_annotation: $ => seq(':', $.type),
    type: $ => choice(
      'int', 'float', 'bool', 'string', 'enum',
      'datetime', 'date', 'time',
      $.bare_key, // open type set
    ),

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
      $.bare_string,
    ),

    // ─── flow mode: [ … ] arrays and { … } objects (fig-inline OR JSON) ───
    flow: $ => choice($.flow_array, $.flow_object),
    flow_array: $ => seq(
      '[',
      optional(seq($._fvalue, repeat(seq(',', $._fvalue)), optional(','))),
      ']',
    ),
    flow_object: $ => seq(
      '{',
      optional(seq($._fpair, repeat(seq(',', $._fpair)), optional(','))),
      '}',
    ),
    _fpair: $ => seq(
      field('key', choice($.bare_key, $.string_single, $.string_double)),
      choice('=', ':'),
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
      $.flow_bare,
    ),

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

    // Bare flow value: runs to the next , ] } (spaces kept, trimmed).
    flow_bare: _ => token(
      /[^\s,\[\]{}#"'][^,\[\]{}\n#]*[^\s,\[\]{}#]|[^\s,\[\]{}#"']/,
    ),

    // Bare key: identifier-ish; anything needing . : = [ ] or space must be quoted.
    bare_key: _ => token(/[A-Za-z_][A-Za-z0-9_\-]*/),
  },
});
