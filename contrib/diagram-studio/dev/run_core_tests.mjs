// Offline unit tests for plugins/src/blocks.js.
// Run with: node dev/run_core_tests.mjs   (from contrib/diagram-studio/)
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const here = dirname(fileURLToPath(import.meta.url));
const B = require(join(here, '..', 'plugins', 'src', 'blocks.js'));
const A = require(join(here, '..', 'plugins', 'src', 'render_ascii.js'));

let failures = 0;
let passed = 0;

function check(name, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) {
    passed++;
  } else {
    failures++;
    console.error(`FAIL ${name}\n  expected: ${e}\n  actual:   ${a}`);
  }
}

function ok(name, cond) {
  check(name, !!cond, true);
}

// ---------------------------------------------------------------------
// indexLines
// ---------------------------------------------------------------------
check('indexLines empty', B.indexLines('').length, 1);
check('indexLines no trailing newline', B.indexLines('a\nb').map((l) => l.text), ['a', 'b']);
check('indexLines trailing newline has no phantom line', B.indexLines('a\n').map((l) => l.text), ['a']);
check('indexLines crlf', B.indexLines('a\r\nb').map((l) => l.text), ['a', 'b']);
check('indexLines blank lines kept', B.indexLines('a\n\nb').map((l) => l.text), ['a', '', 'b']);
{
  const src = 'ab\ncd\n';
  const lines = B.indexLines(src);
  check('indexLines ranges', lines.map((l) => [l.start, l.end, l.next]), [[0, 2, 3], [3, 5, 6]]);
  check('indexLines slice roundtrip', src.slice(lines[1].start, lines[1].end), 'cd');
}

// ---------------------------------------------------------------------
// Fence parsing
// ---------------------------------------------------------------------
check('fence open basic', B.parseFenceOpen('```mermaid'), { indent: 0, char: '`', len: 3, info: 'mermaid' });
check('fence open tilde', B.parseFenceOpen('~~~js'), { indent: 0, char: '~', len: 3, info: 'js' });
check('fence open indented', B.parseFenceOpen('   ```'), { indent: 3, char: '`', len: 3, info: '' });
check('fence open 4-space is not a fence', B.parseFenceOpen('    ```'), null);
check('fence open long', B.parseFenceOpen('`````mermaid'), { indent: 0, char: '`', len: 5, info: 'mermaid' });
check('fence open backtick in info rejected', B.parseFenceOpen('```a`b'), null);
check('fence open tilde allows backtick info', B.parseFenceOpen('~~~a`b'), { indent: 0, char: '~', len: 3, info: 'a`b' });
ok('fence close matching', B.isFenceClose('```', { char: '`', len: 3 }));
ok('fence close longer ok', B.isFenceClose('`````', { char: '`', len: 3 }));
ok('fence close shorter rejected', !B.isFenceClose('```', { char: '`', len: 5 }));
ok('fence close wrong char rejected', !B.isFenceClose('~~~', { char: '`', len: 3 }));
ok('fence close with info rejected', !B.isFenceClose('```js', { char: '`', len: 3 }));

// ---------------------------------------------------------------------
// ASCII art heuristic
// ---------------------------------------------------------------------
const BOX_ART = [
  '┌─────────┐      ┌─────────┐',
  '│  Client │─────▶│  Server │',
  '└─────────┘      └─────────┘',
].join('\n');

const PLAIN_ART = [
  '+---------+      +---------+',
  '|  Client |----->|  Server |',
  '+---------+      +---------+',
].join('\n');

const PROSE = [
  'The client sends a request to the server, which processes it',
  'and returns a response containing the requested resource.',
].join('\n');

const TABLE = ['| Name | Size |', '| --- | --- |', '| a | 1 |'].join('\n');

const CODE = [
  'function add(a, b) {',
  '  return a + b;',
  '}',
].join('\n');

