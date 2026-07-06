# fig authoring dialect — specification

**Version: 1.0**

This document is normative: where the implementation and this document disagree, that is an implementation bug. The reference implementation is the reader at `src/languages/fig/parser.zig` (with `tokenizer.zig`) and the formatter at `src/languages/fig/printer.zig`.

Key words MUST, MUST NOT, SHOULD, and MAY are to be interpreted as in RFC 2119.

---

## 1. Overview and goals

fig is a line-oriented configuration language designed to be typed on a bare keyboard and edited safely without tooling. Nesting depth is carried by a counted marker (`>`), never by indentation, so reformatting a document never changes its meaning. The dialect is strict: likely mistakes are errors or warnings, not silent coercions. A fig document parses into the same abstract syntax tree (AST) shared by every other format in the fig toolchain; the separate *canonical form* — not this dialect — is the lossless, single-spelling oracle for that tree.

## 2. Document model

A document is a sequence of lines that parses to a tree of:

- **mappings** — ordered key/value pairs with string keys,
- **sequences** — ordered elements,
- **scalars** — `null`, booleans, strings, numbers, and *extended* scalars (datetimes, enum literals, char literals, non-finite floats).

The root of a document is a mapping or a sequence, never a scalar. A document with no content (empty, or containing only blank lines and comments) is an empty root mapping. There is no authoring spelling for a scalar-root document; printing such an AST as `.fig`/`.figl` is a hard error (`FigUnrepresentableRoot`) rather than emitting non-conforming output — use the canonical form or another output format instead.

Numbers are stored and compared by their **source lexeme**, not by numeric conversion: `1.10` is preserved as `1.10`, `1e2` is distinct from `100.0`, and `0xFF` is never normalized to `255`. A conforming implementation MUST NOT define value identity by numeric conversion; it MAY offer numeric coercion as an explicitly lossy accessor. Two numbers are equal iff their lexemes match byte-for-byte and their integer/float kinds agree.

