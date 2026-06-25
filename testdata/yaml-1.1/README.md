# YAML 1.1 resolution fixtures

Hand-authored spec tests pinning **YAML 1.1 scalar type resolution** — the area
where 1.1 and 1.2 actually diverge. Driven by `src/yaml/conformance_1_1.zig`
(gated behind `-Dyaml-conformance=true`).

Unlike `testdata/yaml/` (the upstream yaml-test-suite, which is 1.2-only and
checks accept/reject), these fixtures check **resolved values**: each `.yaml`
has a sibling `.json` that pins every scalar's `{type, value}`, using the same
tagged-JSON shape as `testdata/toml/` (toml-test's format). The harness parses
the `.yaml` under `Type.v1_1`, parses the `.json`, and compares the trees leaf
by leaf (type + normalized value).

`type` is one of: `null`, `bool`, `integer`, `float`, `string`, `datetime`,
`date-local`, `time-local`. Numeric `value`s are canonical decimals (octal,
hex, binary, and sexagesimal are normalized); the harness strips `_` separators.

## Provenance

Every case is grounded in the YAML 1.1 **tag repository** (the normative source
for 1.1 resolution — 1.1's core spec delegates type resolution to it), mirrored
into the repo as `src/yaml/spec-1.1-tag-repository.md` (full spec in
`src/yaml/spec-1.1.md`). Key regexps:

| File | type/ rule (verbatim) |
| -- | -- |
| `null__*`  | `~ \| null\|Null\|NULL \| (empty)` |
| `bool__*`  | `y\|Y\|yes\|Yes\|YES\|n\|N\|no\|No\|NO\|true\|True\|TRUE\|false\|False\|FALSE\|on\|On\|ON\|off\|Off\|OFF` |
| `int__base2`  | `[-+]?0b[0-1_]+` |
| `int__base8`  | `[-+]?0[0-7_]+`  (leading-zero octal; **no** `0o`) |
| `int__base10` | `[-+]?(0\|[1-9][0-9_]*)` |
| `int__base16` | `[-+]?0x[0-9a-fA-F_]+` |
| `int__base60` | `[-+]?[1-9][0-9_]*(:[0-5]?[0-9])+` |
| `float__base10` | `[-+]?([0-9][0-9_]*)?\.[0-9.]*([eE][-+][0-9]+)?` (`.` required; exponent sign **mandatory**) |
| `float__base60` | `[-+]?[0-9][0-9_]*(:[0-5]?[0-9])+\.[0-9_]*` |
| `float__inf-nan` | `[-+]?\.(inf\|Inf\|INF)` / `\.(nan\|NaN\|NAN)` |
| `timestamp__*` | type/timestamp (ISO-8601 subset) → `extended` scalar |

## Divergence fixtures (the point of the suite)

`string__not-1-1-numbers` pins tokens that are typed in **1.2** but stay
**strings** in 1.1 (or vice versa):

- `1e3`  — 1.1 floats require a `.` and a *signed* exponent → string (1.2: float)
- `0o17` — 1.1 has no `0o` octal form → string (1.2: octal int)
- `08`   — leading zero ⇒ octal class, but `8` isn't octal → string (1.2: int 8)

The reverse flips (`yes`→bool, `0777`→octal 511, `1_000`→int, `0b1010`→int,
`190:20:30`→int, `685_230.15`→float) live in the typed fixtures and are the
ratchet targets as the 1.1 resolver is implemented.

## Status

The 1.1 resolver (`scalarKind1_1` in `src/yaml/parser.zig`) is implemented:
**14/14** fixtures pass. The scoreboard is a **ratchet** — it asserts the pass
count never drops below the recorded baseline (now 14).
