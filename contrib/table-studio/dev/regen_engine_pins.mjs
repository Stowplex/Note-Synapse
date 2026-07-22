// Regenerates the ENGINE manifest entries in plugins/src/univer_bridge.js
// for an engine upgrade. Fetches every file from the primary mirror, prints
// ready-to-paste manifest lines with fresh byte counts and sha256 pins.
//
//   node dev/regen_engine_pins.mjs           # re-pin the current versions
//   node dev/regen_engine_pins.mjs 0.26.0    # target a new @univerjs version
//
// After pasting: bump ENGINE.version (e.g. univer-0.26.0-r1), run
// fetch_univer_mirror.sh, the harnesses, and plugins/build.sh.
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createHash } from 'node:crypto';

const require = createRequire(import.meta.url);
const bridge = require(join(dirname(fileURLToPath(import.meta.url)), '..', 'plugins', 'src', 'univer_bridge.js'));

const targetVersion = process.argv[2] || null;

function retarget(path) {
  if (!targetVersion) return path;
  return path.replace(/(@univerjs\/[a-z-]+@)[0-9.]+/, `$1${targetVersion}`);
}

for (const [kind, files] of [['js', bridge.ENGINE.js], ['css', bridge.ENGINE.css]]) {
  console.log(`    ${kind}: [`);
  for (const f of files) {
    const path = retarget(f.path);
    const url = bridge.MIRRORS[0] + path;
    const res = await fetch(url);
    if (!res.ok) {
      console.error(`FAILED ${url} -> HTTP ${res.status}`);
      process.exit(1);
    }
    const buf = Buffer.from(await res.arrayBuffer());
    const sha = createHash('sha256').update(buf).digest('hex');
    console.log(
      `      { name: '${f.name}', path: '${path}', bytes: ${buf.length}, sha256: '${sha}' },`
    );
  }
  console.log('    ],');
}