Comments are preserved in an AST side-table with three anchors: **leading** (before a node), **trailing** (same line, after a node), and **dangling** (at the end of a container's body).

## 3. Lexical rules

### 3.1 Encoding and line structure

A fig document is UTF-8-encoded text. A line terminator is LF (`\n`) or CRLF (`\r\n`): a CR immediately preceding an LF, or ending the input, is trivia, so a CRLF document parses identically to its LF counterpart — including inside multi-line strings, whose captured content always carries LF line breaks (§ 4.6). A CR anywhere else is ordinary content bytes where content is captured (bare values trim it at their edges like any other whitespace). A leading UTF-8 BOM is permitted and silently ignored; input that is not valid UTF-8 is a hard error (`FigInvalidUtf8`).

Each physical line is one of:

- a **blank line** — whitespace only (ignored; it does not close containers, reset baselines, or break `+` chains),
- a **comment line** — an optional marker prefix, then `#` to end of line,
- a **content line** — an optional marker prefix, then a header, assignment, element, or continuation body.

A line containing only depth markers is equivalent to a blank line. Trailing whitespace after the markers does not change this (`>>` followed by spaces or tabs and the line end is still blank); a marker run followed by `#` is a comment line at that depth, per the classification above.

### 3.2 Depth markers

Nesting depth is the **count of leading `>` markers** on a line. Indentation never carries meaning.

- A marker run MAY be contiguous (`>>>`) or spaced (`> > >`); both denote the same depth. Whitespace MAY appear between markers within a run.
- A run MUST be separated from the body that follows it by at least one space or tab (`> key`, not `>key`). Violation: `FigBadMarkerSeparator`.
- Optional leading indentation before the run is cosmetic (see § 3.3).
- Depth MUST NOT grow by more than one level from line to line; a deeper jump is `FigSkippedLevel`. Depth MAY shrink by any amount (closing several containers at once).
- A marked line with no open parent above it is `FigRootMarker` ("root keys carry zero markers").
- Depth counts are **relative to the active baseline** (see § 7.2), not absolute document depth.

The **element marker `*`** sits in key position, ending the run: `> *` (spaced, the canonical form) or `>*` (glued) are equivalent; at root an element is a bare `*`. `*` is a role marker, not a counted depth mark — depth is the `>` count alone. A `*` glued to its value (`*v`, `>*v`) is `FigBadMarkerSeparator`. A typed element's `:` binds to the `*` with no separator required — `*: int = 1` (the canonical spelling) and the spaced `* : int = 1` are equivalent.

Foreign-syntax guardrails at line dispatch (all hard errors that name the fig form):

- any `-` element spelling (`- v`, `>-`, `> -`) → `FigForeignSyntaxDash`;
- `[section]` / `[[x]]` at the start of a line's body → `FigForeignSyntaxBracket`;
- `key: value` (a `:` with no following `=`) → `FigForeignSyntaxColon`.

### 3.3 Whitespace and indentation

Whitespace is insignificant except in three places: the marker↔body separator (§ 3.2), the whitespace that precedes an inline `#` (§ 3.4), and the interior of quoted/multi-line strings.

Indentation, when present, is checked against the convention `2 × depth` spaces. A line whose indentation is present and disagrees with its marker count produces the `indent_marker_mismatch` warning; any tab in the indentation produces it regardless of width. Unindented lines are always clean. Comment lines participate in this check (their depth is load-bearing for attachment).

### 3.4 Comments

`#` opens a comment **only at the start of a line's body or after whitespace**; a `#` glued to non-whitespace is literal value text (URL fragments survive: `https://x/v1#frag` is one value). A comment runs to end of line. There is no block-comment syntax; a run of consecutive `#` lines is one logical comment block, and printers downgrade any stored block-style comment to such a run.

Attachment rules:

- a comment-only line attaches as a **leading** comment, at its own marker depth, to the next structural sibling;
- a `# …` after a value on the same line is that value's **trailing** comment;
- when containers close over buffered comment lines, a comment at or deeper than the closing container's child depth becomes that container's **dangling** run; a shallower one stays pending as a leading comment on the next sibling;
- comments buffered at end of input attach as the root's dangling run.

Comments inside flow collections (§ 6.3) are accepted and **discarded** except for the opener-line comment rule (§ 6.3).

## 4. Scalars

### 4.1 Bare values and the literal-else-string rule

A bare (unquoted, undelimited) right-hand side is first trimmed of leading and trailing whitespace, keeping interior spaces verbatim, then classified by sniffing the **whole token**:

1. `null` → null; `true` / `false` → boolean (exact lowercase only);
2. else, if the token is a valid number (§ 4.3) → number;
3. else, if the token is a valid datetime (§ 4.4) → datetime;
4. **else it is a plain string**, verbatim.

Consequences (all normative):

```
answer = 42                # integer
enabled = true             # boolean
movie = 12 monkeys         # string — not a clean number
semver = 1.2.3             # string
norway = Yes               # string — literals are lowercase-only (warned)
zip = 007                  # string — leading zero is not a number (warned)
title = My Application     # string, spaces kept
```

Enum atoms and non-finite floats are never sniffed: bare `inf`, `nan`, and `@x` are plain strings. They are authored only through explicit typing (§ 5.3).

Edge whitespace of a bare value is trimmed; quote the value to preserve edges (`'  padded  '`). A bare value ends at the first whitespace-preceded `#` (§ 3.4).

### 4.2 Booleans and null

Exactly `true`, `false`, and `null`, lowercase. `Yes`, `ON`, `TRUE`, `Null`, etc. are strings (and produce the `string_looks_like_literal` warning).

### 4.3 Numbers

A bare token is a number iff it is, after an optional `+`/`-` sign:

- a **radix integer**: `0x` + hex digits, `0o` + octal digits, or `0b` + binary digits;
- a **decimal integer**: digits, with **no leading zero** on a multi-digit value (`007` is a string — the TOML leading-zero rule; `0` is a number);
- a **float**: a decimal integer part (same no-leading-zero rule: `01.5` is a string), then an optional `.` + at least one fractional digit, and/or an optional exponent (`e`/`E`, optional sign, digits). At least one of fraction/exponent makes it a float.

A token that would be a valid number but for a leading zero on its integer part — sign included — produces the `string_leading_zero` warning (`007`, `-07`, `01.5`, `-01e2`). There are no digit separators (`1_000` is a string). Numbers never accept a leading-dot or trailing-dot float: a bare trailing-dot token (`1.`) and a bare leading-dot token (`.5`) are **strings**, and both shapes produce the `string_looks_like_number` warning — write `1.0` / `0.5`. `: float =` coercion accepts the trailing-dot lexeme (`x: float = 1.`) but NOT a leading-dot one: `x: float = .5` is a `FigTypeMismatch`.

The lexeme is preserved verbatim (§ 2): `1.10`, `1e2`, `0xFF`, `+9` all keep their spelling.

### 4.4 Datetimes

fig's datetime syntax is **TOML-compatible RFC 3339**: RFC 3339 shapes with TOML's relaxations — a space MAY replace `T` as the date/time separator, and `T` and `Z` MAY be written lowercase (`t`/`z`). A bare token that is a well-formed datetime sniffs to one of four self-identifying kinds:

- **offset datetime** — `2026-07-01T12:00:00Z`, `2026-07-01t12:00:00+02:00`;
- **local datetime** — `2026-07-01T12:00:00` (separator `T`, `t`, or a space);
- **local date** — `2026-07-01` (calendar-validated, leap years included);
- **local time** — `07:30:00`, `10:30` (seconds optional; optional fractional seconds; leap second `60` allowed).

A bare local time produces the `ambiguous_datetime` warning (it shares its shape with durations/ratios); bare dates and `T`/zone-carrying timestamps do not warn.

### 4.5 Quoted strings (single-line)

- `'…'` — **raw**: no escapes; MUST NOT contain `'` or a newline.
- `"…"` — **escaped**: `\n`, `\t`, `\r`, `\\`, `\"`, `\'`, and `\uXXXX` (exactly four hex digits, encoded as UTF-8); MUST NOT contain a raw newline. Any other escape is `FigBadEscape`.

Quoting overrides sniffing: `flag = "true"` and `team = "99"` are strings. Quoted forms are **committed** (§ 4.7). Keys may also be quoted (§ 5.1).

### 4.6 Multi-line strings

Both forms suspend the block layer (markers do not apply inside) and close at the matching triple delimiter:

- `'''` … `'''` — **raw/verbatim**: no escapes, no dedent. A content line's leading indentation is content, so raw blocks are conventionally written flush-left.
- `"""` … `"""` — **escaped + smart-dedent**: escapes as in § 4.5, and the whitespace run preceding the closing delimiter on its line is stripped from the start of every content line. A content line with less leading whitespace than that run loses whatever it has (never an error).

The opener line is still block-layer: a `# …` after the opening delimiter is the value's trailing comment, and content capture begins at the next newline — any other non-comment content after the opening delimiter is a hard error (`FigMultilineOpenerContent`; there is no one-line spelling of a multi-line string). The block **closes at the first line whose first non-whitespace content is the matching triple delimiter**; that closer line's leading whitespace is not content (for `"""` it defines the dedent run above), and the newline before the closer's line is not part of the value. A triple delimiter anywhere else in a line is ordinary content, so a value may contain `'''`/`"""` mid-line — but a content line *beginning* with the block's own delimiter is unrepresentable in that form (write it in the other form, or escape a leading `"""` as `\"""`). A block that never finds its closer is `FigUnclosedString`.

```
banner = """                  # trailing comment on the value
      Welcome!
      Enjoy your stay.
      """
```

parses `banner` as `"Welcome!\nEnjoy your stay."`.

### 4.7 Committed values

Commitment decides whether a malformed value is an error or a string, and it is a property of the **whole RHS**:

- **Quotes commit on the first character.** An unclosed quote is `FigUnclosedString`. A single-line quote that closes early with stray non-comment content after it is `FigQuotedTrailingContent` (`she = "She said, "Hi""` — the fix is to drop or escape the outer quotes).
- **Brackets commit by whole shape.** A leading `[`/`{`:
  - whose matching close (quoted spans skipped) is the final non-comment token of the line → **flow** (§ 6.3); a subsequent parse failure is a hard error;
  - that never closes on the line → handed to the flow parser, which scans across lines and raises `FigUnclosedFlow` at end of input if unterminated;
  - whose **balanced** close is followed by more content → the value was never flow: it is a **bare string**, left verbatim. This is what lets markdown links, globs, regexes, and BBCode go unquoted:

    ```
    link = [Blog](/Blog/Blog.md)     # string
    glob = [a-z]*.md                 # string
    regex = [0-9]+ years             # string
    ports = [80, 443]                # flow sequence (close is terminal)
    bad = [80, 443                   # hard error: FigUnclosedFlow
    ```

  A balanced, *well-formed* bracket group separated from its trailing content by whitespace (`[80, 443] x`) still parses as a string but produces the `flow_like_string` warning; glued shapes (`[Blog](/x)`) never warn.

## 5. Keys and key-value pairs

### 5.1 Keys

Keys are strings. A **bare key** consists of ASCII letters, digits, `_`, and `-`; it MUST NOT begin with `-` or `>`. Digit-first bare keys are legal (`1_sig_fig` is a valid bare key). A bare key MUST NOT contain a structural character — `.` `:` `=` `[` — nor whitespace, nor `*`/`+`/`@` (these are simply not bare-key characters). Any key needing such a character MUST be quoted:

```
"my.key" = present
"port 5432" = x        # a multi-word key must be quoted
```

The no-whitespace rule makes the dropped-`=` typo (`port 5432`) a hard `FigBadKey` rather than a silent container. Both quote forms (§ 4.5) are accepted for keys.

Non-string keys have no fig spelling (canonical form / envelope only).

### 5.2 Assignments and headers

On a content line, after the marker prefix:

- **assignment** — `keypath = value` (or `keypath: type = value`, § 5.3): binds a value;
- **header** — a bare `keypath` with no `=`: opens a container whose children are written one level deeper (or re-anchors the baseline at depth zero, § 7.2). Non-comment content after a header's path is `FigTrailingContent`.

The separator is ` = ` — `=` surrounded by optional whitespace. `:` never separates a key from a value (§ 3.2 guardrail); it introduces a type only.

A `keypath` is one or more key segments joined by `.`, each segment optionally followed by index steps `[i]` or `[]` (§ 7; a `[]` in an assignment's final position is an error, § 7.3). A missing value after `=` is `FigInvalidValue`.

### 5.3 Explicit type annotations — `key: type = value`

Typing is optional: `:` introduces a type name, `=` assigns. The built-in type names are `int`, `float`, `bool`, `string`, `enum`, `char`, `datetime`, `date`, `time`. An unrecognized name is `FigUnknownType`.

The annotation is **checked, coercing, and stored**:

- *checked* — an RHS incompatible with the type is `FigTypeMismatch` (`port: int = hello` errors);
- *coercing* — the annotation turns sniffing off and reinterprets the RHS: `x: string = 42` is the string `"42"`; `b: int = 09` and `a: float = 1.` accept lexemes bare sniffing rejects, keeping the **verbatim lexeme**;
- *stored* — `int`/`float`/`string`/`bool` annotations persist as a cross-format type tag, so `fig fmt` re-emits them (a redundant `n: int = 3` round-trips).

Under **every** annotation the RHS is scanned as **one raw token**: quote characters are not stripped and are part of the token, so under a non-`string` annotation a quoted RHS fails the check — `x: int = "42"` is `FigTypeMismatch` **by design**. Do not quote annotated numbers; write `x: int = 42`.

Type-specific rules:

- `: string` is a **total raw-text sink**: the ENTIRE RHS is verbatim text to end of line (the `#`-after-whitespace comment rule of § 3.4 still applies, exactly as for a bare RHS), with sniffing, bracket commitment, and the quote forms all off — `x: string = [ 1 + 2 ]` is one string, quote characters are literal content (`str: string = "hello"` is the seven-character string `"hello"`, equivalent to `str = "\"hello\""`), backslashes are literal (no escape processing), and a `'''`/`"""` opener is content rather than a multiline opener. Escape processing and multiline strings require dropping the annotation and quoting normally (§ 4.5 / § 4.6).
- `: enum = atom` — the only spelling of an enum literal; any non-empty bare token is the atom (`mode: enum = creative`).
- `: char = 'A'` — a single-quoted, single-codepoint ZON-style char literal; Zig escapes work (`'\t'`, `'\''`, `'\u{1F600}'`). A bare (unquoted) RHS or a multi-codepoint literal is `FigTypeMismatch`. Stored as the decimal codepoint.
- `: float = inf | -inf | nan` — the only spelling of non-finite floats.
- `: datetime` accepts any of the four datetime shapes; `: date` only a local date; `: time` only a local time.

Typing composes with elements: `*: int = 5` (the `*` is a positional key).

### 5.4 Duplicate keys

Re-defining an existing key within one mapping — by assignment, or by a header whose final segment names an existing non-container — is `FigDuplicateKey`. This applies inside flow objects and within one sequence element as well. Re-entering a header to add **new** keys is legal (§ 7.2).

## 6. Collections

### 6.1 Block mappings

A header line opens a mapping; its entries are written one level deeper.

```
database                    # header
> host = localhost
> port = 5432
> pool                      # nested header
> > size = 10
```

A header (or `*` element opener) whose container ends with zero children is `FigEmptyContainer` — this applies uniformly, including to an element created by an append header `[]` (which is map-shaped from birth but MUST NOT remain empty). Empty containers MUST be written inline: `key = {}` or `key = []`; a genuinely empty appended element is written inline as `xs = [{}]`.

### 6.2 Block sequences — the `*` element

`*` is an anonymous positional key: it sits exactly where a named key would, and its children live one level deeper.

```
servers
> *                        # first element (a map)
> > host = a.com
> > port = 25565
> *                        # second element
> > host = b.com

ports                      # scalar elements
> * 25565
> * 25566
```

At root, an element is a bare `*` (`* first` / `* second` build a root sequence). Rules:

- An element line whose bare RHS contains ` = ` is `FigElementInlineField` (`* host = a.com` — fields go on following lines). Quoted, flow, and typed RHS forms are exempt from this check.
- A container MUST NOT hold both `key = value` entries and `*` elements (`FigMixedContainerChildren`) — at root too.
- One sequence MUST NOT mix `*` elements with `[]`/`[i]` addressing (`FigMixedSequenceAddressing`).

### 6.3 Flow collections

A value beginning `[` or `{` (when committed, § 4.7) enters an inline flow sublanguage that suspends the block layer until the matching close; interior newlines carry no markers, so flow values may span lines.

```
tags = [a, b, c]                        # fig-inline: bare strings
audience = [friends, Adam Harris]       # bare values run to the comma
point = { x = 1, y = 2 }                # fig object: `=` pairs, bare keys
pasted = { "x": 1, "y": [2, 3] }        # JSON object: `:` pairs, quoted keys
empty_list = []
empty_map = {}
```

- **Objects have two spellings, selected per object by the pair separator**: fig-inline (`=`, keys bare or quoted) or JSON (`:`, keys MUST be quoted). Mixing separators in one object is `FigMixedFlowSeparators`; a bare key before `:` is `FigFlowBareKeyColon`. Arrays have no separator and no mode; each element self-selects, so pasted JSON subtrees nest inside fig objects.
- **Bare flow values run to the next `,` `]` `}` or newline**, spaces included then edge-trimmed — `[Adam Harris, Makena Harris]` is two two-word strings. They are sniffed by the same literal-else-string rule. A non-bracket-led bare value is terminated by *any* `]`/`}`; quote a value containing them. A newline ends a bare value but is **not** an element separator: the next non-blank, non-comment token must be `,` or the closer, so `[a` ⏎ `b]` is `FigUnclosedFlow` (a bare flow value cannot span lines; quote it instead).
- **Bracket-led bare strings** (§ 4.7's flow twin): an element whose first char is `[`/`{` and whose balanced close is followed by more content is a bare string, scanned bracket-aware so interior `]` does not terminate it — `links = [[Blog](/Blog.md), [Resume](/Resume.md)]` is two unquoted strings.
- **JSONC affordances**: trailing commas and `#` comments are accepted in both spellings; interior comments are discarded. JSON5 is otherwise dropped: `Infinity`/`NaN` are plain strings.
- A `# …` alone after the opening bracket on its line is the flow value's trailing comment (the multi-line-string opener rule's flow twin).
- A bare flow value containing ` = ` produces the `flow_missing_comma` warning (`{ x = 1 y = 2 }` reads `x = "1 y = 2"`).

