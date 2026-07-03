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
(datetime) @string.special
(string_single) @string
(string_double) @string
(multiline_single) @string
(multiline_double) @string
(bare_string) @string
(flow_bare) @string
; balanced-then-trailing bare strings: markdown links, globs, BBCode
; (`[Blog](/x)`, `[a-z]*.md`, `[b]x[/b]`) — see grammar.js and src/scanner.c.
(bracket_led_bare_string) @string
(flow_bracket_led_bare) @string
