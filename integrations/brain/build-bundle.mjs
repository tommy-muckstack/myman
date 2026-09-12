import { build } from 'esbuild';
import { mkdir, readFile, writeFile, readdir, unlink } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const directory = path.dirname(fileURLToPath(import.meta.url));
const output = path.resolve(directory, '../../src/Resources/BrainCompanion');
const result = await build({ absWorkingDir: directory, entryPoints: ['cli.mjs', 'server.mjs'], outdir: output, outExtension: { '.js': '.mjs' }, bundle: true, platform: 'node', target: 'node22', format: 'esm', minify: true, legalComments: 'linked', write: false, metafile: true,
  banner: { js: "import { createRequire as __createRequire } from 'node:module'; const require = __createRequire(import.meta.url);" } });
result.outputFiles.push({ path: path.join(output, 'actions.json'), contents: await readFile(path.join(directory, 'actions.json')) });
// The separately installed GrokBot package must carry its own workflow recipes.
result.outputFiles.push({ path: path.resolve(directory, '../grok-bot/skills/myman/references/agent-workflows.md'), contents: await readFile(path.resolve(directory, '../../docs/agent-workflows.md')) });
const packages = new Set(Object.keys(result.metafile.inputs).filter(p => p.includes('node_modules/')).map(p => {
  const parts = p.split('node_modules/').at(-1).split('/');
  return parts[0].startsWith('@') ? parts.slice(0, 2).join('/') : parts[0];
}));
let notices = await readFile(path.resolve(directory, '../../LICENSE'), 'utf8');
for (const name of [...packages].sort()) {
  const root = path.join(directory, 'node_modules', name);
  for (const file of await readdir(root)) {
    if (/^licen[sc]e(?:\..*)?$/i.test(file)) notices += `\n\n--- ${name} ---\n\n` + await readFile(path.join(root, file), 'utf8');
  }
}
result.outputFiles.push({ path: path.join(output, 'LICENSES.txt'), contents: Buffer.from(notices) });
const check = process.argv.includes('--check');
if (!check) await mkdir(output, { recursive: true });
for (const file of result.outputFiles) {
  if (check) {
    if (!(await readFile(file.path)).equals(Buffer.from(file.contents))) throw new Error('Brain companion bundle is stale; run npm run bundle.');
  } else {
    await mkdir(path.dirname(file.path), { recursive: true });
    await writeFile(file.path, file.contents);
  }
}
if (!check) {
  const expected = new Set(result.outputFiles.map(f => path.basename(f.path)));
  for (const name of await readdir(output)) if (!expected.has(name)) await unlink(path.join(output, name));
}