### 6.4 Closed flow values

A container written as a flow value is **closed**: extending it later by a dotted path, header, or index is `FigClosedFlowValue`.

```
a = { x = 1 }
a.y = 2            # error: FigClosedFlowValue
```

Write the block or header form when a table needs to grow.

## 7. Sections and flatteners

### 7.1 Dotted keys

A dotted path in an assignment or header flattens nesting within one line: `> pool.size = 10` assigns through intermediate maps. Absent intermediate containers are auto-created; stepping into an existing non-container value is `FigKeyNotContainer`. Auto-creation never overwrites.

### 7.2 Section headers and baselines

A **zero-marker header** re-anchors the depth baseline (like TOML `[a.b.c]`):

```
services.web.frontend      # selects/creates services.web.frontend
> replicas = 3             # depth counts RELATIVE to the header
```

A baseline stays active until the next zero-marker structural line, which establishes a new one (another header, or root for a plain assignment or `*` element). Blank and comment lines do not reset it. Baselines do not stack: each zero-marker header replaces the active one. Re-entering an existing path to add new keys is legal; re-defining an existing leaf is `FigDuplicateKey`.

### 7.3 Append headers — `[]`

A `[]` as a header's **final** step appends a new anonymous element to that sequence and re-anchors the baseline to it. A **non-final** `[]` (mid-path in a header or assignment) means "the last existing element". Only a header-final `[]` creates.

