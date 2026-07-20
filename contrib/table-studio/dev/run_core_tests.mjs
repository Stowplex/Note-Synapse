// Offline unit tests for plugins/src/table_core.js.
// Run with: node dev/run_core_tests.mjs   (from contrib/table-studio/)
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const require = createRequire(import.meta.url);
const core = require(join(dirname(fileURLToPath(import.meta.url)), '..', 'plugins', 'src', 'table_core.js'));

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
// splitPipeRow / escapes
// ---------------------------------------------------------------------
check('split basic', core.splitPipeRow('| a | b | c |'), ['a', 'b', 'c']);
check('split no outer pipes', core.splitPipeRow('a | b'), ['a', 'b']);
check('split escaped pipe', core.splitPipeRow('| a \\| b | c |'), ['a \\| b', 'c']);
check('split empty cells', core.splitPipeRow('| | x | |'), ['', 'x', '']);
check('split single empty', core.splitPipeRow('|'), ['']);
check('decode', core.decodeMdCell('a \\| b<br>c<br/>d'), 'a | b\nc\nd');
check('encode', core.encodeMdCell('a | b\nc'), 'a \\| b<br>c');
check('encode crlf', core.encodeMdCell('a\r\nb\rc'), 'a<br>b<br>c');
check('roundtrip literal br text', core.encodeMdCell(core.decodeMdCell('x<br>y')), 'x<br>y');

// Backslash/pipe escaping must be bijective: a cell whose text ends in a
// backslash right before a pipe must not decay into a separator.
check('encode bs-pipe', core.encodeMdCell('a\\|b'), 'a\\\\\\|b');
check('decode bs-pipe', core.decodeMdCell('a\\\\\\|b'), 'a\\|b');
check('encode lone bs kept', core.encodeMdCell('C:\\x \\*'), 'C:\\x \\*');
check('decode lone bs kept', core.decodeMdCell('C:\\x \\*'), 'C:\\x \\*');
for (const tricky of ['\\|', 'a\\', '\\\\|', 'a\\|\\|b', '|\\', '\\', '\\\\\\|']) {
  check(
    'escape bijective ' + JSON.stringify(tricky),
    core.decodeMdCell(core.encodeMdCell(tricky)),
    tricky
  );
}

// Full table round trip for backslash-adjacent-to-pipe cells: the serialized
// text must re-scan to the identical grid with no phantom columns.
{
  const grid = [
    ['h', 'x'],
    ['a\\|', '\\|b'],
    ['tail\\', '\\\\|'],
  ];
  const out = core.serializeTable(grid, [null, null], '');
  const back = core.scanTables(out);
  check('bs-pipe table roundtrip', back[0].grid, grid);
  check('bs-pipe no phantom cols', back[0].grid[0].length, 2);
}

// ---------------------------------------------------------------------
// isDelimiterRow
// ---------------------------------------------------------------------
ok('delim simple', core.isDelimiterRow('| --- | :-: |'));
ok('delim minimal', core.isDelimiterRow('|-|'));
ok('delim aligned', core.isDelimiterRow(':--- | ---:'));
ok('delim not text', !core.isDelimiterRow('| a | b |'));
ok('delim not hr', !core.isDelimiterRow('---'));
ok('delim not empty', !core.isDelimiterRow(''));
ok('delim not mixed', !core.isDelimiterRow('| --- | x |'));

// ---------------------------------------------------------------------
// scanTables
// ---------------------------------------------------------------------
{
  const md = [
    '# Title',
    '',
    '| Name | Qty |',
    '| ---- | --: |',
    '| foo  | 1   |',
    '| bar  | 22  |',
    '',
    'text after',
  ].join('\n');
  const t = core.scanTables(md);
  check('scan count', t.length, 1);
  check('scan lines', [t[0].startLine, t[0].endLine], [2, 6]);
  check('scan grid', t[0].grid, [
    ['Name', 'Qty'],
    ['foo', '1'],
    ['bar', '22'],
  ]);
  check('scan aligns', t[0].aligns, [null, 'right']);
  check(
    'scan raw',
    t[0].raw,
    '| Name | Qty |\n| ---- | --: |\n| foo  | 1   |\n| bar  | 22  |'
  );
}

