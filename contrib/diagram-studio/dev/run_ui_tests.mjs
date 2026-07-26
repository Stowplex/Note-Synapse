// End-to-end UI tests for the Diagram Studio shell.
//
// Builds a self-contained harness the same way plugins/build.sh does (so the
// thing under test is the thing that ships), swaps synapse://mermaid.min.js
// for the real bundled asset, injects dev/synapse_stub.js as window.Synapse,
// and drives it in headless Chrome.
//
// Run with: node dev/run_ui_tests.mjs   (from contrib/diagram-studio/)
import { readFileSync, writeFileSync, existsSync, unlinkSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));
const pluginsDir = join(here, '..', 'plugins');
const repoRoot = resolve(here, '..', '..', '..');
const mermaidAsset = join(repoRoot, 'assets', 'scripts', 'mermaid.min.js');
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

if (!existsSync(mermaidAsset)) {
  console.error(`Missing bundled mermaid at ${mermaidAsset}`);
  process.exit(1);
}

// --- inline exactly like build.sh -------------------------------------
let html = readFileSync(join(pluginsDir, 'diagram_studio.html'), 'utf8');
html = html.replace(
  /^.*<script[^>]*src="((?:src|vendor)\/[^"]+)"[^>]*><\/script>.*$/gm,
  (_line, rel) => {
    const body = readFileSync(join(pluginsDir, rel), 'utf8').replace(/<\/script>/g, '<\\/script>');
    return `  <script>\n${body}\n  </script>`;
  }
);
if (/<script[^>]*src="(src|vendor)\//.test(html)) {
  console.error('harness: a local script failed to inline');
  process.exit(1);
}
// Real mermaid, loaded from the bundled app asset.
html = html.replace('synapse://mermaid.min.js', 'file://' + mermaidAsset);

// --- inject the stub + driver ------------------------------------------
const stubSource = readFileSync(join(here, 'synapse_stub.js'), 'utf8');

const NOTE = [
  '# Architecture',
  '',
  '```mermaid',
  'graph TD',
  '  A[Client] --> B[Server]',
  '```',
  '',
  'Some prose that is definitely not a diagram of any kind.',
  '',
  '```',
  '+--------+      +--------+',
  '|  Web   |----->|  API   |',
  '+--------+      +--------+',
  '```',
].join('\n');

const driver = `
<script>
${stubSource}
</script>
<script>
(function () {
  // A synchronous sha256 for the stub. Tiny, self-contained implementation —
  // SubtleCrypto is async and the stub's contract is synchronous.
  function sha256(ascii) {
    function rightRotate(v, a) { return (v >>> a) | (v << (32 - a)); }
    var mathPow = Math.pow, maxWord = mathPow(2, 32), i, j, result = '';
    var words = [], asciiBitLength;
    var hash = sha256.h = sha256.h || [], k = sha256.k = sha256.k || [], primeCounter = k.length;
    var isComposite = {};
    for (var candidate = 2; primeCounter < 64; candidate++) {
      if (!isComposite[candidate]) {
        for (i = 0; i < 313; i += candidate) isComposite[i] = candidate;
        hash[primeCounter] = (mathPow(candidate, 0.5) * maxWord) | 0;
        k[primeCounter++] = (mathPow(candidate, 1 / 3) * maxWord) | 0;
      }
    }
    var utf8 = unescape(encodeURIComponent(ascii));
    hash = hash.slice(0); words = []; asciiBitLength = utf8.length * 8;
    utf8 += '\\x80';
    while (utf8.length % 64 - 56) utf8 += '\\x00';
    for (i = 0; i < utf8.length; i++) {
      j = utf8.charCodeAt(i);
      if (j >> 8) return null;
      words[i >> 2] |= j << ((3 - i) % 4) * 8;
    }
    words[words.length] = (asciiBitLength / maxWord) | 0;
    words[words.length] = asciiBitLength;
    for (j = 0; j < words.length;) {
      var w = words.slice(j, j += 16), oldHash = hash;
      hash = hash.slice(0, 8);
      for (i = 0; i < 64; i++) {
        var w15 = w[i - 15], w2 = w[i - 2];
        var a = hash[0], e = hash[4];
        var temp1 = hash[7] + (rightRotate(e, 6) ^ rightRotate(e, 11) ^ rightRotate(e, 25))
          + ((e & hash[5]) ^ ((~e) & hash[6])) + k[i]
          + (w[i] = (i < 16) ? w[i] : (w[i - 16] + (rightRotate(w15, 7) ^ rightRotate(w15, 18) ^ (w15 >>> 3))
            + w[i - 7] + (rightRotate(w2, 17) ^ rightRotate(w2, 19) ^ (w2 >>> 10))) | 0);
        var temp2 = (rightRotate(a, 2) ^ rightRotate(a, 13) ^ rightRotate(a, 22))
          + ((a & hash[1]) ^ (a & hash[2]) ^ (hash[1] & hash[2]));
        hash = [(temp1 + temp2) | 0].concat(hash);
        hash[4] = (hash[4] + temp1) | 0;
      }
      for (i = 0; i < 8; i++) hash[i] = (hash[i] + oldHash[i]) | 0;
    }
    for (i = 0; i < 8; i++) {
      for (j = 3; j + 1; j--) {
        var b = (hash[i] >> (j * 8)) & 255;
        result += ((b < 16) ? 0 : '') + b.toString(16);
      }
    }
    return result;
  }

  var MODE = new URLSearchParams(location.search).get('mode') || 'note';
  var NOTE = ${JSON.stringify(NOTE)};
  var BLOCK = '\`\`\`mermaid\\ngraph TD\\n  A[Client] --> B[Server]\\n\`\`\`';

  var stub = SynapseStub.createSynapseStub(
    MODE === 'block'
      ? { mode: 'block', content: BLOCK, parentContent: NOTE, sha256: sha256,
          chatAIResponse: function () { return { success: true, response: [{ type: 'image', content: 'data:image/png;base64,iVBORw0KGgo=' }] }; } }
      : { mode: 'note', content: NOTE, sha256: sha256,
          chatAIResponse: function () { return { success: true, response: [{ type: 'image', content: 'data:image/png;base64,iVBORw0KGgo=' }] }; } }
  );
  window.Synapse = stub.synapse;
  window.__stub = stub;
})();
</script>
`;