ok('ascii detects box drawing', B.looksLikeAsciiArt(BOX_ART));
ok('ascii detects plain ascii art', B.looksLikeAsciiArt(PLAIN_ART));
ok('ascii rejects prose', !B.looksLikeAsciiArt(PROSE));
ok('ascii rejects pipe table', !B.looksLikeAsciiArt(TABLE));
ok('ascii rejects single line', !B.looksLikeAsciiArt('---> over here'));
ok('ascii rejects empty', !B.looksLikeAsciiArt(''));
ok('ascii rejects a lone arrow in a sentence', !B.looksLikeAsciiArt('go left → then right\nand carry on walking'));
ok('ascii rejects ordinary source code', !B.looksLikeAsciiArt(CODE));

// ---------------------------------------------------------------------
// classify
// ---------------------------------------------------------------------
check('classify mermaid info', B.classify('mermaid', 'graph TD\nA-->B'), 'mermaid');
check('classify mermaid info with attrs', B.classify('mermaid {theme=dark}', 'graph TD'), 'mermaid');
check('classify ai info', B.classify('ai-diagram', 'a cat'), 'ai');
check('classify draw info', B.classify('jsdraw', '<svg/>'), 'draw');
check('classify bare fence with mermaid keyword', B.classify('', 'sequenceDiagram\n A->>B: hi'), 'mermaid');
check('classify tagged fence never guesses mermaid', B.classify('python', 'graph = {}\nprint(graph)'), 'other');
check('classify ascii in bare fence', B.classify('', BOX_ART), 'ascii');
check('classify ascii in text fence', B.classify('text', PLAIN_ART), 'ascii');
check('classify prose is other', B.classify('', PROSE), 'other');

// ---------------------------------------------------------------------
// Render marker
// ---------------------------------------------------------------------
check('render line typed', B.parseRenderLine('![diagram:mermaid](x.svg)'), {
  alt: 'diagram:mermaid', ref: 'x.svg', kind: 'mermaid',
});
check('render line legacy', B.parseRenderLine('![mermaid](synapsetemp:///a.svg)'), {
  alt: 'mermaid', ref: 'synapsetemp:///a.svg', kind: 'mermaid',
});
check('render line untyped diagram', B.parseRenderLine('![diagram](x.svg)'), {
  alt: 'diagram', ref: 'x.svg', kind: null,
});
check('render line rejects user image', B.parseRenderLine('![my holiday photo](p.png)'), null);
check('render line rejects image with trailing prose', B.parseRenderLine('![diagram:mermaid](x.svg) see above'), null);
check('render line rejects empty alt', B.parseRenderLine('![](x.svg)'), null);

// ---------------------------------------------------------------------
// scanBlocks
// ---------------------------------------------------------------------
{
  const note = [
    '# Notes',
    '',
    '![diagram:mermaid](synapsetemp:///old.svg)',
    '',
    '```mermaid',
    'graph TD',
    'A-->B',
    '```',
    '',
    'Some prose here that is definitely not a diagram at all.',
    '',
    '```',
    ...BOX_ART.split('\n'),
    '```',
  ].join('\n');

  const units = B.scanBlocks(note);
  check('scan finds two units', units.length, 2);
  check('scan first unit kind', units[0].kind, 'mermaid');
  check('scan first unit render ref', units[0].renderRef, 'synapsetemp:///old.svg');
  check('scan first unit render above', units[0].renderPosition, 'above');
  check('scan first unit body', units[0].body, 'graph TD\nA-->B');
  check('scan second unit kind', units[1].kind, 'ascii');
  check('scan second has no render', units[1].renderRef, null);

  // The unit range must cover image + blank line + fence, exactly.
  check(
    'scan unit range covers image and fence',
    note.slice(units[0].unitStart, units[0].unitEnd),
    '![diagram:mermaid](synapsetemp:///old.svg)\n\n```mermaid\ngraph TD\nA-->B\n```'
  );
  check(
    'scan source range excludes the image',
    note.slice(units[0].sourceStart, units[0].sourceEnd),
    '```mermaid\ngraph TD\nA-->B\n```'
  );
}

