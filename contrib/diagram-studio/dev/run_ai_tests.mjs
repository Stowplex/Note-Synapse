// Offline tests for plugins/src/ai.js, driven through dev/synapse_stub.js.
// Run with: node dev/run_ai_tests.mjs   (from contrib/diagram-studio/)
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createHash } from 'node:crypto';

const require = createRequire(import.meta.url);
const here = dirname(fileURLToPath(import.meta.url));
const AI = require(join(here, '..', 'plugins', 'src', 'ai.js'));
const { createSynapseStub } = require(join(here, 'synapse_stub.js'));

const sha256 = (text) => createHash('sha256').update(text, 'utf8').digest('hex');

let failures = 0;
let passed = 0;
function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) passed++;
  else { failures++; console.error(`FAIL ${name}\n  expected: ${e}\n  actual:   ${a}`); }
}
function ok(name, cond) { check(name, !!cond, true); }
async function throws(name, fn, matcher) {
  try { await fn(); failures++; console.error(`FAIL ${name}: expected a rejection`); }
  catch (e) {
    if (matcher && !matcher.test(String(e.message))) {
      failures++; console.error(`FAIL ${name}\n  message did not match ${matcher}\n  actual: ${e.message}`);
    } else passed++;
  }
}

const PNG = 'data:image/png;base64,iVBORw0KGgo=';

// ---------------------------------------------------------------------
// Prompt building (pure)
// ---------------------------------------------------------------------
{
  const t = AI.emptyThread('');
  const p = AI.buildPrompt(t, 'a network diagram');
  ok('first turn includes the brief', p.indexOf('a network diagram') !== -1);
  ok('first turn has the style preamble', p.indexOf(AI.STYLE_PREAMBLE) === 0);
  ok('first turn does not mention revising', p.indexOf('revising') === -1);
}
{
  const t = { prompt: 'a network diagram', turns: [{ instruction: 'a network diagram' }], lastImageUri: 'u1' };
  const p = AI.buildPrompt(t, 'make the arrows thicker');
  ok('refinement mentions the original brief', p.indexOf('a network diagram') !== -1);
  ok('refinement states the change', p.indexOf('make the arrows thicker') !== -1);
  ok('refinement references the attachment', p.indexOf('attached') !== -1);
  ok('refinement asks to keep the rest', p.indexOf('Keep everything else') !== -1);
}
{
  // The instruction history must accumulate, so a backend that ignores the
  // attached image still produces a cumulative result rather than a fresh one.
  const t = {
    prompt: 'a flowchart',
    turns: [{ instruction: 'a flowchart' }, { instruction: 'add a database' }, { instruction: 'use blue' }],
    lastImageUri: 'u3',
  };
  const p = AI.buildPrompt(t, 'bigger labels');
  ok('history lists prior revisions', p.indexOf('add a database') !== -1 && p.indexOf('use blue') !== -1);
  ok('history is numbered in order', p.indexOf('1. add a database') !== -1 && p.indexOf('2. use blue') !== -1);
  ok('the brief is not repeated as a revision', (p.match(/a flowchart/g) || []).length === 1);
  ok('new instruction is last', p.lastIndexOf('bigger labels') > p.lastIndexOf('use blue'));
}

// ---------------------------------------------------------------------
// Response parsing (pure)
// ---------------------------------------------------------------------
check('extract multi_part image', AI.extractParts([{ type: 'image', content: PNG }]).image, { kind: 'dataUri', value: PNG });
check('extract multi_part text', AI.extractParts([{ type: 'text', content: 'hi' }]).text, 'hi');
check('extract picks the first image only',
  AI.extractParts([{ type: 'image', content: 'a' }, { type: 'image', content: 'b' }]).image.value, 'a');
check('extract string-mode temp uri',
  AI.extractParts('here you go\n![Generated Image](synapsetemp:///g.png)').image,
  { kind: 'uri', value: 'synapsetemp:///g.png' });
check('extract string-mode strips the image from text',
  AI.extractParts('here you go\n![Generated Image](synapsetemp:///g.png)').text, 'here you go');
check('extract handles no image', AI.extractParts([{ type: 'text', content: 'sorry' }]).image, null);
check('extract handles null', AI.extractParts(null).image, null);
check('mime of data uri', AI.mimeOfDataUri('data:image/jpeg;base64,xx'), 'image/jpeg');
check('mime default', AI.mimeOfDataUri('nonsense'), 'image/png');
check('base64 of data uri', AI.base64OfDataUri(PNG), 'iVBORw0KGgo=');

// ---------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------
let clock = 0;
const now = () => ++clock;

