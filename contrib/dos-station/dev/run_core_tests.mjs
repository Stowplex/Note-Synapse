// Offline unit tests for the pure helpers in plugins/dos_station.html.
//
// DOS Station is a single self-contained HTML file, so the pure section is
// bracketed by `/* ==== core:begin ==== */` … `/* ==== core:end ==== */` and
// sliced out here. Nothing in that region may touch the DOM, Synapse or the
// emulator, which is exactly what this runner proves.
//
// Run with: node dev/run_core_tests.mjs   (from contrib/dos-station/)
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const html = readFileSync(join(here, '..', 'plugins', 'dos_station.html'), 'utf8');

const BEGIN = '/* ==== core:begin ==';
const END = '/* ==== core:end ==';
const a = html.indexOf(BEGIN);
const b = html.indexOf(END);
if (a < 0 || b < 0) {
  console.error('core:begin / core:end markers not found in dos_station.html');
  process.exit(1);
}

const EXPORTS = [
  'CP437_HI', 'cp437Encode', 'cp437Decode', 'cp437Unmappable',
  'toDosBytes', 'fromDosBytes', 'looksBinary',
  'indexLines', 'parseFenceOpen', 'isFenceClose', 'scanFences', 'fenceBody',
  'fenceMarkerLen', 'replaceFence',
  'parseInfoAttrs', 'infoAttr', 'setInfoAttr',
  'safeRelName', 'dosPathCheck', 'dosifyName',
  'parseDosFilesLine', 'formatDosFilesLine', 'parseDosFilesBody',
  'formatDosFilesBody', 'dosFilesOpt', 'setDosFilesOpt',
  'CODE_WARN_BYTES', 'classifyNewFiles', 'composeFenceBlock', 'langForDosPath',
];
const C = new Function(html.slice(a, b) + '\nreturn {' + EXPORTS.join(',') + '};')();

let failures = 0;
let passed = 0;

function check(name, actual, expected) {
  const x = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (x === e) passed++;
  else {
    failures++;
    console.error(`FAIL ${name}\n  expected: ${e}\n  actual:   ${x}`);
  }
}
function ok(name, cond) { check(name, !!cond, true); }
const bytes = (u8) => Array.from(u8);

// =====================================================================
// CP437 + CRLF
// =====================================================================
check('cp437 table length', C.CP437_HI.length, 128);
{
  const all = new Uint8Array(256);
  for (let i = 0; i < 256; i++) all[i] = i;
  check('cp437 all 256 bytes round-trip', bytes(C.cp437Encode(C.cp437Decode(all))), bytes(all));
}
check('cp437 e-acute is 0x82', bytes(C.cp437Encode('\u00e9')), [0x82]);
check('cp437 full block is 0xdb', bytes(C.cp437Encode('\u2588')), [0xdb]);
check('cp437 pi is 0xe3', bytes(C.cp437Encode('\u03c0')), [0xe3]);
check('cp437 nbsp is 0xff', bytes(C.cp437Encode('\u00a0')), [0xff]);
check('cp437 euro is unmappable', bytes(C.cp437Encode('\u20ac')), [0x3f]);
check('cp437 astral pair is one ?', bytes(C.cp437Encode('\u{1F600}')), [0x3f]);
check('cp437 ascii identity', bytes(C.cp437Encode('AZ09')), [65, 90, 48, 57]);
check('cp437Unmappable counts', C.cp437Unmappable('a\u20ace\u00e9\u{1F600}'), 2);
check('cp437Unmappable clean', C.cp437Unmappable('plain ascii \u00e9'), 0);

check('toDosBytes lf to crlf', bytes(C.toDosBytes('a\nb')), [97, 13, 10, 98, 13, 10]);
check('toDosBytes crlf kept', bytes(C.toDosBytes('a\r\nb\r\n')), [97, 13, 10, 98, 13, 10]);
check('toDosBytes lone cr', bytes(C.toDosBytes('a\rb')), [97, 13, 10, 98, 13, 10]);
check('toDosBytes empty stays empty', bytes(C.toDosBytes('')), []);
check('fromDosBytes strips one trailing crlf', C.fromDosBytes(C.toDosBytes('a\nb')), 'a\nb');
check('fromDosBytes keeps blank last line', C.fromDosBytes(C.toDosBytes('a\n\n')), 'a\n');
check('fromDosBytes strips dos eof marker',
  C.fromDosBytes(new Uint8Array([97, 13, 10, 0x1a])), 'a');
