# Editor support for fig

Two artifacts that give the `.fig` authoring dialect syntax highlighting:

| Dir | What it is |
|---|---|
| [`tree-sitter-fig/`](./tree-sitter-fig) | The Tree-sitter grammar. Editor-agnostic — Zed, Neovim, Helix, and others can all consume it. |
| [`zed-fig/`](./zed-fig) | A thin Zed extension that points Zed at the grammar and ships the highlight query. |

## Design stance: the grammar is NOT a second source of truth

The Tree-sitter grammar is deliberately **shallow and lexical**. It recognizes
token *shapes* for coloring and nothing more. It does **not** reimplement fig's
semantics — depth-by-`>`-count, literal-else-string sniffing, baseline
re-anchoring, skipped-level / duplicate-key / closed-flow errors all live in the
Zig parser (`src/fig/parser.zig`), which stays authoritative.

Consequence: if the grammar and the Zig parser ever disagree, the worst outcome
is a **cosmetic mis-color**, never wrong behavior. That is what lets the grammar
be approximate (and therefore cheap to maintain). Known intentional
approximations are listed at the top of `tree-sitter-fig/grammar.js`.

For real diagnostics / formatting / hover, the future path is an **LSP server**
that wraps the Zig parser — a separate track from highlighting.

## Working on the grammar

```sh
cd editors/tree-sitter-fig
npm install                 # installs tree-sitter-cli locally
npx tree-sitter generate    # grammar.js -> src/parser.c
npx tree-sitter test        # runs test/corpus/*.txt
```

The generated `src/` (parser.c, node-types.json, grammar.json) **is committed**
on purpose so Zed can build the grammar without running codegen.

Sanity-check against the canonical feature dump (should print no `ERROR` nodes):

```sh
npx tree-sitter parse ../../src/fig/testdata/kitchen_sink.fig.txt | grep -c ERROR
```

To render highlighting in the terminal, add this directory to your
`~/.config/tree-sitter/config.json` `parser-directories`, then:

```sh
npx tree-sitter highlight some.fig
```

## Loading the Zed extension

Zed builds grammars from git — there is no "live local grammar" mode — so:

1. Commit the grammar (including `editors/tree-sitter-fig/src/`).
2. Set `rev` in `zed-fig/extension.toml` to that commit's sha
   (`git rev-parse HEAD`). The `repository`/`path` keys already point at this
   monorepo and the `editors/tree-sitter-fig` subdirectory.
3. In Zed: command palette → **`zed: install dev extension`** → pick
   `editors/zed-fig`. (Requires Rust via rustup installed.)
4. Open any `.fig` file.

Iterating on the grammar afterward = re-commit, bump `rev`, re-run
`zed: install dev extension`. The `highlights.scm` query under
`zed-fig/languages/fig/` can be tweaked without rebuilding the grammar.
