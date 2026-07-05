# Editor support for fig

Two artifacts that give the `.figl` authoring dialect syntax highlighting
(`.fig` is also accepted for back-compat):

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

For real diagnostics / formatting / hover, there is an **LSP server** that wraps
the Zig parser — a separate track from highlighting. It is implemented and wired
into the Zed extension (see "The language server" below).

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
npx tree-sitter parse ../../src/languages/fig/testdata/kitchen_sink.figl | grep -c ERROR
```

To render highlighting in the terminal, add this directory to your
`~/.config/tree-sitter/config.json` `parser-directories`, then:

```sh
npx tree-sitter highlight some.figl
```

## Loading the Zed extension

Zed builds grammars from git — there is no "live local grammar" mode — so:

1. Commit the grammar (including `editors/tree-sitter-fig/src/`).
2. Set `rev` in `zed-fig/extension.toml` to that commit's sha
   (`git rev-parse HEAD`). The `repository`/`path` keys already point at this
   monorepo and the `editors/tree-sitter-fig` subdirectory.
3. In Zed: command palette → **`zed: install dev extension`** → pick
   `editors/zed-fig`. (Requires Rust via rustup installed.)
4. Open any `.figl` file.

Iterating on the grammar afterward = re-commit, bump `rev`, re-run
`zed: install dev extension`. The `highlights.scm` query under
`zed-fig/languages/fig/` can be tweaked without rebuilding the grammar.

## The language server

`fig-lsp` (built from `src/lsp/main.zig`) speaks LSP over stdio. Right now it
does one thing: re-parse on every open/change and publish the fig parser's
teaching diagnostics (`src/fig/parser.zig` → `Diagnostic`/`describe`) as editor
squiggles. It is a thin shell — the Zig parser stays the source of truth.

Build it (part of a normal build):

```sh
zig build            # produces zig-out/bin/fig-lsp
zig build run-lsp    # run it standalone on stdio (for manual testing)
```

The Zed extension launches it via the Rust shim in `zed-fig/src/lib.rs`
(`language_server_command`), which finds `fig-lsp` on your `PATH`
(`worktree.which`) and otherwise falls back to `zig-out/bin/fig-lsp`. To use the
`PATH` route, symlink it once:

```sh
ln -sf "$PWD/zig-out/bin/fig-lsp" ~/.local/bin/fig-lsp   # or anywhere on PATH
```

The `[language_servers.fig-lsp]` table is already in `zed-fig/extension.toml`.
When you `zed: install dev extension`, Zed compiles `zed-fig/src/lib.rs` to wasm
(needs Rust + the wasm target; Zed adds it) and starts `fig-lsp` for `.figl`
files. Open a file with a mistake — e.g. `host: localhost` (should be `=`) — and
you should see the teaching diagnostic inline.

Manual smoke test without Zed (drives the server over stdio):

```sh
python3 - <<'PY'
import subprocess, json
p = subprocess.Popen(["zig-out/bin/fig-lsp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
def send(m):
    d = json.dumps(m).encode()
    p.stdin.write(b"Content-Length: %d\r\n\r\n" % len(d) + d); p.stdin.flush()
def read():
    h = {}
    while (l := p.stdout.readline().rstrip(b"\r\n")):
        k, _, v = l.partition(b":"); h[k.strip().lower()] = v.strip()
    return json.loads(p.stdout.read(int(h[b"content-length"])))
send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}); read()
send({"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":
    {"uri":"file:///t.figl","languageId":"fig","version":1,"text":"a\n  > host: localhost\n"}}})
print(json.dumps(read(), indent=2))   # expect one FigForeignSyntaxColon diagnostic
PY
```

### Scope / next steps

Implemented: `initialize`, `didOpen`/`didChange`/`didClose`, `shutdown`/`exit`,
full-document sync, and diagnostics with UTF-16 ranges from the parser's
`Report` — the hard parse error (severity 1) **and** the authoring-time warnings
(severity 2: Norway-class strings, leading zeros, ambiguous datetimes,
indent/marker mismatch), published together (warnings collected before a failure
still show). Deliberately not yet done, in rough priority order:

- **Formatting** (`textDocument/formatting`) → call the fig printer
  (`src/fig/printer.zig`) and return a whole-document edit; this is the natural
  next feature and reuses existing code.
- **Multiple diagnostics** — the parser stops at the first error today; surfacing
  more needs parser support for error recovery.
- **Hover / completion** — would need the AST + span table (`Document.span`),
  which the parser already produces.