```
jobs.test.steps[]              # append a step; fields sit one `>` deep
> uses = actions/setup-node@v4
> with.node-version = 20

spec.containers[]              # append a container
> name = app
spec.containers[].ports[]      # last container → append a port
> containerPort = 80
```

A `[]` in an assignment's **final** position (`xs[] = 5`) is a hard error: `[]` is only a header step or a mid-path "last element" step, never an assignment target. The diagnostic MUST teach the valid spellings — append map elements with an `xs[]` header, scalar elements with `*` element lines, or assign to an existing element by index (`xs[i] =`).

Append headers are order-dependent by design (the file is a log of append events). A non-final `[]` on an empty sequence — including one just auto-created — is `FigEmptyAppendTarget`. Append headers are legal at any depth; only zero-marker ones arm the `+` continuation (§ 8).

### 7.4 Index addressing — `[i]`

`clusters[0].name = alpha` addresses an element by position, for editing existing lists:

```
clusters[0].name = alpha
clusters[0].size = 3
clusters[1].name = beta        # indices extend by at most one
```

- A literal index in final assignment position MUST equal the sequence's current length (appending exactly one element): a smaller index is `FigIndexAlreadySet`, a larger one is `FigIndexSkipped`.
- An `[i]` header re-opens element `i` (if it exists and is a container) or creates element `i == len`.
- Indexes and `*` elements MUST NOT mix on one sequence (`FigMixedSequenceAddressing`).