{
  const md = [
    '```',
    '| a | b |',
    '| - | - |',
    '| 1 | 2 |',
    '```',
    '',
    '| real | table |',
    '| ---- | ----- |',
    '| yes  | here  |',
  ].join('\n');
  const t = core.scanTables(md);
  check('fenced table skipped', t.length, 1);
  check('fenced survivor', t[0].grid[0], ['real', 'table']);
}

{
  const md = ['~~~text', '| a | b |', '| - | - |', '~~~'].join('\n');
  check('tilde fence skipped', core.scanTables(md).length, 0);
}

{
  // Table at end of content without trailing newline
  const md = '| a |\n| - |\n| 1 |';
  const t = core.scanTables(md);
  check('table at EOF', t.length, 1);
  check('table at EOF end', t[0].endLine, 3);
}

{
  // Header/delimiter column count mismatch is not a table
  const md = '| a | b |\n| - |\n| 1 | 2 |';
  check('mismatched delim rejected', core.scanTables(md).length, 0);
}

{
  // Body row wider than header extends the grid instead of dropping data
  const md = '| a | b |\n| - | - |\n| 1 | 2 | 3 |';
  const t = core.scanTables(md);
  check('wide body kept', t[0].grid, [
    ['a', 'b', ''],
    ['1', '2', '3'],
  ]);
  check('wide body aligns padded', t[0].aligns, [null, null, null]);
}

{
  // Two adjacent tables separated by a blank line
  const md = '| a |\n| - |\n\n| b |\n| - |\n| 2 |';
  const t = core.scanTables(md);
  check('two tables', t.length, 2);
  check('second table start', t[1].startLine, 3);
}

{
  // Escaped pipe cells survive a scan -> serialize round trip
  const md = '| a \\| b | c |\n| ------- | - |\n| x<br>y  | z |';
  const t = core.scanTables(md);
  check('escape decode', t[0].grid, [
    ['a | b', 'c'],
    ['x\ny', 'z'],
  ]);
  const out = core.serializeTable(t[0].grid, t[0].aligns, '');
  const rescan = core.scanTables(out);
  check('escape roundtrip', rescan[0].grid, t[0].grid);
}

{
  // Indented table keeps its indent
  const md = '  | a | b |\n  | - | - |\n  | 1 | 2 |';
  const t = core.scanTables(md);
  check('indent captured', t[0].indent, '  ');
  const out = core.serializeTable(t[0].grid, t[0].aligns, t[0].indent);
  ok('indent emitted', out.split('\n').every((l) => l.startsWith('  | ')));
}

{
  // An unclosed fence swallows the rest of the document
  const md = '```\n| a | b |\n| - | - |';
  check('unclosed fence', core.scanTables(md).length, 0);
}

// ---------------------------------------------------------------------
// serializeTable
// ---------------------------------------------------------------------
{
  const out = core.serializeTable(
    [
      ['Name', 'Qty'],
      ['foo', '1'],
    ],
    [null, 'right'],
    ''
  );
  check('serialize pretty', out, '| Name | Qty |\n| ---- | --: |\n| foo  |   1 |');
}

{
  const out = core.serializeTable([['a'], ['b']], ['center'], '');
  check('serialize center', out, '|  a  |\n| :-: |\n|  b  |');
}

{
  // Serialization always yields something scanTables can parse again
  const grid = [
    ['h1', 'h|2', 'multi\nline'],
    ['', '  ', '汉字宽'],
  ];
  const out = core.serializeTable(grid, [null, 'center', 'right'], '');
  const t = core.scanTables(out);
  check('hard roundtrip', t[0].grid, [
    ['h1', 'h|2', 'multi\nline'],
    ['', '', '汉字宽'],
  ]);
  check('hard roundtrip aligns', t[0].aligns, [null, 'center', 'right']);
}

// ---------------------------------------------------------------------
// CSV / TSV
// ---------------------------------------------------------------------
{
  const p = core.parseDelimited('a,b\n1,2\n', ',');
  check('csv rows', p.rows, [
    ['a', 'b'],
    ['1', '2'],
  ]);
  check('csv trailing nl', p.trailingNewline, true);
  check('csv eol', p.lineEnding, '\n');
  check('csv bom', p.hadBom, false);
  check('csv roundtrip', core.serializeDelimited(p.rows, p), 'a,b\n1,2\n');
}

