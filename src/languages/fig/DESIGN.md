# fig language design

Two text surfaces sit over one AST (`src/ast/ast.zig`). They optimize for
opposite things, so they are kept as separate surfaces rather than one
compromise format.

| | **canonical form** (`src/canonical/`, formerly "native") | **fig authoring dialect** (`src/languages/fig/`) |
|---|---|---|
| Audience | machines / the test oracle | humans writing config by hand |
| Goal | totality + a single spelling per document | memorability, typeability, ergonomics |
| Spellings per doc | exactly one (diffable by `strcmp`) | many (indentation free; several flatteners) |
| String default | always quoted | bare by default |
| Separator | `key: value` | `key = value` |
| Role | lossless oracle, debug output, comparison | the format users actually author |

The canonical form already exists and is a **total bijection** with the AST — it
can represent every `Node.Kind`, the YAML reference layer (`&`/`!`/`*`), the
int/float sigil (`~i`/`~f`), non-string keys, and line/block comments. Its
rigidity (fixed indent, always-quoted, one spelling) is exactly what makes it a
valid comparison oracle. **We are not changing it.**

The fig authoring dialect is the memorable, hand-writable surface. It parses
into the same AST and is emitted by `fig fmt`. It is allowed to be *lossy at the
edges* because the canonical form and the `$fig-envelope` lossless mode are
always available as the faithful fallback. It gives up canonicality (many
spellings) on purpose — it is not the oracle.

---

## The fig authoring dialect

### Design goals

- **Typeable on a bare keyboard.** No glyph that requires an editor plugin,
  snippet, or copy-paste. (This killed the original box-drawing `├`/`└` idea:
  config gets edited in emergencies over SSH on machines with no tooling.)
- **Whitespace never changes meaning.** The `>` count is the sole source of truth,
  so any reformatting — re-indent, paste, editor mangling — is semantically safe.
  This is a *semantic* guarantee, **not a keystroke claim**: it does not promise
  less typing than tooled YAML (see "Depth is a correctness risk" for the honest
  ergonomic contract). The indented/box-drawing view is a human aid layered on top,
  never the source of meaning.
- **Strict.** Prefer an error over a silent surprise (see duplicate keys,
  skipped levels, Norway problem).
- **Memorable.** The box-drawing aesthetic that started this survives as
  *rendered* output from `fig fmt`, not as required input.

### Structure — prefix-count depth

Nesting depth = **count of leading `>` markers**. Not indentation.

```
database
> host = localhost        # database.host
> port = 5432             # database.port
> pool                    # container header (no `=`)
>> size = 10              # database.pool.size
logging
> level = info
```

- A bare word with **no `=`** is a container header; with `=` it is an
  assignment.
- **Root keys carry zero markers.** A `>` at the top with no parent above it is a
  skipped-level error, not a root assignment.
- **Root is a map or a sequence — never a bare scalar.**
  - *Map* (the default): bare keys, assignments, and headers at zero markers — the
    shape of nearly all config.
  - *Sequence*: `*` elements at zero markers. `* 1` / `* 2` for scalars; a bare
    `*` then `> field` lines for a list of maps. The root can't be *both* — the
    `key = v` + `*` type error applies at root too.
  - *Scalar* (a whole document that is just `42` or `"hi"`): **no authoring
    spelling.** A bare token at root is a container header, so there is no
    unambiguous scalar-root syntax — and real config never needs one. Falls to the
    canonical form / envelope (tier 3), same as non-string keys.
- **Skipped levels error** (`>` then `>>>`). Almost always a miscount; erroring
  is how the format catches the one thing prefix-counting is bad at.
- **Marker tokenization.** A depth marker is a run of `>`; count = depth. The run
  may carry optional *leading* indentation (cosmetic — indentation is never
  load-bearing) and **requires** whitespace between the run and the key.
  Contiguous (`>>>`) and spaced (`> > >`) runs are equal; **`fig fmt` normalizes
  to a spaced run** (settled — the earlier contiguous-run house style is
  reversed). The spaced run recreates indentation's column geometry (two columns
  per level) out of the markers themselves: a visual ruler with no redundant
  second signal to keep in sync, easier to count than a tally-glued `>>>>`, and
  less intimidating to approach. Contiguous runs stay first-class input (faster
  to type; fmt restores the ruler). The marker/key separator is the one
  load-bearing space in the block layer.
- **The element marker is `*`, written in key position: `> *`.** A sequence
  element line is a key line with an *anonymous* key — `*` sits exactly where a
  named key would (`> host` / `> *`), and its children live one level deeper
  either way. `*` was chosen over the earlier glued `>-` (settled — see
  "Resolved"): it is visually distinct from `>`, so nothing can be mis-tallied
  and no glue rule is needed (`> > *` spaced is the normalized form; glued
  `>*` also parses); it is the universal plaintext bullet; and it ends the
  dash's double duty with the minus sign — a negative element is just `* -5`,
  no disambiguation rule required. At root an element is a bare `*` (zero
  markers, mirroring root keys exactly). `*` is a role marker, **not** a
  counted depth mark — depth is the `>` count alone (making `*` count-bearing
  was considered and rejected: a depth-0 root element would be unspellable, or
  root sequences would collide with nested ones). A `*` glued to its value
  (`>*v`, `*v`) is a `FigBadMarkerSeparator`, exactly like `>v`. Any `-`
  element spelling (`- v`, `>-`, `> -`) is a hard `FigForeignSyntaxDash` error
  naming the `*` form — YAML's list marker deserves a teaching error, not a
  silent parse.
- `>` chosen over `|`/`+`/mixed glyphs: it is the only single repeated char that
  (a) generalizes cleanly (level N+1 = append one `>`) and (b) stays countable.

### Depth is a correctness risk (not just readability)

Prefix-count did not *remove* load-bearing structure; it *relocated* it from
indentation to the `>` count. And the failure modes are asymmetric — the
skipped-level error catches only one of four miscount directions:

- **Deeper by ≥2** (`>` then `>>>`) → skipped-level error. **Caught.**
- **Deeper by exactly 1** → a valid new child. **Silent.**
- **Shallower by any amount** → valid (closing N containers at once is legitimate
  and common). **Silent.**
- **Same depth when a child was meant (or vice versa)** → both valid. **Silent.**

The everyday edit — "add a line one level in, tally one `>` wrong" — lands on a
still-valid depth with no error and, without indentation, no misalignment to catch
it by eye. And this **cannot be caught from the count alone**: shallow-by-many is
a legal, necessary operation, so no rule over a single signal can tell "meant it"
from "miscounted." Detection *requires a second, redundant signal.*

**The honest contract.** In the safe mode, indentation does the *visual* work and
the `>` count is the machine-checked *truth* — the lint forces them to agree. This
is the real design and a good one (double-entry bookkeeping for structure), but it
is the inverse of a naive "whitespace is free saves keystrokes" reading: you author
*one* signal and `fig fmt` maintains the redundancy; you carry both by hand in only
one loop — editing an already-indented file in a dumb editor without running fmt.
And YAML's "one gesture to deepen a block" is a *tooling* advantage (select+tab)
that the stated target user (nano over SSH) doesn't have either — so the ergonomic
gap is mainly against *tooled* YAML, which needs the safety net least. Two modes,
your choice, meaning always the count:

- **Bare `>`** — minimal to type, no visual net; miscounts are silent. Fine for
  shallow files and quick edits.
- **Indented `>`** — the cross-checked mode below; a write-time miscount net.

Mitigations, strongest first:

1. **Checked indentation (the second signal), opt-in.** Meaning stays
   entirely in the `>` count, so the semantic invariant holds exactly. Authors
   *may* indent; the linter warns only when a line's indent is **present and
   disagrees** with its marker count — so bare-`>` stays lint-clean and
   first-class, while indented files get cross-checked. The two encodings fail
   *independently* — indent you get right by visual alignment, count by
   tallying — so a silent wrong tree needs the *same* mistake in both at once.
   This restores YAML's visual-ruler catchability *as a check* rather than *as
   load-bearing structure*, and it is a **write-time** net. **Settled
   (revised):** emitted indentation is *not* the fmt default — the default house
   style is spaced marker runs (`> > `), which rebuild the visual ruler out of
   the markers themselves at half the leader width and with nothing to drift
   out of sync (see "What `fig fmt` normalizes"). Indentation *on top* of the
   count spends 3×depth columns doing with whitespace what the `>` run already
   does inherently, and an fmt'd file that intimidates readers into "don't
   touch without tooling" defeats the nano-over-SSH goal. A future
   `fig fmt --indent` re-adds derived indentation for repos that want the
   machine-checkable double-entry; the lint honors it either way. What the
   spaced-run default gives up is only the *machine* cross-check — the by-eye
   misalignment catch survives, since a miscounted line still sits at a
   visibly wrong column.
2. **`fig fmt` guide rendering.** Re-emit with the shelved box-drawing/guide
   aesthetic so misplacement is glaring on review. A **read-time** aid; make
   `fig fmt` the expected default (gofmt-style, in pre-commit/CI) so it is routine,
   not "if the user runs it."
3. The two **flatteners** below genuinely shrink the surface: if dotted keys and
   section headers keep typical depth at 2–3, deep `>>>>` runs are rare in
   well-written *map-heavy* config (but see the list caveat under "Sequences").

What does **not** work: round-tripping through `fig fmt` does *not* detect a
miscount. fmt re-emits the tree you *wrote*, not the one you *meant*; a miscounted
line is an internally-consistent wrong tree, so normalize-and-re-emit yields no
semantic diff. Round-trip surfaces formatting drift, never intent mismatch.

**Design fork (settled: count-authoritative).** Which signal is authoritative for
`fig fmt`? *Count-authoritative* (chosen): fmt derives indentation from the count,
so meaning is paste-safe *always* — fig's core differentiator. *Indent-
authoritative-until-fmt* (rejected): author by indentation and let fmt lower it to
counts — ergonomically closer to YAML, but a pre-fmt file's meaning would depend on
indentation (fragile until fmt runs), forfeiting paste-safety. Recorded so the
choice is deliberate; revisit only if nano-authoring ergonomics ever outweigh
pre-fmt paste-safety.

### Flatteners (escape hatches from "nesting hell")

- **Dotted keys** flatten within a line: `> pool.size = 10`.
- **Dotted section headers** re-anchor the baseline, exactly like TOML
  `[a.b.c]`:

  ```
  list.of.servers
  > host = a.com            # list.of.servers.host
  ```

  A header only *selects/creates* a map path. **Depth markers count relative to
  the active header's baseline**, not absolute document depth — so `> host` above
  is `list.of.servers.host`, and the skipped-level check is likewise relative.
  (Relative depth is deliberate: mandatory absolute depth would renumber the whole
  file on any near-root insert — the same edit-fragility rejected for sequence
  indices. The skipped-level error is the safety net for its one downside.)
  **A baseline stays active until the next zero-marker line**, which establishes a
  new one — another header, or root for a plain key/assignment/`*` element. Blank
  and comment-only lines don't reset it, and baselines don't stack: each
  zero-marker header *replaces* the active one (there is no "pop to parent").
  Re-entering a path to add new keys is fine; redefining a leaf key that already
  exists is a duplicate-key error. This is the **map-side** flattener; its
  sequence-side twin is the append header below.