{
  // A user's OWN image directly above a fence must never be absorbed.
  const note = ['![my diagram sketch](photo.png)', '', '```mermaid', 'graph TD', '```'].join('\n');
  const units = B.scanBlocks(note);
  check('user image not absorbed: one unit', units.length, 1);
  check('user image not absorbed: no ref', units[0].renderRef, null);
  check('user image survives range', note.slice(units[0].unitStart, units[0].unitEnd), '```mermaid\ngraph TD\n```');
}

{
  // Render below the fence.
  const note = ['```mermaid', 'graph TD', '```', '', '![diagram:mermaid](a.svg)'].join('\n');
  const units = B.scanBlocks(note);
  check('render below detected', units[0].renderRef, 'a.svg');
  check('render below position', units[0].renderPosition, 'below');
  check('render below range', note.slice(units[0].unitStart, units[0].unitEnd), note);
}

{
  // Two blank lines is too far to be "adjacent": the fence must not claim that
  // image, and the orphaned render is reported separately rather than silently
  // swallowed on the next write.
  const note = ['![diagram:mermaid](a.svg)', '', '', '```mermaid', 'graph TD', '```'].join('\n');
  const units = B.scanBlocks(note);
  check('two blank lines away yields two units', units.length, 2);
  check('orphaned render is its own unit', units[0].renderRef, 'a.svg');
  check('orphaned render has no source', units[0].body, '');
  check('the fence claims no render', units[1].renderRef, null);
  check('the fence keeps its own range', note.slice(units[1].unitStart, units[1].unitEnd), '```mermaid\ngraph TD\n```');
}

{
  const note = ['```mermaid', 'graph TD'].join('\n');
  const units = B.scanBlocks(note);
  check('unterminated fence still scanned', units.length, 1);
  ok('unterminated flagged', units[0].unterminated);
  check('unterminated body', units[0].body, 'graph TD');
}

{
  // Non-diagram fences are still reported — the block list needs them as
  // insertion points — but classified 'other' so the studio does not open one.
  const note = ['```', 'graph TD', '```', '', '```python', 'graph = 1', '```'].join('\n');
  const units = B.scanBlocks(note);
  check('bare fence guessed mermaid, tagged fence is other', units.map((u) => u.kind), ['mermaid', 'other']);
}

{
  // A standalone render image is a Draw unit (its SVG is its source).
  const note = ['# Title', '', '![diagram:draw](sketch_abc.svg)', '', 'after'].join('\n');
  const units = B.scanBlocks(note);
  check('solo render is a draw unit', units.map((u) => u.kind), ['draw']);
  check('solo render ref', units[0].renderRef, 'sketch_abc.svg');
  check('solo render range', note.slice(units[0].unitStart, units[0].unitEnd), '![diagram:draw](sketch_abc.svg)');
}

{
  // ASCII art living in a bare paragraph, not a fence.
  const note = ['Intro line.', '', ...BOX_ART.split('\n'), '', 'Outro line.'].join('\n');
  const units = B.scanBlocks(note);
  check('ascii paragraph detected', units.map((u) => u.kind), ['ascii']);
  check('ascii paragraph range', note.slice(units[0].unitStart, units[0].unitEnd), BOX_ART);
}

{
  // A render image tells us the tab even when the source no longer parses.
  const note = ['![diagram:ai](gen.png)', '', '```ai-diagram', 'a friendly robot', '```'].join('\n');
  const units = B.scanBlocks(note);
  check('ai unit kind', units[0].kind, 'ai');
  check('ai unit body', units[0].body, 'a friendly robot');
}