{
  const src = '﻿"a,1","b""q"\r\n"line\nbreak",x';
  const p = core.parseDelimited(src, ',');
  check('csv quoted rows', p.rows, [
    ['a,1', 'b"q'],
    ['line\nbreak', 'x'],
  ]);
  check('csv crlf', p.lineEnding, '\r\n');
  check('csv bom kept', p.hadBom, true);
  check('csv quoted roundtrip', core.serializeDelimited(p.rows, p), src);
}

{
  const p = core.parseDelimited('a\tb\n1\t2', '\t');
  check('tsv rows', p.rows, [
    ['a', 'b'],
    ['1', '2'],
  ]);
  check('tsv roundtrip', core.serializeDelimited(p.rows, p), 'a\tb\n1\t2');
}

{
  // Ragged rows become rectangular in the grid, but serialization restores
  // the original arity for untouched rows.
  const p = core.parseDelimited('a,b,c\n1\n', ',');
  check('csv ragged', p.rows, [
    ['a', 'b', 'c'],
    ['1', '', ''],
  ]);
  check('csv ragged arities', p.arities, [3, 1]);
  check('csv ragged roundtrip', core.serializeDelimited(p.rows, p), 'a,b,c\n1\n');
}

{
  // Blank lines survive the round trip byte-for-byte.
  const src = 'a,b\n\n1,2\n';
  const p = core.parseDelimited(src, ',');
  check('csv blank line roundtrip', core.serializeDelimited(p.rows, p), src);
}

{
  // Editing a cell beyond a ragged row's original arity widens just that row.
  const p = core.parseDelimited('a,b,c\n1\n', ',');
  p.rows[1][2] = 'z';
  check('csv ragged edit widens', core.serializeDelimited(p.rows, p), 'a,b,c\n1,,z\n');
}

{
  // Appended all-empty trailing rows (fluid Enter entry) are dropped;
  // appended rows with content serialize at full width.
  const p = core.parseDelimited('a,b\n1,2\n', ',');
  p.rows.push(['', '']);
  p.rows.push(['', '']);
  check('csv trailing empties dropped', core.serializeDelimited(p.rows, p), 'a,b\n1,2\n');
  p.rows[2][0] = 'x';
  check('csv appended row kept', core.serializeDelimited(p.rows, p), 'a,b\n1,2\nx,\n');
}

{
  // Size limits abort before the grid is made rectangular.
  let threw = false;
  try {
    core.parseDelimited('a,b,c,d,e\n1\n', ',', { maxCols: 4 });
  } catch (e) {
    threw = true;
  }
  check('csv maxCols throws', threw, true);
  let threw2 = false;
  try {
    core.parseDelimited('a,b,c\n1\n2\n3\n', ',', { maxCells: 6 });
  } catch (e) {
    threw2 = true;
  }
  check('csv maxCells throws', threw2, true);
}

{
  // Oversized markdown tables are skipped, not truncated; smaller ones scan.
  const md = '| a | b | c | d |\n| - | - | - | - |\n\n| x |\n| - |\n| 1 |';
  const t = core.scanTables(md, { maxCols: 3 });
  check('md oversized skipped', t.length, 1);
  check('md oversized survivor', t[0].grid[0], ['x']);
  const t2 = core.scanTables('| a |\n| - |\n| 1 |\n| 2 |\n| 3 |', { maxCells: 3 });
  check('md maxCells skipped', t2.length, 0);
}

{
  // Quote appearing mid-cell is literal (RFC edge)
  const p = core.parseDelimited('ab"c,d\n', ',');
  check('mid-cell quote', p.rows, [['ab"c', 'd']]);
}

{
  check('empty text', core.parseDelimited('', ',').rows, [['']]);
  const cr = core.parseDelimited('a\rb\r', ',');
  check('cr only rows', cr.rows, [['a'], ['b']]);
  check('cr only eol', cr.lineEnding, '\r');
  check('cr only roundtrip', core.serializeDelimited(cr.rows, cr), 'a\rb\r');
}

check('sniff tsv ext', core.sniffDelimiter('a,b', 'tsv'), '\t');
check('sniff semicolon', core.sniffDelimiter('a;b;c\n1;2;3', 'csv'), ';');
check('sniff comma default', core.sniffDelimiter('plain text', 'csv'), ',');
check(
  'sniff quoted ignored',
  core.sniffDelimiter('"a;b;c;d",x\n"1;2;3;4",y', 'csv'),
  ','
);

