import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const here = dirname(fileURLToPath(import.meta.url));
const F = require(join(here, '..', 'plugins', 'src', 'formula_core.js'));
const W = require(join(here, '..', 'plugins', 'src', 'writeback.js'));

let passed = 0;
let failed = 0;

function check(name, actual, expected) {
  if (JSON.stringify(actual) === JSON.stringify(expected)) {
    passed++;
  } else {
    failed++;
    console.error(`FAIL ${name}\n  expected: ${JSON.stringify(expected)}\n  actual:   ${JSON.stringify(actual)}`);
  }
}

function ok(name, condition, detail = '') {
  if (condition) {
    passed++;
  } else {
    failed++;
    console.error(`FAIL ${name}${detail ? `\n  ${detail}` : ''}`);
  }
}

function harness(content, noteOverrides = {}) {
  let stored = content;
  let writes = 0;
  let nextResponse = null;
  const note = {
    id: 'note-1',
    title: 'Math',
    content,
    ...noteOverrides,
  };
  const synapse = {
    runQuery: async () => ({ success: true, data: [{ content: stored }] }),
    updateNotes: async (requests) => {
      writes++;
      if (nextResponse) return nextResponse;
      stored = requests[0].modification.content.text;
      return { success: true, updatedCount: 1 };
    },
  };
  return {
    note,
    synapse,
    writer: W.createWriter({ synapse, core: F, note }),
    get content() { return stored; },
    set content(value) { stored = value; },
    get writes() { return writes; },
    rejectNext(response) { nextResponse = response; },
  };
}

{
  const h = harness('Before \\(x\\) after');
  const unit = F.scanFormulas(h.content)[0];
  const result = await h.writer.save({
    target: F.createTarget(h.content, unit),
    body: 'y',
    kind: 'inline',
  });
  ok('existing formula save succeeds', result.success);
  check('existing formula replaced', h.content, 'Before \\(y\\) after');
  check('one update per save', h.writes, 1);
}

{
  const original = 'Before \\(x\\) after';
  const h = harness(original);
  const target = F.createTarget(original, F.scanFormulas(original)[0]);
  h.content = 'New first line\n' + original;
  const result = await h.writer.save({ target, body: 'z', kind: 'inline' });
  ok('shifted formula safely relocates', result.relocated);
  check('external edit survives relocation', h.content, 'New first line\nBefore \\(z\\) after');
}

{
  const original = '\\(x\\) \\(x\\)';
  const h = harness(original);
  const target = F.createTarget(original, F.scanFormulas(original)[0]);
  target.originalOffset = 999;
  target.anchorBefore = '';
  target.anchorAfter = '';
  let error = '';
  try {
    await h.writer.save({ target, body: 'z', kind: 'inline' });
  } catch (caught) {
    error = caught.message;
  }
  ok('ambiguous relocation aborts', /several places/.test(error));
  check('ambiguous relocation performs no write', h.writes, 0);
}

{
  const h = harness('$x$');
  const unit = F.scanFormulas(h.content, { legacySingleDollar: true })[0];
  const result = await h.writer.save({
    target: F.createTarget(h.content, unit),
    body: 'x+1',
    kind: 'inline',
  });
  ok('legacy normalization is reported', result.normalizedLegacy);
  check('legacy formula becomes canonical', h.content, '\\(x+1\\)');
}

{
  const h = harness('\\[x\\]');
  const unit = F.scanFormulas(h.content)[0];
  await h.writer.save({
    target: F.createTarget(h.content, unit),
    body: '',
    kind: 'display',
  });
  check('removing the only formula can empty a note', h.content, '');
  check('empty-note removal is one update', h.writes, 1);
}

{
  const h = harness('Paragraph');
  await h.writer.save({ target: { mode: 'append' }, body: 'x=1', kind: 'display' });
  check('whole-note add appends display formula', h.content, 'Paragraph\n\n\\[\nx=1\n\\]');
}

{
  const source = 'A \\(x\\) remains one paragraph.\n\nNext';
  const h = harness(source);
  const unit = F.scanFormulas(source)[0];
  await h.writer.save({
    target: F.createTarget(source, unit),
    body: 'x',
    kind: 'inline',
    insertBelow: 'x=2',
  });
  check(
    'result below does not split inline paragraph',
    h.content,
    'A \\(x\\) remains one paragraph.\n\n\\[\nx=2\n\\]\n\nNext',
  );
  check('result below is one note update', h.writes, 1);
}

{
  const h = harness('\\[x\\]');
  h.synapse.runQuery = async () => ({ success: false, error: 'too large' });
  let error = '';
  try {
    await h.writer.save({
      target: F.createTarget(h.content, F.scanFormulas(h.content)[0]),
      body: 'y',
      kind: 'display',
    });
  } catch (caught) {
    error = caught.message;
  }
  ok('fresh read failure aborts', /refused to overwrite/.test(error));
  check('fresh read failure performs no write', h.writes, 0);
}

{
  const h = harness('\\[x\\]');
  h.rejectNext({ success: true, updatedCount: 0, errors: [{ error: 'stale block' }] });
  let error = '';
  try {
    await h.writer.save({
      target: F.createTarget(h.content, F.scanFormulas(h.content)[0]),
      body: 'y',
      kind: 'display',
    });
  } catch (caught) {
    error = caught.message;
  }
  ok('updatedCount zero is a failed write', /stale block/.test(error));
}

console.log(`Formula writeback: ${passed} passed, ${failed} failed`);
if (failed) process.exit(1);