// ---------------------------------------------------------------------
// composeUnit
// ---------------------------------------------------------------------
check(
  'compose image above',
  B.composeUnit({ kind: 'mermaid', ref: 'a.svg', body: 'graph TD', position: 'above' }),
  '![diagram:mermaid](a.svg)\n\n```mermaid\ngraph TD\n```'
);
check(
  'compose image below',
  B.composeUnit({ kind: 'mermaid', ref: 'a.svg', body: 'graph TD', position: 'below' }),
  '```mermaid\ngraph TD\n```\n\n![diagram:mermaid](a.svg)'
);
check(
  'compose no ref yet',
  B.composeUnit({ kind: 'mermaid', ref: null, body: 'graph TD' }),
  '```mermaid\ngraph TD\n```'
);
check(
  'compose draw has no body',
  B.composeUnit({ kind: 'draw', ref: 'd.svg', body: '' }),
  '![diagram:draw](d.svg)'
);
check(
  'compose ascii keeps original info string',
  B.composeUnit({ kind: 'ascii', ref: 'a.svg', body: PLAIN_ART, info: 'text' }),
  '![diagram:ascii](a.svg)\n\n```text\n' + PLAIN_ART + '\n```'
);
check(
  'compose ascii unfenced stays unfenced',
  B.composeUnit({ kind: 'ascii', ref: 'a.svg', body: PLAIN_ART, fenced: false }),
  '![diagram:ascii](a.svg)\n\n' + PLAIN_ART
);
check('fenceFor plain', B.fenceFor('graph TD'), '```');
check('fenceFor body containing a fence', B.fenceFor('see ``` here'), '````');
check('fenceFor body containing a long run', B.fenceFor('a ````` b'), '``````');
check(
  'compose escapes a body containing backticks',
  B.composeUnit({ kind: 'ai', ref: null, body: 'draw ``` this' }),
  '````ai-diagram\ndraw ``` this\n````'
);