// ---------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------
check('colLabel A', core.colLabel(0), 'A');
check('colLabel Z', core.colLabel(25), 'Z');
check('colLabel AA', core.colLabel(26), 'AA');
check('colLabel AZ', core.colLabel(51), 'AZ');
check('colLabel BA', core.colLabel(52), 'BA');

// looksNumeric is lossless-only: the number must format back to the exact
// same string, so zip codes, phone numbers, and exponents stay text.
ok('numeric int', core.looksNumeric('42'));
ok('numeric neg float', core.looksNumeric('-3.5'));
ok('numeric decimal', core.looksNumeric('1234.57'));
ok('not numeric exp', !core.looksNumeric('1e5'));
ok('not numeric leading zero', !core.looksNumeric('007'));
ok('not numeric padded', !core.looksNumeric(' 5 '));
ok('not numeric neg zero', !core.looksNumeric('-0'));
ok('not numeric overflow', !core.looksNumeric('1e999'));
ok('not numeric text', !core.looksNumeric('42a'));
ok('not numeric empty', !core.looksNumeric(''));
ok('not numeric long', !core.looksNumeric('12345678901234567890'));

{
  // Trailing all-empty body rows are trimmed from markdown tables; the
  // header always survives. An explicit eol joins with CRLF.
  const out = core.serializeTable(
    [['h'], ['x'], [''], ['']],
    [null],
    ''
  );
  check('md trailing empties trimmed', out, '| h   |\n| --- |\n| x   |');
  const crlf = core.serializeTable([['a'], ['1']], [null], '', '\r\n');
  check('md crlf eol', crlf, '| a   |\r\n| --- |\r\n| 1   |');
}

{
  const g = [['a'], ['b', 'c']];
  core.normalizeGrid(g);
  check('normalize', g, [
    ['a', ''],
    ['b', 'c'],
  ]);
}

// =====================================================================
// univer_bridge.js
// =====================================================================
const bridge = require(join(dirname(fileURLToPath(import.meta.url)), '..', 'plugins', 'src', 'univer_bridge.js'));
const XLSX = require(join(dirname(fileURLToPath(import.meta.url)), '..', 'plugins', 'vendor', 'xlsx-0.20.3.full.min.js'));

// ---------------------------------------------------------------------
// engine manifest sanity
// ---------------------------------------------------------------------
ok('engine has js files', bridge.ENGINE.js.length >= 10);
ok('engine has css files', bridge.ENGINE.css.length >= 3);
for (const f of bridge.ENGINE.js.concat(bridge.ENGINE.css)) {
  ok('engine pin ' + f.name, /^[0-9a-f]{64}$/.test(f.sha256) && f.bytes > 0 && f.path.includes('@'));
  check('engine mirrors ' + f.name, bridge.engineUrls(f).length, 2);
}
ok('engine total plausible', bridge.engineTotalBytes() > 10 * 1024 * 1024);

// ---------------------------------------------------------------------
// stableNumber — only round-trip-stable numerics become numbers
// ---------------------------------------------------------------------
check('num int', bridge.stableNumber('3'), 3);
check('num negative', bridge.stableNumber('-2.5'), -2.5);
check('num zero', bridge.stableNumber('0'), 0);
check('num trailing zero stays text', bridge.stableNumber('3.10'), null);
check('num leading zeros stay text', bridge.stableNumber('007'), null);
check('num exponent stays text', bridge.stableNumber('1e3'), null);
check('num padded stays text', bridge.stableNumber(' 4'), null);
check('num comma stays text', bridge.stableNumber('1,000'), null);
check('num empty', bridge.stableNumber(''), null);

// ---------------------------------------------------------------------
// grid -> sheet data -> grid round trip
// ---------------------------------------------------------------------
{
  const grid = [
    ['Item', 'Qty', 'Notes'],
    ['Milk', '2', 'oat | soy'],
    ['Eggs', '12', ''],
  ];
  const data = bridge.gridToSheetData(grid, { headerRow: true, aligns: [null, 'right', null] });
  check('grid header style', data.cellData[0][1].s, 'ts-h-right');
  check('grid plain header style', data.cellData[0][0].s, 'ts-h');
  check('grid number typed', data.cellData[1][1], { v: 2, t: 2, s: 'ts-right' });
  check('grid text kept', data.cellData[1][2].v, 'oat | soy');
  ok('grid empty cell omitted', !data.cellData[2] || !data.cellData[2][2]);

  const back = bridge.snapshotToGrid({ cellData: data.cellData }, data.styles, { minRows: 1, minCols: 1 });
  check('roundtrip grid', back.grid, grid);
  check('roundtrip aligns', back.aligns, [null, 'right', null]);
  check('roundtrip no formula', back.hasFormula, false);
}

