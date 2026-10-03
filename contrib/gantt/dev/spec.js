/*
 * Gantt assertions. Runs under node (`node dev/run.js`) and, from M3, in the
 * browser (dev/auto_smoke.html). Pure modules only here - no DOM.
 *
 * M1 covers dates, model (shape, coerce, transforms, applyPatch, merge3),
 * undo, block (scan, read, serialise, mirror, region, splice, key, hash), the
 * region fixtures and property test of plan §5.6, an i18n skeleton check and
 * the "only host.js touches Synapse" grep rule.
 *
 * M2 adds md (headings, checklists, toggleEdit checked against a port of the
 * host's replace_text, templates, links, needles) and the summarize /
 * classify truth tables.
 */
(function (global) {
  'use strict';
  var GT = global.GT;
  var D = GT.dates, M = GT.model, U = GT.undo, B = GT.block, I = GT.i18n, MD = GT.md;

  var results = [];
  function ok(name, cond, detail) { results.push({ name: name, pass: !!cond, detail: cond ? '' : (detail || '') }); }
  function eq(name, actual, expected) {
    var pass = actual === expected;
    ok(name, pass, pass ? '' : '\n--- expected ---\n' + show(expected) + '\n--- actual ---\n' + show(actual) + '\n---');
  }
  function show(x) { return typeof x === 'string' ? x : JSON.stringify(x); }
  function json(x) { return JSON.stringify(x); }
  // Key-order independent structural identity.
  function canon(x) {
    if (Array.isArray(x)) return '[' + x.map(canon).join(',') + ']';
    if (x && typeof x === 'object') {
      return '{' + Object.keys(x).sort().map(function (k) { return JSON.stringify(k) + ':' + canon(x[k]); }).join(',') + '}';
    }
    return JSON.stringify(x === undefined ? null : x);
  }
  function same(name, a, b) { eq(name, canon(a), canon(b)); }
  function freeze(x) {
    if (x && typeof x === 'object' && !Object.isFrozen(x)) {
      Object.freeze(x);
      Object.keys(x).forEach(function (k) { freeze(x[k]); });
    }
    return x;
  }

  var FIX = global.GT_FIXTURES || {};
  function fix(name) {
    if (!(name in FIX)) throw new Error('missing fixture ' + name);
    return FIX[name];
  }

  var asyncCases = [];
  function acase(name, fn) { asyncCases.push({ name: name, fn: fn }); }
  function runAsync() {
    var i = 0;
    function step() {
      if (i >= asyncCases.length) return Promise.resolve();
      var c = asyncCases[i++];
      var p;
      try { p = Promise.resolve(c.fn()); } catch (e) { ok(c.name, false, String((e && e.stack) || e)); return step(); }
      return p.then(function () { return step(); }, function (e) { ok(c.name, false, String((e && e.stack) || e)); return step(); });
    }
    return step();
  }

  var P = D.parse;

  // The §5.2 example chart, built from JSON data.
  var N1 = '8f0c1e2a-5b7d-4c11-9a0e-2f6b3c9d1e01', N2 = '1b7d4e90-0c2a-4f5e-8d61-7a3b2c1d0e02',
    N3 = '77aa3c21-9e4f-4b6d-a0c8-5d2e1f3a4b03', N4 = 'c3e98a10-6d5b-4e2f-b1a7-0c9d8e7f6a04';
  function exampleData() {
    return {
      v: 1,
      settings: { weekStart: 1, holidays: ['2026-12-25'], progressSource: 'checklist', progressSection: '## Checklist', progressStyle: 'segments' },
      groups: [{ id: 'g1', title: 'Discovery' }, { id: 'g2', title: 'Build', color: 'teal' }],
      tasks: [
        { id: 't1', note: N1, title: 'Customer interviews', start: '2026-10-01', end: '2026-10-09', group: 'g1' },
        { id: 't2', note: N2, title: 'Competitive teardown', start: '2026-10-05', end: '2026-10-14', group: 'g1', color: 'amber' },
        { id: 't3', note: N3, title: 'Sync engine', start: '2026-10-12', end: '2026-11-06', group: 'g2', after: ['t1'] },
        { id: 't4', note: N4, title: 'Beta cut', start: '2026-11-09', milestone: true, group: 'g2', after: ['t3'] }
      ]
    };
  }
  function example() { return M.coerce(exampleData()).chart; }
  var EX_SUMS = { t1: { done: 3, total: 5 }, t2: { done: 0, total: 4 }, t3: { done: 6, total: 10 } };

  function save(text, sums) {
    var r = B.read(text);
    return B.splice(text, B.region(r.chart, sums, { embedOutside: r.embedOutside }));
  }
  function count(hay, needle) { return hay.split(needle).length - 1; }

  /* ================================================================ dates */

  function withTZ(tz, fn) {
    var env = typeof process !== 'undefined' && process.env ? process.env : null;
    if (!env) return false;
    var old = env.TZ;
    env.TZ = tz;
    try { fn(); } finally { if (old === undefined) delete env.TZ; else env.TZ = old; }
    return true;
  }

  function datesSpec() {
    eq('1970-01-01 is day 0', P('1970-01-01'), 0);
    ['2026-03-08', '2026-11-01', '2028-02-29', '2026-10-01', '1999-12-31', '2100-02-28'].forEach(function (s) {
      eq('parse/format round-trips ' + s, D.format(P(s)), s);
    });
    eq('the day after the spring DST switch is one day later', P('2026-03-09') - P('2026-03-08'), 1);
    eq('the day before the spring DST switch is one day earlier', P('2026-03-08') - P('2026-03-07'), 1);
    eq('the day after the autumn DST switch is one day later', P('2026-11-02') - P('2026-11-01'), 1);
    eq('the leap day sits between Feb 28 and Mar 1', P('2028-03-01') - P('2028-02-28'), 2);
    ['2026-02-29', '2026-13-01', '2026-00-10', '2026-04-31', '26-01-01', '2026-1-1', 'soon', '', null, 42].forEach(function (s) {
      eq('parse rejects ' + JSON.stringify(s), P(s), null);
    });
    eq('format of a non-number is empty', D.format(null), '');

    eq('2026-09-25 is a Friday', D.dow(P('2026-09-25')), 5);
    eq('2026-10-01 is a Thursday', D.dow(P('2026-10-01')), 4);
    eq('2028-02-29 is a Tuesday', D.dow(P('2028-02-29')), 2);
    eq('1969-12-31 (negative day) is a Wednesday', D.dow(-1), 3);

    eq('week start Sunday', D.format(D.startOfWeek(P('2026-09-25'), 0)), '2026-09-20');
    eq('week start Monday', D.format(D.startOfWeek(P('2026-09-25'), 1)), '2026-09-21');
    eq('a Sunday with Monday week start belongs to the week before', D.format(D.startOfWeek(P('2026-09-27'), 1)), '2026-09-21');
    eq('a Sunday with Sunday week start is its own week start', D.format(D.startOfWeek(P('2026-09-27'), 0)), '2026-09-27');
    eq('a Monday with Monday week start is its own week start', D.format(D.startOfWeek(P('2026-09-21'), 1)), '2026-09-21');

    eq('startOfMonth', D.format(D.startOfMonth(P('2026-09-25'))), '2026-09-01');
    eq('addMonths clamps Jan 31 to Feb 28', D.format(D.addMonths(P('2026-01-31'), 1)), '2026-02-28');
    eq('addMonths clamps Jan 31 to Feb 29 in a leap year', D.format(D.addMonths(P('2028-01-31'), 1)), '2028-02-29');
    eq('addMonths backwards', D.format(D.addMonths(P('2026-03-31'), -1)), '2026-02-28');
    eq('addMonths across a year', D.format(D.addMonths(P('2026-11-15'), 3)), '2027-02-15');
    eq('addMonths back across a year', D.format(D.addMonths(P('2026-01-15'), -13)), '2024-12-15');
    eq('startOfQuarter', D.format(D.startOfQuarter(P('2026-11-15'))), '2026-10-01');
    eq('startOfQuarter of Q1', D.format(D.startOfQuarter(P('2026-03-31'))), '2026-01-01');

    // Workdays.
    var s = { workdays: [1, 2, 3, 4, 5], holidays: ['2026-12-25', '2026-09-29'] };
    ok('Saturday is not a workday', !D.isWork(P('2026-09-26'), s));
    ok('Friday is a workday', D.isWork(P('2026-09-25'), s));
    ok('a holiday on a weekday is not a workday', !D.isWork(P('2026-12-25'), s));
    ok('default settings use Monday to Friday', D.isWork(P('2026-09-25')) && !D.isWork(P('2026-09-27')));
    ok('a six-day week counts Saturday', D.isWork(P('2026-09-26'), { workdays: [1, 2, 3, 4, 5, 6] }));
    eq('Fri + 1 workday is Mon', D.format(D.addWork(P('2026-09-25'), 1, {})), '2026-09-28');
    eq('Fri + 5 workdays is next Fri', D.format(D.addWork(P('2026-09-25'), 5, {})), '2026-10-02');
    eq('Mon - 1 workday is Fri', D.format(D.addWork(P('2026-09-28'), -1, {})), '2026-09-25');
    eq('a holiday is skipped (Mon + 1 over a Tue holiday is Wed)', D.format(D.addWork(P('2026-09-28'), 1, s)), '2026-09-30');
    eq('Christmas Eve + 1 over the holiday and the weekend is Mon', D.format(D.addWork(P('2026-12-24'), 1, s)), '2026-12-28');
    eq('Wed - 2 over a Tue holiday is Fri', D.format(D.addWork(P('2026-09-30'), -2, s)), '2026-09-25');
    eq('addWork 0 on a Saturday snaps to Monday', D.format(D.addWork(P('2026-09-26'), 0, s)), '2026-09-28');
    eq('workBetween a full week is 5', D.workBetween(P('2026-09-21'), P('2026-09-27'), {}), 5);
    eq('workBetween with a holiday is 4', D.workBetween(P('2026-09-28'), P('2026-10-04'), s), 4);
    eq('workBetween reversed is negative', D.workBetween(P('2026-09-27'), P('2026-09-21'), {}), -5);
    eq('workBetween one Saturday is 0', D.workBetween(P('2026-09-26'), P('2026-09-26'), {}), 0);
    eq('workBetween over Christmas week', D.workBetween(P('2026-12-21'), P('2027-01-01'), s), 9);
    eq('snap forward from Saturday', D.format(D.snap(P('2026-09-26'), s, 1)), '2026-09-28');
    eq('snap back from Saturday', D.format(D.snap(P('2026-09-26'), s, -1)), '2026-09-25');
    eq('snap a workday is itself', D.format(D.snap(P('2026-09-25'), s, 1)), '2026-09-25');
    eq('no working days at all treats every day as work', D.format(D.addWork(P('2026-09-26'), 2, { workdays: [] })), '2026-09-28');
    // addWork and workBetween agree: n workdays after a workday d spans n+1 workdays.
    var agree = true;
    for (var n = 1; n < 40; n++) {
      var a = P('2026-12-15');
      if (D.workBetween(a, D.addWork(a, n, s), s) !== n + 1) agree = false;
    }
    ok('addWork and workBetween agree across weekends and holidays', agree);

    // Host strings.
    eq('toHost writes YYYY-MM-DD', D.toHost(P('2026-10-01')), '2026-10-01');
    ok('toHost is always the documented form', /^\d{4}-\d{2}-\d{2}$/.test(D.toHost(P('2028-02-29'))));
    eq('fromHost on a bare date', D.fromHost('2026-10-01'), P('2026-10-01'));
    eq('fromHost on the Calendar local form', D.fromHost('2026-10-01T00:00:00.000'), P('2026-10-01'));
    eq('fromHost on a zone-less late time keeps the date', D.fromHost('2026-10-01T23:59:59.999'), P('2026-10-01'));
    ['soon', '', '2026-02-30', '2026-10-01Tnoon', '2026-10-01T25:99:00.000Z', null, 42, {}].forEach(function (g) {
      eq('fromHost rejects ' + JSON.stringify(g), D.fromHost(g), null);
    });
    var zoned = [
      ['Asia/Shanghai', '2024-01-15T09:00:00.000Z', '2024-01-15'],
      ['America/Los_Angeles', '2024-01-15T09:00:00.000Z', '2024-01-15'],
      ['Pacific/Pago_Pago', '2024-01-15T09:00:00.000Z', '2024-01-14'],
      ['Pacific/Kiritimati', '2024-01-15T12:00:00.000Z', '2024-01-16'],
      ['Asia/Shanghai', '2026-10-01T23:30:00.000-08:00', '2026-10-02'],
      ['America/Los_Angeles', '2026-10-01T23:30:00.000-08:00', '2026-10-02'],
      ['Pacific/Honolulu', '2026-10-01T23:30:00.000-08:00', '2026-10-01'],
      ['UTC', '2026-10-01T23:30:00.000-08:00', '2026-10-02']
    ];
    var ran = withTZ('UTC', function () {});
    if (ran) {
      zoned.forEach(function (z) {
        withTZ(z[0], function () { eq('fromHost ' + z[1] + ' in ' + z[0], D.format(D.fromHost(z[1])), z[2]); });
      });
      withTZ('America/New_York', function () {
        eq('today at 03:30 on the spring DST day', D.format(D.today(new Date(2026, 2, 8, 3, 30))), '2026-03-08');
        eq('today at 23:30 on the spring DST day', D.format(D.today(new Date(2026, 2, 8, 23, 30))), '2026-03-08');
        eq('today at 01:30 on the autumn DST day', D.format(D.today(new Date(2026, 10, 1, 1, 30))), '2026-11-01');
        eq('today just after midnight after the autumn switch', D.format(D.today(new Date(2026, 10, 2, 0, 5))), '2026-11-02');
        var steps = 0, good = true, prev = D.today(new Date(2026, 2, 7, 0, 0).getTime());
        for (var t = new Date(2026, 2, 7, 0, 30).getTime(); t < new Date(2026, 2, 10).getTime(); t += 1800e3) {
          var d = D.today(t);
          if (d !== prev && d !== prev + 1) good = false;
          prev = d;
          steps++;
        }
        ok('today never jumps by more than a day across DST (' + steps + ' half hours)', good);
        eq('dayFraction at local noon', D.dayFraction(new Date(2026, 2, 9, 12, 0)), 0.5);
      });
    } else {
      var loc = new Date('2024-01-15T09:00:00.000Z');
      eq('fromHost converts a Z time to the local date', D.fromHost('2024-01-15T09:00:00.000Z'),
        Math.round(Date.UTC(loc.getFullYear(), loc.getMonth(), loc.getDate()) / 864e5));
    }
    eq('today of a fixed local time', D.format(D.today(new Date(2026, 8, 25, 10))), '2026-09-25');
    ok('dayFraction stays in [0, 1)', D.dayFraction(new Date(2026, 8, 25, 23, 59, 59, 999)) < 1 && D.dayFraction(new Date(2026, 8, 25)) === 0);
  }

  /* ================================================================ model */

  function transformCases() {
    var c = freeze(example());
    var t1 = P('2026-10-01');
    return [
      ['addTasks', function (x) { return M.addTasks(x, [{ note: 'n-new', title: 'New', start: t1, end: t1 + 4, group: 'g2' }, { note: N1 }], { index: 1 }); }],
      ['addTasks milestone without note', function (x) { return M.addTasks(x, [{ title: 'Gate', start: t1, milestone: true }]); }],
      ['moveTask forward', function (x) { return M.moveTask(x, 't3', 3); }],
      ['moveTask back', function (x) { return M.moveTask(x, 't1', -2); }],
      ['moveTask milestone', function (x) { return M.moveTask(x, 't4', 7); }],
      ['resizeTask start earlier', function (x) { return M.resizeTask(x, 't1', 'start', t1 - 5); }],
      ['resizeTask end later', function (x) { return M.resizeTask(x, 't1', 'end', t1 + 20); }],
      ['resizeTask start past the end clamps', function (x) { return M.resizeTask(x, 't1', 'start', t1 + 40); }],
      ['resizeTask end to the start', function (x) { return M.resizeTask(x, 't2', 'end', P('2026-09-01')); }],
      ['setDates swapped', function (x) { return M.setDates(x, 't2', P('2026-12-01'), P('2026-11-01')); }],
      ['setDates unschedule', function (x) { return M.setDates(x, 't2', null, null); }],
      ['reorder to the top', function (x) { return M.reorder(x, 't4', 0); }],
      ['reorder into another group', function (x) { return M.reorder(x, 't1', 3, 'g2'); }],
      ['reorder out of any group', function (x) { return M.reorder(x, 't2', 2, null); }],
      ['removeTask strips after', function (x) { return M.removeTask(x, 't1'); }],
      ['removeTask last', function (x) { return M.removeTask(x, 't4'); }],
      ['setTask colour', function (x) { return M.setTask(x, 't1', { color: 'rose' }); }],
      ['setTask milestone drops end', function (x) { return M.setTask(x, 't2', { milestone: true }); }],
      ['setTask several fields', function (x) { return M.setTask(x, 't3', { title: 'Sync v2', progress: 'status', group: 'g1', color: null }); }],
      ['setDeps', function (x) { return M.setDeps(x, 't2', ['t1']); }],
      ['addGroup', function (x) { return M.addGroup(x, { title: 'Launch', color: 'rose' }, 1); }],
      ['renameGroup', function (x) { return M.renameGroup(x, 'g1', 'Research'); }],
      ['renameGroup colour', function (x) { return M.renameGroup(x, 'g2', undefined, 'sky'); }],
      ['removeGroup ungroups its tasks', function (x) { return M.removeGroup(x, 'g1'); }],
      ['setSettings', function (x) { return M.setSettings(x, { colorBy: 'group', workdays: [1, 2, 3, 4], embed: true }); }]
    ].map(function (p) { return { name: p[0], fn: p[1], chart: c }; });
  }

  function modelSpec() {
    var e = M.empty();
    eq('empty chart data is just the version', json(M.toData(e)), '{"v":1}');
    eq('AUTO_HUES has ten hues', M.AUTO_HUES.length, 10);
    ok('AUTO_HUES never yields slate', M.AUTO_HUES.indexOf('slate') < 0);
    var slate = false;
    for (var i = 0; i < 2000; i++) if (M.AUTO_HUES[parseInt(B.hash('note-' + i), 16) % 10] === 'slate') slate = true;
    ok('hash(noteId) % 10 over AUTO_HUES never yields slate', !slate);
    ok('the palette names are the eleven of D2', M.COLORS.length === 11 && M.COLORS.indexOf('slate') === 10);

    var c = example();
    eq('example: settings kept', c.settings.progressSource + '|' + c.settings.weekStart, 'checklist|1');
    eq('example: days in memory', c.tasks[0].start, P('2026-10-01'));
    eq('example: milestone has no end', c.tasks[3].end, null);
    eq('coerce of garbage is empty', json(M.toData(M.coerce('nope').chart)), '{"v":1}');
    eq('coerce of non-array lists is empty', json(M.toData(M.coerce({ v: 1, tasks: 'x', groups: 5 }).chart)), '{"v":1}');

    var dep = B.read(fix('deps.md'));
    eq('deps: surviving tasks', dep.chart.tasks.map(function (t) { return t.id; }).join(','), 't1,t2,t3,t6');
    eq('deps: missing, self and duplicate refs removed', dep.chart.tasks[1].after.join(','), 't1');
    eq('deps: the edge closing a cycle is dropped', dep.chart.tasks[2].after.join(','), '');
    eq('deps: first-come edge kept', dep.chart.tasks[0].after.join(','), 't3');
    eq('deps: unknown group reads as ungrouped', dep.chart.tasks[3].group, null);
    eq('deps: dropped counts deps, duplicate note, note-less task, bad group', dep.dropped, 6);

    var sw = M.coerce({ v: 1, tasks: [{ id: 't1', note: 'a', start: '2026-10-09', end: '2026-10-01' }, { id: 't2', note: 'b', end: '2026-10-05' }, { note: 'c', start: '2026-10-01', end: '2026-10-03', milestone: true }] }).chart;
    eq('coerce swaps an end before the start', D.format(sw.tasks[0].start) + '>' + D.format(sw.tasks[0].end), '2026-10-01>2026-10-09');
    eq('coerce turns an end without a start into a one-day task', D.format(sw.tasks[1].start) + '|' + sw.tasks[1].end, '2026-10-05|null');
    ok('coerce drops a milestone end and assigns a missing id', /^t[0-9a-z]{6}$/.test(sw.tasks[2].id) && sw.tasks[2].end === null, sw.tasks[2].id);
    var swData = { v: 1, tasks: [{ note: 'c', start: '2026-10-01', milestone: true }] };
    eq('coerce assigns the same missing id on every read', M.coerce(swData).chart.tasks[0].id, M.coerce(swData).chart.tasks[0].id);

    var td = M.taskData(c.tasks[1]);
    eq('task data key order', Object.keys(td).join(','), 'id,note,title,start,end,group,color');
    eq('milestone data key order', Object.keys(M.taskData(c.tasks[3])).join(','), 'id,note,title,start,group,milestone,after');
    eq('settings data: defaults omitted, fixed order', Object.keys(M.settingsData(c.settings)).join(','), 'progressSource,progressSection,progressStyle,weekStart,holidays');

    ok('nextId is t plus six base-36 characters', /^t[0-9a-z]{6}$/.test(M.nextId(c)));
    ok('nextId for groups is g plus six base-36 characters', /^g[0-9a-z]{6}$/.test(M.nextId(c, 'g')));
    // A random source that first offers ids already on the chart.
    var realRandom = M.random, feed = [];
    ['000001', '000001', '00000a'].forEach(function (s) { s.split('').forEach(function (ch) { feed.push((parseInt(ch, 36) + 0.5) / 36); }); });
    M.random = function () { return feed.length ? feed.shift() : realRandom(); };
    var clashChart = M.coerce({ v: 1, tasks: [{ id: 't000001', note: 'a' }] }).chart;
    eq('nextId skips an id already on the chart', M.nextId(clashChart), 't00000a');
    M.random = realRandom;
    // Id reuse (review round 1): remove a task, add another; the removed id
    // is not issued again, so a merge sees remove vs edit, not an edit.
    var S2 = M.coerce({ v: 1, tasks: [{ id: 't1', note: 'n1', start: '2026-10-01' }, { id: 't2', note: 'nA', start: '2026-10-03', end: '2026-10-05' }] }).chart;
    var reuse = M.addTasks(M.removeTask(S2, 't2').chart, [{ note: 'nX', title: 'X', start: P('2026-12-01') }]);
    ok('ids: a removed id is not issued again', reuse.added[0] !== 't2', reuse.added[0]);
    var reuseMerge = M.merge3(S2, reuse.chart, M.setTask(S2, 't2', { color: 'rose' }).chart);
    eq('ids: remove plus add vs an edit of the removed task is a remove-vs-edit conflict',
      reuseMerge.conflicts.map(function (x) { return x.key; }).join(','), 't2.removed');
    ok('ids: the new task keeps its own dates', reuseMerge.chart.tasks.some(function (t) { return t.note === 'nX' && t.start === P('2026-12-01') && t.color === null; }));
    var seen = Object.create(null), dup = false, churn = S2;
    for (var ci = 0; ci < 3000; ci++) {
      var ad = M.addTasks(churn, [{ note: 'churn' + ci }]);
      if (seen[ad.added[0]]) dup = true;
      seen[ad.added[0]] = true;
      churn = M.removeTask(ad.chart, ad.added[0]).chart;
    }
    ok('ids: 3000 add/remove cycles never reissue an id', !dup);

    // Review round 2: derived ids do not depend on position, so an external
    // edit to a hand-written, id-less block never renames a record.
    var idless = { v: 1, tasks: [{ note: 'n1', title: 'A', start: '2026-10-01', end: '2026-10-03' }, { note: 'n2', title: 'B', start: '2026-10-05' },
      { note: 'n3', title: 'C' }, { milestone: true, title: 'M', start: '2026-10-09' }, { milestone: true, title: 'M', start: '2026-10-09' }] };
    function idl(edit) { var d = JSON.parse(JSON.stringify(idless)); if (edit) edit(d); return M.coerce(d).chart; }
    function idsByKey(c) { var o = {}; c.tasks.forEach(function (t, k) { o[t.note || ('ms' + k)] = t.id; }); return o; }
    var IB = idl(), ib = idsByKey(IB);
    var ibIns = idsByKey(idl(function (d) { d.tasks.unshift({ note: 'n0', title: 'Z' }); }));
    ok('derived ids: an insert above keeps every noted task\'s id', ibIns.n1 === ib.n1 && ibIns.n2 === ib.n2 && ibIns.n3 === ib.n3);
    ok('derived ids: an insert above keeps the note-less milestones\' ids', ibIns.ms4 === ib.ms3 && ibIns.ms5 === ib.ms4);
    ok('derived ids: a content edit keeps a noted task\'s id', idsByKey(idl(function (d) { d.tasks[1].title = 'B2'; d.tasks[1].start = '2026-10-20'; })).n2 === ib.n2);
    ok('derived ids: two identical milestones get two ids', ib.ms3 !== ib.ms4);
    var myMove = M.moveTask(IB, ib.n2, 2).chart;
    var rTitle = M.merge3(IB, myMove, idl(function (d) { d.tasks[1].title = 'B2'; }));
    eq('derived ids: my move vs their title edit merges cleanly', keys(rTitle) + '|' + D.format(M.task(rTitle.chart, ib.n2).start), '|2026-10-07');
    eq('derived ids: my move vs their date edit is a field conflict, not a removal', keys(M.merge3(IB, myMove, idl(function (d) { d.tasks[1].start = '2026-10-20'; }))), ib.n2 + '.start');
    var theirIns = idl(function (d) { d.tasks.unshift({ note: 'n0', title: 'Z' }); });
    var rRem = M.merge3(IB, M.removeTask(IB, ib.n2).chart, theirIns);
    eq('derived ids: my removal survives their insert above', keys(rRem) + '|' + rRem.chart.tasks.map(function (t) { return t.note || 'ms'; }).join(','), '|n0,n1,n3,ms,ms');
    var rOrd = M.merge3(IB, M.reorder(IB, ib.n3, 0).chart, theirIns);
    eq('derived ids: my reorder survives their insert above', keys(rOrd) + '|' + rOrd.chart.tasks.map(function (t) { return t.note || 'ms'; }).join(','), '|n3,n0,n1,n2,ms,ms');
    var rMs = M.merge3(IB, M.removeTask(IB, ib.ms4).chart, theirIns);
    eq('derived ids: removing one of two identical milestones survives their insert', keys(rMs) + '|' + rMs.chart.tasks.filter(function (t) { return !t.note; }).length, '|1');

    // Review round 2: a repeated explicit id keeps the record under a derived id.
    var rep = M.coerce({ v: 1, groups: [{ id: 'g1', title: 'A' }, { id: 'g1', title: 'B' }],
      tasks: [{ id: 't1', note: 'n1', group: 'g1' }, { id: 't1', note: 'n2' }] });
    eq('a repeated task id keeps both tasks', rep.chart.tasks.map(function (t) { return t.note; }).join(','), 'n1,n2');
    ok('the repeat gets another id', rep.chart.tasks[1].id !== 't1' && /^t[0-9a-z]{6}$/.test(rep.chart.tasks[1].id));
    eq('a repeated group id keeps both groups', rep.chart.groups.map(function (g) { return g.title; }).join(','), 'A,B');
    ok('references go to the first record with the id', rep.chart.tasks[0].group === 'g1' && rep.chart.groups[1].id !== 'g1');
    eq('repeated ids are counted', rep.dropped, 2);

    // Review round 2: a field that ended up with a real value has no shadow.
    var mv2 = M.coerce({ v: 1, tasks: [{ id: 't1', note: 'a', start: 'soon', end: '2026-10-05' }] });
    eq('an end moved into a bad start leaves no dead shadow', B.serialize(mv2.chart), '{"v":1,\n"tasks":[\n {"id":"t1","note":"a","start":"2026-10-05"}\n]}');
    eq('and it is still counted', mv2.dropped, 1);
    ok('the dead shadow is not kept in memory either', !Object.prototype.hasOwnProperty.call(mv2.chart.tasks[0]._x, 'start'));

    // Review round 2: an undo applied after a merge never builds a chart
    // coerce would change.
    var Su = M.coerce({ v: 1, groups: [{ id: 'g1', title: 'G1' }, { id: 'g2', title: 'G2' }],
      tasks: [{ id: 't1', note: 'n1', start: '2026-10-01', group: 'g1' }, { id: 't2', note: 'n2', start: '2026-10-03', group: 'g1', after: ['t1'] }] }).chart;
    function clean(c) { var rr = M.coerce(JSON.parse(B.serialize(c))); return rr.dropped === 0 && B.serialize(rr.chart) === B.serialize(c); }
    var rmU = M.removeTask(Su, 't2');
    var reAdd = M.addTasks(M.removeTask(Su, 't2').chart, [{ note: 'n2', title: 'again' }]).chart;
    var uA = M.applyPatch(M.merge3(Su, rmU.chart, reAdd).chart, rmU.inverse).chart;
    ok('undo of my remove after they re-added the note leaves one task for it', uA.tasks.filter(function (t) { return t.note === 'n2'; }).length === 1 && clean(uA));
    var grU = M.setTask(Su, 't1', { group: 'g2' });
    var uB = M.applyPatch(M.merge3(Su, grU.chart, M.removeGroup(Su, 'g1').chart).chart, grU.inverse).chart;
    ok('undo into a group they removed leaves the task ungrouped', M.task(uB, 't1').group === null && clean(uB));
    // Their group removal edits t2, so keeping my removal takes a resolution.
    var mC = M.merge3(Su, rmU.chart, M.removeGroup(M.removeTask(Su, 't1').chart, 'g1').chart, { resolutions: { 't2.removed': 'mine' } });
    ok('(setup) t2 and its group and dependency are gone', !M.task(mC.chart, 't2') && !M.group(mC.chart, 'g1') && !M.task(mC.chart, 't1'));
    var uC = M.applyPatch(mC.chart, rmU.inverse).chart;
    ok('undo of a remove whose group and dependency are gone inserts a valid task', M.task(uC, 't2') && M.task(uC, 't2').group === null &&
      M.task(uC, 't2').after.length === 0 && clean(uC));
    var dp = M.setDeps(Su, 't2', []);
    var uD = M.applyPatch(M.merge3(Su, dp.chart, M.setDeps(M.setDeps(Su, 't2', []).chart, 't1', ['t2']).chart).chart, dp.inverse).chart;
    ok('undo that would restore a dependency cycle keeps the chart acyclic', clean(uD));
    var ntU = M.setTask(Su, 't1', { note: 'n9' });
    var uE = M.applyPatch(M.merge3(Su, ntU.chart, M.addTasks(Su, [{ note: 'n1', title: 'x' }]).chart).chart, ntU.inverse).chart;
    ok('undo that would give a note to a second task leaves it out', clean(uE));

    // M1 review round 3: restoring my edge when their edge now closes a
    // cycle leaves out only my restored entry; their edge survives.
    var S3 = M.coerce({ v: 1, tasks: [{ id: 'tA', note: 'nA' }, { id: 'tB', note: 'nB' }, { id: 'tC', note: 'nC' }] }).chart;
    var myDep = M.setDeps(S3, 'tA', ['tB']);
    var undoneDep = M.applyPatch(myDep.chart, myDep.inverse);
    var theirDep = M.merge3(S3, undoneDep.chart, M.setDeps(S3, 'tB', ['tA']).chart).chart;
    var redone = M.applyPatch(theirDep, undoneDep.inverse);
    eq('redo of my edge after they added the reverse keeps their edge', redone.chart.tasks.map(function (t) { return t.id + '>' + t.after.join('+'); }).join(' '), 'tA> tB>tA tC>');
    ok('the redo left out is a no-op with no inverse', redone.inverse.length === 0 && clean(redone.chart));
    // A restored entry that is fine is kept next to one that is left out.
    var S4 = M.coerce({ v: 1, tasks: [{ id: 'tA', note: 'nA' }, { id: 'tB', note: 'nB', after: ['tA'] }, { id: 'tC', note: 'nC' }] }).chart;
    var mixed = M.applyPatch(S4, [{ op: 'set', id: 'tA', fields: { after: ['tC', 'tB'] } }]).chart;
    eq('a restored after list keeps the entries that close no cycle', mixed.tasks.map(function (t) { return t.id + '>' + t.after.join('+'); }).join(' '), 'tA>tC tB>tA tC>');
    // Undo of a remove restores the edges that pointed at the task, unless
    // one now closes a cycle; their edges stay.
    var S5 = M.coerce({ v: 1, tasks: [{ id: 'tC', note: 'nC', after: ['tB'] }, { id: 'tB', note: 'nB', after: ['tA'] }, { id: 'tA', note: 'nA' }] }).chart;
    var rmB = M.removeTask(S5, 'tB');
    var th5 = M.setDeps(M.setDeps(S5, 'tB', []).chart, 'tA', ['tC']).chart;
    var m5 = M.merge3(S5, rmB.chart, th5, { resolutions: { 'tB.removed': 'mine' } });
    ok('(setup) their edge tA>tC is in the merge', m5.conflicts.length === 0 && M.task(m5.chart, 'tA').after.join() === 'tC' && !M.task(m5.chart, 'tB'));
    var un5 = M.applyPatch(m5.chart, rmB.inverse).chart;
    eq('undo of a remove keeps their edge and leaves out the restored one that closes a cycle',
      un5.tasks.map(function (t) { return t.id + '>' + t.after.join('+'); }).join(' '), 'tC> tB>tA tA>tC');

    // M1 review round 3 (nit): id-less, note-less milestones edited before
    // the first save take a new derived id, so their edit reads as a remove
    // plus an add (§5.3 id row states these outcomes).
    var msBase = { v: 1, tasks: [{ note: 'n1', title: 'A', start: '2026-10-01' }, { milestone: true, title: 'M', start: '2026-10-09' }] };
    var MS = M.coerce(JSON.parse(JSON.stringify(msBase))).chart, msId = MS.tasks[1].id;
    var msTheirs = JSON.parse(JSON.stringify(msBase)); msTheirs.tasks[1].title = 'M2';
    var MT = M.coerce(msTheirs).chart;
    ok('(pin) their title edit renames an id-less milestone', MT.tasks[1].id !== msId);
    var msDate = M.merge3(MS, M.moveTask(MS, msId, 2).chart, MT);
    eq('(pin) my date edit vs their title edit: <id>.removed conflict', keys(msDate), msId + '.removed');
    var msRem = M.merge3(MS, M.removeTask(MS, msId).chart, MT);
    eq('(pin) my removal vs their title edit: their renamed milestone stays', keys(msRem) + '|' + msRem.chart.tasks.map(function (t) { return t.title; }).join(','), '|A,M2');

    // Unknown keys and enum values survive.
    var uk = B.read(fix('unknown-keys.md')).chart;
    eq('unknown setting enum kept', uk.settings.colorBy, 'sparkle');
    same('unknown setting key kept', uk.settings._x.zoomHint, { a: [1, 2] });
    ok('an unknown __proto__ key is kept as data', Object.prototype.hasOwnProperty.call(uk.settings._x, '__proto__') &&
      Object.getPrototypeOf(uk.settings._x) === Object.prototype && uk.settings._x.x === undefined);
    eq('unknown task keys kept', json(uk.tasks[0]._x), '{"pct":40,"tags":["x","y"]}');
    eq('unknown per-task progress source kept', uk.tasks[0].progress, 'manual');
    eq('unknown colour name kept', uk.tasks[1].color, 'chartreuse');
    eq('unknown group keys kept', json(uk.groups[0]._x), '{"owner":"ann","meta":{"k":[true,null]}}');
    eq('unknown top-level keys kept', json(uk._x), '{"theme":"dusk","layout":{"lanes":[{"id":1}]}}');

    // Every transform's inverse restores the chart exactly, and the inverse
    // of that inverse redoes it.
    transformCases().forEach(function (tc) {
      var before = canon(tc.chart);
      var r;
      try { r = tc.fn(tc.chart); } catch (err) { ok(tc.name + ' runs on a frozen chart', false, String(err && err.stack)); return; }
      eq(tc.name + ' leaves its input untouched', canon(tc.chart), before);
      ok(tc.name + ' changes the chart', canon(r.chart) !== before, 'no change');
      ok(tc.name + ' returns inverse patches', r.inverse.length > 0);
      var back = M.applyPatch(r.chart, r.inverse);
      eq(tc.name + ': inverse restores the chart', canon(back.chart), before);
      eq(tc.name + ': inverse restores the JSON', json(M.toData(back.chart)), json(M.toData(tc.chart)));
      var again = M.applyPatch(back.chart, back.inverse);
      eq(tc.name + ': inverse of the inverse redoes it', canon(again.chart), canon(r.chart));
      eq(tc.name + ': no host effects', back.effects.length, 0);
    });

    // Transform semantics.
    var m = M.moveTask(c, 't3', 3).chart;
    eq('moveTask keeps the length', m.tasks[2].end - m.tasks[2].start, c.tasks[2].end - c.tasks[2].start);
    eq('moveTask of an unscheduled task is a no-op', M.moveTask(M.setDates(c, 't1', null, null).chart, 't1', 2).inverse.length, 0);
    eq('resize clamps start to end', M.resizeTask(c, 't1', 'start', P('2026-12-01')).chart.tasks[0].start, P('2026-10-09'));
    eq('resize clamps end to start', M.resizeTask(c, 't1', 'end', P('2026-01-01')).chart.tasks[0].end, null);
    eq('milestones never resize', M.resizeTask(c, 't4', 'end', P('2026-12-01')).inverse.length, 0);
    eq('removeTask strips after references', M.removeTask(c, 't1').chart.tasks[1].after.length, 0);
    eq('removeGroup ungroups', M.removeGroup(c, 'g1').chart.tasks[0].group, null);
    eq('reorder places the task at the index', M.reorder(c, 't4', 0).chart.tasks.map(function (t) { return t.id; }).join(','), 't4,t1,t2,t3');
    var add = M.addTasks(c, [{ note: N1 }, { note: 'x1' }, { note: 'x1' }, { title: 'no note' }]);
    eq('addTasks skips notes already on the chart and repeats (D20)', add.added.length + '|' + add.skipped, '1|3');
    eq('setDeps refuses a cycle', M.setDeps(c, 't1', ['t3']).chart.tasks[0].after.length, 0);
    eq('setSettings ignores unknown keys', M.setSettings(c, { bogus: 1 }).inverse.length, 0);

    // applyPatch details.
    var host = { op: 'host', kind: 'toggleItem', args: { noteId: N1, section: '## Checklist', line: '- [x] call', prevLine: '- [ ] plan', checked: true } };
    var hr = M.applyPatch(c, [host, { op: 'host', kind: 'setChildStatus', args: { noteId: N2, status: 'complete', prev: 'todo' } }]);
    ok('host patches leave the chart untouched', hr.chart === c);
    eq('host patches come back as effects', hr.effects.length, 2);
    eq('a checkbox inverse flips the box and the flag', hr.inverse[1].args.line + '|' + hr.inverse[1].args.checked, '- [ ] call|false');
    eq('a status inverse swaps status and prev', hr.inverse[0].args.status + '|' + hr.inverse[0].args.prev, 'todo|complete');
    eq('toggleSubnote inverse', M.invertHost({ op: 'host', kind: 'toggleSubnote', args: { noteId: 'n', subId: 's', done: true } }).args.done, false);
    eq('renameChart inverse', M.invertHost({ op: 'host', kind: 'renameChart', args: { title: 'B', prev: 'A' } }).args.title, 'A');
    var ordAdd = M.addTasks(M.reorder(c, 't4', 0).chart, [{ note: 'late' }], { index: 2 });
    var ordBack = M.applyPatch(ordAdd.chart, [{ op: 'order', ids: ['t1', 't2', 't3', 't4'] }]).chart;
    eq('an order patch keeps a task added since in its slot', ordBack.tasks.map(function (t) { return t.id; }).join(','), 't1,t2,' + ordAdd.added[0] + ',t3,t4');
    // Undo of a remove after an insert elsewhere puts the task back after
    // the task it followed, not at a shifted index.
    var rm = M.removeTask(c, 't3');
    var ext = M.addTasks(rm.chart, [{ note: 'z' }], { index: 0 });
    eq('undo of a remove after an external insert restores its place',
      M.applyPatch(ext.chart, rm.inverse).chart.tasks.map(function (t) { return t.id; }).join(','), ext.added[0] + ',t1,t2,t3,t4');

    // Unusable known values are kept as shadows (re-emitted) and counted.
    var shRead = M.coerce({ v: 1, settings: { mirror: 'no', weekStart: 7 }, tasks: [{ id: 't1', note: 'a', start: '2026-10-1', group: 'g404' }] });
    eq('coerce counts unusable known values', shRead.dropped, 4);
    eq('coerce keeps unusable known values verbatim', B.serialize(shRead.chart),
      '{"v":1,\n"settings":{"mirror":"no","weekStart":7},\n"tasks":[\n {"id":"t1","note":"a","start":"2026-10-1","group":"g404"}\n]}');
    eq('coerce: a shadowed field reads as its default', shRead.chart.settings.mirror + '|' + shRead.chart.tasks[0].start + '|' + shRead.chart.tasks[0].group, 'true|null|null');
    var shSet = M.setDates(shRead.chart, 't1', P('2026-10-02'), null);
    eq('setting a shadowed field drops the shadow', json(M.taskData(shSet.chart.tasks[0])), '{"id":"t1","note":"a","start":"2026-10-02","group":"g404"}');
    eq('undo restores the shadow', B.serialize(M.applyPatch(shSet.chart, shSet.inverse).chart), B.serialize(shRead.chart));
    var shS = M.setSettings(shRead.chart, { weekStart: 1 });
    eq('setting a shadowed setting drops the shadow', json(M.settingsData(shS.chart.settings)), '{"weekStart":1,"mirror":"no"}');
    eq('undo restores the setting shadow', B.serialize(M.applyPatch(shS.chart, shS.inverse).chart), B.serialize(shRead.chart));

    // setTask guards (review round 1).
    eq('setTask refuses a note already on another task (D20)', M.setTask(c, 't1', { note: N2 }).inverse.length, 0);
    eq('setTask accepts a fresh note', M.setTask(c, 't1', { note: 'n-fresh' }).chart.tasks[0].note, 'n-fresh');
    var stD = M.setTask(c, 't1', { start: P('2026-12-01') }).chart.tasks[0];
    eq('setTask dates go through the setDates rules (swap)', D.format(stD.start) + '>' + D.format(stD.end), '2026-10-09>2026-12-01');
    eq('setTask milestone clears the end', M.setTask(c, 't1', { milestone: true }).chart.tasks[0].end, null);
    var bare = M.addTasks(c, [{ title: 'Gate', milestone: true, start: P('2026-10-20') }]);
    eq('setTask cannot turn a note-less milestone into a task', M.setTask(bare.chart, bare.added[0], { milestone: false }).inverse.length, 0);

    // Dates stay within four-digit years.
    var far = M.moveTask(c, 't1', 8000 * 366).chart;
    eq('moveTask clamps at 9999-12-31', D.format(far.tasks[0].start) + '|' + far.tasks[0].end, '9999-12-31|null');
    var farRead = B.read('x\n\n' + B.region(far, {}, {}));
    ok('a clamped chart reads back', farRead.status === 'ok' && farRead.chart.tasks[0].start === far.tasks[0].start);
    eq('setDates clamps below 0100-01-01', D.format(M.setDates(c, 't1', -1e7, null).chart.tasks[0].start), '0100-01-01');
    ok('an insert patch for an existing id is ignored', M.applyPatch(c, [{ op: 'insert', task: c.tasks[0], index: 3 }]).chart === c);
    ok('a set patch for a missing task is ignored', M.applyPatch(c, [{ op: 'set', id: 'nope', fields: { color: 'rose' } }]).chart === c);

    // Queries.
    same('range spans every dated task', M.range(c), { min: P('2026-10-01'), max: P('2026-11-09') });
    eq('range of an empty chart', M.range(M.empty()), null);
    var facts = {}; facts[N1] = { title: 'Interviews (renamed)' }; facts[N2] = { title: 'x', missing: true };
    var tf = M.titlesFrom(c, facts);
    eq('titlesFrom refreshes titles', tf.tasks[0].title, 'Interviews (renamed)');
    eq('titlesFrom ignores missing notes', tf.tasks[1].title, 'Competitive teardown');
    ok('titlesFrom returns the same chart when nothing changed', M.titlesFrom(c, {}) === c);
    ok('sameIgnoringTitles ignores titles', M.sameIgnoringTitles(c, tf));
    ok('sameIgnoringTitles sees other changes', !M.sameIgnoringTitles(c, M.moveTask(tf, 't1', 1).chart));
  }

  /* ================================================================ merge */

  function ids(c) { return c.tasks.map(function (t) { return t.id; }).join(','); }
  function keys(r) { return r.conflicts.map(function (x) { return x.key; }).sort().join(','); }

  function mergeSpec() {
    var S = freeze(example());
    var mine, theirs, r;
    // Every matrix case is recorded and re-merged at the end with merge
    // results and JSON round-tripped charts in place of its inputs.
    var cases = [];
    function m3(b, m, t, o) {
      var res = M.merge3(b, m, t, o);
      cases.push({ b: b, m: m, t: t, o: o, res: res });
      return res;
    }
    function notes(c) { return c.tasks.map(function (t) { return t.note || t.id; }).join(','); }

    mine = M.moveTask(S, 't1', 2).chart;
    theirs = M.setTask(S, 't2', { color: 'sky' }).chart;
    r = m3(S, mine, theirs);
    eq('merge: disjoint fields merge without conflict', keys(r), '');
    ok('merge: both sides kept', r.chart.tasks[0].start === S.tasks[0].start + 2 && r.chart.tasks[1].color === 'sky');

    mine = M.setTask(S, 't1', { color: 'rose' }).chart;
    theirs = M.setTask(S, 't1', { color: 'sky' }).chart;
    r = m3(S, mine, theirs);
    eq('merge: same field, different values conflicts', keys(r), 't1.color');
    same('merge: the conflict names all three values', r.conflicts[0], { key: 't1.color', base: null, mine: 'rose', theirs: 'sky' });
    eq('merge: an unresolved conflict takes theirs', r.chart.tasks[0].color, 'sky');
    r = m3(S, mine, theirs, { resolutions: { 't1.color': 'mine' } });
    eq('merge: resolution mine', r.chart.tasks[0].color + '|' + keys(r), 'rose|');
    r = m3(S, mine, theirs, { resolutions: { 't1.color': 'theirs' } });
    eq('merge: resolution theirs', r.chart.tasks[0].color + '|' + keys(r), 'sky|');
    r = m3(S, mine, M.setTask(S, 't1', { color: 'rose' }).chart);
    eq('merge: the same change on both sides is no conflict', keys(r) + r.chart.tasks[0].color, 'rose');

    var both = M.setTask(M.moveTask(S, 't1', 1).chart, 't2', { color: 'pink' }).chart;
    var th2 = M.setTask(M.moveTask(S, 't1', 3).chart, 't2', { color: 'sky' }).chart;
    r = m3(S, both, th2, { resolutions: { 't1.start': 'mine' } });
    eq('merge: resolutions cover only the listed conflicts', keys(r), 't1.end,t2.color');

    var myAdd = M.addTasks(S, [{ note: 'n-mine', title: 'Mine' }]);
    theirs = M.removeTask(S, 't2').chart;
    r = m3(S, myAdd.chart, theirs);
    eq('merge: add vs remove both apply', notes(r.chart) + '|' + keys(r), [N1, N3, N4, 'n-mine'].join(',') + '|');

    var theirAdd = M.addTasks(S, [{ note: 'n-theirs', title: 'Theirs' }]);
    r = m3(S, myAdd.chart, theirAdd.chart);
    eq('merge: both add at once: both kept, no conflict, no id changed', notes(r.chart) + '|' + keys(r) + '|' + json(r.remap),
      [N1, N2, N3, N4, 'n-mine', 'n-theirs'].join(',') + '||{}');
    ok('merge: both adds keep their own ids', M.task(r.chart, myAdd.added[0]).note === 'n-mine' && M.task(r.chart, theirAdd.added[0]).note === 'n-theirs');
    var undoMine = M.applyPatch(r.chart, myAdd.inverse).chart;
    eq('merge: undo of my add after the merge removes only mine', notes(undoMine), [N1, N2, N3, N4, 'n-theirs'].join(','));

    var theirSame = M.addTasks(M.addTasks(S, [{ note: 'n-x' }]).chart, [{ note: 'n-mine', title: 'Mine' }]);
    r = m3(S, myAdd.chart, theirSame.chart);
    eq('merge: both add the same note: one task, theirs (D20)', r.chart.tasks.filter(function (t) { return t.note === 'n-mine'; }).map(function (t) { return t.id; }).join() + '|' + keys(r), theirSame.added[0] + '|');
    eq('merge: remap names my dropped id', json(r.remap), json((function () { var o = {}; o[myAdd.added[0]] = theirSame.added[0]; return o; })()));
    eq('merge: undo of my add after the dedupe leaves their task alone', notes(M.applyPatch(r.chart, myAdd.inverse).chart), notes(r.chart));

    mine = M.removeTask(S, 't2').chart;
    theirs = M.setTask(S, 't2', { color: 'sky' }).chart;
    r = m3(S, mine, theirs);
    eq('merge: remove vs edit conflicts', keys(r), 't2.removed');
    eq('merge: unresolved remove vs edit keeps theirs', ids(r.chart), 't1,t2,t3,t4');
    eq('merge: resolution mine removes', ids(m3(S, mine, theirs, { resolutions: { 't2.removed': 'mine' } }).chart), 't1,t3,t4');
    r = m3(S, theirs, mine, { resolutions: { 't2.removed': 'mine' } });
    eq('merge: edit (mine) vs remove (theirs) resolved mine keeps the edit in place', ids(r.chart) + '|' + r.chart.tasks[1].color, 't1,t2,t3,t4|sky');
    r = m3(S, mine, M.setTask(S, 't2', { title: 'Renamed' }).chart);
    eq('merge: remove vs a title refresh is no conflict', ids(r.chart) + '|' + keys(r), 't1,t3,t4|');
    r = m3(S, mine, M.removeTask(S, 't2').chart);
    eq('merge: both remove', ids(r.chart) + '|' + keys(r), 't1,t3,t4|');

    mine = M.reorder(S, 't4', 0).chart;
    theirs = M.reorder(S, 't2', 0).chart;
    r = m3(S, mine, theirs);
    eq('merge: order follows theirs with my moved row re-applied', ids(r.chart), 't4,t2,t1,t3');
    mine = M.reorder(S, 't1', 3).chart;
    var tAdd = M.addTasks(S, [{ note: 'n-t' }]);
    r = m3(S, mine, tAdd.chart);
    eq('merge: my move lands after its new predecessor, their add stays', ids(r.chart), 't2,t3,t4,t1,' + tAdd.added[0]);

    mine = M.setSettings(S, { colorBy: 'group' }).chart;
    theirs = M.setSettings(S, { progressStyle: 'dots' }).chart;
    r = m3(S, mine, theirs);
    eq('merge: settings merge per key', r.chart.settings.colorBy + '|' + r.chart.settings.progressStyle + '|' + keys(r), 'group|dots|');
    r = m3(S, mine, M.setSettings(S, { colorBy: 'task' }).chart);
    eq('merge: the same setting on both sides conflicts', keys(r), 'settings.colorBy');
    eq('merge: settings resolution', m3(S, mine, M.setSettings(S, { colorBy: 'task' }).chart, { resolutions: { 'settings.colorBy': 'mine' } }).chart.settings.colorBy, 'group');

    mine = M.removeGroup(S, 'g1').chart;
    theirs = M.renameGroup(S, 'g1', 'Research').chart;
    r = m3(S, mine, theirs);
    eq('merge: remove group vs rename conflicts', keys(r), 'g1.removed');
    theirs = M.reorder(S, 't3', 1, 'g1').chart;
    r = m3(S, mine, theirs);
    eq('merge: a task moved into a group removed on the other side is ungrouped', M.task(r.chart, 't3').group, null);
    var ga = M.addGroup(S, { title: 'Mine' }), gb = M.addGroup(S, { title: 'Theirs' });
    var gm = M.reorder(ga.chart, 't1', 0, ga.id).chart;
    r = m3(S, gm, gb.chart);
    eq('merge: both add a group at once: both kept, no conflict', r.chart.groups.map(function (g) { return g.title; }).join(',') + '|' + keys(r), 'Discovery,Build,Mine,Theirs|');
    eq('merge: my task stays in my new group', r.chart.tasks[0].group, ga.id);

    // Review round 1: a chart that came out of a merge (other key order in
    // its records) used again as mine must not invent a conflict.
    var S3 = freeze(M.coerce({ v: 1, groups: [{ id: 'g1', title: 'A' }, { id: 'g2', title: 'B' }],
      tasks: [{ id: 't1', note: 'n1', start: '2026-10-01', group: 'g1' }, { id: 't2', note: 'n2', start: '2026-10-03' }] }).chart);
    var merged = m3(S3, M.moveTask(S3, 't2', 1).chart, M.setTask(S3, 't1', { color: 'rose' }).chart).chart;
    eq('merge: records coming out of a merge have the canonical shape', Object.keys(merged.groups[1]).join(','), 'id,title,color,_x');
    eq('merge: a merge result as mine, theirs removes an untouched group: no conflict', keys(m3(S3, merged, M.removeGroup(S3, 'g2').chart)), '');
    eq('merge: a merge result as base, mine removes an untouched group: no conflict', keys(m3(merged, M.removeGroup(merged, 'g2').chart, S3)), '');

    var withX = M.coerce(M.toData(S)).chart;
    withX.tasks[0]._x = { lane: 2 };
    r = m3(S, M.moveTask(S, 't1', 1).chart, withX);
    eq('merge: unknown keys from one side survive another edit', json(r.chart.tasks[0]._x) + '|' + keys(r), '{"lane":2}|');
    var objKeys = M.coerce({ v: 1, tasks: [{ id: 't1', note: 'n1', toString: 1, constructor: 'x', hasOwnProperty: 2 }] }).chart;
    var plain = M.coerce({ v: 1, tasks: [{ id: 't1', note: 'n1' }] }).chart;
    var threw = null;
    try { r = m3(objKeys, objKeys, plain); } catch (e) { threw = e; }
    ok('merge: unknown keys named like Object methods do not throw', threw === null, String(threw));
    eq('merge: and their removal on one side merges', threw ? '' : json(M.toData(r.chart)), '{"v":1,"tasks":[{"id":"t1","note":"n1"}]}');

    mine = M.removeTask(S, 't1').chart;
    theirs = M.setDeps(S, 't2', ['t1']).chart;
    r = m3(S, mine, theirs);
    eq('merge: a dep on a task removed on the other side is dropped', ids(r.chart) + '|' + r.chart.tasks[0].after.length, 't2,t3,t4|0');

    mine = M.setTask(S, 't1', { title: 'Refreshed A' }).chart;
    theirs = M.setTask(S, 't1', { title: 'Refreshed B' }).chart;
    r = m3(S, mine, theirs);
    eq('merge: titles never conflict, theirs wins', keys(r) + r.chart.tasks[0].title, 'Refreshed B');

    // The formulas the journal and saveOnce use (§9.1.5, §9.2).
    var A = M.moveTask(S, 't1', 2).chart;
    same('merge3(S, A, S) = A', M.toData(m3(S, A, S).chart), M.toData(A));
    var E = M.setTask(S, 't3', { color: 'violet' }).chart;
    same('merge3(S, S, E) = E', M.toData(m3(S, S, E).chart), M.toData(E));
    var Bc = M.setTask(A, 't2', { color: 'pink' }).chart;
    var AE = m3(S, A, E).chart;
    var BE = m3(A, Bc, AE);
    eq('merge3(A, B, A+E) = B+E: no conflicts', keys(BE), '');
    ok('merge3(A, B, A+E) = B+E: B and E both present', BE.chart.tasks[0].start === A.tasks[0].start &&
      BE.chart.tasks[1].color === 'pink' && BE.chart.tasks[2].color === 'violet');
    var clash = m3(A, M.setTask(A, 't3', { color: 'rose' }).chart, AE);
    eq('merge3: an in-flight commit clashing with the note conflicts', keys(clash), 't3.color');

    // Re-merge every case: charts read back from JSON, and charts that came
    // out of an earlier merge, must merge exactly like the originals.
    function rt(c) { return M.coerce(M.toData(c)).chart; }
    function sig(x) { return M.stable(M.toData(x.chart)) + '|' + keys(x) + '|' + json(x.remap); }
    var bad = { rt: [], mine: [], theirs: [], base: [] };
    cases.forEach(function (k, n) {
      var want = sig(k.res);
      if (sig(M.merge3(rt(k.b), rt(k.m), rt(k.t), k.o)) !== want) bad.rt.push(n);
      if (sig(M.merge3(k.b, M.merge3(k.b, k.m, k.b).chart, k.t, k.o)) !== want) bad.mine.push(n);
      if (sig(M.merge3(k.b, k.m, M.merge3(k.b, k.b, k.t).chart, k.o)) !== want) bad.theirs.push(n);
      if (sig(M.merge3(M.merge3(k.b, k.b, k.b).chart, k.m, k.t, k.o)) !== want) bad.base.push(n);
    });
    ok('merge matrix (' + cases.length + ' cases) gives the same result on JSON round-tripped charts', !bad.rt.length, json(bad.rt));
    ok('merge matrix gives the same result with a merge result as mine', !bad.mine.length, json(bad.mine));
    ok('merge matrix gives the same result with a merge result as theirs', !bad.theirs.length, json(bad.theirs));
    ok('merge matrix gives the same result with a merge result as base', !bad.base.length, json(bad.base));
  }

  /* ================================================================= undo */

  function undoSpec() {
    var c0 = freeze(example());
    var clock = 1000;
    var st = U.createStack({ cap: 100, now: function () { return clock; } });
    var r1 = M.moveTask(c0, 't1', 1); st.push({ label: 'Move 1', patches: r1.inverse });
    var r2 = M.moveTask(r1.chart, 't2', 2); st.push({ label: 'Move 2', patches: r2.inverse });
    eq('undo label is the newest entry', st.label('undo'), 'Move 2');
    var u = st.undo(r2.chart);
    same('undo reverts the newest change only', M.toData(u.chart), M.toData(r1.chart));
    eq('redo label after undo', st.label('redo'), 'Move 2');
    var u2 = st.undo(u.chart);
    same('undo again reaches the start', M.toData(u2.chart), M.toData(c0));
    ok('nothing left to undo', !st.canUndo() && st.undo(u2.chart) === null);
    var rd = st.redo(u2.chart);
    same('redo re-applies the oldest undone change', M.toData(rd.chart), M.toData(r1.chart));
    var rd2 = st.redo(rd.chart);
    same('redo again restores the latest chart', M.toData(rd2.chart), M.toData(r2.chart));
    st.undo(rd2.chart);
    ok('there is something to redo', st.canRedo());
    st.push({ label: 'Other', patches: M.moveTask(r1.chart, 't3', 1).inverse });
    ok('a new push clears redo', !st.canRedo());
    ok('an empty entry is not pushed', st.push({ label: 'nothing', patches: [] }) === false);

    var capped = U.createStack({ cap: 3 }), c = c0, charts = [c0];
    for (var i = 0; i < 5; i++) { var r = M.moveTask(c, 't1', 1); capped.push({ label: 'm' + i, patches: r.inverse }); c = r.chart; charts.push(c); }
    eq('cap keeps the newest entries', capped.size().undo, 3);
    var back = c;
    for (i = 0; i < 3; i++) back = capped.undo(back).chart;
    same('undoing the capped stack stops at the oldest kept state', M.toData(back), M.toData(charts[2]));

    // Coalescing: keyboard nudges within 800 ms merge.
    var co = U.createStack({ now: function () { return clock; } });
    c = c0;
    clock = 0;
    r = M.moveTask(c, 't1', 1); co.push({ label: 'Nudge', patches: r.inverse, coalesceKey: 'nudge:t1' }); c = r.chart;
    clock = 500;
    r = M.moveTask(c, 't1', 1); co.push({ label: 'Nudge', patches: r.inverse, coalesceKey: 'nudge:t1' }); c = r.chart;
    clock = 1400;   // 900 ms after the previous nudge: a new entry
    r = M.moveTask(c, 't1', 1); co.push({ label: 'Nudge', patches: r.inverse, coalesceKey: 'nudge:t1' }); c = r.chart;
    eq('nudges within 800 ms coalesce, a later one does not', co.size().undo, 2);
    var cu = co.undo(c).chart;
    eq('undo of the later nudge', cu.tasks[0].start, c0.tasks[0].start + 2);
    eq('undo of the coalesced pair', co.undo(cu).chart.tasks[0].start, c0.tasks[0].start);
    clock = 1300;
    r = M.moveTask(c0, 't1', 1); co.push({ label: 'a', patches: r.inverse, coalesceKey: 'k1' });
    r = M.moveTask(r.chart, 't2', 1); co.push({ label: 'b', patches: r.inverse, coalesceKey: 'k2' });
    eq('different coalesce keys do not merge', co.size().undo, 2);

    // Undo applies to the current chart, so an external merge survives.
    var mv = M.moveTask(c0, 't1', 3);
    var ext = U.createStack();
    ext.push({ label: 'Move', patches: mv.inverse });
    var theirs = M.setTask(c0, 't2', { color: 'sky' }).chart;
    var merged = M.merge3(c0, mv.chart, theirs).chart;
    var afterUndo = ext.undo(merged).chart;
    eq('undo after an external merge restores my task', afterUndo.tasks[0].start, c0.tasks[0].start);
    eq('undo after an external merge keeps the external change', afterUndo.tasks[1].color, 'sky');

    // Host effects are carried, not executed.
    var hs = U.createStack();
    var hp = { op: 'host', kind: 'toggleSubnote', args: { noteId: N1, subId: 's1', done: false } };
    hs.push({ label: 'Toggle', patches: [hp] });
    var hu = hs.undo(c0);
    ok('undo of a host entry leaves the chart alone', hu.chart === c0);
    eq('undo returns the host effect', hu.effects.length + ':' + hu.effects[0].kind, '1:toggleSubnote');
    hs.revert(hu);
    ok('a failed effect puts the entry back and does not touch redo', hs.canUndo() && !hs.canRedo() && hs.label('undo') === 'Toggle');
    var hu2 = hs.undo(c0);
    ok('the put-back entry is the same entry', hu2.entry === hu.entry);
    var hr = hs.redo(hu2.chart);
    eq('redo of a host entry returns the opposite effect', hr.effects[0].args.done, true);
    hs.undo(hr.chart);
    hs.revert(hs.undo(hr.chart) || null);
    hs.skip();
    ok('skip drops a stuck entry', !hs.canUndo());
    // A redo whose effect fails can be skipped too (review round 1).
    hs.push({ label: 'Toggle', patches: [hp] });
    var ru = hs.undo(c0), rr = hs.redo(ru.chart);
    hs.revert(rr);
    ok('a failed redo effect goes back on the redo stack', hs.canRedo() && hs.label('redo') === 'Toggle');
    hs.skip('redo');
    ok('skip("redo") drops a stuck redo entry', !hs.canRedo() && !hs.canUndo());
    hs.clear();
    ok('clear empties both stacks', !hs.canUndo() && !hs.canRedo());

    // M1 review round 3: an undo that the chart guards into a no-op (their
    // copy of the note wins) pushes nothing onto redo.
    var Sg = M.coerce({ v: 1, tasks: [{ id: 'tA', note: 'nA' }, { id: 'tB', note: 'nB' }] }).chart;
    var gs = U.createStack();
    var rmg = M.removeTask(Sg, 'tB');
    gs.push({ label: 'Remove', patches: rmg.inverse });
    var reAdded = M.merge3(Sg, rmg.chart, M.addTasks(M.removeTask(Sg, 'tB').chart, [{ note: 'nB', title: 'again' }]).chart).chart;
    var gu = gs.undo(reAdded);
    ok('a guarded undo leaves the chart as it was', gu && gu.chart === reAdded && gu.effects.length === 0);
    ok('a guarded undo pushes nothing onto redo', !gs.canRedo() && gs.size().redo === 0 && !gs.canUndo());
    ok('redo after a guarded undo has nothing to do', gs.redo(gu.chart) === null);
    gs.revert(gu);
    ok('revert of a guarded undo puts the entry back', gs.canUndo() && !gs.canRedo());
  }

  /* ================================================================ block */

  function blockSpec() {
    eq('INFO', B.INFO, 'synapse-gantt');
    eq('a plain note reads as none', B.read('# Just a note\n\nNo chart.').status, 'none');
    var rb = B.read(fix('region-basic.md'));
    eq('the example reads ok', rb.status, 'ok');
    eq('the example block key is the body key', rb.key, B.key(B.serialize(rb.chart)));
    eq('the key ignores whitespace outside strings', B.key('{"a": 1,\n "b":[1, 2]}'), B.key('{"a":1,"b":[1,2]}'));
    ok('the key keeps whitespace inside strings', B.key('{"a":"x  y"}') !== B.key('{"a":"x y"}'));
    ok('the key keeps escaped quotes', B.key('{"a":"x\\" y"}') === '{"a":"x\\" y"}');
    eq('hash of the empty string', B.hash(''), '811c9dc5');
    eq('hash of "a"', B.hash('a'), 'e40c292c');
    ok('hash differs for different text', B.hash('ab') !== B.hash('ba'));

    // Serialise idempotent after one pass; parse(serialize(parse(x))) = parse(x).
    Object.keys(FIX).sort().forEach(function (f) {
      var r = B.read(FIX[f]);
      if (r.status !== 'ok' && r.status !== 'future') return;
      var s1 = B.serialize(r.chart);
      var c2 = M.coerce(JSON.parse(s1)).chart;
      eq(f + ': parse(serialize(parse(x))) = parse(x)', canon(c2), canon(r.chart));
      eq(f + ': serialising twice gives identical bytes', B.serialize(c2), s1);
      ok(f + ': the fence body has one group or task per line', s1.split('\n').every(function (l) { return !/\{"id".*\{"id"/.test(l); }));
    });

    // Unknown keys byte-stable.
    var uk = fix('unknown-keys.md');
    var u1 = save(uk, {}), u2 = save(u1, {});
    eq('unknown keys: second save is byte-identical', u2, u1);
    ['"colorBy":"sparkle"', '"progressStyle":"confetti"', '"zoomHint":{"a":[1,2]}', '"__proto__":{"x":1}', '"owner":"ann"',
      '"meta":{"k":[true,null]}', '"progress":"manual","pct":40,"tags":["x","y"]', '"color":"chartreuse","startTime":"09:30"',
      '"theme":"dusk"', '"layout":{"lanes":[{"id":1}]}'].forEach(function (needle) {
      ok('unknown keys: ' + needle + ' survives', u1.indexOf(needle) >= 0, u1);
    });

    // Statuses.
    var cr = B.read(fix('crlf.md'));
    eq('CRLF: reads ok', cr.status, 'ok');
    eq('CRLF: region is found', cr.region.text.indexOf('```synapse-gantt'), 0);
    var crs = save(fix('crlf.md'), {});
    eq('CRLF: bytes before the region untouched', crs.slice(0, cr.region.start), fix('crlf.md').slice(0, cr.region.start));
    eq('CRLF: bytes after the region untouched', crs.slice(crs.length - (fix('crlf.md').length - cr.region.end)), fix('crlf.md').slice(cr.region.end));
    var un = B.read(fix('unclosed.md'));
    eq('unclosed: malformed', un.status + '/' + un.reason, 'malformed/unclosed');
    ok('unclosed: the span stops before the first blank line', un.region.text.slice(-6) === '"tasks":[]}'.slice(-6) && un.region.text.indexOf('## Notes') < 0);
    var unSp = B.splice(fix('unclosed.md'), 'X');
    ok('unclosed: a forced splice keeps the prose below', unSp.indexOf('The prose under a damaged block survives.') > 0 && unSp.indexOf('\nX\n') > 0);
    var fu = B.read(fix('future.md'));
    eq('future: status and reason', fu.status + '/' + fu.reason, 'future/v2');
    ok('future: the chart is readable and keeps unknown keys', fu.chart && fu.chart.v === 2 && fu.chart.tasks[0]._x.lanes === 3 && json(fu.chart._x.swimlanes) === '["a"]');
    eq('malformed JSON', B.read(fix('malformed.md')).status + '/' + B.read(fix('malformed.md')).reason, 'malformed/json');
    eq('malformed not an object', B.read(fix('malformed-array.md')).reason, 'not-object');
    eq('malformed version', B.read(fix('malformed-version.md')).reason, 'version');
    ok('malformed: no chart but a region to repair', B.read(fix('malformed.md')).chart === null && B.read(fix('malformed.md')).region !== null);
    var ne = B.read(fix('nested-fence.md'));
    eq('nested in a wider fence: not a chart', ne.status + '/' + ne.shadowed, 'none/1');
    eq('indented 4+ spaces: not a chart', B.read(fix('indented.md')).status, 'none');
    eq('indented 3 spaces: a chart', B.read(fix('three-space.md')).status, 'ok');
    var two = B.read(fix('two-blocks.md'));
    eq('two blocks: extra is reported', two.extra, 1);
    eq('two blocks: the first is used', two.chart.tasks[0].note, 'n-alpha');
    var tws = save(fix('two-blocks.md'), { t1: { done: 1, total: 2 } });
    ok('two blocks: a splice touches only the first', tws.indexOf('"note":"n-other"') > 0 && tws.indexOf('Tail.') > 0);
    var cj = fix('cjk-emoji.md'), cjs = save(cj, { t1: { done: 2, total: 3 } });
    eq('CJK and emoji titles round-trip byte-exact', cjs, cj);
    eq('CJK and emoji titles parse', B.read(cj).chart.tasks[0].title, '用户访谈 👥');

    // Splice is byte-exact outside the region: literal expectations, spelled
    // out per fixture rather than derived from the detected offsets.
    var INTRO = 'Launch plan for the Q4 release. Owners are in each task note.';
    [
      ['region-basic.md', INTRO + '\n\n', ''],
      ['region-embed-mirror.md', INTRO + '\n\n', '\n\nNotes below the chart.'],
      ['region-crlf.md', INTRO + '\r\n\r\n', '\r\n\r\nTail line.\r\n'],
      ['region-no-blank.md', 'Some text right above the fence:\n', '\nAnd after.'],
      ['region-bold-above-ungrouped.md', 'Intro.\n\n- **Notes**\n', ''],
      ['region-foreign-link-adjacent.md', 'Intro.\n\n- [Not on this chart](synapseresource://note/other-9?via=gantt) · 2026-01-01\n', ''],
      ['two-blocks.md', '# Two charts\n\n', null],
      ['unclosed.md', '# Closing fence deleted\n\n', '\n\n## Notes\n\nThe prose under a damaged block survives.'],
      ['unclosed-later-fence.md', 'Intro\n\n', '\n\nMy important prose.\n\n```js\ncode()\n```\nTail'],
      ['malformed-mirror.md', 'Intro.\n\n', ''],
      ['fence-attr-info.md', null, '\n\nTail.\n']
    ].forEach(function (x) {
      var out = B.splice(fix(x[0]), '<<REGION>>');
      var at = out.indexOf('<<REGION>>');
      if (x[1] !== null) eq(x[0] + ': splice keeps the bytes before the region', out.slice(0, at), x[1]);
      if (x[2] !== null) eq(x[0] + ': splice keeps the bytes after the region', out.slice(at + 10), x[2]);
    });
    Object.keys(FIX).sort().forEach(function (f) {
      var text = FIX[f], r = B.read(text);
      if (!r.region) return;
      eq(f + ': splicing the detected region back is the identity', B.splice(text, r.region.text), text);
    });
    eq('splice appends after a blank line', B.splice('Body', 'R'), 'Body\n\nR');
    eq('splice appends after a trailing newline', B.splice('Body\n', 'R'), 'Body\n\nR');
    eq('splice appends after a trailing blank line', B.splice('Body\n\n', 'R'), 'Body\n\nR');
    eq('splice into an empty note', B.splice('', 'R'), 'R');

    // Line grammar.
    eq('etext keeps balanced brackets', B.etext('Fix [bug] **now**'), 'Fix [bug] **now**');
    eq('etext replaces an unmatched ]', B.etext('a ] b'), 'a ］ b');
    eq('etext replaces an unclosed [', B.etext('[draft'), '［draft');
    eq('etext handles nesting', B.etext('[a [b] c'), '［a [b] c');
    eq('etext replaces line breaks', B.etext('one\r\ntwo\nthree\rfour'), 'one two three four');
    var pl = B.parseLine('  - ◆ [x [y] z](synapseresource://note/abc-1?via=gantt) · 2026-10-01 → 2026-10-02 · 1/2');
    eq('parseLine: a grouped milestone line', pl && pl.kind + '|' + pl.id + '|' + pl.title + '|' + pl.milestone, 'sub|abc-1|x [y] z|true');
    eq('parseLine: rest must be exact', B.parseLine('- [x](synapseresource://note/a?via=gantt) · 2026-10-01 extra'), null);
    eq('parseLine: three-space indent is not a subLine', B.parseLine('   - [x](synapseresource://note/a?via=gantt)'), null);
    eq('parseLine: a group line', B.parseLine('- **A ** B**').title, 'A ** B');
    eq('parseLine: a plain bullet', B.parseLine('- note to self'), null);
    eq('parseLine: an unscheduled line with progress', B.parseLine('- [x](synapseresource://note/a?via=gantt) · 3/5').kind, 'top');
    eq('parseLine: a title with U+2028 still parses', B.parseLine('- [a b](synapseresource://note/a?via=gantt)').title, 'a b');
    ok('the embed line matches the grammar', B.isEmbedLine(B.embedLine()));

    // Fences per CommonMark (review round 1).
    var fa = B.read(fix('fence-attr-info.md'));
    eq('fence: code blocks with attribute info strings do not hide the chart', fa.status + '/' + fa.shadowed, 'ok/0');
    eq('fence: the chart after them is found', fa.chart.tasks[0].note, 'n-alpha');
    ok('fence: saving leaves those code blocks alone', save(fix('fence-attr-info.md'), {}).indexOf('```python title="x"\nprint(1)\n```\n\n~~~js {linenos=true}\na = `tick`\n~~~\n\n') === '# Code with attribute info strings\n\n'.length);
    var fd = B.read(fix('fence-doc-info.md'));
    eq('fence: a chart inside a documentation fence with an info string is not a chart', fd.status + '/' + fd.shadowed, 'none/1');
    eq('fence: the first word of the info string names the chart', B.read(fix('fence-info-words.md')).status, 'ok');
    eq('fence: a backtick in a backtick fence info string is not an opening', B.opening('```js `x`'), null);
    eq('fence: a backtick in a tilde fence info string is fine', B.opening('~~~js `x`').info, 'js');
    eq('fence: info string words', B.opening('   ````  synapse-gantt  x=1').info + '|' + B.opening('````  synapse-gantt  x=1').len, 'synapse-gantt|4');
    eq('fence: four spaces is not a fence', B.opening('    ```synapse-gantt'), null);

    // A chart fence closed by a later bare fence is bounded at the first blank line.
    var ul = B.read(fix('unclosed-later-fence.md'));
    eq('broken fence: read as unclosed', ul.status + '/' + ul.reason, 'malformed/unclosed');
    ok('broken fence: the region stops before the prose', ul.region.text.indexOf('My important prose') < 0 && /"tasks":\[\]\}$/.test(ul.region.text));
    var ulRep = B.splice(fix('unclosed-later-fence.md'), 'REPAIRED');
    eq('broken fence: a forced Repair keeps the prose, the code block and the tail', ulRep, 'Intro\n\nREPAIRED\n\nMy important prose.\n\n```js\ncode()\n```\nTail');
    eq('a chart body with a blank line that parses is still ok', B.read('```synapse-gantt\n{"v":1,\n\n"tasks":[]}\n```').status, 'ok');
    // Review round 2: a real block with a JSON typo and a blank line keeps
    // its whole closed span, so Repair leaves no JSON tail or stray fence.
    var bt = B.read(fix('malformed-blank-typo.md'));
    eq('JSON typo after a blank line: malformed, not unclosed', bt.status + '/' + bt.reason, 'malformed/json');
    ok('JSON typo after a blank line: the region is the whole closed fence', /\n```$/.test(bt.region.text));
    var btRep = B.splice(fix('malformed-blank-typo.md'), B.region(M.empty(), {}));
    eq('JSON typo after a blank line: Repair leaves the text after intact', btRep, 'Intro\n\n```synapse-gantt\n{"v":1}\n```\n\nAfter para.');
    ok('JSON typo after a blank line: after Repair nothing is left open', !B.read(btRep).openAtEnd && B.scan(btRep).spans.length === 1);
    eq('a heading after a blank line counts as prose', B.read('```synapse-gantt\n{"v":1,\n\n## Notes\n```').reason, 'unclosed');
    eq('a whitespace-only line counts as blank', B.read('```synapse-gantt\n{"v":1,\n  \nProse\n```').region.text, '```synapse-gantt\n{"v":1,');
    eq('the rule works on CRLF notes', B.read('```synapse-gantt\r\n{"v":1,\r\n"tasks":[]}\r\n\r\nProse.\r\n\r\n```\r\nTail').region.text, '```synapse-gantt\r\n{"v":1,\r\n"tasks":[]}');
    // Documented limit (§5.5): prose directly under the JSON with no blank
    // line stays inside a span that a later bare fence closes.
    ok('documented limit: prose with no blank line stays in the span', B.read('```synapse-gantt\n{"v":1,"tasks":[]}\nProse right under\n```js\nx\n```\nTail').region.text.indexOf('Prose right under') > 0);

    // M1 review round 3. Hand-edited JSON (unquoted keys, // comments,
    // single quotes) after a blank line is JSON-looking, so a closed block
    // with such a typo keeps its whole span.
    var uq = B.read(fix('malformed-unquoted-key.md'));
    eq('unquoted key after a blank line: malformed json, not unclosed', uq.status + '/' + uq.reason, 'malformed/json');
    var uqRep = B.splice(fix('malformed-unquoted-key.md'), B.region(M.empty(), {}));
    eq('unquoted key after a blank line: Repair leaves no tail or stray fence', uqRep, 'Intro\n\n```synapse-gantt\n{"v":1}\n```\n\nAfter para.\n');
    ok('unquoted key after a blank line: nothing is left open after Repair', !B.read(uqRep).openAtEnd && B.scan(uqRep).spans.length === 1);
    [' tasks:[', "'tasks': [", '// a comment', '  $x: {', 'tasks : null'].forEach(function (l) {
      eq('JSON-looking after a blank line: ' + JSON.stringify(l), B.read('```synapse-gantt\n{"v":1,\n\n' + l + '\n```').reason, 'json');
    });
    ['Note: remember this', 'Summary:', '1. First step', '2) Second', '[docs](https://example.com) are here', '- item', '* item',
      '[ ] a bare checkbox', '[x] done', '2026 goals', '3rd step', '2026年计划'].forEach(function (l) {
      eq('prose after a blank line: ' + JSON.stringify(l), B.read('```synapse-gantt\n{"v":1,\n\n' + l + '\n```').reason, 'unclosed');
    });
    // B.jsonish directly (review round 1).
    [['{"v":1,', true], ['"tasks":[', true], [']}', true], ['-3,', true], ['1e5,', true], ['12,', true], ['true,', true], ['[ ]', true], ['[]', true], ['// c', true],
      ['tasks: [', true], ['2026 goals', false], ['3rd', false], ['3 eggs', false], ['10 Easy wins', false], ['5 extra tasks', false], ['2 +more', false], ['7 -ish', false], ['[ ] task', false], ['[X] task', false], ['1. step', false], ['[a](b)', false], ['Note: x', false], ['Prose', false]
    ].forEach(function (c) { eq('jsonish ' + JSON.stringify(c[0]), B.jsonish(c[0]), c[1]); });
    // M2 review round 2: digits then a word starting with e/E/+/- are prose.
    var dw = B.read(fix('unclosed-digit-word.md'));
    eq('digits then a word after a deleted close: read as unclosed', dw.status + '/' + dw.reason, 'malformed/unclosed');
    eq('digits then a word after a deleted close: Repair keeps the lines', B.splice(fix('unclosed-digit-word.md'), 'REPAIRED'), 'Intro\n\nREPAIRED\n\n3 eggs\n10 Easy wins\n```\ncode\n```\n');
    // A deleted closing fence followed by a numbered list: the list is prose.
    var nl = B.read(fix('unclosed-numbered-list.md'));
    eq('numbered list after a deleted close: read as unclosed', nl.status + '/' + nl.reason, 'malformed/unclosed');
    var nlRep = B.splice(fix('unclosed-numbered-list.md'), 'REPAIRED');
    eq('numbered list after a deleted close: Repair keeps the list', nlRep, 'Intro\n\nREPAIRED\n\n1. First step\n2. Second step\n```\ncode\n```\n');
    // An interior blank line inside the JSON: the cut is the last blank line
    // before the first prose line, not the first blank line.
    var ib2 = B.read(fix('unclosed-interior-blank.md'));
    eq('interior blank line: read as unclosed', ib2.status + '/' + ib2.reason, 'malformed/unclosed');
    eq('interior blank line: the region keeps the whole JSON', ib2.region.text, '```synapse-gantt\n{"v":1,\n\n"tasks":[{"id":"t1","note":"n1"}]}');
    var ibRep = B.splice(fix('unclosed-interior-blank.md'), 'REPAIRED');
    eq('interior blank line: Repair leaves no JSON tail', ibRep, 'Intro\n\nREPAIRED\n\nProse here.\n```\ncode\n```\n');
    eq('interior blank line: a truly unclosed fence is cut the same way', B.read('A\n\n```synapse-gantt\n{"v":1,\n\n"tasks":[]}\n\nProse.\n').region.text, '```synapse-gantt\n{"v":1,\n\n"tasks":[]}');
    eq('interior blank line: with no prose at all the cut stays at the first blank', B.read('```synapse-gantt\n{"v":1,\n\n"tasks":[]}\n').region.text, '```synapse-gantt\n{"v":1,');

    // A malformed block's old mirror is part of the region, so Repair
    // replaces it instead of leaving a second mirror.
    var mm = B.read(fix('malformed-mirror.md'));
    eq('malformed: the old mirror is in the region', mm.status + '|' + mm.region.text.indexOf('- [Alpha]'), 'malformed|0');
    var fixedChart = M.coerce({ v: 1, tasks: [{ id: 't1', note: 'n-alpha', title: 'Alpha', start: '2026-10-01', end: '2026-10-03' }] }).chart;
    var repaired = B.splice(fix('malformed-mirror.md'), B.region(fixedChart, SMALL_SUMS));
    eq('malformed: after Repair there is one mirror', count(repaired, '](synapseresource://note/n-alpha?via=gantt)'), 1);
    eq('malformed: Repair keeps the text above', repaired.indexOf('Intro.\n\n- [Alpha]'), 0);

    // Progress counts in the mirror are safe integers only.
    var one = M.coerce({ v: 1, tasks: [{ id: 't1', note: 'a', title: 'A' }] }).chart;
    eq('mirror: an infinite total writes no progress', B.mirror(one, { t1: { done: 1, total: Infinity } }), '- [A](synapseresource://note/a?via=gantt)');
    eq('mirror: a huge total writes no progress', B.mirror(one, { t1: { done: 1, total: 1e21 } }), '- [A](synapseresource://note/a?via=gantt)');
    eq('mirror: done is clamped to the total', B.mirror(one, { t1: { done: 9, total: 4 } }), '- [A](synapseresource://note/a?via=gantt) · 4/4');
    eq('mirror: a fractional done counts as 0', B.mirror(one, { t1: { done: 1.5, total: 4 } }), '- [A](synapseresource://note/a?via=gantt) · 0/4');
  }

  /* ======================================================= region fixtures */

  var SMALL_SUMS = { t1: { done: 1, total: 2 } };
  var UNS_SUMS = { t2: { done: 3, total: 5 }, t4: { done: 2, total: 4 }, t5: { done: 1, total: 1 } };

  function regionFixtureSpec() {
    var EMB = B.embedLine();
    var CASES = {
      'region-basic.md': { sums: EX_SUMS, check: function (x, r, s1) {
        eq('region-basic: saves byte-exact', s1, x);
        eq('region-basic: region starts at the mirror', r.region.text.indexOf('- **Discovery**\n'), 0);
      } },
      'region-embed-mirror.md': { sums: EX_SUMS, check: function (x, r, s1) {
        eq('region-embed-mirror: region starts at the embed line', r.region.text.indexOf(EMB + '\n\n- **Discovery**'), 0);
        eq('region-embed-mirror: saves byte-exact', s1, x);
      } },
      'region-embed-nomirror.md': { sums: EX_SUMS, check: function (x, r, s1, s2) {
        eq('region-embed-nomirror: region starts at the embed line', r.region.text.indexOf(EMB + '\n\n```'), 0);
        eq('region-embed-nomirror: exactly one embed line', count(s2, EMB), 1);
        eq('region-embed-nomirror: saves byte-exact', s1, x);
      } },
      'region-embed-empty.md': { sums: {}, check: function (x, r, s1, s2) {
        eq('region-embed-empty: region starts at the embed line', r.region.text.indexOf(EMB), 0);
        eq('region-embed-empty: exactly one embed line', count(s2, EMB), 1);
        eq('region-embed-empty: saves byte-exact', s1, x);
      } },
      'region-embed-off.md': { sums: EX_SUMS, check: function (x, r, s1) {
        eq('region-embed-off: the embed line is in the region', r.region.text.indexOf(EMB), 0);
        eq('region-embed-off: the save removes it', count(s1, EMB), 0);
        eq('region-embed-off: nothing else changes', s1, x.replace(EMB + '\n\n', ''));
      } },
      'region-bold-above-ungrouped.md': { sums: SMALL_SUMS, check: function (x, r, s1) {
        eq('region-bold-above-ungrouped: region starts at the first task', r.region.text.indexOf('- [Alpha]'), 0);
        ok('region-bold-above-ungrouped: the bold bullet is kept', s1.indexOf('- **Notes**\n- [Alpha]') > 0);
        eq('region-bold-above-ungrouped: saves byte-exact', s1, x);
      } },
      'region-bold-above-group.md': { sums: EX_SUMS, check: function (x, r, s1) {
        eq('region-bold-above-group: region starts at the group line', r.region.text.indexOf('- **Discovery**'), 0);
        eq('region-bold-above-group: saves byte-exact', s1, x);
      } },
      'region-bold-mirror-off.md': { sums: SMALL_SUMS, check: function (x, r, s1) {
        eq('region-bold-mirror-off: region is the fence only', r.region.text.indexOf('```'), 0);
        eq('region-bold-mirror-off: nothing swallowed', s1, x);
      } },
      'region-foreign-links.md': { sums: {}, check: function (x, r, s1) {
        eq('region-foreign-links: region is the fence only', r.region.text.indexOf('```'), 0);
        eq('region-foreign-links: nothing swallowed', s1, x);
      } },
      'region-foreign-links-milestones.md': { sums: {}, check: function (x, r, s1) {
        eq('region-foreign-links (note-less milestones): region is the fence only', r.region.text.indexOf('```'), 0);
        eq('region-foreign-links (note-less milestones): nothing swallowed', s1, x);
      } },
      'region-foreign-link-adjacent.md': { sums: SMALL_SUMS, check: function (x, r, s1) {
        eq('region-foreign-link-adjacent: the run stops at the foreign link', r.region.text.indexOf('- [Alpha]'), 0);
        eq('region-foreign-link-adjacent: saves byte-exact', s1, x);
      } },
      'region-edited-line.md': { sums: EX_SUMS, check: function (x, r, s1) {
        eq('region-edited-line: the run stops below the edited line', r.region.text.indexOf('- **Build**'), 0);
        var keep = x.slice(0, r.region.start);
        ok('region-edited-line: the edited line and the lines above are kept', keep.indexOf('(blocked on legal)\n') > 0 && keep.indexOf('- **Discovery**') > 0);
        eq('region-edited-line: a fresh mirror is written below', s1, keep + B.region(r.chart, EX_SUMS));
      } },
      'region-edited-date.md': { sums: EX_SUMS, check: function (x, r, s1) {
        eq('region-edited-date: the line still matches', r.region.text.indexOf('- **Discovery**'), 0);
        eq('region-edited-date: regenerated from the JSON', s1, fix('region-basic.md'));
      } },
      'region-edited-line-embed.md': { sums: EX_SUMS, check: function (x, r, s1, s2) {
        ok('region-edited-line-embed: the old embed line is outside', r.embedOutside);
        eq('region-edited-line-embed: one embed line after the first save', count(s1, EMB), 1);
        eq('region-edited-line-embed: one embed line after the second save', count(s2, EMB), 1);
      } },
      'region-prose-split.md': { sums: EX_SUMS, check: function (x, r, s1) {
        eq('region-prose-split: the run stops at the prose', r.region.text.indexOf('- **Build**'), 0);
        ok('region-prose-split: the prose and the lines above are kept', s1.indexOf('- **Discovery**') < s1.indexOf('I moved Build') &&
          s1.indexOf('I moved Build') < s1.lastIndexOf('- **Discovery**'));
      } },
      'region-escaped-title.md': { sums: {}, check: function (x, r, s1) {
        eq('region-escaped-title: saves byte-exact', s1, x);
        eq('region-escaped-title: region starts at the first line', r.region.text.indexOf('- [Fix [bug] **now**]'), 0);
        ok('region-escaped-title: no backslashes', r.region.text.indexOf('\\') < 0);
        var mirror = r.region.text.split('\n\n')[0].split('\n');
        eq('region-escaped-title: six mirror lines', mirror.length, 6);
        ok('region-escaped-title: every line parses', mirror.every(function (l) { return B.parseLine(l) !== null; }));
        ok('region-escaped-title: unbalanced brackets are fullwidth', x.indexOf('[a ］ b]') > 0 && x.indexOf('[［draft]') > 0 && x.indexOf('Group ］ [x]') > 0);
      } },
      'region-empty-group.md': { sums: {}, check: function (x, r, s1) {
        eq('region-empty-group: saves byte-exact', s1, x);
        ok('region-empty-group: no line for the empty group', s1.indexOf('- **Empty**') < 0);
      } },
      'region-unscheduled.md': { sums: UNS_SUMS, check: function (x, r, s1) {
        eq('region-unscheduled: saves byte-exact', s1, x);
        var mirror = r.region.text.split('\n\n')[0];
        eq('region-unscheduled: five mirrored tasks', mirror.split('\n').length, 5);
        ok('region-unscheduled: note-less milestones and their group are not mirrored', mirror.indexOf('Freeze') < 0 && mirror.indexOf('bare milestone') < 0);
      } },
      'region-crlf.md': { sums: EX_SUMS, check: function (x, r, s1) {
        eq('region-crlf: region starts at the mirror', r.region.text.indexOf('- **Discovery**\r\n'), 0);
        eq('region-crlf: bytes before untouched', s1.slice(0, r.region.start), x.slice(0, r.region.start));
        ok('region-crlf: bytes after untouched', s1.slice(-('\r\n\r\nTail line.\r\n').length) === '\r\n\r\nTail line.\r\n');
      } },
      'region-no-blank.md': { sums: SMALL_SUMS, check: function (x, r, s1) {
        eq('region-no-blank: region is the fence only', r.region.text.indexOf('```'), 0);
        ok('region-no-blank: text around is kept', s1.indexOf('Some text right above the fence:\n') === 0 && /\nAnd after\.$/.test(s1));
        // Mirror-shaped lines and an embed line sitting directly on the fence
        // (no blank line) are user text: step 1 of the detection.
        var glued = x.replace('Some text right above the fence:\n',
          EMB + '\n- [Alpha](synapseresource://note/n-alpha?via=gantt) · 2026-10-01 → 2026-10-03 · 1/2\n- [Beta](synapseresource://note/n-beta?via=gantt) · 2026-10-05\n');
        var gr = B.read(glued);
        eq('region-no-blank: lines glued to the fence are not the region', gr.region.text.indexOf('```'), 0);
        ok('region-no-blank: a glued embed line counts as outside', gr.embedOutside);
        var g1 = save(glued, SMALL_SUMS);
        ok('region-no-blank: glued lines are kept by the first save', g1.indexOf(glued.slice(0, gr.region.start)) === 0);
        // The fresh mirror now sits under the glued grammar lines, so the
        // second read joins them (D21: matching lines are regenerated). It
        // settles on the second save; the embed line (not grammar) stays.
        var g2 = save(g1, SMALL_SUMS);
        eq('region-no-blank: glued note settles after two saves', save(g2, SMALL_SUMS), g2);
        ok('region-no-blank: the glued embed line and the text around survive', count(g2, EMB) === 1 && g2.indexOf('Intro') < 0 &&
          g2.indexOf(EMB + '\n- [Alpha]') === 0 && /\nAnd after\.$/.test(g2), g2);
        eq('region-no-blank: exactly one copy of each mirror line remains', count(g2, '](synapseresource://note/n-alpha?via=gantt)'), 1);
      } },
      'region-embed-stranded.md': { sums: EX_SUMS, check: function (x, r, s1) {
        ok('region-embed-stranded: the embed line is outside', r.embedOutside);
        eq('region-embed-stranded: it stays and none is added', count(s1, EMB), 1);
        eq('region-embed-stranded: saves byte-exact', s1, x);
      } }
    };

    Object.keys(FIX).filter(function (f) { return /^region-/.test(f); }).forEach(function (f) {
      ok('region fixture ' + f + ' has a case', !!CASES[f]);
    });
    ['region-basic', 'region-embed-mirror', 'region-embed-nomirror', 'region-embed-empty', 'region-embed-off',
      'region-bold-above-ungrouped', 'region-bold-above-group', 'region-bold-mirror-off', 'region-foreign-links',
      'region-foreign-link-adjacent', 'region-edited-line', 'region-edited-date', 'region-edited-line-embed',
      'region-prose-split', 'region-escaped-title', 'region-empty-group', 'region-unscheduled', 'region-crlf',
      'region-no-blank', 'region-embed-stranded'].forEach(function (n) {
      ok('the §5.6 fixture ' + n + ' exists', (n + '.md') in FIX);
    });

    Object.keys(CASES).forEach(function (f) {
      var x = fix(f), r = B.read(x);
      eq(f + ': reads ok', r.status, 'ok');
      var s1 = save(x, CASES[f].sums), s2 = save(s1, CASES[f].sums);
      eq(f + ': the second save gives identical bytes', s2, s1);
      ok(f + ': the region never ends with a newline', !/\n$/.test(B.read(s1).region.text));
      CASES[f].check(x, r, s1, s2);
    });

    // The §5.2 example as written in the plan (hand-ordered keys) settles
    // after one save: only the fence body changes, to canonical order.
    var v = fix('example-verbatim.md'), vr = B.read(v), vs = save(v, EX_SUMS);
    same('example-verbatim: same chart as region-basic', M.toData(vr.chart), M.toData(B.read(fix('region-basic.md')).chart));
    eq('example-verbatim: one save gives the canonical text', vs, fix('region-basic.md') + '\n');
    eq('example-verbatim: a second save is byte-identical', save(vs, EX_SUMS), vs);
  }

  /* ======================================================== property test */

  function mulberry32(a) {
    return function () {
      a |= 0; a = (a + 0x6D2B79F5) | 0;
      var t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  var TITLES = ['Plan', 'Fix [bug] **now**', 'a ] b', '[draft', '◆ diamond first', '设计评审', 'Launch 🚀', '',
    'x\ny', 'tab\there', '[[nested]]', ']', '[', '**bold**', 'Q4 · 3/5', 'a](synapseresource://note/zz?via=gantt)',
    'ends with **', 'line\r\nbreak', '  spaced  '];

  function genChart(rng, n) {
    function int(a, b) { return a + Math.floor(rng() * (b - a + 1)); }
    function pick(list) { return list[int(0, list.length - 1)]; }
    var c = M.empty();
    var ng = int(0, 4);
    for (var g = 0; g < ng; g++) c.groups.push({ id: 'g' + (g + 1), title: pick(TITLES), color: rng() < 0.3 ? pick(M.COLORS) : null, _x: {} });
    var nt = int(0, 12), base = P('2026-01-01');
    for (var i = 0; i < nt; i++) {
      var kind = pick(['ranged', 'oneday', 'oneday-end', 'unsched', 'ms-note', 'ms-bare', 'ms-unsched']);
      var s = base + int(0, 700), t = {
        id: 't' + (i + 1).toString(36), note: kind === 'ms-bare' ? null : 'n' + n + '-' + i + '-' + Math.floor(rng() * 1e6).toString(36),
        title: pick(TITLES), start: null, end: null, group: ng && rng() < 0.6 ? 'g' + int(1, ng) : null,
        color: rng() < 0.2 ? pick(M.COLORS) : null, milestone: /^ms/.test(kind), after: [],
        progress: rng() < 0.1 ? pick(M.SOURCES) : null, _x: rng() < 0.1 ? { extra: int(0, 9) } : {}
      };
      if (kind === 'ranged') { t.start = s; t.end = s + int(1, 60); }
      else if (kind === 'oneday' || kind === 'ms-note' || kind === 'ms-bare') t.start = s;
      else if (kind === 'oneday-end') { t.start = s; t.end = s; }
      if (i > 0 && rng() < 0.3) t.after = [c.tasks[int(0, i - 1)].id];
      c.tasks.push(t);
    }
    c.settings.embed = rng() < 0.5;
    c.settings.mirror = rng() < 0.75;
    if (rng() < 0.3) c.settings.progressSource = pick(M.SOURCES);
    if (rng() < 0.2) c.settings.holidays = ['2026-12-25'];
    if (rng() < 0.2) c.settings.weekStart = int(0, 6);
    if (rng() < 0.1) c._x = { future: { k: int(0, 3) } };
    return c;
  }

  function genSums(rng, c) {
    var s = {};
    c.tasks.forEach(function (t) {
      if (rng() < 0.2) return;
      var total = Math.floor(rng() * 11);
      s[t.id] = { done: Math.floor(rng() * (total + 1)), total: total };
    });
    return s;
  }

  function genPrefix(rng, c, embedOutside) {
    function int(a, b) { return a + Math.floor(rng() * (b - a + 1)); }
    var noted = c.tasks.filter(function (t) { return t.note; });
    var kinds = ['prose', 'bold', 'links', 'foreign', 'foreign-sub', 'foreign-group'];
    if (noted.length) kinds.push('inchart');
    var pieces = [], k = int(0, 4);
    for (var i = 0; i < k; i++) {
      var kind = kinds[int(0, kinds.length - 1)];
      var fid = 'zz-' + int(0, 99);
      if (kind === 'prose') pieces.push('Some prose about the plan.');
      else if (kind === 'bold') pieces.push('- **Notes**');
      else if (kind === 'links') pieces.push('- [Docs](https://example.com)\n- [More](https://example.com/2)');
      else if (kind === 'foreign') pieces.push('- [Other](synapseresource://note/' + fid + '?via=gantt) · 2026-01-01');
      else if (kind === 'foreign-sub') pieces.push('  - [Other](synapseresource://note/' + fid + '?via=gantt) · 1/2');
      else if (kind === 'foreign-group') pieces.push('- **Theirs**\n  - [Other](synapseresource://note/' + fid + '?via=gantt)');
      else pieces.push('- [Mine](synapseresource://note/' + noted[int(0, noted.length - 1)].note + '?via=gantt)\nA prose line.');
    }
    if (embedOutside) pieces.splice(int(0, pieces.length), 0, B.embedLine() + '\nText under my embed.');
    if (!pieces.length) return '';
    return pieces.join('\n') + '\n\n';
  }

  function checkInvariant(label, c, sums, embedOutside, prefix, fail) {
    var r = B.region(c, sums, { embedOutside: embedOutside });
    if (/\n$/.test(r)) return fail(label, 'region ends with a newline');
    var text = prefix + r, rd = B.read(text);
    if (rd.status !== 'ok') return fail(label, 'status ' + rd.status);
    if (!rd.region || rd.region.text !== r) return fail(label, 'region mismatch\n--- written ---\n' + r + '\n--- detected ---\n' + (rd.region && rd.region.text) + '\n--- prefix ---\n' + prefix);
    var hasEmbed = prefix.indexOf('synapseresource://app/' + GT.APP_UUID) >= 0;
    if (rd.embedOutside !== hasEmbed) return fail(label, 'embedOutside ' + rd.embedOutside + ', prefix has embed ' + hasEmbed);
    if (canon(rd.chart) !== canon(c)) return fail(label, 'chart mismatch\n' + canon(rd.chart) + '\n' + canon(c));
    if (B.splice(text, r) !== text) return fail(label, 'splice of the same region changed the note');
    var other = B.region(M.empty(), {}, {});
    if (B.splice(text, other) !== prefix + other) return fail(label, 'splice changed the prefix');
    var s1 = B.serialize(c);
    if (B.serialize(M.coerce(JSON.parse(s1)).chart) !== s1) return fail(label, 'serialise not idempotent');
    return true;
  }

  function propertySpec() {
    var seed = typeof global.GT_SEED === 'number' && isFinite(global.GT_SEED) ? global.GT_SEED : (Date.now() % 2147483647);
    var failures = 0, first = '';
    function fail(label, why) {
      failures++;
      if (!first) first = label + ': ' + why;
      return false;
    }

    // Every region-* fixture's chart, with and without an outside embed.
    var fixtureRuns = 0;
    Object.keys(FIX).filter(function (f) { return /^region-/.test(f); }).forEach(function (f) {
      var c = B.read(FIX[f]).chart;
      if (!c) return;
      c = M.coerce(M.toData(c)).chart;
      var rng = mulberry32(fixtureRuns + 7);
      [false, true].forEach(function (eo) {
        for (var k = 0; k < 6; k++) {
          fixtureRuns++;
          checkInvariant(f + ' embedOutside=' + eo + ' #' + k, c, genSums(rng, c), eo, genPrefix(rng, c, eo), fail);
        }
      });
    });
    ok('region invariant holds for every region-* fixture chart (' + fixtureRuns + ' runs)', failures === 0, first);

    failures = 0; first = '';
    var rng = mulberry32(seed), N = 500, stats = { mirror: 0, embed: 0, bareMs: 0, emptyGroup: 0 };
    for (var n = 0; n < N; n++) {
      var c0 = genChart(rng, n);
      var c = M.coerce(M.toData(c0)).chart;
      var eo = rng() < 0.5;
      if (c.settings.mirror && c.tasks.some(function (t) { return t.note; })) stats.mirror++;
      if (c.settings.embed && !eo) stats.embed++;
      if (c.tasks.some(function (t) { return !t.note; })) stats.bareMs++;
      if (c.groups.some(function (g) { return !c.tasks.some(function (t) { return t.group === g.id; }); })) stats.emptyGroup++;
      checkInvariant('GT_SEED=' + seed + ' chart #' + n + ' embedOutside=' + eo, c, genSums(rng, c), eo, genPrefix(rng, c, eo), fail);
    }
    ok('region invariant holds for ' + N + ' random charts (seed ' + seed + '; rerun with GT_SEED=' + seed + ')', failures === 0,
      failures + ' failures; first: ' + first);
    ok('the random charts exercise mirrors, embeds, bare milestones and empty groups',
      stats.mirror > 50 && stats.embed > 50 && stats.bareMs > 50 && stats.emptyGroup > 50, JSON.stringify(stats));
  }

  /* ================================================================= i18n */

  function i18nSpec() {
    var d = P('2026-03-03');
    eq('i18n starts in en-US', I.language, 'en-US');
    eq('text passes English through', I.text('Undo'), 'Undo');
    eq('fmt plural one', I.fmt('{n} day(s)', { n: 1 }), '1 day');
    eq('fmt plural many', I.fmt('{n} day(s)', { n: 26 }), '26 days');
    eq('fmt progress', I.fmt('{a} of {b} done', { a: 3, b: 5 }), '3 of 5 done');
    eq('monthYear en', I.date.monthYear(d), 'March 2026');
    eq('monthShort en', I.date.monthShort(d), 'Mar');
    eq('short en', I.date.short(d), 'Mar 3');
    eq('long en', I.date.long(d), 'Tue, Mar 3, 2026');
    eq('weekdayNarrow en', I.date.weekdayNarrow(d), 'T');
    eq('week en', I.date.week(10), 'W10');
    eq('quarter en', I.date.quarter(d), 'Q1');
    eq('week start en-US is Sunday', I.weekStart({}), 0);
    eq('settings.weekStart wins', I.weekStart({ weekStart: 1 }), 1);
    ok('weekend days include Saturday and Sunday', I.weekendDays().indexOf(6) >= 0 && I.weekendDays().indexOf(0) >= 0);
    var c = example();
    // formatRange output (CLDR): thin spaces around an en dash. ICU builds
    // differ in which space they use (node: U+2009), so spaces are folded.
    var TS = ' ', EN = '–';
    function sp(x) { return String(x).replace(/[\u2009\u202f\u00a0 ]/g, ' '); }
    eq('taskLabel reads title, dates, length, progress and overdue', sp(I.taskLabel(c.tasks[2], { done: 6, total: 10, overdue: true })),
      sp('Sync engine, Oct 12' + TS + EN + TS + 'Nov 6, 26 days, 6 of 10 done, overdue'));
    eq('dayNum en', I.date.dayNum(d), '3');
    eq('range en within a month', sp(I.date.range(d, P('2026-03-09'))), sp('Mar 3' + TS + EN + TS + '9'));
    eq('range en across months', sp(I.date.range(P('2026-10-12'), P('2026-11-06'))), sp('Oct 12' + TS + EN + TS + 'Nov 6'));
    eq('fmt never rewrites "(s)" inside a value', I.fmt('Undo: {action} “{title}”', { action: 'Move', title: '3 box(s)' }), 'Undo: Move “3 box(s)”');
    eq('fmt plural keyed on its own count', I.fmt('{n} day(s) for {t}', { n: 1, t: '2 cat(s)' }), '1 day for 2 cat(s)');
    // Week start follows the region of the host tag, not the UI language.
    I.setLanguage('en-GB');
    eq('en-GB keeps English strings', I.language + '|' + I.text('Undo'), 'en-US|Undo');
    eq('en-GB weeks start on Monday', I.weekStart({}), 1);
    I.setLanguage('de-DE');
    eq('de-DE weeks start on Monday', I.weekStart({}), 1);
    I.setLanguage('ar-EG');
    eq('ar-EG weeks start on Saturday', I.weekStart({}), 6);
    eq('ar-EG weekend is Friday and Saturday', I.weekendDays().join(','), '5,6');
    I.setLanguage('not a tag!');
    eq('a bad tag falls back to the UI language', I.weekStart({}), 0);
    I.setLanguage('en-US');

    eq('setLanguage zh_CN', I.setLanguage('zh_CN'), 'zh-CN');
    eq('text zh', I.text('Undo'), '撤销');
    eq('text zh falls back to English', I.text('Not in the table'), 'Not in the table');
    eq('fmt zh days', I.fmt('{n} day(s)', { n: 3 }), '3 天');
    eq('fmt zh progress', I.fmt('{a} of {b} done', { a: 3, b: 5 }), '已完成 3/5');
    eq('fmt zh undo label (§15.1: the action is translated once ZH has it, M6)', I.fmt('Undo: {action} “{title}”', { action: 'Move', title: 'X' }), '撤销：移动“X”');
    eq('monthYear zh', I.date.monthYear(d), '2026年3月');
    eq('monthShort zh', I.date.monthShort(d), '3月');
    eq('short zh', I.date.short(d), '3月3日');
    eq('long zh', I.date.long(d), '2026年3月3日 周二');
    eq('weekdayNarrow zh', I.date.weekdayNarrow(d), '二');
    eq('week zh', I.date.week(10), '第10周');
    eq('quarter zh', I.date.quarter(d), '第1季度');
    eq('dayNum zh', I.date.dayNum(d), '3');
    // M9 review round 1: written out with 至, like the single date (§15.1).
    eq('range zh', I.date.range(d, P('2026-04-09')), '3月3日至4月9日');
    eq('week start zh-CN is Monday', I.weekStart({}), 1);
    eq('setLanguage back to en', I.setLanguage('en-US'), 'en-US');
    eq('unknown languages fall back to en-US', I.setLanguage('fr-FR'), 'en-US');
  }

  /* ============================================================ host port */

  /*
   * The oracle for toggleEdit: the port of the host's replace_text rules
   * (note_modification_service.dart 555-613, 643-656, 660-683, 721-724). It
   * lives in host.js as GT.host.port because the mock's updateNotes applies
   * replace_text with the same rules.
   */
  var HOST = GT.host.port;

  // Apply a toggleEdit result through the host port; the error text or the
  // new content.
  function hostApply(content, e) {
    try { return HOST.replaceText(content, e.old_text, e.new_text, e.section); } catch (err) { return 'ERROR: ' + err.message; }
  }
  // The content with only line `index` flipped.
  function flipped(content, index) {
    var ls = content.split('\n');
    ls[index] = ls[index].replace(/\[( |x|X)\]/, function (m, c) { return c === ' ' ? '[x]' : '[ ]'; });
    return ls.join('\n');
  }

  /* =================================================================== md */

  function mdSpec() {
    // The port itself behaves like the Dart it restates.
    eq('host port: replaces one exact occurrence', HOST.replaceText('a\n- [ ] x\nb', '- [ ] x', '- [x] x'), 'a\n- [x] x\nb');
    ok('host port: two matches throw', /matched 2/.test(hostApply('- [ ] x\n- [ ] x', { old_text: '- [ ] x', new_text: '- [x] x' })));
    ok('host port: zero matches throw', /not found/.test(hostApply('abc', { old_text: 'zzz', new_text: 'yyy' })));
    eq('host port: an applied edit retried is a no-op', HOST.replaceText('- [x] x', '- [ ] x', '- [x] x'), '- [x] x');
    eq('host port: section scopes to the first trim-equal line', HOST.replaceText('## A\n- [ ] x\n## B\n- [ ] x', '- [ ] x', '- [x] x', '## B'), '## A\n- [ ] x\n## B\n- [x] x');
    ok('host port: a bare section has no level, so it runs to the end', /matched 2/.test(hostApply('A\n- [ ] x\n## B\n- [ ] x', { old_text: '- [ ] x', new_text: '- [x] x', section: 'A' })));
    ok('host port: a missing section throws', /Section not found/.test(hostApply('x', { old_text: 'x', new_text: 'y', section: '## Z' })));
    eq('host port: the section is not fence aware', HOST.sliceSection('```\n## C\n```\n## C\nx', '## C').body.join('|'), '```');

    // normHeading
    [['Checklist', 'checklist'], ['## Checklist', 'checklist'], ['### checklist:', 'checklist'], ['  # CHECKLIST #  ', 'checklist'],
      ['Check   list', 'check list'], ['##Checklist', 'checklist'], ['清单：', '清单'], ['## 清单', '清单'], ['', ''], [null, ''], ['#', '']
    ].forEach(function (c) { eq('normHeading ' + JSON.stringify(c[0]), MD.normHeading(c[0]), c[1]); });

    // Checklist counts, by hand (plan §18 M2 acceptance).
    function cl(content, section) {
      var r = MD.checklist(content, section);
      return (r.found ? 'found' : 'missing') + '|' + r.done + '/' + r.total + '|' + r.bits;
    }
    var TABLE = [
      ['GFM variants and the host bare form', '## Checklist\n- [ ] dash\n* [x] star\n+ [X] plus\n1. [ ] one dot\n2) [x] paren\n[ ] bare host form\n[x] bare checked', 'Checklist', 'found|4/7|0110101'],
      ['nested items count one by one', '## Checklist\n- [ ] parent\n  - [x] child\n    - [ ] grandchild\n\t- [x] tab child', 'Checklist', 'found|2/4|0101'],
      ['not checkboxes', '## Checklist\n- [-] dash state\n- [~] tilde state\n- [ ]\n- [ ]   \n- [x]\n-[ ] no space\n- [ ]no space after\n- [xx] two\n> - [ ] quoted\n<!-- - [ ] hidden -->\n<!--\n- [x] in a comment\n-->\n```\n- [ ] in code\n```\n~~~md\n- [x] in tilde code\n~~~\n- [ ] the only one', 'Checklist', 'found|0/1|0'],
      ['an inline comment after an item keeps the item', '## C\n- [x] done <!-- note -->', 'C', 'found|1/1|1'],
      ['bare setting matches ## heading', 'x\n## Checklist\n- [x] a', 'Checklist', 'found|1/1|1'],
      ['heading setting matches another level and a colon', '### checklist:\n- [x] a\n- [ ] b', '## Checklist', 'found|1/2|10'],
      ['closing hashes and indent', '  ## CHECKLIST ##\n- [ ] a', 'checklist', 'found|0/1|0'],
      ['the section ends at the next heading of the same level', '## Checklist\n- [ ] a\n### Sub\n- [x] b\n## Notes\n- [ ] c', 'Checklist', 'found|1/2|01'],
      ['a deeper section', '## Checklist\n- [ ] a\n### Sub\n- [x] b\n## Notes\n- [ ] c', 'Sub', 'found|1/1|1'],
      ['setext level 1 holds its level 2 subsection', 'Checklist\n=========\n- [ ] a\n\nNext\n----\n- [x] b\n# Other\n- [ ] c', 'Checklist', 'found|1/2|01'],
      ['setext level 2', 'Intro text\n\nTasks\n-----\n- [x] a\n## Other\n- [ ] b', 'Tasks', 'found|1/1|1'],
      ['a multi-line setext heading', 'My\nChecklist\n===\n- [x] a', 'My Checklist', 'found|1/1|1'],
      ['a quoted line over --- is not a setext heading', '## C\n- [ ] a\n> note\n---\n- [x] b', 'C', 'found|1/2|01'],
      ['a quoted paragraph over --- is not a setext heading', '## C\n- [ ] a\n\n> note\n---\n- [x] b', 'C', 'found|1/2|01'],
      ['a lazy continuation of an item over --- is not a setext heading', '## C\n- [ ] a\ncontinued\n---\n- [x] b', 'C', 'found|1/2|01'],
      // M2 review round 2: only a comment that starts a line hides lines
      // (CommonMark HTML block type 2); a mid-line `<!--` is inline and hides
      // nothing (known limit: an inline comment spanning lines of one
      // paragraph is not hidden either).
      ['a comment opened mid-line hides nothing', '## C\n- [ ] a <!-- hidden\n- [x] b\n-->\n- [ ] c', 'C', 'found|1/3|010'],
      ['a `<!--` inside a code span hides nothing', '## C\n- [ ] use `<!--` here\n- [ ] b\n- [x] c', 'C', 'found|1/3|001'],
      ['a comment that starts a line hides up to its end', '## C\n- [ ] a\n<!-- hidden\n- [x] b\n-->\n- [ ] c', 'C', 'found|0/2|00'],
      ['a lazy continuation of a quote over --- is not a setext heading', '> x\nC\n---\n- [ ] a', 'C', 'missing|0/0|'],
      ['a comment opened and closed mid-line hides nothing more', '## C\n- [ ] a <!-- x --> y\n- [x] b', 'C', 'found|1/2|01'],
      ['a list item over --- is not a setext heading', '## C\n- [ ] a\n---\n- [x] b', 'C', 'found|1/2|01'],
      ['a heading inside a code fence is skipped', '```\n## Checklist\n- [ ] fake\n```\n## Checklist\n- [x] real', 'Checklist', 'found|1/1|1'],
      ['a heading inside the chart\'s own block is skipped', '```synapse-gantt\n## Checklist\n- [ ] fake\n```\n\n## Checklist\n- [x] real', 'Checklist', 'found|1/1|1'],
      ['a heading in a comment or a quote is skipped', '<!--\n## Checklist\n-->\n> ## Checklist\n- [ ] a', 'Checklist', 'missing|0/0|'],
      ['CJK heading', '## 清单\n- [x] 写文档\n- [ ] 评审', '清单', 'found|1/2|10'],
      ['CJK heading with a fullwidth colon', '### 清单：\n- [ ] 一', '清单', 'found|0/1|0'],
      ['heading not found', '## Notes\n- [ ] a', 'Checklist', 'missing|0/0|'],
      ['an empty section setting is the whole note', '# A\n- [ ] a\n## B\n- [x] b', '', 'found|1/2|01'],
      ['duplicate items count twice', '## C\n- [ ] same\n- [ ] same', 'C', 'found|0/2|00'],
      ['CRLF note', '## Checklist\r\n- [ ] a\r\n- [x] b\r\n', 'Checklist', 'found|1/2|01'],
      ['an unclosed fence hides the rest', '## C\n- [ ] a\n```\n- [ ] b', 'C', 'found|0/1|0'],
      ['#hashtag is not a heading', '## C\n- [ ] a\n#tag\n- [x] b', 'C', 'found|1/2|01'],
      ['the first matching heading wins', '## C\n- [ ] a\n## C\n- [x] b', 'C', 'found|0/1|0']
    ];
    TABLE.forEach(function (row) { eq('checklist: ' + row[0], cl(row[1], row[2]), row[3]); });
    var many = '## C\n' + new Array(70).join('- [x] a\n');
    eq('checklist: more than 64 items keep counts but no bits', cl(many, 'C'), 'found|69/69|');
    var region = fix('region-basic.md');
    eq('checklist: the whole chart note has no items in its mirror or block', cl(region + '\n\n- [ ] a real item', ''), 'found|0/1|0');
    var items = MD.checklist('## C\r\n- [ ] a\r\n  - [x] b', 'C').items;
    eq('checklist items carry the raw line without CR, its neighbour and state', JSON.stringify(items.map(function (it) { return [it.index, it.line, it.prevLine, it.checked, it.text, it.indent]; })),
      JSON.stringify([[1, '- [ ] a', '## C', false, 'a', 0], [2, '  - [x] b', '- [ ] a', true, 'b', 2]]));

    var fs = MD.findSection('Intro\n\n## Check list ##\nx', 'check list');
    eq('findSection gives the full ATX heading line', fs.heading + '|' + fs.level + '|' + fs.bodyStart + '|' + fs.bodyEnd, '## Check list ##|2|3|4');
    var fset = MD.findSection('Checklist\n---\nx', 'Checklist');
    eq('findSection marks a setext heading and gives no heading line', fset.setext + '|' + fset.heading + '|' + fset.level + '|' + fset.bodyStart, 'true|null|2|2');

    // Templates (§8 create row, §15.1).
    var tp = MD.template({ source: 'checklist', section: 'Checklist', steps: ['Draft', ' Review ', '', 'two\nlines'], backlink: { chartId: 'c-1', title: 'Q4 [plan' } });
    eq('template: checklist heading, steps, backlink', tp.content, '## Checklist\n- [ ] Draft\n- [ ] Review\n- [ ] two lines\n\n[↩ Q4 ［plan](synapseresource://note/c-1?via=gantt-chart)');
    eq('template: no subnotes in checklist mode', tp.subNotes.length, 0);
    eq('template: the chart finds the new checklist', cl(tp.content, 'Checklist'), 'found|0/3|000');
    eq('template: a heading setting is used as written', MD.template({ source: 'checklist', section: '### To do:', steps: ['a'] }).content, '### To do:\n- [ ] a');
    eq('template: a heading setting still matches the chart', cl(MD.template({ source: 'checklist', section: '### To do:', steps: ['a'] }).content, '### To do:'), 'found|0/1|0');
    eq('template: ##Checklist gets a space', MD.headingLine('##Checklist'), '## Checklist');
    eq('template: checklist with no steps still writes the heading', MD.template({ source: 'checklist', section: 'Checklist' }).content, '## Checklist');
    eq('template: the whole-note section writes a bare list', MD.template({ source: 'checklist', section: '', steps: ['a'] }).content, '- [ ] a');
    var ts = MD.template({ source: 'subnotes', section: 'Checklist', steps: ['a', 'b'], intro: '  Owner: me\r\n' });
    eq('template: subnotes mode sends subNotes', JSON.stringify(ts.subNotes), '[{"name":"a","content":""},{"name":"b","content":""}]');
    eq('template: subnotes mode writes no checklist', ts.content, 'Owner: me');
    eq('template: status source with no steps writes nothing', MD.template({ source: 'status', section: 'Checklist' }).content, '');
    eq('template: backlink off', MD.template({ source: 'checklist', section: 'C', steps: ['a'] }).content, '## C\n- [ ] a');
    eq('template: a bad chart id writes no backlink', MD.template({ source: 'subnotes', backlink: { chartId: 'x y', title: 'T' } }).content, '');
    ok('template: content has no outer whitespace', MD.template({ source: 'checklist', section: 'C', steps: ['a'], intro: '\n\nx\n', backlink: { chartId: 'c', title: '' } }).content === 'x\n\n## C\n- [ ] a\n\n[↩ ](synapseresource://note/c?via=gantt-chart)');

    // Section defaults (§15.1, D14).
    eq('defaultSection zh-CN', MD.defaultSection('zh-CN'), '清单');
    eq('defaultSection zh-Hans-CN', MD.defaultSection('zh-Hans-CN'), '清单');
    eq('defaultSection zh_CN', MD.defaultSection('zh_CN'), '清单');
    eq('defaultSection en-US', MD.defaultSection('en-US'), 'Checklist');
    eq('defaultSection zh-TW follows the en UI', MD.defaultSection('zh-TW'), 'Checklist');
    eq('defaultSection with no tag', MD.defaultSection(undefined), 'Checklist');
    I.setLanguage('zh-CN');
    eq('a chart with no progressSection reads "Checklist" whatever the UI language', M.coerce({ v: 1 }).chart.settings.progressSection, 'Checklist');
    I.setLanguage('en-US');
    var zhChart = M.setSettings(M.empty(), { progressSection: MD.defaultSection('zh-CN') }).chart;
    eq('a new zh-CN chart stores its section explicitly', JSON.stringify(M.toData(zhChart).settings), '{"progressSection":"清单"}');
    var zhNote = MD.template({ source: 'checklist', section: zhChart.settings.progressSection, steps: ['写文档'] }).content;
    eq('its created task notes use the same heading', zhNote, '## 清单\n- [ ] 写文档');
    eq('and the chart counts them', cl(zhNote, zhChart.settings.progressSection), 'found|0/1|0');

    // Note links (§10.3 "Import N linked notes").
    var links = 'See [A](synapseresource://note/aa1) and [B](synapseresource://note/bb-2?via=gantt).\n' +
      '[A again](synapseresource://note/aa1)\n```\n[C](synapseresource://note/cc3)\n```\n<!-- [D](synapseresource://note/dd4) -->\n' +
      '> quoted [E](synapseresource://note/ee5)\n[↩ Chart](synapseresource://note/ch1?via=gantt-chart)\n[Self](synapseresource://note/me)\n' +
      'bare synapseresource://note/ff6 and app synapseresource://app/xx7';
    eq('noteLinkIds: order, no repeats, no code, comment, backlink or self', MD.noteLinkIds(links, { exclude: 'me' }).join(','), 'aa1,bb-2,ee5,ff6');
    eq('noteLinkIds on a note with none', MD.noteLinkIds('plain').length, 0);

    // SQL needles (§7.4).
    [['## Checklist', 'Checklist'], ["### It's done:", "It''s done"], ['', ''], ['清单：', '清单'], ['Checklist ##', 'Checklist'], ['  #  Check  ', 'Check']]
      .forEach(function (c) { eq('sqlNeedle ' + JSON.stringify(c[0]), MD.sqlNeedle(c[0]), c[1]); });
  }

  /* =============================================================== toggle */

  function toggleSpec() {
    // Each case: note, section setting, item line index, expected section.
    function tg(content, section, index, opts) {
      var e = MD.toggleEdit(content, section, { index: index }, opts);
      return e;
    }
    function check(name, content, section, index, wantSection, opts) {
      var e = tg(content, section, index, opts);
      ok(name + ': ok', e.ok, JSON.stringify(e));
      if (!e.ok) return e;
      eq(name + ': the host applies it to exactly that line', hostApply(content, e), flipped(content, index));
      eq(name + ': section', String(e.section), String(wantSection));
      return e;
    }
    var base = 'Intro\n\n## Checklist\n- [ ] a\n- [ ] b';
    var e1 = check('unique item', base, 'Checklist', 3, '## Checklist');
    eq('unique item: old_text is the line', e1.old_text + '|' + e1.new_text + '|' + e1.checked, '- [ ] a|- [x] a|true');
    check('the full heading line is sent for any spelling of the setting', 'x\n### Checklist:\n- [x] a', 'checklist', 2, '### Checklist:');
    var e2 = check('a duplicated item', '## C\n- [ ] x\n- [ ] a\n- [ ] y\n- [ ] a', 'C', 4, '## C');
    eq('a duplicated item: old_text is prevLine + line', e2.old_text, '- [ ] y\n- [ ] a');
    var e3 = check('a prefix of another item', '## C\n- [ ] Buy milk and eggs\n- [ ] Buy milk', 'C', 2, '## C');
    eq('a prefix of another item: context is added', e3.old_text, '- [ ] Buy milk and eggs\n- [ ] Buy milk');
    eq('a nested item equal to a top item: the line below is added', check('a nested item equal to a top item', '## C\n- [ ] a\n  - [ ] a', 'C', 1, '## C').old_text, '- [ ] a\n  - [ ] a');
    // The heading is outside the host's scope, so the line below is used.
    eq('the first of two identical items: the line below is added', check('the first of two identical items (its prevLine is the heading)', '## C\n- [ ] a\n- [ ] a', 'C', 1, '## C').old_text, '- [ ] a\n- [ ] a');
    var e4 = check('the last of three identical items', '## C\n- [ ] a\n- [ ] a\n- [ ] a', 'C', 3, '## C');
    eq('the last of three identical items: two lines of context', e4.old_text, '- [ ] a\n- [ ] a\n- [ ] a');
    eq('the second of four identical items: the whole run', check('the second of four identical items', '## C\n- [ ] a\n- [ ] a\n- [ ] a\n- [ ] a', 'C', 2, '## C').old_text, '- [ ] a\n- [ ] a\n- [ ] a\n- [ ] a');
    check('the middle of three identical items', '## C\n- [ ] a\n- [ ] a\n- [ ] a', 'C', 2, '## C');
    eq('context below is preferred to everything above plus below', check('a duplicated pair above', '## C\n- [ ] a\n- [ ] a\n- [ ] b\n- [ ] a\n- [ ] a\n- [ ] c', 'C', 2, '## C').old_text, '- [ ] a\n- [ ] b');
    check('an item with the same neighbours above and below', '## C\n- [ ] x\n- [ ] a\n- [ ] y\n- [ ] x\n- [ ] a\n- [ ] y', 'C', 5, '## C');
    check('a setext heading sends no section', 'Checklist\n=====\n- [ ] a\n- [x] b', 'Checklist', 2, 'undefined');
    check('the whole-note section sends no section', '- [ ] a\n- [x] b', '', 1, 'undefined');
    // M2 review round 1: new_text is unique after the edit too, so a retry
    // of an applied toggle is the host's no-op success.
    var rt = check('a checked twin right below', '## C\n- [ ] a\n- [x] a', 'C', 1, '## C');
    eq('a checked twin right below: a retry is a no-op', hostApply(hostApply('## C\n- [ ] a\n- [x] a', rt), rt), '## C\n- [x] a\n- [x] a');
    eq('a checked twin right below: new_text occurs once after the edit', rt.new_text, '- [x] a\n- [x] a');
    var rt2 = check('an unchecked twin elsewhere', '## C\n- [x] a\n- [ ] q\n- [ ] a', 'C', 1, '## C');
    eq('an unchecked twin elsewhere: a retry is a no-op', hostApply(hostApply('## C\n- [x] a\n- [ ] q\n- [ ] a', rt2), rt2), '## C\n- [ ] a\n- [ ] q\n- [ ] a');
    // M2 review round 2: this note is decided by uniqueness (the line repeats,
    // the line above makes it unique), not by the old-gone rule.
    var sub = '## C\n- [x] a\n- [x] a\n- [ ] ab';
    var rt3 = check('a checked twin above and a longer item below', sub, 'C', 2, '## C');
    eq('a checked twin above and a longer item below: prevLine makes it unique', rt3.old_text, '- [x] a\n- [x] a');
    eq('a checked twin above and a longer item below: a retry is a no-op', hostApply(hostApply(sub, rt3), rt3), '## C\n- [x] a\n- [ ] a\n- [ ] ab');
    // Only the old-gone rule decides here: prevLine + line is unique before
    // the edit and new_text once after it, but the edited line plus the line
    // below spell old_text again, so the line below is used instead.
    var og = '## C\n- [x] a\n- [ ] a\n- [ ] a';
    var rt5 = check('old_text reappears after the edit (only the old-gone rule decides)', og, 'C', 2, '## C');
    eq('old_text reappears after the edit: the line below is used', rt5.old_text, '- [ ] a\n- [ ] a');
    eq('old_text reappears after the edit: a retry is a no-op', hostApply(hostApply(og, rt5), rt5), '## C\n- [x] a\n- [x] a\n- [ ] a');
    var sub2 = '## C\n- [x] a\n- [ ] a\n- [ ] ab';
    var rt4 = check('old_text would match the longer item after the edit', sub2, 'C', 2, '## C');
    eq('old_text would match the longer item after the edit: a retry is a no-op', hostApply(hostApply(sub2, rt4), rt4), '## C\n- [x] a\n- [x] a\n- [ ] ab');
    ok('toggleEdit takes no block-scope option (the host has no replace_text for blocks)', MD.toggleEdit.length === 3);
    // M2 review round 1: Dart's trim() also strips U+0085, so the host takes
    // a fenced '## C<NEL>' line as the section heading.
    check('a fenced heading line ending in U+0085 before the real one', '```\n## C\u0085\n- [ ] a\n```\n## C\n- [ ] a', 'C', 5, 'undefined');
    check('the heading line also sits in an earlier code fence', '```\n## C\n- [ ] a\n```\n## C\n- [ ] a', 'C', 5, 'undefined');
    check('the host section would stop at a fenced heading', '## C\n```\n## Z\n```\n- [ ] a\n- [ ] b', 'C', 4, 'undefined');
    check('the same item in two sections', '## A\n- [ ] a\n## C\n- [ ] a', 'C', 3, '## C');
    check('a checked item unchecks', '## C\n- [X] a', 'C', 1, '## C');
    check('the bare host form', '## C\n[ ] a', 'C', 1, '## C');
    check('an ordered item', '## C\n1) [ ] a\n2) [ ] a', 'C', 2, '## C');
    check('CRLF note, unique', '## C\r\n- [ ] a\r\n- [ ] b\r\n', 'C', 1, '## C');
    check('CRLF note, duplicated', '## C\r\n- [ ] q\r\n- [ ] a\r\n- [ ] r\r\n- [ ] a\r\n', 'C', 4, '## C');
    check('CJK section', '## 清单\n- [ ] 写文档\n- [ ] 写文档', '清单', 2, '## 清单');

    eq('no section', MD.toggleEdit('## A\n- [ ] a', 'C', { index: 1 }).reason, 'no-section');
    eq('an index that is not an item', MD.toggleEdit('## C\n- [ ] a\ntext', 'C', { index: 2 }).reason, 'gone');
    eq('an item outside the section', MD.toggleEdit('- [ ] a\n## C\n- [ ] b', 'C', { index: 0 }).reason, 'gone');

    // Identity form for undo (§6.1): {line after the toggle, prevLine}.
    var t0 = '## C\n- [ ] y\n- [ ] a\n- [ ] z\n- [ ] a';
    var tgl = MD.toggleEdit(t0, 'C', { index: 4 });
    var t1 = hostApply(t0, tgl);
    var un = MD.toggleEdit(t1, 'C', { line: tgl.newLine, prevLine: tgl.prevLine });
    eq('undo by identity flips the same duplicated item back', hostApply(t1, un), t0);
    eq('undo by identity: the new state', un.checked, false);
    eq('undo of an item the user changed meanwhile is gone', MD.toggleEdit(t0, 'C', { line: tgl.newLine, prevLine: tgl.prevLine }).reason, 'gone');
    eq('undo of two identical items with the same neighbour is ambiguous', MD.toggleEdit('## C\n- [x] a\n- [x] a\n- [x] a', 'C', { line: '- [x] a', prevLine: '- [x] a' }).reason, 'ambiguous');
    eq('identity without prevLine on a unique line', MD.toggleEdit('## C\n- [x] a', 'C', { line: '- [x] a' }).index, 1);

    // Fuzz: every item of random notes toggles through the host port to
    // exactly that line, and undo by identity restores the note.
    var seed = typeof global.GT_SEED === 'number' && isFinite(global.GT_SEED) ? global.GT_SEED : (Date.now() % 2147483647);
    var rng = mulberry32(seed + 101);
    var POOL = ['## Checklist', '### Checklist', 'Checklist', '=====', '-----', '## Notes', '# Top', '## Checklist:', '- [ ] a', '- [x] a',
      '- [ ] a b', '  - [ ] a', '* [X] a', '1. [ ] a', '[ ] a', '- [ ] ab', '```', '~~~', '> - [ ] a', '<!--', '-->', 'text', '', '', '- [ ] b', '- [x] b'];
    var SECTIONS = ['Checklist', '## Checklist', '', 'Notes', 'checklist:'];
    var notes = 0, toggles = 0, withSection = 0, fails = [], unsent = 0, retries = 0;
    for (var n = 0; n < 800; n++) {
      var len = 3 + Math.floor(rng() * 14), ls = [];
      for (var k = 0; k < len; k++) ls.push(POOL[Math.floor(rng() * POOL.length)]);
      var content = ls.join(rng() < 0.2 ? '\r\n' : '\n') + (rng() < 0.3 ? '\n' : '');
      var section = SECTIONS[Math.floor(rng() * SECTIONS.length)];
      var list = MD.checklist(content, section);
      if (!list.found) continue;
      notes++;
      list.items.forEach(function (it) {
        toggles++;
        var e = MD.toggleEdit(content, section, { index: it.index });
        if (!e.ok) { fails.push('#' + n + ' item ' + it.index + ' ' + e.reason + ' ' + JSON.stringify(content)); return; }
        if (e.section) {
          withSection++;
          var fsn = MD.findSection(content, section);
          if (e.section !== fsn.heading || fsn.setext) fails.push('#' + n + ' wrong section ' + JSON.stringify(e.section));
        } else if (section && !MD.findSection(content, section).setext) unsent++;
        var after = hostApply(content, e);
        if (after !== flipped(content, it.index)) { fails.push('#' + n + ' item ' + it.index + ' ' + JSON.stringify(content) + ' -> ' + JSON.stringify(e)); return; }
        // A retry of the same edit (a timeout after the host applied it) is
        // the host's idempotent no-op, never an error and never a change.
        retries++;
        if (hostApply(after, e) !== after) fails.push('#' + n + ' retry ' + JSON.stringify(hostApply(after, e)) + ' ' + JSON.stringify(e));
        var back = MD.toggleEdit(after, section, { line: e.newLine, prevLine: e.prevLine });
        if (!back.ok) {
          // Identity can be ambiguous (same line, same neighbour); never wrong.
          if (back.reason !== 'ambiguous') fails.push('#' + n + ' undo ' + back.reason + ' ' + JSON.stringify(after));
          return;
        }
        // Undo writes 'x' for a box that was 'X'; the line is what matters.
        var undone = hostApply(after, back);
        if (undone !== flipped(after, it.index)) fails.push('#' + n + ' undo mismatch ' + JSON.stringify(after));
        else if (hostApply(undone, back) !== undone) fails.push('#' + n + ' undo retry ' + JSON.stringify(undone));
      });
    }
    ok('toggle fuzz (seed ' + seed + '; rerun with GT_SEED=' + seed + '): every toggle and undo applies to exactly its line, and a retry of either is a no-op', fails.length === 0, fails.slice(0, 3).join('\n'));
    ok('toggle fuzz covered enough notes, toggles and retries', notes > 150 && toggles > 400 && retries === toggles, notes + ' notes, ' + toggles + ' toggles');
    ok('toggle fuzz sent the heading line as section most of the time', withSection > unsent, withSection + ' with, ' + unsent + ' without');
  }

  /* ============================================================== summary */

  function summarySpec() {
    var today = P('2026-10-10');
    var FUT = { note: 'n1', start: P('2026-10-12'), end: P('2026-10-20'), milestone: false, progress: null };
    var PAST = { note: 'n1', start: P('2026-10-01'), end: P('2026-10-05'), milestone: false, progress: null };
    function task(t, extra) { var o = {}; Object.keys(t).forEach(function (k) { o[k] = t[k]; }); Object.keys(extra || {}).forEach(function (k) { o[k] = extra[k]; }); return o; }
    function fact(status, prog, extra) {
      var f = { title: 'T', type: 'task', status: status, archived: false, missing: false, prog: prog || null };
      Object.keys(extra || {}).forEach(function (k) { f[k] = extra[k]; });
      return f;
    }
    var SUB = { progressSource: 'subnotes', childTasks: true }, CHK = { progressSource: 'checklist' }, STA = { progressSource: 'status' }, NON = { progressSource: 'none' };
    function sp(done, total, bits) { return { src: 'subnotes', done: done, total: total, bits: bits === undefined ? null : bits }; }
    function cp(done, total, found) { return { src: 'checklist', done: done, total: total, bits: '', found: found !== false }; }
    function sum(f, t, s) { return M.summarize(f, t, s, today); }
    function line(r) { return r.cls + '|' + r.done + '/' + r.total + '|' + r.ratio + '|' + r.chip; }

    // Truth table: every class for every source (plan §6.2, §17.1).
    var TT = [
      ['subnotes', 'none', fact('todo', sp(0, 0)), FUT, SUB, 'none|0/0|null|'],
      ['subnotes', 'todo', fact('todo', sp(0, 3)), FUT, SUB, 'todo|0/3|0|0/3'],
      ['subnotes', 'doing', fact('todo', sp(1, 3)), FUT, SUB, 'doing|1/3|' + (1 / 3) + '|1/3'],
      ['subnotes', 'doing (in_progress, nothing to count)', fact('in_progress', sp(0, 0)), FUT, SUB, 'doing|0/0|null|'],
      ['subnotes', 'done (all counted)', fact('todo', sp(3, 3)), PAST, SUB, 'done|3/3|1|✓'],
      ['subnotes', 'done (status complete)', fact('complete', sp(1, 3)), PAST, SUB, 'done|1/3|' + (1 / 3) + '|✓'],
      ['subnotes', 'late', fact('in_progress', sp(1, 3)), PAST, SUB, 'late|1/3|' + (1 / 3) + '|1/3'],
      ['subnotes', 'dropped', fact('abandoned', sp(3, 3)), PAST, SUB, 'dropped|3/3|1|3/3'],
      ['checklist', 'none (section missing)', fact('todo', cp(0, 0, false)), FUT, CHK, 'none|0/0|null|'],
      ['checklist', 'todo', fact('todo', cp(0, 2)), FUT, CHK, 'todo|0/2|0|0/2'],
      ['checklist', 'doing', fact('todo', cp(1, 2)), FUT, CHK, 'doing|1/2|0.5|1/2'],
      ['checklist', 'doing (in_progress, section missing)', fact('in_progress', cp(0, 0, false)), FUT, CHK, 'doing|0/0|null|'],
      ['checklist', 'done', fact('todo', cp(2, 2)), FUT, CHK, 'done|2/2|1|✓'],
      ['checklist', 'late', fact('todo', cp(0, 2)), PAST, CHK, 'late|0/2|0|0/2'],
      ['checklist', 'dropped', fact('abandoned', cp(1, 2)), FUT, CHK, 'dropped|1/2|0.5|1/2'],
      ['status', 'none (no status)', fact(null), FUT, STA, 'none|0/0|null|'],
      ['status', 'todo', fact('todo'), FUT, STA, 'todo|0/1|0|'],
      ['status', 'doing (in_progress gives ratio 0.5)', fact('in_progress'), FUT, STA, 'doing|0/1|0.5|'],
      ['status', 'done', fact('complete'), PAST, STA, 'done|1/1|1|✓'],
      ['status', 'late', fact('in_progress'), PAST, STA, 'late|0/1|0.5|'],
      ['status', 'dropped', fact('abandoned'), PAST, STA, 'dropped|0/1|0|'],
      ['none', 'none', fact('todo', sp(1, 3)), FUT, NON, 'none|0/0|null|'],
      ['none', 'todo is not reachable: a todo note is none', fact('todo'), FUT, NON, 'none|0/0|null|'],
      ['none', 'doing', fact('in_progress'), FUT, NON, 'doing|0/0|null|'],
      ['none', 'done', fact('complete'), PAST, NON, 'done|0/0|null|✓'],
      ['none', 'late', fact('todo'), PAST, NON, 'late|0/0|null|'],
      ['none', 'dropped', fact('abandoned'), PAST, NON, 'dropped|0/0|null|'],
      // Review round 1: in_progress with items and none done is todo (§6.2 precedence).
      ['subnotes', 'todo (in_progress, 0 of 3)', fact('in_progress', sp(0, 3)), FUT, SUB, 'todo|0/3|0|0/3'],
      ['checklist', 'todo (in_progress, 0 of 2)', fact('in_progress', cp(0, 2)), FUT, CHK, 'todo|0/2|0|0/2']
    ];
    var seenCls = {};
    TT.forEach(function (row) {
      var r = sum(row[2], row[3], row[4]);
      eq('classify ' + row[0] + ': ' + row[1], line(r), row[5]);
      eq('summary ' + row[0] + ': ' + row[1] + ' (overdue, src)', r.overdue + '|' + r.src, (r.cls === 'late') + '|' + row[0]);
      seenCls[row[0] + ':' + r.cls] = true;
    });
    M.SOURCES.forEach(function (src) {
      var missingCls = M.CLASSES.filter(function (c) { return !seenCls[src + ':' + c] && !(src === 'none' && c === 'todo'); });
      eq('the truth table reaches every class for source ' + src, missingCls.join(','), '');
      var m = sum({ missing: true, status: 'complete', prog: sp(3, 3) }, PAST, { progressSource: src });
      eq('missing note, source ' + src + ': flag set, class none, no counts, not loading', m.missing + '|' + line(m) + '|' + m.loading, 'true|none|0/0|null||false');
    });

    // Subnotes plus child tasks (D4, §6.3).
    var kid = fact('todo', { src: 'subnotes', done: 1, total: 2, bits: '10', child: { done: 1, total: 1, bits: '1' } });
    var rk = sum(kid, FUT, SUB);
    eq('child tasks add to subnotes, subnote bits first', rk.done + '/' + rk.total + '|' + rk.bits, '2/3|101');
    var rk2 = sum(kid, FUT, { progressSource: 'subnotes', childTasks: false });
    eq('childTasks off counts subnotes only', rk2.done + '/' + rk2.total + '|' + rk2.bits, '1/2|10');
    eq('child tasks count only for the subnotes source', sum(fact('todo', { src: 'checklist', done: 1, total: 2, bits: '10', child: { done: 1, total: 1, bits: '1' } }), FUT, CHK).total, 2);
    eq('bad child bits drop all bits but keep counts', (function () { var r = sum(fact('todo', { src: 'subnotes', done: 1, total: 2, bits: '10', child: { done: 1, total: 2, bits: '1' } }), FUT, SUB); return r.done + '/' + r.total + '|' + r.bits; })(), '2/4|');
    eq('done is clamped to total', line(sum(fact('todo', sp(5, 3)), FUT, SUB)), 'done|3/3|1|✓');
    eq('negative, fractional or huge counts read as 0', line(sum(fact('todo', sp(-1, 2.5)), FUT, SUB)) + ' ' + line(sum(fact('todo', sp(1, 1e21)), FUT, SUB)), 'none|0/0|null| none|0/0|null|');
    eq('bits must match the total', sum(fact('todo', sp(1, 3, '1')), FUT, SUB).bits, '');
    eq('bits must be 0 and 1', sum(fact('todo', sp(1, 2, '1x')), FUT, SUB).bits, '');
    var b64 = new Array(65).join('1'), b70 = new Array(71).join('1');
    eq('64 bits are kept', sum(fact('todo', sp(64, 64, b64)), FUT, SUB).bits, b64);
    eq('more than 64 bits are dropped', sum(fact('todo', sp(70, 70, b70)), FUT, SUB).bits, '');
    eq('status source has no bits', sum(fact('in_progress'), FUT, STA).bits, '');

    // Checklist extras.
    var nf = sum(fact('todo', cp(3, 5, false)), FUT, CHK);
    eq('section not found: found false, no counts', nf.found + '|' + line(nf), 'false|none|0/0|null|');
    eq('partial passes through', sum(fact('todo', { src: 'checklist', done: 1, total: 4, found: true, partial: true }), FUT, CHK).partial, true);

    // Stale or unresolved progress never shows old counts (§7.5).
    var stale = sum(fact('todo', sp(2, 3)), FUT, CHK);
    eq('progress from another source is stale: loading, no counts', stale.loading + '|' + line(stale), 'true|none|0/0|null|');
    var noFact = sum(null, PAST, SUB);
    eq('no fact yet: loading, never late', noFact.loading + '|' + noFact.cls, 'true|none');
    eq('a task override picks the source', sum(fact('complete'), task(FUT, { progress: 'status' }), SUB).src, 'status');
    eq('an unknown override falls back to the chart', sum(fact('todo', cp(1, 2)), task(FUT, { progress: 'manual' }), CHK).src, 'checklist');
    eq('an unknown chart source falls back to subnotes', sum(fact('todo', sp(1, 2)), FUT, { progressSource: 'manual' }).src, 'subnotes');
    eq('no settings at all means subnotes', M.summarize(fact('todo', sp(1, 2)), FUT, null, today).src, 'subnotes');

    // Dates (D16: one-day tasks and milestones have no end).
    var lateOf = function (t) { return sum(fact('todo', sp(0, 1)), t, SUB).cls; };
    eq('a one-day task in the past is late', lateOf({ note: 'n1', start: P('2026-10-09'), end: null, milestone: false }), 'late');
    eq('a task ending today is not late', lateOf({ note: 'n1', start: P('2026-10-01'), end: today, milestone: false }), 'todo');
    eq('a milestone with a note in the past is late', lateOf({ note: 'n1', start: P('2026-10-01'), end: null, milestone: true }), 'late');
    eq('an unscheduled task is never late', lateOf({ note: 'n1', start: null, end: null, milestone: false }), 'todo');
    var bare = M.summarize(null, { note: null, start: P('2026-10-01'), end: null, milestone: true }, SUB, today);
    eq('a note-less milestone: no counts, not loading, never late', bare.loading + '|' + line(bare), 'false|none|0/0|null|');
    eq('no today: never late', M.summarize(fact('todo', sp(0, 1)), PAST, SUB).cls, 'todo');
    eq('an unknown status is no signal', sum(fact('blocked'), FUT, STA).cls, 'none');

    // Shape (§6.3).
    eq('summary keys', Object.keys(sum(fact('todo', sp(1, 2)), FUT, SUB)).sort().join(','), 'bits,chip,cls,done,found,loading,missing,overdue,partial,ratio,src,total');
    // Review round 1: while progress is loading, no class comes from counts
    // or dates; only the note's status speaks.
    var ld = sum(fact('todo', sp(0, 3)), PAST, CHK);
    eq('loading: never late, no counts', ld.loading + '|' + line(ld), 'true|none|0/0|null|');
    eq('loading: status complete is still done', sum(fact('complete', sp(0, 3)), PAST, CHK).cls, 'done');
    eq('loading: status abandoned is still dropped', sum(fact('abandoned', sp(0, 3)), PAST, CHK).cls, 'dropped');
    eq('loading: in_progress is doing', sum(fact('in_progress', sp(0, 3)), PAST, CHK).cls, 'doing');
    eq('classify ignores stale counts while loading', M.classify(fact('todo'), FUT, { src: 'subnotes', done: 3, total: 3, loading: true }, today), 'none');
    eq('classify honours summary.loading on its own', M.classify(fact('todo'), PAST, { src: 'subnotes', done: 0, total: 0, loading: true }, today), 'none');
    ['status', 'none'].forEach(function (src) {
      var nf2 = M.summarize(null, PAST, { progressSource: src }, today);
      eq('no fact yet, source ' + src + ': loading, not late', nf2.loading + '|' + nf2.cls, 'true|none');
    });
    eq('classify alone', M.classify(fact('in_progress'), FUT, { src: 'subnotes', done: 0, total: 0 }, today), 'doing');
    eq('classify with no summary', M.classify(fact('abandoned'), FUT, null, today), 'dropped');
    eq('taskLabel reads the summary', I.taskLabel({ title: 'T', start: P('2026-10-01'), end: P('2026-10-05'), milestone: false }, sum(fact('todo', sp(1, 3)), PAST, SUB)).indexOf('1 of 3 done, overdue') > 0, true);
  }

  /* ================================================================= grep */

  // Plan §17.1: identifiers, not prose.
  var SYNAPSE_ID = /\bSynapse\s*(\?\.|\.[A-Za-z_$]|\[)|window\.Synapse/;
  var SYNAPSE_EVT = /['"`]synapse:/;
  var PURE = ['i18n.js', 'dates.js', 'model.js', 'undo.js', 'block.js', 'md.js', 'scale.js', 'layout.js'];

  function grepSpec() {
    ok('grep rule catches window.Synapse', SYNAPSE_ID.test('var s = window.Synapse;'));
    ok('grep rule catches Synapse.locale', SYNAPSE_ID.test('x = Synapse.locale'));
    ok('grep rule catches Synapse?.theme', SYNAPSE_ID.test('Synapse?.theme'));
    ok('grep rule catches Synapse["x"]', SYNAPSE_ID.test('Synapse["x"]'));
    ok('grep rule catches a synapse: event name', SYNAPSE_EVT.test("addEventListener('synapse:localechanged', f)"));
    ok('grep rule allows prose "Note Synapse asks"', !SYNAPSE_ID.test("'Note Synapse asks before an app edits a note.'"));
    ok('grep rule allows a sentence ending "Note Synapse."', !SYNAPSE_ID.test("'Made for Note Synapse.'"));

    var src = global.GT_SOURCES;
    if (!src) { ok('grep test needs GT_SOURCES (node only)', true); return; }
    var files = Object.keys(src).sort();
    ok('grep test sees the source files', files.length >= 5, files.join(','));
    files.forEach(function (f) {
      if (f === 'host.js') return;
      var bad = src[f].split('\n').filter(function (l) { return SYNAPSE_ID.test(l) || SYNAPSE_EVT.test(l); });
      ok(f + ' does not reference Synapse (only host.js may)', bad.length === 0, bad.join('\n'));
    });
    files.forEach(function (f) {
      if (PURE.indexOf(f) < 0) return;
      ok(f + ' (pure) has no innerHTML', src[f].indexOf('innerHTML') < 0);
      ok(f + ' (pure) uses no document or window object at all', !/\bdocument\.|\bwindow\.(?!Synapse)/.test(src[f]));
    });
    // host.js is the one file allowed to reach Synapse, and it does.
    ok('grep test sees host.js', files.indexOf('host.js') >= 0, files.join(','));
    var host = src['host.js'] || '';
    ok('host.js references window.Synapse / Synapse.x', SYNAPSE_ID.test(host) || /global\.Synapse/.test(host));
    ok('host.js names the synapse: events it listens to', /'synapse:'/.test(host));
    // §17.3 note-safety contract, checked on the source.
    ok('host.js never calls deleteNotes', host.indexOf('deleteNotes') < 0);
    ok('host.js never sends a content replace action', !/action\s*:\s*['"]replace['"]/.test(host));
    ok('host.js sends replace_text for the region', /action: 'replace_text'/.test(host));
    ok('host.js reads loadAppState through .data', /r\.data/.test(host) && !/r\.state\b/.test(host));
    files.forEach(function (f) {
      // §4.1: every module, pure or not.
      ok(f + ' has the IIFE + module.exports shape', /module\.exports = GT;\n\}\)\(typeof window !== 'undefined' \? window : globalThis\);\n$/.test(src[f]));
      ok(f + ' has no em-dash', src[f].indexOf(String.fromCharCode(0x2014)) < 0);
    });
  }

  /* ================================================================== run */

  var SPEC = (GT.spec = {});
  function guard(name, fn) {
    try { fn(); } catch (e) { ok(name + ' ran to the end', false, String((e && e.stack) || e)); }
  }
  // Later spec files (dev/host_spec.js, ...) register suites here and use
  // the same assertion helpers.
  SPEC.api = { ok: ok, eq: eq, same: same, acase: acase, fix: fix, canon: canon, show: show };
  SPEC.suites = SPEC.suites || [];
  SPEC.run = function () {
    results = [];
    asyncCases = [];
    guard('the dates spec', datesSpec);
    guard('the model spec', modelSpec);
    guard('the merge spec', mergeSpec);
    guard('the undo spec', undoSpec);
    guard('the block spec', blockSpec);
    guard('the region fixture spec', regionFixtureSpec);
    guard('the property spec', propertySpec);
    guard('the i18n spec', i18nSpec);
    guard('the md spec', mdSpec);
    guard('the toggle spec', toggleSpec);
    guard('the summary spec', summarySpec);
    guard('the grep spec', grepSpec);
    SPEC.suites.forEach(function (s) { guard(s.name, s.fn); });
    return runAsync().then(function () { return results; });
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