// ---------------------------------------------------------------------
// Splicing
// ---------------------------------------------------------------------
{
  const note = ['# Title', '', '```mermaid', 'graph TD', '```', '', 'Tail text.'].join('\n');
  const units = B.scanBlocks(note);
  const next = B.replaceUnit(note, units[0], B.composeUnit({ kind: 'mermaid', ref: 'a.svg', body: 'graph LR' }));
  check(
    'replace preserves surroundings byte for byte',
    next,
    '# Title\n\n![diagram:mermaid](a.svg)\n\n```mermaid\ngraph LR\n```\n\nTail text.'
  );

  // Re-scanning and replacing again must not stack images.
  const units2 = B.scanBlocks(next);
  check('rescan sees one unit', units2.length, 1);
  check('rescan picks up our image', units2[0].renderRef, 'a.svg');
  const third = B.replaceUnit(next, units2[0], B.composeUnit({ kind: 'mermaid', ref: 'b.svg', body: 'graph LR' }));
  check(
    'second render replaces rather than stacks',
    third,
    '# Title\n\n![diagram:mermaid](b.svg)\n\n```mermaid\ngraph LR\n```\n\nTail text.'
  );
  check('only one image in the note', (third.match(/!\[diagram/g) || []).length, 1);
}

{
  const note = ['a', '', '```mermaid', 'x', '```', '', 'b'].join('\n');
  const units = B.scanBlocks(note);
  check('delete unit collapses the seam', B.replaceUnit(note, units[0], ''), 'a\n\nb');
}

{
  const note = ['# Title', '', '```mermaid', 'graph TD', '```'].join('\n');
  const units = B.scanBlocks(note);
  check(
    'insert before a unit',
    B.insertRelative(note, units[0], 'before', '```mermaid\nnew\n```'),
    '# Title\n\n```mermaid\nnew\n```\n\n```mermaid\ngraph TD\n```'
  );
  check(
    'insert after a unit',
    B.insertRelative(note, units[0], 'after', '```mermaid\nnew\n```'),
    '# Title\n\n```mermaid\ngraph TD\n```\n\n```mermaid\nnew\n```'
  );
  check(
    'insert at end of note',
    B.insertRelative(note, null, 'after', '```mermaid\nnew\n```'),
    '# Title\n\n```mermaid\ngraph TD\n```\n\n```mermaid\nnew\n```'
  );
  check('insert into empty note', B.insertRelative('', null, 'after', 'X'), 'X');
}

{
  // Legacy note written by Mermaid Block Renderer upgrades cleanly.
  const note = ['![mermaid](synapsetemp:///legacy.svg)', '', '```mermaid', 'graph TD', '```'].join('\n');
  const units = B.scanBlocks(note);
  check('legacy render recognised', units[0].renderRef, 'synapsetemp:///legacy.svg');
  const next = B.replaceUnit(note, units[0], B.composeUnit({ kind: 'mermaid', ref: 'new.svg', body: 'graph TD' }));
  check('legacy image replaced not stacked', (next.match(/!\[/g) || []).length, 1);
  check('legacy upgraded to typed alt', next.indexOf('![diagram:mermaid](new.svg)') === 0, true);
}

{
  // CRLF content (notes synced from Windows) must splice without corrupting
  // the line endings of everything around the block.
  const note = ['# Title', '', '```mermaid', 'graph TD', '```', '', 'Tail.'].join('\r\n');
  const units = B.scanBlocks(note);
  check('crlf: one unit', units.length, 1);
  check('crlf: body has no stray CR', units[0].body, 'graph TD');
  const next = B.replaceUnit(note, units[0], B.composeUnit({ kind: 'mermaid', ref: 'a.svg', body: 'graph LR' }));
  check('crlf: surrounding line endings preserved', next.indexOf('# Title\r\n\r\n'), 0);
  check('crlf: tail preserved', next.slice(-'\r\n\r\nTail.'.length), '\r\n\r\nTail.');
}

{
  // A longer outer fence legitimately contains ``` runs. Scanning must not
  // stop at the inner fence, or everything after it is silently swallowed.
  const note = ['````ai-diagram', 'render this: ```code```', '````', '', 'after'].join('\n');
  const units = B.scanBlocks(note);
  check('nested fence: one unit', units.length, 1);
  check('nested fence: body intact', units[0].body, 'render this: ```code```');
  check('nested fence: tail not swallowed', note.slice(units[0].unitEnd), '\n\nafter');
  // And a round-trip must widen the fence again rather than truncate.
  const composed = B.composeUnit({ kind: 'ai', ref: null, body: units[0].body });
  check('nested fence: round-trips', B.scanBlocks(composed)[0].body, units[0].body);
}

{
  // Regression: an ASCII paragraph must not claim a neighbouring *drawing's*
  // render as its own output. Two units both owning that line would make the
  // second write clobber the first.
  const note = [...BOX_ART.split('\n'), '', '![diagram:draw](d.svg)'].join('\n');
  const units = B.scanBlocks(note);
  check('ascii paragraph and draw render stay separate', units.length, 2);
  check('ascii paragraph claims no render', units[0].renderRef, null);
  check('draw render is its own unit', [units[1].kind, units[1].renderRef], ['draw', 'd.svg']);

  // But an `ascii`-typed render beside the same paragraph IS its output.
  const owned = [...BOX_ART.split('\n'), '', '![diagram:ascii](a.svg)'].join('\n');
  const ownedUnits = B.scanBlocks(owned);
  check('ascii-typed render is claimed', ownedUnits.length, 1);
  check('ascii-typed render ref', ownedUnits[0].renderRef, 'a.svg');
}

{
  // Every unit range must be a valid, non-overlapping slice of the note.
  const note = [
    '![diagram:mermaid](a.svg)', '', '```mermaid', 'graph TD', '```', '',
    'prose', '', '```python', 'x = 1', '```', '', BOX_ART, '', '![diagram:draw](d.svg)',
  ].join('\n');
  const units = B.scanBlocks(note);
  let overlapping = false;
  let ordered = true;
  for (let i = 0; i < units.length; i++) {
    if (units[i].unitStart < 0 || units[i].unitEnd > note.length) overlapping = true;
    if (units[i].unitStart >= units[i].unitEnd) overlapping = true;
    if (i > 0 && units[i].unitStart < units[i - 1].unitEnd) ordered = false;
  }
  ok('all unit ranges are valid', !overlapping);
  ok('units never overlap', ordered);
  check('units are indexed in order', units.map((u) => u.index), units.map((_, i) => i));
}

// ---------------------------------------------------------------------
// ASCII rendering
// ---------------------------------------------------------------------
check('ascii toLines expands tabs to the grid', A.toLines('a\tb', 4), ['a   b']);
check('ascii toLines tab at a stop', A.toLines('abcd\te', 4), ['abcd    e']);
check('ascii toLines normalises crlf', A.toLines('a\r\nb'), ['a', 'b']);
check('ascii trims blank edges', A.trimBlankEdges(['', 'a', '', 'b', '']), ['a', '', 'b']);
check('ascii measure', A.measure('ab\ncdef'), { rows: 2, cols: 4, lines: ['ab', 'cdef'] });
check('ascii measure ignores trailing spaces', A.measure('ab   \ncd').cols, 2);
check('ascii pad makes a rectangle', A.padLines('ab\ncdef'), 'ab  \ncdef');
check('ascii pad is idempotent', A.padLines(A.padLines('ab\ncdef')), A.padLines('ab\ncdef'));

{
  const svg = A.asciiToSvg(PLAIN_ART, { fontSize: 14 });
  ok('ascii svg is an svg', svg.indexOf('<svg') === 0 && svg.endsWith('</svg>'));
  ok('ascii svg preserves whitespace', svg.indexOf('xml:space="preserve"') !== -1);
  ok('ascii svg pins the grid with textLength', svg.indexOf('textLength=') !== -1);
  ok('ascii svg pins a monospace stack', svg.indexOf('monospace') !== -1);
  check('ascii svg has one text per art line', (svg.match(/<text /g) || []).length, 3);
  ok('ascii svg paints a backdrop', svg.indexOf('<rect') !== -1);

  // Every line must be pinned to an exact multiple of the advance width, or
  // columns drift between lines in the viewer's font.
  const advance = 14 * A.ADVANCE_RATIO;
  const lengths = [...svg.matchAll(/textLength="([\d.]+)"/g)].map((m) => parseFloat(m[1]));
  ok('ascii textLengths are exact column multiples',
    lengths.every((l) => Math.abs((l / advance) - Math.round(l / advance)) < 1e-6));
}

{
  // XML-hostile characters in the art must not produce a broken SVG.
  const svg = A.asciiToSvg('a < b & c > d\n"quoted"');
  ok('ascii escapes angle brackets', svg.indexOf('&lt;') !== -1 && svg.indexOf('&gt;') !== -1);
  ok('ascii escapes ampersands', svg.indexOf('&amp;') !== -1);
  ok('ascii leaves no raw < in text', !/>\s*[^<]*[^&]<\s(?!\/)/.test(svg));
}

{
  // Blank interior lines must keep their vertical slot, or the art collapses.
  const svg = A.asciiToSvg('top\n\nbottom', { fontSize: 10, padding: 0 });
  const ys = [...svg.matchAll(/<text x="\d+" y="([\d.]+)"/g)].map((m) => parseFloat(m[1]));
  check('ascii skips empty lines but keeps their spacing', ys.length, 2);
  ok('ascii row spacing is two line heights', Math.abs((ys[1] - ys[0]) - 2 * 10 * A.LINE_RATIO) < 1e-6);
}

check('ascii empty input still yields a valid svg', A.asciiToSvg('').indexOf('<svg') , 0);

// ---------------------------------------------------------------------
console.log(`\n${passed} passed, ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