for (const s of ['', 'x', 'print "hi"\n', 'a\nb\nc', 'caf\u00e9\nna\u00efve\n']) {
  check('dos bytes round-trip ' + JSON.stringify(s),
    C.fromDosBytes(C.toDosBytes(s)), s.replace(/\r\n?/g, '\n').replace(/\n$/, ''));
}
ok('looksBinary nul', C.looksBinary(new Uint8Array([65, 0, 66])));
ok('looksBinary text', !C.looksBinary(C.toDosBytes('10 PRINT "HI"\n20 GOTO 10\n')));
ok('looksBinary empty', !C.looksBinary(new Uint8Array(0)));
// A trailing ^Z is ordinary DOS text; in a short file it is >5% on its own.
ok('looksBinary tolerates a trailing ^Z',
  !C.looksBinary(new Uint8Array([...C.toDosBytes('10 PRINT 1'), 0x1a])));
ok('looksBinary lone ^Z', !C.looksBinary(new Uint8Array([0x1a])));
ok('looksBinary still catches control bytes',
  C.looksBinary(new Uint8Array([65, 1, 2, 3, 4, 5, 66])));

// =====================================================================
// Line indexing
// =====================================================================
check('indexLines empty', C.indexLines('').length, 1);
check('indexLines no trailing newline', C.indexLines('a\nb').map((l) => l.text), ['a', 'b']);
check('indexLines trailing newline has no phantom line', C.indexLines('a\n').map((l) => l.text), ['a']);
check('indexLines crlf', C.indexLines('a\r\nb').map((l) => l.text), ['a', 'b']);
{
  const src = 'ab\ncd\n';
  const lines = C.indexLines(src);
  check('indexLines ranges', lines.map((l) => [l.start, l.end, l.next]), [[0, 2, 3], [3, 5, 6]]);
}

// =====================================================================
// Fence parsing
// =====================================================================
check('fence open basic', C.parseFenceOpen('```basic'), { indent: 0, char: '`', len: 3, info: 'basic' });
check('fence open tilde', C.parseFenceOpen('~~~js'), { indent: 0, char: '~', len: 3, info: 'js' });
check('fence open indented', C.parseFenceOpen('   ```'), { indent: 3, char: '`', len: 3, info: '' });
check('fence open 4-space is not a fence', C.parseFenceOpen('    ```'), null);
check('fence open long', C.parseFenceOpen('`````x'), { indent: 0, char: '`', len: 5, info: 'x' });
check('fence open backtick in info rejected', C.parseFenceOpen('```a`b'), null);
ok('fence close matching', C.isFenceClose('```', { char: '`', len: 3 }));
ok('fence close longer ok', C.isFenceClose('`````', { char: '`', len: 3 }));
ok('fence close shorter rejected', !C.isFenceClose('```', { char: '`', len: 5 }));
ok('fence close with info rejected', !C.isFenceClose('```js', { char: '`', len: 3 }));

{
  const src = 'intro\n\n```basic {dos-name="HELLO.BAS"}\n10 PRINT\n```\n\ntail\n';
  const f = C.scanFences(src);
  check('scanFences count', f.length, 1);
  check('scanFences info', f[0].info, 'basic {dos-name="HELLO.BAS"}');
  check('scanFences body', C.fenceBody(src, f[0]), '10 PRINT');
  check('scanFences block slice', src.slice(f[0].blockStart, f[0].blockEnd),
    '```basic {dos-name="HELLO.BAS"}\n10 PRINT\n```\n');
  check('scanFences info slice', src.slice(f[0].infoStart, f[0].infoEnd), 'basic {dos-name="HELLO.BAS"}');
}
{
  // A 4-backtick fence containing a 3-backtick run must be one block, not three.
  const src = 'a\n````md\n```js\nx\n```\n````\nb\n';
  const f = C.scanFences(src);
  check('scanFences nested count', f.length, 1);
  check('scanFences nested body', C.fenceBody(src, f[0]), '```js\nx\n```');
}
{
  const src = 'a\n```x\nbody\n';           // unterminated at EOF
  const f = C.scanFences(src);
  check('scanFences unterminated count', f.length, 1);
  check('scanFences unterminated closeLine', f[0].closeLine, null);
  check('scanFences unterminated body', C.fenceBody(src, f[0]), 'body');
}
{
  const src = '  ```txt\n  hi\n  ```\n';
  const f = C.scanFences(src);
  check('scanFences indented body strips indent', C.fenceBody(src, f[0]), 'hi');
}
{
  const src = '```\n```\n```\n```\n';       // two empty blocks, not four fences
  const f = C.scanFences(src);
  check('scanFences empty blocks', f.length, 2);
  check('scanFences empty body', C.fenceBody(src, f[0]), '');
}