- **Appending sequence headers** `a.b[]` are the sequence-side twin of dotted
  section headers — the primary surface for nested lists of maps (k8s / CI /
  Compose). A `[]` suffix on a header path **appends a new element** to that
  sequence and re-anchors the baseline to it, so its fields sit one `>` deep no
  matter how deeply the *list* nests:

  ```
  jobs.test.steps[]           # append an element to steps, re-anchor here
  > uses = actions/setup-node@v4
  > with.node-version = 20
  jobs.test.steps[]           # append another element
  > run = npm test
  ```

  The element stays anonymous (positional) — `[]` *appends*, it does not *name* —
  so the old "headers can't name an element" objection does not apply. And because
  it appends rather than indexes, it is **edit-stable**: drop a new `steps[]`
  block anywhere and nothing renumbers. Same AST as `> *` (a `sequence` of element
  children). Borrowed straight from TOML's array-of-tables `[[steps]]`.

  **An append header is a log, not a declaration.** Because `[]` appends and a
  non-final `[]` binds to *the last element*, the file is deliberately
  **order-dependent**: reordering two `spec.containers[]` blocks changes which
  container a following `spec.containers[].ports[]` (or `+`) attaches to. This is
  the price of edit-stability (no indices to renumber) and is intended — but it
  means append blocks read top-to-bottom as a sequence of operations, not as a
  set of independent declarations. Index addressing (`[i]`) is the order-*in*dependent
  counterpart, trading edit-stability for it.

  **Nested lists of lists** use TOML's rule: a **non-final `[]` means "the last
  element,"** only the final `[]` appends. So `containers[].ports[]` appends a port
  to the *last* container — the real k8s shape, still flat:

  ```
  spec.containers[]           # append a container
  > name = app
  spec.containers[].ports[]   # last container → append a port
  > containerPort = 80
  spec.containers[].ports[]   # last container → append another port
  > containerPort = 443
  ```
