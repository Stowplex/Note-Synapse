// Offline tests for plugins/src/writeback.js, driven through dev/synapse_stub.js.
// Run with: node dev/run_writeback_tests.mjs   (from contrib/diagram-studio/)
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createHash } from 'node:crypto';

const require = createRequire(import.meta.url);
const here = dirname(fileURLToPath(import.meta.url));
const B = require(join(here, '..', 'plugins', 'src', 'blocks.js'));
const W = require(join(here, '..', 'plugins', 'src', 'writeback.js'));
const { createSynapseStub, ATTACH_DIR } = require(join(here, 'synapse_stub.js'));

const sha256 = (text) => createHash('sha256').update(text, 'utf8').digest('hex');

let failures = 0;
let passed = 0;

function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) passed++;
  else {
    failures++;
    console.error(`FAIL ${name}\n  expected: ${e}\n  actual:   ${a}`);
  }
}
function ok(name, cond) { check(name, !!cond, true); }
async function throws(name, fn, matcher) {
  try {
    await fn();
    failures++;
    console.error(`FAIL ${name}\n  expected a rejection, got success`);
  } catch (e) {
    if (matcher && !matcher.test(String(e.message))) {
      failures++;
      console.error(`FAIL ${name}\n  message did not match ${matcher}\n  actual: ${e.message}`);
    } else passed++;
  }
}

const SVG = '<svg xmlns="http://www.w3.org/2000/svg"><text>café</text></svg>';
let clock = 1000;
const now = () => ++clock;

function writerFor(stub) {
  return W.createWriter({ synapse: stub.synapse, blocks: B, note: stub.note, now });
}

