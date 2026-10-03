/*
 * Gantt task list assertions (task-groups plan §5, §10.1, milestone G1):
 * the delimited list reader and writer in block.js (boundary, line classes,
 * copies, sections, attached blocks, regionParts), the missing heading
 * fallback, the seed parse, the list-* and seed-* fixtures, the migration
 * twins of the region-* fixtures, the §5.3 properties and the performance
 * guard. From G2 the fold and key assertions run here; those that need the
 * store (banners, actions, held saves) are tagged G2 and asserted under the
 * same names by store_spec.js. Runs under node (dev/run.js) and in the
 * browser (dev/auto_smoke.html).
 */
(function (global) {
  'use strict';
  var GT = global.GT, SPEC = GT.spec;
  var A = SPEC.api, ok = A.ok, eq = A.eq, fix = A.fix, canon = A.canon;
  var B = GT.block, M = GT.model;
  var FIX = global.GT_FIXTURES || {};

  function json(x) { return JSON.stringify(x); }
  function count(hay, needle) { return hay.split(needle).length - 1; }
  function chart(d) { return M.coerce(d).chart; }
  // The list reader and writer are gated behind opts.list (review round 1).
  function LR(text, o) { return B.read(text, Object.assign({ list: true }, o || {})); }
  function RP(c, sums, o) { return B.regionParts(c, sums, Object.assign({ list: true }, o || {})); }
  function read(text, o) { return LR(text, Object.assign({ listDefault: 'Tasks' }, o || {})); }

  // One save as the store will do it (§6.4): read, regionParts with the
  // read's blocks, spill above the region, replace the region. A note in
  // the missing heading state is held (no write).
  function save(text, sums, edit) {
    var r = read(text);
    if (r.missing || r.status !== 'ok') return text;
    var c = edit ? edit(r.chart) : r.chart;
    var p = RP(c, sums || {}, { embedOutside: r.embedOutside, attach: r.list ? r.list.attach : {},
      ambiguous: r.list ? r.list.ambiguous : [] });
    return text.slice(0, r.region.start) + (p.spill ? p.spill + '\n\n' : '') + p.text + text.slice(r.region.end);
  }
  // Every attached block is re-emitted, its lines contiguous and in order.
  function blocksIn(list, out) {
    var miss = [];
    Object.keys(list.attach).forEach(function (k) {
      var b = list.attach[k];
      if (b.length && out.indexOf(b.join('\n')) < 0) miss.push(k + ': ' + json(b));
    });
    return miss;
  }
  function gids(list) { return list.sections.map(function (s) { return s.gid; }); }
  function rowsOf(r, cls) { return r.list.rows.filter(function (x) { return x.cls === cls; }); }
  function lineOf(text, k) { return text.split('\n')[k]; }

  var LINE = {
    kick: '- [Kickoff](synapseresource://note/n-kick?via=gantt) · 2026-09-30',
    int: '- [Customer interviews](synapseresource://note/n-int?via=gantt) · 2026-10-01 → 2026-10-09',
    comp: '- [Competitive teardown](synapseresource://note/n-comp?via=gantt) · 2026-10-05 → 2026-10-14',
    sync: '- [Sync engine](synapseresource://note/n-sync?via=gantt) · 2026-10-12 → 2026-11-06',
    beta: '- ◆ [Beta cut](synapseresource://note/n-beta?via=gantt) · 2026-11-09'
  };
  var INTRO = 'Plan for the release.\n\n';

  /* ======================================================== line classes */

  var CT = { v: 1, settings: { listHeading: 'Tasks' }, groups: [{ id: 'g1', title: 'Build' }],
    tasks: [{ id: 't1', note: 'n1', title: 'T1' }, { id: 't2', note: 'n2', title: 'T2', group: 'g1' }] };
  var FENCE = '```synapse-gantt\n' + B.serialize(chart(CT)) + '\n```';
  function note(lines, data) {
    var f = data ? '```synapse-gantt\n' + B.serialize(chart(data)) + '\n```' : FENCE;
    return '## Tasks\n' + lines.join('\n') + '\n\n' + f;
  }
  function classes(lines, data) {
    var r = LR(note(lines, data));
    return r.list ? r.list.rows.filter(function (x) { return x.line <= lines.length; }).map(function (x) { return x.cls; }) : null;
  }

  function classSpec() {
    var T1 = '(synapseresource://note/n1?via=gantt)';
    [
      ['blank', [''], 'BLANK'], ['spaces only', ['   '], 'BLANK'], ['tab only', ['\t'], 'BLANK'],
      ['L+1 heading', ['### Build'], 'MARKER'], ['L+1 heading, one space', [' ### Build'], 'MARKER'],
      ['L+1 heading, two spaces', ['  ### Build'], 'TEXT'], ['L+1 heading, closing sequence', ['### Build ##'], 'MARKER'],
      ['L+1 heading, tab after the hashes', ['###\tBuild'], 'MARKER'],
      ['heading with no text', ['###'], 'TEXT'], ['heading with only a space', ['### '], 'TEXT'], ['no space after hashes', ['###Build'], 'TEXT'],
      ['level L heading', ['## Notes'], 'TEXT'], ['deeper heading', ['#### Deep'], 'TEXT'], ['seven hashes', ['####### x'], 'TEXT'],
      ['level 1 heading', ['# Title'], 'TEXT'],
      ['MARKED task', ['- [T1]' + T1], 'LINK'], ['bare link', ['[T1]' + T1], 'LINK'],
      ['star bullet', ['* [T1]' + T1], 'LINK'], ['plus bullet', ['+ [T1]' + T1], 'LINK'],
      ['1) item', ['1) [T1]' + T1], 'LINK'], ['1. item', ['1. [T1]' + T1], 'LINK'],
      ['3 spaces of indent', ['   - [T1]' + T1], 'LINK'], ['4 spaces of indent', ['    - [T1]' + T1], 'TEXT'],
      ['tab indent', ['\t- [T1]' + T1], 'TEXT'],
      ['milestone diamond', ['- ◆ [T1]' + T1 + ' · 2026-10-01'], 'LINK'],
      ['full rest', ['- [T1]' + T1 + ' · 2026-10-01 → 2026-10-09 · 1/2'], 'LINK'],
      ['progress only', ['- [T1]' + T1 + ' · 1/2'], 'LINK'],
      ['trailing spaces', ['- [T1]' + T1 + '   '], 'LINK'],
      ['text after rest', ['- [T1]' + T1 + ' · 2026-10-01 more'], 'TEXT'],
      ['PLAIN link', ['[T1](synapseresource://note/n1)'], 'LINK'],
      ['two links on one line', ['[a](synapseresource://note/n1) [b](synapseresource://note/n2)'], 'TEXT'],
      ['"](" in link text', ['- [a](b)](synapseresource://note/n1?via=gantt)'], 'TEXT'],
      ['foreign link', ['- [X](synapseresource://note/zz-1?via=gantt)'], 'LINK'],
      ['web link', ['- [Docs](https://example.com)'], 'TEXT'],
      ['bold then indented MARKED task', ['- **Build**', '  - [T2](synapseresource://note/n2?via=gantt)'], 'LEGACY'],
      ['bold then unindented task', ['- **Build**', '- [T2](synapseresource://note/n2?via=gantt)'], 'TEXT'],
      ['bold then indented PLAIN task', ['- **Build**', '  - [T2](synapseresource://note/n2)'], 'TEXT'],
      ['bold then indented foreign link', ['- **Build**', '  - [X](synapseresource://note/zz?via=gantt)'], 'TEXT'],
      ['bold then 3-space task', ['- **Build**', '   - [T2](synapseresource://note/n2?via=gantt)'], 'TEXT'],
      ['bold alone', ['- **Waiting on legal**'], 'TEXT'],
      ['embed line', [B.embedLine()], 'EMBED'],
      ['other app embed', ['@[100% x 420](synapseresource://app/other?note=current&mode=embed)'], 'TEXT'],
      ['table row', ['| a | b |'], 'TEXT']
    ].forEach(function (c) {
      eq('class: ' + c[0], (classes(c[1]) || [])[0], c[2]);
    });
    eq('class: fenced code lines are CODE, even marker and task lines',
      json(classes(['```', '### Build', '- [T1]' + T1, '```'])), json(['CODE', 'CODE', 'CODE', 'CODE']));
    eq('class: a blank line inside code is CODE', json(classes(['~~~', '', '~~~'])), json(['CODE', 'CODE', 'CODE']));
    var crlf = LR(note(['### Build', '- [T2](synapseresource://note/n2?via=gantt)']).replace(/\n/g, '\r\n'));
    eq('class: CRLF lines classify like LF', json(crlf.list.rows.map(function (x) { return x.cls; }).slice(0, 2)), json(['MARKER', 'LINK']));
    eq('class: a heading at L+1 is a marker whatever follows it', json(classes(['### Build', 'prose'])), json(['MARKER', 'TEXT']));
    eq('heading(): closing sequence stripped', json(B.heading('## Tasks ##')), json({ level: 2, text: 'Tasks ##', stripped: 'Tasks' }));
    eq('heading(): a text of hashes keeps them', B.heading('## #').stripped, '#');

    // Copies (5.2.4).
    var cp = function (lines) { return LR(note(lines)).list; };
    var M1 = '- [T1]' + T1, P1 = '[T1](synapseresource://note/n1)';
    eq('copies: two MARKED lines are ambiguous', json(cp([M1, M1]).ambiguous), json(['t1']));
    eq('copies: two PLAIN lines and no MARKED are ambiguous', json(cp([P1, P1]).ambiguous), json(['t1']));
    var mp = cp([M1, P1]);
    ok('copies: one MARKED and one PLAIN: not ambiguous, the MARKED line is owned',
      !mp.ambiguous.length && mp.rows[0].owned && !mp.rows[1].owned);
    var po = cp([P1]);
    ok('copies: a single PLAIN line is owned', !po.ambiguous.length && po.rows[0].owned && po.sections[0].tasks[0] === 't1');
    eq('copies: a MARKED line in a code block does not count', json(cp([M1, '```', M1, '```']).ambiguous), json([]));
    eq('copies: ambiguous lines are attached', json(cp(['### Build', M1, M1]).attach['g:g1']), json([M1, M1]));

    // Blocks (5.2.5): edge blank lines trimmed, inner kept.
    var bl = cp([M1, '', '', 'prose a', '', 'prose b', '', '']);
    eq('blocks: edge blanks trimmed, inner kept', json(bl.attach['t:t1']), json(['prose a', '', 'prose b']));
    eq('blocks: every owner has a key in read order', Object.keys(bl.attach).join(','), 'h,t:t1');
    var hb = cp(['Intro under the heading.', '### Build', '  note under the marker', M1]);
    eq('blocks: lines under the list heading are the h block', json(hb.attach.h), json(['Intro under the heading.']));
    eq('blocks: lines under a marker are its block', json(hb.attach['g:g1']), json(['  note under the marker']));
    var eb = LR(note(['head block', B.embedLine(), 'embed block'], Object.assign({}, CT, { settings: { listHeading: 'Tasks', embed: true } }))).list;
    eq('blocks: the heading and embed blocks join with one blank line', json(eb.attach.h), json(['head block', '', 'embed block']));
  }

  /* ============================================================ boundary */

  function boundarySpec() {
    var two = '## Tasks\nold\n\n## Tasks\n\n- [T1](synapseresource://note/n1?via=gantt)\n\n' + FENCE;
    eq('boundary: the nearest list heading wins', LR(two).region.text.indexOf('## Tasks\n\n- [T1]'), 0);
    var inCode = '## Tasks\n\n```\n## Tasks\n```\n\n- [T1](synapseresource://note/n1?via=gantt)\n\n' + FENCE;
    eq('boundary: a heading inside another code block is not the list heading', LR(inCode).region.start, 0);
    var lv = LR('### Tasks\n\n' + FENCE);
    ok('boundary: level must match (### Tasks is a marker, so the note is headless)', lv.missing && lv.list === null);
    eq('boundary: text must match (case-sensitive)', LR('## tasks\n\n' + FENCE).list.heading, null);
    eq('boundary: whitespace in the text is normalised', LR('##  Tasks  \n\n' + FENCE).region.start, 0);
    eq('boundary: a closing sequence is allowed', LR('## Tasks ##\n\n' + FENCE).region.start, 0);
    eq('boundary: one leading space is allowed', LR(' ## Tasks\n\n' + FENCE).region.start, 0);
    eq('boundary: two leading spaces are not a heading', LR('  ## Tasks\n\n' + FENCE).list.heading, null);
    eq('boundary: nothing between the heading and the fence is required', LR('## Tasks\n' + FENCE).list.heading.line, 0);
    [1, 2, 3, 4, 5].forEach(function (L) {
      var c = chart({ v: 1, settings: { listHeading: 'Tasks', listLevel: L }, groups: [{ id: 'g1', title: 'Build' }],
        tasks: [{ id: 't1', note: 'n1', title: 'A', group: 'g1' }] });
      var t = 'Intro.\n\n' + RP(c, {}).text, r = LR(t);
      ok('boundary: listLevel ' + L + ' round-trips', r.list && r.region.start === 8 && r.list.sections[1].gid === 'g1' &&
        r.list.sections[1].marker.level === L + 1 && lineOf(t, 2).indexOf(new Array(L + 1).join('#') + ' Tasks') === 0);
    });
    var conf = B.listConf(chart({ v: 1, settings: { listHeading: 'Plan', listLevel: 9 } }));
    eq('listConf: an out-of-range level reads as 2', conf.L, 2);
    eq('listConf: no heading on a chart without the key', B.listConf(chart({ v: 1 })).h, null);
    eq('listConf: a blank heading is no heading', B.listConf(chart({ v: 1, settings: { listHeading: '  ' } })).h, null);
    eq('B.region with opts.list writes the delimited region for a list chart', B.region(chart(CT), {}, { list: true }).indexOf('## Tasks\n\n- [T1]'), 0);
    eq('B.region writes the legacy region for a chart without a heading', B.region(chart({ v: 1, tasks: CT.tasks }), {}, { list: true }).indexOf('- [T1]'), 0);
  }

  /* ============================================================== writer */

  function writerSpec() {
    var c = chart({ v: 1, settings: { listHeading: 'Tasks' }, groups: [{ id: 'g1', title: 'Build' }, { id: 'g2', title: 'Empty' }],
      tasks: [{ id: 't1', note: 'n1', title: 'A](x) [b' }, { id: 't2', note: 'n2', title: 'B', group: 'g1', milestone: true, start: '2026-10-01' },
        { id: 't3', title: 'Bare', milestone: true, start: '2026-10-02', group: 'g1' }] });
    var p = RP(c, {}, {});
    eq('writer: the whole region', p.text.split('```')[0],
      '## Tasks\n\n- [A］(x) ［b](synapseresource://note/n1?via=gantt)\n\n### Build\n- ◆ [B](synapseresource://note/n2?via=gantt) · 2026-10-01\n\n### Empty\n\n');
    eq('writer: attach lists every written owner in write order', Object.keys(p.attach).join(','), 'h,t:t1,g:g1,t:t2,g:g2');
    eq('writer: a note-less milestone has no line', count(p.text, 'Bare'), 1);
    eq('writer: ltext never leaves "](" in link text', B.ltext('a](b'), 'a］(b');
    eq('writer: htext of "" is Untitled', B.htext('  '), 'Untitled');
    var sep = RP(c, {}, { attach: { 't:t1': ['prose'], 't:t2': ['- item'], 'g:g2': ['  indented'] } }).text;
    ok('writer: a prose block gets one blank line before it', sep.indexOf('?via=gantt)\n\nprose\n\n### Build') > 0, sep);
    ok('writer: a list-item block gets none', sep.indexOf('2026-10-01\n- item\n\n### Empty') > 0, sep);
    ok('writer: an indented block gets none', sep.indexOf('### Empty\n  indented\n\n```') > 0, sep);
    var hb = RP(c, {}, { attach: { h: ['- first'] } }).text;
    ok('writer: the h block follows the heading after one blank line', hb.indexOf('## Tasks\n\n- first\n\n- [A') === 0, hb);
    var orphan = RP(c, {}, { attach: { h: [], 't:t1': ['a'], 't:gone': ['orphan'], 'g:g1': ['b'], 'g:x': ['c'] } });
    eq('writer: orphan blocks join the preceding written owner', json([orphan.attach['t:t1'], orphan.attach['g:g1']]), json([['a', '', 'orphan'], ['b', '', 'c']]));
    var first = RP(c, {}, { attach: { 't:gone': ['first orphan'], h: ['h'] } });
    eq('writer: an orphan with no written owner before it goes to h', json(first.attach.h), json(['first orphan', '', 'h']));
    var amb = RP(c, {}, { attach: { h: [], 't:t1': [], 'g:g1': [], 't:t2': ['kept'] }, ambiguous: ['t2'] });
    ok('writer: an ambiguous task is not written and its block re-homes', amb.text.indexOf('[B]') < 0 && amb.attach['g:g1'][0] === 'kept', amb.text);
    var off = RP(M.setSettings(c, { mirror: false }).chart, {}, { attach: { h: ['x'], 't:t1': ['y', '', 'z'] } });
    eq('writer: list off spills every block', off.spill, 'x\n\ny\n\nz');
    ok('writer: list off writes the main spec region', off.text.indexOf('```synapse-gantt') === 0 && json(off.attach) === '{}');
    eq('writer: a chart without a heading spills too', RP(chart({ v: 1 }), {}, { attach: { h: ['x'] } }).spill, 'x');
  }

  /* ========================================================= fixture table */

  var EX_SUMS = { t1: { done: 3, total: 5 }, t2: { done: 0, total: 4 }, t3: { done: 6, total: 10 } };
  var G2 = [];   // G2 assertion names asserted by the store spec (banners, actions, held saves)
  function g2(name) { G2.push(name); }

  function restoreOf(x) { return B.restoreHeading(x, { listDefault: 'Tasks' }); }

  var CASES = {
    'list-basic.md': { sums: EX_SUMS, check: function (x, r, s1) {
      eq('list-basic: saves byte-exact', s1, x);
      eq('list-basic: region starts at ## Tasks', r.region.text.indexOf('## Tasks\n\n- [Kickoff]'), 0);
      eq('list-basic: the indented note stays under its task', json(r.list.attach['t:t1']), json(['  - Owner: Ana. Waiting on two more calls.']));
      eq('list-basic: the prose line stays under Beta cut', json(r.list.attach['t:t4']), json(['Remember to book the launch room.']));
      eq('list-basic: sections', json(r.list.sections.map(function (s) { return (s.gid || '-') + ':' + s.tasks.join('+'); })), json(['-:t0', 'g1:t1+t2', 'g2:t3+t4', 'g3:']));
      eq('list-basic: key is the body key', r.key, r.bodyKey);
    } },
    'list-typed-headings.md': { check: function (x, r, s1) {
      eq('list-typed-headings: both ## headings are TEXT', rowsOf(r, 'MARKER').length + rowsOf(r, 'LEGACY').length, 0);
      eq('list-typed-headings: promote candidates', json(r.list.promote.map(function (p) { return p.text + '@' + p.owner; })), json(['Group 1@h', 'Group 2@t:t2']));
      ok('list-typed-headings: kept as ## in place after a save', s1.indexOf('## Tasks\n\n## Group 1\n\n- [Kickoff]') > 0 && s1.indexOf(LINE.comp + '\n\n## Group 2\n' + LINE.sync) > 0, s1);
      ok('list-typed-headings: nothing written at L+1', s1.indexOf('### ') < 0);
      g2('list-typed-headings: Make groups gives two groups, tasks folded, written back as ###');
    } },
    'list-typed-above-fence.md': { check: function (x, r, s1) {
      ok('list-typed-above-fence: both lines are inside the region', r.region.text.indexOf('## Tasks') === 0 && r.region.text.indexOf('Ask Ana') > 0);
      var last = r.list.sections[r.list.sections.length - 1].marker;
      ok('list-typed-above-fence: the heading is a new marker', last.title === 'QA' && last.kind === 'new', json(last));
      eq('list-typed-above-fence: the line is attached to Launch', json(r.list.attach['g:g3']), json(['Ask Ana about the date']));
      // G2: the read folds QA in, so the save writes its marker after the line.
      ok('list-typed-above-fence: the line is kept above the fence', s1.indexOf('### Launch\n\nAsk Ana about the date\n\n### QA\n\n```synapse-gantt') > 0, s1);
      ok('list-typed-above-fence: QA becomes a group and is written as ### QA; key composite',
        r.key === r.bodyKey + '#' + B.hash(r.list.sig) && r.chart.groups.map(function (g) { return g.title; }).join() === 'Discovery,Build,Launch,QA' &&
        r.json.groups.length === 3 && read(s1).key === read(s1).bodyKey, json(r.chart.groups));
    } },
    'list-prose-inside.md': { check: function (x, r, s1) {
      eq('list-prose-inside: saves byte-exact', s1, x);
      eq('list-prose-inside: nothing splits', r.list.sections.length, 4);
      eq('list-prose-inside: the code lines are CODE', rowsOf(r, 'CODE').length, 4);
      eq('list-prose-inside: the quoted task line is no copy', json(r.list.ambiguous), json([]));
      eq('list-prose-inside: prose and code attached to Competitive teardown',
        json(r.list.attach['t:t2']), json(['Next: hire a PM before the build.', '', '```text', '### Not a marker', LINE.sync, '```']));
    } },
    'list-two-links.md': { check: function (x, r, s1) {
      eq('list-two-links: saves byte-exact', s1, x);
      eq('list-two-links: attached verbatim', json(r.list.attach['t:t3']), json(['- [Spec](synapseresource://note/n-spec) and [Design](synapseresource://note/n-design?via=gantt)']));
      eq('list-two-links: no offer', r.list.offers.length, 0);
    } },
    'list-bold-inside.md': { check: function (x, r, s1) {
      eq('list-bold-inside: saves byte-exact', s1, x);
      eq('list-bold-inside: no LEGACY, no new section', rowsOf(r, 'LEGACY').length + ':' + r.list.sections.length, '0:4');
      eq('list-bold-inside: attached', json(r.list.attach['t:t3']), json(['- **Waiting on legal**']));
    } },
    'list-attached-notes.md': { check: function (x, r, s1) {
      eq('list-attached-notes: saves byte-exact', s1, x);
      var moved = save(x, {}, function (c) { return M.setTask(c, 't3', { group: 'g3' }).chart; });
      ok('list-attached-notes: the note moves with Sync engine', moved.indexOf('### Launch\n' + LINE.sync + '\n  - waiting on legal\n\n```') > 0, moved);
      ok('list-attached-notes: the marker note stays with Build', moved.indexOf('### Build\n  Scope: two sprints.\n' + LINE.beta) > 0, moved);
      eq('list-attached-notes: stable after the move', save(moved), moved);
    } },
    'list-orphans.md': { check: function (x, r, s1) {
      eq('list-orphans: saves byte-exact', s1, x);
      var out = save(x, {}, function (c) { return M.removeGroup(M.removeTask(c, 't2').chart, 'g3').chart; });
      ok('list-orphans: a removed task\'s block joins the task above', out.indexOf(LINE.int + '\n  - three vendors so far\n\n### Build') > 0, out);
      ok('list-orphans: a removed group\'s block joins the owner above', out.indexOf(LINE.beta + '\n  Needs a date.\n\n```') > 0, out);
      eq('list-orphans: stable after', save(out), out);
    } },
    'list-mirror-off-spill.md': { check: function (x, r, s1) {
      eq('list-mirror-off-spill: saves byte-exact', s1, x);
      var off = save(x, {}, function (c) { return M.setSettings(c, { mirror: false }).chart; });
      ok('list-mirror-off-spill: blocks written above the fence as user text',
        off.indexOf(INTRO + '  - Owner: Ana\n\nBuild starts after the review.\n\n```synapse-gantt') === 0, off);
      ok('list-mirror-off-spill: no list is left', off.indexOf('## Tasks') < 0 && off.indexOf('- [Kickoff]') < 0);
      eq('list-mirror-off-spill: stable after', save(off), off);
    } },
    'list-empty-group.md': { check: function (x, r, s1) {
      eq('list-empty-group: saves byte-exact', s1, x);
      eq('list-empty-group: empty groups first, middle and last map back', json(gids(r.list)), json([null, 'ge1', 'g1', 'ge2', 'g2', 'ge3']));
    } },
    'list-untitled-group.md': { check: function (x, r, s1) {
      eq('list-untitled-group: saves byte-exact', s1, x);
      eq('list-untitled-group: "" is written ### Untitled', count(x, '### Untitled\n'), 2);
      eq('list-untitled-group: "" and Untitled map back by overlap then order', json(gids(r.list)), json([null, 'g1', 'g2', 'g3']));
      eq('list-untitled-group: the block stays with the "" group', json(r.list.attach['g:g1']), json(['Notes for the untitled group.']));
    } },
    'list-duplicate-titles.md': { check: function (x, r, s1) {
      eq('list-duplicate-titles: saves byte-exact', s1, x);
      eq('list-duplicate-titles: in order', json(gids(r.list)), json([null, 'g1', 'g2', 'g3']));
      var parts = x.split('### Build\n'), swapped = parts[0] + '### Build\n' + parts[2].replace(/\n\n$/, '\n\n') + '### Build\n' + parts[1] + '### Build\n' + parts[3];
      var rs = LR(swapped);
      eq('list-duplicate-titles: swapped sections pair by overlap', json(gids(rs.list)), json([null, 'g2', 'g1', 'g3']));
      eq('list-duplicate-titles: all same-title pairs', rs.list.sections.slice(1).map(function (s) { return s.marker.kind; }).join(','), 'same,same,same');
    } },
    'list-group-named-like-heading.md': { check: function (x, r, s1) {
      eq('list-group-named-like-heading: saves byte-exact', s1, x);
      ok('list-group-named-like-heading: the group is ### Tasks, the list heading ## Tasks',
        r.region.text.indexOf('## Tasks\n') === 0 && count(x, '\n### Tasks\n') === 1 && r.list.sections[1].gid === 'g1');
    } },
    'list-new-heading.md': { check: function (x, r, s1) {
      var m = r.list.sections[4].marker, again = LR('Prose added above.\n\n' + x).list.sections[4].marker;
      ok('list-new-heading: a new marker with a derived id', m.kind === 'new' && m.title === 'QA' && /^g[0-9a-z]{6}$/.test(m.gid), json(m));
      eq('list-new-heading: same id on two reads', again.gid, m.gid);
      var rep = B.listReport(x);
      eq('list-new-heading: report', json([rep.newGroups.map(function (g) { return g.title; }), rep.moved]), json([['QA'], [{ id: 't4', from: 'g2', to: m.gid }]]));
      var qa = r.chart.groups.filter(function (g) { return g.id === m.gid; })[0], r1 = read(s1);
      ok('list-new-heading: new group folded; key composite; body key after one save',
        !!qa && qa.title === 'QA' && M.task(r.chart, 't4').group === m.gid && r.key !== r.bodyKey && r.key.indexOf(r.bodyKey + '#') === 0 &&
        r1.key === r1.bodyKey && B.serialize(r1.chart) === B.serialize(r.chart) && s1.indexOf('### QA\n' + LINE.beta) > 0, s1);
    } },
    'list-renamed-heading.md': { check: function (x, r) {
      eq('list-renamed-heading: kinds', r.list.sections.slice(1).map(function (s) { return s.marker.kind + ':' + s.gid; }).join(','), 'same:g1,overlap:g2,position:g3');
      eq('list-renamed-heading: report', json(B.listReport(x).renamed), json([{ id: 'g2', from: 'Build', to: 'Construction' }, { id: 'g3', from: 'Launch', to: 'Release' }]));
      eq('list-renamed-heading: same ids, new titles folded', json(r.chart.groups.map(function (g) { return g.id + ':' + g.title; })), json(['g1:Discovery', 'g2:Construction', 'g3:Release']));
      ok('list-renamed-heading: key composite, then the body key after one save', r.key !== r.bodyKey && read(save(x)).key === read(save(x)).bodyKey);
    } },
    'list-reordered-sections.md': { check: function (x, r) {
      eq('list-reordered-sections: sections map by title', json(gids(r.list)), json([null, 'g2', 'g1', 'g3']));
      eq('list-reordered-sections: no task moved', B.listReport(x).moved.length, 0);
      eq('list-reordered-sections: group order follows', json(r.chart.groups.map(function (g) { return g.id; })), json(['g2', 'g1', 'g3']));
      ok('list-reordered-sections: key composite; the fold reports a group reorder only', r.key !== r.bodyKey && r.fold.report.groupsReordered && !r.fold.report.moved.length);
    } },
    'list-heading-deleted.md': { check: function (x, r, s1) {
      var rep = B.listReport(x);
      eq('list-heading-deleted: Build is gone, its tasks held', json([rep.goneGroups, rep.held, rep.moved]), json([['g2'], ['t3', 't4'], []]));
      ok('list-heading-deleted: a save writes the marker back', s1.indexOf('### Build\n' + LINE.sync) > 0);
      g2('list-heading-deleted: removal banner; Remove moves held tasks to their placement');
    } },
    'list-duplicate-marker.md': { check: function (x, r, s1) {
      var rep = B.listReport(x);
      eq('list-duplicate-marker: duplicate, held, nothing new', json([rep.duplicates.map(function (d) { return d.title + '=' + d.gid; }), rep.held, rep.newGroups]), json([['Build=g2'], ['t0'], []]));
      ok('list-duplicate-marker: one ### Build after a save; Kickoff ungrouped', count(s1, '### Build\n') === 1 && s1.indexOf('## Tasks\n\n' + LINE.kick) > 0, s1);
      g2('list-duplicate-marker: banner "Listed more than once"');
    } },
    'list-foreign-links.md': { check: function (x, r, s1) {
      eq('list-foreign-links: saves byte-exact', s1, x);
      eq('list-foreign-links: unindented foreign links are offers with group and position',
        json(r.list.offers.map(function (o) { return o.note + '|' + o.group + '|' + o.after; })), json(['n-vendor|g1|t2', 'n-qa|g1|t2']));
      ok('list-foreign-links: indented and heading-scoped links are no offers', !r.list.offers.some(function (o) { return o.note === 'n-ref' || o.note === 'n-wiki'; }));
      g2('list-foreign-links: Added in the note banner; Add places per note');
    } },
    'list-no-via.md': { check: function (x, r, s1) {
      var row = r.list.rows.filter(function (q) { return q.task === 't0'; })[0];
      ok('list-no-via: the PLAIN picker link is the owned line', row && row.owned && r.list.sections[2].tasks.indexOf('t0') >= 0);
      ok('list-no-via: a save rewrites it MARKED', count(s1, LINE.kick) === 1 && s1.indexOf('[Kickoff](synapseresource://note/n-kick)') < 0, s1);
      eq('list-no-via: report moves it to Build', json(B.listReport(x).moved), json([{ id: 't0', from: null, to: 'g2' }]));
      ok('list-no-via: Kickoff folded into Build', M.task(r.chart, 't0').group === 'g2' && r.json.tasks[0].group === null && r.key !== r.bodyKey);
    } },
    'list-copy-inside.md': { check: function (x, r, s1) {
      eq('list-copy-inside: ambiguous', json(r.list.ambiguous), json(['t3']));
      var s = s1;
      for (var i = 0; i < 4; i++) s = save(s);
      ok('list-copy-inside: both kept, stable over five saves', count(s, LINE.sync) === 2 && s === s1, s);
      eq('list-copy-inside: JSON group kept', read(s).chart.tasks[3].group, 'g2');
      g2('list-copy-inside: banner "Listed more than once"');
    } },
    'list-copy-above.md': { check: function (x, r, s1) {
      eq('list-copy-above: saves byte-exact', s1, x);
      ok('list-copy-above: the copy above is not read', !r.list.ambiguous.length && r.list.sections[2].tasks.join() === 't3,t4');
    } },
    'list-user-sections-above.md': { check: function (x, r, s1) {
      eq('list-user-sections-above: saves byte-exact', s1, x);
      eq('list-user-sections-above: the region starts at the lower ## Tasks', r.region.start, x.lastIndexOf('## Tasks'));
      eq('list-user-sections-above: nothing above is read', json(r.list.ambiguous), json([]));
    } },
    'list-level-3.md': { check: function (x, r, s1) {
      eq('list-level-3: saves byte-exact', s1, x);
      ok('list-level-3: ### list heading, #### markers', r.region.text.indexOf('### Tasks\n') === 0 && count(x, '\n#### ') === 3 && r.list.sections.length === 4);
      eq('list-level-3: a ## inside is attached text', json(r.list.attach['t:t2']), json(['## Aside', 'An aside inside the list.']));
      eq('list-level-3: no promote offer for a shallower heading', r.list.promote.length, 0);
    } },
    'list-level-mismatch.md': { check: function (x, r, s1) {
      eq('list-level-mismatch: the ##### line is attached', json(r.list.attach['t:t2']), json(['##### Build']));
      eq('list-level-mismatch: Build is gone', json(B.listReport(x).goneGroups), json(['g2']));
      ok('list-level-mismatch: a save writes ### Build back below it', s1.indexOf(LINE.comp + '\n\n##### Build\n\n### Build\n' + LINE.sync) > 0, s1);
    } },
    'list-shadow-group.md': { check: function (x, r, s1) {
      eq('list-shadow-group: saves byte-exact', s1, x);
      ok('list-shadow-group: the shadow is kept', r.chart.tasks[0].group === null && r.chart.tasks[0]._x.group === 'gone-1' && s1.indexOf('"group":"gone-1"') > 0);
      eq('list-shadow-group: no move reported', B.listReport(x).moved.length, 0);
      ok('list-shadow-group: no composite key', r.key === r.bodyKey && !r.fold.changed);
    } },
    'list-crlf.md': { check: function (x, r, s1) {
      eq('list-crlf: region found', r.region.text.indexOf('## Tasks\r\n'), 0);
      eq('list-crlf: attached content has no CR', json(r.list.attach['t:t1']), json(['  - Owner: Ana']));
      var r1 = read(s1);
      ok('list-crlf: region LF only after the save', r1.region.text.indexOf('\r') < 0);
      eq('list-crlf: bytes before untouched', s1.slice(0, r.region.start), x.slice(0, r.region.start));
      eq('list-crlf: bytes after untouched', s1.slice(r1.region.end), x.slice(r.region.end));
    } },
    'list-cjk.md': { check: function (x, r, s1) {
      eq('list-cjk: saves byte-exact', s1, x);
      ok('list-cjk: 任务 heading, CJK markers', r.list.heading.text === '任务' && json(gids(r.list)) === json([null, 'g1', 'g2']));
      ok('list-cjk: fullwidth brackets and emoji kept', x.indexOf('[［草稿］评审 🚀]') > 0 && x.indexOf('[发布 ◆ ［beta]') > 0 && x.indexOf('### 设计 🎨') > 0);
    } },
    'list-embed.md': { check: function (x, r, s1) {
      var EMB = B.embedLine();
      eq('list-embed: saves byte-exact', s1, x);
      eq('list-embed: heading, embed, list, fence', r.region.text.indexOf('## Tasks\n\n' + EMB + '\n\n- [Kickoff]'), 0);
      var y = x.replace(INTRO, INTRO + EMB + '\n\n'), ry = read(y), sy = save(y);
      ok('list-embed: an embed line elsewhere sets embedOutside', ry.embedOutside && count(sy, EMB) === 1 && save(sy) === sy, sy);
    } },
    'list-malformed.md': { check: function (x, r) {
      ok('list-malformed: the list heading comes from the raw body', r.status === 'malformed' && r.region.text.indexOf('## Tasks') === 0 && !r.list);
      eq('list-malformed: attached lines, every link FOREIGN, come back as spill', r.spill,
        LINE.kick + '\nRemember the vendor call.\n\n' + LINE.sync + '\n  - owner: Ana');
      var fixed = B.splice(x, B.region(M.empty(), {}), { list: true });
      eq('list-malformed: Repair replaces the region and keeps the attached lines above it', fixed,
        INTRO + r.spill + '\n\n```synapse-gantt\n{"v":1}\n```\n\nAfter the chart.');
      eq('list-malformed: without opts.list the region is main spec §5.6 (the fence)', B.read(x).region.text.indexOf('```synapse-gantt'), 0);
    }, noSave: true },
    'list-legacy-migrate.md': { sums: EX_SUMS, check: function (x, r, s1, s2) {
      var plain = LR(x);
      ok('list-legacy-migrate: without a default it reads as today', plain.legacy && !plain.defaulted && plain.key === plain.bodyKey && B.listConf(plain.chart).h === null);
      ok('list-legacy-migrate: default heading, legacy region, no list', r.legacy && r.defaulted && B.listConf(r.chart).h === 'Tasks' &&
        r.region.text.indexOf('- **Discovery**') === 0 && r.list === null);
      ok('list-legacy-migrate: composite key from the default heading', r.key !== r.bodyKey && r.key.indexOf(r.bodyKey + '#') === 0);
      ok('list-legacy-migrate: the first save writes the delimited region', s1.indexOf('\n\n## Tasks\n\n### Discovery\n- [Customer interviews]') > 0 && s1.indexOf('"listHeading":"Tasks"') > 0, s1);
      var r1 = read(s1);
      ok('list-legacy-migrate: then it is a list chart with a body key', !r1.legacy && r1.list && r1.key === r1.bodyKey);
      eq('list-legacy-migrate: the second save is identical', s2, s1);
    } },
    'list-missing-heading-prose.md': { missing: true, check: function (x, r) {
      ok('list-missing-heading-prose: fallback from the note start', r.fallback.line === 0 && r.fallback.p0 === 'Plan for the release.' && r.fallback.useAs === null, json(r.fallback));
      var fixed = restoreOf(x);
      eq('list-missing-heading-prose: Restore heading inserts ## Tasks after P0', fixed, x.replace(INTRO, INTRO + '## Tasks\n\n'));
      var xc = x.replace(/\n/g, '\r\n');
      eq('list-missing-heading-prose: on a CRLF note P0 keeps its \\r and the inserted lines are CRLF', restoreOf(xc), fixed.replace(/\n/g, '\r\n'));
      var rf = read(fixed), edited = save(fixed, {}, function (c) { return M.setTask(c, 't1', { title: 'User interviews' }).chart; });
      ok('list-missing-heading-prose: the next read is normal and the held edit saves', !rf.missing && rf.list &&
        edited.indexOf('- [User interviews]') > 0 && edited.indexOf(LINE.comp + '\n\nNext: hire a PM.\n\n### Build') > 0, edited);
      g2('list-missing-heading-prose: saveOnce returns heading-missing, pill text, journal kept');
    } },
    'list-missing-heading-empty-last.md': { missing: true, check: function (x, r) {
      ok('list-missing-heading-empty-last: the empty last marker is inside the fallback', r.fallback.text.indexOf('### Launch\n\n```') > 0);
      var fixed = restoreOf(x);
      eq('list-missing-heading-empty-last: Restore heading writes one heading line', fixed.split('\n').length, x.split('\n').length + 2);
      eq('list-missing-heading-empty-last: nothing else changes on the next save', save(fixed), fixed);
    } },
    'list-missing-heading-above-fence.md': { missing: true, check: function (x, r) {
      var fixed = restoreOf(x), s = save(fixed);
      ok('list-missing-heading-above-fence: the line is kept, no second list',
        count(s, '## Tasks') === 1 && count(s, LINE.sync) === 1 && s.indexOf('### Launch\n\nAsk Ana about the date\n\n```') > 0, s);
      eq('list-missing-heading-above-fence: stable', save(s), s);
    } },
    'list-missing-heading-typo.md': { missing: true, check: function (x, r) {
      ok('list-missing-heading-typo: P0 is the mistyped heading', r.fallback.p0 === '## Taks' && r.fallback.useAs === 'Taks', json(r.fallback));
      eq('list-missing-heading-typo: Restore heading inserts ## Tasks below it', restoreOf(x), x.replace('## Taks\n\n', '## Taks\n\n## Tasks\n\n'));
      var use = x.replace('"listHeading":"Tasks"', '"listHeading":"Taks"'), ru = read(use);
      ok('list-missing-heading-typo: Use as the list heading leaves the missing state', !ru.missing && ru.list.heading.text === 'Taks' && save(use) === use);
      g2('list-missing-heading-typo: the held save proceeds after Use as list heading');
    } },
    'list-missing-heading-none.md': { missing: true, check: function (x, r) {
      ok('list-missing-heading-none: fallback from the note start, P0 empty', r.fallback.line === 0 && r.fallback.p0 === '');
      eq('list-missing-heading-none: Restore heading starts with ## Tasks', restoreOf(x), '## Tasks\n\n' + x);
    } },
    'list-missing-heading-inside-text-heading.md': { missing: true, check: function (x, r) {
      ok('list-missing-heading-inside-text-heading: the climb passes ## Notes', r.fallback.line === 0 && r.fallback.p0 === 'Plan for the release.');
      var fixed = restoreOf(x), rf = read(fixed), s = save(fixed);
      ok('list-missing-heading-inside-text-heading: ## Tasks above the whole list, ## Notes inside as TEXT',
        fixed.indexOf(INTRO + '## Tasks\n\n' + LINE.kick) === 0 && rf.list.sections.length === 4 && rf.list.attach['t:t2'][0] === '## Notes');
      eq('list-missing-heading-inside-text-heading: stable', s, fixed);
    } },
    'list-missing-heading-stale-copy.md': { missing: true, check: function (x, r) {
      ok('list-missing-heading-stale-copy: the climb reaches the section through a joined segment', r.fallback.p0 === '## My notes\nRemember:', json(r.fallback));
      var fixed = restoreOf(x), rf = read(fixed), s = save(fixed);
      ok('list-missing-heading-stale-copy: after Restore the task is ambiguous', json(rf.list.ambiguous) === json(['t3']) && rf.list.sections[2].tasks.join() === 't4');
      ok('list-missing-heading-stale-copy: nothing lost, stable', count(s, LINE.sync) === 2 && save(s) === s && blocksIn(rf.list, s).length === 0, s);
    } },
    'list-missing-heading-text-heading-last.md': { missing: true, check: function (x, r) {
      ok('list-missing-heading-text-heading-last: segment 1 (## Notes to the fence) is crossed', r.fallback.line === 0 && r.fallback.p0 === 'Plan for the release.', json(r.fallback));
      var fixed = restoreOf(x), s = save(fixed);
      ok('list-missing-heading-text-heading-last: Restore heading, ## Notes kept under Launch, one list',
        fixed === x.replace(INTRO, INTRO + '## Tasks\n\n') && s === fixed && count(s, LINE.sync) === 1 && s.indexOf('### Launch\n\n## Notes\nA note at the end of the list.\n\n```') > 0, s);
      // Threshold: a chain holding MARKED lines for fewer than half the noted
      // tasks is not crossed to; the list is gone.
      var gone = 'Plan.\n\n## My notes\nRemember:\n' + LINE.sync + '\n\n## Notes\nprose\n\n' + x.slice(x.indexOf('```synapse-gantt'));
      var rg = read(gone);
      ok('list-missing-heading-text-heading-last: one stale copy above a deleted list is "list gone"', !rg.missing && rg.list && rg.list.heading === null &&
        json(B.listReport(gone).deleted) === json(['t0', 't1', 't2', 't4']), json([rg.missing, B.listReport(gone).deleted]));
      var half = gone.replace('Remember:\n', 'Remember:\n' + LINE.kick + '\n' + LINE.beta + '\n'), rh = read(half);
      ok('list-missing-heading-text-heading-last: three of five noted tasks in the chain is enough', rh.missing && rh.fallback.p0 === '## My notes\nRemember:', json(rh.fallback));
      var two = gone.replace('Remember:\n', 'Remember:\n' + LINE.kick + '\n');
      ok('list-missing-heading-text-heading-last: two of five is not', !read(two).missing);
      // Two TEXT headings with nothing joining between them inside the list:
      // crossed until every task with a MARKED line is in the chain.
      var inner = x.replace(LINE.comp + '\n', LINE.comp + '\n\n## Aside\nNo tasks here.\n\n## More\n'), ri = read(inner);
      ok('list-missing-heading-text-heading-last: an inner gap is crossed', ri.missing && ri.fallback.line === 0, json(ri.fallback));
      // Once the chain holds every such task, a gap ends the climb: a stale
      // copy of Sync engine far above is not reached.
      var far = x.replace(INTRO, 'Plan.\n\n## Old\n' + LINE.sync + '\n\n## Gap\nprose\n\n## Between\n\n'), rf = read(far);
      ok('list-missing-heading-text-heading-last: a stale copy past a gap is not reached', rf.missing && rf.fallback.p0 === '## Between' &&
        read(B.restoreHeading(far)).list.ambiguous.length === 0, json(rf.fallback));
    } },
    'list-missing-heading-deleted-line.md': { missing: true, check: function (x, r) {
      // Case A (review round 2): Beta's line was deleted from the headless
      // list and its only MARKED line is a stale copy above two user
      // sections: one stray task never pulls the sections in.
      ok('list-missing-heading-deleted-line: the climb stops at the gap', r.fallback.p0 === '## Ideas\nidea' && r.fallback.line === x.split('\n').indexOf('## Ideas'), json(r.fallback));
      var fixed = restoreOf(x), s = save(fixed), rep = B.listReport(fixed);
      ok('list-missing-heading-deleted-line: after Restore the user sections stay outside, Beta reads as edited',
        fixed.indexOf('## Meeting notes\nWe met.\n\n## Ideas\nidea\n\n## Tasks\n\n- [Kickoff]') > 0 && json(rep.edited) === json(['t4']) && json(rep.deleted) === json([]), fixed);
      ok('list-missing-heading-deleted-line: one save writes Beta back in Build, stale copy untouched', count(s, LINE.beta) === 2 && s.indexOf('## Old plan\n' + LINE.beta) > 0 && save(s) === s, s);
    } },
    'list-missing-heading-two-tasks.md': { check: function (x, r, s1) {
      // Case B: a 2-task chart, list deleted, one stale copy above: crossing
      // reaches a run of one task and no marker, so the list is gone.
      ok('list-missing-heading-two-tasks: one stale copy of two tasks is "list gone"', !r.missing && r.fallback === null && r.list.heading === null);
      eq('list-missing-heading-two-tasks: report', json([B.listReport(x).deleted, B.listReport(x).edited]), json([['t1'], ['t0']]));
      ok('list-missing-heading-two-tasks: a save writes a new list above the fence, the user sections stay', s1.indexOf('idea\n\n## Tasks\n\n' + LINE.kick + '\n' + LINE.int) > 0 && s1.indexOf('## Old plan\n' + LINE.kick) > 0, s1);
      var two = x.replace('## Old plan\n' + LINE.kick + '\n\n', '').replace('idea\n\n', 'idea\n\n' + LINE.kick + '\n' + LINE.int + '\n\n## Notes\nlast\n\n'), rt = read(two);
      ok('list-missing-heading-two-tasks: a headless 2-task list with a last-block heading is crossed', rt.missing && rt.fallback.p0 === '## Ideas\nidea', json(rt.fallback));
      var one = two.replace(LINE.int + '\n', '').replace(/ \{"id":"t1"[^\n]*\n/, '').replace('"start":"2026-09-30"},', '"start":"2026-09-30"}');
      ok('list-missing-heading-two-tasks: the same with one task and no marker is "list gone" (documented limit)', !read(one).missing && read(one).status === 'ok', one);
    } },
    'list-heading-higher.md': { check: function (x, r, s1) {
      eq('list-heading-higher: the region grows up to the user ## Tasks', r.region.start, x.indexOf('## Tasks'));
      eq('list-heading-higher: the user headings in between are TEXT', json(r.list.attach.h), json(['My own to-dos: call Ana.', '', '## Notes', 'Some notes.', '', '## Ideas', '- idea one']));
      eq('list-heading-higher: byte-identical after a save', s1, x);
    } },
    'list-second-heading.md': { check: function (x, r, s1, s2) {
      eq('list-second-heading: the region shrinks to the second heading', r.region.start, x.lastIndexOf('## Tasks'));
      eq('list-second-heading: tasks above read as edited', json(B.listReport(x).edited), json(['t0', 't1', 't2']));
      eq('list-second-heading: the stale part is no seed', r.seed, null);
      eq('list-second-heading: no seed after the saves either', read(s1).seed, null);
      // Attached lines in the stale part cut the run above it; the run left
      // is still a written list (MARKED chart links under L+1 markers).
      [['prose in the stale h block', x.replace('## Tasks\n\n- [Kick', '## Tasks\n\nOur plan:\n\n- [Kick')],
        ['a note under Kickoff', x.replace('2026-09-30\n', '2026-09-30\n  owner: Ana\n')],
        ['prose after Competitive teardown', x.replace('2026-10-14\n\n## Tasks', '2026-10-14\nwaiting on legal\n\n## Tasks')],
        ['a closing sequence on the stale heading', x.replace('## Tasks\n\n- [Kick', '## Tasks ##\n\n- [Kick')]].forEach(function (v) {
        eq('list-second-heading: no seed with ' + v[0], read(v[1]).seed, null);
      });
      ok('list-second-heading: a real seed (picker links) above a second heading is still offered',
        !!read(x.replace('## Tasks\n\n- [Kick', '## Tasks\n\n## Design\n[W](synapseresource://note/zz-w)\n\n## Build\n[A](synapseresource://note/zz-a)\n\nmid\n\n- [Kick').replace(LINE.comp + '\n\n## Tasks', LINE.comp + '\n\n## Design\n[W](synapseresource://note/zz-w)\n\n## Tasks')).seed);
      ok('list-second-heading: the stale part stays once, every task written below', count(s1, LINE.kick) === 2 && count(s1, LINE.sync) === 1);
      eq('list-second-heading: stable over three saves', save(s2), s1);
    } },
    'list-level-l-text.md': { check: function (x, r, s1) {
      eq('list-level-l-text: saves byte-exact', s1, x);
      ok('list-level-l-text: both ## headings are TEXT, no group', r.list.sections.length === 4 && rowsOf(r, 'MARKER').length === 3);
      eq('list-level-l-text: the picker link after ## Notes is no offer', r.list.offers.length, 0);
      var moved = save(x, {}, function (c) { return M.setTask(c, 't3', { group: 'g1' }).chart; }), rm = read(moved);
      ok('list-level-l-text: a drag that puts a task line after ## Notes changes nothing', moved.indexOf('[Legal memo](synapseresource://note/n-legal)\n' + LINE.sync) > 0 &&
        rm.list.sections.length === 4 && rm.list.sections[1].tasks.join() === 't1,t2,t3' && save(moved) === moved, moved);
    } },
    'list-level-l-offer.md': { check: function (x, r, s1) {
      eq('list-level-l-offer: saves byte-exact', s1, x);
      eq('list-level-l-offer: promote candidates with owner, index and section',
        json(r.list.promote.map(function (p) { return [p.text, p.owner, p.index, p.section, p.group]; })),
        json([['Group 1', 't:t0', 0, null, null], ['Group 2', 't:t4', 0, 'g2', null]]));
      g2('list-level-l-offer: Make groups, one save, Undo restores ## lines; Not now writes nothing');
    } },
    'list-closing-sequence.md': { check: function (x, r, s1) {
      ok('list-closing-sequence: ## Tasks ## is the list heading', r.region.start === x.indexOf('## Tasks ##') && r.list.heading.text === 'Tasks');
      var m = r.list.sections[2].marker;
      ok('list-closing-sequence: ### Build ## maps to Build', m.gid === 'g2' && m.kind === 'same' && B.listReport(x).renamed.length === 0);
      ok('list-closing-sequence: the save drops the closing sequences', s1.indexOf('## Tasks\n\n') > 0 && s1.indexOf('### Build\n') > 0 && s1.indexOf(' ##\n') < 0);
    } },
    'list-indented-heading.md': { check: function (x, r, s1) {
      eq('list-indented-heading: one space is the list heading', r.region.text.indexOf(' ## Tasks\n'), 0);
      ok('list-indented-heading: rewritten flush left', s1.indexOf('\n## Tasks\n') > 0);
      var two = read(x.replace(' ## Tasks', '  ## Tasks'));
      ok('list-indented-heading: two spaces are not', two.missing && two.fallback.p0 === 'Plan for the release.\n\n  ## Tasks', json(two.fallback));
    } },
    'list-plain-elsewhere.md': { check: function (x, r, s1) {
      eq('list-plain-elsewhere: saves byte-exact', s1, x);
      ok('list-plain-elsewhere: attached, the task stays in Build', r.list.sections[2].tasks.join() === 't3,t4' && r.list.attach['t:t2'][0] === '[Sync engine](synapseresource://note/n-sync)');
      eq('list-plain-elsewhere: reported', json(r.list.plainElsewhere), json(['t3']));
    } },
    'list-older-build.md': { check: function (x, r, s1, s2) {
      eq('list-older-build: LEGACY markers', rowsOf(r, 'LEGACY').length, 2);
      eq('list-older-build: every task is ambiguous', json(r.list.ambiguous), json(['t0', 't1', 't2', 't3', 't4']));
      var rep = B.listReport(x);
      eq('list-older-build: duplicate markers held, no new group', json([rep.duplicates.map(function (d) { return d.title; }), rep.newGroups.length]), json([['Discovery', 'Build'], 0]));
      ok('list-older-build: every task line kept', [LINE.kick, LINE.int.slice(2), LINE.comp.slice(2), LINE.sync.slice(2), LINE.beta.slice(2)].every(function (l) { return count(s1, l) === 2; }), s1);
      eq('list-older-build: stable', s2, s1);
    } },
    'seed-basic.md': { check: function (x, r) {
      ok('seed-basic: fence-only region, the seed read', r.region.text.indexOf('```') === 0 && r.seed && r.seed.tasks === 3 && r.seed.groups.length === 2);
      eq('seed-basic: seed text', r.seed.text, '## Design\n[Wireframes](synapseresource://note/n-wire)\n[Style guide](synapseresource://note/n-style)\n\n## Build\n[API](synapseresource://note/n-api)');
      g2('seed-basic: offer "3 tasks in 2 groups"; Use as groups: one commit, one save, lines replaced by the list');
    } },
    'seed-basic-mirror.md': { check: function (x, r) {
      ok('seed-basic (legacy mirror): region at the mirror, seed across the blank line', r.region.text.indexOf('- [Kickoff]') === 0 && r.seed && r.seed.tasks === 3 && r.seed.groups.map(function (g) { return g.title; }).join() === 'Design,Build');
    } },
    'seed-basic-embed.md': { check: function (x, r) {
      ok('seed-basic (embed on top): region at the embed line, seed read', r.region.text.indexOf('@[100% x 420]') === 0 && r.seed && r.seed.tasks === 3);
    } },
    'seed-after-save.md': { check: function (x, r) {
      ok('seed-after-save: the list heading sits under the seed and the seed is read', r.list && r.seed && r.seed.tasks === 3 && r.seed.groups.length === 2);
      g2('seed-after-save: Use as groups replaces seed and old region');
    } },
    'seed-links-only.md': { check: function (x, r) {
      eq('seed-links-only: links with no heading are no seed', r.seed, null);
    } },
    'seed-not-now.md': { check: function (x, r) {
      ok('seed-not-now: seedSkip hides the seed', r.seed && r.seed.skipped);
      g2('seed-not-now: Not now in view state, seedSkip rides the next commit, undo clears it');
    } }
  };

  function fixtureSpec() {
    G2.length = 0;
    Object.keys(FIX).filter(function (f) { return /^(list|seed)-/.test(f) && !/^list-migrated-/.test(f); }).forEach(function (f) {
      ok('list fixture ' + f + ' has a case', !!CASES[f]);
    });
    Object.keys(CASES).forEach(function (f) {
      var c = CASES[f], x = fix(f), r = read(x);
      if (c.noSave) { c.check(x, r); return; }
      var s1 = save(x, c.sums), s2 = save(s1, c.sums);
      if (c.missing) {
        ok(f + ': missing heading state, chart saves held', r.missing && r.list === null && s1 === x && r.region.text.indexOf('```synapse-gantt') === 0, json(r.fallback));
      } else {
        eq(f + ': the second save gives identical bytes', s2, s1);
        if (r.list) {
          var lost = blocksIn(r.list, s1);
          ok(f + ': every attached line is kept', !lost.length, lost.join('\n'));
        }
      }
      c.check(x, r, s1, s2);
    });

    // Migration twins: the first save of each region-* fixture.
    var SM = { t1: { done: 1, total: 2 } }, UN = { t2: { done: 3, total: 5 }, t4: { done: 2, total: 4 }, t5: { done: 1, total: 1 } };
    var SUMS = { 'region-basic': EX_SUMS, 'region-embed-mirror': EX_SUMS, 'region-embed-nomirror': EX_SUMS, 'region-embed-empty': {},
      'region-embed-off': EX_SUMS, 'region-bold-above-ungrouped': SM, 'region-bold-above-group': EX_SUMS, 'region-bold-mirror-off': SM,
      'region-foreign-links': {}, 'region-foreign-links-milestones': {}, 'region-foreign-link-adjacent': SM, 'region-edited-line': EX_SUMS,
      'region-edited-date': EX_SUMS, 'region-edited-line-embed': EX_SUMS, 'region-prose-split': EX_SUMS, 'region-escaped-title': {},
      'region-empty-group': {}, 'region-unscheduled': UN, 'region-crlf': EX_SUMS, 'region-no-blank': SM, 'region-embed-stranded': EX_SUMS };
    var twins = 0;
    Object.keys(FIX).filter(function (f) { return /^region-.*\.md$/.test(f); }).forEach(function (f) {
      var n = f.replace(/\.md$/, ''), x = fix(f), r = read(x), s1 = save(x, SUMS[n]);
      ok('migration: ' + n + ' has sums and a twin', !!SUMS[n] && ('list-migrated-' + f) in FIX);
      if (!(('list-migrated-' + f) in FIX)) return;
      twins++;
      eq('migration: ' + n + ' first save equals its twin', s1, fix('list-migrated-' + f));
      eq('migration: ' + n + ' second save identical', save(s1, SUMS[n]), s1);
      var r1 = read(s1);
      ok('migration: ' + n + ' bytes outside the region untouched', s1.slice(0, r.region.start) === x.slice(0, r.region.start) &&
        s1.slice(r1.region.end) === x.slice(r.region.end));
      if (r.chart.settings.mirror !== false) ok('migration: ' + n + ' is a list chart after one save', !!r1.list && r1.region.start === r.region.start);
    });
    eq('migration: twins for every region-* fixture', twins, 21);
    [['region-bold-above-ungrouped.md', '- **Notes**'], ['region-bold-above-group.md', '- **Read this first**'],
      ['region-foreign-link-adjacent.md', '[Not on this chart]']].forEach(function (p) {
      var t = fix('list-migrated-' + p[0]);
      ok('migration: ' + p[0] + ' keeps the user line above the new list heading', t.indexOf(p[1]) >= 0 && t.indexOf(p[1]) < t.indexOf('## Tasks'));
    });
    // G2 phase 2: the fold and key assertions above run here; the ones that
    // need the store (banners, actions, held saves) run in store_spec's "the
    // G2 list store spec" under these exact names, which checks them all.
    GT.G2_STORE_NAMES = G2.slice();
    ok('G2-tagged store assertions handed to the store spec (' + G2.length + ')', G2.length >= 10, G2.join('\n'));
  }

  /* ============================================================ properties */

  function mulberry32(a) {
    return function () {
      a |= 0; a = (a + 0x6D2B79F5) | 0;
      var t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  function hashes(n) { return new Array(n + 1).join('#'); }

  var TITLES = ['Plan', 'Fix [bug] **now**', 'a ] b', '[draft', '◆ diamond first', '设计评审', 'Launch 🚀', '',
    'x\ny', 'tab\there', '[[nested]]', ']', '[', '**bold**', 'Q4 · 3/5', 'a](synapseresource://note/zz?via=gantt)',
    'ends with **', 'line\r\nbreak', '  spaced  ', 'Untitled', 'Build', 'Build'];
  var HEADS = ['Tasks', '任务', '计划 [草稿]', '[Plan]', 'Plan ] x', '路线图', 'Road map'];

  function gen(rng, n) {
    function int(a, b) { return a + Math.floor(rng() * (b - a + 1)); }
    function pick(l) { return l[int(0, l.length - 1)]; }
    var L = int(1, 3), h = pick(HEADS), ng = int(0, 5), groups = [], tasks = [];
    for (var g = 0; g < ng; g++) {
      var ti = rng() < 0.12 ? h : pick(TITLES);
      var gr = { id: 'g' + (g + 1), title: ti };
      if (rng() < 0.2) gr.color = 'teal';
      groups.push(gr);
    }
    var nt = int(0, 10), base = '2026-';
    for (var i = 0; i < nt; i++) {
      var kind = pick(['ranged', 'oneday', 'unsched', 'ms-note', 'ms-bare']);
      var t = { id: 't' + i, title: pick(TITLES) };
      if (kind !== 'ms-bare') t.note = 'n' + n + '-' + i;
      if (kind === 'ranged') { t.start = base + '10-0' + int(1, 5); t.end = base + '11-1' + int(0, 9); }
      else if (kind === 'oneday' || /^ms/.test(kind)) t.start = base + '10-1' + int(0, 9);
      if (/^ms/.test(kind)) t.milestone = true;
      var r = rng();
      if (ng && r < 0.6) t.group = 'g' + int(1, ng); else if (r < 0.7) t.group = 'gone-' + int(1, 3);
      tasks.push(t);
    }
    var settings = { listHeading: h, embed: rng() < 0.4 };
    if (L !== 2) settings.listLevel = L;
    return { c: chart({ v: 1, settings: settings, groups: groups, tasks: tasks }), L: L, h: h };
  }

  // Blocks from the attachable set (§5.3), never starting or ending blank.
  function genItem(rng, g) {
    function int(a, b) { return a + Math.floor(rng() * (b - a + 1)); }
    function pick(l) { return l[int(0, l.length - 1)]; }
    var noted = g.c.tasks.filter(function (t) { return t.note; });
    var L = g.L, k = int(0, 99);
    var levels = [1, 2, 3, 4, 5, 6].filter(function (x) { return x !== L + 1; });
    var hText = pick(['Notes', 'Aside', '设计', 'Tasks later', g.h + ' extra']);
    if (B.norm(hText) === B.norm(g.h)) hText = 'Notes';
    var kinds = [
      function () { return 'Remember the launch room.'; },
      function () { return 'First paragraph line.\n\nSecond paragraph after a blank line.'; },
      function () { return '  - Owner: Ana'; },
      function () { return '  indented prose'; },
      function () { return '- a plain bullet'; },
      function () { return '1. numbered item'; },
      function () { return '- **Waiting on legal**'; },
      function () { return hashes(pick(levels)) + ' ' + hText; },
      function () { return hashes(L) + ' ' + hText; },
      function () { return hashes(pick(levels)) + ' Notes ##'; },
      function () { return '```\n' + hashes(L + 1) + ' Fake marker\n' + (noted.length ? '- [X](synapseresource://note/' + pick(noted).note + '?via=gantt)\n' : '') + '```'; },
      function () { return '~~~text\n' + hashes(L) + ' ' + g.h + '\n\n~~~'; },
      function () { return '- [Other](synapseresource://note/zz-' + k + '?via=gantt)'; },
      function () { return '[Other](synapseresource://note/zz-' + k + ')'; },
      function () { return '  - [Ref](synapseresource://note/zz-' + k + ')'; },
      function () { var t = noted.length ? pick(noted) : null; return t ? '[' + B.ltext(t.title) + '](synapseresource://note/' + t.note + ')' : 'no task'; },
      function () { return '[A](synapseresource://note/zz-1) and [B](synapseresource://note/zz-2)'; },
      function () { return '####### seven'; },
      function () { return '  ' + hashes(L + 1) + ' two-space marker-like'; },
      function () { return '| a | b |'; },
      function () { return 'Trailing spaces here   '; },
      function () { return '- a bullet with a trailing tab\t'; },
      function () { return 'Para one\n   \nPara two after a whitespace-only line'; },
      function () { return 'Para one\n\t\nPara two after a tab-only line'; },
      function () { return '@[100% x 300](synapseresource://app/other-app?note=current&mode=embed)'; },
      function () { return noted.length ? '- [T](synapseresource://note/' + pick(noted).note + '?via=gantt) with text after' : 'x'; }
    ];
    return pick(kinds)();
  }
  function genAttach(rng, g, owners, p) {
    var A = {};
    owners.forEach(function (k) {
      A[k] = [];
      if (rng() >= p) return;
      var n = 1 + Math.floor(rng() * 3), lines = [];
      for (var i = 0; i < n; i++) lines = lines.concat(genItem(rng, g).split('\n'));
      A[k] = lines;
    });
    return A;
  }
  function genPrefix(rng, g, wantEmbed, noHeadingCopy) {
    function int(a, b) { return a + Math.floor(rng() * (b - a + 1)); }
    function pick(l) { return l[int(0, l.length - 1)]; }
    var c = g.c, noted = c.tasks.filter(function (t) { return t.note; });
    var lines = RP(c, {}, {}).text.split('\n').filter(function (l) { return /\?via=gantt\)/.test(l); });
    var kinds = ['prose', 'bold', 'foreign', 'plain', 'code', 'seed', 'marker', 'levels'];
    if (!noHeadingCopy) kinds.push('userlist');
    if (lines.length) kinds.push('copies');
    var pieces = [], n = int(0, 4);
    for (var i = 0; i < n; i++) {
      var kind = pick(kinds);
      if (kind === 'prose') pieces.push('Some prose about the plan.');
      else if (kind === 'bold') pieces.push('- **Notes**\n  - [Other](synapseresource://note/zz-3?via=gantt)');
      else if (kind === 'foreign') pieces.push('- [Other](synapseresource://note/zz-' + int(0, 9) + '?via=gantt) · 2026-01-01');
      else if (kind === 'plain') pieces.push(noted.length ? '[Mine](synapseresource://note/' + pick(noted).note + ')' : 'x');
      else if (kind === 'code') pieces.push('```js\nvar x = "## ' + g.h + '";\n```');
      else if (kind === 'seed') pieces.push('## Design\n[W](synapseresource://note/zz-5)\n\n## Build\n[A](synapseresource://note/zz-6)');
      else if (kind === 'marker') pieces.push(c.groups.length ? hashes(g.L + 1) + ' ' + B.htext(pick(c.groups).title) : '### x');
      else if (kind === 'levels') pieces.push(hashes(int(1, 6)) + ' Heading');
      else if (kind === 'userlist') pieces.push(hashes(g.L) + ' ' + B.htext(g.h) + (rng() < 0.5 ? ' ##' : '') + '\nMy own list.');
      else pieces.push('## Copied\n' + lines.join('\n'));
    }
    if (wantEmbed) pieces.splice(int(0, pieces.length), 0, B.embedLine() + '\nText under my embed.');
    if (!pieces.length) return '';
    return pieces.join(rng() < 0.5 ? '\n' : '\n\n') + (rng() < 0.5 ? '\n' : '\n\n');
  }
  function genSums(rng, c) {
    var s = {};
    c.tasks.forEach(function (t) { if (rng() < 0.5) { var n = Math.floor(rng() * 6); s[t.id] = { done: Math.floor(rng() * (n + 1)), total: n }; } });
    return s;
  }
  function seedOf() {
    return typeof global.GT_SEED === 'number' && isFinite(global.GT_SEED) ? global.GT_SEED : (Date.now() % 2147483647);
  }

  // One written note: {g, sums, P, suffix, eo, r (regionParts), text}.
  function writtenNote(rng, n, opts) {
    opts = opts || {};
    var g = gen(rng, n), sums = genSums(rng, g.c), eo = rng() < 0.3;
    var owners = Object.keys(RP(g.c, sums, {}).attach);
    var A = genAttach(rng, g, owners, opts.p || 0.35);
    var P = genPrefix(rng, g, eo, opts.noHeadingCopy);
    var suffix = rng() < 0.5 ? '' : '\n\nTail after the chart.';
    var r = RP(g.c, sums, { embedOutside: eo, attach: A, ambiguous: [] });
    return { g: g, sums: sums, P: P, suffix: suffix, eo: eo, A: A, r: r, text: P + r.text + suffix };
  }

  function idempotenceSpec() {
    var seed = seedOf(), rng = mulberry32(seed), N = 500, fails = 0, first = '', lossFails = 0, lossFirst = '';
    var stats = { L1: 0, L3: 0, embed: 0, emptyGroup: 0, dupTitles: 0, blocks: 0, off: 0, removed: 0, crlf: 0, trailingWs: 0, wsInner: 0 };
    function fail(n, why) { fails++; if (!first) first = 'chart #' + n + ': ' + why; }
    function lfail(n, why) { lossFails++; if (!lossFirst) lossFirst = 'chart #' + n + ': ' + why; }
    for (var n = 0; n < N; n++) {
      var w = writtenNote(rng, n), g = w.g, c = g.c, crlf = rng() < 0.25;
      var CR = function (s) { return crlf ? s.replace(/\n/g, '\r\n') : s; };
      var text = CR(w.text), rd = LR(text);
      if (crlf) stats.crlf++;
      if (g.L === 1) stats.L1++;
      if (g.L === 3) stats.L3++;
      if (c.settings.embed && !w.eo) stats.embed++;
      if (c.groups.some(function (x) { return !c.tasks.some(function (t) { return t.group === x.id; }); })) stats.emptyGroup++;
      var ts = c.groups.map(function (x) { return B.htext(x.title); });
      if (ts.some(function (t, i) { return ts.indexOf(t) !== i; })) stats.dupTitles++;
      Object.keys(w.A).forEach(function (k) {
        var b = w.A[k];
        if (b.length) stats.blocks++;
        if (b.some(function (l) { return /\S[ \t]+$/.test(l); })) stats.trailingWs++;
        if (b.some(function (l) { return /^[ \t]+$/.test(l); })) stats.wsInner++;
      });
      if (rd.status !== 'ok' || !rd.list) { fail(n, 'no list: ' + rd.status + '\n' + text); continue; }
      if (rd.region.start !== CR(w.P).length || rd.region.text !== CR(w.r.text)) { fail(n, 'region mismatch\n--- written ---\n' + w.r.text + '\n--- read ---\n' + rd.region.text + '\n--- prefix ---\n' + w.P); continue; }
      if (rd.list.heading.line !== w.P.split('\n').length - 1) { fail(n, 'heading line'); continue; }
      if (canon(rd.chart) !== canon(c)) { fail(n, 'chart mismatch\n' + canon(rd.chart) + '\n' + canon(c)); continue; }
      if (json(rd.list.attach) !== json(w.r.attach)) { fail(n, 'attach mismatch\n' + json(rd.list.attach) + '\n' + json(w.r.attach) + '\n' + text); continue; }
      if (rd.list.ambiguous.length) { fail(n, 'ambiguous ' + json(rd.list.ambiguous)); continue; }
      if (rd.key !== rd.bodyKey) { fail(n, 'composite key'); continue; }
      if (rd.embedOutside !== w.eo) { fail(n, 'embedOutside'); continue; }
      var bad = rd.list.sections.some(function (s, i) {
        if (!i) return s.gid !== null;
        return s.gid !== c.groups[i - 1].id || s.marker.kind !== 'same';
      }) || rd.list.sections.length !== c.groups.length + 1;
      var member = rd.list.sections.map(function (s) { return s.tasks.join(','); }).join('|');
      var want = [c.tasks.filter(function (t) { return t.note && (t.group === null); }).map(function (t) { return t.id; }).join(',')].concat(
        c.groups.map(function (x) { return c.tasks.filter(function (t) { return t.note && t.group === x.id; }).map(function (t) { return t.id; }).join(','); })).join('|');
      if (bad || member !== want) { fail(n, 'sections do not match the chart: ' + member + ' vs ' + want + '\n' + text); continue; }
      // A CRLF note's first save writes the region LF only, nothing else.
      var lf = CR(w.P) + w.r.text + CR(w.suffix);
      if (save(text, w.sums) !== lf || save(lf, w.sums) !== lf) { fail(n, 'a save is not a fixed point' + (crlf ? ' (CRLF)' : '')); continue; }

      // No loss after random chart edits.
      var c2 = c, noted = c.tasks.filter(function (t) { return t.note; });
      var nr = Math.floor(rng() * 3);
      for (var i = 0; i < nr && noted.length; i++) { c2 = M.removeTask(c2, noted.splice(Math.floor(rng() * noted.length), 1)[0].id).chart; stats.removed++; }
      if (c2.groups.length && rng() < 0.4) c2 = M.removeGroup(c2, c2.groups[Math.floor(rng() * c2.groups.length)].id).chart;
      if (rng() < 0.2) { c2 = M.setSettings(c2, { mirror: false }).chart; stats.off++; }
      var p = RP(c2, w.sums, { embedOutside: rd.embedOutside, attach: rd.list.attach, ambiguous: rd.list.ambiguous });
      var out = w.P + (p.spill ? p.spill + '\n\n' : '') + p.text + w.suffix;
      var lost = blocksIn(rd.list, (p.spill ? p.spill + '\n\n' : '') + p.text);
      if (lost.length) { lfail(n, 'lost ' + lost.join('; ')); continue; }
      if (out.indexOf(w.P) !== 0 || out.slice(out.length - w.suffix.length) !== w.suffix) { lfail(n, 'text outside the region changed'); continue; }
      var ro = LR(out);
      if (c2.settings.mirror !== false && json(ro.list && ro.list.attach) !== json(p.attach)) { lfail(n, 'attach after edits\n' + json(ro.list && ro.list.attach) + '\n' + json(p.attach) + '\n' + out); continue; }
      if (save(out, w.sums) !== out) lfail(n, 'not a fixed point after edits\n' + out + '\n---\n' + save(out, w.sums));
    }
    ok('idempotence holds for ' + N + ' random list charts (seed ' + seed + '; rerun with GT_SEED=' + seed + ')', fails === 0, fails + ' failures; first: ' + first);
    ok('no loss after random chart edits for ' + N + ' charts (seed ' + seed + ')', lossFails === 0, lossFails + ' failures; first: ' + lossFirst);
    ok('the generator exercises levels, embeds, empty and duplicate groups, blocks, list off and removals',
      stats.L1 > 50 && stats.L3 > 50 && stats.embed > 30 && stats.emptyGroup > 50 && stats.dupTitles > 20 && stats.blocks > 500 && stats.off > 30 && stats.removed > 100 &&
      stats.crlf > 80 && stats.trailingWs > 30 && stats.wsInner > 30, json(stats));
  }

  function copiesSpec() {
    var seed = seedOf() + 1, rng = mulberry32(seed), runs = 0, fails = 0, first = '';
    function fail(n, why) { fails++; if (!first) first = 'region #' + n + ': ' + why; }
    for (var n = 0; runs < 200 && n < 2000; n++) {
      var w = writtenNote(rng, n);
      var rd = LR(w.text), rows = rd.list.rows, owned = rows.filter(function (x) { return x.owned; });
      if (!owned.length) continue;
      runs++;
      var ls = w.text.split('\n'), owners = rows.filter(function (x) { return x.owned || x.cls === 'MARKER'; }).map(function (x) { return x.line; });
      owners.unshift(rd.list.heading.line);
      var nc = 1 + Math.floor(rng() * 2), copied = [], ins = [];
      for (var i = 0; i < nc; i++) {
        var src = owned[Math.floor(rng() * owned.length)], at = owners[Math.floor(rng() * owners.length)];
        if (copied.indexOf(src.task) < 0) copied.push(src.task);
        ins.push({ at: at, line: ls[src.line] });
      }
      ins.sort(function (a, b) { return b.at - a.at; }).forEach(function (x) { ls.splice(x.at + 1, 0, x.line); });
      var text = ls.join('\n'), r0 = LR(text);
      if (copied.some(function (id) { return r0.list.ambiguous.indexOf(id) < 0; })) { fail(n, 'copy not ambiguous ' + json(r0.list.ambiguous) + '\n' + text); continue; }
      var s1 = save(text, w.sums), s = s1, stable = true;
      for (var k = 0; k < 5; k++) { var nx = save(s, w.sums); if (nx !== s) stable = false; s = nx; }
      if (!stable) { fail(n, 'not a fixed point after one save\n' + s1); continue; }
      var lost = blocksIn(r0.list, s1);
      if (lost.length) { fail(n, 'lost ' + lost.join('; ')); continue; }
      var r1 = LR(s1);
      var groupsKept = copied.every(function (id) {
        var a = r1.chart.tasks.filter(function (t) { return t.id === id; })[0], b = w.g.c.tasks.filter(function (t) { return t.id === id; })[0];
        return a.group === b.group && r1.list.ambiguous.indexOf(id) >= 0;
      });
      if (!groupsKept) fail(n, 'a copied task changed group or stopped being ambiguous');
    }
    ok('copies: 200 regions with MARKED copies are fixed points after one save (seed ' + seed + ')', fails === 0 && runs === 200, runs + ' runs, ' + fails + ' failures; first: ' + first);
  }

  // P0 computed independently of block.js: from the fallback start to the
  // first MARKER, LEGACY, EMBED or MARKED chart-task line outside code,
  // trailing blank lines trimmed, bytes as in the note.
  function p0Oracle(text, start, L, c) {
    var raw = text.split('\n'), lines = raw.map(function (l) { return l.replace(/\r$/, ''); }), notes = {}, code = [], open = null;
    c.tasks.forEach(function (t) { if (t.note) notes[t.note] = true; });
    lines.forEach(function (t, k) {
      if (open) { code[k] = true; if (B.closes(t, open)) open = null; return; }
      var o = B.opening(t);
      code[k] = !!o;
      if (o) open = o;
    });
    function markedAt(k, indent) {
      var p = code[k] ? null : B.parseLink(lines[k]);
      return !!(p && p.marked && notes[p.note] && (indent === undefined || p.indent === indent));
    }
    function term(k) {
      if (code[k]) return false;
      var t = lines[k], hd = B.heading(t);
      if (B.isEmbedLine(t) || (hd && hd.level === L + 1) || markedAt(k)) return true;
      return /^- \*\*[\s\S]+\*\*$/.test(t) && k + 1 < lines.length && markedAt(k + 1, 2);
    }
    var t = start;
    while (t < lines.length && !term(t)) t++;
    var e = t - 1;
    while (e >= start && !/\S/.test(lines[e])) e--;
    return e >= start ? raw.slice(start, e + 1).join('\n').replace(/\r$/, '') : '';
  }

  // Lines of a note as the climb sees them, written apart from block.js.
  function climbView(text, L, c) {
    var lines = text.split('\n').map(function (l) { return l.replace(/\r$/, ''); }), code = [], open = null, ids = {};
    lines.forEach(function (t, k) {
      if (open) { code[k] = true; if (B.closes(t, open)) open = null; return; }
      var o = B.opening(t);
      code[k] = !!o;
      if (o) open = o;
    });
    c.tasks.forEach(function (t) { if (t.note) ids[t.note] = t.id; });
    return {
      lines: lines, F: lines.indexOf('```synapse-gantt'),
      head: function (k) { var hd = code[k] ? null : B.heading(lines[k]); return hd && hd.level <= L ? hd : null; },
      marked: function (k) { var p = code[k] ? null : B.parseLink(lines[k]); return p && p.marked && ids[p.note] ? ids[p.note] : null; },
      marker: function (k) { var hd = code[k] ? null : B.heading(lines[k]); return !!hd && hd.level === L + 1; }
    };
  }
  // §5.6 climb rule (review round 2) as the plan states it. Returns
  // {start, declined}: start null means "list gone"; declined means a run
  // above a gap was not taken because it held no marker and fewer than two
  // new tasks.
  function climbOracle(text, L, c) {
    var v = climbView(text, L, c), noted = c.tasks.filter(function (t) { return t.note; }).length, need = {}, needN = 0, segs = [], hi = v.F;
    for (var q = 0; q < v.F; q++) { var id0 = v.marked(q); if (id0 && !need[id0]) { need[id0] = 1; needN++; } }
    for (var k = v.F - 1; k >= -1; k--) {
      if (k >= 0 && !v.head(k)) continue;
      var s = { top: Math.max(k, 0), joins: false, tasks: [], mk: false };
      for (var j = k + 1; j < hi; j++) { var id = v.marked(j); if (id) { s.joins = true; s.tasks.push(id); } else if (v.marker(j)) { s.joins = s.mk = true; } }
      segs.push(s);
      hi = k;
    }
    var chain = {}, n = 0, start = null, crossed = false, declined = false, i = 0;
    function run(a) { var b = a; while (b < segs.length && segs[b].joins) b++; return b; }
    function ok2(a, b) {
      var fresh = {}, m = 0, mk = false;
      segs.slice(a, b).forEach(function (s) { if (s.mk) mk = true; s.tasks.forEach(function (id) { if (!chain[id] && !fresh[id]) { fresh[id] = 1; m++; } }); });
      return mk || m >= 2;
    }
    function take(a, b) { segs.slice(a, b).forEach(function (s) { start = s.top; s.tasks.forEach(function (id) { if (!chain[id]) { chain[id] = 1; n++; } }); }); }
    while (i < segs.length && !segs[i].joins) { i++; crossed = true; }
    if (i === segs.length) return { start: null, declined: false };
    var e = run(i);
    if (crossed && !ok2(i, e)) return { start: null, declined: true };
    take(i, e);
    i = e;
    while (i < segs.length && n < needN) {
      while (i < segs.length && !segs[i].joins) i++;
      if (i === segs.length) break;
      e = run(i);
      if (!ok2(i, e)) { declined = true; break; }
      crossed = true;
      take(i, e);
      i = e;
    }
    if (crossed && !(n >= 1 && 2 * n >= noted)) return { start: null, declined: declined };
    return { start: start, declined: declined };
  }
  // The top of the headless list: the segment holding its first task line
  // or marker at or after line `at` (the list heading's old place), extended
  // over joining segments directly above. Attached lines above the first
  // owner that sit under their own level <= L heading own nothing and stay
  // user text.
  function listTop(text, L, c, at) {
    var v = climbView(text, L, c), top = 0, f = at;
    // First task line; a chart with none starts at its first marker. (Markers
    // above a gap once every task is in the chain stay outside: known limit,
    // G1 review round 2; the property counts them as markerLeft.)
    while (f < v.F && !v.marked(f)) f++;
    if (f === v.F) { f = at; while (f < v.F && !v.marker(f)) f++; }
    for (var k = f; k >= 0; k--) if (v.head(k)) { top = k; break; }
    for (;;) {
      if (top === 0 && !v.head(0)) return 0;
      var up = -1;
      for (var k2 = top - 1; k2 >= 0; k2--) if (v.head(k2)) { up = k2; break; }
      var joins = false;
      for (var j = up + 1; j < top && !joins; j++) joins = !!v.marked(j) || v.marker(j);
      if (!joins) return top;
      top = Math.max(up, 0);
      if (up < 0) return 0;
    }
  }

  function missingSpec() {
    var seed = seedOf() + 2, rng = mulberry32(seed), runs = 0, fails = 0, first = '', mistyped = 0, useAs = 0;
    var lastHead = 0, p0Rich = 0, crlfRuns = 0, gone = 0, partial = 0, markerLeft = 0;
    function fail(n, why) { fails++; if (!first) first = 'region #' + n + ': ' + why; }
    for (var n = 0; runs < 200 && n < 4000; n++) {
      var w = writtenNote(rng, n, { p: 0.5, noHeadingCopy: true }), g = w.g, c = g.c;
      if (!c.groups.length && !c.tasks.some(function (t) { return t.note; })) continue;
      runs++;
      var text = w.text, ls = text.split('\n'), rd0 = LR(text), hl = rd0.list.heading.line, F = ls.indexOf('```synapse-gantt');
      // A level-L TEXT heading in the last block (crossed only when the chain
      // holds noted tasks, §5.6 threshold), a line typed above the fence.
      var hasNoted = c.tasks.some(function (x) { return x.note; });
      if (hasNoted && rng() < 0.4) { ls.splice(F - 1, 0, hashes(g.L) + ' Notes', 'A note at the end.'); F += 2; lastHead++; }
      if (rng() < 0.5) { ls[F - 1] = 'Typed right above the fence'; }
      // User section above with a stale MARKED copy and a PLAIN link.
      var own = rd0.list.rows.filter(function (x) { return x.owned; });
      if (own.length && rng() < 0.5) {
        var t = c.tasks.filter(function (x) { return x.id === own[0].task; })[0];
        ls.splice(hl, 0, '## My notes', text.split('\n')[own[0].line], '[' + B.ltext(t.title) + '](synapseresource://note/' + t.note + ')', '');
        hl += 4;
      }
      var mis = rng() < 0.4;
      if (mis) { ls[hl] = hashes(g.L) + ' ' + B.htext(g.h) + 'x'; mistyped++; }
      else ls.splice(hl, ls[hl + 1] === '' ? 2 : 1);
      // Prose, a PLAIN chart-task link and a foreign MARKED link before the
      // first terminator: all of it is P0 (not terminators).
      if (rng() < 0.5) {
        var head0 = [], pt0 = own.length ? c.tasks.filter(function (x) { return x.id === own[0].task; })[0] : null;
        head0.push('Prose before the list.');
        if (pt0) head0.push('[' + B.ltext(pt0.title) + '](synapseresource://note/' + pt0.note + ')');
        head0.push('- [Other](synapseresource://note/zz-9?via=gantt)', '');
        ls.splice.apply(ls, [mis ? hl + 1 : hl, 0].concat(mis ? [''].concat(head0) : head0));
        p0Rich++;
      }
      var crlf = rng() < 0.25, nlLen = crlf ? 2 : 1;
      if (crlf) crlfRuns++;
      var edited = ls.join(crlf ? '\r\n' : '\n'), rd = LR(edited);
      // The §5.6 climb, computed without block.js: "list gone" or the start.
      var cl = climbOracle(edited, g.L, c);
      if (cl.start === null) {
        gone++;
        if (rd.missing || !rd.list || rd.list.heading !== null) fail(n, 'expected "list gone"\n' + edited);
        continue;
      }
      if (!rd.missing) { fail(n, 'not in the missing heading state\n' + edited); continue; }
      if (rd.fallback.line !== cl.start) { fail(n, 'fallback start ' + rd.fallback.line + ' vs oracle ' + cl.start + '\n' + edited); continue; }
      // The list top the generator knows (the removed or mistyped heading's
      // place, plus contiguous joining segments above): the fallback starts
      // there unless the rule declined an upper run of one task (counted).
      var top = listTop(edited, g.L, c, hl);
      if (rd.fallback.line !== top) {
        var vw = climbView(edited, g.L, c), taskAbove = false;
        for (var q = top; q < rd.fallback.line; q++) if (vw.marked(q)) taskAbove = true;
        if (rd.fallback.line > top && cl.declined) partial++;
        else if (rd.fallback.line > top && !taskAbove) markerLeft++;
        else { fail(n, 'fallback start ' + rd.fallback.line + ' vs list top ' + top + '\n' + edited); continue; }
      }
      if (rd.list || rd.region.text.indexOf('```synapse-gantt') !== 0 && !B.isEmbedLine(rd.region.text.split('\n')[0])) { fail(n, 'region is not the main spec region'); continue; }
      if (save(edited, w.sums) !== edited) { fail(n, 'a chart save wrote'); continue; }
      if (rd.fallback.useAs !== null) useAs++;
      var want0 = p0Oracle(edited, rd.fallback.line, g.L, c);
      if (rd.fallback.p0 !== want0) { fail(n, 'P0 ' + json(rd.fallback.p0) + ' vs oracle ' + json(want0) + '\n' + edited); continue; }
      var fixed = B.restoreHeading(edited), head = hashes(g.L) + ' ' + B.htext(g.h);
      var nb = function (s) { return s.split('\n').map(function (l) { return l.replace(/\r$/, ''); }).filter(function (l) { return /\S/.test(l); }); };
      var a = nb(edited), b = nb(fixed), at = -1;
      for (var i = 0; i < b.length; i++) if (b[i] === head && json(b.slice(0, i).concat(b.slice(i + 1))) === json(a)) { at = i; break; }
      if (at < 0 || b.length !== a.length + 1) { fail(n, 'Restore heading is not one line insertion\n' + edited + '\n---\n' + fixed); continue; }
      var keep = rd.fallback.start + rd.fallback.p0.length;
      if (fixed.slice(0, keep) !== edited.slice(0, keep)) { fail(n, 'P0 or the text above changed'); continue; }
      var rf = LR(fixed);
      if (rf.missing || !rf.list || rf.region.start !== rd.fallback.start + (rd.fallback.p0 ? rd.fallback.p0.length + 2 * nlLen : 0)) { fail(n, 'the next read does not find the restored heading'); continue; }
      var s1 = save(fixed, w.sums), lost = blocksIn(rf.list, s1);
      if (lost.length) { fail(n, 'lost ' + lost.join('; ')); continue; }
      if (save(s1, w.sums) !== s1) { fail(n, 'not stable after restore'); continue; }
      var r2 = LR(s1);
      if (r2.region.start !== rf.region.start || r2.list.ambiguous.some(function (id) { return rf.list.ambiguous.indexOf(id) < 0; })) fail(n, 'more than one list');
    }
    ok('missing heading: 200 regions held, restored by one line, no loss (seed ' + seed + ')', fails === 0 && runs === 200, runs + ' runs, ' + fails + ' failures; first: ' + first);
    ok('missing heading: the generator mistypes, offers Use as list heading, crosses a last-block heading, fills P0 and uses CRLF ' +
      '[mistyped, useAs, lastHead, p0Rich, crlf, gone, partial, markerLeft] = ' + json([mistyped, useAs, lastHead, p0Rich, crlfRuns, gone, partial, markerLeft]),
      mistyped > 40 && useAs > 5 && lastHead > 40 && p0Rich > 60 && crlfRuns > 25, json([mistyped, useAs, lastHead, p0Rich, crlfRuns, gone, partial, markerLeft]));
  }

  /*
   * Hand edits (§5.3, §10.1): random edits inside a written region against
   * an oracle computed from the edit. G1 checks the parsed membership, no
   * loss and convergence in one save; the fold equality is G2.
   */
  function handEditSpec() {
    var seed = seedOf() + 3, rng = mulberry32(seed), runs = 0, fails = 0, first = '', kinds = {};
    var foldFails = 0, foldFirst = '', folded = 0;
    function fail(n, why) { fails++; if (!first) first = 'edit #' + n + ': ' + why; }
    function int(a, b) { return a + Math.floor(rng() * (b - a + 1)); }
    for (var n = 0; runs < 500 && n < 5000; n++) {
      var w = writtenNote(rng, n), g = w.g, text = w.text, rd = LR(text), list = rd.list;
      var ls = text.split('\n'), hl = list.heading.line, F = ls.indexOf('```synapse-gantt');
      var byLine = {};
      list.rows.forEach(function (x) { byLine[x.line] = x; });
      var sec = list.sections;
      // Region lines with metas: marker title (norm) or owned task id.
      var lines = [];
      for (var k = hl + 1; k < F; k++) {
        var row = byLine[k], meta = { text: ls[k], cls: row.cls, task: row.owned ? row.task : null, marker: null };
        if (row.cls === 'MARKER') meta.marker = sec.filter(function (s) { return s.line === k; })[0].marker.title;
        lines.push(meta);
      }
      // Boundaries not inside a code block.
      var safe = [], open = null;
      for (var i = 0; i <= lines.length; i++) {
        if (!open) safe.push(i);
        if (i === lines.length) break;
        var t = lines[i].text;
        if (open) { if (B.closes(t, open)) open = null; } else { var o = B.opening(t); if (o) open = o; }
      }
      function pickSafe() { return safe[int(0, safe.length - 1)]; }
      var tasks = lines.filter(function (m) { return m.task; }), markers = lines.filter(function (m) { return m.marker !== null; });
      var ops = ['heading', 'prose', 'foreign', 'levelL', 'code'];
      if (tasks.length) ops.push('move', 'move', 'plain');
      if (markers.length) ops.push('rename', 'delete');
      if (markers.length >= 2) ops.push('swap');
      if (lines.some(function (m) { return m.cls === 'TEXT'; })) ops.push('indent');
      var op = ops[int(0, ops.length - 1)], nl = lines.slice(), p;
      function insert(at, metas) { nl.splice.apply(nl, [at, 0].concat(metas)); }
      if (op === 'move') {
        var tm = tasks[int(0, tasks.length - 1)], from = nl.indexOf(tm);
        nl.splice(from, 1);
        p = pickSafe(); if (p > from) p--;
        var s2 = []; open = null;
        for (var j = 0; j <= nl.length; j++) { if (!open) s2.push(j); if (j === nl.length) break; var tt = nl[j].text; if (open) { if (B.closes(tt, open)) open = null; } else { var oo = B.opening(tt); if (oo) open = oo; } }
        if (s2.indexOf(p) < 0) p = s2[s2.length - 1];
        insert(p, [tm]);
      } else if (op === 'heading') {
        var title = ['QA', 'Review', '测试', g.c.groups.length ? B.htext(g.c.groups[0].title) : 'Later'][int(0, 3)];
        insert(pickSafe(), [{ text: hashes(g.L + 1) + ' ' + title, cls: 'MARKER', task: null, marker: B.norm(title) }]);
      } else if (op === 'rename') {
        var mm = markers[int(0, markers.length - 1)], nt = 'Renamed ' + int(0, 9);
        nl[nl.indexOf(mm)] = { text: hashes(g.L + 1) + ' ' + nt, cls: 'MARKER', task: null, marker: nt };
      } else if (op === 'delete') {
        nl.splice(nl.indexOf(markers[int(0, markers.length - 1)]), 1);
      } else if (op === 'swap') {
        var mi = int(0, markers.length - 2), a0 = nl.indexOf(markers[mi]), b0 = nl.indexOf(markers[mi + 1]);
        var b1 = mi + 2 < markers.length ? nl.indexOf(markers[mi + 2]) : nl.length;
        nl = nl.slice(0, a0).concat(nl.slice(b0, b1), nl.slice(a0, b0), nl.slice(b1));
      } else if (op === 'foreign') {
        insert(pickSafe(), [{ text: '[Vendor](synapseresource://note/zz-' + int(0, 9) + ')', cls: 'LINK', task: null, marker: null }]);
      } else if (op === 'plain') {
        var pid = tasks[int(0, tasks.length - 1)].task, pt = g.c.tasks.filter(function (x) { return x.id === pid; })[0];
        insert(pickSafe(), [{ text: '[' + B.ltext(pt.title) + '](synapseresource://note/' + pt.note + ')', cls: 'LINK', task: null, marker: null }]);
      } else if (op === 'prose') {
        insert(rng() < 0.3 ? lines.length : pickSafe(), [{ text: 'Typed by hand ' + n, cls: 'TEXT', task: null, marker: null }]);
      } else if (op === 'code') {
        insert(pickSafe(), ['```', hashes(g.L + 1) + ' not a marker', '```'].map(function (x) { return { text: x, cls: 'CODE', task: null, marker: null }; }));
      } else if (op === 'levelL') {
        insert(pickSafe(), [{ text: hashes(g.L) + ' Group ' + n, cls: 'TEXT', task: null, marker: null }]);
      } else if (op === 'indent') {
        var tx = nl.filter(function (m) { return m.cls === 'TEXT'; }), ti = tx[int(0, tx.length - 1)];
        nl[nl.indexOf(ti)] = { text: '  ' + ti.text, cls: 'TEXT', task: null, marker: null };
      }
      kinds[op] = (kinds[op] || 0) + 1;
      runs++;
      // Oracle: each owned task's section title.
      var oracle = {}, cur = null;
      nl.forEach(function (m) { if (m.marker !== null) cur = m.marker; else if (m.task) oracle[m.task] = cur; });
      var edited = ls.slice(0, hl + 1).concat(nl.map(function (m) { return m.text; }), ls.slice(F)).join('\n');
      var re = LR(edited);
      if (!re.list) { fail(n, op + ': no list\n' + edited); continue; }
      var parsed = {};
      re.list.sections.forEach(function (s) { s.tasks.forEach(function (id) { parsed[id] = s.marker ? s.marker.title : null; }); });
      if (json(Object.keys(parsed).sort().map(function (k) { return k + '=' + parsed[k]; })) !== json(Object.keys(oracle).sort().map(function (k) { return k + '=' + oracle[k]; }))) {
        fail(n, op + ': membership ' + json(parsed) + ' vs oracle ' + json(oracle) + '\n' + edited); continue;
      }
      if (re.list.ambiguous.length) { fail(n, op + ': ambiguous'); continue; }
      var s1 = save(edited, w.sums), lost = blocksIn(re.list, s1);
      if (lost.length) { fail(n, op + ': lost ' + lost.join('; ') + '\n' + edited); continue; }
      if (save(s1, w.sums) !== s1) fail(n, op + ': does not converge in one save\n' + edited + '\n---\n' + s1);
      // G2: the fold of read 1 is the chart read 2 finds, and read 2 folds
      // nothing (its key is its body key).
      var r2 = LR(s1);
      if (B.serialize(r2.chart) !== B.serialize(re.chart) || r2.key !== r2.bodyKey) { foldFails++; if (!foldFirst) foldFirst = op + '\n' + edited; }
      if (re.key !== re.bodyKey) folded++;
    }
    ok('hand edits: 500 edits parse as the oracle, lose nothing and converge in one save (seed ' + seed + ')', fails === 0 && runs === 500,
      runs + ' runs, ' + fails + ' failures; first: ' + first);
    ok('hand edits: every edit kind ran', ['move', 'heading', 'rename', 'delete', 'swap', 'foreign', 'plain', 'prose', 'code', 'levelL', 'indent'].every(function (k) { return kinds[k] > 5; }), json(kinds));
    ok('hand edits: the fold of read 1 equals the fold of read 2; the second read\'s key is its body key', foldFails === 0 && folded > 50,
      foldFails + ' failures, ' + folded + ' folded; first: ' + foldFirst);
  }

  /* ========================================================= performance */

  function perfSpec() {
    var groups = [], tasks = [], attach = { h: ['Intro paragraph.'] };
    for (var g = 0; g < 30; g++) groups.push({ id: 'g' + g, title: 'Group ' + g });
    for (var i = 0; i < 300; i++) tasks.push({ id: 't' + i, note: 'n' + i, title: 'Task ' + i + ' [x]', start: '2026-10-01', end: '2026-10-09', group: 'g' + (i % 30) });
    for (var b = 0; b < 60; b++) attach['t:t' + (b * 5)] = ['  - note ' + b, '', 'Prose line ' + b];
    var c = chart({ v: 1, settings: { listHeading: 'Tasks' }, groups: groups, tasks: tasks });
    var text = 'Intro.\n\n' + RP(c, {}, { attach: attach }).text + '\n\nTail.';
    function best(fn) { var t = Infinity; for (var k = 0; k < 5; k++) { var s = Date.now(); fn(); t = Math.min(t, Date.now() - s); } return t; }
    var rd = LR(text);
    ok('performance: the 300-task note reads as a list', rd.list && rd.list.sections.length === 31 && Object.keys(rd.list.attach).filter(function (k) { return rd.list.attach[k].length; }).length === 61);
    var tr = best(function () { LR(text); B.listReport(text); });
    var tw = best(function () { RP(rd.chart, {}, { attach: rd.list.attach }); });
    ok('performance: read plus report under 30 ms (' + tr + ' ms)', tr < 30);
    ok('performance: regionParts under 15 ms (' + tw + ' ms)', tw < 15);
  }

  function reportSpec() {
    var legacy = B.listReport(fix('region-basic.md'));
    ok('listReport: a legacy chart reports deleted and edited only', legacy && legacy.deleted.length === 0 && legacy.moved.length === 0);
    var gone = fix('list-basic.md').replace(/- \[Sync engine\][^\n]*\n/, '');
    eq('listReport: a deleted task line', json(B.listReport(gone).deleted), json(['t3']));
    var moved = fix('list-basic.md').replace(/(- \[Sync engine\][^\n]*\n)/, '').replace('Launch plan for the Q4 release.\n', 'Launch plan for the Q4 release.\n- [Sync engine](synapseresource://note/77aa3c21-9e4f-4b6d-a0c8-5d2e1f3a4b03)\n');
    eq('listReport: a task line moved above the list is edited', json([B.listReport(moved).edited, B.listReport(moved).deleted]), json([['t3'], []]));
    eq('listReport: none while the heading is missing', B.listReport(fix('list-missing-heading-prose.md')).missing, true);
    var ids = {}, taken = {};
    ids.a = B.derivedId('g', 'list:QA#0', taken);
    ok('derivedId: pure and never reuses a taken id', ids.a === B.derivedId('g', 'list:QA#0', {}) && B.derivedId('g', 'list:QA#0', taken) !== ids.a);
  }

  /* ================================================ gate and join (round 1) */

  function gateSpec() {
    // Without opts.list the module is an older build (main spec §5.6).
    var x = fix('list-basic.md'), r = B.read(x);
    ok('gate: without opts.list no list is read', r.list === null && r.seed === null && !r.missing && !r.legacy && r.key === r.bodyKey);
    eq('gate: the region is main spec §5.6 (here the fence)', r.region.text.indexOf('```synapse-gantt'), 0);
    var old = B.splice(x, B.region(r.chart, EX_SUMS, { embedOutside: r.embedOutside }));
    ok('gate: an ungated save writes the bullet mirror and keeps every line above it', old.indexOf(x.slice(0, r.region.start)) === 0 &&
      old.indexOf('- **Discovery**\n  - [Customer interviews]') > 0, old);
    var ro = read(old);
    ok('gate: the gated reader then sees the older-build case with nothing lost', ro.list && ro.list.ambiguous.length === 5 &&
      blocksIn(LR(x).list, old).length === 0 && save(save(old, EX_SUMS), EX_SUMS) === save(old, EX_SUMS));
    eq('gate: regionParts without opts.list writes main spec §5.6', B.regionParts(chart(CT), {}, {}).text.indexOf('- [T1]'), 0);
    var mh = fix('list-missing-heading-prose.md'), rm = B.read(mh);
    ok('gate: a headless list is not in the missing state without opts.list', !rm.missing && rm.fallback === null);
    var ms = B.splice(mh, B.region(rm.chart, {}, { embedOutside: rm.embedOutside }));
    ok('gate: an ungated save of a headless list keeps every line above the fence', ms.indexOf(mh.slice(0, rm.region.start)) === 0);
    ok('gate: mirrorGap is the main spec one', B.mirrorGap(x) !== null && json(B.mirrorGap(x).deleted) === json([]));
    ok('gate: ungated mirrorGap on a list note calls every task edited (why phase 2 must not use it)', B.mirrorGap(x).edited.length === 5);
    eq('gate: mirrorGap(text, {list: true}) answers from listReport: no banner on list-basic', json(B.mirrorGap(x, { list: true })), json({ key: LR(x).key, deleted: [], edited: [] }));
    eq('gate: gated mirrorGap reports a deleted line', json(B.mirrorGap(x.replace(/- \[Sync engine\][^\n]*\n/, ''), { list: true }).deleted), json(['t3']));
  }

  function joinSpec() {
    var COPY = '  - [T2](synapseresource://note/n2?via=gantt)';
    var c = chart(CT);
    // Writer: a re-homed block joins after one blank line.
    var p = RP(c, {}, { attach: { h: [], 't:t1': ['- **Note**'], 't:gone': [COPY, COPY] }, ambiguous: ['t2'] });
    eq('join: a re-homed block is joined after one blank line', json(p.attach['t:t1']), json(['- **Note**', '', COPY, COPY]));
    var rp = LR(p.text);
    ok('join: no LEGACY pair forms across the join', rowsOf(rp, 'LEGACY').length === 0 && rp.list.sections.length === 2 &&
      json(rp.list.attach) === json(p.attach), p.text);
    // Reader: the heading and embed blocks join with one blank line.
    var ce = chart(Object.assign({}, CT, { settings: { listHeading: 'Tasks', embed: true } }));
    var t = '## Tasks\n- **Note**\n' + B.embedLine() + '\n' + COPY + '\n' + COPY + '\n\n- [T1](synapseresource://note/n1?via=gantt)\n\n' +
      '```synapse-gantt\n' + B.serialize(ce) + '\n```', re = LR(t);
    eq('join: the heading and embed blocks join with a blank line', json(re.list.attach.h), json(['- **Note**', '', COPY, COPY]));
    var s1 = save(t), r1 = read(s1);
    ok('join: after a save no LEGACY pair, same blocks, stable', rowsOf(r1, 'LEGACY').length === 0 && r1.list.sections.length === 2 &&
      json(r1.list.attach.h) === json(re.list.attach.h) && save(s1) === s1, s1);

    // Property: a bold line ending the block before a removed owner whose
    // block starts with indented copies of an ambiguous task.
    var seed = seedOf() + 4, rng = mulberry32(seed), runs = 0, fails = 0, first = '';
    for (var n = 0; runs < 100 && n < 3000; n++) {
      var w = writtenNote(rng, n), g = w.g, noted = g.c.tasks.filter(function (x) { return x.note; });
      if (noted.length < 2) continue;
      var A = noted[Math.floor(rng() * noted.length)], others = noted.filter(function (x) { return x !== A; });
      var Bt = others[Math.floor(rng() * others.length)];
      var keys0 = Object.keys(RP(g.c, w.sums, { ambiguous: [A.id] }).attach), at = keys0.indexOf('t:' + Bt.id);
      var att = {};
      keys0.forEach(function (k) { att[k] = []; });
      var line = '  - [' + B.ltext(A.title) + '](synapseresource://note/' + A.note + '?via=gantt)';
      att[keys0[at - 1]] = ['Some text.', '- **Held**'];
      att['t:' + Bt.id] = [line, line];
      var text = w.P + RP(g.c, w.sums, { embedOutside: w.eo, attach: att, ambiguous: [A.id] }).text;
      var r0 = LR(text);
      if (!r0.list || r0.list.ambiguous.indexOf(A.id) < 0 || rowsOf(r0, 'LEGACY').length) { fails++; if (!first) first = '#' + n + ' setup\n' + text; continue; }
      runs++;
      var s = save(text, w.sums, function (cc) { return M.removeTask(cc, Bt.id).chart; }), rs = read(s);
      var bad = rowsOf(rs, 'LEGACY').length || rs.list.sections.length !== g.c.groups.length + 1 || blocksIn(r0.list, s).length ||
        save(s, w.sums) !== s;
      if (bad) { fails++; if (!first) first = '#' + n + '\n' + s; }
    }
    ok('join: 100 re-homed blocks after a bold line never form a LEGACY pair (seed ' + seed + ')', fails === 0 && runs === 100, runs + ' runs, ' + fails + ' failures; first: ' + first);
  }

  /*
   * LEGACY needs a bold title naming a JSON group (review round 2): a user's
   * "- **Waiting on**" over an indented link to a note that is later added
   * to the chart stays TEXT; no phantom group, no regroup.
   */
  function legacySpec() {
    var c = chart({ v: 1, settings: { listHeading: 'Tasks' }, groups: [{ id: 'g1', title: 'Build' }], tasks: [{ id: 't1', note: 'n1', title: 'A', group: 'g1' }] });
    var t = RP(c, {}, { attach: { h: [], 'g:g1': [], 't:t1': ['- **Waiting on**', '  - [Legal](synapseresource://note/nf?via=gantt)'] } }).text;
    var c2 = M.addTasks(c, [{ note: 'nf', title: 'Legal', group: 'g1' }]).chart;
    var s = save(t, {}, function () { return c2; }), rs = read(s);
    ok('legacy: an untitled-group bold line stays TEXT after its link\'s note joins the chart', rowsOf(rs, 'LEGACY').length === 0 &&
      rs.list.sections.length === 2 && !rs.list.sections.some(function (x) { return x.marker && x.marker.kind === 'new'; }), s);
    var g2t = t.replace('- **Waiting on**', '- **Build**'), c3 = read(g2t);
    ok('legacy: a bold line titled like a group over an indented MARKED task is LEGACY', LR(g2t.replace('synapseresource://note/nf?', 'synapseresource://note/n1?')).list.rows.some(function (x) { return x.cls === 'LEGACY'; }) && c3.list);

    var seed = seedOf() + 5, rng = mulberry32(seed), runs = 0, fails = 0, first = '';
    for (var n = 0; runs < 100 && n < 2000; n++) {
      var w = writtenNote(rng, n), g = w.g;
      var keys0 = Object.keys(w.r.attach), k = keys0[Math.floor(rng() * keys0.length)];
      var att = JSON.parse(json(w.r.attach));
      att[k] = att[k].concat(['- **Waiting on**', '  - [Legal](synapseresource://note/zz-legal?via=gantt)']);
      var text = w.P + RP(g.c, w.sums, { embedOutside: w.eo, attach: att }).text, r0 = LR(text);
      if (!r0.list || rowsOf(r0, 'LEGACY').length) { fails++; if (!first) first = '#' + n + ' setup\n' + text; continue; }
      runs++;
      var gid = g.c.groups.length && rng() < 0.7 ? g.c.groups[Math.floor(rng() * g.c.groups.length)].id : null;
      var s1 = save(text, w.sums, function (cc) { return M.addTasks(cc, [{ note: 'zz-legal', title: 'Legal', group: gid }]).chart; });
      var r1 = LR(s1);
      var bad = rowsOf(r1, 'LEGACY').length || r1.list.sections.length !== g.c.groups.length + 1 ||
        r1.list.sections.some(function (x) { return x.marker && x.marker.kind !== 'same'; }) || blocksIn(r0.list, s1).length || save(s1, w.sums) !== s1;
      if (bad) { fails++; if (!first) first = '#' + n + '\n' + s1; }
    }
    ok('legacy: 100 charts with a bold line over a foreign indented link, then its note added: no phantom group (seed ' + seed + ')', fails === 0 && runs === 100, runs + ' runs, ' + fails + ' failures; first: ' + first);
  }

  SPEC.suites.push({ name: 'the list legacy spec', fn: legacySpec });
  SPEC.suites.push({ name: 'the list gate spec', fn: gateSpec });
  SPEC.suites.push({ name: 'the list join spec', fn: joinSpec });
  SPEC.suites.push({ name: 'the list class spec', fn: classSpec });
  SPEC.suites.push({ name: 'the list boundary spec', fn: boundarySpec });
  SPEC.suites.push({ name: 'the list writer spec', fn: writerSpec });
  SPEC.suites.push({ name: 'the list fixture spec', fn: fixtureSpec });
  SPEC.suites.push({ name: 'the list report spec', fn: reportSpec });
  SPEC.suites.push({ name: 'the list idempotence and no-loss property', fn: idempotenceSpec });
  SPEC.suites.push({ name: 'the list copies property', fn: copiesSpec });
  SPEC.suites.push({ name: 'the list missing heading property', fn: missingSpec });
  SPEC.suites.push({ name: 'the list hand edits property', fn: handEditSpec });
  SPEC.suites.push({ name: 'the list performance guard', fn: perfSpec });

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