- **`+` continuation lines** de-duplicate a run of identical append headers. A
  zero-marker line consisting of just `+` (optionally a trailing comment)
  re-runs the most recent zero-marker `[]` append header: append another
  element, re-anchor to it.

  ```
  workspace.metadata.pre-release-replacements[]
  > file = README.md
  > exactly = 0
  +                           # same as repeating the [] header line
  > file = CHANGELOG.md
  > exactly = 0
  ```

  Rules: `+` is valid **iff the most recent zero-marker *structural* line was a
  `[]` append header or another `+`** — blank and comment lines don't break the
  chain (body lines are deeper, so they can't). A dangling `+` is a hard error
  (`FigDanglingContinuation`) naming the fix, which makes reorder/delete
  accidents loud — the deliberate price of a block that isn't self-contained
  (or greppable) the way a repeated header is. For a nested header
  (`containers[].ports[]`), `+` re-runs the *whole path* — non-final `[]` still
  means "the last element" — so it appends another port to the last container.
  A bare key may not begin with `+` (quote such a key), mirroring `>` (and `*`/`-`, which are never bare-key characters at all).
  `fig fmt` emits `[]` for a sequence's first element and `+` for the rest.
- **Index addressing** `servers[0].pool.size = x` addresses an *existing*
  element. Unlike `[]`, it is **edit-fragile** (inserting an element renumbers the
  rest), so it is for editing/addressing, **not** authoring fresh lists. The AST
  sequence has no index concept, only order; indices canonicalize to position.
  **Skipping an index errors** — write the earlier element first (even
  `servers[0] = null`), so gaps are explicit. **Mixing `[]`/`[i]` addressing and
  `*` element syntax for the same sequence is a type error** (same spirit as the
  `key = v` + `*` rule).

**When a path doesn't resolve: auto-create absent structure, error on conflicts.**
The rule for headers, dotted keys, `[]`, and `+` is asymmetric on purpose:

- **Absent parent structure is auto-created.** A header or dotted key names a map
  path; missing intermediate maps are materialized silently (`a.b.c = 1` creates
  `a` and `a.b`). Deep config shouldn't require declaring every ancestor first.
- **Conflicting structure is a hard error.** Stepping a path into an existing
  *non-container* value is `FigKeyNotContainer`; a non-final `[]` on an *empty*
  sequence (there is no "last element") is `FigEmptyAppendTarget`; a `+` with no
  preceding `[]` header is `FigDanglingContinuation`; re-defining an existing leaf
  is `FigDuplicateKey`. Auto-vivification never *overwrites* — it only fills gaps.
  **Absent and empty converge on one error, by design:** a non-final
  `spec.containers[].ports[]` on a file with *no* `spec.containers` auto-creates
  `spec.containers` as an empty sequence, whose "last element" then doesn't
  exist — landing on the same `FigEmptyAppendTarget`. Both paths name the remedy
  ("append one first with a header-final `[]`"), so a CI log tells the author the
  fix regardless of which path they took.

**The auto-create footgun tooling can catch (the format can't).** Auto-vivify has
one inherent hazard no *syntax* can fix: a typo'd path (`servces.web` for
`services.web`) silently creates a parallel tree rather than erroring — the classic
INI/TOML footgun. This is a property of auto-create itself, not a fig flaw, and the
right home for it is a **lint**, not a parse rule. fig is unusually well-positioned
to ship it: the CST already holds every sibling name and every read/write site, so
a `fig fmt`/`check --strict` lint can flag *sibling containers with edit-distance-1
names* and *a container created but never read*. Recorded as a tooling direction,
not a format change.

The four ways to descend, as a 2×2 — the append header completes it:

| | nested (costs depth) | flat header (re-anchors) |
|---|---|---|
| **map** | `> key = v` | `a.b.c` section header |
| **sequence** | `> *` (A2) | `a.b[]` append header |

Which list surface to reach for:

- **`a.b[]` append header** — nested / vertical lists of maps (the common
  real-world shape). Fig-native, flat, edit-stable, clean diffs. A `+` line
  continues a run of appends without re-typing the path.
- **`> *` (A2)** — short block lists where nesting is shallow, or lists whose
  elements carry comments / multi-line strings (which multi-line flow can't hold).
- **flow `[…]`** — genuinely inline small lists (`ports = [80, 443]`),
  heterogeneous data, or pasted JSON. The inline convenience, **not** the primary
  list surface. `fig fmt` **stacks** a long or many-element scalar/nested-list
  flow value onto multiple lines (see "Multi-line flow for long lists") — the
  answer for frontmatter link/tag lists.
- **`[i]` index** — editing / addressing an *existing* element (accepts the
  fragility).

### Append headers are a log, not a declaration

The conceptual key to the whole sequence surface — and the thing that makes its
order-dependence feel *designed* rather than accidental. A reader arriving from
TOML expects headers to be **declarative and commutative**: `[a.b]` names a table,
and reordering two `[a.b]` blocks is a no-op. fig's append surface is the
opposite by construction: **`a.b[]`, `+`, and the non-final `[]` are events
applied in document order.** The file is a *script that builds the tree*, and the
canonical form is the **replayed log** — one canonical event sequence. This single
reframe explains behaviors that are otherwise surprising:

- **Why reordering `[]` blocks changes meaning.** Two `spec.containers[]` blocks
  are two append events; swap them and a following `spec.containers[].ports[]`
  (whose non-final `[]` means "the last element") attaches to a different
  container. That is a log being replayed in a new order, not a declaration being
  mis-parsed.
- **Why `+` is positional.** `+` re-runs *the most recent `[]` append event*
  (verified: an intervening plain assignment or bare header breaks the run into a
  hard `FigDanglingContinuation`; only another `[]` header rebinds it — because a
  new append event legitimately becomes the thing `+` continues). Under the log
  model this is not "action at a distance" — `+` means "another element of the
  append that just ran," and reading top-to-bottom there is exactly one such
  append. The retarget some reviewers worry about (interpose or reorder a `[]`
  header above a `+` and its target shifts) is **the log behaving as a log**: the
  event that most recently ran *is* the antecedent. No purely-local rule can make
  that an error instead of a rebind, because after the edit the `+` is genuinely
  positioned to continue the new event — only an accessor that re-reads intent
  (a full-path echo, or a lint over the CST) could, and the log framing is what
  makes the plain positional rule the *correct* one rather than a compromise.
- **Why `[i]` index addressing exists.** It is the escape hatch to *declaration*
  semantics — address element `[0]` by identity, order-independently — traded for
  edit-fragility (inserting renumbers). Append when authoring a growing list;
  index when you need to name an existing element.

The fmt contract falls out cleanly: the printer **replays the log and emits one
canonical event sequence** — `[]` for a sequence's first element, `+` for the
rest — so any two documents that build the same tree normalize to the same script.

### What `fig fmt` normalizes (house style)

Canonical is the diff oracle, but the authoring dialect needs a *house style* so a
fmt'd repo reads consistently (many spellings → one predictable form; the reader
learns *this rule*, not each author's taste). The decision procedure below is
**implemented** (`src/languages/fig/printer.zig`); the numbers are defaults, not law.

- **Markers:** spaced runs (`> > key`), zero leading indentation. The spaced run
  recreates indentation's column geometry (two columns per level) out of the
  markers themselves — the visual ruler with no redundant second signal to keep
  in sync. Element stars occupy their own cell (`> > *`). A future
  `fig fmt --indent` can re-add derived indentation for repos that want the
  machine-checkable double-entry; the indent/count lint applies either way.
- **Fits-or-breaks (the split rule).** A container value renders as inline flow
  **iff** every descendant is flow-representable, no comment would be dropped
  or re-anchored, no object directly contains another object, and the whole
  line fits the width budget (`width` option, default 80 cols). Otherwise it
  renders block, and each child re-decides independently. All-or-nothing per
  node — deliberately *not* "measure which member contributes most and hoist
  it": partial inlining creates mixed spellings (see the closed-flow rule) and
  makes layout flip under small edits. The recursive fits rule needs no
  complexity metric, is stable and idempotent, and reproduces hand taste: a
  `serde = { version = "1.0", features = [derive] }` that fits stays inline; a
  `chrono` that doesn't gets block lines with its `features = […]` leaf inline.
- **Multi-line flow for long lists (the frontmatter surface).** A **sequence**
  that is fully flow-representable (every element has an inline spelling, no
  comment would drop) and holds **no map element** renders as *multi-line flow*
  — `key = [`, one element per line (two-space cosmetic indent, trailing comma),
  a `]` back at the opener's indent — whenever the inline form is rejected, for
  **either** reason: the line overflows the width budget, **or** the list
  exceeds an item-count threshold (`max_inline_seq_items`, default 6) even if
  it would fit. Short lists stay inline (`ports = [80, 443]`); long index-style
  lists stack. This is the terse answer for markdown frontmatter — a list of
  links or tags reads and diffs one-per-line without the depth-marker overhead
  of `> *` block lines. The interior is a suspended flow region (block markers
  don't apply inside), so the indent is purely visual and paste-safe.
  - **Nested lists re-decide fits-or-breaks independently** — the same
    recursive rule as everywhere else: a nested element rejected for the
    inline form (width or item count) stacks recursively, two more columns per
    level. No "nested stays on one line" exception; a long inner list can't
    smuggle a 200-column line into an otherwise-stacked value.
  - **The value's trailing comment rides the opener line** — `key = [  # note`
    — the multiline-string opener rule's flow twin: the opener line is still
    block-layer, so a `# …` after the `[` (with nothing else on the line)
    parses as the sequence's trailing comment, and fmt emits it there — next
    to the key it describes, not after the far-away `]`. A comment written
    after the closing `]` still parses as trailing and migrates to the opener
    on the next fmt; when both are written, the opener wins — same as `'''`.
  - **Not blank-line separated at the root.** A stacked list is still one
    assignment, so it packs tight with its scalar neighbors — the frontmatter
    look — rather than reading as a section the way a header + block body does.
  - **Quote-avoidance: bare beats quoted.** When a list breaks, it takes the
    `> *` block form instead of stacked flow if flow would force quotes onto
    an element that block position renders bare. The common case is prose with
    a top-level comma — `,` terminates a bare flow value but is ordinary text
    in a block bare string:

    ```
    random
    > * test of very long things in a list to see if it works
    > * hello there, this is also a long test; hopefully it works
    ```

    Markdown links, tags, and paths have no top-level commas, so the
    frontmatter lists stay on stacked flow. Elements needing quotes in *both*
    positions (`"true"`, a leading space, a flow-shaped string) don't count
    against flow — quoting is the same price either way. The rule recurses
    into nested lists (their interiors are flow-quoted too while the outer
    value stays flow), and it only arbitrates between the two *broken* forms:
    a short comma-carrying list that fits stays inline (`[a, "b, c"]` — one
    quoted element beats three lines). The trade, accepted: editing a comma
    into an element flips the list's layout on the next fmt — the same class
    of flip as crossing the width or item-count threshold.

  Falls back to `> *` block lines also when an element carries a comment
  (multi-line flow discards *interior* comments — the opener/closer trailing
  comment above is block-layer, not interior), is a multi-line string, or is an
  enum/char/float atom with no flow spelling. **Lists of maps stay on the
  append-header / block path** — flow of maps is brace-heavy (see the A2 vs
  `[{…}]` stress test).
- **Dotted keys:** a chain of single-child maps collapses into one dotted key
  (`a.b.c = v`) — blocked only where a comment's anchor wouldn't survive the
  collapse.
- **Sections (document root).** Each root entry becomes one or more sections:
  - scalar or inline-fitting value → dotted assignment (`workspace.resolver = "2"`);
  - a map whose block body stays within **depth 2** → dotted section header
    with a nested body;
  - a deeper map **hoists** into sections, recursively — the depth budget is
    what pushes k8s/CI-shaped config out to the flat `a.b.c` / `a.b[]`
    surfaces instead of `>>>>` runs. Hoisting is **grouped**: a run of ≥2
    consecutive flat siblings (scalar / inline-fitting) shares ONE header
    re-entry — the path is named once, not repeated per line — while each
    deep child gets its own section, and a lone flat child stays a dotted
    assignment (one line beats a two-line header group). Headers are
    re-enterable, so interleaved runs stay legal and key order is preserved
    exactly (this is TOML's own shape: scalars under `[a.b]`, sub-tables
    after);
  - a sequence of maps → `path[]` append header, then `+` continuations;
  - any other non-inline sequence → header + `* v` element lines.
- **Index `[i]`:** never emitted — rewritten to append/block form.
- **Multi-line strings:** a string containing newlines prints as a `'''` raw
  block (verbatim, flush-left), or `"""` with `\`/`"` escaped when the content
  contains `'''` or a carriage return. The closer sits at column 0, pinning the
  escaped flavor's smart-dedent at zero so leading whitespace in the value
  survives. A multi-line string also forces its container out of inline flow —
  blocks only exist in block position.
- **Quotes:** bare where literal-else-string round-trips the value unquoted —
  tightened in flow position, where a bare value must also survive the
  flow scanner (`,`/`]`/`}` anywhere, or a leading `[`/`{`, force quotes); else
  a double-quoted form. (Choosing `'…'` when no escapes are needed is a
  remaining nicety.)
- **Comments are conservative blockers.** Inline flow, dotted collapse,
  hoisting, and `[]`/`+` groups are all skipped when they would drop a comment
  or re-anchor it onto a different node; the printer falls back to the nested
  form that round-trips it exactly. fmt never loses a comment to win a
  prettier shape.

### Sequences — form A2 (`*` = anonymous positional key)

A list is a map whose keys are positions; `*` is how you write a positional key.
So `*` behaves *exactly* like a named key — it is written in key position, and
its fields live one level deeper — which means **no new parse rules** and every
line's *role* is fully determined by its own prefix. (Precise wording: a line
self-describes its **role** — assignment / header / element — not its **path**.
The path is baseline-relative, like TOML: it depends on the nearest zero-marker
line above.)

```
servers
> *                       # anonymous key at depth 1 = a new element
>> host = a.com           # its fields at depth 2, like any map
>> port = 25565
>> backends               # nested list field
>>> *                     # a backend element
>>>> url = x
>>>> weight = 1
>>> *
>>>> url = y
> *                       # second server element
>> host = b.com
```

(Spaced `> *` is the normalized form; glued `>*` parses identically — see
"Marker tokenization".)

- Chosen over **A1** (first field rides the element line, siblings continue at
  the same depth). A1 is one marker shallower per list, but it introduces the one
  place in fig where two same-depth lines play different roles (element-opener vs
  continuation). A2 keeps every line self-describing, matching fig's "role is in
  the prefix, never in whitespace" thesis.
- **A2's depth cost is real, and it lands worst where config is most common
  (nested lists of maps).** A real GitHub Actions job in A2 reaches depth 5
  (`steps` → element → `with` → key). Stress-tested against the alternatives:
  - *A2* — depth 5; self-describing, but marker-dense.
  - *A1* — depth 4 (saves one level) at the cost of the self-describing thesis.
  - *flow* `[{…}]` — flat but brace-heavy, repeats keys, noisy diffs.
  - *append header* `steps[]` — **depth 1, bare keys, edit-stable.** The winner.

  So A2 stays the block-layer default for shallow lists, but the answer for
  list-heavy config is the **append header** (see Flatteners), not deep `>`. Deep
  block list-in-list is friction *by design* — a nudge toward the header.
- Rejected: counter-shelving sugar (a marker that suspends depth counting). A whitespace-free, count-based
  language cannot contain a counter-free zone — a zone needs boundaries, and the
  only boundary marker available is the count itself. The moment such objects
  nest, the counter returns (or indentation does). Structural, not cosmetic.
- Scalar element: `> * 25565` (at root, `* 25565`). Map element: `> *` then
  `>>` fields.
- **No inline field on an element.** `* host = a.com` does *not* make a
  one-field map element (that is the rejected A1 shape). An element line whose
  RHS contains ` = ` is a **hard error** pointing at the `> *` / `>> host` form
  — never the silent string `"host = a.com"`. Muscle memory makes this worth an
  error, not a coercion.
- **Empty** list vs map is ambiguous as a bare childless container, so require
  inline `= []` / `= {}` (native via flow mode).
- A container with both `key = v` children **and** `*` children is a type error.

### Values

- **Literal-else-string rule (bare tokens only):** a bare, unsigiled, undelimited
  RHS is typed by *sniffing* — if the whole trimmed token parses as a
  number / bool / null / datetime it is that type; otherwise a bare string.
  Resolves `12 monkeys` (string), `true` (bool). Enum atoms and non-finite floats
  (`inf`/`nan`) are **not** sniffed — they are explicit-typing-only (below), so
  bare `@x` and bare `inf` are plain strings.
- **Committed values error, never fall back — but commitment is a property of the
  whole RHS, not just the first char.** The first-char test is a *proxy* for "the
  author intended structure"; for brackets it is too coarse, so the precise rule
  splits by delimiter:
  - **Quotes/triple** (`"` `'` / `"""` `'''`) commit on the first char: a parse
    failure is a **hard error**, never a string (`f = "true`, unclosed → error).
    Intent to write a string was declared by the opening quote. This is the
    principled *asymmetry* with the bracket rule above, and it is why the
    markdown-link lookahead does **not** generalize to quotes: the balanced-then-
    trailing fallback keeps the delimiters as *content* (`[Blog](/x)` verbatim is
    the intended value), but a quote's delimiters are *syntax meant to be
    stripped* — so a verbatim fallback (`"She said, "Hi""` including the outer
    quotes) is never what the author meant. A leading `"` also has no competing
    bare idiom (unlike `[`, overloaded with links/globs/regexes), so it is a
    *reliable* intent signal. A single-line quote that **closes early with more
    content on the line** — the wrapped-a-bare-string-in-unescaped-quotes slip
    (`she = "She said, "Hey there!""`) — is therefore a hard error
    (`FigQuotedTrailingContent`), and its message names the two fig fixes: drop
    the outer quotes (a bare string carries interior quotes fine — that is the
    common case) or escape them (`"She said, \"Hey there!\""`).
  - **Flow** (`[` / `{`) commits **only when the matching close is the final
    non-comment token** of the RHS. `ports = [80, 443` (never closes) is
    committed → **hard error**. (Note a *missing comma* inside a flow object is
    no longer an error: since bare flow values run to the comma, `{x = 1 y = 2}`
    reads `x = "1 y = 2"` — a spaced bare string, not a malformed pair. The price
    of bare values with spaces; quote or comma-separate to be explicit.) A leading
    `[`/`{` whose *balanced* close is
    followed by more content was **never** flow — it is a **bare string**, left
    unquoted: a markdown link `[Archived Docs](</a.md>)`, a glob `[a-z]*.md`, a
    regex `[0-9]+`, BBCode `[b]x[/b]`. This is what lets markdown links (and their
    kin) go unquoted: the author never intended structure, so string is the
    correct read — no surprise.
  Only *bare* tokens use the literal-else-string fallback; the balanced-then-
  trailing forms above join them. A genuine typo'd array (`[80, 443] x` — balanced
  but with trailing junk) also falls to string, but earns a coercion **warn**
  (below) since it *looks* like it wanted to be flow.
- **Leading-zero rule (TOML-style):** `007` is *not* a valid number, so it falls
  to the string `"007"` — zero-padded IDs, zip codes, and phone numbers keep
  their padding. Same family as the Norway fix.
- **Coercion diagnostic.** Because sniffing reinterprets by shape, the diagnostics
  layer warns on the surprising cases (see "Coercion diagnostics"): a
  number/bool/null-looking token that fell to string, or an inline `#` that
  truncated a bare value. A bare clock time warns **quietly** (`10:30` — the same
  shape as a duration/ratio/score, with no unambiguous subset even at full
  seconds precision); a bare *date* (`2026-07-01`) does not, since that shape is
  the overwhelmingly common, deliberate hand-authored case (frontmatter dates,
  deadlines, changelog entries) and warning on it was warn-fatigue rather than a
  catch. A full RFC-3339 timestamp (`T`/zone present) is unambiguous either way
  and always stays silent. Strictness via warning, not by removing the
  ergonomic default.
- **Bare strings by default**, including spaces: `title = My server`.
- **Bare-string whitespace: interior kept, edges trimmed; quote to preserve
  edges.** A bare value is trimmed of leading and trailing whitespace but keeps
  its interior spaces verbatim — `title = My server` is `"My server"`, and
  `movie = 12 monkeys` (no comment) is `"12 monkeys"` with the trailing run
  dropped. This composes with the `#` rule below: the value ends at the first
  whitespace-preceded `#`, then edge-trimming removes the space *before* that
  `#`. To keep a leading/trailing space (or a value that is only whitespace),
  quote it — `'  padded  '` preserves every byte, since quotes turn off both the
  trim and the bare-`#` truncation.
- **Comment marker (`#`) only after whitespace or line-start.** This saves URLs
  and fragments: `url = https://example.com  # real comment` → value
  `https://example.com`, comment `real comment`; `url = https://x#frag` keeps
  `#frag` (the `#` has no preceding space). See "Comments" for why `#`.
- **Quotes:** single `'…'` = raw/literal (no escapes); double `"…"` = escapes
  (`\n`, `\"`, `\uXXXX`). Mirrors TOML. Quote to override a literal:
  `team = "99"`.
- **Lowercase only** for `true` / `false` / `null`. `Yes`, `on`, `TRUE`, `NO`
  are strings. (Avoids YAML's Norway problem.)
- **Enum literal** — a tagged atom (canonical `@enum_literal "…"`), distinct from a
  string, **authored explicit-typing-only:** `mode: enum = creative`. There is no
  bare value sigil, so `reviewer = @alice` is the *string* `"@alice"`, not a silent
  atom (see "Enum: explicit-only" for why the `@`-value-sigil idea was dropped).
- **Char literal** — a single Unicode scalar (canonical `@char_literal "<codepoint>"`,
  the value ZON authors as `'a'`), **authored explicit-typing-only:** `sep: char = ','`.
  The `: char =` annotation is the disambiguator — it reads the RHS as a ZON-style
  char literal (`'A'`, `'\t'`, `'\''`, `'\u{1F600}'`) rather than as a length-1
  string, exactly the trick `: enum =`/`: float =` use. Stored as the decimal
  codepoint (the cross-format `char_literal` invariant), so `fig fmt` re-emits the
  `'…'` form and the value round-trips fig↔ZON↔canonical without loss. A **bare**
  (unquoted) RHS or a multi-codepoint literal is a `FigTypeMismatch`. Reusing the
  Zig char codec means escapes work for free.
- **Numbers** as bare lexemes; datetimes (RFC-3339, self-identifying) sniff
  natively. **Non-finite floats (`inf`/`nan`) are explicit-typing-only** —
  `timeout: float = inf` — so bare `inf`/`nan` stay strings; `fig fmt` emits the
  explicit form when the AST holds a `number_special`.
- **A number's value *is* its lexeme (normative, cross-implementation).** fig
  stores the source bytes of a number, not a decoded `f64`/`i64`: equality,
  round-trip, and canonical emission are all defined **over the source lexeme**,
  so `1.10` stays `1.10` (never `1.1`), `1e2` stays distinct from `100.0`, and
  `0xFF` is preserved rather than normalized to `255`. A conforming parser **MUST
  NOT** define value identity by numeric conversion; it **MAY** offer numeric
  coercion (`as_f64()`, `as_i64()`) as an explicitly *lossy accessor*, never as
  the stored value. This is the guarantee that stops a `float()`-based
  reimplementation from silently mangling versions and significant figures — it
  is a property of *the format*, not merely of the reference Zig library (whose
  `Number { raw, kind }` is where it happens to live today). Two numbers are
  equal iff their lexemes match byte-for-byte and their kinds agree.
- **Keys** are strings (bare or quoted). A **bare key may not contain a structural
  character** — `.` (path), `:` (type), `=` (assign), `[` (index) — nor whitespace,
  and may not begin with `>` or `-` (and `*`/`+` are not bare-key characters); any key that needs such a character must be quoted:
  `"my.key" = x`, `"foo:bar" = x` (bare `foo:bar = x` would read `bar` as a type).
  The no-whitespace rule closes the **dropped-`=` trap**: a header is a bare word,
  so `port 5432` (a `port = 5432` with the `=` fumbled) does **not** silently
  create a container named `port 5432` — the interior space makes it a hard
  `FigBadKey` ("a bare key cannot contain … whitespace"). A multi-word name that
  is genuinely intended must be quoted (`"port 5432"`). Erroring on the typo is
  the whole point: a format earns trust by demonstrating it has seen the traps.
  Non-string keys are deliberately **not** natively representable — the AST allows
  them (`keyvalue.key` is any node) but almost no config needs them; they fall to
  the canonical form / envelope.
- **Duplicate keys error** (within a map, and within one sequence element).

### Comments

- `#` line comments (chosen over `//`: it is the universal config comment char —
  shell, YAML, TOML, Python — which matters for a format meant to be edited over
  SSH in an emergency, and it collides with fewer bare values; only URL fragments
  carry `#`, and the after-whitespace rule saves those). Block comments degrade to
  a run of `#` lines (the AST records line-vs-block as a hint; printers
  downgrade).
- **Dangling / attached comments.** A `#`-only line carrying a depth prefix
  attaches at that depth to the *next* sibling; a trailing comment inside an
  otherwise-empty container attaches to the container. The depth prefix is the
  placement anchor YAML/TOML lack. When containers close over a buffered
  comment, its own depth decides its home: at or below the closing container's
  child depth → that container's **dangling** run (it was written inside);
  shallower → **leading** on the next sibling line (it was written between
  sections). This distinction is load-bearing for `fig fmt` output, where a
  section's leading comment sits at depth 0 right after a deeply nested body.

### Enum: explicit-only (why no value sigil)

Enum atoms are authored `x: enum = atom` and have **no bare value sigil**. We
first searched for one — a terse `@atom` spelling — then decided against a value
sigil at all; both the search and its abandonment are worth recording.

A value sigil would be a leading char meaning "the following bare word is a tagged
atom, not a string." Every candidate collided or overloaded:

| Sigil | Verdict |
|---|---|
| `.foo` | **out** — collides with dotfiles (`.env`, `.gitignore`) and overloads the path separator. This is what started the search. |
| `:foo` | Culturally *most correct* (the atom/symbol sigil), but re-muddies `:` the moment `key: type = value` gave it one clean meaning. Self-inflicted cognitive double-duty. |
| `!foo` | YAML-tag connotation; burns `!`, reserved for the reference layer. |
| `#foo` | taken by comments. |
| `$foo` | reads as variable/interpolation; also collides with `$fig-envelope`. |
| `%foo` / `^foo` / `/foo` | connotation-light but arbitrary; `/foo` reads as a path, `%` as URL-encoding. No cultural fit. |
| `@foo` | the least-bad — atom/handle-shaped, one char, no structural clash — and briefly chosen. But it still collides with bare handles (`reviewer = @alice`). |

The `@foo` collision is the general problem: *any* value sigil re-creates a
Norway-class edge where a plausible string silently becomes an atom. Since enum
atoms are rare in hand-authored config (most "enums" are perfectly good bare
strings — `level = info`), a sigil buys terseness for the exotic case at the cost
of a footgun on the common one. **Explicit-typing-only** removes the collision
entirely (bare `@x` is just a string) and shrinks the value grammar; `@` is
retired from the authoring value surface.

### Explicit typing — `key: type = value`

Typing is optional and reuses the separator split: `:` introduces a type, `=`
assigns. This is *why* the two separators stay distinct.

```
port: int = 5432
name: string = My server
mode: enum = creative      # the only way to author an enum atom
```

- Untyped `key = value` and typed `key: type = value` form a gradient, exactly
  like inferred vs annotated numbers.
- **The annotation is checked, coercing, AND stored.** It does two jobs at
  parse time: (a) *coerce/disambiguate* — `x: string = 42` yields the string
  `"42"`, not the int, turning off literal-else-string for that line; (b)
  *validate* — the RHS must be compatible with the named type or it is a **parse
  error** (`port: int = hello` → error). This is the annotation's whole point: it
  converts literal-else-string's silent coercion into a checked assertion — and it
  is what lets the two separators earn their keep. It is **also persisted** as a
  cross-format type tag (`ast.node_tags`; see AST fit #2), so it **round-trips**:
  `fig fmt` re-emits `: int/float/string/bool` and keeps the value's **verbatim
  lexeme** (`1_sig_fig: float = 1.` stays `1.`, `id: int = 09` stays `09`,
  `x: string = [ 1 + 2 ]` re-emits bare, not quoted). A redundant annotation
  (`n: int = 3`) is preserved too — the tag is recorded whenever the annotation
  is written. (`enum`/`datetime` map to distinct `extended` node kinds that
  self-annotate on print, so they carry no tag.)
- **Composes with `*`.** Because `*` is a positional key, an element types the
  same way: `*: int = 5`. One typing syntax everywhere — no special element case.
- Rejected `!type` (YAML-tag prefix): positionally ambiguous (`!int 5` — where
  does the tag end?) and it burns `!`, reserved for the reference layer.

### Flow mode & suspended regions

fig has two layers:

- **Block layer** — prefix-count depth; every line self-describes (the bulk of
  the format).
- **Delimited regions** — a value that begins `[` or `{` enters an inline **flow
  sublanguage** and parses until the matching close, *suspending* the block /
  prefix rules inside. Multiline strings (below) suspend the block layer the same
  way — one concept, two uses.

Flow objects come in **two spellings, and the pair separator selects between
them** — fig-inline (`=`) or JSON (`:`). This is *not* a JSON5 superset (that was
tried and dropped): the point is only that **real pasted JSON parses verbatim**,
not that fig embeds a second messy format.

```
tags   = [a, b, c]                 # fig-inline: bare strings
names  = [Adam Harris, Makena Harris]   # bare values run to the comma — spaces OK
point  = { x = 1, y = 2 }          # fig-inline object: `=` pairs, bare keys
pasted = { "x": 1, "y": [2, 3] }   # JSON object: `:` pairs, quoted keys
empty  = []                        # required spelling for an empty sequence
none   = {}                        # required spelling for an empty map
```

| Object spelling | Separator | Keys | Source |
|---|---|---|---|
| **fig-inline** | `=` | bare or quoted | terse hand-authored |
| **JSON** | `:` | **must** be quoted | pasted JSON verbatim |

- **The separator is the discriminator, chosen per object, and it may not mix.**
  `{x = 1, "y": 2}` is a **hard error** (`FigMixedFlowSeparators`) — an object is
  fig or JSON, never both.
- **A bare key before `:` is an error** (`{x: 1}` → "`x = 1` (fig) or `"x": 1`
  (JSON)") — the same YAML/JSON-habit guardrail as the block layer's `key: value`.
  So `:` never acts as a bare separator anywhere in fig.
- **Arrays have no separator, so no mode** — they are neutral containers; each
  element self-selects (`[a, b]` is fig by its bare strings, `["a","b"]` is
  neutral, `[{"x":1}]` holds a JSON object). Only *objects* fork. Selection is
  **per brace**, so a pasted JSON subtree drops straight into a fig object:
  `{ x = {"deep": [1, 2]} }`.
- **Bare values run to the next `,`/`]`/`}`** (spaces included, then trimmed), so
  `[Adam Harris, Makena Harris]` is two two-word strings — the exact ergonomic
  win that makes flow the answer for hand-written scalar lists.
- **Balanced-then-trailing is a bare string in flow too.** A flow element whose
  first char is `[`/`{` normally opens a nested collection — but the same
  whole-shape test the block layer uses (see "Committed values") applies: if the
  bracket's matching close is followed by a *flow terminator* (`,`/`]`/`}`) the
  element is genuine nested flow (`[[1, 2], [3, 4]]`); if it is followed by *more
  content* it was never a collection but a **bare string** — a markdown link
  `[Blog](/Blog.md)`, a glob, a regex. The bare scan is then **bracket-aware**:
  `[`/`{` raise a nesting depth and `]`/`}` lower it, so the interior `]` of
  `[text]` does not terminate the value — only a depth-0 `,`/`]`/`}` does. This
  is what lets a frontmatter list of markdown links, `[[Blog](/Blog.md),
  [Resume](/Resume.md)]`, stay entirely unquoted. (A markdown link whose text
  contains a top-level `,`/`]`/`}` still needs quoting — those are the flow
  terminators — but that is rare.)
- **JSONC affordances:** trailing commas and `#` **comments** (fig's comment char,
  not `//`/`/* */`) are accepted in both spellings. Interior comments are
  *discarded*, not attached to the AST (a documented edge cut).
- **Dropped from JSON5:** unquoted-key-`:`, `Infinity`/`NaN` (a bare `Infinity`
  now sniffs to the *string* `"Infinity"`, exactly as bare `inf` does in the block
  layer — closing a Norway-class hole the union had re-opened), and single-quoted
  *JSON* keys (single-quote stays fig's raw-string delimiter).
- **Not** a claim the whole language is a JSON superset — bare block strings,
  block `#` comments, and root-must-be-map still differ. Think "JSON embeddable as
  any value."
- **Flow values are closed** (TOML's inline-table rule): a container written as
  a flow value cannot be extended later by a dotted path, header, or index —
  `fig = { version = "1.0" }` followed by `fig.features = […]` is a hard error
  (`FigClosedFlowValue`). An inline value reads as *complete*; extending it
  after the fact is mutation at a distance, and the mixed spelling (half flow,
  half dotted siblings) was considered and rejected as a `fig fmt` output for
  the same reason. Write the block/header form when a table needs to grow.
- Makes inline `[]`/`{}` **native** (tier 1) and is the single rule behind the
  literal-else-string "flow collection" case; empty `[]` vs `{}` stay distinct
  (empty `sequence` node vs empty `mapping` node).
- Also why fig does **not** need an everything-is-a-map hack to get sequences:
  real sequences exist, and flow mode covers the inline case.

### Multiline strings — two flavors

Both are delimited regions that suspend the block layer until the close, mirroring
the single-line quote rule:

- `'''…'''` — **raw / verbatim**: no escapes, content whitespace preserved
  exactly. For blobs (PEM keys, regexes, pasted SQL). Caveat: because it is
  verbatim, leading indentation *becomes content* — do not indent raw blocks.
- `"""…"""` — **escaped + smart-dedent**: `\n`/`\uXXXX` honored, and the common
  leading indentation is stripped so the block can be indented to line up under
  its key without that indent leaking into the value.
- The opener line is still **block-layer**: a trailing `# …` after the opening
  `'''`/`"""` is an ordinary same-line comment; content capture begins at the next
  newline and runs until the close. (Stored as a `trailing` comment on the value;
  purely a lexer sequencing rule — see "AST fit".)

Multiline *comments* are intentionally **not** added (settled — see "Deferred /
declined losslessness"). A `/* … */` block would fight the line-oriented model
(where do depth `>` markers land on continuation lines?), and the loss it would
avoid is small: a block comment's *content* already survives as a run of `#`
lines; only the line-vs-block *style* flag degrades, and the AST documents that
flag as a downgradeable hint. `#`-per-line stays the one comment form.

### Authoring-time diagnostics

fig's strictness is delivered through diagnostics, not silent behavior. Two
severities, both routed through the existing diagnostics layer (`--quiet` /
`--strict`):

- **error** — refuse to parse; the document has no well-defined tree (or a
  structurally forbidden one).
- **warn** — the tree is well-defined but the line is a likely mistake. `--strict`
  promotes warns to errors; `--quiet` silences them.

Every diagnostic **names the fix.** The format teaches its own conventions at the
point of failure, because the target user is editing over SSH with no docs open.

#### Foreign-syntax guardrails (errors)

These catch muscle memory from YAML / JSON / TOML. Each has a valid fig spelling
that looks *almost* identical, so a silent misparse would be the worst outcome —
they are hard errors that point at the fig form rather than coercions.

| You wrote | Habit from | Diagnostic |
|---|---|---|
| `key: value` (no `=`) | YAML / JSON | error → "`:` introduces a *type*, not a value; did you mean `key = value`, or `key: type = value`?" |
| `- item` (any `-` element line) | YAML | error → "fig elements are `*`; write `> *` then `>> host = a.com`" |
| `* host = a.com` | A1 habit | error → "an element's fields go on following lines; write `> *` then `>> host = a.com`" |
| `[section]` / `[[x]]` at line-start | TOML | error → "fig section headers are bare dotted paths; write `section` / `x[]`, not `[section]` / `[[x]]`" |

`key: value` is the single most likely mistake in the whole format — every
YAML/JSON user has it in muscle memory — so it earns the most explicit message,
in the same spirit as the element-inline-field error.

#### Depth diagnostics

- **Skipped level** (`>` then `>>>`) — error. The one miscount that prefix-counting
  can catch from the count *alone* (see "Depth is a correctness risk").
- **Root marker** — a `>` at top level with no parent above it — error → "root keys
  carry zero markers; remove the `>`". (Distinct from skipped-level: here there is
  no parent at all.)
- **Indent/count disagreement** — warn, **on by default.** When a line's visual
  indentation does not match its marker count (the `--indent` convention is
  `2 × depth` spaces before the `>` run), the two redundant signals disagree and one
  is wrong. This is the write-time net from mitigation #1 — the *only* diagnostic
  that catches a deeper-by-exactly-1 or same-depth-when-a-child-was-meant miscount,
  which no rule over the count alone can detect. (Fires only when indentation is
  *present*; the bare/spaced-marker house style is lint-clean.)
- **Comment depth mismatch** — warn (planned). A `#`-only line whose marker depth
  matches neither the previous nor the next structural line probably anchors
  somewhere the author didn't intend (comment depth is load-bearing for
  attachment — see "Comments"). Catches the "wrote a comment for a depth-1 key
  at depth 0" slip.

#### Coercion diagnostics (warns)

The sniffing cost, surfaced rather than removed:

- a bare token that *looks* typed but fell to string, or the reverse (`Yes`, `007`,
  `12 monkeys`, `"true"`);
- a bare **clock time** where the author may have meant a duration/ratio/score
  (`meet = 10:30`) — but **only the time shape**, and quietly. A bare *date*
  (`day = 2026-07-01`) does **not** warn: in hand-authored config that shape is
  almost always a deliberate date (frontmatter, deadlines, changelogs), so
  flagging it was warn-fatigue on the common case rather than a catch. A bare
  time has no comparable safe majority — `HH:MM[:SS[.frac]]` is exactly a
  duration's/ratio's shape too, and neither seconds nor fractional precision
  tell them apart, so there is no narrower unambiguous subset to carve out the
  way the date/timestamp split does. A full RFC-3339 timestamp (`T` or zone
  present) is unambiguous either way and always stays silent;
- an inline `#` that silently truncated a bare value;
- a **balanced `[…]`/`{…}` with trailing content** that fell to a bare string
  (`[80, 443] oops`) — the shape opens like a flow collection but its close is not
  terminal, so it was read as a string. The fix the message names: drop the
  trailing content (to make it flow) or quote the whole value (to affirm the
  string). Markdown links, globs, and regexes are the *common, intended* form of
  this shape, so — like the datetime warn — it fires **only when the leading
  bracket-pair is itself well-formed flow** (`[80, 443]`), never for a link whose
  first `]` sits mid-value (`[text](url)`), to avoid warn-fatigue on the very case
  the rule exists to un-quote.

(Enum atoms and `inf`/`nan` are explicit-typing-only, so they never sniff and never
warn — bare `@x`/`inf` are plainly strings.) The fix is always a quote (`"…"`) or
an explicit `: type`, which the message names.

#### Structural semantic errors (post-parse)

Consolidated from the context-sensitive layer; all errors:

- a **committed value** that fails to parse — a leading quote/triple, or a leading
  `[`/`{` whose matching close is the final token (or never closes) — never string
  fallback; "close the `]`/quote, or quote the whole value". (A leading `[`/`{`
  whose balanced close has trailing content is *not* committed — it is a bare
  string; see Values.)
- a **single-line quote that closes early**, leaving stray non-comment content on
  the line (`she = "She said, "Hey there!""`) — a quote-specific trailing-content
  error (`FigQuotedTrailingContent`) that names the bare-string fix ("drop the
  outer quotes, or escape the inner ones"), rather than the generic
  `FigTrailingContent`. Triple-quoted openers keep the generic message.
- duplicate key (within a map, or within one sequence element);
- bare key containing a structural char (`.` `:` `=` `[`) or a leading `>`/`-` —
  "quote it: `\"my.key\"`";
- `[]`-as-last-element (a non-final or assignment `[]`) on an empty sequence —
  nothing to refer to (only a header-final `[]` *creates* an element);
- a **dangling `+`** — a continuation with no `[]` append header (or `+`) as the
  most recent zero-marker structural line, or a `+` carrying depth markers —
  "repeat the `a.b[]` header, or move the `+` directly after its group";
- **extending a closed flow value** — a dotted path / header / index stepping
  into a container written as `[…]`/`{…}` (`FigClosedFlowValue`, the TOML
  inline-table rule) — "write the block or header form if this table grows";
- mixing `[]`/`[i]` addressing with `*` elements for the same sequence;
- a flow object that **mixes `=` and `:` separators** (`{x = 1, "y": 2}`), or uses
  `:` after a **bare** key (`{x: 1}`) — "`x = 1` (fig) or `"x": 1` (JSON)";
- skipping a sequence index (`[0]` then `[2]`) — "write `[1]` first (even `= null`)";
- a container with both `key = v` and `*` children;
- a bare childless container — "give it `= []` or `= {}`";
- a scalar-root document — no authoring spelling; use canonical / `$fig-envelope`;
- **unknown type name** in `key: type = value`. The annotation is checked, and an
  unrecognized name cannot be checked — so it is an error, never a silently dropped
  annotation. The `type` set is *open in the grammar* but *closed at resolution* to
  the known types (plus any a host reader registers).

### Totality strategy — three tiers

The dialect stays *total* (nothing unrepresentable) without being *canonical* by
inheriting the canonical form's escape sigils for the long tail:

1. **Native** (the ergonomic 95%): null, bool, string, number, datetime, enum
   literal (via `: enum =`), char literal (via `: char =`), non-finite float (via
   `: float =`), sequence, mapping, keyvalue, `#` line comments, inline flow
   collections (`[…]`/`{…}`, see "Flow mode"), single/triple-quoted strings, and
   **explicit type annotations** (`: int/float/string/bool =`) — persisted as
   `node_tags` type tags, lexeme kept verbatim, so they round-trip through `fig fmt`
   (see "Explicit typing" and AST fit #2).
2. **Degrade + warn** (the existing diagnostics layer already reports this
   class): block comment → `#` runs, YAML **custom** tags dropped (core type
   tags map to `: type =` — see AST fit #2), aliases materialized. These are
   *deliberate* degrades, not gaps to close — see "Deferred / declined
   losslessness" for the reasoning on each.
3. **Inherited sigils / envelope** for the rest: `@extkind "text"`, `&`, `!`,
   `*`, `~i`/`~f`, non-string keys, scalar-root documents. `$fig-envelope`
   guarantees round-trip by construction.

`fig fmt` bridges the surfaces: parse authoring text → AST → emit canonical for
`strcmp`.

### Deferred / declined losslessness

The tier-2 degrades are choices, not oversights. As the dialect matures, each
`extended` scalar that lacks a bare spelling *can* be promoted to tier 1 by the
"explicit typing is the disambiguator" pattern — but only where the ergonomic
win is worth a new type name. The current dispositions:

- **Char literal — DONE (tier 1).** `: char = 'a'` promotes it exactly like
  `: enum =` did for atoms: the annotation reclassifies a `'…'` RHS (a length-1
  string bare) as a `char_literal`, stored as the decimal codepoint, re-emitted
  as `'a'`. Reuses the Zig char codec, so escapes (`'\t'`, `'\u{1F600}'`) come
  for free. Round-trips fig↔ZON↔canonical without loss. (See "Char literal".)
- **Block comment style — DECLINED.** Kept as a tier-2 degrade on purpose. The
  loss is only the line-vs-block *hint* (content is preserved as `#` runs), and a
  `/* … */` construct is incompatible with prefix-count depth. Byte-faithful
  `/* */` round-trips, if ever needed, belong in `$fig-envelope`, not the
  authoring surface. (See "Comments".)
- **YAML custom tags — DECLINED.** A `!foo` on a value is YAML-local metadata
  with no cross-format meaning. The honest degrade is to **drop the tag and keep
  the value at its real kind** (`!foo 42` stays the number `42`, not a string),
  with a warning — never to stringify the value. A native fig spelling would be
  complexity for a feature that doesn't cross formats; the `!` sigil in
  tier-3/`$fig-envelope` already carries it verbatim for the rare lossless need.
- **Anchors / aliases (`&`/`*`) — DEFERRED to a future point release.** The AST
  already models this fully (the `alias` node kind, `node_anchors`/`anchors`
  side-tables; canonical prints `&name`/`*name`), so the work is purely *surface
  syntax* — `&name`/`*name` glued to names, which sit in usable space. Worth
  doing eventually for large configs (Terraform/CI/infra) that share blocks.
  Three things to settle first, written down so the deferral is cheap to pick up:
  1. **Fundamentally format-limited.** Aliases survive losslessly only through
     fig↔canonical↔YAML; every other target calls `materialize` (expand aliases
     to copied subtrees), so JSON/TOML/ZON cannot carry sharing at all.
  2. **Cycles.** A true cycle (`&a { self = *a }`) cannot be materialized —
     infinite expansion. Decide the policy up front: detect and error cleanly
     (recommended) rather than blow the stack.
  3. **The `*` collision.** `*` is already the element marker in *key* position
     (`> *`). An alias `*name` in *value* position looks unambiguous, but that
     must be proven across flow mode and sequence tails before committing.
- **JSON-spelling preservation (`@json`) — DEFERRED to a point release.** Implicit
  JSON-in-flow (`pasted = {"x": 1}`) is normalized to fig-inline on `fig fmt`
  (`{ x = 1 }`) — the right default for hand-authored config, but it means a
  pasted JSON blob can't be kept verbatim-as-JSON. The wanted feature is to
  *preserve the JSON spelling*, and the key design realization is that this is a
  **rendering directive, not a data type.** A `json`-marked node is already a
  plain `mapping`/`sequence`; a type tag answers "*what* is this value?", a
  directive answers "*how* is it spelled?" — orthogonal axes. So it does **not**
  belong in `node_tags` (type assertions, e.g. `: int =`). Its home is a **new
  directive axis**:
  - An `@name` marker in the annotation slot, *before* an optional type and
    combinable with it: `val: @json = {"k": "v"}` (a container) and
    `val: @json string = "…"` (a scalar's spelling). `@` keeps directives visibly
    distinct from type names, and opens a namespace (`@json` first; future
    `@block`/`@flow`/… style hints could follow).
  - A `node_directives` side-table parallel to `node_comments`/`node_tags`,
    excluded from `eql` (it is trivia, like comments), plus parser recognition of
    `@name` and per-printer honor-or-drop.
  - fig-local by nature: every non-fig format drops it (a render hint has no
    cross-format meaning), so it round-trips through fig + canonical only — the
    same disposition as a dropped tag, NOT carried by `$fig-envelope` until the
    reference-layer envelope work lands.

  Open questions to settle first: what `@json` means on a **scalar** (JSON string
  quoting/escapes vs. a no-op), and whether it **validates** JSON-representability
  (string keys, JSON-legal number lexemes — no `0xFF`/datetime) or is a pure
  spelling directive that best-effort-renders. A whole annotation axis is more
  than this round warrants; the reasoning is captured so it is cheap to pick up.

---

## Grammar

An EBNF for fig is **illustrative, not complete**: like Python or YAML, fig is not
context-free. Depth is a *count* that a stack-based tree-builder resolves, and
several rules (`literal-else-string`, `#`-after-whitespace, suspended regions) are
lexer/strategy rules a CFG cannot state. So the grammar below gives the *shape*;
the "context-sensitive layer" list after it carries the rest.

```ebnf
(* ─── Notation ─────────────────────────────────────────────
   ::=  define     |  alternate     { } zero-or-more
   [ ]  optional   ( ) group        "…" terminal      ε empty
   NL = newline · EOF = end · WS = run of spaces/tabs
   UPPER = lexical token (see Lexical);  lower = grammar rule.   *)

(* ─── Block layer (line-oriented) ─── *)
document    ::= { line NL } [ line ] EOF
line        ::= WS* ( [ prefix WS+ ] body | continuation )
continuation::= "+" [ WS+ comment ]              (* re-runs the last zero-marker `[]` header *)
prefix      ::= markers [ WS* "*" ] | "*"       (* "*" = element role, in key position *)
markers     ::= ">" { WS* ">" }                  (* depth = count of ">"     *)
body        ::= header | assignment | eltail | comment | ε

header      ::= keypath [ WS+ comment ]          (* no "=" → container / section / append header *)
assignment  ::= keypath [ ":" type ] "=" value [ WS+ comment ]
eltail      ::= [ ( [ ":" type ] "=" value ) | value ] [ WS+ comment ]  (* body of a "*" element line *)

keypath     ::= keyseg { "." keyseg }
keyseg      ::= key { index }
index       ::= "[" [ INT ] "]"                  (* [i] address existing · [] append (header-final only) *)
key         ::= BAREKEY | STRING_SQ | STRING_DQ
type        ::= "int" | "float" | "bool" | "string" | "enum" | "char"
             | "datetime" | "date" | "time" | BAREKEY      (* open set *)

(* ─── Values (block RHS) — sniff bare tokens; committed forms error on failure ─── *)
value       ::= NULL | BOOL | NUMBER | DATETIME     (* sniffed bare tokens           *)
             | STRING_SQ | STRING_DQ | mlstring     (* committed: parse-fail = error  *)
             | flow          (* committed IFF matching close is terminal; balanced-then-trailing → BARESTRING *)
             | BARESTRING                            (* fallback — bare tokens & balanced-then-trailing *)
(* enum atoms, char literals & inf/nan are NOT here — explicit-typing-only, recognized only
   when the assignment carries ": enum =" / ": char =" / ": float =". Bare @x / 'a' / inf →
   BARESTRING (a string); a lone "'a'" is a length-1 string until ": char =" reclassifies it. *)

(* ─── Flow mode (recursive; fig-inline ∪ pasted-JSON, NOT JSON5) ─── *)
(* WS here also spans NL and "#" comments (JSONC); trailing "," allowed above.  *)
flow        ::= array | object
array       ::= "[" [ fvalue { "," fvalue } [ "," ] ] "]"
object      ::= figobject | jsonobject          (* separator selects; may not mix *)
figobject   ::= "{" [ figpair  { "," figpair  } [ "," ] ] "}"
jsonobject  ::= "{" [ jsonpair { "," jsonpair } [ "," ] ] "}"
figpair     ::= fkey                 "=" fvalue  (* bare or quoted key *)
jsonpair    ::= ( STRING_SQ | STRING_DQ ) ":" fvalue   (* quoted key required *)
fkey        ::= BAREKEY | STRING_SQ | STRING_DQ
fvalue      ::= NULL | BOOL | NUMBER | DATETIME
             | STRING_SQ | STRING_DQ | flow | BAREVAL
(* NUMSPECIAL is NOT an fvalue — Infinity/NaN sniff to BAREVAL strings, like bare inf/nan. *)

(* ─── Multiline strings (suspend the block layer) ─── *)
mlstring    ::= "'''" NL rawbody "'''"            (* verbatim                 *)
             | '"""' NL escbody '"""'             (* escaped + smart-dedent   *)

(* ─── Lexical tokens ─── *)
comment     ::= "#" { any-but-NL }
NULL        ::= "null"
BOOL        ::= "true" | "false"
NUMBER      ::= INT | FLOAT | HEX | OCT | BIN     (* leading-zero INT is NOT a number → BARESTRING *)
NUMSPECIAL  ::= "inf" | "-inf" | "nan"
            (* ": float =" context ONLY — never bare, in block or flow. JSON5's
               Infinity/NaN spellings are dropped: bare in flow they are strings. *)
DATETIME    ::= (* RFC-3339 offset/local datetime · full-date · time *)
STRING_SQ   ::= "'" { any-but-"'" } "'"           (* raw, no escapes          *)
STRING_DQ   ::= '"' { CHAR | ESC } '"'
ESC         ::= "\" ( "n" | "t" | "r" | "\" | '"' | "u" HEX HEX HEX HEX )
IDENT       ::= letter { letter | digit | "_" | "-" }
BAREKEY     ::= IDENT   (* excludes . : = [ * + and WS, and leading > - @ → quote such keys *)
BARESTRING  ::= (* trimmed RHS that matched no typed value; may contain WS *)
BAREVAL     ::= (* bare flow value: runs to the next "," "]" "}" NL (spaces
                   included, trimmed), or a " #" that opens a comment — so
                   [Adam Harris, ...] is two-word strings; sniffed like a block
                   bare token (Infinity/NaN → string) *)
```

### The context-sensitive layer (what EBNF can't carry)

These rules live in the scanner and tree-builder, not the CFG:

1. **Depth is a count; structure is built with a stack.** `markers` yields a
   number; parent/child nesting comes from comparing that number line-to-line
   (off-side style), which is where the **skipped-level error** fires — like
   Python emitting `INDENT`/`DEDENT` before the CFG runs.
2. **Section-header baseline.** After `a.b.c` (or an append header `a.b[]`), `>`
   counts are *relative* to that header's depth; the builder carries a baseline
   offset. A baseline is active until the next zero-marker line (which sets a new
   one, or root); baselines don't stack. A **header-final `[]`** appends a fresh
   element and re-anchors; a **non-final `[]`** (or `[]` in an assignment path)
   means the *last existing* element (TOML array-of-tables) — so
   `containers[].ports[]` appends a port to the *last* container. `[i]` addresses
   an existing element by position. The builder also remembers the most recent
   zero-marker append-header path (cleared by any other zero-marker structural
   line): a `+` continuation line re-runs it verbatim; with nothing to re-run,
   `+` is a `FigDanglingContinuation` error.
3. **Sniff bare tokens; commit on a leading delimiter — quotes by first char,
   brackets by whole shape.** A bare token is typed by whole-RHS sniffing
   (number/bool/null/datetime), else `BARESTRING` — this makes `12 monkeys`, `007`,
   `Yes` strings. A leading quote (`"` `'` / triple) **commits** to the string form
   on the first char (parse failure = hard error, never string fallback). A leading
   `[`/`{` commits to **flow only if its matching close is the final non-comment
   token** of the RHS: a non-closing bracket (`[80, 443`) stays committed and
   errors, but a *balanced* close with trailing content (`[text](url)`, a glob, a
   regex) was never flow and is a **bare string**. (Scan detail: skip over quoted
   spans while matching brackets, stop at the newline; a bracket that doesn't close
   on the line is either multi-line flow or truncation — both handed to the flow
   parser, which errors at EOF.) Enum atoms and `inf`/`nan` are recognized only in
   typed context (`: enum =` / `: float =`), where the annotation reinterprets the
   bare RHS.
4. **`#`-after-whitespace.** `#` opens a comment only at line-start or after WS; a
   `#` glued to non-WS (a URL fragment) is literal. Character-context → lexer.
5. **Suspended regions.** `'''`, `"""`, `[`, `{` switch the lexer *out of*
   line/prefix mode until the matching close; interior newlines carry no markers.
   `mlstring`/`flow` are the re-entry points.
6. **Semantic errors, not syntax errors** (post-parse checks): a committed value
   (leading `[ { " '`/triple) that fails to parse · duplicate keys · `* host =
   a.com` (inline field on an element) · an unquoted bare-key with a structural char
   (`.`/`:`/`=`/`[`) · a flow object mixing `=` and `:` separators, or a bare key
   before `:` · `[]`-as-last-element on an empty sequence · mixing
   `[]`/`[i]` and `*` for one sequence · skipping an index · a container with both
   `key = v` and `*` children · a bare childless container · a scalar-root document
   · an unknown `: type` name. (Full list: "Structural semantic errors".)
7. **Whitespace is free** *except* three load-bearing spots: the marker↔key
   separator, the space before an inline `#`, and inside quotes/multiline.

### Implied implementation shape

1. **Line splitter** — per line: strip cosmetic indent, count `markers`, split off
   the inline comment (honoring the `#`-after-WS rule).
2. **Stack-based block builder** — uses depth counts + header baseline to nest,
   emitting AST `mapping`/`sequence`/`keyvalue` and enforcing the count-based
   errors.
3. **Recursive-descent sub-parsers** — one for `flow` (the recursive EBNF is used
   almost verbatim), one for `mlstring` bodies: the only genuinely context-free
   parts.
4. **Value resolver** — the `literal-else-string` try-typed-then-fallback, per RHS.

Two productions most likely to change once the reader lands: the `element` tail
and the `type` set.

---

## AST fit

Checked against `src/ast/ast.zig`: the authoring dialect is a **subset of what
the AST already represents** — no new `Node.Kind` is required to hold a fig
document. (Expected — canonical is a total bijection with the AST, and fig is a
friendlier surface over the same tree.)

| fig surface | AST node |
|---|---|
| null / bool / string / number | `null_` / `boolean` / `string` / `number` (`raw` verbatim) |
| `mode: enum = atom` (explicit-only) | `extended` `enum_literal` (text = bare name) |
| datetime / date / time | `extended` `offset_datetime` / `local_date` / `local_time` |
| `inf` / `nan` | `extended` `number_special` — same spelling as TOML, reuses its handling |
| block seq (`> *`) **and** flow `[…]` | `sequence` |
| block map, flow `{…}`, dotted header/key | `mapping` + `keyvalue` |
| index addressing `xs[0]` | `sequence` position (indices canonicalize to order) |
| `key: int/float/string/bool = v` (explicit type) | `node_tags` type tag (`Tag.kind`) + verbatim value |
| `#` comments (leading / trailing / dangling) | `node_comments` side-table |

**Comment model is a direct fit.** `NodeComments{leading, trailing, dangling}`
already encodes fig's placement rules exactly: a depth-prefixed `#` line = a
`leading` comment on the next sibling; an end-of-container `#` = `dangling`; a
same-line `#` = `trailing`; a block comment carries `style = .block` and fig
downgrades it to a `#` run on print. Nothing new needed — including the
multiline-opener trailing comment (a `trailing` on the value; a lexer rule, not an
AST one).

**What the AST intentionally drops** (the "lossy at the edges" surface choices):
flow-vs-block, `=` vs `:` in flow, bare vs quoted, single vs triple quotes,
dotted vs nested. Spellings that decode to the same value build identical trees,
so `fig fmt` normalizes them — by design. (Explicit *type* annotations are **not**
in this list: they persist as `node_tags` and round-trip — see AST fit #2.)

**Optional accommodations (none blocking):**

1. To *preserve* a user's flow-vs-block / quote choice through `fig fmt`, add a
   style-hint side-table (mirroring `node_comments`/`node_tags`). Recommend
   **not** — normalize instead.
2. **Round-tripping explicit type annotations — DONE (`node_tags`).** The
   annotation is stored as a cross-format **type tag** in the generalized
   `node_tags` side-table (`ast.Tag`, a two-arm union: a normalized
   `kind: KindTag` — the companion to `Node.Kind`, so a fig `: int =`, a YAML
   `!!int`, and a canonical `!!int` all decode to the same value — or a verbatim
   `text` for a format tag with no core meaning, e.g. a YAML custom `!foo`). fig
   emits/reads the `kind` arm (`int/float/string/bool`); YAML keeps emitting its
   verbatim `text` tags but its printer + materializer also understand `kind`, so
   the mapping is **bidirectional and core tags round-trip both ways**:
   - *fig→YAML* — a fig `: int =` (a `.kind` tag) prints as `!!int`.
   - *YAML→fig* — `materialize` (the leaving-YAML pass) applies a core `!!int`/
     `!!str`/`!!float`/`!!bool`/`!!null` scalar tag to the node's kind AND keeps
     its identity as a normalized `.kind` tag, which the fig printer re-surfaces
     as `: int =` (and the canonical oracle as `!!int`); JSON/TOML/ZON ignore it
     (the value is already concrete). So
     `fig → yaml → fig` preserves the `: type` surface, not just the value.

   The value's verbatim lexeme is kept alongside (the coercion normalizers now
   only *validate*). This reverses the earlier "accept the loss" recommendation.
   `node_tags` is no longer YAML-only — it is the AST's cross-format type-tag
   layer. (Scope: fig + canonical/YAML; the C ABI / Rust bindings have no tag
   consumer and are untouched.) Edges: a preserved non-canonical lexeme (`09`,
   `1.`) is exact through fig↔fig (and fig↔YAML), but a strict target
   (JSON/canonical re-lex) may reject it; fig can't spell a YAML custom `text` tag,
   so it drops on output to fig; and a YAML `!!seq`/`!!map` collection tag is
   validated but not carried (fig has no `: seq`/`: map` annotation).
3. Cosmetic: the `enum_literal` doc comment in `ast.zig` says "without the leading
   `.`" (ZON's sigil) — note fig's `@` when the reader lands.

---

## Naming & migration — landed for 2.0

All of the following is **done**; build, tests, and `zig build semver-check`
(verdict: major → 2.0.0, already covered by `build.zig.zon`) are green.

- **Module:** `src/native/` → `src/canonical/`; `native.zig` → `canonical.zig`;
  `root.Native` → `root.Canonical` (with a deprecated `Native` alias so the
  Diaryx git dep keeps building).
- **AST enum:** `AST.SerializeFormat.native` → `.canonical`.
- **CLI:** `main.Format.native` → `.canonical`; new `main.Format.fig` (authoring);
  `--input/--output` accept `canonical` and `fig` (the old `native` token is
  gone); help text updated.
- **Canonical is explicit-only** — it owns **no file extension**. Select it with
  `--input canonical` / `--output canonical`. (It stays the AST oracle: still the
  round-trippable 1:1 encoding, just no longer auto-detected.)
- **`.fig` now routes to the authoring dialect.** Its reader/printer aren't built
  yet, so a `.fig` file (or `--input/--output fig`) errors with a clear message:
  *"the fig authoring dialect is not yet implemented (reserved; see DESIGN.md)."*
  The `get` path exits cleanly (`exit 2`, no stack trace); edit/set/check paths
  return `error.FigAuthoringNotImplemented`.
- **C ABI + Rust bindings: untouched by design.** Canonical was never a member of
  the C ABI's `FigFormat` (only json/jsonc/json5/yaml/toml/zon/xml), and the Rust
  `Format` enum mirrors exactly that. So there was nothing to rename there; the
  semver-check C-ABI diff shows no canonical/native delta. If canonical (or the
  authoring dialect) should ever be reachable through the C ABI, that's a
  *feature addition* (`FIG_FORMAT_CANONICAL`), tracked separately below.

### Still open / future

- Add `FIG_FORMAT_CANONICAL` (and eventually a fig-authoring member) to the C ABI
  `FigFormat` if hosts need canonical output through the bindings. Additive →
  MINOR.
- **Landed:** `src/languages/fig/` (reader + `fig fmt` printer), wired into `Language`,
  `AST.SerializeFormat`, and the CLI's `get` path (`--input/--output fig`,
  `.fig` extension). **Also landed:** the `fig fmt` house-style heuristics
  (spaced markers, fits-or-breaks flow budget, dotted-key collapse, root
  sections with the depth-2 header/hoist rule, `[]`/`+` append groups — see
  "What `fig fmt` normalizes"), the `+` continuation line, the closed-flow-value
  rule, and depth-aware comment attachment at container close. **Also landed:
  teaching-error rendering** — the parser captures a `Diagnostic{code, offset}`
  at the failure site (`parseWithDiagnostic`; the single-pass cursor is the
  position, with `failAt` pinning the few sites that scan past the offender,
  e.g. the `:` of `key: value`), a `describe()` table carries this document's
  name-the-fix messages, and the CLI renders `file:line:col: error: <message>`
  plus the offending line and a caret — `get` exits 2 cleanly, `check` prints
  the report in place of the generic `file: ErrorName` line. The flow-object
  bare-key-`:` case got its own code (`FigFlowBareKeyColon`) so the message can
  name both fixes (`key = 1` fig / `"key": 1` JSON). **Also landed: the WARN
  layer** — `Warning{code, offset}` collected during the pass and returned via
  `Report`/`parseWithReport` (valid alongside a failure too). Codes: the
  coercion set (`string_looks_like_literal` for `Yes`/`ON`/`TRUE`/`Null`,
  `string_leading_zero` for `007`, `ambiguous_datetime` for a bare *time* only
  (`10:30` — a bare date no longer warns, and a `T`/zone-carrying timestamp
  stays silent), `flow_like_string` (balanced
  well-formed `[…]` + whitespace + trailing content only — glued links/globs
  never warn; well-formedness by speculative sub-parse of the prefix),
  `flow_missing_comma` (a bare flow value swallowing ` = `, the
  `{x = 1 y = 2}` case — an addition beyond the DESIGN warn list), and
  `indent_marker_mismatch` (the mitigation-#1 lint: fires only when indent is
  present and ≠ `2 × depth` spaces; comment lines included, since their depth
  drives attachment). CLI: `get` renders warns under the existing
  `--quiet`/`--strict` contract (strict aborts, exit 2); `check` prints them
  after the `ok` line (still `ok` — warns don't fail the run). The LSP
  publishes them as severity-2 diagnostics alongside the severity-1 error.
  Deliberately NOT warned: `12 monkeys`-style prose with a leading number
  (warn-fatigue on titles; single-token lookalikes only) and the inline-`#`
  truncation (indistinguishable from an ordinary trailing comment — needs a
  better heuristic than DESIGN records). Not yet done: the comment-depth
  mismatch warn (needs comment offsets threaded through `PendingComment`),
  `fig fmt --indent` (the opt-in derived-indentation mode), and
  minimal-quote selection (`'…'` vs `"…"`).

**Landed: the in-place editor.** `fig/parser.zig` now stamps a real source
`Span` on every built node (key spans included; a container's span widens to
its full subtree bottom-up as children are built — see its "AST assembly"
section), which is what `Editor(fig.Language.FIG)` needs to splice edits
in place, same as TOML/YAML/ZON. `fig/editor_helper.zig` holds the fig-only
pieces: block insert/append/prepend copy an existing sibling's marker-prefix
text verbatim (depth + spaced-vs-glued style, no separate bookkeeping — fig's
self-describing lines make this safe to splice after any existing child,
scattered re-entered headers included); flow-object insert matches the
object's own fig-inline (`=`) vs JSON (`:`) pair mode. `edit`/`set`/`insert`/
`delete`/`comment` all work on `.fig` now.

**Landed: whole-container structural ops.** `deleteContainer`/`moveContainer`/
`reorderContainers` — fig's twins of TOML's `deleteTable`/`moveTable`/
`reorderTables` (library-level only, same as TOML's; no dedicated
`renameContainer` — the generic `replaceKeyAtPath` already splices a header's
key in place). Built on `gatherContainerRegions`, the fig generalization of
TOML's bracket-header region-gather: fig has no `[header]` token to grep for,
but ANY block (non-flow) mapping/sequence-valued entry was introduced by SOME
header line regardless of depth, so recursing into every such child and
recovering its header line from the child's own (always-accurate) span
handles fig's TOML-equivalent scattering (fields split across separate dotted
paths interleaved with foreign siblings) for free. The one shape spans alone
can't discover — a header **re-opening** an already-existing container (the
exact same header re-entered verbatim, a dotted path whose final segment
re-selects an existing container, an `xs[i]` header re-opening an element),
whose line sits in no child's span since a container's span anchors only its
CREATING line — is solved exactly rather than heuristically: the parser
records every header-final re-open at its single choke point
(`resolveHeaderFinal`) into a `Document.reentry_headers` side-table (node id
→ header-line position), and the gather folds those lines into the region
set. This matters beyond hand-authored files: `fig fmt`'s grouped hoisting
*emits* verbatim re-entered headers (a second flat-sibling run re-enters its
section header), so delete/move/reorder must handle them, not merely fail
safe. `deleteKey` still refuses a block-container-valued key outright
(`error.CannotDeleteContainer`) — use `deleteContainer` for that. Two
documented residual edges, both fail-safe via the reparse-rollback net:
replacing a re-entered/scattered container's entire value in one
`replaceValAtPath` splice (span-based, not region-aware), and a delete that
leaves an *ancestor* header childless (`FigEmptyContainer` rolls it back; the
cascade delete is deliberately not implied).

## Resolved (this round)

- **Separator split kept and now justified:** `:` introduces an optional type, `=`
  assigns (`key: type = value`). The split earns its keep.
- **Char literals are native (tier 1) via `: char = 'a'`** — promoted from the
  earlier degrade-to-string by the same explicit-typing-is-the-disambiguator
  pattern as enums, so they round-trip fig↔ZON↔canonical losslessly. (Superseded
  the "degrade to string" decision; see "Char literal" and "Deferred / declined
  losslessness".)
- **Dangling comments:** depth-prefixed `#` line attaches to the next sibling; a
  trailing comment in an empty container attaches to the container.
- **Enums explicit-only** (no value sigil; `x: enum = atom`), **`inf`/`nan`
  explicit-only** (`x: float = inf`), **committed values error** (a leading
  quote/triple, or a leading `[`/`{` whose matching close is terminal, that fails to
  parse is not string fallback — but a balanced `[…]`/`{…}` with trailing content,
  e.g. a markdown link, is a bare string), **comment char `#`**,
  **flow mode = fig-inline (`=`) + pasted JSON (`:`)** — separator-selected, no
  mixing, JSONC trailing commas + `#` comments, JSON5 otherwise dropped —
  **two multiline-string flavors**, leading-zero TOML rule,
  inline-field-on-dash is a hard error.
- **Authoring-time diagnostic set** (see that section): foreign-syntax guardrails
  (`key: value`, `[section]`), the indent/count disagreement warn, and unknown
  type name is an error (the `type` set is open in grammar, closed at resolution).

## Resolved (final batch)

- **Enum keys: no** — keys stay strings; keeps the LHS grammar small (and moot now
  that enums are explicit-only).
- **`"""` smart-dedent: automatic** — it is why the flavor exists (Swift/Java both
  landed there).
- **Table sugar: deferred past 1.0** — the hesitation was correct; if it ever
  lands, `fig fmt` detecting uniform lists is the right home. (A list of
  identical-shape scalar records is more compact as a table — one header row of
  keys, one row per element — but degrades the moment a cell holds a map or is
  absent, and real config is rarely that uniform, so append headers stay the
  general answer.)

## Resolved (fmt house-style round)

Settled while implementing the printer heuristics, prompted by converting a
real `Cargo.toml` and comparing against a hand-written target:

- **Marker style: spaced runs, no indentation** (Example 3 of the three
  candidates: indented+contiguous, bare contiguous, spaced). The markers ARE
  the ruler; emitted indentation was demoted from house default to the future
  `--indent` opt-in. Reverses the earlier normalize-to-contiguous rule.
- **The split rule is recursive fits-or-breaks, not a complexity metric.**
  All-or-nothing per node; no partial hoisting of the widest member. The
  "which children contribute most to line width" idea was considered and
  dropped — layout stability and idempotence win.
- **Flow values are closed** (`FigClosedFlowValue`). The 2-line
  `fig = {…}` + `fig.features = […]` split was considered as printer output
  and rejected: TOML forbids extending inline tables for good reason.
- **`+` continuation** landed in reader and printer (dangling `+` errors;
  chain survives blanks/comments; nested headers re-run the whole path).
- **Section shape budget: depth 2.** A root map renders as a header while its
  body stays within two marker levels, hoists into sections beyond that. This
  single number is what routes deep config to `a.b.c` headers and `a.b[]`
  groups automatically.
- **Hoisting groups flat-sibling runs** (follow-up: repetition). Naive
  per-child hoisting turned a run of sibling scalars into N copies of a long
  dotted path (`workspace.metadata.release.push = …` × 8). Fixed with header
  re-entry — ≥2 consecutive flat children share one `workspace.metadata.release`
  header line; deep children still section out after it. No new syntax needed;
  a relative-header sugar (e.g. `.child[]` continuing the previous section's
  path) was noted as a possible future step but not adopted.
- **Comment anchors outrank aesthetics** in fmt: every heuristic (inline,
  collapse, hoist, `[]` groups) backs off to the nested spelling rather than
  drop or re-anchor a comment.
- **Element marker: `*` replaces `-`** (settled, this round). The dash carried
  two disambiguation rules (the `>-` glue against mis-tallying, and the
  one-dash-only rule against the minus sign) that `*` makes unnecessary — it is
  visually distinct from `>` and collides with nothing in prefix position. `*`
  sits in key position (`> *`), making the A2 "anonymous positional key" thesis
  literal; every `-` element spelling is now a `FigForeignSyntaxDash` teaching
  error, which also makes the YAML-habit guardrail uniform (previously `- 25565`
  silently worked while `- k = v` errored). Considered and rejected: making `*`
  count toward depth itself (`*` / `> *` as depth 1/2) — a depth-0 root element
  would be unspellable, or root sequences would need a special deeper baseline
  and seq-of-seqs at root would collide; keeping `*` a role-in-key-position
  marker preserves exact root symmetry with named keys. Typing cost (`*` is
  shifted) accepted; `*` remains reserved for the YAML reference layer in VALUE
  position (tier 3), which never meets the prefix position.

## Open questions

*(None blocking. Remaining items are tuning-level: the comment-depth-mismatch
warn (the rest of the diagnostics layer — errors and warns — is landed and
rendered), `fig fmt --indent`, minimal-quote selection, and the additive
`FIG_FORMAT_CANONICAL` C-ABI member tracked above.)*