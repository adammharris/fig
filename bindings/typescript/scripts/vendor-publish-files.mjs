// Dev tool: vendor fig's shared docs/license text into the npm package so the
// published tarball is self-contained.
//
// These files live once at the repo root (LICENSE-MIT, LICENSE-APACHE, and the
// canonical README content fig.md). An npm package can only ship files inside
// its own dir, and a symlink would resolve to nothing once installed from the
// registry — so before packing we copy real content in. The copies are
// git-ignored; package.json's `files` allowlist force-adds them to the tarball.
// Runs from `prepack`, so it covers both `npm pack` and `npm publish`.
import { copyFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const pkgDir = dirname(dirname(fileURLToPath(import.meta.url))); // bindings/typescript
const repoRoot = join(pkgDir, '..', '..');

// [source-at-root, dest-in-package]
const copies = [
  ['LICENSE-MIT', 'LICENSE-MIT'],
  ['LICENSE-APACHE', 'LICENSE-APACHE'],
  ['fig.md', 'README.md'],
];

for (const [src, dest] of copies) {
  copyFileSync(join(repoRoot, src), join(pkgDir, dest));
}
console.error('vendor-publish-files: copied ' + copies.length + ' files -> ' + pkgDir);