// =====================================================================
// BLOCK SCOPE
// =====================================================================
{
  const parent = ['# Title', '', '```mermaid', 'graph TD', '```', '', 'Tail.'].join('\n');
  const block = '```mermaid\ngraph TD\n```';
  const stub = createSynapseStub({ mode: 'block', content: block, parentContent: parent, sha256 });
  const writer = writerFor(stub);

  ok('block: detected as block scope', writer.isBlockScope);
  check('block: attachments target the parent', writer.attachmentNoteId, 'parent-note-1');

  const unit = B.scanBlocks(writer.initialContent())[0];
  const res = await writer.saveUnit({ kind: 'mermaid', unit, body: 'graph TD', image: { format: 'svg', text: SVG } });

  ok('block: ref is a temp uri', W.isTempUri(res.ref));
  check(
    'block: parent note spliced correctly',
    stub.parentContent,
    `# Title\n\n![diagram:mermaid](${res.ref})\n\n\`\`\`mermaid\ngraph TD\n\`\`\`\n\nTail.`
  );
  check('block: exactly one attachment promoted', stub.attachments.length, 1);
  check(
    'block: promoted name is content-addressed',
    stub.attachments[0].fileName,
    `parent-note-1_${sha256(res.ref)}.svg`
  );
  // One updateNotes call, not three.
  check('block: single write call', stub.log.filter((l) => l.call === 'updateNotes').length, 1);
  ok('block: never used exportNotes to place the image', !stub.log.some((l) => l.call === 'exportNotes'));

  // Re-render: the host must prune the superseded render.
  const unit2 = B.scanBlocks(stub.note.content)[0];
  check('block: rescan finds our render', unit2.renderRef, res.ref);
  const res2 = await writer.saveUnit({ kind: 'mermaid', unit: unit2, body: 'graph LR', image: { format: 'svg', text: SVG + '<!--2-->' } });
  check('block: still one attachment after re-render', stub.attachments.length, 1);
  check('block: attachment is the new render', stub.attachments[0].fileName, `parent-note-1_${sha256(res2.ref)}.svg`);
  check('block: only one image in the note', (stub.parentContent.match(/!\[diagram/g) || []).length, 1);
  check('block: body updated', stub.parentContent.indexOf('graph LR') !== -1, true);
  check('block: tail intact', stub.parentContent.endsWith('\n\nTail.'), true);
}

{
  // Insert position below.
  const parent = '```mermaid\ngraph TD\n```';
  const stub = createSynapseStub({ mode: 'block', content: parent, parentContent: parent, sha256 });
  const writer = writerFor(stub);
  const unit = B.scanBlocks(writer.initialContent())[0];
  const res = await writer.saveUnit({ kind: 'mermaid', unit, body: 'graph TD', position: 'below', image: { format: 'svg', text: SVG } });
  check('block: image below the source', stub.parentContent, '```mermaid\ngraph TD\n```\n\n![diagram:mermaid](' + res.ref + ')');
}

{
  // PNG goes through the binary channel.
  const parent = '```mermaid\ngraph TD\n```';
  const stub = createSynapseStub({ mode: 'block', content: parent, parentContent: parent, sha256 });
  const writer = writerFor(stub);
  const unit = B.scanBlocks(writer.initialContent())[0];
  const res = await writer.saveUnit({
    kind: 'mermaid', unit, body: 'graph TD',
    image: { format: 'png', data: 'data:image/png;base64,QUJD' },
  });
  check('block: png ref extension', res.ref.slice(-4), '.png');
  const saved = stub.log.find((l) => l.call === 'saveTemp');
  check('block: png saved with the right mime', saved.mimeType, 'image/png');
  check('block: data uri prefix stripped', stub.temps[res.ref].raw, 'QUJD');
}

{
  // A refused write must surface, not silently succeed.
  const parent = '```mermaid\ngraph TD\n```';
  const stub = createSynapseStub({ mode: 'block', content: parent, parentContent: parent, sha256, declineWrites: true });
  const writer = writerFor(stub);
  const unit = B.scanBlocks(writer.initialContent())[0];
  await throws('block: declined write rejects', () => writer.saveUnit({
    kind: 'mermaid', unit, body: 'graph TD', image: { format: 'svg', text: SVG },
  }), /not updated|declined/i);
}

// =====================================================================
// WHOLE NOTE
// =====================================================================
{
  const parent = ['# Title', '', '```mermaid', 'graph TD', '```', '', 'Tail.'].join('\n');
  const stub = createSynapseStub({ mode: 'note', content: parent, sha256 });
  const writer = writerFor(stub);

  ok('note: not block scope', !writer.isBlockScope);
  const unit = B.scanBlocks(writer.initialContent())[0];
  const res = await writer.saveUnit({ kind: 'mermaid', unit, body: 'graph TD', image: { format: 'svg', text: SVG } });

  ok('note: ref is a bare filename', !W.isTempUri(res.ref) && res.ref.indexOf('/') === -1);
  ok('note: ref carries the host uuid rename', /^diagram-mermaid-\d+_uuid\d+\.svg$/.test(res.ref));
  check(
    'note: content spliced correctly',
    stub.parentContent,
    `# Title\n\n![diagram:mermaid](${res.ref})\n\n\`\`\`mermaid\ngraph TD\n\`\`\`\n\nTail.`
  );
  check('note: one attachment', stub.attachments.length, 1);
  // The SVG must survive the base64 round trip including non-ASCII.
  check('note: stored svg is intact utf-8', Buffer.from(stub.files[ATTACH_DIR + res.ref], 'base64').toString('utf8'), SVG);
  check('note: three calls (attach, discover, write)', stub.log.filter((l) => l.call === 'updateNotes').length, 2);
  ok('note: used exportNotes to discover the stored name', stub.log.some((l) => l.call === 'exportNotes'));

  // Re-render must clean up its own predecessor.
  const unit2 = B.scanBlocks(stub.parentContent)[0];
  check('note: rescan finds our render', unit2.renderRef, res.ref);
  const res2 = await writer.saveUnit({ kind: 'mermaid', unit: unit2, body: 'graph LR', image: { format: 'svg', text: SVG } });
  check('note: stale attachment removed', stub.attachments.length, 1);
  check('note: remaining attachment is the new one', stub.attachments[0].fileName, res2.ref);
  check('note: only one image in the note', (stub.parentContent.match(/!\[diagram/g) || []).length, 1);
}

{
  // A user's own attachment must never be collected.
  const parent = ['![my sketch](photo.png)', '', '```mermaid', 'graph TD', '```'].join('\n');
  const stub = createSynapseStub({ mode: 'note', content: parent, sha256 });
  const writer = writerFor(stub);
  const unit = B.scanBlocks(writer.initialContent())[0];
  check('note: user image is not part of the unit', unit.renderRef, null);
  await writer.saveUnit({ kind: 'mermaid', unit, body: 'graph TD', image: { format: 'svg', text: SVG } });
  const removals = stub.log.filter((l) => l.call === 'updateNotes' && l.modification.attachments && l.modification.attachments.removed);
  check('note: nothing was removed', removals.length, 0);
  ok('note: user image survives', stub.parentContent.indexOf('![my sketch](photo.png)') !== -1);
}

{
  // Stale-read guard: a failed re-read must abort, never write the snapshot.
  const parent = ['```mermaid', 'graph TD', '```'].join('\n');
  const stub = createSynapseStub({ mode: 'note', content: parent, sha256, failRunQuery: true });
  const writer = writerFor(stub);
  const unit = B.scanBlocks(writer.initialContent())[0];
  await throws('note: unreadable note aborts the save', () => writer.saveUnit({
    kind: 'mermaid', unit, body: 'graph LR', image: { format: 'svg', text: SVG },
  }), /re-read|nothing was written/i);
  check('note: content untouched after abort', stub.parentContent, parent);
}

{
  // The note changed underneath us but the block is still there: relocate it
  // and splice into the FRESH content, preserving the other edit.
  const parent = ['# Title', '', '```mermaid', 'graph TD', '```'].join('\n');
  const stub = createSynapseStub({ mode: 'note', content: parent, sha256 });
  const writer = writerFor(stub);
  const unit = B.scanBlocks(writer.initialContent())[0];

  // Simulate an edit elsewhere: a paragraph added above, shifting every offset.
  await stub.synapse.updateNotes([{
    id: 'parent-note-1',
    modification: { content: { action: 'replace', text: '# Title\n\nA new paragraph.\n\n```mermaid\ngraph TD\n```' } },
  }]);

  const res = await writer.saveUnit({ kind: 'mermaid', unit, body: 'graph TD', image: { format: 'svg', text: SVG } });
  ok('note: concurrent edit preserved', stub.parentContent.indexOf('A new paragraph.') !== -1);
  check(
    'note: spliced at the relocated block',
    stub.parentContent,
    `# Title\n\nA new paragraph.\n\n![diagram:mermaid](${res.ref})\n\n\`\`\`mermaid\ngraph TD\n\`\`\``
  );
}

{
  // The block is gone entirely: refuse rather than guess.
  const parent = ['```mermaid', 'graph TD', '```'].join('\n');
  const stub = createSynapseStub({ mode: 'note', content: parent, sha256 });
  const writer = writerFor(stub);
  const unit = B.scanBlocks(writer.initialContent())[0];
  await stub.synapse.updateNotes([{
    id: 'parent-note-1',
    modification: { content: { action: 'replace', text: 'The diagram is gone now.' } },
  }]);
  await throws('note: deleted block aborts the save', () => writer.saveUnit({
    kind: 'mermaid', unit, body: 'graph TD', image: { format: 'svg', text: SVG },
  }), /no longer be found/i);
  check('note: content untouched', stub.parentContent, 'The diagram is gone now.');
}

{
  // Creating a brand new diagram at a chosen insert point.
  const parent = ['# Title', '', '```mermaid', 'graph TD', '```', '', 'Tail.'].join('\n');
  const stub = createSynapseStub({ mode: 'note', content: parent, sha256 });
  const writer = writerFor(stub);
  const anchor = B.scanBlocks(writer.initialContent())[0];
  const res = await writer.saveUnit({
    kind: 'mermaid', unit: null, body: 'graph LR\nX-->Y',
    at: { unit: anchor, where: 'after' },
    image: { format: 'svg', text: SVG },
  });
  check(
    'note: new diagram inserted after the anchor',
    stub.parentContent,
    '# Title\n\n```mermaid\ngraph TD\n```\n\n' +
      `![diagram:mermaid](${res.ref})\n\n\`\`\`mermaid\ngraph LR\nX-->Y\n\`\`\`` +
      '\n\nTail.'
  );
  check('note: two diagrams now', B.scanBlocks(stub.parentContent).length, 2);
}

// =====================================================================
// An already-stored image (the AI tab)
// =====================================================================
{
  // The AI session saveTemp's its own image so it can preview it and feed it
  // back as the next turn's attachment. Saving must reuse that URI rather than
  // trying to re-derive bytes it was never given.
  const parent = '```ai-diagram\na robot\n```';
  const stub = createSynapseStub({ mode: 'block', content: parent, parentContent: parent, sha256 });
  const writer = writerFor(stub);
  const pre = await stub.synapse.saveTemp({ binary: 'QUJD' }, 'image/png');

  const unit = B.scanBlocks(writer.initialContent())[0];
  const res = await writer.saveUnit({
    kind: 'ai', unit, body: 'a robot',
    image: { format: 'png', uri: pre.uri },
  });

  check('ai/block: reuses the existing temp uri', res.ref, pre.uri);
  check('ai/block: no second saveTemp', stub.log.filter((l) => l.call === 'saveTemp').length, 1);
  check('ai/block: written into the note', stub.parentContent,
    `![diagram:ai](${pre.uri})\n\n\`\`\`ai-diagram\na robot\n\`\`\``);
  check('ai/block: promoted to an attachment', stub.attachments.length, 1);
  check('ai/block: content-addressed name', stub.attachments[0].fileName, `parent-note-1_${sha256(pre.uri)}.png`);
}

{
  // Whole-note: the temp URI is attached directly, and the host promotes it
  // under the TEMP FILE's own name — so that is the stem to rediscover.
  const parent = '```ai-diagram\na robot\n```';
  const stub = createSynapseStub({ mode: 'note', content: parent, sha256 });
  const writer = writerFor(stub);
  const pre = await stub.synapse.saveTemp({ binary: 'QUJD' }, 'image/png');

  const unit = B.scanBlocks(writer.initialContent())[0];
  const res = await writer.saveUnit({
    kind: 'ai', unit, body: 'a robot',
    image: { format: 'png', uri: pre.uri },
  });

  ok('ai/note: ref is a bare filename', !W.isTempUri(res.ref) && res.ref.indexOf('/') === -1);
  ok('ai/note: named after the temp file, not our stamp', res.ref.indexOf('syn_') === 0);
  ok('ai/note: kept the png extension', /\.png$/.test(res.ref));
  check('ai/note: one attachment', stub.attachments.length, 1);
  check('ai/note: written into the note', stub.parentContent,
    `![diagram:ai](${res.ref})\n\n\`\`\`ai-diagram\na robot\n\`\`\``);

  // A second generation must still replace rather than accumulate.
  const pre2 = await stub.synapse.saveTemp({ binary: 'REVG' }, 'image/png');
  const unit2 = B.scanBlocks(stub.parentContent)[0];
  const res2 = await writer.saveUnit({
    kind: 'ai', unit: unit2, body: 'a robot',
    image: { format: 'png', uri: pre2.uri },
  });
  check('ai/note: stale attachment collected', stub.attachments.length, 1);
  check('ai/note: attachment is the new image', stub.attachments[0].fileName, res2.ref);
  check('ai/note: one image in the note', (stub.parentContent.match(/!\[diagram/g) || []).length, 1);
}

{
  // An empty image payload must fail loudly rather than calling saveTemp with
  // nothing, which is what produced "requires either data.text or data.binary".
  const parent = '```mermaid\ngraph TD\n```';
  const stub = createSynapseStub({ mode: 'block', content: parent, parentContent: parent, sha256 });
  const writer = writerFor(stub);
  const unit = B.scanBlocks(writer.initialContent())[0];
  await throws('empty image payload rejects clearly', () => writer.saveUnit({
    kind: 'mermaid', unit, body: 'graph TD', image: { format: 'png' },
  }), /no rendered image/i);
  check('empty payload never reached saveTemp', stub.log.filter((l) => l.call === 'saveTemp').length, 0);
  check('empty payload left the note alone', stub.parentContent, parent);
}

// =====================================================================
// Reading a render back (Draw round-trip)
// =====================================================================
{
  // Block scope: content-addressed lookup through crypto.digest.
  const parent = '```jsdraw\n```';
  const stub = createSynapseStub({ mode: 'block', content: parent, parentContent: parent, sha256 });
  const writer = writerFor(stub);
  const unit = B.scanBlocks(writer.initialContent())[0];
  const res = await writer.saveUnit({ kind: 'draw', unit, body: '', image: { format: 'svg', text: SVG } });

  const back = await writer.readRender(res.ref);
  ok('draw/block: render read back', !!back);
  check('draw/block: bytes round-trip', back.text, SVG);
  ok('draw/block: resolved via the sha256 name', back.fileName === `parent-note-1_${sha256(res.ref)}.svg`);
  ok('draw/block: used an absolute path', back.path.indexOf('/') === 0);
}

{
  // Whole note: bare filename lookup.
  const parent = '![diagram:draw](placeholder.svg)';
  const stub = createSynapseStub({ mode: 'note', content: parent, sha256 });
  const writer = writerFor(stub);
  const unit = B.scanBlocks(writer.initialContent())[0];
  check('draw/note: solo image is a draw unit', unit.kind, 'draw');
  const res = await writer.saveUnit({ kind: 'draw', unit, body: '', image: { format: 'svg', text: SVG } });
  const back = await writer.readRender(res.ref);
  ok('draw/note: render read back', !!back);
  check('draw/note: bytes round-trip', back.text, SVG);
  check('draw/note: note holds only the image', stub.parentContent, `![diagram:draw](${res.ref})`);
}

{
  // The rendered `exportNotes().markdown` must never reach the note. The stub
  // prefixes it with a section heading exactly so this leak would show up.
  const parent = ['```mermaid', 'graph TD', '```'].join('\n');
  const stub = createSynapseStub({ mode: 'note', content: parent, sha256 });
  const writer = writerFor(stub);
  const unit = B.scanBlocks(writer.initialContent())[0];
  await writer.saveUnit({ kind: 'mermaid', unit, body: 'graph TD', image: { format: 'svg', text: SVG } });
  ok('note: rendered export never leaks into content', stub.parentContent.indexOf('## Fake Note') === -1);

  // readAttachment's contract is base64; `text` is the decoded convenience.
  const back = await writer.readRender(B.scanBlocks(stub.parentContent)[0].renderRef);
  check('read: data stays base64', back.data, Buffer.from(SVG, 'utf8').toString('base64'));
  check('read: text is decoded utf-8', back.text, SVG);
}

{
  // An unresolvable ref must return null, not throw and not silently succeed.
  const stub = createSynapseStub({ mode: 'note', content: 'x', sha256 });
  const writer = writerFor(stub);
  check('read: missing ref resolves to null', await writer.readRender('nope.svg'), null);
  check('read: empty ref resolves to null', await writer.readRender(null), null);
}

// =====================================================================
console.log(`\n${passed} passed, ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
