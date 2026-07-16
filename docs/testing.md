```fig
title = fig testing
author = adammharris
part_of = [fig docs](docs.md)
```

# Testing `fig`

`fig`'s job is to read bytes it did not write, in eleven formats, without
misreading them. Three layers guard that, in increasing order of paranoia:

| Layer | Command | Asks |
| --- | --- | --- |
| Unit tests | `zig build test` | Does each piece do what it says? |
| Conformance | `zig build conformance` | Do we agree with the format's own spec suite? |
| Fuzzing | `zig build fuzz --fuzz=1G` | Is there *any* input that breaks us? |

The first two run on every push, via `zig build check`. The third runs nightly —
see [Fuzzing](#Fuzzing) for why it cannot sensibly run on a pull request.

# Conformance

Conformance suites answer a question unit tests cannot: *does `fig` agree with
everyone else?* Each one scores our parser against a corpus the format's own
community maintains, so a passing score is evidence about the format, not just
about our reading of it.

```bash
zig build conformance   # all suites, ~13s
```

The corpora are vendored under `testdata/` — about 2,700 cases, tracked in git.
Nothing here touches the network, and nothing needs an external checkout.

| Suite | Corpus | Source |
| --- | --- | --- |
| JSON | `testdata/json/` | JSONTestSuite |
| JSON5 | `testdata/json5/` | json5/json5-tests |
| YAML | `testdata/yaml/`, `testdata/yaml-1.1/` | yaml-test-suite |
| TOML | `testdata/toml/`, `testdata/toml-1.1.0/` | toml-lang/toml-test |
| NestedText | `testdata/nestedtext/` | official NestedText suite |
| plist | `testdata/plist/` | system `Info.plist` files + `plutil`-verified oracles |

## Scoreboards ratchet

Every suite prints a scoreboard and asserts against a **baseline** — the number
of cases that pass today:

```
  1.0.0  valid: 209/209 (baseline 209)   invalid: 495/495 (baseline 495)
plist conformance (testdata/plist)
  valid   parsed:   9/9 (baseline 9)
  valid   vs plutil oracle: 7/7 (baseline 7)
  invalid rejected: 5/5 (baseline 5)
```

The baseline can only go up. A regression fails the build; fixing more cases
means raising the number in the same commit. This is what lets a suite be
adopted before it fully passes — the score is a record of where we are, not a
claim to be perfect.

Note the plist suite tracks *parsed*, *matches the oracle*, and *rejected*
separately, on purpose. Folding oracle-match into parse-success would let a
silent mis-parse hide behind a passing parse count, which is precisely the bug
class the oracle exists to catch.

## How it is wired

The suites sit behind `-D*-conformance` flags that default **off**, so a routine
`zig build test` stays fast. `zig build conformance` builds a variant of the
library module with all six forced on — and every language forced on too, which
is a deliberate bonus: `xml`, `plist` and `canonical` are all off by default, so
this is the only build that proves the everything-on configuration still
compiles.

`check` depends on it, which is the point. CI runs `zig build check` and nothing
else, so a new suite is scored the moment it is added to `src/root.zig` — there
is no workflow to remember to edit. The flags still work by hand when iterating
on one format:

```bash
zig build test -Dtoml-conformance=true
```

## Refreshing a corpus

The `gen-*-conformance` steps vendor an upstream corpus into `testdata/`. They
take a path to a local checkout and are run by hand, never by the test suite:

```bash
zig build gen-toml-conformance -- ../toml-test
```

# Fuzzing

Conformance proves `fig` handles the inputs somebody thought to write down.
Fuzzing goes looking for the ones nobody did.

A fuzzer generates inputs, runs a parser on them, and reports anything that
crashes, leaks, or violates a stated property. It is **coverage-guided**: it
instruments the parser, watches which branches each input reaches, keeps the
inputs that reach new code, and mutates those. It is not random noise — it hill
climbs into the corners of the grammar. This matters here because `fig` is
~12,000 lines of hand-written tokenizer and parser whose entire job is consuming
untrusted bytes; that is the textbook target.

The bug classes it finds are ones conformance structurally cannot: panics on
truncated input, overflow in span arithmetic, unbounded recursion, leaks on
error paths (the `parseCollecting` recovery paths especially), and silent
mis-parses.

```bash
zig build fuzz --fuzz=1G      # fuzz until you stop it
zig build fuzz --fuzz=50K     # or cap the iterations
```

Two flags, not one: `zig build fuzz` alone just runs the targets once. `--fuzz`
is a build-*runner* flag, so it cannot be turned on from `build.zig`. Its
argument is an **iteration cap, not a time budget** — and omitting it implies
`--webui`, a live coverage view served until you interrupt it. Locally that is
excellent; in CI it is a hang, which is why the workflow always passes `=<n>`.

## The targets

Both live in `src/fuzz.zig`, split by what they can prove:

- **`detect`** — *breadth*. `Language.detect` runs every compiled-in parser over
  the same bytes, so one target sweeps all eleven grammars for crashes and
  leaks. It cannot check correctness: the result is just an enum.
- **canonical round-trip** — *depth*. The canonical form is a bijection with the
  AST, so for any input it accepts, `parse → print → parse` must land on the
  same tree. This is the one property strong enough to catch a **silent
  mis-parse** — a parser that accepts input and builds the wrong tree, which
  `detect` would never notice.

Leaks come free: the test runner gives each iteration a fresh
`std.testing.allocator` and fails on a leak.

Note what is *not* asserted: `parse → print == original`. Printers render from
the AST, not from `Document.source`, so byte-identical output is not a property
of this codebase — asserting it would just freeze today's formatting. The real
claim is idempotence from the second print on.

## On pull requests

The targets run as ordinary tests on every `zig build test`, because
`src/root.zig` imports `src/fuzz.zig` unconditionally. **This is not fuzz
coverage.** Outside fuzz mode, Zig runs each target over a single empty input,
so both pass trivially. It exists so a target cannot silently stop compiling or
have its property broken between nightly runs. A green PR says the targets are
alive, nothing more.

## Nightly

`.github/workflows/fuzz.yml` fuzzes for 15 minutes each night and, on a finding,
files an issue with the corpus attached. It is deduped on the `fuzz` label — an
unfixed crash is deterministic and would otherwise refile every morning.

Fuzzing has no natural stopping point, which is the whole reason it is not on
the gate: you cannot block a merge on an unbounded search.

The budget is enforced by `timeout(1)`, not by `--fuzz`, because iteration
throughput is a property of the machine — ~50K iterations took over 10 minutes
on an M-series laptop, and a CI runner is slower again. Any count tuned to fill
15 minutes there is wrong everywhere else. So the workflow sets an iteration cap
it will never reach and lets the clock end the run.

## Why the nightly greps instead of trusting `$?`

The workflow decides pass/fail by **scanning the fuzzer's output for a failure
marker**, and only then looks at the exit code. That inversion is deliberate.

On Zig 0.16.0, `zig build fuzz` does not reliably exit non-zero when a target
fails. Verified on aarch64-macos with a deliberately-always-failing target:
`zig build test` exits 1 correctly, but under `--fuzz` the same failure prints
`error: '<test>' failed:` with a full error return trace and then **hangs** —
so `timeout` reaps it and reports 124, which is exactly what a clean run
reports. A nightly trusting the exit code would be permanently, silently green
while sitting on a crash. That is worse than no nightly, because it looks like
coverage.

Relatedly, `--fuzz=<n>` does not appear to terminate at its limit at all:
`--fuzz=100` ran for five minutes without printing a report. This is why the
budget is a clock rather than a count.

Both may well be macOS-only — the fuzzer is least exercised there, and CI runs
Linux — but a redundant check costs nothing, and being wrong about it would be
invisible. A clean run emits neither `^error: ` nor `^failed command: `; a
failing one emits both. If a future Zig makes the exit code trustworthy, the
grep can go.

To reproduce a nightly failure: download the run's `fuzz-corpus-*` artifact,
unzip it so `f` lands at `.zig-cache/f`, and re-run `zig build fuzz --fuzz=1G`.
The fuzzer resumes from that corpus rather than starting cold. That is a head
start, not a stored repro case — the run log names the failing target and
carries the error return trace, so read that first. `-Dtest-filter` narrows to a
single target.

**Known limitation:** an input that makes a parser loop forever is
indistinguishable from a clean run, since both end at the budget. Zig 0.16's
fuzzer has no per-input timeout. Crashes, leaks and broken invariants are
caught; hangs are not.

## The vendored test runner

`tools/fuzz_test_runner.zig` is a copy of Zig 0.16.0's own test runner with a
one-line fix. It exists because **`zig build test --fuzz` does not compile on
Zig 0.16.0** — the stock runner's fuzz path calls `std.debug.writeStackTrace`
with the result of `@errorReturnTrace()`, and those are different types. It is
upstream's bug and it hits every 0.16.0 project that tries to fuzz; it survived
upstream CI because that path is only analyzed under `-ffuzz`.

It is scoped to the `fuzz` step alone. `test`, `conformance` and `check` all use
the stock runner, so a stale copy can never compromise the release gate — the
worst it can do is break `zig build fuzz`. **Delete it** once a Zig release
fixes this; the file's header says how to check and what else to remove.

## Adding a target

Add it to `src/fuzz.zig` next to the two there; `root.zig` already imports the
module, and the `fuzz` step filters on `fuzz`, so nothing else needs wiring.
Start the body with `@disableInstrumentation()` — the fuzzer should be measuring
the parser's coverage, not the harness's — and use `std.testing.allocator` so
leaks are caught.

Prefer a target that asserts a **property** over one that only checks for
crashes; "does not crash" is a low bar, and the canonical round-trip shows what
a real oracle buys. One trap worth knowing: `FuzzInputOptions.corpus` entries
are `Smith` *decision tapes*, not source text, so the fixtures under `testdata/`
cannot be dropped in as seeds — they are ordinary files, and the conformance
suites already read them as such.