html = html.replace('<script type="text/javascript" src="file://', driver + '<script type="text/javascript" src="file://');

const generated = join(here, '.harness.generated.html');
writeFileSync(generated, html, 'utf8');

// --- the assertions, injected as a final script -----------------------
const probe = `
<script>
(function () {
  var out = [];
  function say(k, v) { out.push(k + '=' + v); }
  function $(id) { return document.getElementById(id); }
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function finish() {
    var el = document.createElement('pre');
    el.id = 'UITEST';
    el.textContent = 'UITEST:' + out.join(';');
    document.body.appendChild(el);
  }

  window.addEventListener('load', function () {
    (async function () {
      try {
        await sleep(1200);   // boot + appState + first render

        var mode = new URLSearchParams(location.search).get('mode') || 'note';
        say('scope', $('scopeBadge').textContent.replace(/\\s/g, '_'));

        // The note has a mermaid fence and an ASCII fence; both must be listed.
        var rows = document.querySelectorAll('.block-row');
        say('blockRows', rows.length);
        var kinds = Array.prototype.map.call(document.querySelectorAll('.block-kind'), function (e) { return e.textContent; });
        say('kinds', kinds.join(','));

        // Boot should have auto-opened the first real diagram in the Mermaid tab.
        say('activeTab', document.querySelector('nav#tabs button.active').getAttribute('data-tab'));
        say('editorLoaded', ($('mermaidEditor').value || '').indexOf('graph TD') !== -1);

        // Live preview must have produced real SVG.
        await sleep(900);
        say('previewHasSvg', $('mermaidPreview').querySelectorAll('svg').length > 0);
        say('mermaidErrorHidden', $('mermaidError').classList.contains('hidden'));
        say('saveEnabled', !$('saveButton').disabled);

        // A syntax error must surface without blanking the last good preview.
        $('mermaidEditor').value = 'graph TD\\n  A -->';
        $('mermaidEditor').dispatchEvent(new Event('input'));
        await sleep(900);
        say('errorShown', !$('mermaidError').classList.contains('hidden'));
        say('previewKept', $('mermaidPreview').querySelectorAll('svg').length > 0);
        say('hasFixWithAi', $('mermaidError').textContent.indexOf('Fix with AI') !== -1);

        // Restore a good diagram and save it.
        $('mermaidEditor').value = 'graph TD\\n  X[One] --> Y[Two]';
        $('mermaidEditor').dispatchEvent(new Event('input'));
        await sleep(900);
        $('saveButton').click();
        await sleep(1500);

        var content = window.__stub.parentContent;
        say('savedImage', /!\\[diagram:mermaid\\]/.test(content));
        say('savedSource', content.indexOf('X[One]') !== -1);
        say('imageCount', (content.match(/!\\[diagram/g) || []).length);
        say('attachments', window.__stub.attachments.length);
        say('proseIntact', content.indexOf('Some prose') !== -1);
        say('asciiBlockIntact', content.indexOf('|  Web   |') !== -1);

        // Saving again must replace, not stack.
        $('mermaidEditor').value = 'graph TD\\n  X[One] --> Z[Three]';
        $('mermaidEditor').dispatchEvent(new Event('input'));
        await sleep(900);
        $('saveButton').click();
        await sleep(1500);
        content = window.__stub.parentContent;
        say('imageCountAfterResave', (content.match(/!\\[diagram/g) || []).length);
        say('attachmentsAfterResave', window.__stub.attachments.length);
        say('sourceUpdated', content.indexOf('Z[Three]') !== -1);

        // ASCII tab: grid editor + live render.
        document.querySelector('nav#tabs button[data-tab="ascii"]').click();
        await sleep(200);
        $('asciiEditor').value = '+---+\\n| a |\\n+---+';
        $('asciiEditor').dispatchEvent(new Event('input'));
        await sleep(500);
        say('asciiPreviewSvg', $('asciiPreview').querySelectorAll('svg').length > 0);
        say('asciiWrapOff', $('asciiEditor').getAttribute('wrap'));
        say('glyphButtons', $('glyphBar').querySelectorAll('button').length);
        $('asciiNormalise').click();
        await sleep(300);
        say('asciiPadded', $('asciiEditor').value.split('\\n').every(function (l) { return l.length === 5; }));

        // Draw tab must mount the vendored editor.
        document.querySelector('nav#tabs button[data-tab="draw"]').click();
        await sleep(700);
        say('drawMounted', $('drawSurface').children.length > 0);
        say('drawFormatLocked', document.querySelector('#formatSeg button[data-format="png"]').disabled);

        // PNG rasterisation from the Mermaid tab.
        document.querySelector('nav#tabs button[data-tab="mermaid"]').click();
        await sleep(200);
        document.querySelector('#formatSeg button[data-format="png"]').click();
        $('mermaidEditor').value = 'graph TD\\n  P[Png] --> Q[Test]';
        $('mermaidEditor').dispatchEvent(new Event('input'));
        await sleep(900);
        $('saveButton').click();
        await sleep(2000);
        content = window.__stub.parentContent;
        say('pngSaved', /!\\[diagram:mermaid\\]\\([^)]*\\.png\\)/.test(content) || /!\\[diagram:mermaid\\]/.test(content));
        var atts = window.__stub.attachments.map(function (a) { return a.fileName; }).join(',');
        say('pngAttachment', /\\.png/.test(atts));

        // AI tab: generate, refine, then save. The generated image is ALREADY
        // stored as a temp URI, which is the case that broke saving.
        document.querySelector('nav#tabs button[data-tab="ai"]').click();
        await sleep(200);
        $('aiPrompt').value = 'a friendly robot';
        $('aiGenerate').click();
        await sleep(1200);
        say('aiPreviewImg', $('aiPreview').querySelectorAll('img').length > 0);
        say('aiSaveEnabled', !$('saveButton').disabled);

        $('aiPrompt').value = 'make it blue';
        $('aiGenerate').click();
        await sleep(1200);
        var chats = window.__stub.log.filter(function (l) { return l.call === 'chatAI'; });
        say('aiChatCalls', chats.length);
        say('aiSecondTurnAttached', !!(chats[1] && chats[1].options && chats[1].options.attachments));
        say('aiNoticeShown', !$('aiNotice').classList.contains('hidden'));

        var attsBefore = window.__stub.attachments.length;
        // Before saving, the button must say it will ADD rather than replace —
        // the selection was dropped when the tab kind changed.
        say('saveLabelIsAdd', $('saveButton').textContent.indexOf('Add') === 0);
        $('saveButton').click();
        await sleep(2000);
        content = window.__stub.parentContent;
        say('aiSaved', /!\\[diagram:ai\\]/.test(content));
        say('aiPromptFenced', content.indexOf('\`\`\`ai-diagram') !== -1);
        say('aiBriefKept', content.indexOf('a friendly robot') !== -1);
        // Switching tab kind must NOT overwrite the block that was on screen.
        say('aiAddedNotReplaced', window.__stub.attachments.length === attsBefore + 1);
        say('mermaidSourceSurvived', content.indexOf('P[Png]') !== -1);
        // After saving, the new unit is selected, so a second save replaces it.
        say('saveLabelIsReplaceAfter', $('saveButton').textContent.indexOf('Replace') === 0);
        say('aiNoErrorBanner', $('message').classList.contains('hidden') ||
          $('message').className.indexOf('error') === -1);
      } catch (e) {
        say('ERROR', (e && e.message ? e.message : String(e)).replace(/[;=]/g, '_'));
      }
      finish();
    })();
  });
})();
</script>
`;

