/*
 * Gantt G0 assertions (task-groups plan §8.9, §10.1 "Naming"): note-less
 * titles through setTask and coalesced undo, titlesFrom, the list writer
 * (G1: regionParts with the list gate, the delimited list), Link note
 * as one patch, the clash check, invertHost for renameNote, and
 * store.renameTask / applyEffects / followTitles over the mock host. Also
 * the §9 naming strings. Runs under node (dev/run.js) and in the browser
 * (dev/auto_smoke.html); the source audit is node only.
 */
(function (global) {
  'use strict';
  var GT = global.GT, SPEC = GT.spec;
  var A = SPEC.api, ok = A.ok, eq = A.eq, acase = A.acase;
  var M = GT.model, U = GT.undo, B = GT.block, H = GT.host, S = GT.store, I = GT.i18n;
  var CH = 'chart-1';

  function C(data) { return M.coerce(data).chart; }
  // G1: a list chart, so the writer cases run on regionParts({list: true}).
  function chart() {
    return C({ v: 1, settings: { listHeading: 'Tasks' }, groups: [{ id: 'g1', title: 'Build' }], tasks: [
      { id: 't1', note: 'n1', title: 'Task one', start: '2026-10-03', end: '2026-10-10', group: 'g1' },
      { id: 'm1', note: null, title: 'Milestone', start: '2026-10-12', milestone: true, group: 'g1' }
    ] });
  }

  function modelSpec() {
    var c = chart();

    // setTask on a note-less task's title, and its inverse.
    var r = M.setTask(c, 'm1', { title: 'Kickoff' });
    eq('naming: setTask sets a note-less title', M.task(r.chart, 'm1').title, 'Kickoff');
    eq('naming: ... one inverse patch', r.inverse.length, 1);
    eq('naming: ... whose inverse restores the title', M.task(M.applyPatch(r.chart, r.inverse).chart, 'm1').title, 'Milestone');
    ok('naming: ... and touches nothing else', S.same(M.applyPatch(r.chart, r.inverse).chart, c));

    // Coalesced commits (key 'title:<id>', within U.COALESCE_MS) are one undo entry.
    var t = 1000, st = U.createStack({ now: function () { return t; } });
    var a = M.setTask(c, 'm1', { title: 'K' });
    st.push({ label: 'Rename', patches: a.inverse, coalesceKey: 'title:m1' });
    t += 300;
    var b = M.setTask(a.chart, 'm1', { title: 'Kickoff' });
    st.push({ label: 'Rename', patches: b.inverse, coalesceKey: 'title:m1' });
    eq('naming: two title commits within 800 ms coalesce into one undo entry', st.size().undo, 1);
    var u = st.undo(b.chart);
    eq('naming: ... whose undo restores the first title', M.task(u.chart, 'm1').title, 'Milestone');
    var t2 = 1000, st2 = U.createStack({ now: function () { return t2; } });
    st2.push({ label: 'Rename', patches: a.inverse, coalesceKey: 'title:m1' });
    t2 += U.COALESCE_MS + 1;
    st2.push({ label: 'Rename', patches: b.inverse, coalesceKey: 'title:m1' });
    eq('naming: ... commits further apart are their own entries (as the plan states)', st2.size().undo, 2);

    // titlesFrom.
    var facts = { n1: { title: 'Task one, renamed' } };
    var f = M.titlesFrom(r.chart, facts);
    eq('naming: titlesFrom leaves a note-less title alone', M.task(f, 'm1').title, 'Kickoff');
    eq('naming: titlesFrom replaces a noted title after a facts change', M.task(f, 't1').title, 'Task one, renamed');
    ok('naming: titlesFrom with unchanged facts returns the same chart', M.titlesFrom(c, { n1: { title: 'Task one' } }) === c);

    // The list writer (G1: regionParts with the list gate; the list is the
    // region's text above the fence).
    function listOf(ch) { var t = B.regionParts(ch, null, { list: true }).text; return t.slice(0, t.indexOf('```')); }
    var mir = listOf(f);
    ok('naming: the list writer writes no line for a note-less milestone', mir.indexOf('Kickoff') < 0 && mir.indexOf('Milestone') < 0 && mir === '## Tasks\n\n### Build\n- [Task one, renamed](synapseresource://note/n1?via=gantt) · 2026-10-03 → 2026-10-10\n\n', mir);
    ok('naming: ... and the new link text for a noted task after titlesFrom', mir.indexOf('\n- [Task one, renamed](synapseresource://note/n1?via=gantt)') >= 0, mir);
    ok('naming: ... not the old one', mir.indexOf('[Task one]') < 0, mir);

    // Link note: one patch {note, title}; its inverse restores note null and the old title.
    var ln = M.setTask(c, 'm1', { note: 'n9', title: 'Picked note' });
    eq('naming: Link note is one patch', ln.inverse.length, 1);
    eq('naming: ... setting note and title together', M.task(ln.chart, 'm1').note + '|' + M.task(ln.chart, 'm1').title, 'n9|Picked note');
    ok('naming: ... still a milestone', M.task(ln.chart, 'm1').milestone === true);
    var back = M.applyPatch(ln.chart, ln.inverse).chart;
    eq('naming: ... whose inverse restores note: null and the old title', M.task(back, 'm1').note + '|' + M.task(back, 'm1').title, 'null|Milestone');
    ok('naming: ... exactly', S.same(back, c));
    var mirL = listOf(M.titlesFrom(ln.chart, {}));
    ok('naming: the linked milestone is written with the picker title, not "Milestone"', mirL.indexOf('◆ [Picked note](synapseresource://note/n9?via=gantt)') >= 0 && mirL.indexOf('[Milestone]') < 0, mirL);

    // The clash check: the note is held by another task.
    eq('naming: holderOf finds the task holding a note', (M.holderOf(c, 'n1') || {}).id, 't1');
    eq('naming: holderOf is null for a free note', M.holderOf(c, 'n9'), null);
    eq('naming: holderOf is null for no note', M.holderOf(c, null), null);
    var drop = M.setTask(c, 'm1', { note: 'n1', title: 'Task one' });
    ok('naming: why the check comes first: setTask drops a held note silently and keeps the title change', M.task(drop.chart, 'm1').note === null && M.task(drop.chart, 'm1').title === 'Task one');

    // G0 review 1: only a CJK group title may wrap (render .tall).
    ok('hasCjk: CJK, kana and hangul titles', GT.render.hasCjk('设计与开发') && GT.render.hasCjk('テスト') && GT.render.hasCjk('설계') && GT.render.hasCjk('Build 阶段'));
    ok('hasCjk: Latin titles, empty and null', !GT.render.hasCjk('Discovery') && !GT.render.hasCjk('Über-Ärger ñ') && !GT.render.hasCjk('') && !GT.render.hasCjk(null));

    // invertHost for renameNote.
    var p = { op: 'host', kind: 'renameNote', args: { noteId: 'n1', title: 'New', prev: 'Old' } };
    var inv = M.invertHost(p);
    eq('naming: invertHost swaps title and prev for renameNote', JSON.stringify(inv), JSON.stringify({ op: 'host', kind: 'renameNote', args: { noteId: 'n1', title: 'Old', prev: 'New' } }));
    eq('naming: ... and twice is the patch again', JSON.stringify(M.invertHost(inv)), JSON.stringify(p));
    var ap = M.applyPatch(c, [p]);
    ok('naming: applyPatch carries the renameNote effect and leaves the chart alone', ap.chart === c && ap.effects.length === 1 && ap.effects[0].kind === 'renameNote' && ap.inverse[0].args.title === 'Old');
  }

  /* ------------------------------------------------ store over the mock */

  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function timers() {
    var list = [];
    return {
      set: function (f, ms) { var x = { f: f, ms: ms }; list.push(x); return x; },
      clear: function (x) { var i = list.indexOf(x); if (i >= 0) list.splice(i, 1); },
      fire: function (ms) {
        var a = list.filter(function (x) { return ms === undefined || x.ms === ms; });
        a.forEach(function (x) { var i = list.indexOf(x); if (i >= 0) list.splice(i, 1); x.f(); });
        return a.length;
      },
      count: function (ms) { return list.filter(function (x) { return ms === undefined || x.ms === ms; }).length; }
    };
  }
  var clock = 1790500000000;
  function world(o) {
    o = o || {};
    var c = chart();
    var seed = [{ id: CH, title: 'Plan', content: 'Intro.\n\n' + B.region(c, null, { list: true }) },
      { id: 'n1', title: 'Task one', type: 'task' }, { id: 'n9', title: 'Picked note', type: 'task' }];
    var mock = H.installMock(seed, Object.assign({ storage: new Map(), global: false, appId: 'gantt-naming-test' }, o.mock || {}));
    var tm = timers();
    var st = S.create({
      host: mock.host, frame: function (f) { return setTimeout(f, 0); }, cancelFrame: function (h) { clearTimeout(h); },
      now: function () { clock += 7; return clock; }, hidden: function () { return false; }, setTimeout: tm.set, clearTimeout: tm.clear
    });
    var e = { mock: mock, st: st, tm: tm };
    if (o.approved) { st.launch.sessionApproved = true; mock.sessionApproved = true; }
    return st.boot().then(function () { return st.open({ noteId: CH, read: B.read(mock.content(CH)), text: mock.content(CH) }); }).then(function (r) {
      e.s = r.session;
      return Promise.all([e.s.checked, e.s.resolved]);
    }).then(function () { return sleep(5); }).then(function () {
      if (o.mode) st.launch.mode = o.mode;
      mock.resetCounts();
      return e;
    });
  }
  function titleEntries(e) {
    var out = [];
    e.mock.updates.forEach(function (list) { list.forEach(function (x) { if (x.modification && x.modification.title) out.push(x); }); });
    return out;
  }

  function storeSpec() {
    acase('G0 renameTask: one updateNotes title entry, facts refreshed, a renameNote patch', function () {
      var e, before, stack = U.createStack({});
      return world({ approved: true }).then(function (w) {
        e = w; before = e.s.live;
        eq('renameTask: the facts hold the old title first', e.s.facts.n1.title, 'Task one');
        return e.st.renameTask('n1', 'Task one, renamed');
      }).then(function (r) {
        eq('renameTask: exactly one updateNotes', e.mock.count('updateNotes'), 1);
        eq('renameTask: ... with one entry {id, modification: {title: {new_title}}}', JSON.stringify(e.mock.updates[0]),
          JSON.stringify([{ id: 'n1', modification: { title: { new_title: 'Task one, renamed' } } }]));
        eq('renameTask: the note is renamed', e.mock.note('n1').title, 'Task one, renamed');
        eq('renameTask: that note\'s facts are refreshed', e.s.facts.n1.title, 'Task one, renamed');
        ok('renameTask: returns the host patch', r.ok && JSON.stringify(r.patch) === JSON.stringify({ op: 'host', kind: 'renameNote', args: { noteId: 'n1', title: 'Task one, renamed', prev: 'Task one' } }), JSON.stringify(r));
        ok('renameTask: ... and its inverse', JSON.stringify(r.inverse) === JSON.stringify([M.invertHost(r.patch)]));
        ok('renameTask: the chart itself is not touched', e.s.live === before);
        eq('renameTask: no chart write', e.mock.updates.filter(function (l) { return l.some(function (x) { return x.id === CH; }); }).length, 0);
        stack.push({ label: 'Rename note', patches: r.inverse });
        e.mock.resetCounts();
        return e.st.undo(stack);
      }).then(function (u) {
        ok('renameTask undo: through applyEffects', u.ok);
        eq('renameTask undo: one updateNotes', e.mock.count('updateNotes'), 1);
        eq('renameTask undo: ... one entry with the old title', JSON.stringify(e.mock.updates[0]), JSON.stringify([{ id: 'n1', modification: { title: { new_title: 'Task one' } } }]));
        eq('renameTask undo: the facts follow', e.s.facts.n1.title, 'Task one');
        e.mock.resetCounts();
        return e.st.redo(stack);
      }).then(function (rd) {
        ok('renameTask redo: renames again in one entry', rd.ok && e.mock.count('updateNotes') === 1 && e.mock.note('n1').title === 'Task one, renamed');
      });
    });

    acase('G0 renameTask: prev from a meta read when the facts have no title', function () {
      var e;
      return world().then(function (w) {
        e = w;
        delete e.s.facts.n1;
        return e.st.renameTask('n1', 'Fresh');
      }).then(function (r) {
        eq('renameTask: prev read from the note', r.ok && r.patch.args.prev, 'Task one');
      });
    });

    acase('G0 review 1: prev falls back to the chart title when the read fails', function () {
      var e;
      return world().then(function (w) {
        e = w;
        delete e.s.facts.n1;
        e.mock.script('runQuery', [{ success: false, error: 'db busy' }]);
        return e.st.renameTask('n1', 'Fresh');
      }).then(function (r) {
        ok('renameTask: a failed meta read takes prev from the task\'s JSON title', r.ok && r.patch.args.prev === 'Task one' && r.inverse.length === 1 && r.inverse[0].args.title === 'Task one', JSON.stringify(r));
        // No title anywhere: no undo entry rather than an undo that sends null.
        var s = e.s;
        s.live = M.setTask(s.live, 't1', { title: '' }).chart;
        delete s.facts.n1;
        e.mock.script('runQuery', [{ success: false, error: 'db busy' }]);
        return e.st.renameTask('n1', 'Fresher');
      }).then(function (r) {
        ok('renameTask: with no previous title known, no inverse (no undo entry)', r.ok && r.inverse.length === 0 && e.mock.note('n1').title === 'Fresher', JSON.stringify(r));
        e.s.title = null;
        e.mock.script('runQuery', [{ success: false, error: 'db busy' }]);
        return e.st.renameChart('New plan');
      }).then(function (r) {
        ok('renameChart: a failed title read gives no inverse (no undo entry)', r.ok && r.inverse.length === 0 && e.mock.note(CH).title === 'New plan', JSON.stringify(r));
      });
    });

    acase('G0 renameTask: a denial and a failure', function () {
      var e, before;
      return world().then(function (w) {
        e = w; before = e.s.live;
        e.mock.approvals.push('deny');
        return e.st.renameTask('n1', 'Nope');
      }).then(function (r) {
        eq('renameTask: a denial returns denied', r.ok + '|' + r.reason, 'false|denied');
        eq('renameTask: ... the facts are unchanged', e.s.facts.n1.title, 'Task one');
        ok('renameTask: ... the chart is unchanged', e.s.live === before);
        eq('renameTask: ... the note is unchanged', e.mock.note('n1').title, 'Task one');
        e.mock.sessionApproved = true;
        e.mock.refuse('n1');
        return e.st.renameTask('n1', 'Nope');
      }).then(function (r) {
        eq('renameTask: any other failure maps to failed', r.ok + '|' + r.reason, 'false|failed');
        eq('renameTask: ... the facts are unchanged', e.s.facts.n1.title, 'Task one');
        ok('renameTask: ... the chart is unchanged', e.s.live === before);
      });
    });

    acase('G0 followTitles: debounce in approved auto, none otherwise, never an undo step', function () {
      var e;
      return world({ approved: true }).then(function (w) {
        e = w;
        return e.st.renameTask('n1', 'Renamed');
      }).then(function () {
        e.mock.resetCounts();
        var mode = e.st.followTitles();
        eq('followTitles: approved auto mode saves on the debounce', mode, 'debounce');
        eq('followTitles: the JSON title follows the note', M.task(e.s.live, 't1').title, 'Renamed');
        eq('followTitles: ... a debounce is armed, nothing written yet', e.tm.count(S.DEBOUNCE_MS) + ':' + e.mock.count('updateNotes'), '1:0');
        eq('followTitles: a second call changes nothing', e.st.followTitles(), null);
        e.tm.fire(S.DEBOUNCE_MS);
        return sleep(20);
      }).then(function () {
        eq('followTitles: one chart save after the debounce', e.mock.count('updateNotes'), 1);
        var c = B.read(e.mock.content(CH));
        eq('followTitles: ... the saved JSON title', M.task(c.chart, 't1').title, 'Renamed');
        ok('followTitles: ... and the new link text', e.mock.content(CH).indexOf('[Renamed](synapseresource://note/n1?via=gantt)') >= 0);
        return world({ mode: 'manual' });
      }).then(function (w) {
        e = w;
        return e.st.renameTask('n1', 'Manual name');
      }).then(function (r) {
        ok('followTitles (manual): the rename itself went through', r.ok && e.mock.count('updateNotes') === 1);
        eq('followTitles (manual): no save', e.st.followTitles(), 'none');
        eq('followTitles (manual): ... the chart has the title', M.task(e.s.live, 't1').title, 'Manual name');
        eq('followTitles (manual): ... nothing armed or written', e.tm.count(S.DEBOUNCE_MS) + ':' + e.mock.count('updateNotes'), '0:1');
        eq('followTitles (manual): ... the pill shows unsaved changes', e.st.ui().pill, 'unsaved');
        return world();
      }).then(function (w) {
        e = w;
        return e.st.renameTask('n1', 'Before approval');
      }).then(function () {
        eq('followTitles (auto, not approved yet): no save', e.st.followTitles(), 'none');
        eq('followTitles (auto, not approved yet): ... nothing armed', e.tm.count(S.DEBOUNCE_MS), 0);
      });
    });
  }

  /* --------------------------------------------------- the §9 strings */

  var ZH_G0 = {
    'Note title': '笔记标题',
    'Renames the note itself, everywhere it appears.': '会重命名笔记本身，所有出现的地方都会改变。',
    'The note was not renamed: not approved': '笔记未重命名：未获允许',
    'The note was not renamed': '笔记未重命名',
    'Dates are written to the note the next time you move it': '下次移动时会把日期写入笔记',
    'New milestone': '新里程碑',
    'Link to a note…': '关联笔记…',
    'Link note…': '关联笔记…',
    'Already on this chart': '已在此图表中',
    'Rename note': '重命名笔记',
    'Link note': '关联笔记'
  };
  var REUSED = ['Title', 'Milestone', 'Add milestone', 'Date', 'Rename', 'Cancel', 'Group', 'No group', 'Untitled', 'Create', 'Note'];
  function i18nSpec() {
    Object.keys(ZH_G0).forEach(function (k) { eq('G0 i18n: zh-CN for "' + k + '"', I.ZH[k], ZH_G0[k]); });
    REUSED.forEach(function (k) { ok('G0 i18n: the reused string "' + k + '" has a zh-CN entry', typeof I.ZH[k] === 'string' && I.ZH[k].length > 0); });
    var src = global.GT_SOURCES;
    if (!src || !GT.m9) { ok('G0 i18n: the source check needs GT_SOURCES (node only)', true); return; }
    var lits = [];
    ['app.js', 'sheet.js'].forEach(function (f) { GT.m9.literals(src[f]).forEach(function (l) { lits.push(l.text); }); });
    Object.keys(ZH_G0).forEach(function (k) { ok('G0 i18n: the audit sees "' + k + '" in app.js or sheet.js', lits.indexOf(k) >= 0); });
  }

  SPEC.suites.push({ name: 'the G0 naming model spec', fn: modelSpec });
  SPEC.suites.push({ name: 'the G0 naming store spec', fn: storeSpec });
  SPEC.suites.push({ name: 'the G0 naming i18n spec', fn: i18nSpec });

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