## 8. Continuations — `+`

A zero-marker line consisting of `+` alone (optionally a trailing comment) re-runs the most recent zero-marker `[]` append header: append another element, re-anchor to it. It is exactly equivalent to repeating the header line.

```
replacements[]
> file = README.md
> exactly = 0
+                           # same as writing `replacements[]` again
> file = CHANGELOG.md
> exactly = 0
```

Rules:

- `+` is valid iff the most recent zero-marker **structural** line was a `[]` append header or another `+`. Blank lines, comment lines, and deeper body lines do not break the chain; any other zero-marker structural line does.
- For a nested header (`containers[].ports[]`), `+` re-runs the whole path — non-final `[]` still means "the last element".
- A `+` with nothing to re-run, or a `+` carrying depth markers (`> +`), is `FigDanglingContinuation`. Non-comment content after the `+` is `FigTrailingContent`.
- Anything glued to the `+` (`+foo`) is not a continuation and falls to key parsing (where `+` is not a bare-key character).

## 9. Canonical formatting (`fig fmt`)

The dialect admits many spellings per document; `fig fmt` (the printer) defines the canonical one. A conforming formatter MUST be idempotent, and its output MUST re-parse to an equal AST — comments included; every layout heuristic below is abandoned in favor of the nested spelling whenever it would drop a comment or re-anchor one onto a different node.