// ---------------------------------------------------------------------
// snapshotToGrid — formulas, booleans, rich text, trailing trim
// ---------------------------------------------------------------------
{
  const sheet = {
    cellData: {
      0: { 0: { v: 'a' }, 1: { f: '=1+1', v: 2, t: 2 } },
      1: { 0: { v: 1, t: 3 }, 1: { p: { body: { dataStream: 'rich\rtext\r\n' } } } },
      5: { 3: { v: '' } }, // empty far cell must not stretch the grid
    },
  };
  const r = bridge.snapshotToGrid(sheet, {}, { minRows: 1, minCols: 1 });
  check('snap formula value', r.grid[0][1], '2');
  check('snap formula flag', r.hasFormula, true);
  check('snap boolean', r.grid[1][0], 'TRUE');
  check('snap rich text', r.grid[1][1], 'rich\ntext');
  check('snap dims trimmed', [r.rows, r.cols], [2, 2]);
}

// ---------------------------------------------------------------------
// worksheetToSheetData — formulas, merges, number formats
// ---------------------------------------------------------------------
{
  const ws = XLSX.utils.aoa_to_sheet([
    ['Name', 'Total'],
    ['Widget', 42],
  ]);
  ws.B2.f = '21*2';
  ws.B2.z = '0.00';
  ws.C3 = { t: 'b', v: true };
  ws['!ref'] = 'A1:C3';
  ws['!merges'] = [{ s: { r: 0, c: 0 }, e: { r: 0, c: 1 } }];
  const d = bridge.worksheetToSheetData(ws, XLSX, 'p-');
  check('ws formula', d.cellData[1][1].f, '=21*2');
  check('ws formula cached value', d.cellData[1][1].v, 42);
  check('ws numfmt style id', d.cellData[1][1].s, 'p-nf-0');
  check('ws numfmt pattern', d.numfmts['p-nf-0'], { n: { pattern: '0.00' } });
  check('ws boolean', d.cellData[2][2], { v: 1, t: 3 });
  check('ws merge', d.mergeData, [{ startRow: 0, startColumn: 0, endRow: 0, endColumn: 1 }]);
  check('ws dims', [d.rows, d.cols], [3, 3]);
}

// ---------------------------------------------------------------------
// normalizeSheet / normalizedEqual — data changes count, styling doesn't
// ---------------------------------------------------------------------
{
  const styles = { bold: { bl: 1 }, money: { n: { pattern: '$#,##0' } } };
  const base = {
    cellData: {
      0: { 0: { v: 'a' }, 1: { v: 5, t: 2, s: 'money' } },
    },
    mergeData: [{ startRow: 2, startColumn: 0, endRow: 3, endColumn: 1 }],
  };
  const n1 = bridge.normalizeSheet(base, styles);
  check('norm numfmt captured', n1.cells['0,1'].z, '$#,##0');
  check('norm merges', n1.merges, [[2, 0, 3, 1]]);

  const styledOnly = JSON.parse(JSON.stringify(base));
  styledOnly.cellData[0][0].s = 'bold';
  ok('styling-only equal', bridge.normalizedEqual(n1, bridge.normalizeSheet(styledOnly, styles)));

  const valueChanged = JSON.parse(JSON.stringify(base));
  valueChanged.cellData[0][0].v = 'b';
  ok('value change detected', !bridge.normalizedEqual(n1, bridge.normalizeSheet(valueChanged, styles)));

  const mergeChanged = JSON.parse(JSON.stringify(base));
  mergeChanged.mergeData = [];
  ok('merge change detected', !bridge.normalizedEqual(n1, bridge.normalizeSheet(mergeChanged, styles)));

  const fmtChanged = JSON.parse(JSON.stringify(base));
  fmtChanged.cellData[0][1].s = null;
  ok('numfmt change detected', !bridge.normalizedEqual(n1, bridge.normalizeSheet(fmtChanged, styles)));
}