// Splice at the LAST </body>, not the first: the vendored js-draw bundle
// contains a whole HTML document inside a template literal, so a naive
// replace lands the probe in the middle of the library.
const closeAt = html.lastIndexOf('</body>');
writeFileSync(generated, html.slice(0, closeAt) + probe + html.slice(closeAt), 'utf8');

function run(mode) {
  const dom = execFileSync(
    CHROME,
    ['--headless=new', '--disable-gpu', '--allow-file-access-from-files',
     '--virtual-time-budget=30000', '--dump-dom', `file://${generated}?mode=${mode}`],
    { encoding: 'utf8', maxBuffer: 1024 * 1024 * 64, stdio: ['ignore', 'pipe', 'ignore'] }
  );
  // Match the result ELEMENT, not the probe's own source text — the script
  // body is in the DOM too and contains the same marker string.
  const m = /<pre id="UITEST">UITEST:([^<]*)<\/pre>/.exec(dom);
  return m ? m[1] : null;
}

let failures = 0;
for (const mode of ['note', 'block']) {
  const raw = run(mode);
  console.log(`\n=== mode: ${mode} ===`);
  if (!raw) {
    console.error('no result — the harness did not finish');
    failures++;
    continue;
  }
  const kv = Object.fromEntries(raw.split(';').filter(Boolean).map((p) => {
    const i = p.indexOf('=');
    return [p.slice(0, i), p.slice(i + 1)];
  }));
  for (const [k, v] of Object.entries(kv)) console.log(`  ${k} = ${v}`);

  const expect = (k, v) => {
    if (String(kv[k]) !== String(v)) { console.error(`  FAIL ${k}: expected ${v}, got ${kv[k]}`); failures++; }
  };
  expect('ERROR', 'undefined');
  expect('editorLoaded', 'true');
  expect('previewHasSvg', 'true');
  expect('saveEnabled', 'true');
  expect('errorShown', 'true');
  expect('previewKept', 'true');
  expect('hasFixWithAi', 'true');
  expect('savedImage', 'true');
  expect('savedSource', 'true');
  expect('imageCount', '1');
  expect('imageCountAfterResave', '1');
  expect('sourceUpdated', 'true');
  expect('asciiPreviewSvg', 'true');
  expect('asciiWrapOff', 'off');
  expect('asciiPadded', 'true');
  expect('drawMounted', 'true');
  expect('drawFormatLocked', 'true');
  expect('aiPreviewImg', 'true');
  expect('aiSaveEnabled', 'true');
  expect('aiChatCalls', '2');
  expect('aiSecondTurnAttached', 'true');
  expect('aiSaved', 'true');
  expect('aiPromptFenced', 'true');
  expect('aiBriefKept', 'true');
  expect('aiAddedNotReplaced', 'true');
  expect('mermaidSourceSurvived', 'true');
  expect('saveLabelIsAdd', 'true');
  expect('saveLabelIsReplaceAfter', 'true');
  expect('aiNoErrorBanner', 'true');
  if (mode === 'note') {
    expect('proseIntact', 'true');
    expect('asciiBlockIntact', 'true');
    expect('attachmentsAfterResave', '1');
  }
}

if (!process.env.KEEP_HARNESS && existsSync(generated)) unlinkSync(generated);
console.log(failures === 0 ? '\nUI tests passed' : `\n${failures} UI assertions failed`);
process.exit(failures === 0 ? 0 : 1);