**Markers.** Spaced runs with zero leading indentation by default: `"> "` per level, so the final space doubles as the marker↔key separator (`> > key`). Element stars occupy their own cell (`> > *`); a root element is a bare `*`. An optional `fig fmt --indent` prefixes each marker/comment line with `2 × depth` literal spaces of cosmetic indentation on top of the marker run, purely visual — markers alone carry parse depth (§ 3.3), so canonical (default, unindented) and `--indent`-ed output re-parse to the same AST.

**Fits-or-breaks.** A container value renders as inline flow iff every descendant is flow-representable, no comment would be dropped or re-anchored, no object directly contains another object, and the whole line fits the width budget (default 80 columns). All-or-nothing per node; each child of a broken node re-decides independently. Not flow-representable (each forces block position): multi-line strings, enum/char/non-finite atoms, and any tag-annotated scalar (the `: type =` spelling exists only in block position).

**Multi-line flow.** A sequence that is fully flow-representable and holds no mapping element renders as stacked flow — `key = [`, one element per line with a two-space cosmetic indent and trailing comma, `]` at the opener's indent — when the inline form is rejected for width **or** for exceeding the item-count threshold (default 6). Nested sequences re-decide recursively. The value's trailing comment rides the opener line (`key = [  # note`). A stacked list is not blank-line separated from its neighbors. **Quote-avoidance:** when a list breaks, it takes `> *` block lines instead of stacked flow if flow would force quotes onto an element that block position renders bare (the common case: prose with a top-level comma).