// =====================================================================
// replaceFence — the splice must not disturb one byte outside the block
// =====================================================================
{
  const src = 'head\n\n```basic\nold\n```\n\ntail\n';
  const f = C.scanFences(src)[0];
  const out = C.replaceFence(src, f, { body: 'new\nlines' });
  check('replaceFence body', out, 'head\n\n```basic\nnew\nlines\n```\n\ntail\n');
  check('replaceFence prefix untouched', out.slice(0, f.blockStart), src.slice(0, f.blockStart));
  check('replaceFence suffix untouched', out.slice(out.length - 6), src.slice(src.length - 6));
}
{
  const src = '```basic\nx\n```\n';
  const f = C.scanFences(src)[0];
  check('replaceFence info only', C.replaceFence(src, f, { info: 'basic {dos-name="A.BAS"}' }),
    '```basic {dos-name="A.BAS"}\nx\n```\n');
}
{
  // A body that contains a fence run must widen the markers, not shred the note.
  const src = 'a\n```txt\nx\n```\nb\n';
  const f = C.scanFences(src)[0];
  const out = C.replaceFence(src, f, { body: 'before\n```\nafter' });
  check('replaceFence widens markers', out, 'a\n````txt\nbefore\n```\nafter\n````\nb\n');
  check('replaceFence widened re-scans as one block', C.scanFences(out).length, 1);
  check('replaceFence widened body survives', C.fenceBody(out, C.scanFences(out)[0]), 'before\n```\nafter');
}
{
  const src = '  ```txt\n  x\n  ```\n';
  const f = C.scanFences(src)[0];
  check('replaceFence re-indents', C.replaceFence(src, f, { body: 'p\n\nq' }),
    '  ```txt\n  p\n\n  q\n  ```\n');
}
{
  const src = 'a\n```txt\nx\n```';           // no trailing newline in the note
  const f = C.scanFences(src)[0];
  check('replaceFence does not invent a trailing newline',
    C.replaceFence(src, f, { body: 'y' }), 'a\n```txt\ny\n```');
}
{
  const src = '```txt\nx\n```\n';
  const f = C.scanFences(src)[0];
  check('replaceFence empty body', C.replaceFence(src, f, { body: '' }), '```txt\n```\n');
}
{
  // An unclosed fence's "body" is the whole rest of the note. Splicing it would
  // delete everything after the stray ``` — refuse instead.
  const src = 'intro\n\n```txt\nbody\n\nlots of other note text\nmore\n';
  const f = C.scanFences(src)[0];
  ok('scanFences still reports the unclosed block', f.closeLine === null);
  let threw = '';
  try { C.replaceFence(src, f, { body: 'NEW' }); } catch (e) { threw = e.message; }
  ok('replaceFence refuses an unclosed fence', /unclosed code block/.test(threw));
}
{
  // A CRLF note must not come back with one LF-ended block in the middle of it.
  const src = 'a\r\n```txt\r\nx\r\n```\r\nb\r\n';
  const f = C.scanFences(src)[0];
  check('replaceFence keeps CRLF', C.replaceFence(src, f, { body: 'q' }),
    'a\r\n```txt\r\nq\r\n```\r\nb\r\n');
}
{
  const src = 'a\n```txt\nx\n```\nb\n';
  const f = C.scanFences(src)[0];
  check('replaceFence keeps LF', C.replaceFence(src, f, { body: 'q' }), 'a\n```txt\nq\n```\nb\n');
}

