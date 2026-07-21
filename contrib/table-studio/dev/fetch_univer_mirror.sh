#!/bin/bash
# Populates dev/univer-mirror/ with the exact engine files the plugin pins
# (see plugins/src/univer_bridge.js), so the dev harness and auto smoke can
# run without touching the real CDNs. The mirror is gitignored.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p univer-mirror

node - <<'EOF'
const fs = require('fs');
const path = require('path');
const bridge = require('../plugins/src/univer_bridge.js');
const { createHash } = require('crypto');

const files = bridge.ENGINE.js.concat(bridge.ENGINE.css);
(async () => {
  for (const f of files) {
    const dest = path.join('univer-mirror', f.name);
    if (fs.existsSync(dest)) {
      const hex = createHash('sha256').update(fs.readFileSync(dest)).digest('hex');
      if (hex === f.sha256) { console.log('ok      ' + f.name); continue; }
    }
    let done = false;
    for (const url of bridge.engineUrls(f)) {
      try {
        const res = await fetch(url);
        if (!res.ok) throw new Error('HTTP ' + res.status);
        const buf = Buffer.from(await res.arrayBuffer());
        const hex = createHash('sha256').update(buf).digest('hex');
        if (hex !== f.sha256) throw new Error('sha256 mismatch');
        fs.writeFileSync(dest, buf);
        console.log('fetched ' + f.name + ' (' + buf.length + ' bytes)');
        done = true;
        break;
      } catch (e) {
        console.warn('  ' + url + ' -> ' + e.message);
      }
    }
    if (!done) { console.error('FAILED ' + f.name); process.exit(1); }
  }
  console.log('Mirror complete.');
})();
EOF
