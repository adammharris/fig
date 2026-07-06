; tree-sitter-fig highlight query (Zed capture-name conventions)
; Kept identical to editors/tree-sitter-fig/queries/highlights.scm.

; ── comments ──
(comment) @comment

; ── structure markers ──
(markers) @punctuation.delimiter
(star) @punctuation.list_marker
(continuation) @punctuation.special

; ── keys ──
(assignment key: (keypath (key) @property))
(header key: (keypath (key) @property))
(flow_object key: (bare_key) @property)
(flow_object key: (string_single) @property)
(flow_object key: (string_double) @property)

; ── type annotations: `: int`, `: enum`, … ──
(type) @type

; ── operators & path/index punctuation ──
"=" @operator
":" @operator
"." @punctuation.delimiter
["[" "]"] @punctuation.bracket
["{" "}"] @punctuation.bracket
"," @punctuation.delimiter

; ── scalars ──
(boolean) @boolean
(null) @constant
(number) @number
(integer) @number
; a `: int`/`: float` coercion lookalike (`09`, `1.`, `inf`) — see grammar.js
(coerced_number) @number
(datetime) @string.special
(string_single) @string
(string_double) @string
(multiline_single) @string
(multiline_double) @string
(bare_string) @string
(flow_bare) @string
; a `: string` sink RHS: verbatim text, brackets included (`: string = [ 1 + 2 ]`)
(string_sink) @string
; balanced-then-trailing bare strings: markdown links, globs, BBCode
; (`[Blog](/x)`, `[a-z]*.md`, `[b]x[/b]`) — see grammar.js and src/scanner.c.
(bracket_led_bare_string) @string
(flow_bracket_led_bare) @string

; a quoted RHS under a non-`string`/non-`int`/non-`float` annotation that
; doesn't accept a quoted spelling (`bool`/`datetime`/`date`/`time`) — this is
; a hard `FigTypeMismatch` in the real parser (spec.md § 5.3), not a valid
; string; see grammar.js `_number_rhs`/`_other_rhs`.
(invalid_annotated_string) @error