**Strings.** Values print bare wherever the literal-else-string sniff round-trips them unchanged (tightened in flow position: no top-level `,`/`]`/`}`, no committing lead character, no whitespace-preceded `#`); otherwise the minimal quoted form that round-trips it: raw `'…'` (§ 4.5) when the content contains neither `'` nor a newline (no escaping needed at all), else a double-quoted form with minimal escapes. A `: string`-tagged value re-emits bare (with its annotation) whenever the total-sink scan reproduces it verbatim; when it does not — the value is multiline, has leading/trailing whitespace, or contains a whitespace-preceded `#` — the printer **drops the tag** and emits the ordinary untagged quoted or multiline form, since quoting under the annotation would turn the quotes into content. A string containing newlines prints as a `'''` raw block (flush-left, closer at column 0), or as `"""` with `\`, `"`, and CR escaped when the content contains `'''` or a CR.

**Dotted collapse.** A chain of single-child maps collapses to one dotted key (`a.b.c = v`), blocked where a comment's anchor would not survive.

**Sections.** Each root entry becomes one or more sections:

- a scalar or inline-fitting value → a dotted assignment (`workspace.resolver = "2"`);
- a mapping whose block body stays within **depth 2** → a dotted section header with a nested body;
- a deeper mapping hoists into per-child sections, recursively; runs of ≥ 2 consecutive flat children (scalar / inline-fitting) share one header re-entry, a lone flat child stays a dotted assignment, and key order is preserved exactly;
- a sequence of mappings → a `path[]` append header for the first element and `+` for the rest, fields one `>` deep;
- any other non-inline sequence → a header plus `* v` element lines.

Sections are separated by one blank line when either side is multi-line or carries leading comments; single-line assignments pack tight.

**Never emitted:** index addressing `[i]` (rewritten to append/block form), contiguous marker runs, JSON-spelled flow objects (normalized to fig-inline `=` pairs), and interior flow comments (not representable).

Trailing comments normalize to ` # text` (one space each side of `#`); leading and dangling comments to `# text` lines at their anchor depth.

## 10. Diagnostics

A conforming parser reports two severities:

- **errors** — the document has no well-defined tree; parsing MUST fail. The error conditions are those named throughout this spec (`Fig*` codes).
- **warnings** — the tree is well-defined but a line is a likely mistake; parsing MUST succeed. Consumers MAY promote warnings to failures (`--strict`) or silence them (`--quiet`).

The normative warning set: `string_looks_like_literal` (§ 4.2), `string_leading_zero` and `string_looks_like_number` (§ 4.3), `ambiguous_datetime` (§ 4.4), `flow_like_string` (§ 4.7), `flow_missing_comma` (§ 6.3), and `indent_marker_mismatch` (§ 3.3). Every diagnostic message SHOULD name the valid fig spelling that fixes it.

## 11. Conformance

- **Round-trip**: for any valid document, parse → AST → canonical-form emission MUST be byte-identical to the canonical emission of the same data authored in any other supported format (the canonical form is the comparison oracle). `fig fmt` MUST be idempotent (a second pass is byte-equal) and its output MUST re-parse to an equal AST, comments included.
- **Reference corpus**: `src/languages/fig/testdata/kitchen_sink.figl` is a canonical valid document exercising every construct in this spec (it deliberately carries warning examples); the parser and printer test suites in `parser.zig` / `printer.zig` are the behavioral reference.
- **Informative grammar**: `editors/tree-sitter-fig/grammar.js` is a shallow, lexical grammar for editor highlighting. It is informative only; where it and the reference parser disagree, the parser is authoritative. One accepted cosmetic gap remains: a double-quoted `: char` RHS (invalid — only a single-quoted `'A'` is a valid char literal, § 5.3) still highlights as an ordinary string, since distinguishing it from the valid single-quoted spelling isn't worth the added grammar complexity for a highlighting-only grammar.

## 12. File extensions

The canonical file extension is **`.figl`**; **`.fig`** is accepted for compatibility. Both select the authoring dialect.