// =====================================================================
// Info string attributes
// =====================================================================
check('parseInfoAttrs bare', C.parseInfoAttrs('').lang, '');
check('parseInfoAttrs lang only', C.parseInfoAttrs('basic'), { lang: 'basic', head: 'basic', attrs: [], hasBrace: false });
check('parseInfoAttrs value', C.infoAttr('basic {dos-name="HELLO.BAS"}', 'dos-name'), 'HELLO.BAS');
check('parseInfoAttrs single quotes', C.infoAttr("basic {dos-name='A.BAS'}", 'dos-name'), 'A.BAS');
check('parseInfoAttrs unquoted', C.infoAttr('basic {dos-name=A.BAS}', 'dos-name'), 'A.BAS');
check('parseInfoAttrs missing', C.infoAttr('basic', 'dos-name'), null);
check('parseInfoAttrs pandoc style keeps lang',
  C.parseInfoAttrs('python {.numberLines startFrom="5"}').lang, 'python');
check('parseInfoAttrs pandoc style raw tokens',
  C.parseInfoAttrs('python {.numberLines startFrom="5"}').attrs.map((x) => x.raw),
  ['.numberLines', 'startFrom="5"']);

check('setInfoAttr adds brace', C.setInfoAttr('basic', 'dos-name', 'A.BAS'), 'basic {dos-name="A.BAS"}');
check('setInfoAttr adds to empty info', C.setInfoAttr('', 'dos-name', 'A.BAS'), '{dos-name="A.BAS"}');
check('setInfoAttr replaces', C.setInfoAttr('basic {dos-name="A.BAS"}', 'dos-name', 'B.BAS'),
  'basic {dos-name="B.BAS"}');
check('setInfoAttr preserves neighbours',
  C.setInfoAttr('python {.numberLines startFrom="5"}', 'dos-name', 'A.PY'),
  'python {.numberLines startFrom="5" dos-name="A.PY"}');
check('setInfoAttr removes and drops empty braces',
  C.setInfoAttr('basic {dos-name="A.BAS"}', 'dos-name', null), 'basic');
check('setInfoAttr removes but keeps others',
  C.setInfoAttr('basic {.x dos-name="A.BAS"}', 'dos-name', null), 'basic {.x}');
check('setInfoAttr strips quotes from the value',
  C.setInfoAttr('basic', 'dos-name', 'A"B.BAS'), 'basic {dos-name="AB.BAS"}');
{
  // A backtick in the info string stops the line being a fence at all: the
  // opener turns into prose and the old closer becomes an opener.
  check('setInfoAttr strips a backtick', C.setInfoAttr('basic', 'dos-name', 'A`B.BAS'),
    'basic {dos-name="AB.BAS"}');
  ok('dosPathCheck rejects a backtick', !C.dosPathCheck('a`b.txt').ok);
  const src = 'head\n\n```basic\nx\n```\n\ntail\n';
  const f = C.scanFences(src)[0];
  const out = C.replaceFence(src, f, { info: C.setInfoAttr(f.info, 'dos-name', 'A`B.BAS') });
  check('a sanitized name leaves the block a block', C.scanFences(out).length, 1);
  check('and the attribute still round-trips', C.infoAttr(C.scanFences(out)[0].info, 'dos-name'),
    'AB.BAS');
}
check('setInfoAttr round-trips through the scanner', (() => {
  const src = '```basic\nx\n```\n';
  const f = C.scanFences(src)[0];
  const out = C.replaceFence(src, f, { info: C.setInfoAttr(f.info, 'dos-name', 'A.BAS') });
  return C.infoAttr(C.scanFences(out)[0].info, 'dos-name');
})(), 'A.BAS');

