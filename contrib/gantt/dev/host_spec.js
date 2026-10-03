/*
 * Gantt host.js assertions (M3a): the host functions against installMock,
 * every mock quirk and hook of plan §17.1 / §9.1.5, the §7 query shapes,
 * the §8 write shapes, isChartHead (§7.7), timing (§9.1.3) and the launch
 * matrix (§10.1). Runs under node (dev/run.js) and in the browser
 * (dev/auto_smoke.html); DOM-only host tests live in dev/dom_spec.js.
 */
(function (global) {
  'use strict';
  var GT = global.GT, H = GT.host, B = GT.block, M = GT.model, SPEC = GT.spec;
  var A = SPEC.api, ok = A.ok, eq = A.eq, same = A.same, acase = A.acase;

  function mk(seed, o) { return H.installMock(seed, Object.assign({ storage: new Map(), global: false }, o || {})); }
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  // Resolves {settled, value} after at most `ms`.
  function within(p, ms) {
    var done = false, value;
    Promise.resolve(p).then(function (v) { done = true; value = v; });
    return sleep(ms).then(function () { return { settled: done, value: value }; });
  }
  function nid(i) { return 'note-' + ('0000' + i).slice(-4); }
  function chart(tasks, settings) { return M.coerce({ v: 1, settings: settings || {}, tasks: tasks || [] }).chart; }
  function regionOf(c) { return B.region(c, null, {}); }
  function chartText(intro, c) { return (intro ? intro + '\n\n' : '') + regionOf(c); }
  function noWholeReplace(name, mock) { eq(name + ': no whole-note replace was sent', mock.wholeReplaces().length, 0); }
  function big(n, ch) { return new Array(n + 1).join(ch); }

  function hostSpec() {
    /* ------------------------------------------------------------ pure */

    // §7.7 isChartHead.
    var F = '```synapse-gantt';
    ok('head: a fence at the note start', H.isChartHead(F + '\n{"v":1,\n"tasks":[]}'));
    ok('head: a fence after text', H.isChartHead('ro\n\n' + F + '\n{"v":1}'));
    ok('head: CRLF', H.isChartHead('x\r\n' + F + '\r\n{"v":1}'));
    ok('head: spaced JSON', H.isChartHead('\n' + F + '\n  {  "v" : 1 }'));
    ok('head: trailing spaces and a tab after the info string', H.isChartHead('\n' + F + ' \t\n{"v":1}'));
    ok('head: 3-space indent', H.isChartHead('\n   ' + F + '\n{"v":1}'));
    ok('head: 4-space indent is a code block', !H.isChartHead('\n    ' + F + '\n{"v":1}'));
    ok('head: an inline mention is not a chart', !H.isChartHead('use ' + F + '\n{"v":1}'));
    ok('head: an info string with more words is not a chart', !H.isChartHead('\n' + F + ' title="x"\n{"v":1}'));
    ok('head: JSON without v first is not a chart', !H.isChartHead('\n' + F + '\n{"tasks":[]}'));
    ok('head: an empty head', !H.isChartHead(''));
    ok('head: not a string', !H.isChartHead(null));
    // The window starts 4 characters before the fence, so a mid-line
    // mention preceded by spaces never looks like a line start.
    ok('head: a mention after 3 spaces mid-line is not a chart', !H.isChartHead('d   ' + F + '\n{"v":1}'));

    // sqlId / space clause.
    ok('sqlId accepts a uuid', H.sqlId('8f0c1e2a-5b7d-4c11-9a0e-2f6b3c9d1e01') !== null);
    ok("sqlId rejects a quote", H.sqlId("a'b") === null);
    ok('sqlId rejects a space', H.sqlId('a b') === null);
    eq('sqlStr doubles quotes and drops NUL', H.sqlStr("Bob's\u0000"), "'Bob''s'");
    eq('space clause outside a Space', H.spaceClause(null), '1=1');
    eq('space clause for a Space without tags', H.spaceClause({ id: 's', name: 'S', tags: [] }), '1=1');
    var sc = H.spaceClause({ id: 's', name: 'S', tags: ['work', "o'k"] });
    ok('space clause ANDs every Space tag', sc.indexOf("tg.name = 'work'") > 0 && sc.indexOf("tg.name = 'o''k'") > 0 && / AND EXISTS/.test(sc));
    ok('space clause ORs all-spaces around the Space group only', /^\(\(EXISTS .*\) OR EXISTS .*tg\.name = 'all-spaces'\)\)$/.test(sc));

    // §7 query shapes.
    var ids99 = [], ids150 = [];
    for (var i = 0; i < 150; i++) { ids150.push(nid(i)); if (i < 99) ids99.push(nid(i)); }
    var metaSql = H.sql.meta(ids99);
    ok('7.1 selects the meta columns and length(content), never content', /^SELECT id, title, type, status, scheduledAt, completeBy, updatedAt, isArchived, length\(content\) AS clen FROM notes/.test(metaSql) && !/[ ,]content[ ,]/.test(metaSql.replace('length(content)', '')));
    ok('7.1 orders by id with LIMIT 100', / ORDER BY id LIMIT 100$/.test(metaSql));
    ok('7.2 aggregates subnotes in createdAt order, rowid breaking ties (M7 review)', /ORDER BY noteId, createdAt, rowid\) GROUP BY noteId LIMIT 100$/.test(H.sql.subnotes(['a'])) && /group_concat\(isCompleted, ''\)/.test(H.sql.subnotes(['a'])));
    var ch = H.sql.children(['a']);
    ok("7.3 counts only 'subnote' links to task notes", /r\.type = 'subnote' AND n\.type = 'task'/.test(ch) && /CASE WHEN n\.status = 'complete' THEN 1 ELSE 0 END/.test(ch) && /ORDER BY r\.fromNoteId, r\.createdAt, r\.rowid\) GROUP BY noteId LIMIT 100$/.test(ch));
    var w = H.sql.windows(['a'], "Bob''s");
    ok('7.4 window: content only up to 16000 characters', /CASE WHEN length\(content\) <= 16000 THEN content ELSE substr\(content, max\(1, instr\(content, 'Bob''s'\) - 200\), 16000\) END AS win/.test(w));
    ok('7.4 window: the offset expression matches', /CASE WHEN length\(content\) <= 16000 THEN 1 ELSE max\(1, instr\(content, 'Bob''s'\) - 200\) END AS off/.test(w) && / LIMIT 100$/.test(w));
    eq('7.6 readNote SQL', H.sql.note('abc'), "SELECT content, length(content) AS clen, updatedAt FROM notes WHERE id = 'abc' LIMIT 1");
    var home = H.sql.charts(null, 26, 25, true);
    ok('7.7 home: no content column, a 64-character head 4 before the fence', !/n\.content AS|, n\.content,/.test(home) && /substr\(n\.content, max\(1, instr\(n\.content, '```synapse-gantt'\) - 4\), 64\) AS head/.test(home));
    ok('7.7 home: counts "note":" in SQL', /\(length\(n\.content\) - length\(replace\(n\.content, '"note":"', ''\)\)\) \/ 8 AS tasks/.test(home));
    ok('7.7 home: archived excluded, newest first, LIMIT 26 OFFSET k', /n\.isArchived = 0 AND 1=1 ORDER BY n\.updatedAt DESC LIMIT 26 OFFSET 25$/.test(home));
    var ref = H.sql.referencing('abc', null);
    ok('7.7 chooser: the note id searched from the fence on, LIMIT 10', /instr\(substr\(n\.content, instr\(n\.content, '```synapse-gantt'\)\), 'abc'\) > 0/.test(ref) && / LIMIT 10$/.test(ref));
    eq('§8 subnote toggle SQL', H.sql.subnoteDone('n1', 's1', true), "UPDATE subnotes SET isCompleted = 1 WHERE id = 's1' AND noteId = 'n1'");

    // SQLite character semantics used by the mock.
    eq('sqlite length stops at NUL', H.sqlite.length('ab\u0000cd'), 2);
    eq('sqlite length counts code points', H.sqlite.length('a😀b'), 3);
    eq('sqlite instr is 1-based in code points', H.sqlite.instr('😀xy', 'y'), 3);
    eq('sqlite instr of a missing needle is 0', H.sqlite.instr('abc', 'z'), 0);
    eq("sqlite instr of '' is 1", H.sqlite.instr('abc', ''), 1);
    eq('sqlite substr in code points', H.sqlite.substr('😀abc', 2, 2), 'ab');

    /* ------------------------------------------------- launch matrix */

    function L(notes, params) { return { notes: notes || [], params: params || {} }; }
    var chartNote = { id: 'c1', title: 'C', content: chartText('Intro', chart([{ id: 't1', note: 'n1', title: 'A' }])) };
    var plainNote = { id: 'p1', title: 'P', content: 'just text' };
    eq('route: embed opens Params.chart', H.route(L([plainNote], { mode: 'embed', chart: 'c9' })).noteId, 'c9');
    var eR = H.route(L([chartNote], { mode: 'embed' }));
    ok('route: embed without chart opens Notes[0]', eR.kind === 'embed' && eR.noteId === 'c1' && eR.needsRead === false);
    eq('route: Params.chart', H.route(L([plainNote], { chart: 'c2' })).kind + ':' + H.route(L([plainNote], { chart: 'c2' })).noteId, 'chart:c2');
    eq('route: standalone is home', H.route(L([chartNote], { standalone: '1' })).kind, 'home');
    eq("route: standalone 'false' is not home", H.route(L([chartNote], { standalone: 'false' })).kind, 'chart');
    eq('route: no notes is home', H.route(L([], {})).kind, 'home');
    var r1 = H.route(L([chartNote], {}));
    ok('route: one chart note opens it with the block already read', r1.kind === 'chart' && r1.noteId === 'c1' && r1.read && r1.read.status === 'ok' && r1.needsRead === false);
    eq('route: one plain note is the chooser', H.route(L([plainNote], {})).kind, 'chooser');
    eq('route: a malformed chart note still opens as a chart', H.route(L([{ id: 'm1', content: F + '\n{"v":1,\n' }], {})).kind, 'chart');
    same('route: several notes', H.route(L([plainNote, chartNote], {})), { kind: 'multi', noteIds: ['p1', 'c1'] });

    /* ------------------------------------------ mock basics and launch */

    var m0 = mk([{ id: 'c1', title: 'Chart', content: chartNote.content }, { id: 'p1', title: 'P', content: 'x' }], {
      Notes: ['c1'], Params: { mode: 'embed' }, locale: 'zh-CN', space: { id: 's1', name: 'Work', tags: ['work'] }
    });
    var l0 = m0.host.launch();
    ok('launch: Notes from the mock', l0.notes.length === 1 && l0.notes[0].id === 'c1' && l0.notes[0].content === chartNote.content);
    ok('launch: Params, locale, space', l0.params.mode === 'embed' && l0.embed === true && l0.locale === 'zh-CN' && l0.space && l0.space.tags[0] === 'work');
    eq('launch: no theme from today\'s host', l0.theme, null);
    var mB = mk([{ id: 'c1', content: 'x' }], { Notes: [{ id: 'blk-tmp-1', isBlockScope: true, parentNoteId: 'c1', title: 'C', content: F + '\n{"v":1}\n```' }] });
    var lB = mB.host.launch();
    ok('launch: a block scope resolves to parentNoteId', lB.notes[0].id === 'c1' && lB.notes[0].blockScope && lB.notes[0].transientId === 'blk-tmp-1');
    var rB = H.route(lB);
    ok('route: a block-scoped launch resolves the parent after a read', rB.kind === 'resolve' && rB.noteId === 'c1' && rB.needsRead === true && rB.read === null);
    eq('launch: an empty host', H.create(null).launch().notes.length, 0);
    eq('locale: falls back without a host', typeof H.create(null).locale(), 'string');
    eq('theme: a host that publishes one', mk([], { theme: 'dark' }).host.theme(), 'dark');
    eq('theme: anything else is null', mk([], { theme: 'blue' }).host.theme(), null);

    /* -------------------------------------------------------- reads */

    // 100-row cap after the full fetch.
    acase('mock: runQuery caps at 100 rows after the full fetch', function () {
      var notes = [];
      for (var k = 0; k < 150; k++) notes.push({ id: nid(k), title: 'T' + k });
      var m = mk(notes);
      return m.host.query('SELECT id, title FROM notes ORDER BY id LIMIT 500 OFFSET 0').then(function (r) {
        ok('cap: ok', r.ok);
        eq('cap: 100 rows', r.rows.length, 100);
        ok('cap: truncated with totalRows', r.truncated === true && r.totalRows === 150);
        return m.host.query('SELECT id, title FROM notes ORDER BY id LIMIT 100 OFFSET 100');
      }).then(function (r) {
        ok('cap: an OFFSET page under the cap is not truncated', r.ok && r.rows.length === 50 && r.truncated === false && r.totalRows === null);
        return m.host.query('SELECT * FROM somewhere');
      }).then(function (r) {
        ok('mock: an unknown query shape fails', r.ok === false && /unsupported/.test(r.error));
      });
    });

    acase('7.1 meta in chunks of 99', function () {
      var notes = [];
      for (var k = 0; k < 150; k++) notes.push({ id: nid(k), title: 'T' + k, content: k === 3 ? 'a😀b' : 'abc', type: k % 2 ? 'task' : 'note', status: k % 2 ? 'in_progress' : null, scheduledAt: k === 1 ? '2026-10-01' : null, isArchived: k === 5 });
      var m = mk(notes);
      var want = ids150.slice(0, 140).concat(['gone-1', 'bad id', nid(3)]);
      return m.host.meta(want).then(function (r) {
        eq('meta: two runQuery calls for 141 valid ids', m.count('runQuery'), 2);
        ok('meta: chunks are 99 then 42', (m.queries[0].match(/'/g) || []).length / 2 === 99 && (m.queries[1].match(/'/g) || []).length / 2 === 42);
        ok('meta: ok', r.ok && r.failed.length === 0);
        eq('meta: rows for every note', Object.keys(r.rows).length, 140);
        same('meta: missing are the absent and the invalid ids', r.missing.slice().sort(), ['bad id', 'gone-1'].sort());
        same('meta: a row', r.rows[nid(1)], { id: nid(1), title: 'T1', type: 'task', status: 'in_progress', scheduledAt: '2026-10-01', completeBy: null, updatedAt: m.note(nid(1)).updatedAt, isArchived: false, clen: 3 });
        eq('meta: clen counts characters', r.rows[nid(3)].clen, 3);
        eq('meta: isArchived is a boolean', r.rows[nid(5)].isArchived, true);
        m.script('runQuery', function (sql) { return /id IN/.test(sql) && sql.indexOf(nid(100)) > 0 ? { success: false, error: 'boom' } : undefined; });
        return m.host.meta(ids150);
      }).then(function (r) {
        ok('meta: a failed chunk resolves nothing', !r.ok && r.failed.length === 51 && r.failed.indexOf(nid(120)) >= 0);
        ok('meta: the failed chunk\'s ids are not missing', r.missing.indexOf(nid(120)) < 0 && r.missing.length === 0);
        ok('meta: the good chunk still resolves', !!r.rows[nid(0)] && !r.rows[nid(120)]);
      });
    });

    acase('7.2 and 7.3 counts', function () {
      var notes = [{ id: 'p1', type: 'task' }, { id: 'p2', type: 'task' }, { id: 'p3' },
        { id: 'k1', type: 'task', status: 'complete' }, { id: 'k2', type: 'task', status: 'todo' }, { id: 'k3', type: 'note' }, { id: 'k4', type: 'task', status: 'complete' }];
      var m = mk(notes);
      m.addSubnote('p1', { id: 's3', isCompleted: 1, createdAt: 30 });
      m.addSubnote('p1', { id: 's1', isCompleted: 1, createdAt: 10 });
      m.addSubnote('p1', { id: 's2', isCompleted: 0, createdAt: 20 });
      m.addSubnote('p2', { id: 's4', isCompleted: 0, createdAt: 5 });
      m.link('p1', 'k2', 'subnote', 2);
      m.link('p1', 'k1', 'subnote', 1);
      m.link('p1', 'k3', 'subnote', 3);      // not a task
      m.link('p1', 'k4', 'related', 4);      // not a subnote link
      m.link('p2', 'k4', 'subnote', 1);
      return m.host.subnoteCounts(['p1', 'p2', 'p3']).then(function (r) {
        eq('7.2: one call', m.count('runQuery'), 1);
        same('7.2: counts and bits in createdAt order', r.counts, { p1: { done: 2, total: 3, bits: '101' }, p2: { done: 0, total: 1, bits: '0' }, p3: { done: 0, total: 0, bits: '' } });
        return m.host.childCounts(['p1', 'p2', 'p3']);
      }).then(function (r) {
        same('7.3: task children by subnote links, in createdAt order', r.counts, { p1: { done: 1, total: 2, bits: '10' }, p2: { done: 1, total: 1, bits: '1' }, p3: { done: 0, total: 0, bits: '' } });
        m.resetCounts();
        var many = [];
        for (var k = 0; k < 101; k++) many.push(nid(k));
        return m.host.subnoteCounts(many.slice(0, 100)).then(function () {
          eq('7.2: 100 ids are one call (§7.5 budget)', m.count('runQuery'), 1);
          return m.host.subnoteCounts(many);
        }).then(function (r2) {
          eq('7.2: 101 ids are two calls', m.count('runQuery'), 3);
          ok('7.2: notes without rows count zero', r2.ok && r2.counts[nid(100)].total === 0);
        });
      });
    });

    acase('7.4 checklist windows', function () {
      var small = '# T\n\n## Checklist\n- [x] a\n- [ ] b';
      var far = big(40000, 'x') + '\n## Checklist\n- [ ] a\n' + big(30000, 'y');
      var nearEnd = big(30000, 'z') + '\n## Checklist\n- [x] end';
      var none = big(20000, 'q');
      var emoji = big(8000, '😀');   // 8000 code points, 16000 UTF-16 units
      var quoted = big(17000, 'w') + "\n## Bob's list\n- [ ] a";
      var notes = [{ id: 'sm', content: small }, { id: 'far', content: far }, { id: 'near', content: nearEnd }, { id: 'none', content: none }, { id: 'emo', content: emoji }, { id: 'quo', content: quoted }];
      for (var k = 0; k < 40; k++) notes.push({ id: nid(k), content: 'x' });
      var m = mk(notes);
      var all = notes.map(function (n) { return n.id; });
      return m.host.checklistWindows(all, '## Checklist').then(function (r0) {
        m.resetCounts();
        return m.host.checklistWindows(['quo'], "## Bob's list").then(function (q) {
          ok('7.4: the needle has its quote doubled in SQL', m.queries[0].indexOf("instr(content, 'Bob''s list')") > 0);
          eq("7.4: a section with a quote is found", q.windows.quo.win.indexOf("Bob's list"), 200);
          m.resetCounts();
          return m.host.checklistWindows(all, '## Checklist');
        });
      }).then(function (r) {
        eq('7.4: 46 ids are 3 calls of at most 20', m.count('runQuery'), 3);
        ok('7.4: every chunk has at most 20 ids', m.queries.every(function (q) { return (q.split('WHERE id IN (')[1].match(/'/g) || []).length / 2 <= 20; }));
        ok('7.4: ok', r.ok && r.failed.length === 0);
        same('7.4: a small note is the whole window', [r.windows.sm.win, r.windows.sm.off, r.windows.sm.whole], [small, 1, true]);
        var at = H.sqlite.instr(far, 'Checklist') - 200;
        ok('7.4: a large note: 16000 characters from 200 before the heading', r.windows.far.off === at && r.windows.far.win.length === 16000);
        eq('7.4: the window starts 200 characters before the needle', r.windows.far.win.indexOf('Checklist'), 200);
        ok('7.4: a window near the end is shorter than 16000 and passes the guard', r.windows.near.win.length < 16000 && r.windows.near.win.length === H.sqlite.length(nearEnd) - r.windows.near.off + 1);
        ok('7.4: no heading: the window starts at 1', r.windows.none.off === 1 && r.windows.none.win.length === 16000 && !r.windows.none.whole);
        ok('7.4: emoji make win.length exceed the character count, and it passes', r.windows.emo.whole && r.windows.emo.win.length === 16000 && r.windows.emo.clen === 8000);
        m.resetCounts();
        m.truncateReads(1000, 1);
        return m.host.checklistWindows(['far', 'sm'], 'Checklist');
      }).then(function (r) {
        ok('7.4: a truncated window counts as a failed read', !r.ok && r.failed.indexOf('far') >= 0 && !r.windows.far);
        ok('7.4: a window that fits is still read', !!r.windows.sm);
        m.script('runQuery', [{ success: false, error: 'x' }]);
        return m.host.checklistWindows(['sm'], 'Checklist');
      }).then(function (r) {
        ok('7.4: a failed query resolves nothing', !r.ok && r.failed[0] === 'sm' && r.missing.length === 0);
        return m.host.checklistWindows(['gone'], '');
      }).then(function (r) {
        ok("7.4: the whole-note section '' works and an absent note is missing", r.ok && r.missing[0] === 'gone');
      });
    });

    acase('7.4 paged fallback', function () {
      var text = big(200000, 'a') + '😀' + big(10, 'b');
      var huge = big(300000, 'c');
      var m = mk([{ id: 'p', content: text }, { id: 'h', content: huge }]);
      return m.host.readPaged('p', 1).then(function (r) {
        ok('paged: reads to the end in 64 KB pages', r.ok && r.complete && r.pages === 4 && r.text === text);
        ok('paged: page SQL', /substr\(content, 1, 65536\) AS page FROM notes WHERE id = 'p' LIMIT 1/.test(m.queries[0]) && /substr\(content, 65537, 65536\)/.test(m.queries[1]));
        return m.host.readPaged('h', 1);
      }).then(function (r) {
        ok('paged: capped at 256 KB', r.ok && !r.complete && r.text.length === 262144);
        return m.host.readRange('p', 199990, 100);
      }).then(function (r) {
        ok('range: near the end the page is short and passes the guard', r.ok && r.chars === 22 && r.text === big(11, 'a') + '😀' + big(10, 'b'));
        m.truncateReads(100, 1);
        return m.host.readRange('p', 1, 65536);
      }).then(function (r) {
        ok('range: a truncated page fails', !r.ok && r.truncated);
        return m.host.readRange('gone', 1, 10);
      }).then(function (r) { ok('range: an absent note', !r.ok && r.missing); });
    });

    acase('7.6 readNote and its guard', function () {
      var m = mk([{ id: 'a', content: 'hello\nworld' }, { id: 'nul', content: 'ab\u0000cd' }, { id: 'emo', content: '😀😀' }]);
      return m.host.readNote('a').then(function (r) {
        ok('readNote: ok', r.ok && r.content === 'hello\nworld' && r.clen === 11 && r.updatedAt === m.note('a').updatedAt);
        eq('readNote: SQL', m.queries[0], H.sql.note('a'));
        return m.host.readNote('nul');
      }).then(function (r) {
        ok('readNote: a note with U+0000 passes the one-sided guard', r.ok && r.clen === 2 && r.content === 'ab\u0000cd');
        return m.host.readNote('emo');
      }).then(function (r) {
        ok('readNote: emoji pass (UTF-16 is longer than clen)', r.ok && r.clen === 2 && r.content.length === 4);
        m.truncateReads(3, 1);
        return m.host.readNote('a');
      }).then(function (r) {
        ok('readNote: a truncated read is rejected', !r.ok && r.truncated === true && r.content === undefined);
        return m.host.readNote('gone');
      }).then(function (r) {
        ok('readNote: an absent note is not an empty note', !r.ok && r.missing === true && r.content === undefined);
        return m.host.readNote("x' OR 1=1 --");
      }).then(function (r) {
        ok('readNote: an invalid id never reaches SQL', !r.ok && m.queries.length === 5);
      });
    });

    acase('7.7 home list', function () {
      var notes = [], c = chart([{ id: 't1', note: 'n1', title: 'A' }, { id: 't2', note: 'n2', title: 'B' }]);
      for (var k = 0; k < 30; k++) notes.push({ id: nid(k), title: 'Chart ' + k, content: chartText('Intro ' + k, c), updatedAt: 1000 + k, tags: ['work'] });
      notes.push({ id: 'arch', title: 'Arch', content: chartText('', c), updatedAt: 5000, isArchived: true, tags: ['work'] });
      notes.push({ id: 'mention', title: 'Mention', content: 'I use ```synapse-gantt blocks.\n\n' + chartText('', c), updatedAt: 5001, tags: ['work'] });
      notes.push({ id: 'other', title: 'Other space', content: chartText('', c), updatedAt: 5002, tags: ['home'] });
      notes.push({ id: 'all', title: 'All spaces', content: chartText('', c), updatedAt: 5003, tags: ['all-spaces'] });
      notes.push({ id: 'crlf', title: 'CRLF', content: 'x\r\n\r\n```synapse-gantt\r\n{ "v" : 1 }\r\n```', updatedAt: 5004, tags: ['work'] });
      notes.push({ id: 'plain', title: 'Plain', content: 'nothing', updatedAt: 5005, tags: ['work'] });
      var m = mk(notes, { space: { id: 's', name: 'Work', tags: ['work'] } });
      var p1;
      return m.host.findCharts({}).then(function (r) {
        p1 = r;
        ok('home: ok and counted', r.ok && r.counted);
        eq('home: one query', m.count('runQuery'), 1);
        ok('home: LIMIT 26 OFFSET 0 with the Space filter', /LIMIT 26 OFFSET 0$/.test(m.queries[0]) && /tg\.name = 'work'/.test(m.queries[0]));
        eq('home: newest first; archived, other-Space and plain notes excluded; the mention excluded by isChartHead', r.charts.slice(0, 3).map(function (x) { return x.id; }).join(','), 'crlf,all,' + nid(29));
        ok('home: the inline mention before the real block is left out (first-occurrence limit)', !r.charts.some(function (x) { return x.id === 'mention'; }));
        eq('home: task count from SQL', r.charts[2].tasks, 2);
        ok('home: more and next', r.more === true && r.next === 25);
        eq('home: 25 rows were a page, 24 of them charts', r.charts.length, 24);
        return m.host.findCharts({ offset: r.next });
      }).then(function (r) {
        ok('home: second page OFFSET 25', /LIMIT 26 OFFSET 25$/.test(m.queries[1]) && r.more === false);
        eq('home: the rest', r.charts.length, 33 - 25);
        ok('home: pages do not overlap', !r.charts.some(function (x) { return p1.charts.some(function (y) { return y.id === x.id; }); }));
        m.script('runQuery', [{ success: false, error: 'no such function' }]);
        return m.host.findCharts({ space: null });
      }).then(function (r) {
        ok('home: the counted query failing falls back to the plain one', r.ok && r.counted === false && r.charts[0].tasks === null);
        ok('home: the fallback SQL has no count', !/AS tasks/.test(m.queries[3]));
        ok('home: without a Space every chart shows', r.charts.some(function (x) { return x.id === 'other'; }) && /AND 1=1 ORDER BY/.test(m.queries[3]));
        m.script('runQuery', [{ success: false, error: 'a' }, { success: false, error: 'b' }]);
        return m.host.findCharts({});
      }).then(function (r) { ok('home: both failing is a failure', !r.ok && r.charts.length === 0); });
    });

    acase('7.7 chooser', function () {
      var c = chart([{ id: 't1', note: 'task-1', title: 'A' }]);
      var notes = [
        { id: 'c1', content: chartText('', c), updatedAt: 10, tags: ['work'] },
        { id: 'c2', content: '[x](synapseresource://note/task-1?via=gantt)\n\n' + chartText('', chart([{ id: 't9', note: 'task-9', title: 'Z' }])), updatedAt: 20, tags: ['work'] },
        { id: 'c3', content: chartText('', c), updatedAt: 30, tags: ['home'] },
        { id: 'c4', content: '```synapse-gantt\n{\n  "v": 1,\n  "tasks": [ { "note" : "task-1" } ]\n}\n```', updatedAt: 40, tags: ['work'] },
        { id: 'task-1', content: 'the task', tags: ['work'] }
      ];
      for (var k = 0; k < 12; k++) notes.push({ id: nid(k), content: chartText('', c), updatedAt: 100 + k, tags: ['work'] });
      var m = mk(notes, { space: { id: 's', name: 'W', tags: ['work'] } });
      return m.host.chartsReferencing('task-1').then(function (r) {
        ok('chooser: ok, at most 10', r.ok && r.charts.length === 10);
        ok('chooser: newest first', r.charts[0].id === nid(11));
        ok('chooser: SQL LIMIT 10', / LIMIT 10$/.test(m.queries[0]));
        m.db.notes[nid(0)].isArchived = 1;
        for (var k = 1; k < 12; k++) m.db.notes[nid(k)].isArchived = 1;
        return m.host.chartsReferencing('task-1');
      }).then(function (r) {
        var got = r.charts.map(function (x) { return x.id; }).join(',');
        eq('chooser: hand-spaced JSON found, a mirror link above the fence does not count, other Space left out', got, 'c4,c1');
        return m.host.chartsReferencing('bad id');
      }).then(function (r) { ok('chooser: an invalid id is no charts, no query', r.ok && r.charts.length === 0 && m.queries.length === 2); });
    });

    /* ------------------------------------------------------ appState */

    acase('appState: loadState reads data, whole-blob store, persistence', function () {
      var storage = new Map();
      var m = mk([], { storage: storage, appId: 'app-A' });
      return m.host.loadState().then(function (r) {
        ok('loadState: nothing stored is {}', r.ok && A.canon(r.data) === '{}');
        return m.host.storeState({ a: 1, journal: { c: { at: 1 } } });
      }).then(function (r) {
        ok('storeState: ok', r.ok);
        ok('storeState: persisted under gt-mock-appstate:<appId>', storage.has('gt-mock-appstate:app-A'));
        return m.synapse.loadAppState();
      }).then(function (raw) {
        ok('mock: loadAppState answers {success, data}', raw.success === true && raw.data && raw.data.a === 1 && !('state' in raw));
        return m.host.storeState({ b: 2 });
      }).then(function () { return m.host.loadState(); }).then(function (r) {
        same('storeAppState replaces the whole blob', r.data, { b: 2 });
        var again = mk([], { storage: storage, appId: 'app-A', db: m.db });
        var other = mk([], { storage: storage, appId: 'app-B', db: m.db });
        return Promise.all([again.host.loadState(), other.host.loadState()]);
      }).then(function (rs) {
        same('a second mock with the same storage and app id sees it', rs[0].data, { b: 2 });
        same('another app id has its own blob', rs[1].data, {});
        m.failLoads(2);
        return Promise.all([m.host.loadState(), m.host.loadState(), m.host.loadState()]);
      }).then(function (rs) {
        ok('failLoads(2) fails the next two loads', !rs[0].ok && !rs[1].ok && rs[2].ok);
        m.failStores(1);
        return m.host.storeState({ c: 3 });
      }).then(function (r) {
        ok('failStores(1) fails a store and changes nothing', !r.ok && m.state().b === 2);
        eq('call counter: loadAppState', m.count('loadAppState'), 6);
        eq('call counter: storeAppState', m.count('storeAppState'), 3);
      });
    });

    acase('appState: a host whose loadAppState returns a legacy {state} shape reads nothing', function () {
      var h = H.create({ loadAppState: function () { return Promise.resolve({ success: true, state: { a: 1 } }); } });
      return h.loadState().then(function (r) { same('loadState reads r.data only', r.data, {}); });
    });

    /* -------------------------------------------------------- writes */

    function setup(o) {
      var c = chart([{ id: 't1', note: 'task-1', title: 'A', start: '2026-10-01', end: '2026-10-05' }]);
      var text = chartText('Intro text.', c);
      var m = mk([{ id: 'chart-1', title: 'Chart', content: text }, { id: 'task-1', title: 'A', type: 'task' }, { id: 'task-2', title: 'B', type: 'task' }], o);
      return { m: m, h: m.host, c: c, region: regionOf(c), text: text };
    }
    function nextRegion(c) { return regionOf(M.moveTask(c, 't1', 2).chart); }

    acase('saveRegion: one updateNotes array, replace_text, dates', function () {
      var s = setup(), next = nextRegion(s.c);
      var dates = [{ id: 'task-1', scheduledAt: '2026-10-03', completeBy: '2026-10-07' }];
      return s.h.saveRegion('chart-1', s.region, next, dates).then(function (r) {
        ok('saveRegion: ok', r.ok && !r.denied && r.failedDates.length === 0);
        eq('saveRegion: one updateNotes call', s.m.count('updateNotes'), 1);
        var list = s.m.updates[0];
        same('saveRegion: the chart entry first, as replace_text with no section', list[0], { id: 'chart-1', modification: { content: { action: 'replace_text', old_text: s.region, new_text: next } } });
        same('saveRegion: the date entry in the same array, dates only', list[1], { id: 'task-1', scheduledAt: '2026-10-03', completeBy: '2026-10-07' });
        eq('saveRegion: the note holds the new region, intro untouched', s.m.content('chart-1'), 'Intro text.\n\n' + next);
        ok('saveRegion: the task note got its dates', s.m.note('task-1').scheduledAt === '2026-10-03' && s.m.note('task-1').completeBy === '2026-10-07');
        ok('saveRegion: roundTripMs recorded', typeof r.roundTripMs === 'number' && s.h.lastRoundTripMs === r.roundTripMs);
        noWholeReplace('saveRegion', s.m);
        return s.h.saveRegion('chart-1', s.region, next, []);
      }).then(function (r) {
        // The host's retry path needs sharedAffix(old, new) * 2 >= new.length.
        // A date move edits the mirror line and the JSON line far apart, so
        // on this small chart the overlap is short: the retry is refused and
        // changes nothing (saveOnce re-reads and merges instead).
        ok('saveRegion: a low-overlap retry is refused and changes nothing', !r.ok && s.m.content('chart-1') === 'Intro text.\n\n' + next);
        return s.h.saveRegion('chart-1', 'not in the note', next, []);
      }).then(function (r) {
        ok('saveRegion: a missing region fails', !r.ok && !r.denied);
        eq('saveRegion: its error is the redacted host text', r.error, 'Updating note chart-1 failed. See the app log for details.');
        eq('saveRegion: updatedCount 0', r.updatedCount, 0);
        // One edit in one place (mirror off): the retry is the host's no-op.
        var c2 = chart([{ id: 't1', note: 'task-1', title: 'A', start: '2026-10-01', end: '2026-10-05' }, { id: 't2', note: 'task-2', title: 'B', start: '2026-10-02' }], { mirror: false });
        var r1 = regionOf(c2), r2 = regionOf(M.moveTask(c2, 't1', 2).chart);
        s.m.setNote('chart-1', 'Intro.\n\n' + r1);
        return s.h.saveRegion('chart-1', r1, r2, []).then(function (a) {
          ok('(setup) first write', a.ok);
          return s.h.saveRegion('chart-1', r1, r2, []);
        });
      }).then(function (r) {
        ok("saveRegion: a high-overlap retry is the host's no-op success", r.ok && s.m.content('chart-1').indexOf('"start":"2026-10-03"') > 0);
      });
    });

    acase('saveRegion: region twice, a failing date entry, a body edit', function () {
      var s = setup(), next = nextRegion(s.c);
      s.m.setNote('chart-1', s.text + '\n\n' + s.region);
      return s.h.saveRegion('chart-1', s.region, next, []).then(function (r) {
        ok('saveRegion: old text matching twice fails (N matches)', !r.ok && s.m.content('chart-1') === s.text + '\n\n' + s.region);
        s.m.setNote('chart-1', s.text);
        s.m.refuse('task-2');
        s.m.outsideEdit(function (mm) { mm.setNote('chart-1', 'Edited above.\n\n' + mm.content('chart-1') + '\n\nEdited below.'); });
        return s.h.saveRegion('chart-1', s.region, next, [{ id: 'task-2', scheduledAt: '2026-10-03', completeBy: '2026-10-03' }, { id: 'task-gone', scheduledAt: '2026-10-03', completeBy: '2026-10-03' }]);
      }).then(function (r) {
        ok('saveRegion: the chart saved although date entries failed', r.ok);
        same('saveRegion: failedDates names both', r.failedDates.map(function (d) { return d.id; }), ['task-2', 'task-gone']);
        eq('saveRegion: a body edit made between read and write survives', s.m.content('chart-1'), 'Edited above.\n\nIntro text.\n\n' + next + '\n\nEdited below.');
        noWholeReplace('saveRegion 2', s.m);
      });
    });

    acase('saveRegion: an outside edit of the region between read and write', function () {
      var s = setup(), next = nextRegion(s.c);
      return s.h.readNote('chart-1').then(function (r0) {
        ok('(setup) read', r0.ok);
        s.m.outsideEdit(function (mm) { mm.setNote('chart-1', 'Intro text.\n\n' + regionOf(M.moveTask(s.c, 't1', 5).chart)); });
        return s.h.saveRegion('chart-1', B.read(r0.content).region.text, next, []);
      }).then(function (r) {
        ok('saveRegion: the stale region misses, nothing overwritten', !r.ok && s.m.content('chart-1').indexOf('2026-10-06') > 0);
        return s.h.readNote('chart-1');
      }).then(function (r) { ok('the re-read sees their block', r.ok && B.read(r.content).chart.tasks[0].start === GT.dates.parse('2026-10-06')); });
    });

    acase('saveRegion: approval dialog, denial, hidden denial, latency', function () {
      var s = setup({ approve: 'once', approvalMs: 60 }), next = nextRegion(s.c);
      return s.h.seedBaseline().then(function (b) {
        ok('seedBaseline runs SELECT 1', b.ok && s.m.queries[0] === 'SELECT 1' && s.h.baselineMs !== null);
        return s.h.saveRegion('chart-1', s.region, next, []);
      }).then(function (r) {
        ok('approval: a slow dialog shows in the round trip', r.ok && r.roundTripMs >= 50);
        ok('approval: baselineMs stays the fastest round trip', s.h.baselineMs < 50);
        eq('approval: one dialog', s.m.dialogs, 1);
        s.m.approvals.push('deny');
        return s.h.saveRegion('chart-1', next, s.region, []);
      }).then(function (r) {
        ok('denial: denied, nothing written', !r.ok && r.denied && s.m.content('chart-1').indexOf(next) > 0);
        eq('denial: a dialog per call without the session tick', s.m.dialogs, 2);
        s.m.unmounted = true;
        return s.h.saveRegion('chart-1', next, s.region, []);
      }).then(function (r) {
        ok('hidden denial: an unmounted view answers the same denial at once', r.denied && r.roundTripMs < 50);
        s.m.unmounted = false;
        s.m.approvals.push('session');
        return s.h.saveRegion('chart-1', next, s.region, []);
      }).then(function (r) {
        ok('session approval: ok', r.ok && s.m.sessionApproved);
        return s.h.saveRegion('chart-1', s.region, next, []);
      }).then(function (r) {
        ok('session approval: no dialog and fast afterwards', r.ok && s.m.dialogs === 4 && r.roundTripMs < 50);
        noWholeReplace('approval', s.m);
      });
    });

    acase('latency option delays a named bridge call', function () {
      var m = mk([{ id: 'a', content: 'x' }], { latency: { loadAppState: 80 } });
      var t0 = Date.now();
      return m.host.loadState().then(function () {
        ok('latency: loadAppState waited', Date.now() - t0 >= 70);
        var t1 = Date.now();
        return m.host.readNote('a').then(function () { ok('latency: other calls are not delayed', Date.now() - t1 < 60); });
      }).then(function () {
        m.latency = function (name) { return name === 'runQuery' ? 40 : 0; };
        return m.host.seedBaseline();
      }).then(function (b) { ok('latency: a function works and read-only queries are timed', b.ms >= 30 && b.baselineMs <= b.ms); });
    });

    acase('replaceText, appendContent, rename, setTaskFields', function () {
      var m = mk([{ id: 'n1', title: 'Old', content: '## Checklist\n- [ ] a\n## Other\n- [ ] a', type: 'task', status: 'todo', scheduledAt: '2026-01-01' }]);
      var h = m.host;
      return h.replaceText('n1', '- [ ] a', '- [x] a', '## Other').then(function (r) {
        ok('replaceText: section-scoped edit', r.ok && m.content('n1') === '## Checklist\n- [ ] a\n## Other\n- [x] a');
        same('replaceText: the entry', m.updates[0][0], { id: 'n1', modification: { content: { action: 'replace_text', old_text: '- [ ] a', new_text: '- [x] a', section: '## Other' } } });
        return h.replaceText('n1', '- [ ] a', '- [x] a');
      }).then(function (r) {
        ok('replaceText: without a section the whole note has one match left', r.ok && m.content('n1') === '## Checklist\n- [x] a\n## Other\n- [x] a' && !('section' in m.updates[1][0].modification.content));
        return h.replaceText('n1', '- [ ] zz', '- [x] zz', '## Missing');
      }).then(function (r) {
        ok('replaceText: a missing section is a redacted failure', !r.ok && /^Updating note n1 failed/.test(r.error));
        return h.appendContent('n1', 'tail');
      }).then(function (r) {
        ok('appendContent: content + "\\n" + text', r.ok && m.content('n1') === '## Checklist\n- [x] a\n## Other\n- [x] a\ntail');
        return h.appendContent('n1', '');
      }).then(function (r) {
        ok('appendContent: an empty append is refused before the bridge', !r.ok && m.count('updateNotes') === 4);
        return h.rename('n1', 'New title');
      }).then(function (r) {
        ok('rename: title modification', r.ok && m.note('n1').title === 'New title');
        same('rename: entry', m.updates[4][0], { id: 'n1', modification: { title: { new_title: 'New title' } } });
        return h.setTaskFields('n1', { status: 'complete', scheduledAt: '2026-02-02', content: 'NOPE' });
      }).then(function (r) {
        ok('setTaskFields: only the task fields are sent', r.ok && A.canon(m.updates[5][0]) === A.canon({ id: 'n1', status: 'complete', scheduledAt: '2026-02-02' }));
        ok('setTaskFields: the note changed only there', m.note('n1').status === 'complete' && m.note('n1').scheduledAt === '2026-02-02' && m.note('n1').completeBy === null && m.content('n1').indexOf('NOPE') < 0);
        return h.setTaskFields('n1', { status: 'completed' });
      }).then(function (r) {
        ok("setTaskFields: a status the host would read as 'todo' is refused", !r.ok && m.count('updateNotes') === 6);
        noWholeReplace('note writes', m);
        // The mock's full-replacement path parses statuses like the host.
        return m.synapse.updateNotes([{ id: 'n1', status: 'Done' }]);
      }).then(function () { eq("mock: an unknown status becomes 'todo' (bridge 3490-3500)", m.note('n1').status, 'todo'); });
    });

    acase('mock: replace_text 0 / 1 / N / idempotent through updateNotes', function () {
      var m = mk([{ id: 'n', content: 'a b a\n- [ ] item' }]);
      function up(o, n2) { return m.synapse.updateNotes([{ id: 'n', modification: { content: { action: 'replace_text', old_text: o, new_text: n2 } } }]); }
      return up('a', 'c').then(function (r) {
        ok('N matches: updatedCount 0 and a redacted error', r.success === true && r.updatedCount === 0 && r.errors[0] === 'Updating note n failed. See the app log for details.' && r.error === r.errors[0]);
        return up('- [ ] item', '- [x] item');
      }).then(function (r) {
        ok('1 match: applied', r.updatedCount === 1 && !r.errors && m.content('n') === 'a b a\n- [x] item');
        return up('- [ ] item', '- [x] item');
      }).then(function (r) {
        ok('idempotent retry: success, unchanged', r.updatedCount === 1 && !r.errors && m.content('n') === 'a b a\n- [x] item');
        return up('zzz', 'yyy');
      }).then(function (r) {
        ok('0 matches: updatedCount 0', r.updatedCount === 0 && r.errors.length === 1);
        return m.synapse.updateNotes([{ id: 'n', modification: { content: { old_text: ' b ', new_text: ' B ' } } }]);
      }).then(function (r) {
        ok('the action may be omitted with old_text and new_text', r.updatedCount === 1 && m.content('n') === 'a B a\n- [x] item');
        return m.synapse.updateNotes([{ id: 'gone', modification: { content: { action: 'append', text: 'x' } } }, {}]);
      }).then(function (r) {
        same('an absent note and an entry without id', r.errors, ['Note not found: gone', 'An update was skipped because it had no note id.']);
        return m.synapse.updateNotes([{ id: 'n', modification: { tags: { added: ['x'] }, unknown: 1 } }, { id: 'n', modification: { nothing: 1 } }]);
      }).then(function (r) { eq('recognised or not, a modification counts', r.updatedCount, 2); });
    });

    acase('createNote: saveNotes one note per call, trims, savedNoteIds', function () {
      var m = mk([], { space: { id: 's', name: 'W', tags: ['work'] } });
      return m.host.createNote({ title: '  Task  ', content: '\n\n## Checklist\n- [ ] a\n\n', type: 'task', status: 'todo', scheduledAt: '2026-10-01', completeBy: '2026-10-05', subNotes: [{ name: 'one', content: '' }, { name: 'two' }], id: 'ignored' }).then(function (r) {
        ok('createNote: ok with the new id', r.ok && !!m.note(r.id));
        eq('createNote: one saveNotes call with one note', m.saves.length + ':' + m.saves[0].length, '1:1');
        var n = m.note(r.id);
        eq('createNote: buildNote trims the content', n.content, '## Checklist\n- [ ] a');
        ok('createNote: title trimmed, task fields kept', n.title === 'Task' && n.type === 'task' && n.scheduledAt === '2026-10-01' && n.completeBy === '2026-10-05');
        eq('createNote: the Space tags are stamped', n.tags.join(','), 'work');
        ok('createNote: no id is sent', !('id' in m.saves[0][0]));
        return m.host.subnoteCounts([r.id]);
      }).then(function (r) {
        eq('createNote: subNotes become subnote rows', A.canon(r.counts[Object.keys(r.counts)[0]]), A.canon({ done: 0, total: 2, bits: '00' }));
        m.script('saveNotes', [{ success: true, savedCount: 0, savedNoteIds: [] }]);
        return m.host.createNote({ title: 'x' });
      }).then(function (r) {
        ok('createNote: an empty savedNoteIds is a failure', !r.ok);
        return m.synapse.saveNotes([{ title: 'a' }, 'junk', { title: 'b' }]);
      }).then(function (r) { ok('mock saveNotes: skipped entries shorten savedNoteIds', r.savedCount === 2 && r.savedNoteIds.length === 2); });
    });

    acase('setSubnoteDone: SQL UPDATE with its own approval', function () {
      var m = mk([{ id: 'p', type: 'task' }], { sqlApprove: 'once' });
      m.addSubnote('p', { id: 'sA', isCompleted: 0, createdAt: 1 });
      m.addSubnote('p', { id: 'sB', isCompleted: 0, createdAt: 2 });
      return m.host.setSubnoteDone('p', 'sB', true).then(function (r) {
        ok('subnote: ok', r.ok);
        eq('subnote: SQL', m.queries[0], "UPDATE subnotes SET isCompleted = 1 WHERE id = 'sB' AND noteId = 'p'");
        eq('subnote: a SQL dialog, not an updateNotes one', m.sqlDialogs + ':' + m.dialogs + ':' + m.count('updateNotes'), '1:0:0');
        return m.host.subnoteCounts(['p']);
      }).then(function (r) {
        same('subnote: counts follow', r.counts.p, { done: 1, total: 2, bits: '01' });
        m.sqlApprovals.push('deny');
        return m.host.setSubnoteDone('p', 'sA', true);
      }).then(function (r) {
        ok('subnote: a denied SQL write', !r.ok && r.denied && r.error === H.SQL_DENIED);
        eq('subnote: the denial changed nothing', m.db.subnotes[0].isCompleted, 0);
        return m.host.setSubnoteDone('p', "x' --", true);
      }).then(function (r) { ok('subnote: an invalid id never reaches SQL', !r.ok && m.queries.length === 3); });
    });

    acase('pickNotes and openNote', function () {
      var m = mk([{ id: 'a', title: 'A' }, { id: 'b', title: 'B' }]);
      m.pickAnswer = ['a', 'gone', 'b'];
      return m.host.pickNotes({ multiSelect: true, title: 'Add', preselectedIds: ['a'] }).then(function (r) {
        ok('pick: references only', r.ok && !r.cancelled && A.canon(r.notes) === A.canon([{ id: 'a', title: 'A' }, { id: 'b', title: 'B' }]));
        same('pick: options passed through', m.picks[0], { multiSelect: true, title: 'Add', preselectedIds: ['a'] });
        m.pickAnswer = null;
        return m.host.pickNotes({});
      }).then(function (r) {
        ok('pick: cancel', r.ok && r.cancelled && r.notes.length === 0);
        m.pickAnswer = 'no_ui';
        return m.host.pickNotes();
      }).then(function (r) {
        ok('pick: no_ui', !r.ok && r.reason === 'no_ui');
        return m.host.openNote('a', false);
      }).then(function (r) {
        ok('openNote: ok', r.ok && m.opened[0].id === 'a' && m.opened[0].replaceWindow === false);
        return m.host.openNote('gone');
      }).then(function (r) { ok('openNote: an absent note', !r.ok); });
    });

    acase('every host call resolves {ok} and never throws', function () {
      var h = H.create(null);
      var thrower = H.create({ runQuery: function () { throw new Error('boom'); }, updateNotes: function () { return Promise.reject(new Error('nope')); } });
      return Promise.all([
        h.query('SELECT 1'), h.meta(['a']), h.readNote('a'), h.saveRegion('a', 'x', 'y', []), h.loadState(), h.storeState({}),
        h.pickNotes(), h.openNote('a'), h.createNote({}), h.findCharts({}), thrower.readNote('a'), thrower.saveRegion('a', 'x', 'y'),
        h.saveRegion(null, 'x', 'y'), h.saveRegion('a', '', 'y'), h.replaceText('a', '', 'x'), h.setTaskFields('a', {})
      ]).then(function (rs) {
        ok('no host: every call is {ok:false}', rs.every(function (r) { return r && r.ok === false; }), JSON.stringify(rs.map(function (r) { return r && r.ok; })));
      });
    });

    /* ------------------------------------------------ crash hooks */

    acase('haltAfter("beforeUpdateNotes") during the approval dialog', function () {
      var s = setup({ approvalMs: 40 }), next = nextRegion(s.c);
      var p = s.h.saveRegion('chart-1', s.region, next, []);
      return sleep(10).then(function () {
        s.m.haltAfter('beforeUpdateNotes');
        return within(p, 80);
      }).then(function (w) {
        ok('halt before: the save never resolves', !w.settled);
        eq('halt before: the note is unchanged', s.m.content('chart-1'), s.text);
        return within(s.h.loadState(), 30);
      }).then(function (w) { ok('halt before: every later call hangs', !w.settled && s.m.halted); });
    });

    acase('haltAfter("beforeUpdateNotes") arms for the next call', function () {
      var s = setup();
      s.m.haltAfter('beforeUpdateNotes');
      return s.h.readNote('chart-1').then(function (r) {
        ok('armed: calls before the write still answer', r.ok && !s.m.halted);
        return within(s.h.saveRegion('chart-1', s.region, nextRegion(s.c), []), 30);
      }).then(function (w) { ok('armed: the next write never applies', !w.settled && s.m.content('chart-1') === s.text && s.m.halted); });
    });

    acase('haltAfter("updateNotes")', function () {
      var s = setup(), next = nextRegion(s.c);
      s.m.haltAfter('updateNotes');
      return within(s.h.saveRegion('chart-1', s.region, next, []), 30).then(function (w) {
        ok('halt after: the write applied', s.m.content('chart-1') === 'Intro text.\n\n' + next);
        ok('halt after: its answer never arrives', !w.settled);
        return within(s.h.readNote('chart-1'), 30);
      }).then(function (w) { ok('halt after: later calls hang', !w.settled); });
    });

    acase('holdUpdateNotes / release("apply") / release()', function () {
      var s = setup({ sessionApproved: true }), next = nextRegion(s.c), done = false;
      s.m.holdUpdateNotes();
      var p = s.h.saveRegion('chart-1', s.region, next, []).then(function (r) { done = true; return r; });
      return sleep(5).then(function () {
        eq('hold: parked', s.m.parked(), 1);
        ok('hold: not applied while parked', s.m.content('chart-1') === s.text && !done);
        s.m.setNote('chart-1', 'Body edit.\n\n' + s.text);
        return s.m.release('apply');
      }).then(function () {
        ok("release('apply'): applied over the body edit", s.m.content('chart-1') === 'Body edit.\n\nIntro text.\n\n' + next);
        return sleep(5);
      }).then(function () {
        ok("release('apply'): the answer stays parked", !done);
        return s.m.release();
      }).then(function () { return p; }).then(function (r) {
        ok('release(): the answer arrives', done && r.ok);
        eq('release(): nothing parked', s.m.parked(), 0);
        s.m.holdUpdateNotes();
        var p2 = s.h.saveRegion('chart-1', next, s.region, []);
        return sleep(5).then(function () { return s.m.release(); }).then(function () { return p2; });
      }).then(function (r) { ok('release() without apply applies and answers', r.ok && s.m.content('chart-1').indexOf(s.region) > 0); });
    });

    acase('hold + haltAfter("updateNotes") + release(): applies, then dies (walkthrough e)', function () {
      var s = setup({ sessionApproved: true }), next = nextRegion(s.c);
      s.m.holdUpdateNotes();
      var p = s.h.saveRegion('chart-1', s.region, next, []);
      return sleep(5).then(function () {
        s.m.haltAfter('updateNotes');
        return s.m.release();
      }).then(function () {
        ok('e: the write applied', s.m.content('chart-1') === 'Intro text.\n\n' + next);
        return within(p, 30);
      }).then(function (w) { ok('e: no answer', !w.settled && s.m.halted); });
    });

    acase('hold + haltAfter("beforeUpdateNotes"): a parked write never applies', function () {
      var s = setup({ sessionApproved: true });
      s.m.holdUpdateNotes();
      var p = s.h.saveRegion('chart-1', s.region, nextRegion(s.c), []);
      return sleep(5).then(function () {
        s.m.haltAfter('beforeUpdateNotes');
        return within(p, 30);
      }).then(function (w) { ok('parked kill: not applied, no answer', !w.settled && s.m.content('chart-1') === s.text && s.m.parked() === 0); });
    });

    /* ------------------------------------------------- resume wiring */

    acase('onResume: triggers, coalescing, pointer after openNote, interval', function () {
      var t = 0;
      var m = mk([{ id: 'a' }], { now: function () { return t; } });
      var h = m.host, got = [];
      var off = h.onResume(function (why) { got.push(why); });
      m.dispatch('focus');
      m.dispatch('pageshow');
      eq('resume: two triggers inside 250 ms fire once', got.join(','), 'focus');
      t = 300; m.dispatch('pageshow');
      t = 600; m.setVisible(false);
      t = 900; m.setVisible(true);
      eq('resume: pageshow, then visible (hidden does not fire)', got.join(','), 'focus,pageshow,visible');
      t = 1200; m.dispatch('pointerdown');
      eq('resume: a pointerdown without openNote does nothing', got.length, 3);
      return h.openNote('a').then(function () {
        t = 1500; m.dispatch('pointerdown');
        t = 1800; m.dispatch('pointerdown');
        eq('resume: the first pointerdown after openNote fires once', got.join(','), 'focus,pageshow,visible,pointer');
        t = 2100; m.tickInterval();
        eq('resume: the 30 s interval fires while visible', got[got.length - 1], 'interval');
        m.setVisible(false);
        t = 2400; m.tickInterval();
        eq('resume: not while hidden', got.length, 5);
        m.setVisible(true);
        eq('resume: becoming visible fires', got[got.length - 1], 'visible');
        t = 2410;
        return m.resume();
      }).then(function () {
        eq('mock.resume() fires the callbacks, bypassing coalescing', got[got.length - 1], 'mock');
        off();
        var n = got.length;
        t = 5000; m.dispatch('focus');
        eq('resume: off() unwires', got.length, n);
        eq('resume: listeners removed', m.win.count('focus') + m.doc.count('visibilitychange'), 0);
      });
    });

    acase('on(): synapse events', function () {
      var m = mk([], { locale: 'en-US' }), h = m.host, seen = [];
      var off = h.on('localechanged', function (d) { seen.push('L:' + d); });
      h.on('spacechanged', function (d) { seen.push('S:' + (d ? d.name : 'none')); });
      h.on('themechanged', function (d) { seen.push('T:' + d); });
      ok('on: an unknown event name is refused', typeof h.on('nope', function () {}) === 'function' && m.win.count('synapse:nope') === 0);
      m.emit('localechanged', 'zh-CN');
      eq('on: locale() is updated before the event', h.locale(), 'zh-CN');
      m.emit('spacechanged', { id: 's', name: 'Work', tags: ['work'] });
      eq('on: space() follows', h.space().name, 'Work');
      m.emit('spacechanged', null);
      m.emit('themechanged', 'dark');
      eq('on: theme() follows (M10)', h.theme(), 'dark');
      off();
      m.emit('localechanged', 'en-US');
      eq('on: events in order, off() works', seen.join('|'), 'L:zh-CN|S:Work|S:none|T:dark');
      return Promise.resolve();
    });

    /* ------------------------------------------------- two instances */

    acase('two mock instances share notes and storage, not approval or halts', function () {
      var storage = new Map();
      var s = setup({ storage: storage, sessionApproved: true });
      var y = mk(null, { db: s.m.db, storage: storage, appId: s.m.appId, Params: { mode: 'embed' } });
      var next = nextRegion(s.c);
      return y.host.readNote('chart-1').then(function (r) {
        ok('two: B reads A\'s notes', r.ok && r.content === s.text);
        return s.h.saveRegion('chart-1', s.region, next, []);
      }).then(function () { return y.host.readNote('chart-1'); }).then(function (r) {
        ok('two: A\'s write is visible to B', r.content === 'Intro text.\n\n' + next);
        return s.h.storeState({ journal: { 'chart-1': { at: 1 } } });
      }).then(function () { return y.host.loadState(); }).then(function (r) {
        ok('two: B loads A\'s appState', r.data.journal['chart-1'].at === 1);
        ok('two: approval is per instance (per launch)', s.m.sessionApproved && !y.sessionApproved);
        eq('two: the embed instance made no storeAppState call', y.count('storeAppState'), 0);
        y.haltAfter('beforeUpdateNotes');
        y.halt();
        return s.h.readNote('chart-1');
      }).then(function (r) {
        ok('two: halting B leaves A working', r.ok);
        return within(y.host.readNote('chart-1'), 30);
      }).then(function (w) { ok('two: B hangs', !w.settled); });
    });

    acase('call counter and event log', function () {
      var m = mk([{ id: 'a', content: 'x' }], { sessionApproved: true });
      return m.host.loadState().then(function () { return m.host.storeState({ a: 1 }); }).then(function () {
        return m.host.saveRegion('a', 'x', 'y', []);
      }).then(function () {
        same('counter: per bridge method', m.calls, { loadAppState: 1, storeAppState: 1, updateNotes: 1 });
        var order = m.events.map(function (e) { return e.method + ':' + e.phase; }).join(',');
        eq('event log: call, apply and resolve in order', order, 'loadAppState:call,loadAppState:resolve,storeAppState:call,storeAppState:resolve,updateNotes:call,updateNotes:apply,updateNotes:resolve');
        m.resetCounts();
        same('resetCounts', m.calls, {});
      });
    });

    acase('outsideEdit beforeRead and setNote', function () {
      var m = mk([{ id: 'a', content: 'one' }]);
      var u0 = m.note('a').updatedAt;
      m.outsideEdit(function (mm) { mm.setNote('a', 'two'); }, 'beforeRead');
      return m.host.readNote('a').then(function (r) {
        ok('outsideEdit beforeRead: the read sees it', r.content === 'two');
        ok('setNote bumps updatedAt', m.note('a').updatedAt > u0);
        return m.host.readNote('a');
      }).then(function (r) { ok('outsideEdit runs once', r.content === 'two'); });
    });
  }

  /* Review round 1 (M3a). */
  function reviewSpec() {
    var F = '```synapse-gantt';
    function chartC() { return M.coerce({ v: 1, tasks: [{ id: 't1', note: 'n1', title: 'A' }] }).chart; }
    var chartContent = 'Intro\n\n' + B.region(chartC(), null, {});

    // R1: null task dates keep the old value on the host (note.dart copyWith `??`).
    acase('r1: null dates are never sent, and the mock keeps the old value on null', function () {
      var m = H.installMock([{ id: 'c', content: 'x' }, { id: 'k', type: 'task', scheduledAt: '2026-01-01', completeBy: '2026-01-02' }], { storage: new Map(), global: false });
      return m.host.setTaskFields('k', { scheduledAt: null }).then(function (r) {
        ok('r1: setTaskFields refuses a null date (nothing else to write)', !r.ok && m.count('updateNotes') === 0);
        return m.host.saveRegion('c', 'x', 'y', [{ id: 'k', scheduledAt: null, completeBy: '2026-03-03' }, { id: 'k2', scheduledAt: null }]);
      }).then(function (r) {
        var list = m.updates[0];
        ok('r1: a null date is dropped from the entry', r.ok && list.length === 2 && !('scheduledAt' in list[1]) && list[1].completeBy === '2026-03-03');
        return m.synapse.updateNotes([{ id: 'k', scheduledAt: null }]);
      }).then(function () {
        eq('r1: the mock keeps the old value on null, like _mergeNoteData', m.note('k').scheduledAt, '2026-01-01');
      });
    });

    // R2: a block-scoped launch is routed after reading the parent.
    var sel = function (content) { return { notes: [{ id: 'parent-1', blockScope: true, transientId: 'blk', title: 'P', content: content }], params: {} }; };
    var rp = H.route(sel('just a paragraph of the chart note'));
    ok("r2: a block-scoped launch on a non-fence block is 'resolve', not 'chooser'", rp.kind === 'resolve' && rp.noteId === 'parent-1' && rp.needsRead === true);
    eq("r2: a block-scoped launch on the fence is 'resolve' too", H.route(sel(F + '\n{"v":1}\n```')).kind, 'resolve');
    eq('r2: a whole-note launch is unchanged', H.route({ notes: [{ id: 'c1', content: chartContent }], params: {} }).kind, 'chart');
    eq('r2: a block-scoped embed stays an embed', H.route({ notes: [{ id: 'parent-1', blockScope: true, content: 'x' }], params: { mode: 'embed' } }).kind, 'embed');

    // R3: the embed route hands over the read like the chart route.
    var re = H.route({ notes: [{ id: 'c1', content: chartContent }], params: { mode: 'embed' } });
    ok('r3: embed of Notes[0] carries its block.read', re.needsRead === false && re.read && re.read.status === 'ok');
    var re2 = H.route({ notes: [{ id: 'c1', content: chartContent }], params: { mode: 'embed', chart: 'c9' } });
    ok('r3: embed of another chart needs a read and carries none', re2.needsRead === true && !re2.read);

    // R4: SQLite substr stops at U+0000, like length().
    eq('r4: sqlite substr stops at NUL', H.sqlite.substr('ab\u0000cd', 1, 10), 'ab');
    eq('r4: sqlite instr still sees past NUL', H.sqlite.instr('ab\u0000cd', 'c'), 4);
    acase('r4: a paged read of a NUL note completes at the NUL', function () {
      var m = H.installMock([{ id: 'z', content: 'hello\u0000world' }], { storage: new Map(), global: false });
      return m.host.readPaged('z', 1).then(function (r) {
        ok('r4: paged read of a NUL note', r.ok && r.complete && r.text === 'hello' && r.clen === 5);
      });
    });

    // N1: synchronous context calls never throw.
    var evil = {};
    Object.defineProperty(evil, 'Notes', { get: function () { throw new Error('boom'); } });
    Object.defineProperty(evil, 'locale', { get: function () { throw new Error('boom'); } });
    Object.defineProperty(evil, 'space', { get: function () { throw new Error('boom'); } });
    Object.defineProperty(evil, 'theme', { get: function () { throw new Error('boom'); } });
    var he = H.create(evil);
    var l = null, threw = false;
    try { l = he.launch(); he.locale(); he.space(); he.theme(); H.route(null); H.route({ notes: [null], params: null }); } catch (e) { threw = String(e); }
    ok('n1: launch/locale/space/theme/route never throw', threw === false, threw);
    ok('n1: launch falls back to an empty launch', l && l.notes.length === 0 && l.locale === 'en-US' && l.space === null && l.theme === null);

    // N2: untested branches.
    acase('n2: a truncated chunk counts as failed; chartNamed; all-invalid picks', function () {
      var m = H.installMock([{ id: 'a' }, { id: 'c', content: 'x' }], { storage: new Map(), global: false });
      m.script('runQuery', [{ success: true, data: [{ id: 'a', title: 'A' }], truncated: true, totalRows: 150 }]);
      return m.host.meta(['a']).then(function (r) {
        ok('n2: a truncated meta chunk resolves nothing', !r.ok && r.failed[0] === 'a' && !r.rows.a && r.missing.length === 0);
        m.script('updateNotes', [{ success: true, updatedCount: 1, errors: ['Updating note c failed. See the app log for details.'] }]);
        return m.host.saveRegion('c', 'x', 'y', [{ id: 'a', scheduledAt: '2026-01-01' }]);
      }).then(function (r) {
        ok('n2: an error naming the chart fails the chart even when a date entry landed', !r.ok && r.failedDates.length === 1);
        m.pickAnswer = ['a'];
        m.script('pickNotes', [{ success: true, notes: [{ id: 'bad id', title: 'x' }, { title: 'no id' }] }]);
        return m.host.pickNotes({});
      }).then(function (r) { ok('n2: a pick with only invalid ids is a cancel', r.ok && r.cancelled && r.notes.length === 0); });
    });
  }
  SPEC.suites.push({ name: 'the host review spec', fn: reviewSpec });

  SPEC.suites.push({ name: 'the host spec', fn: hostSpec });
  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
