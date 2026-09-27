/*
 * Gantt G2 store assertions (task-groups plan §5.5, §6, §10.1 "store",
 * milestone G2): the fold at open and on a silent reload (the `list` event
 * and `la`), merges of a folded note, the removal, seed, promote, additions
 * and listed-more-than-once inputs and actions, the §6.6 walkthroughs (a) to
 * (q), the G2-tagged fixture assertions of list_spec.js, and the seeds
 * property. Built on store_spec.js's helpers (SPEC.storeKit), against the
 * mock host. Runs under node (dev/run.js) and in the browser.
 */
(function (global) {
  'use strict';
  var GT = global.GT, B = GT.block, M = GT.model, S = GT.store, U = GT.undo, SPEC = GT.spec;
  var A = SPEC.api, ok = A.ok, eq = A.eq, same = A.same, acase = A.acase, fix = A.fix;
  var K = null, CH = 'chart-1';

  function json(x) { return JSON.stringify(x); }
  function count(hay, needle) { return hay.split(needle).length - 1; }
  var EXTRA = [['n-wire', 'Wireframes'], ['n-style', 'Style guide'], ['n-api', 'API'], ['n-vendor', 'Vendor contract'], ['n-qa', 'QA pass'],
    ['n-test', 'Test plan'], ['n-reg', 'Regression pass']].map(function (x) { return { id: x[0], title: x[1], type: 'task' }; });
  function seedOf(text) { return [{ id: CH, title: 'Plan', content: text }].concat(K.TASKS, EXTRA); }
  function rd(text) { return B.read(text, K.GATE); }
  function ups(e) { return e.mock.count('updateNotes'); }
  function content(e) { return e.mock.content(CH); }
  function gOf(c, id) { var t = M.task(c, id); return t ? t.group : undefined; }
  function titles(c) { return c.groups.map(function (g) { return g.title; }).join(','); }
  // The cache entry of the chart, as stored in appState.
  function cacheOf(e) { var st = e.mock.state(); return st && st.charts ? st.charts[CH] || null : null; }
  // The removal gate: the store wrote this block (its body key is `wk`).
  function wk(text, la) {
    var c = {};
    c[CH] = { at: 1, facts: {}, wk: rd(text).bodyKey };
    if (la) c[CH].la = la;
    return { v: 1, charts: c };
  }
  // A store opened on `text` with `list` events recorded from the start.
  function open(text, o) {
    o = o || {};
    var e = K.env({ seed: o.db ? null : seedOf(text), db: o.db, storage: o.storage, mock: o.mock });
    e.lists = [];
    e.st.on('list', function (x) { e.lists.push(x); });
    if (o.state) e.mock.setState(o.state);
    if (o.mode) e.st.launch.mode = o.mode;
    if (o.approved !== false) { e.st.launch.sessionApproved = true; e.mock.sessionApproved = true; }
    return e.st.boot().then(function () {
      var t = content(e);
      return e.st.open({ noteId: CH, read: B.read(t), text: t });
    }).then(function (r) {
      e.s = r.session;
      return Promise.all([e.s.checked, e.s.resolved]);
    }).then(function () { return K.settle(e); }).then(function () { return e; });
  }
  function again(e, o) { return open(null, Object.assign({ db: e.mock.db, storage: e.storage }, o || {})); }
  function resume(e) { return e.mock.resume().then(function () { return K.settle(e); }); }
  function stackWith(r, label) { var st = U.createStack(); st.push({ label: label || 'x', patches: r.inverse }); return st; }

  var L = {
    kick: '- [Kickoff](synapseresource://note/n-kick?via=gantt) · 2026-09-30',
    int: '- [Customer interviews](synapseresource://note/n-int?via=gantt) · 2026-10-01 → 2026-10-09',
    comp: '- [Competitive teardown](synapseresource://note/n-comp?via=gantt) · 2026-10-05 → 2026-10-14',
    sync: '- [Sync engine](synapseresource://note/n-sync?via=gantt) · 2026-10-12 → 2026-11-06',
    beta: '- ◆ [Beta cut](synapseresource://note/n-beta?via=gantt) · 2026-11-09'
  };
  // §5.1's chart with short note ids, as the writer writes it (no fold).
  function base() {
    return fix('list-new-heading.md').replace('\n\n### QA\n' + L.beta, '').replace(L.sync + '\n', L.sync + '\n' + L.beta + '\n');
  }
  function moved() { return base().replace(L.sync + '\n', '').replace(L.comp + '\n', L.comp + '\n' + L.sync + '\n'); }

  function syncSpec() {
    K = SPEC.storeKit;
    CH = K.CH;
    var seen = {};
    function named(n) { seen[n] = true; return n; }

    acase('G2 base note: canonical (no fold)', function () {
      var r = rd(base());
      ok('G2 base: the base note folds to nothing', r.key === r.bodyKey && r.list.sections.length === 4, base());
      ok('G2 base: moving Sync engine under Discovery folds', rd(moved()).key !== rd(moved()).bodyKey);
    });

    acase('§6.6 (a) move in the note, chart closed: folded at open, no write, one list event, once per state (la)', function () {
      var e, e2, e3, key;
      return open(moved()).then(function (w) {
        e = w;
        key = e.s.key;
        eq('(a) Sync engine is in Discovery', gOf(e.s.live, 't3'), 'g1');
        ok('(a) live = base (clean), key composite', S.same(e.s.live, e.s.base) && key.indexOf(rd(moved()).bodyKey + '#') === 0);
        eq('(a) no write, no journal entry, pill saved', ups(e) + '|' + json(K.stored(e)) + '|' + e.st.ui().pill, '0|null|saved');
        eq('(a) one list event with the move', json(e.lists.map(function (x) { return x.report.moved; })), json([[{ id: 't3', from: 'g2', to: 'g1' }]]));
        ok('(a) the toast is pending once (takeFold), then gone', !!e.st.takeFold() && e.st.takeFold() === null);
        eq('(a) la (the composite key\'s hash) goes to the cache', (e.st.cache.get(CH) || {}).la, B.hash(key));
        return e.st.state.flush().then(function () {
          eq('(a) ... and is stored in appState', (cacheOf(e) || {}).la, B.hash(key));
          return again(e);
        });
      }).then(function (w) {
        e2 = w;
        eq('(a) a reopen of the same note state shows no toast (la)', e2.lists.length + '|' + (e2.st.takeFold() === null), '0|true');
        ok('(a) ... and still folds', gOf(e2.s.live, 't3') === 'g1' && e2.s.key === key);
        e2.mock.setNote(CH, content(e2).replace(L.beta + '\n', '').replace(L.int + '\n', L.int + '\n' + L.beta + '\n'));
        return again(e2);
      }).then(function (w) {
        e3 = w;
        eq('(a) another note state shows it again', e3.lists.length, 1);
        eq('(a) ... with both moves the note now shows', json(e3.lists[0].report.moved), json([{ id: 't4', from: 'g2', to: 'g1' }, { id: 't3', from: 'g2', to: 'g1' }]));
      });
    });

    acase('§6.6 (b) move in the note, chart open and clean: the resume folds silently, list once', function () {
      var e;
      return open(base()).then(function (w) {
        e = w;
        eq('(b) nothing at open', e.lists.length, 0);
        e.mock.setNote(CH, moved());
        return resume(e);
      }).then(function () {
        eq('(b) the resume folded Sync engine into Discovery', gOf(e.s.live, 't3'), 'g1');
        ok('(b) clean, no write', S.same(e.s.live, e.s.base) && ups(e) === 0);
        eq('(b) one list event', e.lists.length, 1);
        return resume(e);
      }).then(function () {
        eq('(b) a second resume over the same note: no second event', e.lists.length, 1);
      });
    });

    acase('§6.6 (c) move in the note with unsaved edits (manual): the save merges the fold; one write carries both; no toast', function () {
      var e;
      return open(base(), { mode: 'manual' }).then(function (w) {
        e = w;
        e.st.commit(M.setTask(e.s.live, 't1', { color: 'rose' }).chart);
        e.mock.setNote(CH, moved());
        return e.st.save();
      }).then(function (r) {
        eq('(c) one try in manual: re-read and merged, retry-needed', r.reason, 'retry-needed');
        ok('(c) live holds the fold and the edit', gOf(e.s.live, 't3') === 'g1' && M.task(e.s.live, 't1').color === 'rose');
        return e.st.save();
      }).then(function (r) {
        var t = content(e), fr = rd(t);
        ok('(c) the tap saves both', r.ok && gOf(fr.chart, 't3') === 'g1' && M.task(fr.chart, 't1').color === 'rose' && fr.key === fr.bodyKey, t);
        ok('(c) the note list shows the move', t.indexOf(L.comp + '\n' + L.sync + '\n\n### Build\n' + L.beta) > 0, t);
        eq('(c) a fold inside absorb shows no toast', e.lists.length, 0);
        K.noWhole('(c)', e);
      });
    });

    acase('§6.6 (d) the same task moved both ways: the conflict <id>.group', function () {
      var e;
      return open(base(), { mode: 'manual' }).then(function (w) {
        e = w;
        e.st.commit(M.moveToGroup(e.s.live, 't3', 'g3').chart);
        e.mock.setNote(CH, moved());
        return e.st.save();
      }).then(function (r) {
        ok('(d) conflict on t3.group', r.reason === 'conflict' && r.conflicts.some(function (c) { return c.key === 't3.group' || c === 't3.group' || c.path === 't3.group' || json(c).indexOf('t3.group') >= 0; }), json(r.conflicts));
      });
    });

    acase('§6.6 (e) new marker with new notes: new group, toast; Added in the note; Add places both in QA, one save, lines MARKED; Undo', function () {
      var e, qa, r0, text = base().replace('### Launch\n\n```', '### Launch\n\n### QA\n[Test plan](synapseresource://note/n-test)\n[Regression pass](synapseresource://note/n-reg)\n\n```');
      return open(text).then(function (w) {
        e = w;
        qa = e.s.live.groups[3];
        ok('(e) QA folded in as a new group', !!qa && qa.title === 'QA' && e.s.key !== rd(text).bodyKey);
        eq('(e) the toast names the new group', json(e.lists[0].report.added), json([{ id: qa.id, title: 'QA' }]));
        var ls = e.st.listState();
        eq('(e) Added in the note: both links, in QA, no key gate (the store never wrote this block)',
          json(ls.offers.map(function (o) { return o.note + '|' + o.group; })), json(['n-test|' + qa.id, 'n-reg|' + qa.id]));
        eq('(e) ... and no removal banner (the gate)', e.st.listReport(), null);
        return e.st.addToChart(CH, ls.offers.map(function (o) { return { id: o.note, title: o.text, group: o.group, after: o.after, owner: o.owner, index: o.index }; }));
      }).then(function (r) {
        r0 = r;
        return K.settle(e);
      }).then(function () {
        var t = content(e), c = e.s.live;
        eq('(e) Add: two tasks in QA in note order', c.tasks.filter(function (x) { return x.group === qa.id; }).map(function (x) { return x.title; }).join(), 'Test plan,Regression pass');
        eq('(e) ... one save', ups(e), 1);
        ok('(e) ... the lines are MARKED once, the PLAIN ones gone', t.indexOf('### QA\n- [Test plan](synapseresource://note/n-test?via=gantt)') > 0 && count(t, 'note/n-test') === 1 && count(t, 'note/n-reg') === 1, t);
        eq('(e) ... no offer left', e.st.listState().offers.length, 0);
        return e.st.undo(stackWith(r0));
      }).then(function (u) {
        return K.settle(e).then(function () { return u; });
      }).then(function (u) {
        var t = content(e);
        ok('(e) Undo: the tasks are gone and the user\'s lines are back as they were', u.ok && e.s.live.tasks.length === 5 &&
          t.indexOf('### QA\n[Test plan](synapseresource://note/n-test)\n[Regression pass](synapseresource://note/n-reg)\n\n```') > 0, t);
      });
    });

    acase(named('list-foreign-links: Added in the note banner; Add places per note'), function () {
      var e, text = fix('list-foreign-links.md');
      return open(text).then(function (w) {
        e = w;
        var ls = e.st.listState();
        eq('list-foreign-links: Added in the note banner; Add places per note', json(ls.offers.map(function (o) { return o.note + '|' + o.group + '|' + o.after; })), json(['n-vendor|g1|t2', 'n-qa|g1|t2']));
        return e.st.addToChart(CH, ls.offers.map(function (o) { return { id: o.note, title: o.text, group: o.group, after: o.after, owner: o.owner, index: o.index }; }));
      }).then(function () { return K.settle(e); }).then(function () {
        var c = e.s.live, t = content(e);
        eq('list-foreign-links: Add: after Competitive teardown in note order', c.tasks.map(function (x) { return x.title; }).slice(0, 5).join(), 'Kickoff,Customer interviews,Competitive teardown,Vendor contract,QA pass');
        ok('list-foreign-links: ... one line each, the indented and heading-scoped links kept', count(t, 'note/n-vendor') === 1 && count(t, 'note/n-qa') === 1 &&
          t.indexOf('  - [Reference](synapseresource://note/n-ref)') > 0 && t.indexOf('#### Links\n[Wiki](synapseresource://note/n-wiki)') > 0, t);
        eq('list-foreign-links: ... stable: the next save writes nothing', rd(t).key, rd(t).bodyKey);
      });
    });

    acase('§6.6 (f) marker deleted: Build held, removal banner; Remove moves its tasks to their place; Restore list writes it back', function () {
      var e, text = base().replace('\n\n### Build\n', '\n');
      return open(text, { state: wk(text) }).then(function (w) {
        e = w;
        eq('(f) Build kept, its tasks held', gOf(e.s.live, 't3') + gOf(e.s.live, 't4') + '|' + titles(e.s.live), 'g2g2|Discovery,Build,Launch');
        var g = e.st.listReport();
        eq('(f) removal banner: Build (group), no task', json([g.goneGroups, g.deleted]), json([['g2'], []]));
        eq('(f) ... placements from the note', json(g.placement), json({ t3: { group: 'g1', after: 't2' }, t4: { group: 'g1', after: 't3' } }));
        var r = e.st.removeGone(g.deleted, g.goneGroups, g.placement);
        ok('(f) Remove: one commit', r.ok && r.inverse.length > 0);
        return K.settle(e);
      }).then(function () {
        var t = content(e);
        eq('(f) ... one save that leaves the list as the user left it', ups(e) + '|' + t.slice(t.indexOf('## Tasks'), t.indexOf('```')), '1|' + text.slice(text.indexOf('## Tasks'), text.indexOf('```')));
        eq('(f) ... Build gone, tasks in Discovery', titles(e.s.live) + '|' + gOf(e.s.live, 't3') + gOf(e.s.live, 't4'), 'Discovery,Launch|g1g1');
        eq('(f) ... no banner left', e.st.listReport(), null);
        return open(text, { state: wk(text) });
      }).then(function (w) {
        e = w;
        return e.st.restoreMirror().then(function () { return K.settle(e); });
      }).then(function () {
        ok('(f) Restore list writes ### Build back with its tasks', content(e).indexOf('### Build\n' + L.sync + '\n' + L.beta) > 0 && e.st.listReport() === null, content(e));
      });
    });

    acase(named('list-heading-deleted: removal banner; Remove moves held tasks to their placement'), function () {
      var e, text = fix('list-heading-deleted.md');
      return open(text, { state: wk(text) }).then(function (w) {
        e = w;
        var g = e.st.listReport();
        ok('list-heading-deleted: removal banner; Remove moves held tasks to their placement', !!g && json(g.goneGroups) === '["g2"]' &&
          e.st.removeGone(g.deleted, g.goneGroups, g.placement).ok, json(g));
        return K.settle(e);
      }).then(function () {
        ok('list-heading-deleted: ... one save, Sync engine and Beta cut under Discovery after Competitive teardown',
          ups(e) === 1 && content(e).indexOf('### Discovery\n' + L.int + '\n' + L.comp + '\n' + L.sync + '\n' + L.beta + '\n\n### Launch') > 0, content(e));
      });
    });

    acase('§6.6 (g) marker and its lines deleted: the banner lists the group and the tasks; Remove takes all in one step; the gate', function () {
      var e, text = base().replace('### Build\n' + L.sync + '\n' + L.beta + '\n\n', '');
      return open(text).then(function (w) {
        e = w;
        eq('(g) the removal gate: a block this store never wrote shows no banner', e.st.listReport(), null);
        return open(text, { state: wk(text) });
      }).then(function (w) {
        e = w;
        var g = e.st.listReport();
        eq('(g) group and tasks', json([g.goneGroups, g.deleted]), json([['g2'], ['t3', 't4']]));
        var r = e.st.removeGone(g.deleted, g.goneGroups, g.placement);
        ok('(g) one commit', r.ok);
        return K.settle(e);
      }).then(function () {
        eq('(g) one save; Build and its tasks gone', ups(e) + '|' + titles(e.s.live) + '|' + e.s.live.tasks.length, '1|Discovery,Launch|3');
        eq('(g) the saved list is the user\'s', content(e).slice(content(e).indexOf('## Tasks'), content(e).indexOf('```')), text.slice(text.indexOf('## Tasks'), text.indexOf('```')));
      });
    });

    acase('§6.6 (h) a note under a task moves with it', function () {
      var e;
      return open(fix('list-attached-notes.md')).then(function (w) {
        e = w;
        e.st.commit(M.moveToGroup(e.s.live, 't3', 'g3').chart);
        return K.settle(e);
      }).then(function () {
        ok('(h) the note line moved with Sync engine', content(e).indexOf('### Launch\n' + L.sync + '\n  - waiting on legal') > 0, content(e));
      });
    });

    acase('§6.6 (i) prose inside the list: attached, no banner, no fold', function () {
      var e, text = base().replace(L.comp + '\n', L.comp + '\nNext: hire a PM\n');
      return open(text, { state: wk(text) }).then(function (w) {
        e = w;
        var ls = e.st.listState();
        ok('(i) no fold, no banner input', e.s.key === rd(text).bodyKey && e.st.listReport() === null && !ls.seed && !ls.promote.length && !ls.offers.length && !ls.ambiguous.length, json(ls));
        e.st.commit(M.setTask(e.s.live, 't1', { color: 'rose' }).chart);
        return K.settle(e);
      }).then(function () {
        ok('(i) kept in place by the next save', content(e).indexOf(L.comp + '\n\nNext: hire a PM\n\n### Build') > 0, content(e));
      });
    });

    acase('§6.6 (j) list turned off: the blocks go above the fence as user text', function () {
      var e;
      return open(base().replace(L.comp + '\n', L.comp + '\n  - three vendors\n')).then(function (w) {
        e = w;
        e.st.commit(M.setSettings(e.s.live, { mirror: false }).chart);
        return K.settle(e);
      }).then(function () {
        ok('(j) spilled above the fence', content(e).indexOf('Plan for the release.\n\n  - three vendors\n\n```synapse-gantt') === 0, content(e));
      });
    });

    acase('§6.6 (k) an older build\'s list: LEGACY markers, ambiguous tasks, duplicates held, no group, banner', function () {
      var e;
      return open(fix('list-older-build.md')).then(function (w) {
        e = w;
        var ls = e.st.listState();
        ok('(k) no group created, no fold', e.s.live.groups.length === 3 && e.lists.length === 0, titles(e.s.live));
        eq('(k) listed more than once: every task and both markers', json([ls.ambiguous, ls.duplicates.map(function (d) { return d.gid; })]), json([['t0', 't1', 't2', 't3', 't4'], ['g1', 'g2']]));
      });
    });

    acase('§6.6 (l) two devices, one on a legacy chart: default heading, no toast; after a save the other folds nothing', function () {
      var e, e2, text = fix('list-legacy-migrate.md');
      var M1 = [['8f0c1e2a-5b7d-4c11-9a0e-2f6b3c9d1e01', 'Customer interviews'], ['1b7d4e90-0c2a-4f5e-8d61-7a3b2c1d0e02', 'Competitive teardown'],
        ['77aa3c21-9e4f-4b6d-a0c8-5d2e1f3a4b03', 'Sync engine'], ['c3e98a10-6d5b-4e2f-b1a7-0c9d8e7f6a04', 'Beta cut']];
      var db = GT.host.installMock([{ id: CH, title: 'Plan', content: text }].concat(M1.map(function (x) { return { id: x[0], title: x[1], type: 'task' }; })), { global: false }).db;
      return open(null, { db: db }).then(function (w) {
        e = w;
        ok('(l) legacy: composite key from the default heading, no list event', e.s.key.indexOf('#') > 0 && e.lists.length === 0 && e.st.takeFold() === null);
        e.st.commit(M.setTask(e.s.live, 't2', { color: 'rose' }).chart);
        return K.settle(e);
      }).then(function () {
        ok('(l) the save wrote the delimited region', content(e).indexOf('## Tasks') > 0);
        return open(null, { db: db, mock: { locale: 'zh-CN' } });
      }).then(function (w) {
        e2 = w;
        ok('(l) the other device reads a body key, no fold, no toast', e2.s.key === rd(content(e2)).bodyKey && e2.lists.length === 0);
      });
    });

    acase('§6.6 (m) text added above the list heading while unsaved edits wait: the save does not miss and leaves it', function () {
      var e;
      return open(base(), { mode: 'manual' }).then(function (w) {
        e = w;
        e.st.commit(M.setTask(e.s.live, 't1', { color: 'rose' }).chart);
        e.mock.setNote(CH, content(e).replace('Plan for the release.\n', 'Plan for the release.\nA line added above.\n'));
        e.mock.resetCounts();
        return e.st.save();
      }).then(function (r) {
        ok('(m) one write, first try', r.ok && ups(e) === 1);
        var t = content(e);
        ok('(m) the added line is kept, the edit is saved', t.indexOf('Plan for the release.\nA line added above.\n\n## Tasks') === 0 && /"color":"rose"/.test(t), t);
        eq('(m) old_text was exactly the region', e.mock.updates[0][0].modification.content.old_text, base().slice(base().indexOf('## Tasks')));
      });
    });

    acase('§6.6 (o) crash, then the note was folded: step 4 on chart keys, step 5 merges, else Restore', function () {
      var S0 = rd(base()).chart, A0 = M.setTask(S0, 't1', { color: 'rose' }).chart, F = rd(moved()).chart, e;
      return K.world({ seed: seedOf(moved()), entry: K.oldEntry(S0, F) }).then(function (w) {
        e = w;
        eq('(o) an entry equal to the folded chart: dropped by step 4', e.st.ui().banner + '|' + json(K.stored(e)), 'null|null');
        return K.world({ seed: seedOf(moved()), entry: K.oldEntry(S0, A0) });
      }).then(function (w) {
        e = w;
        eq('(o) an entry with other edits: Restore offered', e.st.ui().banner, 'restore');
        var r = e.st.journal.restore();
        ok('(o) Restore gives the edit and the fold', r.ok && M.task(e.s.live, 't1').color === 'rose' && gOf(e.s.live, 't3') === 'g1');
      });
    });

    acase('§6.6 (q) a line typed directly above the fence: attached to the last owner, written back in place', function () {
      var e, text = base().replace('### Launch\n\n```', '### Launch\nAsk Ana about the date\n```');
      return open(text).then(function (w) {
        e = w;
        e.st.commit(M.setTask(e.s.live, 't1', { color: 'rose' }).chart);
        return K.settle(e);
      }).then(function () {
        ok('(q) kept, then a blank line and the fence', content(e).indexOf('### Launch\n\nAsk Ana about the date\n\n```synapse-gantt') > 0 && e.s.live.groups.length === 3, content(e));
      });
    });

    // §6.6 (n), (p): the request's example and review 2 blocker 1 (below).
    function useSeedCase(file, variant) {
      acase(named('seed-basic: offer "3 tasks in 2 groups"; Use as groups: one commit, one save, lines replaced by the list') + (variant ? ' (' + variant + ')' : ''), function () {
        var e, text = fix(file), n0, res;
        return open(text).then(function (w) {
          e = w;
          var ls = e.st.listState();
          eq('seed-basic: offer "3 tasks in 2 groups"; Use as groups: one commit, one save, lines replaced by the list' + (variant ? ' (' + variant + ')' : ''),
            ls.seed ? ls.seed.tasks + '|' + ls.seed.groups.map(function (g) { return g.title; }).join() : 'none', '3|Design,Build');
          n0 = ups(e);
          var commits = 0, commit = e.st.commit;
          e.st.commit = function (c, o) { commits++; return commit(c, o); };
          return e.st.useSeed().then(function (r) { res = r; e.st.commit = commit; eq('seed ' + file + ': one commit', commits, 1); });
        }).then(function () { return K.settle(e); }).then(function () {
          var t = content(e), fr = rd(t);
          ok('seed ' + file + ': ok, one save', res.ok && ups(e) - n0 === 1, json(res));
          eq('seed ' + file + ': the groups and their tasks', json(fr.chart.groups.map(function (g) {
            return g.title + ':' + fr.chart.tasks.filter(function (x) { return x.group === g.id; }).map(function (x) { return x.title; }).join('+');
          })), json(['Design:Wireframes+Style guide', 'Build:API']));
          ok('seed ' + file + ': the user\'s lines are replaced by the list, the intro untouched', t.indexOf('Project notes.\n\n## Tasks\n\n') === 0 && count(t, '\n## Design') === 0 &&
            count(t, 'note/n-wire)') === 0 && t.indexOf('### Design\n- [Wireframes](synapseresource://note/n-wire?via=gantt)') > 0 && t.indexOf('### Build\n- [API](synapseresource://note/n-api?via=gantt)') > 0, t);
          ok('seed ' + file + ': Kickoff kept, one list, stable', count(t, 'n-kick?via=gantt') === 1 && count(t, '## Tasks') === 1 && fr.key === fr.bodyKey && !fr.seed, t);
          eq('seed ' + file + ': no offer after', e.st.listState().seed, null);
          return e.st.undo(stackWith(res));
        }).then(function () { return K.settle(e); }).then(function () {
          var fr = rd(content(e));
          ok('seed ' + file + ': Undo is one step back to the chart before', fr.chart.groups.length === 0 && fr.chart.tasks.length === 1, content(e));
        });
      });
    }
    useSeedCase('seed-basic.md', 'fence-only region');
    useSeedCase('seed-basic-mirror.md', 'legacy mirror region');
    useSeedCase('seed-basic-embed.md', 'embed line on top');

    acase(named('seed-after-save: Use as groups replaces seed and old region'), function () {
      var e, text = fix('seed-after-save.md');
      return open(text).then(function (w) {
        e = w;
        ok('seed-after-save: offered below a list heading', !!e.st.listState().seed);
        return e.st.useSeed();
      }).then(function (r) { return K.settle(e).then(function () { return r; }); }).then(function (r) {
        var t = content(e);
        ok('seed-after-save: Use as groups replaces seed and old region', r.ok && ups(e) === 1 && t.indexOf('Project notes.\n\n## Tasks\n\n' + L.kick + '\n\n### Design\n') === 0 && count(t, '## Tasks') === 1 && count(t, 'note/n-api') === 1, t);
      });
    });

    acase('§6.6 (n) the request\'s example, after a save: a bar moved first, then Use as groups', function () {
      var e, text = fix('seed-basic.md');
      return open(text).then(function (w) {
        e = w;
        e.st.commit(M.moveTask(e.s.live, 't0', 1).chart);
        return K.settle(e);
      }).then(function () {
        ok('(n) the save put the list heading under the seed; still offered', content(e).indexOf('[API](synapseresource://note/n-api)\n\n## Tasks') > 0 && !!e.st.listState().seed, content(e));
        return e.st.useSeed();
      }).then(function (r) { return K.settle(e).then(function () { return r; }); }).then(function (r) {
        var t = content(e);
        ok('(n) replaced both with one list', r.ok && count(t, '## Tasks') === 1 && count(t, '\n## Design') === 0 && t.indexOf('### Build\n- [API]') > 0, t);
      });
    });

    acase(named('seed-not-now: Not now in view state, seedSkip rides the next commit, undo clears it'), function () {
      var e, hash, st2 = U.createStack();
      return open(fix('seed-basic.md')).then(function (w) {
        e = w;
        hash = e.st.listState().seed.hash;
        ok('seed-not-now: Not now records the hash with no write', e.st.seedNotNow(hash) && ups(e) === 0);
        var res = M.setTask(e.s.live, 't0', { color: 'rose' });
        e.st.commit(res.chart);
        st2.push({ label: 'Colour', patches: res.inverse.concat(e.st.takeSkipInverse()) });
        return K.settle(e);
      }).then(function () {
        var t = content(e);
        ok('seed-not-now: Not now in view state, seedSkip rides the next commit, undo clears it', ups(e) === 1 && t.indexOf('"seedSkip":"' + hash + '"') > 0 && /"color":"rose"/.test(t), t);
        eq('seed-not-now: the offer is gone from the store too', e.st.listState().seed, null);
        return e.st.undo(st2);
      }).then(function () { return K.settle(e); }).then(function () {
        ok('seed-not-now: undo of that commit clears seedSkip and the colour', !e.s.live.settings.seedSkip && !M.task(e.s.live, 't0').color, content(e));
        eq('seed-not-now: a second commit carries nothing more', (e.st.commit(M.setTask(e.s.live, 't0', { color: 'teal' }).chart), e.st.takeSkipInverse().length), 0);
      });
    });

    acase('seed-not-now fixture: a seedSkip in the block hides the offer', function () {
      return open(fix('seed-not-now.md')).then(function (e) { eq('seed-not-now fixture: no offer', e.st.listState().seed, null); });
    });

    acase(named('list-typed-headings: Make groups gives two groups, tasks folded, written back as ###'), function () {
      var e, res;
      return open(fix('list-typed-headings.md')).then(function (w) {
        e = w;
        eq('list-typed-headings: promote offer', e.st.listState().promote.map(function (p) { return p.text; }).join(), 'Group 1,Group 2');
        res = e.st.makeGroups();
        return K.settle(e);
      }).then(function () {
        var t = content(e), fr = rd(t);
        ok('list-typed-headings: Make groups gives two groups, tasks folded, written back as ###', res.ok && titles(fr.chart) === 'Group 1,Group 2' &&
          fr.chart.tasks.map(function (x) { return x.group === null ? '-' : fr.chart.groups.map(function (g) { return g.id; }).indexOf(x.group); }).join() === '0,0,0,1,1' &&
          t.indexOf('## Tasks\n\n### Group 1\n' + L.kick) > 0 && t.indexOf('### Group 2\n' + L.sync) > 0 && count(t, '\n## Group') === 0 && ups(e) === 1 && fr.key === fr.bodyKey, t);
      });
    });

    acase(named('list-level-l-offer: Make groups, one save, Undo restores ## lines; Not now writes nothing'), function () {
      var e, text = fix('list-level-l-offer.md'), res, n0;
      return open(text).then(function (w) {
        e = w;
        eq('list-level-l-offer: Not now writes nothing (the offer is view state only)', ups(e), 0);
        res = e.st.makeGroups();
        return K.settle(e);
      }).then(function () {
        var t = content(e), fr = rd(t);
        ok('list-level-l-offer: Make groups, one save, Undo restores ## lines; Not now writes nothing', res.ok && ups(e) === 1 && titles(fr.chart) === 'Group 1,Discovery,Build,Group 2,Launch' &&
          M.task(fr.chart, 't0').group === null && fr.chart.tasks.every(function (x) { return x.group !== res.groups[0] && x.group !== res.groups[1]; }) &&
          count(t, '\n## Group') === 0 && t.indexOf('### Group 1\n\n### Discovery') > 0 && t.indexOf('### Group 2\n\n### Launch') > 0, t);
        n0 = ups(e);
        return e.st.undo(stackWith(res));
      }).then(function () { return K.settle(e); }).then(function () {
        var t = content(e);
        ok('list-level-l-offer: ... Undo restores the chart and the ## lines, one save', ups(e) - n0 === 1 && titles(e.s.live) === 'Discovery,Build,Launch' &&
          t.slice(t.indexOf('## Tasks'), t.indexOf('```')) === text.slice(text.indexOf('## Tasks'), text.indexOf('```')), t);
      });
    });

    acase('§6.6 (p) review 2 blocker 1: ## Group 1 above the first task, ## Group 2 lower: offered, never taken alone', function () {
      var e;
      return open(fix('list-typed-headings.md')).then(function (w) {
        e = w;
        ok('(p) both stay text: no group, no write', e.s.live.groups.length === 0 && ups(e) === 0 && e.s.key === rd(content(e)).bodyKey);
        e.st.commit(M.setTask(e.s.live, 't1', { color: 'rose' }).chart);
        return K.settle(e);
      }).then(function () {
        ok('(p) an unrelated save keeps them as ##', count(content(e), '\n## Group 1\n') === 1 && count(content(e), '### Group') === 0 && e.st.listState().promote.length === 2, content(e));
      });
    });

    acase(named('list-duplicate-marker: banner "Listed more than once"'), function () {
      return open(fix('list-duplicate-marker.md')).then(function (e) {
        var ls = e.st.listState();
        ok('list-duplicate-marker: banner "Listed more than once"', ls.duplicates.length === 1 && ls.duplicates[0].gid === 'g2' && gOf(e.s.live, 't0') === null, json(ls));
      });
    });
    acase(named('list-copy-inside: banner "Listed more than once"'), function () {
      return open(fix('list-copy-inside.md')).then(function (e) {
        eq('list-copy-inside: banner "Listed more than once"', json(e.st.listState().ambiguous), json(['t3']));
      });
    });
    acase('list-plain-elsewhere: in the "Listed more than once" input', function () {
      return open(fix('list-plain-elsewhere.md')).then(function (e) {
        eq('list-plain-elsewhere: plainElsewhere', json(e.st.listState().plainElsewhere), json(['t3']));
      });
    });

    acase(named('list-missing-heading-prose: saveOnce returns heading-missing, pill text, journal kept'), function () {
      var e;
      return open(fix('list-missing-heading-prose.md')).then(function (w) {
        e = w;
        e.st.commit(M.setTask(e.s.live, 't1', { color: 'rose' }).chart);
        e.fr.run();
        return K.settle(e);
      }).then(function () { return e.st.save(); }).then(function (r) {
        ok('list-missing-heading-prose: saveOnce returns heading-missing, pill text, journal kept', r.reason === 'heading-missing' && ups(e) === 0 &&
          e.st.ui().pill === 'heading-missing' && !!K.stored(e), json([r, e.st.ui().pill, !!K.stored(e)]));
        eq('list-missing-heading-prose: no fold and no offers in this state', e.st.listState(), null);
      });
    });

    acase(named('list-missing-heading-typo: the held save proceeds after Use as list heading'), function () {
      var e;
      return open(fix('list-missing-heading-typo.md')).then(function (w) {
        e = w;
        e.st.commit(M.setTask(e.s.live, 't1', { color: 'rose' }).chart);
        return K.settle(e);
      }).then(function () {
        eq('list-missing-heading-typo: held', ups(e), 0);
        return e.st.useListHeading();
      }).then(function (r) { return K.settle(e).then(function () { return r; }); }).then(function (r) {
        var t = content(e);
        ok('list-missing-heading-typo: the held save proceeds after Use as list heading', r.ok && ups(e) === 1 && t.indexOf('## Taks\n\n' + L.kick) > 0 && /"color":"rose"/.test(t) && count(t, '## Tasks') === 0, t);
      });
    });

    acase('toast Undo (Undo note changes) writes the old grouping back', function () {
      var e;
      return open(moved()).then(function (w) {
        e = w;
        var n = e.st.takeFold(), r = M.applyPatch(e.s.live, n.inverse);
        e.st.commit(r.chart);
        return K.settle(e);
      }).then(function () {
        var t = content(e);
        ok('toast Undo: Sync engine is back under Build in the note', t.indexOf('### Build\n' + L.sync + '\n' + L.beta) > 0 && gOf(e.s.live, 't3') === 'g2' && ups(e) === 1, t);
      });
    });

    acase('fold: never on a future block; never in an embed; a legacy default heading alone has no toast', function () {
      var fut = moved().replace('{"v":1,', '{"v":2,'), r = rd(fut);
      ok('fold: a future block never folds', r.status === 'future' && !r.fold && r.key === r.bodyKey);
      var e;
      return open(moved(), { mock: { Params: { mode: 'embed' } } }).then(function (w) {
        e = w;
        ok('fold: an embed shows the folded chart and emits nothing', e.st.launch.embed && gOf(e.s.live, 't3') === 'g1' && e.lists.length === 0 &&
          e.mock.count('storeAppState') === 0, json([e.st.launch.embed, e.lists.length]));
      });
    });

    acase('defect 2 (Beta/QA): ### Build deleted and ### QA typed: QA is a new group, Build gone with held tasks, removal banner', function () {
      var e, text = base().replace('### Build\n', '').replace('### Launch\n', '### Launch\n\n### QA\n');
      return open(text, { state: wk(text) }).then(function (w) {
        e = w;
        var g = e.st.listReport();
        ok('Beta/QA: QA is new, Build is not renamed', titles(e.s.live) === 'Discovery,Build,Launch,QA' && gOf(e.s.live, 't3') === 'g2' && gOf(e.s.live, 't4') === 'g2', titles(e.s.live));
        eq('Beta/QA: the removal banner offers Build (group)', json(g && g.goneGroups), json(['g2']));
      });
    });

    /* ---- G2 phase 2, review round 1 ---- */

    // A promote heading after Beta cut, and a foreign link at task indent
    // under Discovery (an Add offer).
    function r1text() {
      return base().replace(L.beta + '\n', L.beta + '\n\n## Later\nNotes for later.\n')
        .replace(L.comp + '\n', L.comp + '\n[Vendor contract](synapseresource://note/n-vendor)\n');
    }
    function offersOf(e) {
      return e.st.listState().offers.map(function (o) { return { id: o.note, title: o.text, group: o.group, after: o.after, owner: o.owner, index: o.index }; });
    }
    function r1check(name, t) {
      ok(name + ': ### Later written once, ## Later gone', count(t, '\n### Later\n') === 1 && count(t, '\n## Later\n') === 0, t);
      ok(name + ': the Vendor link once, MARKED', count(t, 'note/n-vendor') === 1 && t.indexOf('[Vendor contract](synapseresource://note/n-vendor?via=gantt)') > 0, t);
      ok(name + ': the line under the heading stays with Later', t.indexOf('### Later\n\nNotes for later.') > 0, t);
      var fr = rd(t), ls = fr.list;
      ok(name + ': the note reads back with nothing listed twice and no offer', !ls.ambiguous.length && !ls.plainElsewhere.length && !ls.offers.length && fr.key === fr.bodyKey, json(ls.offers));
    }
    acase('review r1 (major): manual, Make groups then Add: the next save writes both edits, nothing back', function () {
      var e, off;
      return open(r1text(), { mode: 'manual' }).then(function (w) {
        e = w;
        off = offersOf(e);
        ok('r1 MG+Add: Make groups', e.st.makeGroups().ok);
        return e.st.addToChart(CH, off);
      }).then(function (r) {
        ok('r1 MG+Add: Add', r.ok && r.added.length === 1);
        return e.st.save();
      }).then(function () { r1check('r1 MG+Add', content(e)); });
    });
    acase('review r1 (major): manual, Add then Make groups', function () {
      var e;
      return open(r1text(), { mode: 'manual' }).then(function (w) {
        e = w;
        return e.st.addToChart(CH, offersOf(e));
      }).then(function () {
        ok('r1 Add+MG: Make groups', e.st.makeGroups().ok);
        return e.st.save();
      }).then(function () { r1check('r1 Add+MG', content(e)); });
    });
    acase('review r1 (major): manual, Make groups, then a save that misses (a line typed in the list) and merges', function () {
      var e;
      return open(r1text(), { mode: 'manual' }).then(function (w) {
        e = w;
        ok('r1 missed: Make groups', e.st.makeGroups().ok);
        e.mock.setNote(CH, content(e).replace('### Launch\n', '### Launch\nTyped meanwhile.\n'));
        return e.st.save();
      }).then(function (r) {
        eq('r1 missed: the first tap re-reads and merges', r.reason, 'retry-needed');
        return e.st.save();
      }).then(function (r) {
        var t = content(e);
        ok('r1 missed: the second tap writes', r.ok, json(r));
        ok('r1 missed: ### Later once, no ## Later written back, the typed line kept', count(t, '\n### Later\n') === 1 && count(t, '\n## Later\n') === 0 &&
          t.indexOf('Typed meanwhile.') > 0 && t.indexOf('### Later\n\nNotes for later.') > 0, t);
      });
    });
    acase('review r1 (major): an Add made while its save is in flight keeps its detach for the next save', function () {
      var e, t0;
      return open(r1text()).then(function (w) {
        e = w;
        e.mock.holdUpdateNotes();
        e.st.commit(M.setTask(e.s.live, 't1', { color: 'rose' }).chart);
        return K.settle(e);
      }).then(function () {
        return e.st.addToChart(CH, offersOf(e));
      }).then(function () {
        return e.mock.release();
      }).then(function () { return K.settle(e); }).then(function () {
        var t = content(e);
        ok('r1 in flight: the Vendor link once, MARKED, after both saves', count(t, 'note/n-vendor') === 1 && t.indexOf('n-vendor?via=gantt') > 0 && /"color":"rose"/.test(t), t);
      });
    });

    acase('review r1 (minor): Make groups moves the lines under the heading into the new group', function () {
      var e;
      return open(base().replace(L.beta + '\n', L.beta + '\n\n## Later\nNotes for later.\n' + L.sync.replace('Sync engine', 'Sync engine') + '\n').replace(L.sync + '\n' + L.beta, L.beta)).then(function (w) {
        e = w;
        var r = e.st.makeGroups();
        ok('r1 tail: Make groups', r.ok);
        return K.settle(e).then(function () { return r; });
      }).then(function (r) {
        var t = content(e);
        ok('r1 tail: the prose is under ### Later, before its task, not in Build', t.indexOf('### Later\n\nNotes for later.\n' + L.sync) > 0 && t.indexOf(L.beta + '\n\nNotes') < 0, t);
        return e.st.undo(stackWith(r));
      }).then(function () { return K.settle(e); }).then(function () {
        var t = content(e);
        ok('r1 tail: Undo puts the heading and the prose back as typed', t.indexOf(L.beta + '\n\n## Later\nNotes for later.\n' + L.sync) > 0 && e.s.live.groups.length === 3, t);
      });
    });

    acase('review r1 (major): Undo of Use as groups puts the seed lines back byte for byte; Redo takes them again', function () {
      var e, text = fix('seed-basic.md'), seedText, res, stck;
      return open(text).then(function (w) {
        e = w;
        seedText = e.st.listState().seed.text;
        return e.st.useSeed();
      }).then(function (r) { res = r; return K.settle(e); }).then(function () {
        stck = stackWith(res);
        return e.st.undo(stck);
      }).then(function () { return K.settle(e); }).then(function () {
        var t = content(e);
        // The chart keeps the list heading the legacy read defaulted, so the
        // list stays; the seed lines are back above it as typed.
        ok('r1 seed undo: the seed lines are back above the chart, byte for byte', t.indexOf('Project notes.\n\n' + seedText + '\n\n## Tasks\n\n- [Kickoff]') === 0 && e.s.live.groups.length === 0, t);
        ok('r1 seed undo: the offer is back', !!e.st.listState() && !!e.st.listState().seed);
        return e.st.redo(stck);
      }).then(function () { return K.settle(e); }).then(function () {
        var t = content(e);
        ok('r1 seed redo: one list, the seed lines replaced again', count(t, '## Tasks') === 1 && count(t, '\n## Design') === 0 && count(t, 'note/n-wire') === 1 && t.indexOf('Project notes.\n\n## Tasks') === 0, t);
      });
    });
    acase('review r1 (major): manual, Use as groups then Undo before any save: the note is never written', function () {
      var e, text = fix('seed-basic.md'), res;
      return open(text, { mode: 'manual' }).then(function (w) {
        e = w;
        return e.st.useSeed();
      }).then(function (r) {
        res = r;
        return e.st.undo(stackWith(res));
      }).then(function () { return K.settle(e); }).then(function () {
        eq('r1 seed unsaved undo: the note is as it was, nothing written', content(e) + '|' + ups(e), text + '|0');
        ok('r1 seed unsaved undo: the region is the fence again', e.s.region.indexOf('```synapse-gantt') === 0, e.s.region.slice(0, 40));
      });
    });

    acase('review r1 (minor): Use as groups reads the note first (a line typed above the list since the last read)', function () {
      var e;
      return open(fix('seed-basic.md')).then(function (w) {
        e = w;
        e.mock.setNote(CH, content(e).replace('Project notes.\n', 'Project notes.\nA line added.\n'));
        return e.st.useSeed();
      }).then(function (r) { return K.settle(e).then(function () { return r; }); }).then(function (r) {
        var t = content(e);
        ok('r1 seed re-read: the seed lines replaced, the added line kept', r.ok && t.indexOf('Project notes.\nA line added.\n\n## Tasks') === 0 && count(t, '\n## Design') === 0 && !e.st.listState().seed, t);
      });
    });
    acase('review r1 (minor): a seed changed since the last read is re-offered, never half taken', function () {
      var e, n0;
      return open(fix('seed-basic.md')).then(function (w) {
        e = w;
        n0 = ups(e);
        e.mock.setNote(CH, content(e).replace('[API](synapseresource://note/n-api)\n', '[API](synapseresource://note/n-api)\n[QA pass](synapseresource://note/n-qa)\n'));
        return e.st.useSeed();
      }).then(function (r) {
        ok('r1 seed changed: nothing taken, nothing written', !r.ok && r.reason === 'changed' && e.s.live.groups.length === 0 && ups(e) === n0, json(r));
        eq('r1 seed changed: the offer now counts the new link', e.st.listState().seed.tasks, 4);
        return e.st.useSeed();
      }).then(function (r) { return K.settle(e).then(function () { return r; }); }).then(function (r) {
        var t = content(e);
        ok('r1 seed changed: Use as groups again takes all four, the seed lines gone', r.ok && e.s.live.tasks.length === 5 && count(t, '\n## Build') === 0 && count(t, 'note/n-qa') === 1, t);
      });
    });
    acase('review r1 (minor): Use as groups with nothing to change still replaces the seed lines', function () {
      var e, text = base().replace('## Tasks\n', '## Build\n[Sync engine](synapseresource://note/n-sync)\n\n## Tasks\n');
      return open(text).then(function (w) {
        e = w;
        ok('r1 seed no-change: offered', !!e.st.listState().seed);
        return e.st.useSeed();
      }).then(function (r) { return K.settle(e).then(function () { return r; }); }).then(function (r) {
        var t = content(e);
        ok('r1 seed no-change: ok, one save, the seed lines gone, no offer left', r.ok && ups(e) === 1 && t.indexOf('## Build\n[Sync engine]') < 0 &&
          t.indexOf('Plan for the release.\n\n## Tasks') === 0 && !e.st.listState().seed, t);
      });
    });

    acase('review r1 (nit): after a write, the same note edit again shows its toast again', function () {
      var e;
      return open(moved()).then(function (w) {
        e = w;
        var n = e.st.takeFold();
        e.st.commit(M.applyPatch(e.s.live, n.inverse).chart);
        return K.settle(e);
      }).then(function () {
        e.mock.setNote(CH, moved());
        return resume(e);
      }).then(function () {
        eq('r1 la: the second, identical note edit emits list again', e.lists.length, 2);
      });
    });

    /* ---- G2 phase 2, review round 2 ---- */

    function hideAndReopen(e, o) {
      e.fr.run();
      return K.settle(e).then(function () { return e.st.onHide('pagehide'); }).then(function () { return K.settle(e); })
        .then(function () { return again(e, o); });
    }
    acase('review r2 (major): Make groups and Add unsaved (manual), hide, reopen, Restore: the journal carries the line edits', function () {
      var e, r, off;
      return open(r1text(), { mode: 'manual' }).then(function (w) {
        e = w;
        off = offersOf(e);
        ok('r2 journal: Make groups', e.st.makeGroups().ok);
        return e.st.addToChart(CH, off);
      }).then(function () {
        return hideAndReopen(e, { mode: 'manual' });
      }).then(function (w) {
        r = w;
        eq('r2 journal: the entry is offered', r.st.ui().banner, 'restore');
        ok('r2 journal: the entry holds the line edits', Array.isArray(K.stored(r).ops) && K.stored(r).ops.length > 0, json(K.stored(r)));
        var res = r.st.journal.restore();
        ok('r2 journal: Restore replays them (same note)', res.ok && !res.opsDropped && r.s.attachOps.length > 0, json(res));
        return r.st.save();
      }).then(function () { r1check('r2 journal', content(r)); });
    });
    acase('review r2 (major): the seed text put back by an unsaved Undo survives hide, reopen and Restore', function () {
      var e, r, seedText, res;
      return open(fix('seed-basic.md')).then(function (w) {
        e = w;
        seedText = e.st.listState().seed.text;
        return e.st.useSeed();
      }).then(function (x) { res = x; return K.settle(e); }).then(function () {
        e.st.launch.mode = 'manual';
        return e.st.undo(stackWith(res));
      }).then(function () {
        eq('r2 seed journal: the undo waits for the pill (manual), pill unsaved', e.st.ui().pill, 'unsaved');
        return hideAndReopen(e, { mode: 'manual' });
      }).then(function (w) {
        r = w;
        var x = r.st.journal.restore();
        ok('r2 seed journal: Restore replays the spill', x.ok && !x.opsDropped && r.s.readSpill === seedText, json([x, r.s.readSpill]));
        return r.st.save();
      }).then(function () {
        var t = content(r);
        ok('r2 seed journal: the save writes the seed lines back above the list', t.indexOf('Project notes.\n\n' + seedText + '\n\n## Tasks') === 0 && r.s.live.groups.length === 0, t);
      });
    });
    acase('review r2 (major): Restore over a note whose block changed drops the line edits and says so; no line is lost', function () {
      var e, r;
      return open(r1text(), { mode: 'manual' }).then(function (w) {
        e = w;
        ok('r2 drop: Make groups', e.st.makeGroups().ok);
        e.fr.run();
        return K.settle(e);
      }).then(function () { return e.st.onHide('pagehide'); }).then(function () { return K.settle(e); }).then(function () {
        // The block changed elsewhere and the user deleted the line the
        // edits would move: replaying them would bring it back.
        e.mock.setNote(CH, content(e).replace('"title":"Kickoff","start":"2026-09-30"', '"title":"Kickoff","start":"2026-09-29"').replace('Notes for later.\n', ''));
        return again(e, { mode: 'manual' });
      }).then(function (w) {
        r = w;
        var x = r.st.journal.restore();
        ok('r2 drop: Restore reports the dropped edits', x.ok && x.opsDropped === true && r.s.attachOps.length === 0, json(x));
        return r.st.save();
      }).then(function () {
        var t = content(r);
        ok('r2 drop: the group is made, ## Later stays as text, the deleted line stays deleted', t.indexOf('\n### Later\n') > 0 && t.indexOf('\n## Later\n') > 0 && t.indexOf('Notes for later.') < 0, t);
      });
    });

    acase('review r2 (major): manual, after Use as groups and before its save the seed offer is gone', function () {
      var e;
      return open(fix('seed-basic.md'), { mode: 'manual', approved: false }).then(function (w) {
        e = w;
        return e.st.useSeed();
      }).then(function (r) {
        ok('r2 seed pending: Use as groups', r.ok);
        eq('r2 seed pending: no offer while the seed is taken and unsaved', e.st.listState().seed, null);
        return e.st.useSeed();
      }).then(function (r) {
        eq('r2 seed pending: a second tap does nothing', r.reason, 'taken');
      });
    });

    acase('review r2 (minor): after a write, the same note edit shows its toast again after a close and reopen', function () {
      var e;
      return open(moved()).then(function (w) {
        e = w;
        var n = e.st.takeFold();
        e.st.commit(M.applyPatch(e.s.live, n.inverse).chart);
        return K.settle(e);
      }).then(function () { return e.st.state.flush(); }).then(function () {
        ok('r2 la: the write cleared la in appState', !(cacheOf(e) || {}).la, json(cacheOf(e)));
        e.mock.setNote(CH, moved());
        return again(e);
      }).then(function (r) {
        eq('r2 la: the reopen shows the toast', r.lists.length, 1);
      });
    });

    acase('review r2 (minor): Use as groups with nothing to change has an Undo and counts as unsaved until written', function () {
      var e, res, text = base().replace('## Tasks\n', '## Build\n[Sync engine](synapseresource://note/n-sync)\n\n## Tasks\n');
      return open(text, { mode: 'manual', approved: false, mock: { approve: 'deny' } }).then(function (w) {
        e = w;
        return e.st.useSeed();
      }).then(function (r) {
        res = r;
        return (r.save || Promise.resolve()).then(function () { return K.settle(e); });
      }).then(function () {
        ok('r2 no-change: an undo step (seedText)', res.ok && res.inverse.length === 1 && res.inverse[0].kind === 'seedText', json(res));
        eq('r2 no-change: denied, so the pill says not saved', e.st.ui().pill, 'not-saved');
        e.fr.run();
        return K.settle(e);
      }).then(function () {
        var en = K.stored(e);
        ok('r2 no-change: the journal keeps the seed op', !!en && Array.isArray(en.ops) && en.ops.some(function (op) { return typeof op.extend === 'string'; }), json(en));
        return e.st.undo(stackWith(res));
      }).then(function () {
        ok('r2 no-change: Undo cancels it: nothing unsaved, the offer is back', e.st.ui().pill === 'saved' && e.s.attachOps.length === 0 && !!e.st.listState().seed, json([e.st.ui().pill, e.s.attachOps]));
      });
    });

    acase('review r2 (nit): an Add made while its save is in flight, and that save misses and merges', function () {
      var e;
      return open(r1text()).then(function (w) {
        e = w;
        e.mock.holdUpdateNotes();
        e.st.commit(M.setTask(e.s.live, 't1', { color: 'rose' }).chart);
        return K.settle(e);
      }).then(function () {
        return e.st.addToChart(CH, offersOf(e));
      }).then(function () {
        e.mock.setNote(CH, content(e).replace('### Launch\n', '### Launch\nTyped meanwhile.\n'));
        return e.mock.release();
      }).then(function () { return K.settle(e); }).then(function () {
        var t = content(e);
        ok('r2 in flight miss: the Vendor link once, MARKED; the typed line and the colour kept', count(t, 'note/n-vendor') === 1 && t.indexOf('n-vendor?via=gantt') > 0 &&
          /"color":"rose"/.test(t) && t.indexOf('Typed meanwhile.') > 0 && e.s.attachOps.length === 0, t);
      });
    });

    /* ---- G2 phase 2, review round 4 ---- */

    acase('review r4 (minor): a late check\'s Restore never replays the other entry\'s edits over the session\'s own', function () {
      var x, y;
      return open(r1text(), { mode: 'manual' }).then(function (w) {
        x = w;
        return again(x, { mode: 'manual' });
      }).then(function (w) {
        y = w;
        ok('r4 late: X makes groups', x.st.makeGroups().ok);
        x.fr.run();
        return K.settle(x);
      }).then(function () { return x.st.onHide('pagehide'); }).then(function () { return K.settle(x); }).then(function () {
        y.s = y.st.session;
        ok('r4 late: Y makes groups too', y.st.makeGroups().ok);
        y.fr.run();
        return K.settle(y);
      }).then(function () { return resume(y); }).then(function () {
        var res = y.st.journal.restore();
        ok('r4 late: Restore of X\'s entry drops its edits (Y has its own)', res.ok && res.opsDropped === true, json(res));
        return y.st.save();
      }).then(function () {
        var t = content(y);
        // Each instance made its own group (two ids, merged like any two
        // added groups); no attached line is written twice.
        ok('r4 late: no ## Later, the note line once', count(t, '\n## Later\n') === 0 && count(t, 'Notes for later.') === 1, t);
      });
    });

    acase('review r4 (minor): Add, then Undo before the save, leaves nothing unsaved', function () {
      var e, add;
      return open(r1text(), { mode: 'manual' }).then(function (w) {
        e = w;
        return e.st.addToChart(CH, offersOf(e));
      }).then(function (r) {
        add = r;
        return e.st.undo(stackWith(add));
      }).then(function () {
        e.fr.run();
        return K.settle(e);
      }).then(function () {
        ok('r4 cancel: no pending op, pill saved, no journal entry', e.s.attachOps.length === 0 && e.st.ui().pill === 'saved' && !K.stored(e),
          json([e.s.attachOps, e.st.ui().pill, !!K.stored(e)]));
        e.mock.setNote(CH, content(e).replace('"start":"2026-09-30"', '"start":"2026-09-29"'));
        return resume(e);
      }).then(function () {
        eq('r4 cancel: a note change then reloads silently', M.task(e.s.live, 't0').start, GT.dates.parse('2026-09-29'));
      });
    });

    // A pending op with live equal to base: Use as groups with nothing to
    // change, its save denied while the page is hidden (auto mode stays).
    var NC = function () { return base().replace('## Tasks\n', '## Build\n[Sync engine](synapseresource://note/n-sync)\n\n## Tasks\n'); };
    function pendingNoChange(o) {
      var e;
      return open(NC(), Object.assign({ approved: false, mock: { approve: 'deny' } }, o || {})).then(function (w) {
        e = w;
        e.flags.hidden = true;
        return e.st.useSeed();
      }).then(function (r) { return (r.save || Promise.resolve()).then(function () { return K.settle(e); }); }).then(function () {
        e.flags.hidden = false;
        ok('r4 pending: one op pending, live equals base', e.s.attachOps.length === 1 && GT.store.same(e.s.live, e.s.base), json(e.s.attachOps));
        return e;
      });
    }
    acase('review r4 (minor): a pending op blocks the silent reload (it is kept)', function () {
      var e, k0;
      return pendingNoChange({ mode: 'manual' }).then(function (w) {
        e = w;
        k0 = e.s.key;
        e.mock.setNote(CH, content(e).replace('"start":"2026-09-30"', '"start":"2026-09-29"'));
        return resume(e);
      }).then(function () {
        ok('r4 reload: no silent reload over the pending op', e.s.key === k0 && e.s.attachOps.length === 1);
      });
    });
    acase('review r4 (minor): a hidden denial with only a pending op is saved on resume', function () {
      var e;
      return pendingNoChange().then(function (w) {
        e = w;
        e.mock.approve = 'session';
        return resume(e);
      }).then(function () {
        ok('r4 resume: the seed lines are replaced', content(e).indexOf('## Build\n[Sync engine]') < 0 && e.s.attachOps.length === 0, content(e));
      });
    });
    acase('review r4 (minor): a hide in auto flushes a pending op', function () {
      var e;
      return pendingNoChange().then(function (w) {
        e = w;
        e.mock.approve = 'session';
        return e.st.onHide('switch');
      }).then(function () { return K.settle(e); }).then(function () {
        ok('r4 flush: the seed lines are replaced', content(e).indexOf('## Build\n[Sync engine]') < 0 && e.s.attachOps.length === 0, content(e));
      });
    });
    acase('review r4 (minor): another instance\'s entry never re-opens over a pending op (late check keeps it)', function () {
      var x, y;
      return pendingNoChange({ mode: 'manual' }).then(function (w) {
        x = w;
        x.fr.run();
        return K.settle(x);
      }).then(function () { return again(x, { mode: 'manual' }); }).then(function (w) {
        y = w;
        y.st.commit(M.setTask(y.s.live, 't1', { color: 'rose' }).chart);
        y.fr.run();
        return K.settle(y);
      }).then(function () { return resume(x); }).then(function () {
        ok('r4 re-open: X kept its pending op (late check, not a re-open)', x.s.attachOps.length === 1 && x.st.ui().banner === 'restore', json([x.s.attachOps.length, x.st.ui().banner]));
      });
    });
    acase('review r4 (minor): Restore heading saves a pending op in auto', function () {
      var e;
      return pendingNoChange().then(function (w) {
        e = w;
        e.mock.approve = 'session';
        e.mock.setNote(CH, content(e).replace('\n## Tasks\n', '\n'));
        e.st.launch.lastSavePrompted = null;
        return resume(e);
      }).then(function () {
        e.s.lastResult = null;
        eq('r4 reanchor: the heading is missing', e.st.ui().banner, 'heading-missing');
        return e.st.restoreHeading();
      }).then(function (r) { return K.settle(e).then(function () { return r; }); }).then(function (r) {
        ok('r4 reanchor: Restore heading, then the pending op saves', r.ok && content(e).indexOf('## Build\n[Sync engine]') < 0 && e.s.attachOps.length === 0, json(r) + '\n' + content(e));
      });
    });

    /* ---- G2 phase 2, review round 4 addendum (G4 mutants S2, S8) ---- */

    acase('removal gate: no banner while unsaved edits wait over a folded note', function () {
      var e, text = base(), cut = moved().replace(L.beta + '\n', '');
      return open(text, { mode: 'manual', state: wk(text) }).then(function (w) {
        e = w;
        e.st.commit(M.setTask(e.s.live, 't1', { color: 'rose' }).chart);
        e.mock.setNote(CH, cut);
        return resume(e);
      }).then(function () {
        ok('removal gate: precondition, the note folds and the session key is the old one', rd(cut).key !== rd(cut).bodyKey && e.s.key === rd(text).key);
        eq('removal gate: an unsaved edit plus a moved and a deleted line in the note: no removal banner until the save merges', e.st.listReport(), null);
      });
    });
    acase('la: a silent reload that shows the toast writes la to the cache at once', function () {
      var e;
      return open(base()).then(function (w) {
        e = w;
        e.mock.setNote(CH, moved());
        return resume(e);
      }).then(function () {
        eq('la: the resume folds with one list event', e.lists.length, 1);
        var ce = e.st.cache.get(CH);
        eq('la: a silent reload that shows the toast writes la to the cache at once', ce && ce.la, B.hash(rd(moved()).key));
      });
    });

    /* ---- G2 phase 2, review round 3: the settings path ---- */

    function settingsCase(name, change, want) {
      acase('review r3: ' + name + ' in manual, a resume before the save, then the save and its undo', function () {
        var e, t0, res;
        return open(base(), { mode: 'manual' }).then(function (w) {
          e = w;
          t0 = content(e);
          res = e.st.setListHeading(change);
          ok('r3 ' + name + ': one commit with an inverse', res.ok && res.inverse.length > 0, json(res));
          e.mock.setNote(CH, content(e));
          return resume(e);
        }).then(function () {
          eq('r3 ' + name + ': the resume finds the note\'s heading: no missing state, no banner', json([e.st.ui().missing, e.st.ui().banner]), json([null, null]));
          eq('r3 ' + name + ': the pill offers the save', e.st.ui().pill, 'unsaved');
          return e.st.save();
        }).then(function (r) {
          var t = content(e);
          ok('r3 ' + name + ': the save writes', r.ok && ups(e) === 1, json(r));
          eq('r3 ' + name + ': the note ends with the new heading, the rest as before', t, want(t0));
          var fr = rd(t);
          ok('r3 ' + name + ': it reads back as one list with a body key', !!fr.list && !fr.missing && fr.key === fr.bodyKey);
          return e.st.undo(stackWith(res));
        }).then(function () { return e.st.save(); }).then(function () {
          eq('r3 ' + name + ': undo brings the old heading back with one save', content(e) + '|' + ups(e), t0 + '|2');
        });
      });
    }
    settingsCase('heading', { heading: 'Work' }, function (t) {
      return t.replace('## Tasks\n', '## Work\n').replace('"listHeading":"Tasks"', '"listHeading":"Work"');
    });
    settingsCase('level', { level: 3 }, function (t) {
      return t.replace('## Tasks\n', '### Tasks\n').split('\n### Discovery').join('\n#### Discovery').split('\n### Build').join('\n#### Build')
        .split('\n### Launch').join('\n#### Launch').replace('"listHeading":"Tasks"', '"listHeading":"Tasks","listLevel":3');
    });
    acase('review r3: the missing state still holds when neither heading is found', function () {
      var e;
      return open(base(), { mode: 'manual' }).then(function (w) {
        e = w;
        e.st.setListHeading({ heading: 'Work' });
        e.mock.setNote(CH, content(e).replace('## Tasks\n', ''));
        return resume(e);
      }).then(function () {
        eq('r3 neither: the banner', e.st.ui().banner, 'heading-missing');
        return e.st.save();
      }).then(function (r) { eq('r3 neither: the save is held', r.reason + '|' + ups(e), 'heading-missing|0'); });
    });
    acase('review r3: setListHeading refuses bad values', function () {
      return open(base()).then(function (e) {
        eq('r3 refuse', [e.st.setListHeading({ heading: '  ' }).reason, e.st.setListHeading({ level: 6 }).reason, e.st.setListHeading({ heading: 'Tasks' }).reason].join(), 'invalid,invalid,same');
      });
    });

    // The G2-tagged names list_spec handed over are all asserted here.
    acase('G2-tagged list_spec names are asserted by the store spec', function () {
      var names = GT.G2_STORE_NAMES || [];
      ok('G2-tagged list_spec names handed over', names.length >= 10, String(names.length));
      var missing = names.filter(function (n) { return n.indexOf('hand edits') !== 0 && !seen[n]; });
      eq('G2-tagged list_spec names all asserted (' + names.length + ')', missing.join('\n'), '');
    });

    seedsProperty();
  }

  /*
   * §10.1 seeds property: random seeds (headings of level 2 to 6 with PLAIN
   * and FOREIGN links, ungrouped links first, blank lines around headings,
   * one blank run before the region top) above fence-only, legacy-mirror,
   * embed-topped and delimited regions: the offer counts match; Use as
   * groups gives one region with those groups; the note above the seed is
   * untouched.
   */
  function mulberry32(a) {
    return function () {
      a |= 0; a = a + 0x6D2B79F5 | 0;
      var t = Math.imul(a ^ a >>> 15, 1 | a);
      t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
      return ((t ^ t >>> 14) >>> 0) / 4294967296;
    };
  }
  var POOL = [];
  for (var pi = 0; pi < 10; pi++) POOL.push({ id: 'sd-' + pi, title: 'Seed note ' + pi, type: 'task' });
  var WORDS = ['Design', 'Build', 'Launch', 'Review', 'Ops', 'Legal', 'Docs', 'QA', 'Research', 'Beta'];

  function seedsProperty() {
    var seed = (typeof global.GT_SEED === 'number' ? global.GT_SEED : 20260927) + 11, rng = mulberry32(seed), N = 200;
    function int(a, b) { return a + Math.floor(rng() * (b - a + 1)); }
    var stats = { fence: 0, mirror: 0, embed: 0, list: 0 }, fails = [], runs = 0;
    function gen() {
      var kind = ['fence', 'mirror', 'embed', 'list'][int(0, 3)];
      stats[kind]++;
      var set = kind === 'list' ? { listHeading: 'Tasks' } : (kind === 'embed' ? { embed: true } : {});
      var chart = M.coerce({ v: 1, settings: set, tasks: [{ id: 't0', note: 'n-kick', title: 'Kickoff', start: '2026-09-30' },
        { id: 't1', note: 'n-int', title: 'Customer interviews', start: '2026-10-01', end: '2026-10-09' }] }).chart;
      var region;
      if (kind === 'list') region = B.regionParts(chart, null, { list: true }).text;
      else {
        region = (kind === 'embed' ? B.embedLine() + '\n\n' : '') + (kind === 'fence' ? '' : '- [Kickoff](synapseresource://note/n-kick?via=gantt) · 2026-09-30\n- [Customer interviews](synapseresource://note/n-int?via=gantt) · 2026-10-01 → 2026-10-09\n\n') + B.fence(chart);
        if (kind === 'fence') region = B.fence(M.coerce({ v: 1, settings: set, tasks: [] }).chart);
      }
      var intro = rng() < 0.5 ? 'Intro line ' + int(0, 99) + '.\n\n' : '';
      var lines = [], notes = {}, groups = [], nu = int(0, 2), used = {};
      function link() {
        var r = rng(), id, t;
        if (r < 0.2 && kind !== 'fence') { id = rng() < 0.5 ? 'n-kick' : 'n-int'; t = id === 'n-kick' ? 'Kickoff' : 'Customer interviews'; }
        else { var p = POOL[int(0, POOL.length - 1)]; id = p.id; t = p.title; }
        notes[id] = true;
        return (rng() < 0.3 ? '- ' : '') + '[' + t + '](synapseresource://note/' + id + ')';
      }
      for (var u = 0; u < nu; u++) lines.push(link());
      var ng = int(1, 3);
      for (var g = 0; g < ng; g++) {
        var title = WORDS[int(0, WORDS.length - 1)] + ' ' + g;
        if (used[title]) title += 'x';
        used[title] = true;
        if (lines.length && rng() < 0.5) lines.push('');
        lines.push('######'.slice(0, int(2, 6)) + ' ' + title);
        if (rng() < 0.3) lines.push('');
        var nl = g === 0 ? int(1, 3) : int(0, 3);
        for (var q = 0; q < nl; q++) lines.push(link());
        groups.push(title);
      }
      var text = intro + lines.join('\n') + '\n\n' + region;
      return { kind: kind, text: text, intro: intro, groups: groups, tasks: Object.keys(notes).length };
    }
    var cases = [];
    for (var i = 0; i < N; i++) cases.push(gen());
    acase('seeds property: ' + N + ' random seeds offer the right counts, Use as groups gives one region, the note above is untouched (seed ' + seed + ')', function () {
      return cases.reduce(function (p, c, k) {
        return p.then(function () {
          var e, res;
          var db = GT.host.installMock([{ id: CH, title: 'Plan', content: c.text }].concat(K.TASKS, POOL), { global: false }).db;
          return open(null, { db: db }).then(function (w) {
            e = w;
            runs++;
            var ls = e.st.listState();
            if (!ls || !ls.seed) { fails.push(k + ' ' + c.kind + ': no offer\n' + c.text); return null; }
            if (ls.seed.tasks !== c.tasks || ls.seed.groups.length !== c.groups.length) { fails.push(k + ': counts ' + ls.seed.tasks + '/' + ls.seed.groups.length + ' vs ' + c.tasks + '/' + c.groups.length + '\n' + c.text); return null; }
            return e.st.useSeed().then(function (r) { res = r; return K.settle(e); }).then(function () {
              var t = content(e), fr = rd(t);
              if (!res.ok) { fails.push(k + ': Use as groups ' + json(res)); return; }
              if (t.slice(0, c.intro.length) !== c.intro) { fails.push(k + ': the note above changed\n' + t); return; }
              if (count(t, '\n## Tasks\n') + (t.indexOf('## Tasks\n') === 0 ? 1 : 0) !== 1 || !fr.list || fr.key !== fr.bodyKey || fr.seed) { fails.push(k + ': not one stable region\n' + t); return; }
              var gt = fr.chart.groups.map(function (g) { return g.title; });
              if (json(gt) !== json(c.groups.map(function (x) { return B.norm(x); }))) { fails.push(k + ': groups ' + json(gt) + ' vs ' + json(c.groups) + '\n' + t); return; }
              var linkLeft = t.slice(c.intro.length, fr.region.start).indexOf('synapseresource://note/') >= 0;
              if (linkLeft) fails.push(k + ': seed lines left above the list\n' + t);
            });
          });
        });
      }, Promise.resolve()).then(function () {
        ok('seeds property: ' + N + ' random seeds offer the right counts, Use as groups gives one region, the note above is untouched (seed ' + seed + ')',
          fails.length === 0 && runs === N, runs + ' runs, ' + fails.length + ' failures; first: ' + (fails[0] || ''));
        ok('seeds property: every region kind ran', stats.fence > 20 && stats.mirror > 20 && stats.embed > 20 && stats.list > 20, json(stats));
      });
    });
  }

  SPEC.suites.push({ name: 'the G2 sync store spec', fn: syncSpec });
  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