// ---------------------------------------------------------------------
// patchWorksheet — untouched cells carried by identity, ref grows
// ---------------------------------------------------------------------
{
  const ws = XLSX.utils.aoa_to_sheet([
    ['keep', 'old'],
    ['x', 9],
  ]);
  ws.B2.f = '3*3';
  const styles = {};
  const baseSnap = {
    cellData: {
      0: { 0: { v: 'keep' }, 1: { v: 'old' } },
      1: { 0: { v: 'x' }, 1: { f: '=3*3', v: 9 } },
    },
  };
  const curSnap = JSON.parse(JSON.stringify(baseSnap));
  curSnap.cellData[0][1].v = 'new';   // edited
  delete curSnap.cellData[1][0];      // cleared
  const baseN = bridge.normalizeSheet(baseSnap, styles);
  const curN = bridge.normalizeSheet(curSnap, styles);
  const res = bridge.patchWorksheet(ws, baseN, curN, XLSX);
  ok('patch changed', res.changed);
  ok('patch original untouched', ws.B1.v === 'old');
  check('patch edited cell', res.ws.B1.v, 'new');
  ok('patch cleared cell removed', !res.ws.A2);
  ok('patch untouched identity', res.ws.B2 === ws.B2);
  ok('patch formula untouched', res.ws.B2.f === '3*3');
}

// no-change patch must report changed=false
{
  const ws = XLSX.utils.aoa_to_sheet([['a']]);
  const snap = { cellData: { 0: { 0: { v: 'a' } } } };
  const n = bridge.normalizeSheet(snap, {});
  const res = bridge.patchWorksheet(ws, n, n, XLSX);
  ok('patch noop', !res.changed);
}

// patch must grow !ref when an edit lands outside it
{
  const ws = XLSX.utils.aoa_to_sheet([['a']]); // !ref A1:A1
  const baseSnap = { cellData: { 0: { 0: { v: 'a' } } } };
  const curSnap = { cellData: { 0: { 0: { v: 'a' } }, 4: { 3: { v: 'far' } } } };
  const res = bridge.patchWorksheet(
    ws,
    bridge.normalizeSheet(baseSnap, {}),
    bridge.normalizeSheet(curSnap, {}),
    XLSX
  );
  check('patch ref grown', res.ws['!ref'], 'A1:D5');
  check('patch far cell', res.ws.D5.v, 'far');
}

// ---------------------------------------------------------------------
// normalizedToWorksheet — full rewrite carries formulas/formats/merges
// ---------------------------------------------------------------------
{
  const snap = {
    cellData: {
      0: { 0: { v: 'n', s: 'm' }, 1: { f: '=A2*2', v: 10 } },
      1: { 0: { v: 5, t: 2 } },
    },
    mergeData: [{ startRow: 3, startColumn: 0, endRow: 3, endColumn: 2 }],
  };
  const norm = bridge.normalizeSheet(snap, { m: { n: { pattern: '0%' } } });
  const ws = bridge.normalizedToWorksheet(norm, XLSX);
  check('rewrite formula', ws.B1.f, 'A2*2');
  check('rewrite cached value', ws.B1.v, 10);
  check('rewrite numfmt', ws.A1.z, '0%');
  check('rewrite number', ws.A2, { t: 'n', v: 5 });
  check('rewrite merges', ws['!merges'], [{ s: { r: 3, c: 0 }, e: { r: 3, c: 2 } }]);
  check('rewrite ref', ws['!ref'], 'A1:C4');
}

// ---------------------------------------------------------------------
// mutation classification
// ---------------------------------------------------------------------
for (const id of [
  'sheet.mutation.insert-row',
  'sheet.mutation.remove-rows',
  'sheet.mutation.insert-col',
  'sheet.mutation.remove-col',
  'sheet.mutation.move-rows',
  'sheet.mutation.move-cols',
  'sheet.mutation.move-range',
  'sheet.mutation.reorder-range',
  'sheet.mutation.remove-sheet',
]) {
  ok('structural ' + id, bridge.isStructuralMutation(id));
}
for (const id of [
  'sheet.mutation.set-range-values',
  'sheet.mutation.set-worksheet-row-height',
  'sheet.mutation.add-worksheet-merge',
  'sheet.mutation.set-style',
]) {
  ok('non-structural ' + id, !bridge.isStructuralMutation(id));
}

console.log(`${passed} passed, ${failures} failed`);
process.exit(failures ? 1 : 0);
