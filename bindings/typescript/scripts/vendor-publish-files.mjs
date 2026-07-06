// Dev tool: vendor fig's shared license text and the TypeScript guide into the
// npm package so the published tarball is self-contained.
//
// These files live once outside the package dir (LICENSE-MIT/LICENSE-APACHE at
// the repo root, the TS guide at docs/typescript.md). An npm package can only
// ship files inside its own dir, and a symlink would resolve to nothing once
// installed from the registry — so before packing we copy real content in. The
// README is the TypeScript-specific guide (not the repo-root Zig README), with
// its leading fig frontmatter block stripped so the npm page opens on prose.
// The copies are git-ignored; package.json's `files` allowlist force-adds them
// to the tarball. Runs from `prepack`, covering `npm pack` and `npm publish`.
import { copyFileSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const pkgDir = dirname(dirname(fileURLToPath(import.meta.url))); // bindings/typescript
const repoRoot = join(pkgDir, '..', '..');

// Verbatim license copies: [source-at-root, dest-in-package].
const copies = [
  ['LICENSE-MIT', 'LICENSE-MIT'],
  ['LICENSE-APACHE', 'LICENSE-APACHE'],
];
for (const [src, dest] of copies) {
  copyFileSync(join(repoRoot, src), join(pkgDir, dest));
}

// README: the TS guide, minus a leading ```fig … ``` frontmatter fence.
const guide = readFileSync(join(repoRoot, 'docs', 'typescript.md'), 'utf8');
const readme = guide.replace(/^\s*```fig\n[\s\S]*?\n```\n+/, '');
writeFileSync(join(pkgDir, 'README.md'), readme);

console.error('vendor-publish-files: wrote ' + (copies.length + 1) + ' files -> ' + pkgDir);