// =====================================================================
// replaceFence property test
//
// Every note write is a whole-body replace built from one of these splices, so
// the invariant that protects the user's note is: nothing outside the block
// moves, and the result re-scans to the same block with the intended body. Run
// it over generated documents rather than only the cases I thought of.
// =====================================================================
{
  // Deterministic PRNG — a failing seed has to be reproducible.
  let seed = 0x2545f491;
  const rnd = (n) => {
    seed ^= seed << 13; seed >>>= 0;
    seed ^= seed >> 17;
    seed ^= seed << 5; seed >>>= 0;
    return seed % n;
  };
  const LINES = [
    'plain prose', '', '# heading', '   indented text', '\tTabbed',
    '```', '````', '~~~', '```js', '~~~text', '  ```sh', '```basic {dos-name="A.BAS"}',
    '````md', 'text with ``` inside it', '- a list item', '> quote',
  ];
  const BODIES = ['', 'x', 'a\nb', '```\nnested\n```', 'line\n\nblank', '````\nwide\n````', '\ttab'];

  let failures0 = failures;
  for (let iter = 0; iter < 3000; iter++) {
    const n = 1 + rnd(9);
    const doc = Array.from({ length: n }, () => LINES[rnd(LINES.length)]).join('\n') +
      (rnd(2) ? '\n' : '');
    // Unterminated fences are never writable — replaceFence refuses them,
    // asserted separately below.
    const fences = C.scanFences(doc).filter((g) => g.closeLine !== null);
    if (!fences.length) continue;
    const f = fences[rnd(fences.length)];
    const body = BODIES[rnd(BODIES.length)];
    let out;
    try {
      out = C.replaceFence(doc, f, { body });
    } catch (e) {
      failures++;
      console.error(`FAIL replaceFence threw (iter ${iter})\n  doc: ${JSON.stringify(doc)}\n  ${e.message}`);
      break;
    }
    const prefixOk = out.slice(0, f.blockStart) === doc.slice(0, f.blockStart);
    const suffixOk = out.slice(out.length - (doc.length - f.blockEnd)) ===
      doc.slice(f.blockEnd);
    // The replaced block must come back as one block holding exactly what we put in.
    const after = C.scanFences(out);
    const hit = after.find((g) => g.blockStart === f.blockStart);
    const bodyOk = hit ? C.fenceBody(out, hit) === body : false;
    const countOk = after.length === C.scanFences(doc).length;
    if (!prefixOk || !suffixOk || !bodyOk || !countOk) {
      failures++;
      console.error(`FAIL replaceFence invariant (iter ${iter})` +
        `\n  doc:    ${JSON.stringify(doc)}` +
        `\n  body:   ${JSON.stringify(body)}` +
        `\n  out:    ${JSON.stringify(out)}` +
        `\n  prefix=${prefixOk} suffix=${suffixOk} body=${bodyOk} count=${countOk}`);
      break;
    }
  }
  if (failures === failures0) passed++;
}

// =====================================================================
// DOS names
// =====================================================================
ok('safeRelName plain', C.safeRelName('A/B.TXT'));
ok('safeRelName rejects absolute', !C.safeRelName('/etc/passwd'));
ok('safeRelName rejects traversal', !C.safeRelName('a/../../b'));
ok('safeRelName rejects drive', !C.safeRelName('C:/x'));

check('dosPathCheck uppercases', C.dosPathCheck('hello.bas').path, 'HELLO.BAS');
ok('dosPathCheck accepts subdirs', C.dosPathCheck('src/main.bas').ok);
check('dosPathCheck normalizes backslashes', C.dosPathCheck('DOCS\\READ.TXT').path, 'DOCS/READ.TXT');
ok('dosPathCheck rejects long stem', !C.dosPathCheck('toolongname.txt').ok);
check('dosPathCheck long stem reason', C.dosPathCheck('toolongname.txt').reason,
  '"TOOLONGNAME" is longer than 8 characters');
ok('dosPathCheck rejects long ext', !C.dosPathCheck('a.text').ok);
ok('dosPathCheck rejects device', !C.dosPathCheck('con.txt').ok);
ok('dosPathCheck rejects bare device', !C.dosPathCheck('nul').ok);
ok('dosPathCheck rejects traversal', !C.dosPathCheck('../x.txt').ok);
ok('dosPathCheck rejects drive', !C.dosPathCheck('C:\\X.TXT').ok);
ok('dosPathCheck rejects empty', !C.dosPathCheck('   ').ok);
ok('dosPathCheck rejects two dots', !C.dosPathCheck('a.b.c').ok);
ok('dosPathCheck rejects plus', !C.dosPathCheck('a+b.txt').ok);
ok('dosPathCheck accepts legal punctuation', C.dosPathCheck("go!-_~.bat").ok);

