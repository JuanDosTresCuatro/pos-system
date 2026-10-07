// Builds a ready-to-run release zip in dist/: runtime files only, no tests or data.
import { readFileSync, readdirSync, statSync, mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { zip } from '../src/zip.js';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pkg = JSON.parse(readFileSync(path.join(ROOT, 'package.json'), 'utf8'));
const INCLUDE = ['server.js', 'package.json', 'README.md', '.env.example', 'src', 'public'];

const walk = (rel) => (statSync(path.join(ROOT, rel)).isDirectory()
  ? readdirSync(path.join(ROOT, rel)).flatMap((name) => walk(path.join(rel, name)))
  : [rel]);

const folder = `${pkg.name}-v${pkg.version}`;
const files = INCLUDE.flatMap(walk).map((rel) => ({
  name: `${folder}/${rel.split(path.sep).join('/')}`,
  data: readFileSync(path.join(ROOT, rel)),
}));
mkdirSync(path.join(ROOT, 'dist'), { recursive: true });
const out = path.join(ROOT, 'dist', `${folder}.zip`);
writeFileSync(out, zip(files));
console.log(`${path.relative(ROOT, out)}: ${files.length} files`);