{
  const stub = createSynapseStub({
    mode: 'note', content: 'x', sha256,
    chatAIResponse: () => ({ success: true, response: [{ type: 'image', content: PNG }] }),
  });
  const s = AI.createSession({ synapse: stub.synapse, now });

  const r1 = await s.generate('k1', 'a network diagram');
  ok('turn 1 produced a temp uri', /^synapsetemp:\/\//.test(r1.imageUri));
  check('turn 1 did not attach a prior image', r1.usedPriorImage, false);
  check('turn 1 index', r1.turn, 1);

  const call1 = stub.log.filter((l) => l.call === 'chatAI')[0];
  check('turn 1 uses the image_gen hint', call1.options.model_hint, ['image_gen']);
  check('turn 1 asks for multi_part', call1.options.response_type, 'multi_part');
  ok('turn 1 sends no attachments', !call1.options.attachments);

  const r2 = await s.generate('k1', 'make the arrows thicker');
  check('turn 2 attached the prior image', r2.usedPriorImage, true);
  check('turn 2 index', r2.turn, 2);
  const call2 = stub.log.filter((l) => l.call === 'chatAI')[1];
  check('turn 2 attaches exactly the previous render', call2.options.attachments, [r1.imageUri]);
  ok('turn 2 prompt carries the history', call2.prompt.indexOf('a network diagram') !== -1);

  check('thread retains both turns', s.getThread('k1').turns.length, 2);
  check('thread tracks the latest image', s.getThread('k1').lastImageUri, r2.imageUri);
}

{
  // A model that returns only text must surface an error, not a blank image.
  const stub = createSynapseStub({
    mode: 'note', content: 'x', sha256,
    chatAIResponse: () => ({ success: true, response: [{ type: 'text', content: 'I cannot draw that' }] }),
  });
  const s = AI.createSession({ synapse: stub.synapse, now });
  await throws('no image in the reply rejects', () => s.generate('k', 'draw'), /without an image.*cannot draw/i);
}

{
  const stub = createSynapseStub({
    mode: 'note', content: 'x', sha256,
    chatAIResponse: () => ({ success: false, error: 'quota exceeded' }),
  });
  const s = AI.createSession({ synapse: stub.synapse, now });
  await throws('a failed call rejects with the reason', () => s.generate('k', 'draw'), /quota exceeded/);
}

{
  const stub = createSynapseStub({ mode: 'note', content: 'x', sha256 });
  const s = AI.createSession({ synapse: stub.synapse, now });
  await throws('an empty brief rejects', () => s.generate('k', '   '), /Describe the diagram/);
}

{
  // String-mode responses (no multi_part support) still work.
  const stub = createSynapseStub({
    mode: 'note', content: 'x', sha256,
    chatAIResponse: () => ({ success: true, response: 'done\n![Generated Image](synapsetemp:///g.png)' }),
  });
  const s = AI.createSession({ synapse: stub.synapse, now });
  const r = await s.generate('k', 'draw');
  check('string mode yields the uri directly', r.imageUri, 'synapsetemp:///g.png');
  ok('string mode saved no extra temp file', !stub.log.some((l) => l.call === 'saveTemp'));
}

{
  // Persistence round-trips, and must merge rather than clobber other state.
  const state = { someOtherAppSetting: 42 };
  const stub = createSynapseStub({
    mode: 'note', content: 'x', sha256, appState: state,
    chatAIResponse: () => ({ success: true, response: [{ type: 'image', content: PNG }] }),
  });
  const s = AI.createSession({ synapse: stub.synapse, now });
  await s.generate('k1', 'a diagram');
  await s.save();

  const s2 = AI.createSession({ synapse: stub.synapse, now });
  await s2.load();
  check('threads survive a reload', s2.getThread('k1').turns.length, 1);
  check('unrelated app state is preserved', (await stub.synapse.loadAppState()).data.someOtherAppSetting, 42);
}

{
  // The thread map must not grow without bound: storeAppState is one blob.
  const stub = createSynapseStub({
    mode: 'note', content: 'x', sha256,
    chatAIResponse: () => ({ success: true, response: [{ type: 'image', content: PNG }] }),
  });
  const s = AI.createSession({ synapse: stub.synapse, now });
  for (let i = 0; i < AI.MAX_THREADS + 5; i++) await s.generate('key' + i, 'draw ' + i);
  check('thread count is capped', s.threadCount, AI.MAX_THREADS);
  check('the oldest thread was evicted', s.getThread('key0'), null);
  ok('the newest thread survives', !!s.getThread('key' + (AI.MAX_THREADS + 4)));
}

{
  // Turn history is capped too, or the prompt grows forever.
  const stub = createSynapseStub({
    mode: 'note', content: 'x', sha256,
    chatAIResponse: () => ({ success: true, response: [{ type: 'image', content: PNG }] }),
  });
  const s = AI.createSession({ synapse: stub.synapse, now });
  for (let i = 0; i < AI.MAX_TURNS + 4; i++) await s.generate('k', 'step ' + i);
  check('turns are capped', s.getThread('k').turns.length, AI.MAX_TURNS);
  check('the most recent turn is kept', s.getThread('k').turns[AI.MAX_TURNS - 1].instruction, 'step ' + (AI.MAX_TURNS + 3));
}

{
  // A corrupt saved blob must not stop the tab loading.
  const stub = createSynapseStub({ mode: 'note', content: 'x', sha256, appState: { aiThreads: 'not an object' } });
  const s = AI.createSession({ synapse: stub.synapse, now });
  await s.load();
  check('corrupt state loads as empty', s.threadCount, 0);
}

{
  const stub = createSynapseStub({
    mode: 'note', content: 'x', sha256,
    chatAIResponse: () => ({ success: true, response: [{ type: 'image', content: PNG }] }),
  });
  const s = AI.createSession({ synapse: stub.synapse, now });
  await s.generate('k', 'first');
  s.reset('k', 'fresh brief');
  check('reset clears history', s.getThread('k').turns.length, 0);
  check('reset clears the prior image', s.getThread('k').lastImageUri, null);
  const r = await s.generate('k', 'second');
  check('after reset nothing is attached', r.usedPriorImage, false);
}

console.log(`\n${passed} passed, ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