check('dosifyName basic', C.dosifyName('levels.dat', []), 'LEVELS.DAT');
check('dosifyName truncates', C.dosifyName('my-long-name.basic', []), 'MY-LONG.BAS');
check('dosifyName strips dirs', C.dosifyName('sound/theme.mid', []), 'THEME.MID');
check('dosifyName replaces illegal', C.dosifyName('a+b.txt', []), 'A_B.TXT');
check('dosifyName de-dups', C.dosifyName('levels.dat', ['LEVELS.DAT']), 'LEVELS~1.DAT');
check('dosifyName de-dups twice', C.dosifyName('levels.dat', ['LEVELS.DAT', 'LEVELS~1.DAT']), 'LEVELS~2.DAT');
ok('dosifyName output is always valid', C.dosPathCheck(C.dosifyName('a really! bad @name.tar.gz', [])).ok);

// =====================================================================
// dos-files fence
// =====================================================================
check('dos-files minimal', C.parseDosFilesLine('attachment: levels.dat'),
  { src: 'levels.dat', dosPath: null, opts: [] });
check('dos-files renamed', C.parseDosFilesLine('attachment: levels.dat -> LEVELS.DAT'),
  { src: 'levels.dat', dosPath: 'LEVELS.DAT', opts: [] });
check('dos-files options', C.parseDosFilesLine('attachment: r.md -> R.TXT | text | v=r-1_a.md'),
  { src: 'r.md', dosPath: 'R.TXT', opts: ['text', 'v=r-1_a.md'] });
check('dos-files quoted source', C.parseDosFilesLine('attachment: "a -> b.dat" -> AB.DAT'),
  { src: 'a -> b.dat', dosPath: 'AB.DAT', opts: [] });
check('dos-files not an entry', C.parseDosFilesLine('# a comment'), null);
check('dos-files format round-trip',
  C.formatDosFilesLine(C.parseDosFilesLine('attachment: r.md -> R.TXT | text | v=r-1_a.md')),
  'attachment: r.md -> R.TXT | text | v=r-1_a.md');
check('dos-files format quotes when needed',
  C.formatDosFilesLine({ src: 'a -> b.dat', dosPath: 'AB.DAT', opts: [] }),
  'attachment: "a -> b.dat" -> AB.DAT');
{
  const body = '# managed by DOS Station\nattachment: levels.dat -> LEVELS.DAT\n\nattachment: r.md | text\nnonsense line';
  const recs = C.parseDosFilesBody(body);
  check('dos-files body entry count', recs.filter((r) => r.kind === 'entry').length, 2);
  check('dos-files body preserves everything', C.formatDosFilesBody(recs), body);
  check('dos-files body flags junk', recs.filter((r) => r.bad).map((r) => r.text), ['nonsense line']);
}
check('dosFilesOpt flag', C.dosFilesOpt(['text'], 'text'), true);
check('dosFilesOpt value', C.dosFilesOpt(['text', 'v=x.dat'], 'v'), 'x.dat');
check('dosFilesOpt missing', C.dosFilesOpt(['text'], 'v'), null);
check('setDosFilesOpt replaces', C.setDosFilesOpt(['text', 'v=old'], 'v', 'new'), ['text', 'v=new']);
check('setDosFilesOpt removes', C.setDosFilesOpt(['text', 'v=old'], 'v', null), ['text']);
check('setDosFilesOpt adds flag', C.setDosFilesOpt([], 'text', true), ['text']);

// =====================================================================
// files DOS created (classifyNewFiles / composeFenceBlock / langForDosPath)
// =====================================================================
{
  const caps = { code: 512 * 1024, att: 8 * 1024 * 1024 };
  const u8 = (s) => new Uint8Array([...s].map((c) => c.charCodeAt(0)));
  const changed = [
    { name: 'NEW.TXT', data: u8('hello\r\n') },
    { name: 'SAVES/GAME1.SAV', data: new Uint8Array([0, 1, 2, 3]) },
    { name: 'linked.bas', data: u8('10 PRINT\r\n') },
    { name: 'toolongname.txt', data: u8('x') },
  ];
  const rows = C.classifyNewFiles(changed, new Set(['LINKED.BAS']), caps);
  check('classify excludes linked case-insensitively',
    rows.map((r) => r.name), ['NEW.TXT', 'SAVES/GAME1.SAV', 'toolongname.txt']);
  const txt = rows.find((r) => r.name === 'NEW.TXT');
  check('classify text file', { code: txt.canCode, att: txt.canAtt, bin: txt.binary, warn: txt.codeWarn },
    { code: true, att: true, bin: false, warn: false });
  check('classify text file size', txt.size, 7);
  const sav = rows.find((r) => r.name === 'SAVES/GAME1.SAV');
  check('classify binary subdir file', { code: sav.canCode, att: sav.canAtt, bin: sav.binary, path: sav.dosPath },
    { code: false, att: true, bin: true, path: 'SAVES/GAME1.SAV' });
  const bad = rows.find((r) => r.name === 'toolongname.txt');
  check('classify invalid name', { code: bad.canCode, att: bad.canAtt, path: bad.dosPath },
    { code: false, att: false, path: null });
  check('classify invalid name reason', bad.reason, '"TOOLONGNAME" is longer than 8 characters');
  ok('classify rows carry no data', rows.every((r) => !('data' in r)));

  const warnRows = C.classifyNewFiles(
    [{ name: 'BIG.TXT', data: new Uint8Array(C.CODE_WARN_BYTES + 1).fill(65) },
     { name: 'OK.TXT', data: new Uint8Array(C.CODE_WARN_BYTES).fill(65) }],
    new Set(), caps);
  check('classify warn boundary', warnRows.map((r) => ({ n: r.name, w: r.codeWarn })),
    [{ n: 'BIG.TXT', w: true }, { n: 'OK.TXT', w: false }]);

  const huge = C.classifyNewFiles(
    [{ name: 'HUGE.DAT', data: new Uint8Array(caps.att + 1).fill(65) },
     { name: 'MID.TXT', data: new Uint8Array(caps.code + 1).fill(65) }],
    new Set(), caps);
  check('classify over attachment cap', { att: huge[0].canAtt, reason: huge[0].reason },
    { att: false, reason: 'larger than 8 MB' });
  check('classify text over code cap keeps attachment',
    { code: huge[1].canCode, att: huge[1].canAtt, reason: huge[1].reason },
    { code: false, att: true, reason: '' });

  check('compose plain', C.composeFenceBlock('basic {dos-name="A.BAS"}', '10 PRINT'),
    '```basic {dos-name="A.BAS"}\n10 PRINT\n```\n');
  check('compose empty body', C.composeFenceBlock('', ''), '```\n```\n');
  check('compose crlf body', C.composeFenceBlock('', 'a\r\nb'), '```\na\nb\n```\n');
  check('compose strips backticks from info', C.composeFenceBlock('x`y', 'a'), '```xy\na\n```\n');
  {
    const body = 'text\n```\ninner\n```\nmore';
    const block = C.composeFenceBlock('{dos-name="X.TXT"}', body);
    ok('compose widens marker', block.startsWith('````'));
    const fences = C.scanFences(block);
    check('compose re-scans as one closed block', fences.length, 1);
    ok('compose block is closed', fences[0].closeLine !== null);
    check('compose body round-trips', C.fenceBody(block, fences[0]), body);
    check('compose keeps attr', C.infoAttr(fences[0].info, 'dos-name'), 'X.TXT');
  }

  check('lang basic', C.langForDosPath('HELLO.BAS'), 'basic');
  check('lang c header', C.langForDosPath('SRC/DEFS.H'), 'c');
  check('lang bat', C.langForDosPath('GO.BAT'), 'bat');
  check('lang unknown is empty', C.langForDosPath('GAME1.SAV'), '');
  check('lang no extension', C.langForDosPath('README'), '');
}

// =====================================================================
console.log(`${passed} passed, ${failures} failed`);
process.exit(failures ? 1 : 0);
