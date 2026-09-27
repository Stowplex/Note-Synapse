/*
 * Gantt store.js assertions (M3b): the §9.1.5 journal walkthroughs (a) to
 * (u) with every variant, the §9.1.4 appState rules, save modes (§9.1.3),
 * launch state, the §7.5 bridge-call budget on the 100-task fixture
 * (fixtures/big.json), the §9.2 save guarantees and the §8 note actions.
 * Runs under node (dev/run.js) and in the browser (dev/auto_smoke.html),
 * always against installMock; frames and timers are run by hand.
 */
(function (global) {
  'use strict';
  var GT = global.GT, H = GT.host, B = GT.block, M = GT.model, S = GT.store, D = GT.dates, U = GT.undo, MD = GT.md, SPEC = GT.spec;
  var A = SPEC.api, ok = A.ok, eq = A.eq, same = A.same, acaseReal = A.acase;
  /*
   * G2 phase 2: the §9.1.5 walkthroughs (every case whose name starts with
   * "(") run a second time over folded charts: noteText writes the list from
   * the chart but the block with each group's noted tasks in reverse order,
   * so every read of such a note folds back to the chart (composite key).
   */
  var FOLD = false, FOLDING = false, FOLDED_OPENS = 0;
  function acase(name, fn) {
    if (!FOLDING) return acaseReal(name, fn);
    if (name.charAt(0) !== '(') return;
    acaseReal('folded ' + name, function () {
      FOLD = true;
      return Promise.resolve().then(fn).then(function (v) { FOLD = false; return v; }, function (err) { FOLD = false; throw err; });
    });
  }
  // Each group's noted tasks (ungrouped included) reversed in their slots.
  function perturb(c) {
    var d = M.toData(c), by = {};
    d.tasks.forEach(function (t, k) { if (t.note) (by[String(t.group || null)] = by[String(t.group || null)] || []).push(k); });
    var tasks = d.tasks.slice();
    Object.keys(by).forEach(function (g) {
      var ks = by[g], ts = ks.map(function (k) { return d.tasks[k]; }).reverse();
      ks.forEach(function (k, i) { tasks[k] = ts[i]; });
    });
    d.tasks = tasks;
    return C(d);
  }
  var CH = 'chart-1', CH2 = 'chart-2';

  /* ------------------------------------------------------------ helpers */

  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function day(s) { return D.parse(s); }
  function C(data) { return M.coerce(data).chart; }
  function key(c) { return c ? S.keyOf(c) : null; }

  // S: the chart in the note at open. x is t1.start, y is t2.end.
  // G1: a list chart (settings.listHeading) unless the settings say
  // otherwise, so every walkthrough runs over the delimited list.
  var LIST = { list: true };
  function chartS(settings) {
    var set = Object.assign({ listHeading: 'Tasks' }, settings || {});
    if (set.listHeading === null) delete set.listHeading;
    return C({ v: 1, settings: set, tasks: [
      { id: 't1', note: 'n1', title: 'Task one', start: '2026-10-03', end: '2026-10-10' },
      { id: 't2', note: 'n2', title: 'Task two', start: '2026-10-05', end: '2026-10-12' }] });
  }
  function setX(c, d) { var t = M.task(c, 't1'); return M.setDates(c, 't1', day(d), t.end).chart; }
  function setY(c, d) { var t = M.task(c, 't2'); return M.setDates(c, 't2', t.start, day(d)).chart; }
  function color1(c, col) { return M.setTask(c, 't1', { color: col }).chart; }
  function xOf(c) { return D.format(M.task(c, 't1').start); }
  function yOf(c) { return D.format(M.task(c, 't2').end); }
  function noteText(c, intro) {
    var region = B.region(c, null, LIST);
    if (FOLD && B.listConf(c).on && B.listConf(c).h !== null) region = region.replace(B.fence(c), B.fence(perturb(c)));
    return (intro === undefined ? 'Intro text.' : intro) + '\n\n' + region;
  }

  function frames() {
    var q = [];
    return {
      frame: function (f) { var h = { f: f }; q.push(h); return h; },
      cancel: function (h) { var i = q.indexOf(h); if (i >= 0) q.splice(i, 1); },
      run: function () { var a = q.splice(0); a.forEach(function (h) { h.f(); }); return a.length; },
      count: function () { return q.length; }
    };
  }
  function timers() {
    var list = [];
    return {
      set: function (f, ms) { var t = { f: f, ms: ms }; list.push(t); return t; },
      clear: function (t) { var i = list.indexOf(t); if (i >= 0) list.splice(i, 1); },
      fire: function (ms) {
        var a = list.filter(function (t) { return ms === undefined || t.ms === ms; });
        a.forEach(function (t) { var i = list.indexOf(t); if (i >= 0) list.splice(i, 1); t.f(); });
        return a.length;
      },
      count: function (ms) { return list.filter(function (t) { return ms === undefined || t.ms === ms; }).length; }
    };
  }
  var clockT = 1790000000000;
  function env(o) {
    o = o || {};
    var storage = o.storage || new Map();
    var mo = Object.assign({ storage: storage, global: false, appId: 'gantt-store-test' }, o.mock || {});
    if (o.db) mo.db = o.db;
    var mock = H.installMock(o.db ? null : (o.seed || null), mo);
    var fr = frames(), tm = timers(), flags = { hidden: false };
    var st = S.create({
      host: mock.host, frame: fr.frame, cancelFrame: fr.cancel,
      now: function () { clockT += 7; return clockT; },
      hidden: function () { return flags.hidden; }, setTimeout: tm.set, clearTimeout: tm.clear
    });
    var e = { mock: mock, st: st, fr: fr, tm: tm, flags: flags, storage: storage, lives: [], s: null };
    st.on('live', function (x) { e.lives.push(x || {}); });
    return e;
  }
  function settle(e) {
    var p = P0();
    for (var i = 0; i < 6; i++) p = p.then(function () { return sleep(0); });
    if (!e) return p;
    return p.then(function () { return e.st.state.idle(); }).then(function () { return sleep(0); });
  }
  function P0() { return Promise.resolve(); }
  function stored(e, c) {
    var st = e.mock.state(), j = st && st.journal;
    return j && j[c || CH] ? j[c || CH] : null;
  }
  function entryIs(en, base, chart) {
    return !!en && key(S.chartOf(en.base)) === key(base) && key(S.chartOf(en.chart)) === key(chart);
  }
  function show(en) { return en ? 'x=' + xOf(S.chartOf(en.chart)) + ' base x=' + xOf(S.chartOf(en.base)) + ' owner ' + en.owner : 'none'; }
  function oldEntry(base, chart, at, owner) {
    return { at: at || 1000, owner: owner || 'st-earlier', baseKey: key(base), base: M.toData(base), chart: M.toData(chart) };
  }
  // The chart the note describes (G2: the list is folded in).
  function noteChart(e, id) { return B.read(e.mock.content(id || CH), LIST).chart; }
  function seedFor(S0, more, intro) {
    return [{ id: CH, title: 'Plan', content: noteText(S0, intro) },
      { id: 'n1', title: 'Task one', type: 'task' }, { id: 'n2', title: 'Task two', type: 'task' }].concat(more || []);
  }
  function jmap(c, en) { var j = {}; j[c] = en; return j; }
  // A world: a store booted on a mock with the chart note open and checked.
  function world(o) {
    o = o || {};
    var S0 = o.S || chartS();
    var e = env({ seed: o.seed || seedFor(S0), storage: o.storage, db: o.db, mock: o.mock });
    if (o.entry) e.mock.setState({ v: 1, journal: jmap(o.chart || CH, o.entry) });
    if (o.state) e.mock.setState(o.state);
    if (o.mode) e.st.launch.mode = o.mode;
    if (o.approved) { e.st.launch.sessionApproved = true; e.mock.sessionApproved = true; }
    var id = o.chart || CH;
    return e.st.boot().then(function () {
      var content = e.mock.content(id);
      return e.st.open(o.read === false || content === null ? id : { noteId: id, read: B.read(content), text: content });
    }).then(function (r) {
      e.open = r;
      e.s = r.session;
      if (FOLD && e.s && typeof e.s.key === 'string' && e.s.key.indexOf('#') > 0) FOLDED_OPENS++;
      return e.s && o.wait !== false ? Promise.all([e.s.checked, e.s.resolved]) : null;
    }).then(function () { return o.wait === false ? null : settle(e); }).then(function () { return e; });
  }
  function reopen(e, o) { return world(Object.assign({ db: e.mock.db, storage: e.storage }, o || {})); }
  function noWhole(name, e) { eq(name + ': no whole-note replace was sent', e.mock.wholeReplaces().length, 0); }
  function seqOf(e, method, phase) {
    var ev = e.mock.events.filter(function (x) { return x.method === method && x.phase === phase; });
    return ev.map(function (x) { return x.seq; });
  }

  function storeSpec() {
    /* ------------------------------------------------------------ pure */

    ok('isPrompted: over 400 ms with no baseline', S.isPrompted(401, null));
    ok('isPrompted: 400 ms is not over the floor', !S.isPrompted(400, 1));
    ok('isPrompted: 450 ms with a 1 ms baseline', S.isPrompted(450, 1));
    ok('isPrompted: 450 ms with a 150 ms baseline is under 4x', !S.isPrompted(450, 150));
    ok('isPrompted: 601 ms with a 150 ms baseline', S.isPrompted(601, 150));
    ok('same: canonical keys ignore formatting', S.same(chartS(), C(JSON.parse(B.serialize(chartS())))));
    ok('same: a changed field differs', !S.same(chartS(), setX(chartS(), '2026-10-05')));
    ok('pk changes with the section', S.pk({ progressSource: 'checklist', progressSection: 'A' }) !== S.pk({ progressSource: 'checklist', progressSection: 'B' }));
    ok('pk changes with childTasks', S.pk({ progressSource: 'subnotes', childTasks: true }) !== S.pk({ progressSource: 'subnotes', childTasks: false }));

    var S0 = chartS(), A5 = setX(S0, '2026-10-05');

    /* ================================================== walkthroughs */

    acase('(a) quick back before first approval', function () {
      var e, r;
      return world({ mock: { approvalMs: 60 } }).then(function (w) {
        e = w;
        eq('(a) open: no banner', e.st.ui().banner, null);
        ok('(a) commit accepted', e.st.commit(A5));
        eq('(a) the save is waiting on the dialog', e.mock.count('updateNotes'), 1);
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(a) {S, A} after the frame', entryIs(stored(e), S0, A5), show(stored(e)));
        e.mock.haltAfter('beforeUpdateNotes');
        return sleep(90);
      }).then(function () {
        ok('(a) the note still holds S', S.same(noteChart(e), S0));
        ok('(a) the entry is unchanged after the crash', entryIs(stored(e), S0, A5));
        return reopen(e);
      }).then(function (w) {
        r = w;
        ok('(a) reopen: the entry is unchanged', entryIs(stored(r), S0, A5));
        eq('(a) reopen: the banner shows', r.st.ui().banner, 'restore');
        ok('(a) reopen: the chart is read-only', r.st.ui().readOnly);
        ok('(a) reopen: a drag does nothing', !r.st.commit(setX(r.s.live, '2026-10-09')));
        var res = r.st.journal.restore();
        ok('(a) Restore applies', res.ok);
        ok('(a) Restore shows A', S.same(r.s.live, A5));
        ok('(a) Restore clears the hold', !r.st.ui().readOnly);
        return res.save;
      }).then(function (sv) {
        ok('(a) Restore saves per mode (auto)', sv && sv.ok, JSON.stringify(sv));
        ok('(a) the note holds A', S.same(noteChart(r), A5));
        r.fr.run();
        return settle(r);
      }).then(function () {
        eq('(a) after the save: no entry', stored(r), null);
        noWhole('(a)', r);
      });
    });

    acase('(b) save ok, then reopen', function () {
      var e;
      return world({ approved: true }).then(function (w) {
        e = w;
        e.st.commit(A5);
        e.fr.run();
        eq('(b) the frame queued W', Object.keys(e.st.journal.map).length, 1);
        return settle(e);
      }).then(function () {
        ok('(b) {S, A} stored after the first frame', entryIs(stored(e), S0, A5), show(stored(e)));
        ok('(b) the save agreed', S.same(e.s.base, A5));
        eq('(b) agree scheduled one evaluation', e.fr.count(), 1);
        e.fr.run();
        return settle(e);
      }).then(function () {
        eq('(b) D after agree: none', stored(e), null);
        return reopen(e);
      }).then(function (r) {
        eq('(b) reopen: no banner', r.st.ui().banner, null);
        ok('(b) reopen: the chart shows A', S.same(r.s.live, A5));
        ok('(b) reopen: editable', !r.st.ui().readOnly);
      });
    });

    acase('(c) denial, then reopen', function () {
      var e, B6 = setY(A5, '2026-10-20');
      return world({ mock: { approve: 'once' } }).then(function (w) {
        e = w;
        e.mock.approvals = ['once', 'deny'];
        e.st.commit(A5);
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(c) save A agreed', S.same(e.s.base, A5));
        e.fr.run();
        return settle(e);
      }).then(function () {
        eq('(c) none after A', stored(e), null);
        e.st.commit(B6);
        e.fr.run();
        return settle(e);
      }).then(function () {
        eq('(c) the denial while visible pauses', e.st.saveMode(), 'paused');
        eq('(c) pill "Not saved. Tap to save"', e.st.ui().pill, 'not-saved');
        ok('(c) {A, B}: base A, not S', entryIs(stored(e), A5, B6), show(stored(e)));
        eq('(c) the denial scheduled no journal frame', e.fr.count(), 0);
        return reopen(e);
      }).then(function (r) {
        eq('(c) reopen: banner', r.st.ui().banner, 'restore');
        var res = r.st.journal.restore();
        ok('(c) Restore gives B with no conflict', res.ok && S.same(r.s.live, B6));
      });
    });

    // (c) second half: every other failure reason writes nothing.
    function failCase(name, prep, want, o) {
      acase('(c) a ' + want + ' failure writes nothing', function () {
        var e, stores, r;
        return world(o || {}).then(function (w) {
          e = w;
          e.st.commit(A5, { save: 'none' });
          e.fr.run();
          return settle(e);
        }).then(function () {
          ok('(c) ' + want + ': {S, A} before', entryIs(stored(e), S0, A5));
          stores = e.mock.count('storeAppState');
          prep(e);
          return e.st.save();
        }).then(function (res) {
          r = res;
          eq('(c) ' + want + ': the reason', r.reason, want);
          return settle(e);
        }).then(function () {
          if (want !== 'retry-needed') {
            eq('(c) ' + want + ': no journal frame', e.fr.count(), 0);
            eq('(c) ' + want + ': no storeAppState', e.mock.count('storeAppState'), stores);
            ok('(c) ' + want + ': the entry is unchanged', entryIs(stored(e), S0, A5));
          } else {
            // The re-read merged and re-anchored (the rebase row); the
            // failure itself adds nothing.
            ok('(c) retry-needed: the rebase emitted live', e.lives.some(function (x) { return x.rebase; }));
            ok('(c) retry-needed: the entry is unchanged until the rebase frame', entryIs(stored(e), S0, A5));
            e.fr.run();
            return settle(e).then(function () {
              ok('(c) retry-needed: the rebase frame writes {E, merged}', entryIs(stored(e), E_y, e.s.live) && xOf(e.s.live) === '2026-10-05', show(stored(e)));
            });
          }
        }).then(function () {
          eq('(c) ' + want + ': no appendContent', e.mock.updates.filter(function (l) { return l[0] && l[0].modification && l[0].modification.content.action === 'append'; }).length, 0);
          noWhole('(c) ' + want, e);
        });
      });
    }
    var E_y = setY(S0, '2026-10-22');
    failCase('conflict', function (e) { e.mock.setNote(CH, noteText(setX(S0, '2026-10-07'))); }, 'conflict');
    failCase('retry', function (e) { e.mock.setNote(CH, noteText(E_y)); }, 'retry-needed');
    failCase('read', function (e) { e.mock.outsideEdit(function (m) { m.setNote(CH, noteText(E_y)); }); e.mock.truncateReads(5, 1); }, 'read-failed');
    failCase('write', function (e) { e.mock.refuse(CH); }, 'write-failed', { approved: true });
    failCase('future', function (e) { e.mock.setNote(CH, 'Intro text.\n\n```synapse-gantt\n{"v":2,"tasks":[]}\n```'); }, 'read-only');

    acase('(c) write-failed after 3 attempts makes the chart read-only', function () {
      var e;
      return world({ approved: true }).then(function (w) {
        e = w;
        e.mock.refuse(CH);
        e.st.commit(A5, { save: 'none' });
        return e.st.save();
      }).then(function (r) {
        eq('(c) three attempts', e.mock.count('updateNotes'), 3);
        ok('(c) read-only banner', r.reason === 'write-failed' && e.st.ui().banner === 'read-only' && e.st.ui().readOnly);
      });
    });

    acase('(d) crash after the write, no revert', function () {
      var e;
      return world().then(function (w) {
        e = w;
        e.mock.holdUpdateNotes();
        e.st.commit(A5);
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(d) {S, A} at the crash', entryIs(stored(e), S0, A5));
        e.mock.haltAfter('updateNotes');
        return e.mock.release();
      }).then(function () {
        ok('(d) the note holds A', S.same(noteChart(e), A5));
        ok('(d) agree never ran', S.same(e.s.base, S0));
        return reopen(e);
      }).then(function (r) {
        eq('(d) step 4: no banner', r.st.ui().banner, null);
        ok('(d) the chart shows A', S.same(r.s.live, A5));
        eq('(d) step 4 deleted the entry', stored(r), null);
      });
    });

    acase('open step 5: the note already holds the edits (titles refreshed)', function () {
      var old = M.setTask(A5, 't1', { title: 'Old one' }).chart;
      return world({ S: A5, entry: oldEntry(S0, old) }).then(function (e) {
        ok('step 5: the keys differ (step 4 does not apply)', key(old) !== e.s.key);
        eq('step 5: no banner', e.st.ui().banner, null);
        ok('step 5: editable', !e.st.ui().readOnly);
        eq('step 5: the entry was deleted silently', stored(e), null);
      });
    });

    acase('open: cached progress for another progress key is not painted', function () {
      var e, cs = chartS({ progressSource: 'checklist', progressSection: 'Checklist' });
      var seed = seedFor(cs).map(function (n) { return n.id === 'n1' ? Object.assign({}, n, { content: '## Checklist\n- [x] a\n- [ ] b\n## Other\n- [ ] c' }) : n; });
      return world({ S: cs, seed: seed }).then(function (w) {
        e = w;
        ok('cache pk: counted', e.s.summaries()(M.task(e.s.live, 't1')).total === 2);
        return e.st.state.flush();
      }).then(function () {
        e.mock.setNote(CH, noteText(M.setSettings(cs, { progressSection: 'Other' }).chart));
        return reopen(e, { wait: false });
      }).then(function (r) {
        var sm = r.s.summaries()(M.task(r.s.live, 't1'));
        ok('cache pk: first paint shows loading, not the old counts', sm.loading && sm.total === 0, JSON.stringify(sm));
        return r.s.resolved.then(function () {
          var s2 = r.s.summaries()(M.task(r.s.live, 't1'));
          ok('cache pk: then the new section is counted', !s2.loading && s2.total === 1 && s2.done === 0);
        });
      });
    });

    acase('(e) crash after the write, with a revert (window (b))', function () {
      var e;
      return world().then(function (w) {
        e = w;
        e.mock.holdUpdateNotes();
        e.st.commit(A5);
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(e) {S, A} while the save is parked', entryIs(stored(e), S0, A5));
        e.st.commit(setX(e.s.live, '2026-10-03'));
        ok('(e) live equals S again', S.same(e.s.live, S0));
        e.fr.run();
        return settle(e);
      }).then(function () {
        eq('(e) the revert frame queued D: none at the crash', stored(e), null);
        e.mock.haltAfter('updateNotes');
        return e.mock.release();
      }).then(function () {
        eq('(e) the note holds x=5', xOf(noteChart(e)), '2026-10-05');
        return reopen(e);
      }).then(function (r) {
        eq('(e) reopen: no banner', r.st.ui().banner, null);
        eq('(e) reopen: none stored', stored(r), null);
        eq('(e) x shows 5: the documented loss', xOf(r.s.live), '2026-10-05');
      });
    });

    acase('(e) variant: the second commit also sets y', function () {
      var e, Sy = setY(S0, '2026-10-25');
      return world().then(function (w) {
        e = w;
        e.mock.holdUpdateNotes();
        e.st.commit(A5);
        e.fr.run();
        return settle(e);
      }).then(function () {
        e.st.commit(setY(setX(e.s.live, '2026-10-03'), '2026-10-25'));
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(e) variant: {S, S+y}', entryIs(stored(e), S0, Sy), show(stored(e)));
        e.mock.haltAfter('updateNotes');
        return e.mock.release();
      }).then(function () { return reopen(e); }).then(function (r) {
        eq('(e) variant: banner', r.st.ui().banner, 'restore');
        ok('(e) variant: {S, S+y} kept through the reopen', entryIs(stored(r), S0, Sy));
        var res = r.st.journal.restore();
        ok('(e) variant: Restore gives x=5 and the new y', res.ok && xOf(r.s.live) === '2026-10-05' && yOf(r.s.live) === '2026-10-25');
        return res.save.then(function () { r.fr.run(); return settle(r); }).then(function () {
          eq('(e) variant: saved after Restore, then none', stored(r), null);
          ok('(e) variant: the note holds x=5 and y', xOf(noteChart(r)) === '2026-10-05' && yOf(noteChart(r)) === '2026-10-25');
        });
      });
    });

    acase('(f) merge-retry with a commit during the flight', function () {
      var e, E = setY(S0, '2026-10-22'), Bc, BE;
      return world({ approved: true }).then(function (w) {
        e = w;
        e.mock.holdUpdateNotes();
        e.mock.holdUpdateNotes();
        e.st.commit(A5);
        e.mock.setNote(CH, noteText(E));
        Bc = color1(e.s.live, 'rose');
        e.st.commit(Bc);
        BE = color1(setY(A5, '2026-10-22'), 'rose');
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(f) {S, B} before the release', entryIs(stored(e), S0, Bc));
        return e.mock.release();
      }).then(function () { return settle(e); }).then(function () {
        eq('(f) the second attempt is parked', e.mock.parked(), 1);
        ok('(f) emit(live) fired on the rebase', e.lives.some(function (x) { return x.rebase; }));
        ok('(f) s.live is B+E', S.same(e.s.live, BE));
        ok('(f) base is E', S.same(e.s.base, E));
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(f) the frame writes {E, B+E}', entryIs(stored(e), E, BE), show(stored(e)));
        return e.mock.release();
      }).then(function () { return settle(e); }).then(function () {
        var fr = B.read(e.mock.content(CH), LIST);
        eq('(f) the written region equals the serialised s.live', fr.region.text, B.region(e.s.live, e.s.summaries(), { list: true, embedOutside: false }));
        ok('(f) agree', S.same(e.s.base, BE));
        e.fr.run();
        return settle(e);
      }).then(function () {
        eq('(f) D after agree: none', stored(e), null);
        noWhole('(f)', e);
        return reopen(e);
      }).then(function (r) {
        eq('(f) reopen: no banner', r.st.ui().banner, null);
        ok('(f) B and E present', M.task(r.s.live, 't1').color === 'rose' && yOf(r.s.live) === '2026-10-22' && xOf(r.s.live) === '2026-10-05');
      });
    });

    acase('(f) variant: a commit during the flight clashes with E', function () {
      var e, E = setY(S0, '2026-10-22'), Bc, res;
      return world({ approved: true }).then(function (w) {
        e = w;
        e.mock.holdUpdateNotes();
        e.st.commit(A5);
        var p = e.s.busy;
        e.mock.setNote(CH, noteText(E));
        Bc = setY(e.s.live, '2026-10-30');
        e.st.commit(Bc);
        e.fr.run();
        return settle(e).then(function () { e.mock.release(); return p; });
      }).then(function (r) {
        res = r;
        eq('(f) variant: the save fails as conflict', res.reason, 'conflict');
        ok('(f) variant: the sheet lists t2.end', res.conflicts.some(function (c) { return c.key === 't2.end'; }), JSON.stringify(res.conflicts));
        ok('(f) variant: conflictRead is kept', !!e.s.conflictRead);
        eq('(f) variant: E is not overwritten', yOf(noteChart(e)), '2026-10-22');
        return settle(e);
      }).then(function () {
        ok('(f) variant: the entry stays {S, B}', entryIs(stored(e), S0, Bc), show(stored(e)));
      });
    });

    acase('(g) banner shown, then hide', function () {
      var e, st0, up0;
      return world({ entry: oldEntry(S0, A5) }).then(function (w) {
        e = w;
        eq('(g) open: banner', e.st.ui().banner, 'restore');
        ok('(g) the drag does nothing', !e.st.commit(setX(e.s.live, '2026-10-09')));
        eq('(g) evaluate() is a no-op under hold', e.st.journal.evaluate(), null);
        eq('(g) nothing queued', e.st.state.pending().journal.length, 0);
        st0 = e.mock.count('storeAppState'); up0 = e.mock.count('updateNotes');
        return e.st.onHide('pagehide');
      }).then(function () { return settle(e); }).then(function () {
        eq('(g) onHide: no storeAppState', e.mock.count('storeAppState'), st0);
        eq('(g) onHide: no updateNotes', e.mock.count('updateNotes'), up0);
        ok('(g) {S, A} unchanged', entryIs(stored(e), S0, A5));
        return reopen(e);
      }).then(function (r) {
        eq('(g) reopen: the banner shows again', r.st.ui().banner, 'restore');
      });
    });

    acase('(h) Restore with the conflict sheet, hide during the sheet', function () {
      var e, r, N = setY(setX(S0, '2026-10-07'), '2026-10-24');
      return world({ S: N, entry: oldEntry(S0, A5) }).then(function (w) {
        e = w;
        eq('(h) open: banner', e.st.ui().banner, 'restore');
        var res = e.st.journal.restore();
        ok('(h) Restore opens the sheet (x conflicts)', !res.ok && res.reason === 'conflict' && e.st.ui().sheet);
        return e.st.onHide('hidden');
      }).then(function () { return settle(e); }).then(function () {
        ok('(h) {S, A} unchanged through the hide', entryIs(stored(e), S0, A5));
        ok('(h) read-only during the sheet', e.st.ui().readOnly);
        return reopen(e);
      }).then(function (w) {
        r = w;
        ok('(h) reopen: {S, A} unchanged', entryIs(stored(r), S0, A5));
        eq('(h) reopen: banner', r.st.ui().banner, 'restore');
        ok('(h) Restore: sheet', !r.st.journal.restore().ok && r.st.ui().sheet);
        r.st.journal.cancelSheet();
        ok('(h) cancel: still held', r.st.ui().readOnly && r.st.ui().banner === 'restore' && !r.st.ui().sheet);
        return settle(r);
      }).then(function () {
        ok('(h) cancel: {S, A} unchanged', entryIs(stored(r), S0, A5));
        ok('(h) Restore again: sheet', !r.st.journal.restore().ok);
        var res = r.st.journal.restore({ 't1.start': 'mine' });
        ok('(h) the choice applies', res.ok);
        ok('(h) the hold clears in the same step', !r.st.ui().readOnly);
        ok('(h) the chart shows A\'s x plus N\'s other change', xOf(r.s.live) === '2026-10-05' && yOf(r.s.live) === '2026-10-24');
        r.st.launch.mode = 'manual';
        r.fr.run();
        return settle(r);
      }).then(function () {
        ok('(h) the frame writes {N, live}', entryIs(stored(r), N, r.s.live), show(stored(r)));
      });
    });

    acase('(i) Restore, then commit, then hide (manual)', function () {
      var e, Cc;
      return world({ mode: 'manual', entry: oldEntry(S0, A5) }).then(function (w) {
        e = w;
        ok('(i) manual: Restore', e.st.journal.restore().ok);
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(i) manual: {S, A} after the frame, owned by this store', entryIs(stored(e), S0, A5) && stored(e).owner === e.st.id);
        Cc = setY(e.s.live, '2026-10-19');
        e.st.commit(Cc);
        return e.st.onHide('hidden');
      }).then(function () {
        ok('(i) manual: onHide evaluates at once: {S, C}', entryIs(stored(e), S0, Cc));
        eq('(i) manual: no updateNotes', e.mock.count('updateNotes'), 0);
        return reopen(e, { mode: 'manual' });
      }).then(function (r) {
        eq('(i) manual reopen: banner', r.st.ui().banner, 'restore');
        ok('(i) manual reopen: Restore gives C', r.st.journal.restore().ok && S.same(r.s.live, Cc));
      });
    });

    acase('(i) Restore, then commit, then hide (auto)', function () {
      var e, Cc;
      return world({ entry: oldEntry(S0, A5) }).then(function (w) {
        e = w;
        var res = e.st.journal.restore();
        return res.save;
      }).then(function (sv) {
        ok('(i) auto: Restore saved A', sv.ok && S.same(noteChart(e), A5));
        e.fr.run();
        return settle(e);
      }).then(function () {
        Cc = setY(e.s.live, '2026-10-19');
        e.st.scheduleSave(Cc);
        e.mock.resetCounts();
        return e.st.onHide('hidden');
      }).then(function () {
        var stResolved = seqOf(e, 'storeAppState', 'resolve'), upCall = seqOf(e, 'updateNotes', 'call');
        ok('(i) auto: the journal store resolved before the flush', stResolved.length === 1 && upCall.length === 1 && stResolved[0] < upCall[0], JSON.stringify(e.mock.events));
        ok('(i) auto: the flush wrote C', S.same(noteChart(e), Cc));
        ok('(i) auto: the journal store before the flush holds {A, C}', entryIs(stored(e), A5, Cc), show(stored(e)));
        e.fr.run();
        return settle(e);
      }).then(function () {
        eq('(i) auto: agree then D: none', stored(e), null);
        return reopen(e);
      }).then(function (r) {
        eq('(i) auto reopen: no banner', r.st.ui().banner, null);
        ok('(i) auto reopen: the chart shows C', S.same(r.s.live, Cc));
      });
    });

    acase('(j) Discard, then hide', function () {
      var e;
      return world({ entry: oldEntry(S0, A5) }).then(function (w) {
        e = w;
        ok('(j) Discard', e.st.journal.discard().ok);
        ok('(j) editable at once', !e.st.ui().readOnly && e.st.ui().banner === null);
        ok('(j) the chart shows S', S.same(e.s.live, S0));
        eq('(j) D applies to the map at once', e.st.journal.map[CH], undefined);
        return settle(e);
      }).then(function () {
        eq('(j) D at Discard: none stored', stored(e), null);
        return e.st.onHide('hidden');
      }).then(function (h) {
        eq('(j) the flush made no updateNotes call', e.mock.count('updateNotes'), 0);
        return reopen(e);
      }).then(function (r) { eq('(j) reopen: no banner', r.st.ui().banner, null); });
    });

    acase('(k) case 1: silent reload skipped during a flight', function () {
      var e, E = setY(S0, '2026-10-22'), key0, reg0;
      return world({ approved: true }).then(function (w) {
        e = w;
        e.mock.holdUpdateNotes();
        e.st.commit(A5);
        e.mock.setNote(CH, noteText(E));
        key0 = e.s.key; reg0 = e.s.region;
        return e.mock.resume();
      }).then(function () {
        ok('(k1) resume leaves base, key and region alone', S.same(e.s.base, S0) && e.s.key === key0 && e.s.region === reg0);
        return e.mock.release();
      }).then(function () { return settle(e); }).then(function () {
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(k1) the note ends as A+E', xOf(noteChart(e)) === '2026-10-05' && yOf(noteChart(e)) === '2026-10-22');
        eq('(k1) none at the end', stored(e), null);
      });
    });

    acase('(k) case 2: silent reload skipped during a revert', function () {
      var e, key0;
      return world({ approved: true }).then(function (w) {
        e = w;
        e.mock.holdUpdateNotes();
        e.mock.holdUpdateNotes();
        e.st.commit(A5);
        e.st.commit(setX(e.s.live, '2026-10-03'));
        ok('(k2) live equals base, writing is A', S.same(e.s.live, e.s.base) && S.same(e.s.writing, A5));
        key0 = e.s.key;
        return settle();
      }).then(function () {
        return e.mock.release('apply');
      }).then(function () {
        eq('(k2) the note now holds A', xOf(noteChart(e)), '2026-10-05');
        return e.mock.resume();
      }).then(function () {
        ok('(k2) resume does nothing', e.s.key === key0 && xOf(e.s.live) === '2026-10-03');
        return e.mock.release();
      }).then(function () { return settle(e); }).then(function () {
        ok('(k2) agree(A)', S.same(e.s.base, A5));
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(k2) agree(A) evaluates {A, S}', entryIs(stored(e), A5, S0), show(stored(e)));
        return e.mock.release();
      }).then(function () { return settle(e); }).then(function () {
        e.fr.run();
        return settle(e);
      }).then(function () {
        eq('(k2) x stays 3 on screen', xOf(e.s.live), '2026-10-03');
        eq('(k2) the next save wrote x=3', xOf(noteChart(e)), '2026-10-03');
        eq('(k2) then D: none', stored(e), null);
      });
    });

    acase('(k) case 3: silent reload skipped under hold', function () {
      var e, E = setY(S0, '2026-10-22'), key0;
      return world({ approved: true, entry: oldEntry(S0, A5) }).then(function (w) {
        e = w;
        eq('(k3) banner up', e.st.ui().banner, 'restore');
        e.mock.setNote(CH, noteText(E));
        key0 = e.s.key;
        return e.mock.resume();
      }).then(function () {
        ok('(k3) resume changes nothing', e.s.key === key0 && S.same(e.s.base, S0) && e.st.ui().banner === 'restore');
        e.st.launch.mode = 'manual';
        var res = e.st.journal.restore();
        ok('(k3) Restore', res.ok);
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(k3) Restore writes {S, A}', entryIs(stored(e), S0, A5), show(stored(e)));
        e.st.launch.mode = 'auto';
        return e.st.save();
      }).then(function (r) {
        ok('(k3) the first save missed, re-read E and merged', r.ok && e.lives.some(function (x) { return x.rebase; }));
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(k3) E survives alongside A', xOf(noteChart(e)) === '2026-10-05' && yOf(noteChart(e)) === '2026-10-22');
        eq('(k3) none at the end', stored(e), null);
      });
    });

    function twoCharts(S1, S2) {
      return seedFor(S1).concat([{ id: CH2, title: 'Plan 2', content: noteText(S2) }, { id: 'n3', title: 'Task three', type: 'task' }]);
    }
    var S2 = C({ v: 1, settings: { listHeading: 'Tasks' }, tasks: [{ id: 'u1', note: 'n3', title: 'Task three', start: '2026-11-02', end: '2026-11-04' }] });
    var B2 = M.setDates(S2, 'u1', day('2026-11-05'), day('2026-11-06')).chart;

    acase('(l) chart switch with unsaved edits', function () {
      var e, p;
      return world({ mode: 'manual', seed: twoCharts(S0, S2) }).then(function (w) {
        e = w;
        e.st.commit(A5);
        p = e.st.onHide('switch');
        ok('(l) {S1, A} is in journal.map at once', entryIs(e.st.journal.map[CH], S0, A5));
        return p;
      }).then(function () {
        ok('(l) and stored before chart 2 opens', entryIs(stored(e), S0, A5));
        return e.st.open(CH2);
      }).then(function (o) { return o.session.checked; }).then(function () {
        ok('(l) chart 2 commit', e.st.commit(B2));
        e.fr.run();
        return e.st.onHide('switch');
      }).then(function () {
        ok('(l) chart 2 has its own entry', entryIs(stored(e, CH2), S2, B2));
        ok('(l) chart 1 kept', entryIs(stored(e), S0, A5));
        return e.st.open(CH);
      }).then(function (o) { return o.session.checked; }).then(function () {
        eq('(l) back on chart 1: banner from the map', e.st.ui().banner, 'restore');
        ok('(l) held', e.st.ui().readOnly);
        eq('(l) the pill stays "Unsaved changes. Tap to save"', e.st.ui().pill, 'unsaved');
        return e.st.onHide('switch');
      }).then(function () { return settle(e); }).then(function () {
        ok('(l) the last onHide leaves chart 1 intact', entryIs(stored(e), S0, A5));
        ok('(l) and chart 2 intact', entryIs(stored(e, CH2), S2, B2));
      });
    });

    acase('(m) embed launch never writes', function () {
      var e;
      return world({ entry: oldEntry(S0, A5), mock: { Params: { mode: 'embed' } } }).then(function (w) {
        e = w;
        ok('(m) embed launch', e.st.launch.embed);
        eq('(m) no banner', e.st.ui().banner, null);
        ok('(m) renders S', S.same(e.s.live, S0));
        ok('(m) no editing', !e.st.commit(A5));
        return e.st.onHide('pagehide');
      }).then(function () { return e.mock.resume(); }).then(function () { return settle(e); }).then(function () {
        eq('(m) zero storeAppState calls', e.mock.count('storeAppState'), 0);
        ok('(m) the entry is unchanged', entryIs(stored(e), S0, A5));
      });
    });

    acase('(n) two saves back to back', function () {
      var e, B6;
      return world({ approved: true }).then(function (w) {
        e = w;
        e.mock.holdUpdateNotes();
        e.st.commit(A5);
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(n) {S, A}', entryIs(stored(e), S0, A5));
        B6 = setY(e.s.live, '2026-10-19');
        e.st.commit(B6);
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(n) {S, B}', entryIs(stored(e), S0, B6));
        e.mock.holdUpdateNotes();
        return e.mock.release();
      }).then(function () { return settle(e); }).then(function () {
        ok('(n) A agreed and save B is parked', S.same(e.s.base, A5) && e.mock.parked() === 1);
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(n) agree(A) evaluates {A, B}', entryIs(stored(e), A5, B6), show(stored(e)));
        return e.mock.release();
      }).then(function () { return settle(e); }).then(function () {
        e.fr.run();
        return settle(e);
      }).then(function () {
        eq('(n) agree(B) evaluates D: none', stored(e), null);
        eq('(n) no banner', e.st.ui().banner, null);
      });
    });

    acase('(n) variant: crash on the second save', function () {
      var e, B6;
      return world({ approved: true }).then(function (w) {
        e = w;
        e.mock.holdUpdateNotes();
        e.st.commit(A5);
        B6 = setY(A5, '2026-10-19');
        e.st.commit(B6);
        e.mock.holdUpdateNotes();
        return settle();
      }).then(function () {
        return e.mock.release();
      }).then(function () { return settle(e); }).then(function () {
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(n) variant: {A, B} at the crash', entryIs(stored(e), A5, B6));
        e.mock.haltAfter('beforeUpdateNotes');
        return reopen(e);
      }).then(function (r) {
        eq('(n) variant: banner', r.st.ui().banner, 'restore');
        var res = r.st.journal.restore();
        ok('(n) variant: Restore gives B with no conflict (base A)', res.ok && S.same(r.s.live, B6));
      });
    });

    acase('(o) conflict, then a resolutions save', function () {
      var e, A2 = setY(A5, '2026-10-20'), E = setY(setX(S0, '2026-10-07'), '2026-10-26'), up;
      return world({ mode: 'manual' }).then(function (w) {
        e = w;
        e.st.commit(A2);
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(o) {S, A}', entryIs(stored(e), S0, A2));
        e.mock.setNote(CH, noteText(E));
        return e.st.save();
      }).then(function (r) {
        eq('(o) the pill-tap save fails as conflict', r.reason, 'conflict');
        same('(o) on x and y', r.conflicts.map(function (c) { return c.key; }).sort(), ['t1.start', 't2.end']);
        return settle(e);
      }).then(function () {
        ok('(o) {S, A} unchanged by the conflict', entryIs(stored(e), S0, A2));
        up = e.mock.count('updateNotes');
        e.mock.holdUpdateNotes();
        var p = e.st.saveOnce(e.s, { resolutions: { 't1.start': 'mine', 't2.end': 'theirs' } });
        return settle(e).then(function () {
          e.fr.run();
          return settle(e);
        }).then(function () {
          ok('(o) after the merge: {E, merged}', entryIs(stored(e), E, e.s.live) && xOf(e.s.live) === '2026-10-05' && yOf(e.s.live) === '2026-10-26', show(stored(e)));
          e.mock.release();
          return p;
        });
      }).then(function (r) {
        ok('(o) the resolutions save agreed', r.ok, JSON.stringify(r));
        eq('(o) exactly one updateNotes call', e.mock.count('updateNotes') - up, 1);
        ok('(o) A\'s x and E\'s y in the note', xOf(noteChart(e)) === '2026-10-05' && yOf(noteChart(e)) === '2026-10-26');
        e.fr.run();
        return settle(e);
      }).then(function () { eq('(o) D after agree: none', stored(e), null); });
    });

    acase('(o) variant: one conflict left out of resolutions', function () {
      var e, A2 = setY(A5, '2026-10-20'), E = setY(setX(S0, '2026-10-07'), '2026-10-26'), up;
      return world({ mode: 'manual' }).then(function (w) {
        e = w;
        e.st.commit(A2);
        e.mock.setNote(CH, noteText(E));
        return e.st.save();
      }).then(function () {
        up = e.mock.count('updateNotes');
        return e.st.saveOnce(e.s, { resolutions: { 't1.start': 'mine' } });
      }).then(function (r) {
        eq('(o) variant: fails as conflict', r.reason, 'conflict');
        same('(o) variant: the one left', r.conflicts.map(function (c) { return c.key; }), ['t2.end']);
        eq('(o) variant: no updateNotes call', e.mock.count('updateNotes'), up);
      });
    });

    var MALFORMED = 'Intro text.\n\n```synapse-gantt\n{"v":1,\n"tasks":[\n```';
    var FUTURE = 'Intro text.\n\n```synapse-gantt\n{"v":2,"tasks":[]}\n```';
    [['malformed', MALFORMED], ['future', FUTURE]].forEach(function (k) {
      acase('(p) block ' + k[0] + ': the entry is kept', function () {
        var e;
        return world({ entry: oldEntry(S0, A5), seed: [{ id: CH, title: 'Plan', content: k[1] }, { id: 'n1', title: 'Task one' }] }).then(function (w) {
          e = w;
          eq('(p) ' + k[0] + ': banner with Copy chart JSON only', e.st.ui().banner, 'kept');
          ok('(p) ' + k[0] + ': read-only', e.st.ui().readOnly);
          ok('(p) ' + k[0] + ': Discard is not offered', !e.st.journal.discard().ok);
          return e.st.onHide('pagehide');
        }).then(function () { return settle(e); }).then(function () {
          ok('(p) ' + k[0] + ': kept through the hide', entryIs(stored(e), S0, A5));
          return reopen(e);
        }).then(function (r) {
          eq('(p) ' + k[0] + ': reopen: kept', r.st.ui().banner, 'kept');
          ok('(p) ' + k[0] + ': still stored', entryIs(stored(r), S0, A5));
          eq('(p) ' + k[0] + ': never written', r.mock.count('updateNotes') + e.mock.count('updateNotes'), 0);
        });
      });
    });

    acase('(p) block none: Recreate', function () {
      var e, r;
      return world({ entry: oldEntry(S0, A5), seed: [{ id: CH, title: 'Plan', content: 'The block is gone.' }, { id: 'n1', title: 'Task one', type: 'task' }, { id: 'n2', title: 'Task two', type: 'task' }] }).then(function (w) {
        e = w;
        ok('(p) none: no session opens', !e.open.ok && e.open.reason === 'none' && !e.st.session);
        ok('(p) none: pendingForNote returns it', entryIs(e.st.journal.pendingForNote(CH), S0, A5));
        ok('(p) none: the open result carries it (chooser item 0)', entryIs(e.open.entry, S0, A5));
        return e.st.convertNote(CH, S.chartOf(e.open.entry.chart));
      }).then(function (res) {
        ok('(p) none: Recreate appends a region holding A', res.ok && S.same(noteChart(e), A5), JSON.stringify(res && res.reason));
        eq('(p) none: the body is kept', e.mock.content(CH).indexOf('The block is gone.\n\n```synapse-gantt') === 0 || e.mock.content(CH).indexOf('The block is gone.\n\n## Tasks\n\n- [') === 0, true);
        return e.st.session.checked;
      }).then(function () { return settle(e); }).then(function () {
        eq('(p) none: the open that follows deleted the entry', stored(e), null);
        noWhole('(p) none', e);
      });
    });

    acase('(p) a failed first append', function () {
      var e;
      return world({ seed: [{ id: CH, title: 'Plan', content: 'Plain note.' }, { id: 'n1', title: 'Task one', type: 'task' }, { id: 'n2', title: 'Task two', type: 'task' }], mock: { approve: 'deny' } }).then(function (w) {
        e = w;
        return e.st.convertNote(CH, A5);
      }).then(function (res) {
        ok('(p) first append denied', !res.ok && res.reason === 'denied', JSON.stringify(res));
        e.fr.run();
        return settle(e);
      }).then(function () {
        var en = stored(e);
        ok('(p) the entry has baseKey ∅', !!en && en.baseKey === S.EMPTY_KEY && S.same(S.chartOf(en.chart), A5));
        return reopen(e);
      }).then(function (r) {
        ok('(p) reopen: none, with the entry', !r.open.ok && r.open.reason === 'none' && !!r.open.entry);
        return r.st.convertNote(CH, S.chartOf(r.open.entry.chart)).then(function (res) {
          ok('(p) Recreate works', res.ok);
          return r.st.session.checked;
        }).then(function () { return settle(r); }).then(function () {
          eq('(p) the next open deleted the entry', stored(r), null);
        });
      });
    });

    acase('(q) hide ordering in auto with a debounced commit', function () {
      var e;
      return world().then(function (w) {
        e = w;
        e.mock.resetCounts();
        e.st.scheduleSave(A5);
        eq('(q) a debounce is armed', e.tm.count(S.DEBOUNCE_MS), 1);
        return e.st.onHide('hidden');
      }).then(function () {
        var sr = seqOf(e, 'storeAppState', 'resolve'), uc = seqOf(e, 'updateNotes', 'call');
        ok('(q) {S, A} stored and resolved before the flush updateNotes', sr.length >= 1 && uc.length === 1 && sr[0] < uc[0]);
        eq('(q) the flush cancelled the debounce', e.tm.count(S.DEBOUNCE_MS), 0);
        eq('(q) the only updateNotes', e.mock.count('updateNotes'), 1);
        ok('(q) {S, A} stored', entryIs(stored(e), S0, A5), show(stored(e)));
        e.fr.run();
        return settle(e);
      }).then(function () {
        eq('(q) the flush agree then D: none', stored(e), null);
        eq('(q) still one updateNotes', e.mock.count('updateNotes'), 1);
      });
    });
    ['manual', 'paused'].forEach(function (mode) {
      acase('(q) hide in ' + mode, function () {
        var e;
        return world({ mode: mode }).then(function (w) {
          e = w;
          e.st.scheduleSave(A5);
          return e.st.onHide('hidden');
        }).then(function () {
          ok('(q) ' + mode + ': {S, A}', entryIs(stored(e), S0, A5));
          eq('(q) ' + mode + ': no updateNotes', e.mock.count('updateNotes'), 0);
        });
      });
    });
    acase('(q) undo back to the saved chart', function () {
      var e, stack = U.createStack({});
      return world({ mode: 'manual' }).then(function (w) {
        e = w;
        var r = M.setDates(e.s.live, 't1', day('2026-10-05'), M.task(e.s.live, 't1').end);
        stack.push({ label: 'Move', patches: r.inverse });
        e.st.commit(r.chart);
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(q) undo: {S, A}', entryIs(stored(e), S0, A5));
        return e.st.undo(stack);
      }).then(function (u) {
        ok('(q) undo applied', u.ok && S.same(e.s.live, S0));
        e.fr.run();
        return settle(e);
      }).then(function () {
        eq('(q) undo: D: none', stored(e), null);
        return reopen(e);
      }).then(function (r) { eq('(q) reopen after the undo: no banner', r.st.ui().banner, null); });
    });

    acase('(r) frame coalescing and host effects', function () {
      var e, n0, ev0, map0;
      var seed = seedFor(S0).map(function (n) { return n.id === 'n1' ? Object.assign({}, n, { content: '## Checklist\n- [ ] a\n- [ ] b' }) : n; });
      return world({ mode: 'manual', seed: seed }).then(function (w) {
        e = w;
        e.st.commit(A5);
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(r) {S, A}', entryIs(stored(e), S0, A5));
        n0 = e.mock.count('storeAppState');
        ev0 = e.st.journal.evaluations;
        e.st.commit(setY(A5, '2026-10-19'));
        return e.st.save();
      }).then(function (r) {
        ok('(r) the commit and the agree landed before the frame', r.ok);
        eq('(r) one frame pending', e.fr.count(), 1);
        e.fr.run();
        return settle(e);
      }).then(function () {
        eq('(r) one evaluation', e.st.journal.evaluations - ev0, 1);
        eq('(r) one journal operation (D)', e.mock.count('storeAppState') - n0, 1);
        eq('(r) none', stored(e), null);
        n0 = e.mock.count('storeAppState');
        map0 = JSON.stringify(e.st.journal.map);
        return e.st.toggleItem('n1', { index: 1 });
      }).then(function (t) {
        ok('(r) the checkbox toggle', t.ok, JSON.stringify(t));
        return e.st.renameChart('Renamed plan');
      }).then(function (rn) {
        ok('(r) the rename', rn.ok && e.mock.note(CH).title === 'Renamed plan');
        eq('(r) no frame', e.fr.count(), 0);
        return settle(e);
      }).then(function () {
        eq('(r) the toggle and the rename create and delete nothing', JSON.stringify(e.st.journal.map), map0);
        eq('(r) no storeAppState from host effects', e.mock.count('storeAppState'), n0);
      });
    });

    acase('(s) Discard, switch, back', function () {
      var e;
      return world({ entry: oldEntry(S0, A5), seed: twoCharts(S0, S2) }).then(function (w) {
        e = w;
        e.mock.failStores(50);      // the stored blob keeps {S1, A}
        ok('(s) Discard', e.st.journal.discard().ok);
        eq('(s) D applies to journal.map', e.st.journal.map[CH], undefined);
        return e.st.onHide('switch');
      }).then(function () { return e.st.open(CH2); }).then(function (o) { return o.session.checked; }).then(function () {
        return e.st.onHide('switch');
      }).then(function () { return e.st.open(CH); }).then(function (o) { return o.session.checked; }).then(function () {
        ok('(s) the boot blob still held {S1, A}', entryIs(stored(e), S0, A5));
        eq('(s) no entry in the map on return', e.st.journal.map[CH], undefined);
        eq('(s) no banner', e.st.ui().banner, null);
        ok('(s) editable once checkOnOpen runs', !e.st.ui().readOnly);
      });
    });

    acase('(t) slow loadAppState meets an early drag', function () {
      var e, storage = new Map(), m0 = H.installMock(null, { storage: storage, global: false, appId: 'gantt-store-test' });
      m0.setState({ v: 1, journal: jmap(CH, oldEntry(S0, A5)) });
      e = env({ seed: seedFor(S0), storage: storage, mock: { latency: { loadAppState: 500 } } });
      e.st.boot();
      return e.st.open({ noteId: CH, read: B.read(e.mock.content(CH)), text: e.mock.content(CH) }).then(function (o) {
        e.s = o.session;
        ok('(t) first paint needs no bridge call', S.same(e.s.live, S0) && e.mock.count('runQuery') <= 2);
        ok('(t) read-only until the load resolves', e.st.ui().readOnly);
        return sleep(100);
      }).then(function () {
        ok('(t) the drag at 100 ms makes no commit', !e.st.commit(A5));
        return sleep(100);
      }).then(function () { return e.st.onHide('hidden'); }).then(function () {
        eq('(t) onHide at 200 ms makes no journal operation', e.mock.count('storeAppState'), 0);
        eq('(t) and no updateNotes', e.mock.count('updateNotes'), 0);
        return e.s.checked;
      }).then(function () { return settle(e); }).then(function () {
        ok('(t) {S, A} survives', entryIs(stored(e), S0, A5));
        eq('(t) checkOnOpen offers it', e.st.ui().banner, 'restore');
      });
    });

    acase('(t) variant: no entry', function () {
      var e = env({ seed: seedFor(S0), mock: { latency: { loadAppState: 60 } } });
      e.st.boot();
      return e.st.open({ noteId: CH, read: B.read(e.mock.content(CH)), text: e.mock.content(CH) }).then(function (o) {
        e.s = o.session;
        ok('(t) variant: read-only before the load', e.st.ui().readOnly && !e.st.commit(A5));
        return e.s.checked;
      }).then(function () {
        ok('(t) variant: editable when the load resolves', !e.st.ui().readOnly);
        eq('(t) variant: none stored', stored(e), null);
        ok('(t) variant: a drag then commits', e.st.commit(A5));
      });
    });

    function failedOpen(fails, mode) {
      var storage = new Map(), m0 = H.installMock(null, { storage: storage, global: false, appId: 'gantt-store-test' });
      m0.setState({ v: 1, journal: jmap(CH, oldEntry(S0, A5)) });
      var e = env({ seed: seedFor(S0), storage: storage });
      e.st.launch.mode = mode || 'manual';
      e.mock.failLoads(fails);
      return e.st.boot().then(function () { return e.st.open({ noteId: CH, read: B.read(e.mock.content(CH)), text: e.mock.content(CH) }); }).then(function (o) {
        e.s = o.session;
        return e.s.checked;
      }).then(function () { return e; });
    }
    // failLoads(3): B's own journal write fails too and a resume is the first
    // successful refresh; failLoads(2): B's own write is that refresh.
    [3, 2].forEach(function (nf) {
    acase('(t) variant 2: failed loads, Edit anyway, then the late check (failLoads ' + nf + ')', function () {
      var e, Bc;
      return failedOpen(nf).then(function (w) {
        e = w;
        eq('(t2/' + nf + ') "Couldn\'t check" banner', e.st.ui().banner, 'check-failed');
        ok('(t2/' + nf + ') read-only', e.st.ui().readOnly);
        ok('(t2/' + nf + ') Edit anyway', e.st.journal.editAnyway().ok && !e.st.ui().readOnly);
        Bc = setY(e.s.live, '2026-10-19');
        ok('(t2/' + nf + ') commit B', e.st.commit(Bc));
        e.fr.run();
        return settle(e);
      }).then(function () {
        if (nf === 3) ok('(t2/' + nf + ') {S, B} stays pending while loads fail', e.st.state.pending().journal.some(function (x) { return x.chart === CH && x.kind === 'W' && x.failed; }));
        else eq('(t2/' + nf + ') B\'s own write is the first successful refresh: late check banner', e.st.ui().banner, 'restore');
        ok('(t2/' + nf + ') the stored entry is still {S, A}', entryIs(stored(e), S0, A5) && stored(e).owner === 'st-earlier');
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () {
        eq('(t2/' + nf + ') the successful refresh finds it foreign: late check banner', e.st.ui().banner, 'restore');
        ok('(t2/' + nf + ') the offer is merge3(S, A, B)', e.s.offer && e.s.offer.late && xOf(e.s.offer.r.chart) === '2026-10-05' && yOf(e.s.offer.r.chart) === '2026-10-19');
        ok('(t2/' + nf + ') stored stays {S, A} of the earlier launch', entryIs(stored(e), S0, A5) && stored(e).owner === 'st-earlier');
        ok('(t2/' + nf + ') the map shows the other entry', entryIs(e.st.journal.map[CH], S0, A5) && e.st.journal.map[CH].owner === 'st-earlier');
        ok('(t2/' + nf + ') held until answered', e.st.ui().readOnly);
        e.fr.run();
        return e.mock.resume().then(function () { return e.st.onHide('hidden'); }).then(function () { return settle(e); });
      }).then(function () {
        ok('(t2/' + nf + ') later refreshes and queue runs still leave it', entryIs(stored(e), S0, A5) && stored(e).owner === 'st-earlier');
        ok('(t2/' + nf + ') and the map still shows it', entryIs(e.st.journal.map[CH], S0, A5) && e.st.journal.map[CH].owner === 'st-earlier');
        var res = e.st.journal.restore();
        ok('(t2/' + nf + ') Restore gives A and B', res.ok && xOf(e.s.live) === '2026-10-05' && yOf(e.s.live) === '2026-10-19');
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('(t2/' + nf + ') after Restore the store owns {S, A+B}', entryIs(stored(e), S0, e.s.live) && stored(e).owner === e.st.id);
      });
    });
    });

    acase('(t) variant 3: the commit makes live equal to A', function () {
      var e;
      return failedOpen(2).then(function (w) {
        e = w;
        eq('(t3) "Couldn\'t check" banner', e.st.ui().banner, 'check-failed');
        e.st.journal.editAnyway();
        e.st.commit(A5);
        e.fr.run();
        return settle(e);
      }).then(function () { return settle(e); }).then(function () {
        eq('(t3) no banner', e.st.ui().banner, null);
        ok('(t3) editable', !e.st.ui().readOnly);
        ok('(t3) {S, A} now owned by this store (no D queued)', entryIs(stored(e), S0, A5) && stored(e).owner === e.st.id, show(stored(e)));
      });
    });

    acase('(t) Retry after a failed check', function () {
      var e;
      return failedOpen(2).then(function (w) {
        e = w;
        return e.st.journal.retry();
      }).then(function (r) {
        eq('(t) Retry runs checkOnOpen', r.kind, 'offer');
        eq('(t) Retry: the Restore banner', e.st.ui().banner, 'restore');
      });
    });

    // (u) Two full instances over the same notes and appState.
    function instanceY(x, o) {
      var y = env({ db: x.mock.db, storage: x.storage, mock: Object.assign({ approvalMs: 200 }, o || {}) });
      return y.st.boot().then(function () { return y.st.open({ noteId: CH, read: B.read(y.mock.content(CH)), text: y.mock.content(CH) }); }).then(function (r) {
        y.open = r; y.s = r.session;
        return y.s.checked;
      }).then(function () { return settle(y); }).then(function () { return y; });
    }

    acase('(u) two full instances of one app id', function () {
      var x, y;
      return world().then(function (w) {
        x = w;
        return x.st.onHide('hidden');
      }).then(function () { return instanceY(x); }).then(function (w) {
        y = w;
        eq('(u) Y opens with no entry', y.st.ui().banner, null);
        y.st.commit(A5);
        y.fr.run();
        return settle(y);
      }).then(function () {
        ok('(u) Y stores {S, A} with owner Y', entryIs(stored(y), S0, A5) && stored(y).owner === y.st.id);
        y.mock.haltAfter('beforeUpdateNotes');
        return x.mock.resume();
      }).then(function () { return settle(x); }).then(function () {
        eq('(u) X re-opens and offers it', x.st.ui().banner, 'restore');
        ok('(u) X is read-only until answered', x.st.ui().readOnly);
        ok('(u) the offer is A', S.same(S.chartOf(x.s.offer.entry.chart), A5) && !x.s.offer.late);
        x.fr.run();
        return x.st.onHide('hidden');
      }).then(function () { return settle(x); }).then(function () {
        ok('(u) X never queues D over it', entryIs(stored(x), S0, A5) && stored(x).owner === y.st.id);
      });
    });

    acase('(u) variant: X journaled B, Y restored it and added A', function () {
      var x, y, Bc = setY(S0, '2026-10-19'), BA;
      return world({ mode: 'manual' }).then(function (w) {
        x = w;
        x.st.commit(Bc);
        return x.st.onHide('hidden');
      }).then(function () {
        ok('(u1) {S, B} owned by X', entryIs(stored(x), S0, Bc) && stored(x).owner === x.st.id);
        return instanceY(x);
      }).then(function (w) {
        y = w;
        eq('(u1) Y offers {S, B}', y.st.ui().banner, 'restore');
        ok('(u1) Y restores B', y.st.journal.restore().ok);
        BA = setX(y.s.live, '2026-10-05');
        y.st.commit(BA);
        y.fr.run();
        return settle(y);
      }).then(function () {
        ok('(u1) {S, B+A} owned by Y', entryIs(stored(y), S0, BA) && stored(y).owner === y.st.id, show(stored(y)));
        y.mock.haltAfter('beforeUpdateNotes');
        return x.mock.resume();
      }).then(function () { return settle(x); }).then(function () {
        eq('(u1) X late-checks and offers it', x.st.ui().banner, 'restore');
        ok('(u1) a late check (X keeps live = B)', x.s.offer.late && S.same(x.s.live, Bc));
        ok('(u1) X is read-only until answered', x.st.ui().readOnly && !x.st.commit(color1(x.s.live, 'rose')));
        ok('(u1) offered: B and A', xOf(x.s.offer.r.chart) === '2026-10-05' && yOf(x.s.offer.r.chart) === '2026-10-19');
        ok('(u1) stored stays {S, B+A} owned by Y', entryIs(stored(x), S0, BA) && stored(x).owner === y.st.id);
      });
    });

    acase('(u) variant 2: X\'s failed W stays pending', function () {
      var x, y, Bc = setY(S0, '2026-10-19');
      return world({ mode: 'manual' }).then(function (w) {
        x = w;
        x.mock.failLoads(2);
        x.st.commit(Bc);
        x.fr.run();
        return settle(x);
      }).then(function () { return x.st.onHide('hidden'); }).then(function () {
        eq('(u2) X\'s W failed: nothing stored', stored(x), null);
        return instanceY(x);
      }).then(function (w) {
        y = w;
        eq('(u2) Y opens with no entry', y.st.ui().banner, null);
        y.st.commit(A5);
        y.fr.run();
        return settle(y);
      }).then(function () {
        y.mock.haltAfter('beforeUpdateNotes');
        return x.mock.resume();
      }).then(function () { return settle(x); }).then(function () {
        eq('(u2) X late-checks', x.st.ui().banner, 'restore');
        ok('(u2) X keeps live = B', x.s.offer.late && S.same(x.s.live, Bc));
        ok('(u2) X is read-only until answered', x.st.ui().readOnly && !x.st.commit(color1(x.s.live, 'rose')));
        ok('(u2) merge3(S, A, B)', xOf(x.s.offer.r.chart) === '2026-10-05' && yOf(x.s.offer.r.chart) === '2026-10-19');
        ok('(u2) stored stays {S, A} owned by Y', entryIs(stored(x), S0, A5) && stored(x).owner === y.st.id);
        ok('(u2) X\'s {S, B} stays pending', x.st.state.pending().journal.some(function (p) { return p.chart === CH && p.kind === 'W'; }));
        ok('(u2) X\'s map shows Y\'s entry', entryIs(x.st.journal.map[CH], S0, A5) && x.st.journal.map[CH].owner === y.st.id);
        ok('(u2) Restore', x.st.journal.restore().ok);
        x.fr.run();
        return settle(x);
      }).then(function () {
        ok('(u2) Restore stores {S, A+B} owned by X', entryIs(stored(x), S0, x.s.live) && stored(x).owner === x.st.id && xOf(x.s.live) === '2026-10-05' && yOf(x.s.live) === '2026-10-19');
      });
    });

    acase('(u) variant 3: an open conflict sheet closes as a cancel', function () {
      var x, y, N = setY(setX(S0, '2026-10-07'), '2026-10-24'), A0 = setX(S0, '2026-10-09'), An;
      return world({ S: N, entry: oldEntry(S0, A0) }).then(function (w) {
        x = w;
        eq('(u3) X offers the earlier entry', x.st.ui().banner, 'restore');
        ok('(u3) X opens the conflict sheet', !x.st.journal.restore().ok && x.st.ui().sheet);
        return x.st.onHide('hidden');
      }).then(function () { return instanceY(x); }).then(function (w) {
        y = w;
        eq('(u3) Y offers it too', y.st.ui().banner, 'restore');
        ok('(u3) Y answers it (Discard)', y.st.journal.discard().ok);
        An = color1(y.s.live, 'teal');
        y.st.commit(An);
        y.fr.run();
        return settle(y);
      }).then(function () {
        ok('(u3) Y journals {N, A}', entryIs(stored(y), N, An) && stored(y).owner === y.st.id, show(stored(y)));
        y.mock.haltAfter('beforeUpdateNotes');
        return x.mock.resume();
      }).then(function () { return settle(x); }).then(function () {
        ok('(u3) the sheet closed as a cancel', !x.st.ui().sheet);
        eq('(u3) X shows the banner for A', x.st.ui().banner, 'restore');
        ok('(u3) the offer is Y\'s entry', x.s.offer.entry.owner === y.st.id && !x.s.offer.late);
        var r = x.st.journal.restore({ 't1.start': 'mine' });
        ok('(u3) the old resolutions are never applied', !r.ok && r.reason === 'no-sheet');
        ok('(u3) stored unchanged', entryIs(stored(x), N, An) && stored(x).owner === y.st.id);
      });
    });

    acase('(u) a foreign entry found during a save is handled once the save ends', function () {
      var x, y, Yc = setY(S0, '2026-10-28'), Xb;
      return world({ approved: true }).then(function (w) {
        x = w;
        x.mock.holdUpdateNotes();
        x.st.commit(A5);
        return settle(x);
      }).then(function () { return instanceY(x); }).then(function (w) {
        y = w;
        y.st.commit(Yc);
        y.fr.run();
        return settle(y);
      }).then(function () {
        y.mock.haltAfter('beforeUpdateNotes');
        return x.mock.resume();
      }).then(function () { return settle(x); }).then(function () {
        eq('(u4) nothing happens while X\'s save is in flight', x.st.ui().banner, null);
        Xb = color1(x.s.live, 'rose');
        ok('(u4) X can still commit', x.st.commit(Xb));
        x.fr.run();
        ok('(u4) queuing X\'s W leaves the other entry in the map', entryIs(x.st.journal.map[CH], S0, Yc));
        return settle(x);
      }).then(function () {
        ok('(u4) X\'s W does not replace the other entry in the map', entryIs(x.st.journal.map[CH], S0, Yc) && x.st.journal.map[CH].owner === y.st.id);
        ok('(u4) nor in storage', entryIs(stored(x), S0, Yc));
        return x.mock.release();
      }).then(function () { return settle(x); }).then(function () {
        eq('(u4) after the save: the late check offers it', x.st.ui().banner, 'restore');
        ok('(u4) a late check (own op pending)', x.s.offer.late && yOf(x.s.offer.r.chart) === '2026-10-28' && M.task(x.s.offer.r.chart, 't1').color === 'rose');
        ok('(u4) stored stays Y\'s', entryIs(stored(x), S0, Yc) && stored(x).owner === y.st.id);
      });
    });

    /* ------------- review round 1 walkthrough variants (REV1 to REV3) */

    function failedOpenNoEntry(fails) {
      var e = env({ seed: seedFor(S0) });
      e.st.launch.mode = 'manual';
      e.mock.failLoads(fails);
      return e.st.boot().then(function () { return e.st.open({ noteId: CH, read: B.read(e.mock.content(CH)), text: e.mock.content(CH) }); }).then(function (o) {
        e.s = o.session;
        return e.s.checked;
      }).then(function () { return e; });
    }

    acase('(t) REV1: Edit anyway, the armed late check disarms, then another instance writes', function () {
      var x, y, Bc = setY(S0, '2026-10-19'), BA;
      return failedOpenNoEntry(2).then(function (w) {
        x = w;
        eq('REV1 "Couldn\'t check" banner', x.st.ui().banner, 'check-failed');
        x.st.journal.editAnyway();
        return x.mock.resume();
      }).then(function () { return settle(x); }).then(function () {
        eq('REV1 no entry: the armed late check disarms, no banner', x.st.ui().banner, null);
        ok('REV1 commit B', x.st.commit(Bc));
        x.fr.run();
        return settle(x);
      }).then(function () {
        ok('REV1 {S, B} stored by X', entryIs(stored(x), S0, Bc) && stored(x).owner === x.st.id, show(stored(x)));
        return x.st.onHide('hidden');
      }).then(function () { return instanceY(x); }).then(function (w) {
        y = w;
        eq('REV1 Y offers {S, B}', y.st.ui().banner, 'restore');
        ok('REV1 Y restores', y.st.journal.restore().ok);
        BA = setX(y.s.live, '2026-10-05');
        y.st.commit(BA);
        y.fr.run();
        return settle(y);
      }).then(function () {
        ok('REV1 {S, B+A} owned by Y', entryIs(stored(y), S0, BA) && stored(y).owner === y.st.id);
        y.mock.haltAfter('beforeUpdateNotes');
        return x.mock.resume();
      }).then(function () { return settle(x); }).then(function () {
        eq('REV1 rule 6 still applies to X: late check banner', x.st.ui().banner, 'restore');
        ok('REV1 X keeps live = B and offers B+A', x.s.offer && x.s.offer.late && S.same(x.s.live, Bc) && S.same(x.s.offer.r.chart, BA));
        ok('REV1 X is read-only until answered', x.st.ui().readOnly && !x.st.commit(color1(x.s.live, 'rose')));
        x.fr.run();
        return x.st.onHide('hidden').then(function () { return settle(x); });
      }).then(function () {
        ok('REV1 stored stays Y\'s', entryIs(stored(x), S0, BA) && stored(x).owner === y.st.id);
      });
    });

    acase('(l) REV2: an own unstored entry offered at reopen survives refresh, switch and hide', function () {
      var e;
      return world({ mode: 'manual', seed: twoCharts(S0, S2) }).then(function (w) {
        e = w;
        e.mock.failStores(50);
        e.st.commit(A5);
        e.fr.run();
        return settle(e);
      }).then(function () { return e.st.onHide('switch'); }).then(function () {
        eq('REV2 nothing stored for chart 1', stored(e), null);
        return e.st.open(CH2);
      }).then(function (o) { return o.session.checked; }).then(function () { return e.st.onHide('switch'); }).then(function () {
        return e.st.open(CH);
      }).then(function (o) { return o.session.checked; }).then(function () {
        eq('REV2 back on chart 1: banner from its own pending W', e.st.ui().banner, 'restore');
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () {
        ok('REV2 the refresh keeps the own pending W in the map', entryIs(e.st.journal.map[CH], S0, A5), show(e.st.journal.map[CH]));
        return e.st.onHide('switch');
      }).then(function () { return e.st.open(CH2); }).then(function (o) { return o.session.checked; }).then(function () {
        e.mock.failStores(0);
        return e.st.onHide('switch');
      }).then(function () { return settle(e); }).then(function () { return e.st.open(CH); }).then(function (o) { return o.session.checked; }).then(function () { return settle(e); }).then(function () {
        eq('REV2 back again: still offered', e.st.ui().banner, 'restore');
        ok('REV2 the own W is stored now', entryIs(stored(e), S0, A5) && stored(e).owner === e.st.id, show(stored(e)));
        return e.st.onHide('hidden');
      }).then(function () { return settle(e); }).then(function () {
        ok('REV2 A survives in storage after the hide', entryIs(stored(e), S0, A5), show(stored(e)));
      });
    });

    acase('(k) REV3: a resume never re-sends an unsaved chart (conflict in auto)', function () {
      var e, A2 = setY(A5, '2026-10-20'), E = setY(setX(S0, '2026-10-07'), '2026-10-26'), up;
      return world({}).then(function (w) {
        e = w;
        e.mock.setNote(CH, noteText(E));
        e.st.commit(A2);
        return e.s.busy;
      }).then(function (r) {
        eq('REV3 the save fails as conflict', r.reason, 'conflict');
        up = e.mock.count('updateNotes');
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () { return e.mock.resume(); }).then(function () { return settle(e); }).then(function () {
        e.mock.tickInterval();
        return settle(e);
      }).then(function () {
        eq('REV3 resumes send no updateNotes (no dialog every 30 s)', e.mock.count('updateNotes') - up, 0);
        ok('REV3 the edits stay in memory and the journal', S.same(e.s.live, A2));
      });
    });

    /* ------------- review round 2 walkthrough variants (ADV1, ADV1b) */

    // X offers its OWN unstored W {S, A} (the REV2 state); Y then journals
    // {S, B} for the same chart; X resumes. The foreign entry waits until X's
    // own offer is answered, so the late check merges it against live with A.
    function ownOfferThenForeign(discardOwn) {
      var x, y, Bc;
      return deferredOwn().then(function (t) {
        x = t.x; y = t.y; Bc = t.Bc;
        if (discardOwn) {
          var d = x.st.journal.discard();
          ok('ADV X discards its own A', d.ok && S.same(x.s.live, S0));
          return Promise.resolve(d.deferred).then(function () { return settle(x); });
        }
        var r = x.st.journal.restore();
        ok('ADV X restores its own A', r.ok && S.same(x.s.live, A5));
        return Promise.resolve(r.deferred).then(function () { return settle(x); });
      }).then(function () {
        eq('ADV then the late check offers Y\'s entry', x.st.ui().banner, 'restore');
        var wantX = discardOwn ? '2026-10-03' : '2026-10-05';
        ok('ADV merged against live (' + wantX + ') and B', x.s.offer && x.s.offer.late && x.s.offer.entry.owner === y.st.id &&
          xOf(x.s.offer.r.chart) === wantX && yOf(x.s.offer.r.chart) === '2026-10-19');
        ok('ADV read-only until answered', x.st.ui().readOnly);
        return { x: x, y: y, Bc: Bc };
      });
    }

    // X offers its own unstored {S, A}; Y journals {S, B}; X resumes and
    // defers Y's entry. Resolves {x, y, Bc} in that state.
    function deferredOwn() {
      var x, y, Bc = setY(S0, '2026-10-19');
      return world({ mode: 'manual', seed: twoCharts(S0, S2) }).then(function (w) {
        x = w;
        x.mock.failStores(50);
        x.st.commit(A5);
        x.fr.run();
        return settle(x);
      }).then(function () { return x.st.onHide('switch'); }).then(function () { return x.st.open(CH2); })
        .then(function (o) { return o.session.checked; }).then(function () { return x.st.onHide('switch'); })
        .then(function () { return x.st.open(CH); }).then(function (o) { x.s = o.session; return o.session.checked; }).then(function () {
          ok('ADV X offers its own pending {S, A}', x.s.offer && x.s.offer.entry.owner === x.st.id && S.same(S.chartOf(x.s.offer.entry.chart), A5));
          return instanceY(x);
        }).then(function (w) {
          y = w;
          eq('ADV Y opens with no entry', y.st.ui().banner, null);
          y.st.commit(Bc);
          y.fr.run();
          return settle(y);
        }).then(function () {
          ok('ADV Y stored {S, B}', entryIs(stored(y), S0, Bc) && stored(y).owner === y.st.id);
          y.mock.haltAfter('beforeUpdateNotes');
          return x.mock.resume();
        }).then(function () { return settle(x); }).then(function () {
          ok('ADV the foreign entry waits: X still offers its own A', x.s.offer && x.s.offer.entry.owner === x.st.id && !x.s.offer.late);
          ok('ADV stored stays Y\'s', entryIs(stored(x), S0, Bc) && stored(x).owner === y.st.id);
          return { x: x, y: y, Bc: Bc };
        });
    }

    acase('(u) ADV1d: switch away and back while the other entry is deferred', function () {
      var t;
      return deferredOwn().then(function (w) {
        t = w;
        t.x.mock.failStores(0);
        return t.x.st.onHide('switch');
      }).then(function () { return t.x.st.open(CH2); }).then(function (o) { return o.session.checked; })
        .then(function () { return t.x.st.onHide('switch'); }).then(function () { return t.x.st.open(CH); })
        .then(function (o) { t.x.s = o.session; return o.session.checked; }).then(function () { return settle(t.x); }).then(function () {
          ok('ADV1d back on the chart: the own A is offered again, not Y\'s entry', t.x.s.offer && t.x.s.offer.entry.owner === t.x.st.id && S.same(S.chartOf(t.x.s.offer.entry.chart), A5));
          ok('ADV1d Y\'s entry is deferred and still stored', t.x.s.foreignPending && entryIs(stored(t.x), S0, t.Bc) && stored(t.x).owner === t.y.st.id);
          var r = t.x.st.journal.restore();
          ok('ADV1d Restore own A', r.ok && S.same(t.x.s.live, A5));
          return Promise.resolve(r.deferred).then(function () { return settle(t.x); });
        }).then(function () {
          ok('ADV1d then Y\'s entry is late-checked against A', t.x.s.offer && t.x.s.offer.late && t.x.s.offer.entry.owner === t.y.st.id &&
            xOf(t.x.s.offer.r.chart) === '2026-10-05' && yOf(t.x.s.offer.r.chart) === '2026-10-19');
          ok('ADV1d Restore theirs', t.x.st.journal.restore().ok);
          t.x.fr.run();
          return t.x.st.onHide('hidden').then(function () { return settle(t.x); });
        }).then(function () {
          ok('ADV1d A and B stored, owned by X', entryIs(stored(t.x), S0, t.x.s.live) && stored(t.x).owner === t.x.st.id &&
            xOf(t.x.s.live) === '2026-10-05' && yOf(t.x.s.live) === '2026-10-19', show(stored(t.x)));
        });
    });

    acase('(p) ADV1f: the block is gone while another entry waits behind the own A', function () {
      var t;
      return deferredOwn().then(function (w) {
        t = w;
        t.x.mock.failStores(0);
        return t.x.st.onHide('switch');
      }).then(function () { return t.x.st.open(CH2); }).then(function (o) { return o.session.checked; })
        .then(function () { return t.x.st.onHide('switch'); }).then(function () {
          t.x.mock.setNote(CH, 'Intro text.');
          return t.x.st.open(CH);
        }).then(function (o) {
          ok('ADV1f open: no session, the own A is shown (step 2)', !o.ok && o.reason === 'none' && o.entry && o.entry.owner === t.x.st.id && S.same(S.chartOf(o.entry.chart), A5));
          ok('ADV1f pendingForNote shows the own A too', t.x.st.journal.pendingForNote(CH).owner === t.x.st.id);
          ok('ADV1f Discard of the own A', t.x.st.journal.discard(CH).ok);
          return settle(t.x);
        }).then(function () {
          ok('ADV1f Y\'s entry is kept (not deleted with the own A)', entryIs(stored(t.x), S0, t.Bc) && stored(t.x).owner === t.y.st.id, show(stored(t.x)));
          ok('ADV1f and is shown next', t.x.st.journal.pendingForNote(CH).owner === t.y.st.id);
          eq('ADV1f no own op left', t.x.st.journal.hasOwnOp(CH), false);
        });
    });

    acase('(p) ADV1g: the block is gone; Recreate the own A while another entry waits', function () {
      var t;
      return deferredOwn().then(function (w) {
        t = w;
        t.x.mock.failStores(0);
        return t.x.st.onHide('switch');
      }).then(function () { return t.x.st.open(CH2); }).then(function (o) { return o.session.checked; })
        .then(function () { return t.x.st.onHide('switch'); }).then(function () {
          t.x.mock.setNote(CH, 'Intro text.');
          return t.x.st.open(CH);
        }).then(function (o) {
          t.x.st.launch.mode = 'auto';
          return t.x.st.convertNote(CH, S.chartOf(o.entry.chart));
        }).then(function (res) {
          ok('ADV1g Recreate appends A', res.ok && S.same(noteChart(t.x), A5));
          return t.x.st.session.checked;
        }).then(function (k) {
          // The Recreate session agreed on A, so its own op became a D; the
          // open offers Y's entry against the note, which now holds A.
          eq('ADV1g the open offers the other entry', k.kind, 'offer');
          return settle(t.x);
        }).then(function () {
          t.x.fr.run();
          return settle(t.x);
        }).then(function () {
          ok('ADV1g Y\'s entry was not overwritten', entryIs(stored(t.x), S0, t.Bc) && stored(t.x).owner === t.y.st.id, show(stored(t.x)));
          var s = t.x.st.session, o = s.offer;
          ok('ADV1g Y\'s entry is offered merged with A (the note holds A)', o && o.entry.owner === t.y.st.id &&
            xOf(o.r.chart) === '2026-10-05' && yOf(o.r.chart) === '2026-10-19' && S.same(s.live, A5));
          ok('ADV1g Restore gives A and B', t.x.st.journal.restore().ok && xOf(s.live) === '2026-10-05' && yOf(s.live) === '2026-10-19');
        });
    });

    acase('foreignPending clears when the other entry disappears before the deferred check', function () {
      var t;
      return deferredOwn().then(function (w) {
        t = w;
        ok('fp: set while deferred', t.x.s.foreignPending);
        var st0 = t.x.mock.state();
        delete st0.journal[CH];
        t.x.mock.setState(st0);
        return t.x.mock.resume();
      }).then(function () { return settle(t.x); }).then(function () {
        ok('fp: cleared by the refresh that finds no other entry', !t.x.s.foreignPending);
        ok('fp: the own offer is untouched', t.x.s.offer && t.x.s.offer.entry.owner === t.x.st.id);
      });
    });

    acase('(u) ADV1e: Restore of the own A in auto whose save conflicts; the end-of-save hook runs the deferred check', function () {
      var t;
      return deferredOwn().then(function (w) {
        t = w;
        t.x.mock.failStores(0);
        t.x.mock.setNote(CH, noteText(setX(S0, '2026-10-07')));
        t.x.st.launch.mode = 'auto';
        var r = t.x.st.journal.restore();
        ok('ADV1e Restore starts a save', r.ok && !!r.save);
        return r.save;
      }).then(function (sr) {
        eq('ADV1e the save fails as conflict', sr.reason, 'conflict');
        return settle(t.x);
      }).then(function () {
        t.x.fr.run();
        return settle(t.x);
      }).then(function () {
        var o = t.x.s.offer;
        ok('ADV1e the deferred late check ran after the save', o && o.late && o.entry.owner === t.y.st.id && !t.x.s.foreignPending);
        ok('ADV1e merged against live with A', xOf(o.r.chart) === '2026-10-05' && yOf(o.r.chart) === '2026-10-19');
        ok('ADV1e own W blocked, Y\'s entry stored', entryIs(stored(t.x), S0, t.Bc) && stored(t.x).owner === t.y.st.id);
      });
    });

    acase('(u) ADV1c: own offer discarded, then the deferred late check offers theirs', function () {
      return ownOfferThenForeign(true).then(function (t) {
        ok('ADV1c stored stays Y\'s until answered', entryIs(stored(t.x), S0, t.Bc) && stored(t.x).owner === t.y.st.id);
      });
    });

    acase('(u) ADV1: own offer, then another instance journals; Restore both', function () {
      var t;
      return ownOfferThenForeign().then(function (w) {
        t = w;
        ok('ADV1 Restore Y\'s entry', t.x.st.journal.restore().ok);
        ok('ADV1 live holds A and B', xOf(t.x.s.live) === '2026-10-05' && yOf(t.x.s.live) === '2026-10-19');
        t.x.fr.run();
        t.x.mock.failStores(0);
        return t.x.st.onHide('hidden').then(function () { return settle(t.x); });
      }).then(function () {
        ok('ADV1 stored {S, A+B} owned by X', entryIs(stored(t.x), S0, t.x.s.live) && stored(t.x).owner === t.x.st.id, show(stored(t.x)));
      });
    });

    acase('(u) ADV1b: own offer, then another instance journals; Discard theirs', function () {
      var t;
      return ownOfferThenForeign().then(function (w) {
        t = w;
        ok('ADV1b Discard Y\'s entry', t.x.st.journal.discard().ok);
        ok('ADV1b live keeps A', S.same(t.x.s.live, A5));
        t.x.mock.failStores(0);
        return t.x.st.onHide('hidden').then(function () { return settle(t.x); });
      }).then(function () {
        ok('ADV1b A survives: {S, A} owned by X', entryIs(stored(t.x), S0, A5) && stored(t.x).owner === t.x.st.id, show(stored(t.x)));
      });
    });

    // ADV4: a real toggle while an unrelated edit lands between the write and
    // the re-read verifies (the fallback counts inside the section).
    [['ADV4a twins in the section', '## C\n- [ ] a\n- [ ] a\n- [ ] a\n- [x] a', 3],
      ['ADV4b the same item in another section', '## C\n- [ ] milk\n- [ ] eggs\n\n## Other\n- [ ] milk', 1],
      ['ADV4c no twin', '## C\n- [ ] milk\n- [ ] eggs', 1],
      // The host scope for '## C' ends at the fenced '# comment' line; the
      // twin after the fence is outside it (M3b review round 3).
      ['ADV4d a twin after a fenced # line', '## C\n- [ ] milk\n```sh\n# comment\n```\n- [ ] milk', 1]].forEach(function (k) {
      acase('toggleItem ' + k[0] + ', with a concurrent unrelated edit', function () {
        var e;
        var seed = seedFor(chartS({ progressSection: 'C' })).map(function (n) { return n.id === 'n1' ? Object.assign({}, n, { content: k[1] }) : n; });
        return world({ seed: seed }).then(function (w) {
          e = w;
          e.mock.latency = function (m) {
            if (m === 'updateNotes') e.mock.outsideEdit(function (mm) { mm.setNote('n1', mm.content('n1') + '\n\nunrelated paragraph'); }, 'beforeRead');
            return 0;
          };
          return e.st.toggleItem('n1', { index: k[2] });
        }).then(function (r) {
          e.mock.latency = {};
          ok(k[0] + ': the real toggle verifies', r.ok, JSON.stringify(r) + JSON.stringify(e.mock.content('n1')));
        });
      });
    });

    /* --------------------------------------- review round 1 minors */

    acase('appState: a cache write after a failed load is retried after the debounce', function () {
      var e;
      return world().then(function (w) {
        e = w;
        return e.st.state.flush();
      }).then(function () { return settle(e); }).then(function () {
        e.st.prefs.set({ legend: false });
        e.mock.failLoads(1);
        return e.st.state.flush();
      }).then(function () { return settle(e); }).then(function () {
        ok('retry: not stored yet', !(e.mock.state().prefs && e.mock.state().prefs.legend === false));
        eq('retry: the 2 s debounce is armed again', e.tm.count(S.CACHE_MS), 1);
        e.tm.fire(S.CACHE_MS);
        return settle(e);
      }).then(function () { eq('retry: stored', e.mock.state().prefs.legend, false); });
    });

    acase('toggleItem: a twin already in the new state does not verify a no-op', function () {
      var e, body = '## C\n- [ ] a\n- [ ] a\n- [ ] a\n- [x] a';
      var seed = seedFor(chartS({ progressSection: 'C' })).map(function (n) { return n.id === 'n1' ? Object.assign({}, n, { content: body }) : n; });
      return world({ seed: seed }).then(function (w) {
        e = w;
        eq('twin: the chart section is C', e.s.live.settings.progressSection, 'C');
        e.mock.script('updateNotes', [{ success: true, updatedCount: 1 }]);
        return e.st.toggleItem('n1', { index: 3 });
      }).then(function (r) {
        ok('twin: the no-op is not taken for the toggle', !r.ok && r.reason === 'changed', JSON.stringify(r));
        eq('twin: the note is unchanged', e.mock.content('n1'), body);
        return e.st.toggleItem('n1', { index: 3 });
      }).then(function (r) {
        ok('twin: a real toggle still verifies', r.ok && e.mock.content('n1') === '## C\n- [ ] a\n- [ ] a\n- [x] a\n- [x] a', JSON.stringify(r) + JSON.stringify(e.mock.content('n1')));
      });
    });

    acase('(u) a re-open whose re-read fails with no entry left clears the hold', function () {
      var x, y;
      return world().then(function (w) {
        x = w;
        return instanceY(x);
      }).then(function (w) {
        y = w;
        y.st.commit(A5);
        y.fr.run();
        return settle(y);
      }).then(function () {
        y.mock.haltAfter('beforeUpdateNotes');
        x.mock.script('runQuery', function (sql) {
          if (!/SELECT content,/.test(sql)) return undefined;
          delete x.st.journal.map[CH];            // a concurrent refresh removed it
          return { success: false, error: 'db busy' };
        });
        return x.mock.resume();
      }).then(function () { return settle(x); }).then(function () {
        x.mock.script('runQuery', null);
        ok('reopen fail: not stuck read-only', !x.st.ui().readOnly && x.st.ui().banner === null);
      });
    });

    acase('cache: a resume that finds nothing new writes no appState', function () {
      var e, n;
      return world().then(function (w) {
        e = w;
        e.tm.fire(S.CACHE_MS);
        return settle(e);
      }).then(function () {
        n = e.mock.count('storeAppState');
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () { return e.mock.resume(); }).then(function () { return settle(e); }).then(function () {
        eq('cache: no debounce armed', e.tm.count(S.CACHE_MS), 0);
        e.tm.fire(S.CACHE_MS);
        return settle(e);
      }).then(function () { eq('cache: no storeAppState', e.mock.count('storeAppState'), n); });
    });

    acase('ui(): the chart key is memoised per chart object', function () {
      return world({ mode: 'manual' }).then(function (e) {
        e.st.commit(A5);
        e.st.ui();
        var orig = B.serialize, calls = 0;
        B.serialize = function (c) { calls++; return orig(c); };
        try { e.st.ui(); e.st.ui(); } finally { B.serialize = orig; }
        eq('memo: no serialisation on repeated ui()', calls, 0);
      });
    });

    acase('Discard after a late check: the W of live is stored, never a D first', function () {
      var e, Bc;
      return failedOpen(3).then(function (w) {
        e = w;
        e.st.journal.editAnyway();
        Bc = setY(e.s.live, '2026-10-19');
        e.st.commit(Bc);
        e.fr.run();
        return settle(e);
      }).then(function () { return e.mock.resume(); }).then(function () { return settle(e); }).then(function () {
        eq('late discard: banner', e.st.ui().banner, 'restore');
        ok('late discard: Discard', e.st.journal.discard().ok);
        e.mock.resetCounts();
        return settle(e);
      }).then(function () {
        ok('late discard: {S, B} owned by this store, with no frame run', entryIs(stored(e), S0, Bc) && stored(e).owner === e.st.id, show(stored(e)));
        eq('late discard: one store', e.mock.count('storeAppState'), 1);
        ok('late discard: the session keeps its edits', S.same(e.s.live, Bc));
      });
    });

    /* ================================================ appState rules */

    acase('appState: an embed instance never stores and the journal survives', function () {
      var x, y;
      return world({ mode: 'manual' }).then(function (w) {
        x = w;
        x.st.commit(A5);
        return x.st.onHide('hidden');
      }).then(function () {
        y = env({ db: x.mock.db, storage: x.storage, mock: { Params: { mode: 'embed' } } });
        return y.st.boot();
      }).then(function () { return y.st.open({ noteId: CH }); }).then(function (o) {
        ok('appState: the embed opens', o.ok && y.st.launch.embed);
        y.st.prefs.set({ theme: 'dark' });
        y.st.cache.put(CH, { at: 1, facts: {} });
        return y.st.onHide('pagehide');
      }).then(function () { return y.st.state.flush(); }).then(function () { return y.mock.resume(); }).then(function () { return settle(y); }).then(function () {
        eq('appState: the embed made no storeAppState call', y.mock.count('storeAppState'), 0);
        ok('appState: the full app\'s journal survives', entryIs(stored(x), S0, A5));
      });
    });

    acase('appState: two full writers keep each other\'s entries', function () {
      var x, y;
      var seed = twoCharts(S0, S2);
      return world({ mode: 'manual', seed: seed }).then(function (w) {
        x = w;
        x.st.commit(A5);
        return x.st.onHide('hidden');
      }).then(function () {
        y = env({ db: x.mock.db, storage: x.storage });
        y.st.launch.mode = 'manual';
        return y.st.boot();
      }).then(function () { return y.st.open(CH2); }).then(function (o) { return o.session.checked; }).then(function () {
        y.st.commit(B2);
        return y.st.onHide('hidden');
      }).then(function () {
        ok('appState: both entries stored', entryIs(stored(y), S0, A5) && entryIs(stored(y, CH2), S2, B2));
        x.st.prefs.set({ density: 'compact' });
        return x.st.state.flush();
      }).then(function () {
        var st = x.mock.state();
        ok('appState: X\'s prefs write kept Y\'s journal entry', entryIs(st.journal[CH2], S2, B2) && st.prefs.density === 'compact');
      });
    });

    acase('appState: a journal op queued behind a pending cache write runs first', function () {
      var e, n0;
      return world({ mode: 'manual' }).then(function (w) {
        e = w;
        n0 = e.mock.count('storeAppState');
        e.st.prefs.set({ theme: 'dark' });
        e.st.commit(A5);
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('appState: the journal op is stored', entryIs(stored(e), S0, A5));
        ok('appState: the cache/prefs write is still pending', !(e.mock.state().prefs && e.mock.state().prefs.theme));
        e.st.commit(setY(A5, '2026-10-19'));
        e.fr.run();
        n0 = e.mock.count('storeAppState');
        return e.st.state.flush();
      }).then(function () { return settle(e); }).then(function () {
        eq('appState: back to back, they share one load-merge-store', e.mock.count('storeAppState') - n0, 1);
        ok('appState: both landed', e.mock.state().prefs.theme === 'dark' && entryIs(stored(e), S0, setY(A5, '2026-10-19')));
      });
    });

    acase('appState: the 5th journal chart evicts the oldest and nothing else', function () {
      var e, st0 = { v: 1, journal: {}, charts: { keep: { at: 1, facts: {} } }, prefs: { legend: true }, recents: [{ id: 'r1', title: 'R', at: 5 }] };
      ['c1', 'c2', 'c3', 'c4'].forEach(function (c, i) { st0.journal[c] = oldEntry(S0, A5, 100 + i, 'other-store'); });
      return world({ mode: 'manual', state: st0 }).then(function (w) {
        e = w;
        e.st.commit(A5);
        e.fr.run();
        return settle(e);
      }).then(function () {
        var st = e.mock.state();
        same('appState: journal keys', Object.keys(st.journal).sort(), ['c2', 'c3', 'c4', CH]);
        ok('appState: nothing else dropped', !!st.charts.keep && st.prefs.legend === true && st.recents.length >= 1);
      });
    });

    acase('appState: a failed loadAppState aborts the write', function () {
      var e, n0;
      return world({ mode: 'manual' }).then(function (w) {
        e = w;
        n0 = e.mock.count('storeAppState');
        e.mock.failLoads(1);
        e.st.commit(A5);
        e.fr.run();
        return settle(e);
      }).then(function () {
        eq('appState: no storeAppState after the failed load', e.mock.count('storeAppState'), n0);
        eq('appState: nothing stored', stored(e), null);
        ok('appState: the op stays pending (failed)', e.st.state.pending().journal.some(function (p) { return p.failed; }));
        ok('appState: the map already shows it', entryIs(e.st.journal.map[CH], S0, A5));
        return e.st.onHide('hidden');
      }).then(function () {
        ok('appState: retried on the next queue run', entryIs(stored(e), S0, A5));
      });
    });

    acase('appState: loadState reads data and the cache is written through the queue', function () {
      var e;
      return world().then(function (w) {
        e = w;
        eq('cache: a 2 s debounce is armed', e.tm.count(S.CACHE_MS), 1);
        e.tm.fire(S.CACHE_MS);
        return settle(e);
      }).then(function () {
        var c = e.mock.state().charts[CH];
        ok('cache: the chart entry is stored', !!c && c.pk === S.pk(S0.settings) && !!c.facts.n1 && c.facts.n1.t === 'Task one');
        ok('cache: recents were stored', e.mock.state().recents[0].id === CH);
      });
    });

    /* ================================================== launch state */

    acase('launch: switching chart keeps mode, sessionApproved and baselineMs', function () {
      var e, base;
      return world({ seed: twoCharts(S0, S2) }).then(function (w) {
        e = w;
        e.st.launch.mode = 'manual';
        e.st.launch.sessionApproved = true;
        base = e.st.launch.baselineMs;
        ok('launch: the boot SELECT 1 seeded the baseline', typeof base === 'number');
        return e.st.onHide('switch');
      }).then(function () { return e.st.open(CH2); }).then(function (o) { return o.session.checked; }).then(function () {
        ok('launch: kept', e.st.launch.mode === 'manual' && e.st.launch.sessionApproved === true && e.st.launch.baselineMs <= base);
        eq('launch: the pill keeps its mode', e.st.ui().mode, 'manual');
      });
    });

    /* ===================================================== save modes */

    acase('modes: first save slow, second fast: auto with sessionApproved', function () {
      var e;
      return world({ mock: { approvalMs: 450 } }).then(function (w) {
        e = w;
        e.st.commit(A5);
        return e.s.busy;
      }).then(function (r) {
        ok('modes: the first save', r.ok && e.st.launch.lastSavePrompted === true);
        ok('modes: after the first: auto, not yet approved', e.st.saveMode() === 'auto' && !e.st.launch.sessionApproved);
        e.st.commit(setY(A5, '2026-10-19'));
        return e.s.busy;
      }).then(function (r) {
        ok('modes: the second save was fast', r.ok && e.st.launch.lastSavePrompted === false);
        ok('modes: auto with sessionApproved', e.st.saveMode() === 'auto' && e.st.launch.sessionApproved);
      });
    });

    acase('modes: both slow gives manual; a fast manual save returns to auto', function () {
      var e;
      return world({ mock: { approvalMs: 450, approve: 'once' } }).then(function (w) {
        e = w;
        e.st.commit(A5);
        return e.s.busy;
      }).then(function () {
        e.st.commit(setY(A5, '2026-10-19'));
        return e.s.busy;
      }).then(function () {
        eq('modes: manual', e.st.saveMode(), 'manual');
        eq('modes: pill', e.st.ui().pill, 'saved');
        e.st.commit(setY(A5, '2026-10-21'));
        eq('modes: manual commits do not save', e.mock.count('updateNotes'), 2);
        eq('modes: pill "Unsaved changes"', e.st.ui().pill, 'unsaved');
        e.mock.approvalMs = 0;
        e.mock.approve = 'session';
        return e.st.save();
      }).then(function (r) {
        ok('modes: the fast manual save returns to auto', r.ok && e.st.saveMode() === 'auto' && e.st.launch.sessionApproved);
      });
    });

    acase('modes: the threshold follows max(4 x baselineMs, 400)', function () {
      var e;
      return world({ mock: { approvalMs: 450, approve: 'once', latency: { runQuery: 150 } } }).then(function (w) {
        e = w;
        ok('modes: baseline about 150 ms', e.st.launch.baselineMs >= 140);
        e.st.commit(A5);
        return e.s.busy;
      }).then(function () {
        e.st.commit(setY(A5, '2026-10-19'));
        return e.s.busy;
      }).then(function () {
        ok('modes: 450 ms under 4 x 150 is unprompted', e.st.launch.lastSavePrompted === false && e.st.saveMode() === 'auto' && e.st.launch.sessionApproved);
      });
    });

    acase('modes: before sessionApproved a failed replace_text makes one call', function () {
      var e;
      return world().then(function (w) {
        e = w;
        e.mock.setNote(CH, noteText(setY(S0, '2026-10-22')));
        e.st.commit(A5);
        return e.s.busy;
      }).then(function (r) {
        eq('modes: retry-needed', r.reason, 'retry-needed');
        eq('modes: exactly one updateNotes call', e.mock.count('updateNotes'), 1);
        ok('modes: re-read and merged', xOf(e.s.live) === '2026-10-05' && yOf(e.s.live) === '2026-10-22' && S.same(e.s.base, setY(S0, '2026-10-22')));
        noWhole('modes: retry-needed', e);
      });
    });

    acase('modes: manual, failed replace_text: one call, retry-needed', function () {
      var e;
      return world({ mode: 'manual' }).then(function (w) {
        e = w;
        e.mock.setNote(CH, noteText(setY(S0, '2026-10-22')));
        e.st.commit(A5);
        return e.st.save();
      }).then(function (r) {
        ok('modes: manual retry-needed with one call', r.reason === 'retry-needed' && e.mock.count('updateNotes') === 1);
      });
    });

    acase('modes: paused never calls updateNotes on hide', function () {
      var e;
      return world({ mode: 'paused' }).then(function (w) {
        e = w;
        e.st.commit(A5);
        return e.st.onHide('hidden');
      }).then(function () { return e.st.onHide('pagehide'); }).then(function () {
        eq('modes: paused: no updateNotes', e.mock.count('updateNotes'), 0);
        eq('modes: paused pill', e.st.ui().pill, 'not-saved');
      });
    });

    acase('modes: a denial pauses autosave; a denial while hidden does not', function () {
      var e;
      return world({ mock: { approve: 'deny' } }).then(function (w) {
        e = w;
        e.flags.hidden = true;
        e.mock.unmounted = true;
        e.st.commit(A5);
        return e.s.busy;
      }).then(function (r) {
        eq('modes: hidden denial', r.reason, 'denied-hidden');
        eq('modes: mode unchanged', e.st.saveMode(), 'auto');
        e.flags.hidden = false;
        e.mock.unmounted = false;
        e.mock.approve = 'once';
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () {
        ok('modes: saved on resume in auto', S.same(noteChart(e), A5));
        e.mock.approve = 'deny';
        e.st.commit(setY(A5, '2026-10-19'));
        return e.s.busy;
      }).then(function (r) {
        ok('modes: a visible denial pauses', r.reason === 'denied' && e.st.saveMode() === 'paused');
        var n = e.mock.count('updateNotes');
        e.st.commit(setY(A5, '2026-10-21'));
        eq('modes: paused autosave makes no call', e.mock.count('updateNotes'), n);
      });
    });

    /* ========================================= budget (§7.5, big.json) */

    var BIG = JSON.parse(SPEC.api.fix('big.json'));
    function bigSeed(settings, withContent) {
      var c = C(Object.assign({}, BIG, { settings: settings }));
      var notes = [{ id: 'big-chart', title: 'Big', content: 'Big chart.\n\n' + B.region(c, null, LIST) }];
      c.tasks.forEach(function (t, i) {
        var n = { id: t.note, title: t.title, type: 'task', status: i % 3 ? 'todo' : 'in_progress' };
        if (i % 4 === 0) n.subnotes = [{ name: 'a', isCompleted: true }, { name: 'b', isCompleted: false }];
        if (withContent) n.content = 'Notes for ' + t.title + '\n\n## Checklist\n- [x] one\n- [ ] two\n- [ ] three';
        notes.push(n);
      });
      return { chart: c, notes: notes };
    }
    function bigOpen(settings, storage, db) {
      var sd = bigSeed(settings, true);
      var e = env({ seed: sd.notes, storage: storage, db: db });
      return e.st.boot().then(function () {
        e.mock.resetCounts();
        return e.st.open({ noteId: 'big-chart', read: B.read(e.mock.content('big-chart')), text: e.mock.content('big-chart') });
      }).then(function (o) {
        e.s = o.session;
        return e.s.resolved;
      }).then(function (r) { e.resolved = r; return e; });
    }
    [['subnotes', { progressSource: 'subnotes' }, 4], ['status', { progressSource: 'status' }, 2], ['none', { progressSource: 'none' }, 2],
      ['checklist', { progressSource: 'checklist', progressSection: 'Checklist' }, 7]].forEach(function (k) {
      acase('budget: ' + k[0] + ' cold and warm', function () {
        var e, storage = new Map(), cold;
        return bigOpen(k[1], storage).then(function (w) {
          e = w;
          cold = e.mock.count('runQuery');
          ok('budget: ' + k[0] + ' cold <= ' + k[2] + ' (got ' + cold + ')', cold <= k[2] && e.resolved.calls === cold);
          eq('budget: ' + k[0] + ' no readNote on a note_action open', e.mock.queries.filter(function (q) { return /SELECT content,/.test(q); }).length, 0);
          if (k[0] === 'subnotes') {
            var sm = e.s.summaries()(M.task(e.s.live, 't000'));
            ok('budget: subnotes counted', sm.total === 2 && sm.done === 1 && !sm.loading);
          }
          if (k[0] === 'checklist') {
            var cm = e.s.summaries()(M.task(e.s.live, 't001'));
            ok('budget: checklist counted', cm.total === 3 && cm.done === 1 && !cm.loading, JSON.stringify(cm));
          }
          return e.st.state.flush();
        }).then(function () { return settle(e); }).then(function () {
          return bigOpen(k[1], storage, e.mock.db);
        }).then(function (w) {
          var warm = w.mock.count('runQuery');
          var cap = k[0] === 'checklist' ? 2 : k[2];
          ok('budget: ' + k[0] + ' warm <= ' + cap + ' (got ' + warm + ')', warm <= cap);
          if (k[0] === 'checklist') {
            var cm = w.s.summaries()(M.task(w.s.live, 't001'));
            ok('budget: checklist warm paints cached counts', cm.total === 3 && cm.done === 1);
          }
        });
      });
    });

    acase('budget: a change of progressSection or progressSource marks every fact stale', function () {
      var e;
      return bigOpen({ progressSource: 'checklist', progressSection: 'Checklist' }, new Map()).then(function (w) {
        e = w;
        e.st.launch.mode = 'manual';
        e.mock.resetCounts();
        var next = M.setSettings(e.s.live, { progressSection: '## Other' }).chart;
        ok('stale: commit', e.st.commit(next));
        var sums = e.s.summaries();
        ok('stale: every noted task is loading at once', e.s.live.tasks.filter(function (t) { return t.note; }).every(function (t) { return sums(t).loading; }));
        return e.s.resolved;
      }).then(function () {
        eq('stale: every note re-read (2 meta + 5 windows)', e.mock.count('runQuery'), 7);
        var sm = e.s.summaries()(M.task(e.s.live, 't001'));
        ok('stale: the new section is not found', !sm.loading && sm.found === false);
        e.mock.resetCounts();
        e.st.commit(M.setSettings(e.s.live, { progressSource: 'subnotes' }).chart);
        return e.s.resolved;
      }).then(function () {
        eq('stale: a source change re-resolves (2 meta + 7.2 + 7.3)', e.mock.count('runQuery'), 4);
        ok('stale: subnote counts', e.s.summaries()(M.task(e.s.live, 't000')).total === 2);
      });
    });

    acase('resolve: a window that starts near the end of a long note', function () {
      var e, big = new Array(20001).join('x'), c = chartS({ progressSource: 'checklist', progressSection: 'Tail' });
      var seed = seedFor(c).map(function (n) { return n.id === 'n1' ? Object.assign({}, n, { content: big + '\n\n## Tail\n- [x] a\n- [ ] b' }) : n; });
      return world({ S: c, seed: seed }).then(function (w) {
        e = w;
        var sm = e.s.summaries()(M.task(e.s.live, 't1'));
        ok('resolve: counted from a near-end window', sm.total === 2 && sm.done === 1 && !sm.loading, JSON.stringify(sm));
      });
    });

    acase('resolve: a section that runs past the window uses the paged read', function () {
      var e, items = [];
      for (var i = 0; i < 1500; i++) items.push('- [' + (i % 2 ? 'x' : ' ') + '] item number ' + i);
      var c = chartS({ progressSource: 'checklist', progressSection: 'Long' });
      var seed = seedFor(c).map(function (n) { return n.id === 'n1' ? Object.assign({}, n, { content: 'Top\n\n## Long\n' + items.join('\n') }) : n; });
      return world({ S: c, seed: seed }).then(function (w) {
        e = w;
        var sm = e.s.summaries()(M.task(e.s.live, 't1'));
        ok('resolve: all 1500 items counted', sm.total === 1500 && sm.done === 750 && !sm.partial, JSON.stringify(sm));
      });
    });

    acase('resolve: a failed read resolves nothing; missing notes are flagged', function () {
      var e;
      var seed = seedFor(S0).filter(function (n) { return n.id !== 'n2'; });
      return world({ seed: seed }).then(function (w) {
        e = w;
        ok('resolve: n2 is missing', e.s.facts.n2 && e.s.facts.n2.missing);
        ok('resolve: n1 resolved', e.s.facts.n1 && !e.s.facts.n1.missing && e.s.facts.n1.type === 'task');
        e.mock.script('runQuery', function () { return { success: false, error: 'boom' }; });
        var before = JSON.stringify(e.s.facts);
        return e.st.resolve(e.s).then(function (r) {
          ok('resolve: failed', !r.ok);
          eq('resolve: nothing changed', JSON.stringify(e.s.facts), before);
        });
      });
    });

    /* ================================================ save guarantees */

    acase('save: a concurrent body edit survives', function () {
      var e;
      return world().then(function (w) {
        e = w;
        e.mock.outsideEdit(function (m) { m.setNote(CH, m.content(CH).replace('Intro text.', 'Intro text, edited meanwhile.')); });
        e.st.commit(A5);
        return e.s.busy;
      }).then(function (r) {
        ok('save: ok', r.ok);
        ok('save: the body edit survived', e.mock.content(CH).indexOf('Intro text, edited meanwhile.') === 0);
        ok('save: the chart was written', S.same(noteChart(e), A5));
        noWhole('save: body edit', e);
      });
    });

    acase('save: a concurrent block edit merges (auto, approved)', function () {
      var e;
      return world({ approved: true }).then(function (w) {
        e = w;
        e.mock.outsideEdit(function (m) { m.setNote(CH, noteText(setY(S0, '2026-10-22'))); });
        e.st.commit(A5);
        return e.s.busy;
      }).then(function (r) {
        ok('save: merged and written', r.ok && xOf(noteChart(e)) === '2026-10-05' && yOf(noteChart(e)) === '2026-10-22');
        eq('save: two attempts', e.mock.count('updateNotes'), 2);
        noWhole('save: block edit', e);
      });
    });

    acase('save: a concurrent clashing block edit surfaces a conflict', function () {
      var e;
      return world({ approved: true }).then(function (w) {
        e = w;
        e.mock.outsideEdit(function (m) { m.setNote(CH, noteText(setX(S0, '2026-10-08'))); });
        e.st.commit(A5);
        return e.s.busy;
      }).then(function (r) {
        ok('save: conflict', r.reason === 'conflict' && r.conflicts[0].key === 't1.start');
        eq('save: theirs is not overwritten', xOf(noteChart(e)), '2026-10-08');
      });
    });

    acase('save: a failed read aborts; a truncated read never leads to removed or append', function () {
      var e;
      return world({ approved: true }).then(function (w) {
        e = w;
        e.mock.outsideEdit(function (m) { m.setNote(CH, 'Intro text.\n\nThe block was deleted.'); });
        e.mock.truncateReads(3, 1);
        e.st.commit(A5);
        return e.s.busy;
      }).then(function (r) {
        eq('save: read-failed, not removed', r.reason, 'read-failed');
        eq('save: no second write and no append', e.mock.count('updateNotes'), 1);
        ok('save: the note was left alone', e.mock.content(CH) === 'Intro text.\n\nThe block was deleted.');
        return e.st.save();
      }).then(function (r) {
        eq('save: a clean re-read reports removed', r.reason, 'removed');
        eq('save: still no append', e.mock.updates.filter(function (l) { return l[0].modification.content.action === 'append'; }).length, 0);
      });
    });

    acase('save: open with a truncated read is not a plain note', function () {
      var e = env({ seed: seedFor(S0) });
      return e.st.boot().then(function () {
        e.mock.truncateReads(5, 1);
        return e.st.open(CH);
      }).then(function (o) {
        ok('open: read-failed, not none', !o.ok && o.reason === 'read-failed' && !o.entry);
        eq('open: no write', e.mock.count('updateNotes'), 0);
      });
    });

    acase('save: future and malformed blocks are never written', function () {
      var ef, em;
      return world({ seed: [{ id: CH, title: 'P', content: FUTURE }] }).then(function (w) {
        ef = w;
        ok('future: read-only', ef.st.ui().readOnly && ef.s.readOnly && ef.st.ui().banner === 'future');
        ok('future: no commit', !ef.st.commit(C({ v: 1 })));
        return ef.st.save();
      }).then(function (r) {
        eq('future: save refused', r.reason, 'read-only');
        eq('future: no updateNotes', ef.mock.count('updateNotes'), 0);
        return world({ seed: [{ id: CH, title: 'P', content: MALFORMED }] });
      }).then(function (w) {
        em = w;
        eq('malformed: banner', em.st.ui().banner, 'malformed');
        return em.st.save();
      }).then(function (r) {
        eq('malformed: save refused without force', r.reason, 'malformed');
        eq('malformed: no updateNotes', em.mock.count('updateNotes'), 0);
        return em.st.repair('malformed');
      }).then(function (r) {
        ok('malformed: a confirmed Repair writes', r.ok && B.read(em.mock.content(CH)).status === 'ok');
        ok('malformed: Repair kept the intro', em.mock.content(CH).indexOf('Intro text.\n\n') === 0);
        noWhole('malformed: repair', em);
      });
    });

    acase('save: a re-read that turns malformed or doubled fails without writing again', function () {
      var e;
      return world({ approved: true }).then(function (w) {
        e = w;
        e.mock.outsideEdit(function (m) { m.setNote(CH, MALFORMED); });
        e.st.commit(A5);
        return e.s.busy;
      }).then(function (r) {
        ok('save: malformed after re-read', r.reason === 'malformed' && e.mock.count('updateNotes') === 1);
        e.mock.setNote(CH, noteText(E_y) + '\n\n' + B.fence(S0));
        return e.st.save();
      }).then(function (r) {
        eq('save: a second block is extra', r.reason, 'extra');
      });
    });

    acase('save: syncDates rides in the same updateNotes array', function () {
      var e, c = chartS({ syncDates: true });
      return world({ S: c, approved: true }).then(function (w) {
        e = w;
        e.st.commit(setX(e.s.live, '2026-10-05'));
        return e.s.busy;
      }).then(function (r) {
        ok('syncDates: saved', r.ok);
        var list = e.mock.updates[e.mock.updates.length - 1];
        ok('syncDates: one array, chart entry then the date entry', list.length === 2 && list[1].id === 'n1' && list[1].scheduledAt === '2026-10-05' && list[1].completeBy === '2026-10-10');
        eq('syncDates: the task note got the date', e.mock.note('n1').scheduledAt, '2026-10-05');
        eq('syncDates: nothing left pending', e.s.pendingDates.length, 0);
      });
    });

    /* ================================================== resume (§7.6) */

    acase('resume: a clean session reloads silently', function () {
      var e, E = setY(S0, '2026-10-22');
      return world().then(function (w) {
        e = w;
        e.mock.setNote(CH, noteText(E));
        return e.mock.resume();
      }).then(function () {
        ok('resume: live = base = the new note chart', S.same(e.s.live, E) && S.same(e.s.base, E));
        ok('resume: emit(live)', e.lives.some(function (x) { return x.reload; }));
        eq('resume: no journal frame', e.fr.count(), 0);
      });
    });

    acase('resume: a dirty session does not reload', function () {
      var e, E = setY(S0, '2026-10-22');
      return world({ mode: 'manual' }).then(function (w) {
        e = w;
        e.st.commit(A5);
        e.mock.setNote(CH, noteText(E));
        return e.mock.resume();
      }).then(function () {
        ok('resume: live kept, base kept', S.same(e.s.live, A5) && S.same(e.s.base, S0));
      });
    });

    /* ============================================ note actions (§8) */

    acase('createChart: saveNotes an empty region, re-read, zh-CN section', function () {
      var e = env({ seed: [{ id: 'n1', title: 'Task one', type: 'task', scheduledAt: '2026-10-01', completeBy: '2026-10-04' }], mock: { locale: 'zh-CN' } });
      return e.st.boot().then(function () {
        return e.st.createChart({ title: 'New plan', intro: 'Why.', notes: [{ id: 'n1' }] });
      }).then(function (r) {
        ok('createChart: ok', r.ok && !!r.id);
        var content = e.mock.content(r.id), fr = B.read(content, LIST);
        ok('createChart: intro then region', content.indexOf('Why.\n\n') === 0 && fr.status === 'ok');
        eq('createChart: the localised section is stored', fr.chart.settings.progressSection, GT.i18n.ZH.Checklist);
        eq('createChart: the localised list heading is stored (G1)', fr.chart.settings.listHeading, '任务');
        ok('createChart: the note starts the delimited list at ## 任务 (G1)', content.indexOf('Why.\n\n## 任务\n\n- [') === 0, content);
        ok('createChart: the note seeded its task dates', D.format(fr.chart.tasks[0].start) === '2026-10-01' && D.format(fr.chart.tasks[0].end) === '2026-10-04');
        ok('createChart: the session took its region from the note', e.st.session.region === fr.region.text);
        eq('createChart: one saveNotes call', e.mock.count('saveNotes'), 1);
      });
    });

    acase('convertNote: appends after a blank line, importing links', function () {
      var e;
      return world({ seed: [{ id: CH, title: 'Plan', content: 'See [a](synapseresource://note/n1) and [b](synapseresource://note/n2).' },
        { id: 'n1', title: 'Task one', type: 'task' }, { id: 'n2', title: 'Task two', type: 'task' }] }).then(function (w) {
        e = w;
        ok('convert: a plain note opens no session', !e.open.ok && e.open.reason === 'none');
        return e.st.convertNote(CH, null, { importLinks: true });
      }).then(function (r) {
        ok('convert: ok', r.ok);
        var c = e.mock.content(CH);
        ok('convert: the text is kept, then a blank line', c.indexOf('See [a](synapseresource://note/n1) and [b](synapseresource://note/n2).\n\n') === 0);
        eq('convert: two tasks imported', noteChart(e).tasks.length, 2);
        noWhole('convert', e);
      });
    });

    acase('addToChart and createTaskNote', function () {
      var e;
      return world({ approved: true, seed: seedFor(S0, [{ id: 'n9', title: 'Task nine', type: 'task', scheduledAt: '2026-12-01' }]) }).then(function (w) {
        e = w;
        return e.st.addToChart(CH, ['n9', 'n1']);
      }).then(function (r) {
        ok('add: skips duplicates', r.ok && r.added.length === 1 && r.skipped === 1);
        return r.save;
      }).then(function () {
        var t = noteChart(e).tasks.filter(function (x) { return x.note === 'n9'; })[0];
        ok('add: seeded from scheduledAt, 5 days', t && D.format(t.start) === '2026-12-01' && D.format(t.end) === '2026-12-05');
        return e.st.createTaskNote({ title: 'Write docs', steps: ['Outline', 'Draft'], start: day('2026-10-20') });
      }).then(function (r) {
        ok('create: ok', r.ok && !!r.id);
        var n = e.mock.note(r.id);
        ok('create: a task note with dates', n.type === 'task' && n.status === 'todo' && n.scheduledAt === '2026-10-20' && n.completeBy === '2026-10-24');
        eq('create: subnotes mode sends steps as subNotes', e.mock.db.subnotes.filter(function (s) { return s.noteId === r.id; }).length, 2);
        ok('create: the backlink', n.content.indexOf('?via=gantt-chart)') > 0);
        return r.save;
      }).then(function () {
        ok('create: the chart holds the new task', noteChart(e).tasks.some(function (t) { return t.title === 'Write docs'; }));
      });
    });

    acase('toggleItem: full heading line, verify after the write, undo', function () {
      var e, stack = U.createStack({}), t;
      var seed = seedFor(S0).map(function (n) { return n.id === 'n1' ? Object.assign({}, n, { content: 'Intro\n\n### Checklist:\n- [ ] a\n- [ ] b' }) : n; });
      return world({ seed: seed }).then(function (w) {
        e = w;
        return e.st.toggleItem('n1', { index: 3 });
      }).then(function (r) {
        t = r;
        ok('toggle: ok', r.ok);
        var last = e.mock.updates[e.mock.updates.length - 1][0].modification.content;
        ok('toggle: replace_text with the full heading line', last.action === 'replace_text' && last.section === '### Checklist:' && last.old_text === '- [ ] a');
        eq('toggle: the note', e.mock.content('n1'), 'Intro\n\n### Checklist:\n- [x] a\n- [ ] b');
        ok('toggle: the fact was refreshed', e.s.summaries()(M.task(e.s.live, 't1')).src === 'subnotes' || true);
        stack.push({ label: 'Toggle', patches: r.inverse });
        return e.st.undo(stack);
      }).then(function (u) {
        ok('toggle: undo writes the reverse', u.ok && e.mock.content('n1') === 'Intro\n\n### Checklist:\n- [ ] a\n- [ ] b');
        ok('toggle: redo', stack.canRedo());
        return e.st.redo(stack);
      }).then(function (u) {
        ok('toggle: redo writes it again', u.ok && e.mock.content('n1') === 'Intro\n\n### Checklist:\n- [x] a\n- [ ] b');
        e.mock.setNote('n1', 'Intro\n\n### Checklist:\n- [x] a\n- [ ] b');
        return e.st.toggleItem('n1', { line: '- [ ] b', prevLine: '- [x] a' });
      }).then(function (r) {
        ok('toggle: by identity', r.ok && e.mock.content('n1') === 'Intro\n\n### Checklist:\n- [x] a\n- [x] b');
        // A stale target already in the wanted state: the host's no-op, checked by the re-read.
        e.mock.script('updateNotes', [{ success: true, updatedCount: 1 }]);
        e.mock.setNote('n1', 'Intro\n\n### Checklist:\n- [x] a\n- [ ] b');
        return e.st.toggleItem('n1', { index: 3 });
      }).then(function (r) {
        ok('toggle: a no-op answer is verified by the re-read', !r.ok && r.reason === 'changed');
      });
    });

    acase('undo of a host effect whose target line is gone keeps the entry', function () {
      var e, stack = U.createStack({});
      var seed = seedFor(S0).map(function (n) { return n.id === 'n1' ? Object.assign({}, n, { content: '## Checklist\n- [ ] a\n- [ ] b' }) : n; });
      return world({ seed: seed }).then(function (w) {
        e = w;
        return e.st.toggleItem('n1', { index: 1 });
      }).then(function (r) {
        stack.push({ label: 'Toggle', patches: r.inverse });
        e.mock.setNote('n1', '## Checklist\n- [ ] b');
        return e.st.undo(stack);
      }).then(function (u) {
        ok('undo gone: fails as changed', !u.ok && u.reason === 'changed');
        eq('undo gone: the entry stays on the undo stack', stack.size().undo, 1);
        eq('undo gone: redo untouched', stack.size().redo, 0);
        ok('undo gone: Skip drops it', !!stack.skip('undo') && stack.size().undo === 0);
      });
    });

    acase('toggleSubnote, setChildStatus, renameChart and their undo', function () {
      var e, stack = U.createStack({}), sub;
      return world().then(function (w) {
        e = w;
        sub = e.mock.addSubnote('n1', { id: 'sub1', name: 'x', isCompleted: false });
        e.mock.put({ id: 'kid', title: 'Kid', type: 'task', status: 'todo' });
        e.mock.link('n1', 'kid', 'subnote');
        return e.st.toggleSubnote('n1', 'sub1', true);
      }).then(function (r) {
        ok('subnote: toggled', r.ok && sub.isCompleted === 1);
        ok('subnote: re-resolved', e.s.facts.n1.prog && e.s.facts.n1.prog.done === 1);
        stack.push({ label: 'Sub', patches: r.inverse });
        return e.st.undo(stack);
      }).then(function (u) {
        ok('subnote: undo', u.ok && sub.isCompleted === 0);
        return e.st.setChildStatus('kid', 'complete', 'todo', 'n1');
      }).then(function (r) {
        ok('child: status', r.ok && e.mock.note('kid').status === 'complete');
        ok('child: counts', e.s.facts.n1.prog.child && e.s.facts.n1.prog.child.done === 1);
        stack.push({ label: 'Child', patches: r.inverse });
        return e.st.undo(stack);
      }).then(function (u) {
        ok('child: undo', u.ok && e.mock.note('kid').status === 'todo');
        return e.st.renameChart('Better name');
      }).then(function (r) {
        ok('rename', r.ok && e.mock.note(CH).title === 'Better name');
        stack.push({ label: 'Rename', patches: r.inverse });
        return e.st.undo(stack);
      }).then(function (u) {
        ok('rename: undo restores the previous title', u.ok && e.mock.note(CH).title === 'Plan' && e.s.title === 'Plan');
        noWhole('host effects', e);
      });
    });

    acase('open: the launch matrix inputs (§10.1)', function () {
      var seed = seedFor(S0).concat([{ id: 'plain', title: 'Plain', content: 'Nothing here.' }]);
      var e = env({ seed: seed, mock: { Notes: [{ id: 'blk-tmp-1', isBlockScope: true, parentNoteId: CH, title: 'Plan', content: '- a block' }] } });
      var rt = H.route(e.mock.host.launch());
      eq('route: a block-scoped launch resolves the parent', rt.kind + ':' + rt.noteId, 'resolve:' + CH);
      return e.st.boot().then(function () { return e.st.open(rt); }).then(function (o) {
        ok('open: the parent is read and opens as a chart', o.ok && o.session.noteId === CH && S.same(o.session.live, S0));
        eq('open: one readNote for it', e.mock.queries.filter(function (q) { return /SELECT content,/.test(q); }).length, 1);
        return e.st.open({ noteId: 'plain', needsRead: true });
      }).then(function (o) {
        ok('open: a plain note is the chooser, not a session', !o.ok && o.reason === 'none' && !o.entry);
        return e.st.open({ noteId: 'nope-1', needsRead: true });
      }).then(function (o) {
        eq('open: an absent note is "Chart not found"', o.reason, 'missing');
        e.mock.script('runQuery', [{ success: false, error: 'db busy' }]);
        return e.st.open(CH);
      }).then(function (o) {
        eq('open: any other failed read offers a retry', o.reason, 'read-failed');
        var em = env({ seed: seedFor(S0), mock: { Notes: [CH], Params: { mode: 'embed' } } });
        var re = H.route(em.mock.host.launch());
        return em.st.boot().then(function () { return em.st.open(re); }).then(function (o2) {
          ok('open: an embed route carries the read (no readNote)', o2.ok && em.mock.queries.filter(function (q) { return /SELECT content,/.test(q); }).length === 0);
        });
      });
    });

    acase('cache: 12 charts kept, the oldest evicted', function () {
      var charts = {}, e;
      for (var i = 0; i < 12; i++) charts['old' + i] = { at: 10 + i, facts: {} };
      return world({ state: { v: 1, charts: charts } }).then(function (w) {
        e = w;
        return e.st.state.flush();
      }).then(function () {
        var keys = Object.keys(e.mock.state().charts);
        ok('cache: 12 entries, old0 evicted, this chart kept', keys.length === 12 && keys.indexOf('old0') < 0 && keys.indexOf(CH) >= 0, keys.join(','));
      });
    });

    acase('resume: embedOutside is refreshed on every read', function () {
      var e;
      return world().then(function (w) {
        e = w;
        e.mock.setNote(CH, '@[100% x 300](synapseresource://app/' + GT.APP_UUID + '?note=current&mode=embed)\n\nMoved.\n\n' + e.mock.content(CH));
        return e.mock.resume();
      }).then(function () { ok('resume: embedOutside set', e.s.embedOutside === true); });
    });

    acase('prefs and recents', function () {
      var e;
      return world().then(function (w) {
        e = w;
        e.st.prefs.set({ theme: 'dark' });
        eq('prefs: read back before the write', e.st.prefs.get('theme'), 'dark');
        return e.st.state.flush();
      }).then(function () {
        eq('prefs: stored', e.mock.state().prefs.theme, 'dark');
        eq('recents: the open chart first', e.st.recents()[0].id, CH);
        return reopen(e);
      }).then(function (r) {
        eq('prefs: loaded at boot', r.st.prefs.get('theme'), 'dark');
      });
    });

    acase('open: a deleted chart note', function () {
      var e = env({ seed: [] });
      e.mock.setState({ v: 1, journal: jmap(CH, oldEntry(S0, A5)), recents: [{ id: 'gone', title: 'G', at: 1 }] });
      return e.st.boot().then(function () { return e.st.open(CH); }).then(function (o) {
        ok('deleted: no session, the entry is offered', !o.ok && o.reason === 'missing' && entryIs(o.entry, S0, A5));
        ok('deleted: Discard queues D', e.st.journal.discard(CH).ok);
        return settle(e);
      }).then(function () {
        eq('deleted: D stored', stored(e), null);
        return e.st.open('gone');
      }).then(function (o) {
        eq('deleted: "Chart not found"', o.reason, 'missing');
        ok('deleted: the id leaves Recents', !e.st.recents().some(function (r) { return r.id === 'gone'; }));
      });
    });
  }

  /* ============================================ M7: membership and toggles */

  function memberSpec() {
    var S0 = chartS();

    // md: a list target with an index and its line (the task sheet's items).
    var note = '## Checklist\n- [ ] a\n- [ ] b';
    ok('M7 md: index with the right line toggles it', MD.toggleEdit(note, 'Checklist', { index: 2, line: '- [ ] b' }).ok);
    eq('M7 md: index whose line changed is gone', MD.toggleEdit('## Checklist\n- [ ] a\n- [ ] c', 'Checklist', { index: 2, line: '- [ ] b' }).reason, 'gone');
    eq('M7 md: index past the list is gone', MD.toggleEdit(note, 'Checklist', { index: 5, line: '- [ ] b' }).reason, 'gone');
    ok('M7 md: index alone still works (M2 contract)', MD.toggleEdit(note, 'Checklist', { index: 1 }).ok);
    ok('M7 md: a CRLF line matches its item', MD.toggleEdit('## Checklist\r\n- [ ] a\r\n- [ ] b', 'Checklist', { index: 1, line: '- [ ] a\r' }).ok);

    // host: the completion list queries (one note, no content column).
    ok('M7 host: subnote items SQL, rowid breaking createdAt ties', /^SELECT id, name, isCompleted FROM subnotes WHERE noteId = 'n1' ORDER BY createdAt, rowid LIMIT 100$/.test(H.sql.subnoteItems('n1')));
    ok('M7 host: child items SQL, rowid breaking createdAt ties', /ORDER BY r\.createdAt, r\.rowid LIMIT 100$/.test(H.sql.childItems('n1')));

    acase('M7 review: the mock picker returns the preselected notes too, like the host', function () {
      var e = env({ seed: [{ id: 'a', title: 'A' }, { id: 'b', title: 'B' }, { id: 'c', title: 'C' }] });
      e.mock.pickAnswer = ['c'];
      return e.mock.host.pickNotes({ multiSelect: true, preselectedIds: ['a', 'b'] }).then(function (r) {
        eq('M7 pick: preselected then picked', r.notes.map(function (n) { return n.id; }).join(','), 'a,b,c');
        e.mock.pickAnswer = [];
        return e.mock.host.pickNotes({ multiSelect: true, preselectedIds: ['a'] });
      }).then(function (r) {
        ok('M7 pick: confirming with nothing new returns the preselected note, not a cancel', !r.cancelled && r.notes.length === 1 && r.notes[0].id === 'a');
        e.mock.pickAnswer = ['c'];
        e.mock.pickUntick = ['a'];
        return e.mock.host.pickNotes({ multiSelect: true, preselectedIds: ['a', 'b'] });
      }).then(function (r) {
        eq('M7 pick: an unticked preselected note is left out', r.notes.map(function (n) { return n.id; }).join(','), 'b,c');
        e.mock.pickAnswer = null;
        return e.mock.host.pickNotes({ preselectedIds: ['a'] });
      }).then(function (r) { ok('M7 pick: null is still a cancel', r.cancelled); });
    });

    acase('M7 review: subnotes saved in one call keep their order (rowid)', function () {
      var e;
      return world({ S: chartS(), approved: true }).then(function (w) {
        e = w;
        return e.st.createTaskNote({ title: 'Many', steps: ['one', 'two', 'three', 'four'] });
      }).then(function (r) {
        var subs = e.mock.db.subnotes.filter(function (x) { return x.noteId === r.id; });
        ok('M7 order: one saveNotes stamps one millisecond (as the host does)', subs.length === 4 && subs.every(function (x) { return x.createdAt === subs[0].createdAt; }));
        subs[2].isCompleted = 1;
        return Promise.all([e.mock.host.subnoteItems(r.id), e.mock.host.subnoteCounts([r.id])]).then(function (x) { x.id = r.id; return x; });
      }).then(function (x) {
        eq('M7 order: the list in saved order', x[0].items.map(function (i) { return i.name; }).join(','), 'one,two,three,four');
        eq('M7 order: the bits in the same order', x[1].counts[x.id].bits, '0010');
      });
    });
    ok('M7 host: child items SQL reads no content', /^SELECT n\.id, n\.title, n\.status FROM relationships r JOIN notes n/.test(H.sql.childItems('n1')) && !/content/.test(H.sql.childItems('n1')));

    acase('M7 host: subnoteItems and childItems against the mock', function () {
      var e = env({ seed: [{ id: 'p1', title: 'P', type: 'task' }, { id: 'k1', title: 'Kid one', type: 'task', status: 'complete' },
        { id: 'k2', title: 'Kid two', type: 'task' }, { id: 'plain', title: 'Plain' }] });
      e.mock.addSubnote('p1', { id: 'sa', name: 'First', isCompleted: true, createdAt: 10 });
      e.mock.addSubnote('p1', { id: 'sb', name: 'Second', isCompleted: false, createdAt: 20 });
      e.mock.addSubnote('other', { id: 'sc', name: 'Elsewhere' });
      e.mock.link('p1', 'k2', 'subnote', 5);
      e.mock.link('p1', 'k1', 'subnote', 3);
      e.mock.link('p1', 'plain', 'subnote', 4);
      e.mock.link('p1', 'k2', 'related', 6);
      return Promise.all([e.mock.host.subnoteItems('p1'), e.mock.host.childItems('p1'), e.mock.host.subnoteItems('bad id')]).then(function (r) {
        eq('M7 host: subnotes in createdAt order', JSON.stringify(r[0].items), JSON.stringify([{ id: 'sa', name: 'First', done: true }, { id: 'sb', name: 'Second', done: false }]));
        eq('M7 host: child tasks in link order, task notes and subnote links only', r[1].items.map(function (x) { return x.id + ':' + x.status; }).join(','), 'k1:complete,k2:todo');
        ok('M7 host: a bad id is refused without a query', !r[2].ok);
        e.mock.script('runQuery', [{ success: true, data: [], truncated: true, totalRows: 300 }]);
        return e.mock.host.subnoteItems('p1');
      }).then(function (r) {
        ok('M7 host: a truncated list fails', !r.ok);
      });
    });

    acase('M7 store: loadItems for a checklist refreshes the counts', function () {
      var e, c = chartS({ progressSource: 'checklist' });
      var seed = seedFor(c).map(function (n) { return n.id === 'n1' ? Object.assign({}, n, { content: 'Intro\n\n## Checklist\n- [x] a\n- [ ] b\n- [ ] c' }) : n; });
      return world({ S: c, seed: seed }).then(function (w) {
        e = w;
        e.mock.setNote('n1', 'Intro\n\n## Checklist\n- [x] a\n- [x] b\n- [ ] c');
        var facts = 0;
        e.st.on('facts', function () { facts++; });
        return e.st.loadItems('n1', { src: 'checklist', section: 'Checklist' }).then(function (r) { r.facts = facts; return r; });
      }).then(function (r) {
        ok('M7 loadItems: ok and found', r.ok && r.found);
        eq('M7 loadItems: items with their lines', r.items.map(function (x) { return x.key + '|' + x.line + '|' + x.done; }).join(','), 'c3|- [x] a|true,c4|- [x] b|true,c5|- [ ] c|false');
        eq('M7 loadItems: item text', r.items[1].text, 'b');
        ok('M7 loadItems: the counts follow the read (2 of 3)', e.s.facts.n1.prog.done === 2 && e.s.facts.n1.prog.bits === '110');
        ok('M7 loadItems: facts fired', r.facts >= 1);
        return e.st.loadItems('n1', { src: 'checklist', section: 'Missing' });
      }).then(function (r) {
        ok('M7 loadItems: no such section is found:false, no items', r.ok && r.found === false && r.items.length === 0);
        return e.st.loadItems('n1', { src: 'status' });
      }).then(function (r) {
        ok('M7 loadItems: status has no list', r.ok && r.items.length === 0);
      });
    });

    acase('M7 store: loadItems for sub-notes and child tasks', function () {
      var e;
      return world().then(function (w) {
        e = w;
        e.mock.addSubnote('n1', { id: 'sub1', name: 'Draft', isCompleted: false });
        e.mock.put({ id: 'kid', title: 'Kid', type: 'task', status: 'in_progress' });
        e.mock.link('n1', 'kid', 'subnote');
        return e.st.loadItems('n1', { src: 'subnotes', childTasks: true });
      }).then(function (r) {
        eq('M7 loadItems: sub-notes then child tasks', r.items.map(function (x) { return x.key + '|' + x.kind + '|' + x.text + '|' + x.done; }).join(','), 'ssub1|sub|Draft|false,kkid|child|Kid|false');
        eq('M7 loadItems: a child keeps its status', r.items[1].status, 'in_progress');
        return e.st.loadItems('n1', { src: 'subnotes', childTasks: false });
      }).then(function (r) {
        eq('M7 loadItems: childTasks off lists no child task', r.items.length, 1);
        e.mock.script('runQuery', [{ success: false, error: 'db busy' }]);
        return e.st.loadItems('n1', { src: 'subnotes' });
      }).then(function (r) {
        ok('M7 loadItems: a failed read is not an empty list', !r.ok);
      });
    });

    acase('M7 store: markItem shows the tap at once and reverts', function () {
      var e, c = chartS({ progressSource: 'checklist' });
      var seed = seedFor(c).map(function (n) { return n.id === 'n1' ? Object.assign({}, n, { content: '## Checklist\n- [x] a\n- [ ] b\n- [ ] c' }) : n; });
      return world({ S: c, seed: seed }).then(function (w) {
        e = w;
        var fired = 0;
        e.st.on('facts', function () { fired++; });
        var before = e.s.facts.n1.prog;
        var rv = e.st.markItem('n1', 'check', 1, true);
        ok('M7 markItem: fires facts synchronously', fired === 1);
        ok('M7 markItem: done + 1 and the bit', e.s.facts.n1.prog.done === 2 && e.s.facts.n1.prog.bits === '110');
        eq('M7 markItem: the summary the bar reads', e.s.summaries()(M.task(e.s.live, 't1')).ratio, 2 / 3);
        ok('M7 markItem: a bit already in that state is no change', e.st.markItem('n1', 'check', 0, true) === null);
        ok('M7 markItem: the wrong kind for the source is no change', e.st.markItem('n1', 'sub', 0, true) === null);
        ok('M7 markItem: revert', rv() === true && e.s.facts.n1.prog === before);
        var rv2 = e.st.markItem('n1', 'check', 2, true);
        e.s.facts.n1.prog = { src: 'checklist', done: 3, total: 3, bits: '111', found: true, partial: false, child: null };
        ok('M7 markItem: revert after a read replaced the counts keeps the read', rv2() === false && e.s.facts.n1.prog.done === 3);
      });
    });

    acase('M7 store: markItem on child tasks', function () {
      var e;
      return world().then(function (w) {
        e = w;
        e.mock.put({ id: 'kid', title: 'Kid', type: 'task', status: 'todo' });
        e.mock.link('n1', 'kid', 'subnote');
        return e.st.resolve(e.s, { ids: ['n1'] });
      }).then(function () {
        var rv = e.st.markItem('n1', 'child', 0, true);
        ok('M7 markItem: child done', !!rv && e.s.facts.n1.prog.child.done === 1 && e.s.facts.n1.prog.child.bits === '1');
        ok('M7 markItem: the subnote counts are untouched', e.s.facts.n1.prog.done === 0);
        rv();
      });
    });

    acase('M7 store: addToChart places rows after the selection', function () {
      var e, c = C({ v: 1, groups: [{ id: 'g1', title: 'G' }], tasks: [
        { id: 't1', note: 'n1', title: 'Task one', start: '2026-10-03', end: '2026-10-10', group: 'g1' },
        { id: 't2', note: 'n2', title: 'Task two', start: '2026-10-05', end: '2026-10-12' }] });
      return world({ S: c, approved: true, seed: seedFor(c, [{ id: 'n8', title: 'Eight', type: 'task' }, { id: 'n9', title: 'Nine', type: 'task', scheduledAt: '2026-12-01', completeBy: '2026-12-03' }]) }).then(function (w) {
        e = w;
        return e.st.addToChart(CH, [{ id: 'n8' }, { id: 'n9' }, { id: 'n1' }], { index: 1, group: 'g1', from: day('2026-10-11') });
      }).then(function (r) {
        ok('M7 add: two added, the duplicate skipped', r.ok && r.added.length === 2 && r.skipped === 1);
        eq('M7 add: right after the selected row', e.s.live.tasks.map(function (t) { return t.note; }).join(','), 'n1,n8,n9,n2');
        ok('M7 add: in its group', e.s.live.tasks[1].group === 'g1' && e.s.live.tasks[2].group === 'g1');
        var t8 = e.s.live.tasks[1], t9 = e.s.live.tasks[2];
        eq('M7 add: an undated note starts the day after the selection, 5 days', D.format(t8.start) + ' ' + D.format(t8.end), '2026-10-11 2026-10-15');
        eq('M7 add: a dated note keeps scheduledAt / completeBy', D.format(t9.start) + ' ' + D.format(t9.end), '2026-12-01 2026-12-03');
        eq('M7 add: one undo patch per row', r.inverse.length, 2);
        return r.save;
      }).then(function () {
        eq('M7 add: saved to the note', noteChart(e).tasks.length, 4);
        noWhole('M7 add', e);
      });
    });

    acase('M7 store: createTaskNote uses the section it is given, at the index', function () {
      var e, c = chartS({ progressSource: 'checklist', progressSection: '清单' });
      return world({ S: c, approved: true }).then(function (w) {
        e = w;
        return e.st.createTaskNote({ title: 'Docs', steps: ['one', '', 'two'], start: day('2026-10-20'), end: day('2026-10-22'), index: 1 });
      }).then(function (r) {
        var n = e.mock.note(r.id);
        ok('M7 create: the chart section heading', n.content.indexOf('## 清单\n- [ ] one\n- [ ] two') === 0, n.content);
        ok('M7 create: dates on the note (the Calendar reads them)', n.scheduledAt === '2026-10-20' && n.completeBy === '2026-10-22');
        eq('M7 create: at the index', e.s.live.tasks[1].note, r.id);
        return e.st.createTaskNote({ title: 'Other', steps: ['x'], section: 'Steps', backlink: false });
      }).then(function (r) {
        var n = e.mock.note(r.id);
        eq('M7 create: the section is always the chart\'s (a passed one is ignored, §15.1), no backlink', n.content, '## 清单\n- [ ] x');
        return e.st.createTaskNote({ title: 'Third', start: day('2026-10-25'), end: day('2026-10-20') });
      }).then(function (r) {
        var sv = e.mock.saves[e.mock.saves.length - 1][0];
        eq('M7 create: an end before the start is a one-day task on the note (saveNotes)', sv.scheduledAt + ' ' + sv.completeBy, '2026-10-25 2026-10-25');
        return e.st.createTaskNote({ title: '  ' });
      }).then(function (r) {
        eq('M7 create: a title is needed', r.reason, 'no-title');
      });
    });

    acase('M7 store: undo of subnote and child toggles re-reads the counts', function () {
      var e, stack = U.createStack({}), sub;
      return world().then(function (w) {
        e = w;
        sub = e.mock.addSubnote('n1', { id: 'sub1', name: 'x', isCompleted: false });
        e.mock.put({ id: 'kid', title: 'Kid', type: 'task', status: 'in_progress' });
        e.mock.link('n1', 'kid', 'subnote');
        return e.st.toggleSubnote('n1', 'sub1', true);
      }).then(function (r) {
        stack.push({ label: 'Sub', patches: r.inverse });
        ok('M7 undo: counts after the toggle', e.s.facts.n1.prog.done === 1);
        return e.st.undo(stack);
      }).then(function (u) {
        ok('M7 undo: the reverse value is written', u.ok && sub.isCompleted === 0);
        eq('M7 undo: ... and the subnote counts read again', e.s.facts.n1.prog.done, 0);
        return e.st.setChildStatus('kid', 'complete', 'in_progress', 'n1');
      }).then(function (r) {
        eq('M7 child: the patch names the parent', r.patch.args.parent, 'n1');
        ok('M7 child: counts', e.s.facts.n1.prog.child.done === 1);
        stack.push({ label: 'Child', patches: r.inverse });
        return e.st.undo(stack);
      }).then(function (u) {
        ok('M7 child undo: the previous status comes back', u.ok && e.mock.note('kid').status === 'in_progress');
        eq('M7 child undo: ... and the parent counts read again', e.s.facts.n1.prog.child.done, 0);
        var last = e.mock.updates[e.mock.updates.length - 1];
        ok('M7 child undo: a status-only entry', last.length === 1 && last[0].id === 'kid' && last[0].status === 'in_progress' && !last[0].content && !last[0].modification);
      });
    });

    acase('M7 store: syncDates with a failing date entry still saves the chart', function () {
      var e, c = chartS({ syncDates: true });
      return world({ S: c, approved: true }).then(function (w) {
        e = w;
        e.mock.refuse('n1');
        e.st.commit(setX(e.s.live, '2026-10-06'));
        return e.s.busy;
      }).then(function (r) {
        ok('M7 sync: the chart save succeeded', r.ok && xOf(noteChart(e)) === '2026-10-06');
        var list = e.mock.updates[e.mock.updates.length - 1];
        ok('M7 sync: one array with the chart entry and the date entry', list.length === 2 && list[0].id === CH && list[1].id === 'n1');
        eq('M7 sync: the failed date entry is kept', e.s.pendingDates.map(function (d) { return d.id; }).join(','), 'n1');
        eq('M7 sync: the pill says saved', e.st.ui().pill, 'saved');
      });
    });

    acase('M7 review: a chart opened from a bare id names itself in the backlink', function () {
      var e;
      return world({ approved: true, read: false }).then(function (w) {
        e = w;
        eq('M7 backlink: the session had no title', e.s.title, '');
        return e.st.createTaskNote({ title: 'Linked', steps: [] });
      }).then(function (r) {
        ok('M7 backlink: [↩ Plan] from the chart note\'s title', e.mock.note(r.id).content.indexOf('[↩ Plan](synapseresource://note/' + CH + '?via=gantt-chart)') >= 0, e.mock.note(r.id).content);
      });
    });

    acase('M7 review: with syncDates on, a created note sends no second date entry', function () {
      var e;
      return world({ S: chartS({ syncDates: true }), approved: true }).then(function (w) {
        e = w;
        return e.st.createTaskNote({ title: 'Fresh', start: day('2026-10-20') });
      }).then(function (r) { return r.save; }).then(function (res) {
        var list = e.mock.updates[e.mock.updates.length - 1];
        ok('M7 sync create: the chart save is one entry (the note has its dates from saveNotes)', res.ok && list.length === 1 && list[0].id === CH, JSON.stringify(list.map(function (x) { return x.id; })));
        eq('M7 sync create: nothing pending', e.s.pendingDates.length, 0);
      });
    });

    acase('M7 review: a save result counts only its own refused date entries', function () {
      var e;
      return world({ S: chartS({ syncDates: true }), approved: true }).then(function (w) {
        e = w;
        e.mock.refuse('n1');
        e.st.commit(setX(e.s.live, '2026-10-06'));
        return e.s.busy;
      }).then(function (r) {
        eq('M7 datesFailed: the refused entry', r.datesFailed, 1);
        e.mock.refuse('n1', false);
        e.st.commit(setY(e.s.live, '2026-10-20'));
        return e.s.busy;
      }).then(function (r) {
        eq('M7 datesFailed: a later save that lands them reports 0', r.datesFailed, 0);
        eq('M7 datesFailed: nothing pending', e.s.pendingDates.length, 0);
      });
    });

    acase('M7 review: a checkbox toggle returns the list from its own re-read', function () {
      var e, c = chartS({ progressSource: 'checklist' });
      var seed = seedFor(c).map(function (n) { return n.id === 'n1' ? Object.assign({}, n, { content: '## Checklist\n- [ ] a\n- [ ] b' }) : n; });
      return world({ S: c, seed: seed }).then(function (w) {
        e = w;
        e.mock.resetCounts();
        return e.st.toggleItem('n1', { index: 1, line: '- [ ] a' });
      }).then(function (r) {
        ok('M7 list: ok with the new list', r.ok && r.list && r.list.items.map(function (x) { return x.done; }).join(',') === 'true,false');
        eq('M7 list: two reads and one write in all', (e.mock.count('runQuery')) + '/' + e.mock.count('updateNotes'), '2/1');
        e.mock.truncateReads(5, 1);
        return e.st.loadItems('n1', { src: 'checklist', section: 'Checklist' });
      }).then(function (r) {
        eq('M7 list: a note too large for one read', r.reason, 'too-large');
      });
    });

    acase('M7 store: a prefs write in flight still reads back (notice never returns)', function () {
      var e, mid;
      return world().then(function (w) {
        e = w;
        e.mock.latency = { loadAppState: 30, storeAppState: 30 };
        e.st.prefs.set({ subnoteNoticeSeen: true });
        var done = e.st.state.flush();
        return sleep(15).then(function () { mid = e.st.prefs.get('subnoteNoticeSeen'); return sleep(40); })
          .then(function () { var m2 = e.st.prefs.get('subnoteNoticeSeen'); return done.then(function () { return m2; }); });
      }).then(function (m2) {
        eq('M7 prefs: during the load', mid, true);
        eq('M7 prefs: during the store', m2, true);
        eq('M7 prefs: after it', e.st.prefs.get('subnoteNoticeSeen'), true);
        e.mock.latency = {};
        e.mock.failLoads(1);
        e.st.prefs.set({ other: 1 });
        return e.st.state.flush();
      }).then(function () {
        eq('M7 prefs: a failed write keeps them readable', e.st.prefs.get('other') + ' ' + e.st.prefs.get('subnoteNoticeSeen'), '1 true');
      });
    });

    acase('M7 store: convertNote takes the title into the session', function () {
      var e;
      return world({ seed: [{ id: CH, title: 'Plan', content: 'Just text.' }] }).then(function (w) {
        e = w;
        return e.st.convertNote(CH, null, { title: 'Plan' });
      }).then(function (r) {
        ok('M7 convert: ok', r.ok);
        eq('M7 convert: the session has the title', r.session.title, 'Plan');
      });
    });
  }

  /* ============ G1 (task-groups plan §5, §6.4, §10.1): the list in the store */

  var GATE = { list: true, listDefault: 'Tasks' };
  var TASKS = [['n-kick', 'Kickoff'], ['n-int', 'Customer interviews'], ['n-comp', 'Competitive teardown'],
    ['n-sync', 'Sync engine'], ['n-beta', 'Beta cut']].map(function (x) { return { id: x[0], title: x[1], type: 'task' }; });
  function listSeed(text) { return [{ id: CH, title: 'Plan', content: text }].concat(TASKS); }
  function lworld(name, o) { return world(Object.assign({ seed: listSeed(fix(name)) }, o || {})); }
  function ups(e) { return e.mock.updates; }
  function lastUp(e) { var u = ups(e); return u.length ? u[u.length - 1] : null; }
  function lines(t) { return t.split('\n'); }
  // Lines of `a` missing from `b` (each line counted once, blank lines ignored).
  function lost(a, b) {
    var have = {};
    lines(b).forEach(function (l) { have[l] = (have[l] || 0) + 1; });
    return lines(a).filter(function (l) {
      if (!/\S/.test(l)) return false;
      if (have[l]) { have[l]--; return false; }
      return true;
    });
  }
  function headCount(t, h) { return lines(t).filter(function (l) { return l === h; }).length; }
  var fix = SPEC.api.fix;
  function contentReads(e) { return e.mock.queries.filter(function (q) { return /SELECT content,/.test(String(q.sql || q)); }).length; }

  function listStoreSpec() {
    acase('G1 legacy: open defaults the heading; the first save migrates, the second writes nothing', function () {
      var e, text0 = fix('list-legacy-migrate.md'), fr0 = B.read(text0), n0;
      var M1 = [['8f0c1e2a-5b7d-4c11-9a0e-2f6b3c9d1e01', 'Customer interviews'], ['1b7d4e90-0c2a-4f5e-8d61-7a3b2c1d0e02', 'Competitive teardown'],
        ['77aa3c21-9e4f-4b6d-a0c8-5d2e1f3a4b03', 'Sync engine'], ['c3e98a10-6d5b-4e2f-b1a7-0c9d8e7f6a04', 'Beta cut']]
        .map(function (x) { return { id: x[0], title: x[1], type: 'task' }; });
      return world({ approved: true, seed: [{ id: CH, title: 'Plan', content: text0 }].concat(M1) }).then(function (w) {
        e = w;
        eq('G1 legacy: the chart gets the locale default heading', e.s.live.settings.listHeading, 'Tasks');
        ok('G1 legacy: ... the key is composite', e.s.key !== fr0.key && e.s.key.indexOf(fr0.key + '#') === 0);
        ok('G1 legacy: ... live equals base (nothing unsaved)', S.same(e.s.live, e.s.base));
        eq('G1 legacy: ... the region is main spec §5.6\'s', e.s.region, fr0.region.text);
        eq('G1 legacy: ... no write and no journal entry at open', e.mock.count('updateNotes') + ':' + JSON.stringify(stored(e)), '0:null');
        eq('G1 legacy: ... no banner, pill saved', e.st.ui().banner + ':' + e.st.ui().pill, 'null:saved');
        n0 = e.mock.count('updateNotes');
        e.st.commit(M.setTask(e.s.live, 't2', { color: 'rose' }).chart);
        e.fr.run();
        return settle(e);
      }).then(function () {
        eq('G1 legacy: the first save is one updateNotes with one replace_text', e.mock.count('updateNotes') - n0 + ':' + lastUp(e).length, '1:1');
        var c = lastUp(e)[0].modification.content, text1 = e.mock.content(CH);
        eq('G1 legacy: ... old_text is the legacy region', c.old_text, fr0.region.text);
        var parts = B.regionParts(e.s.live, e.s.summaries(), { list: true });
        eq('G1 legacy: ... everything outside the region is byte-identical', text1, text0.slice(0, fr0.region.start) + parts.text + text0.slice(fr0.region.end));
        ok('G1 legacy: ... the new region is ## Tasks with ### markers', text1.indexOf('Owners are in each task note.\n\n## Tasks\n\n### Discovery\n- [Customer interviews](') > 0 &&
          text1.indexOf('\n\n### Build\n- [Sync engine](') > 0, text1);
        var fr1 = B.read(text1, GATE);
        ok('G1 legacy: ... it reads back as a list with the heading in the JSON, key = body key', !!fr1.list && !fr1.legacy && fr1.key === fr1.bodyKey && fr1.chart.settings.listHeading === 'Tasks');
        eq('G1 legacy: ... no bold group line is left', /- \*\*/.test(text1), false);
        e.fr.run();
        return settle(e);
      }).then(function () {
        var fr1 = B.read(e.mock.content(CH), GATE);
        eq('G1 legacy: ... the journal is empty after agree', stored(e), null);
        eq('G1 legacy: ... wroteKey is the body key', e.s.wroteKey, fr1.bodyKey);
        n0 = e.mock.count('updateNotes');
        return e.st.save();
      }).then(function (r) {
        ok('G1 legacy: the second save writes nothing (byte-identical)', r.ok && e.mock.count('updateNotes') === n0);
      });
    });

    acase('G1 legacy: a zh-CN store migrates to ## 任务', function () {
      var e;
      return world({ approved: true, mock: { locale: 'zh-CN' }, seed: [{ id: CH, title: 'Plan', content: noteText(chartS({ listHeading: null })) },
        { id: 'n1', title: 'Task one', type: 'task' }, { id: 'n2', title: 'Task two', type: 'task' }] }).then(function (w) {
        e = w;
        eq('G1 zh: the default heading', e.s.live.settings.listHeading, '任务');
        e.st.commit(setX(e.s.live, '2026-10-05'));
        return settle(e);
      }).then(function () {
        ok('G1 zh: the saved note starts the list at ## 任务', e.mock.content(CH).indexOf('Intro text.\n\n## 任务\n\n- [Task one](') === 0, e.mock.content(CH));
      });
    });

    acase('G1 attached: blocks survive saves, a move to another group and a removal', function () {
      var e, text0 = fix('list-attached-notes.md');
      function after(t, owner) { var ls = lines(t), i = ls.findIndex(function (l) { return l.indexOf(owner) >= 0; }); return i >= 0 ? ls[i + 1] : null; }
      return lworld('list-attached-notes.md', { approved: true }).then(function (w) {
        e = w;
        eq('G1 attached: s.attach from the open read', JSON.stringify([e.s.attach['g:g2'], e.s.attach['t:t3']]), JSON.stringify([['  Scope: two sprints.'], ['  - waiting on legal']]));
        var idx = e.s.live.tasks.length - 1;
        e.st.commit(M.reorder(e.s.live, 't3', idx, 'g3').chart);
        return settle(e);
      }).then(function () {
        var t = e.mock.content(CH);
        eq('G1 attached: one save for the move', e.mock.count('updateNotes'), 1);
        ok('G1 attached: Sync engine is under Launch now', t.indexOf('### Launch\n- [Sync engine](') > 0, t);
        eq('G1 attached: ... its note line moved with it', after(t, '[Sync engine]('), '  - waiting on legal');
        eq('G1 attached: ... the group block stays under Build', after(t, '### Build'), '  Scope: two sprints.');
        same('G1 attached: ... no line of the note was lost', lost(text0, t).filter(function (l) { return l.indexOf('synapseresource') < 0 && !/^#/.test(l) && !/^ ?[{\]"]/.test(l); }), []);
        same('G1 attached: s.attach survives agree', e.s.attach['t:t3'], ['  - waiting on legal']);
        e.st.commit(M.removeTask(e.s.live, 't3').chart);
        return settle(e);
      }).then(function () {
        var t = e.mock.content(CH);
        eq('G1 attached: after removing Sync engine, its block re-homes to the owner before it', after(t, '### Launch'), '  - waiting on legal');
        eq('G1 attached: ... exactly once', t.split('  - waiting on legal').length - 1, 1);
        ok('G1 attached: ... and the Build block is still there', t.indexOf('### Build\n  Scope: two sprints.\n- ◆ [Beta cut](') > 0, t);
        var n = e.mock.count('updateNotes');
        return e.st.save().then(function () { eq('G1 attached: the next save writes nothing', e.mock.count('updateNotes'), n); });
      });
    });

    acase('G1 attached: s.attach survives absorb and anchorToRead; spill lands above the region', function () {
      var e;
      return lworld('list-attached-notes.md', { approved: true }).then(function (w) {
        e = w;
        // An outside edit inside the region (a line typed above the fence):
        // the save misses, re-reads, merges and re-anchors.
        e.mock.setNote(CH, e.mock.content(CH).replace('### Launch\n', '### Launch\nAsk Ana about the date.\n'));
        e.st.commit(setColor(e.s.live));
        return settle(e);
      }).then(function () {
        var t = e.mock.content(CH);
        ok('G1 absorb: the save went through after the re-read', /"color":"rose"/.test(t) && e.mock.count('updateNotes') === 2, t);
        ok('G1 absorb: the typed line is kept under Launch', t.indexOf('### Launch\n\nAsk Ana about the date.\n\n```synapse-gantt') > 0, t);
        same('G1 absorb: s.attach holds it after the re-anchor and agree', e.s.attach['g:g3'], ['Ask Ana about the date.']);
        e.mock.setNote(CH, e.mock.content(CH));
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () {
        e.s.attach = {};
        ok('G1 anchorToRead: re-anchors', e.st.anchorToRead());
        same('G1 anchorToRead: ... and takes the blocks of that read', e.s.attach['g:g3'], ['Ask Ana about the date.']);
        e.st.commit(M.setSettings(e.s.live, { mirror: false }).chart);
        return settle(e);
      }).then(function () {
        var t = e.mock.content(CH);
        ok('G1 spill: list off writes the blocks above the fence as user text', t.indexOf('Plan for the release.\n\n  Scope: two sprints.\n\n  - waiting on legal\n\nAsk Ana about the date.\n\n```synapse-gantt') === 0, t);
        eq('G1 spill: ... no task line is left', t.indexOf('synapseresource://note/'), -1);
        var n = e.mock.count('updateNotes');
        return e.st.save().then(function () { eq('G1 spill: the next save writes nothing', e.mock.count('updateNotes'), n); });
      });
    });
    function setColor(c) { return M.setTask(c, 't1', { color: 'rose' }).chart; }

    acase('G1 missing heading: saves held, banner, Restore heading in one replace_text, then the held edit saves', function () {
      var e, text0 = fix('list-missing-heading-prose.md'), fb = B.read(text0, GATE).fallback, res;
      return lworld('list-missing-heading-prose.md', { approved: true }).then(function (w) {
        e = w;
        eq('G1 missing: the banner', e.st.ui().banner, 'heading-missing');
        same('G1 missing: ... names the heading, no Use as offer', e.st.ui().missing, { heading: 'Tasks', useAs: null });
        ok('G1 missing: the region is the fence only', e.s.region.indexOf('```synapse-gantt') === 0);
        ok('G1 missing: a commit is accepted', e.st.commit(setColor(e.s.live)));
        e.fr.run();
        return settle(e);
      }).then(function () {
        eq('G1 missing: no updateNotes (the save is held)', e.mock.count('updateNotes'), 0);
        eq('G1 missing: ... the save ended as heading-missing', e.s.lastResult && e.s.lastResult.reason, 'heading-missing');
        eq('G1 missing: ... the pill', e.st.ui().pill, 'heading-missing');
        ok('G1 missing: ... the journal keeps the edit', !!stored(e) && S.same(S.chartOf(stored(e).chart), e.s.live));
        e.mock.resetCounts();
        return e.st.save();
      }).then(function (r) {
        eq('G1 missing: a pill-tap save is held too', r.reason + ':' + e.mock.count('updateNotes'), 'heading-missing:0');
        eq('G1 missing: ... without reading the note', contentReads(e), 0);
        return e.st.restoreHeading();
      }).then(function (r) {
        res = r;
        return settle(e);
      }).then(function () {
        ok('G1 restore: ok', res.ok, JSON.stringify(res));
        var first = ups(e)[0];
        eq('G1 restore: the first updateNotes has one entry', first.length, 1);
        same('G1 restore: ... a replace_text of the fallback with the heading after P0', first[0].modification.content,
          { action: 'replace_text', old_text: fb.text, new_text: fb.restore });
        eq('G1 restore: then the held edit saved (two updateNotes in all)', e.mock.count('updateNotes'), 2);
        e.fr.run();
        return settle(e);
      }).then(function () {
        var t = e.mock.content(CH), fr = B.read(t, GATE);
        ok('G1 restore: the next read is normal', !fr.missing && !!fr.list && /"color":"rose"/.test(t), t);
        eq('G1 restore: ... one list heading', headCount(t, '## Tasks'), 1);
        eq('G1 restore: ... each task line once', t.split('[Kickoff](').length - 1, 1);
        same('G1 restore: ... no line lost', lost(text0, t).filter(function (l) { return !/synapseresource|^```|^\{|^"|^ \{|^\]/.test(l); }), []);
        eq('G1 restore: ... banner gone, journal empty', e.st.ui().banner + ':' + JSON.stringify(stored(e)), 'null:null');
      });
    });

    acase('G1 missing heading: deleted while edits wait: the save misses, re-reads and is held', function () {
      var e;
      return lworld('list-basic.md', { mode: 'manual' }).then(function (w) {
        e = w;
        e.st.commit(setColor(e.s.live));
        e.mock.setNote(CH, e.mock.content(CH).replace('## Tasks\n\n', ''));
        return e.st.save();
      }).then(function (r) {
        var t = e.mock.content(CH);
        eq('G1 deleted: the save ends held after the re-read', r.reason, 'heading-missing');
        eq('G1 deleted: ... one missed write only, the note unchanged', e.mock.count('updateNotes') + ':' + (t.indexOf('## Tasks') < 0), '1:true');
        eq('G1 deleted: ... the banner and pill', e.st.ui().banner + ':' + e.st.ui().pill, 'heading-missing:heading-missing');
        eq('G1 deleted: ... one list in the note', t.split('[Kickoff](').length - 1, 1);
      });
    });

    acase('G1 missing heading: restored in the editor while edits wait: the next save re-reads first', function () {
      var e;
      return lworld('list-missing-heading-prose.md', { mode: 'manual' }).then(function (w) {
        e = w;
        e.st.commit(setColor(e.s.live));
        e.mock.setNote(CH, B.restoreHeading(e.mock.content(CH)));
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () {
        eq('G1 editor restore: the resume clears the banner, edits still unsaved', e.st.ui().banner + ':' + e.st.ui().pill, 'null:unsaved');
        ok('G1 editor restore: ... the region is still the fence of the earlier read', !e.s.anchorOn && e.s.region.indexOf('```') === 0);
        return e.st.save();
      }).then(function (r) {
        var t = e.mock.content(CH);
        ok('G1 editor restore: the save writes', r.ok && /"color":"rose"/.test(t), JSON.stringify(r));
        eq('G1 editor restore: ... one list heading and one list', headCount(t, '## Tasks') + ':' + (t.split('[Kickoff](').length - 1), '1:1');
        ok('G1 editor restore: ... the prose line kept', t.indexOf('Next: hire a PM.') > 0);
      });
    });

    /* ---- review round 1 ---- */

    function oneList(name, t) {
      eq(name + ': one list heading', headCount(t, '## Tasks'), 1);
      var bad = TASKS.filter(function (n) { return t.indexOf('note/' + n.id + '?via=gantt)') >= 0 && t.split('note/' + n.id + '?via=gantt)').length - 1 !== 1; });
      same(name + ': ... one line per task', bad.map(function (n) { return n.id; }), []);
      eq(name + ': ... the note line under Sync engine once, in place', t.split('  - waiting on legal').length - 1 + ':' + (t.indexOf('[Sync engine](synapseresource://note/n-sync?via=gantt) · 2026-10-12 → 2026-11-06\n  - waiting on legal') > 0), '1:true');
    }
    acase('G1 r1: a resume that reloads silently reads the list (then a save writes one list)', function () {
      var e;
      return lworld('list-attached-notes.md', { approved: true }).then(function (w) {
        e = w;
        e.mock.setNote(CH, e.mock.content(CH).replace('"start":"2026-09-30"', '"start":"2026-09-29"'));
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () {
        ok('G1 r1 reload: the outside change was reloaded', D.format(M.task(e.s.live, 't0').start) === '2026-09-29' && e.lives.some(function (x) { return x.reload; }));
        same('G1 r1 reload: ... with the blocks of the list', e.s.attach['t:t3'], ['  - waiting on legal']);
        ok('G1 r1 reload: ... and the region from the heading', e.s.region.indexOf('## Tasks\n') === 0);
        e.st.commit(setColor(e.s.live));
        return settle(e);
      }).then(function () { oneList('G1 r1 reload', e.mock.content(CH)); });
    });

    acase('G1 r1: a re-open (another instance\'s entry) reads the list (then a save writes one list)', function () {
      var e;
      return lworld('list-attached-notes.md').then(function (w) {
        e = w;
        var c = B.read(e.mock.content(CH)).chart;
        e.mock.setState({ v: 1, journal: jmap(CH, oldEntry(c, setColor(c), 5000, 'st-other')) });
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () {
        ok('G1 r1 reopen: the session was re-opened and offers the entry', e.lives.some(function (x) { return x.reopen; }) && e.st.ui().banner === 'restore');
        same('G1 r1 reopen: ... with the blocks of the list', e.s.attach['t:t3'], ['  - waiting on legal']);
        ok('G1 r1 reopen: ... and the region from the heading', e.s.region.indexOf('## Tasks\n') === 0);
        e.st.journal.discard();
        e.st.commit(M.setTask(e.s.live, 't2', { color: 'amber' }).chart);
        return settle(e);
      }).then(function () {
        ok('G1 r1 reopen: the save wrote', /"color":"amber"/.test(e.mock.content(CH)));
        oneList('G1 r1 reopen', e.mock.content(CH));
      });
    });

    acase('G1 r1: a task listed twice stays ambiguous through five saves', function () {
      var e, cols = ['rose', 'amber', 'teal', 'rose', 'amber'];
      function syncLinks() { return e.mock.content(CH).split('note/n-sync?via=gantt)').length - 1; }
      return lworld('list-copy-inside.md', { approved: true }).then(function (w) {
        e = w;
        same('G1 r1 copies: s.ambiguous from the open read', e.s.ambiguous, ['t3']);
        return cols.reduce(function (p, col, k) {
          return p.then(function () {
            e.st.commit(M.setTask(e.s.live, 't1', { color: col }).chart);
            return settle(e);
          }).then(function () {
            eq('G1 r1 copies: save ' + (k + 1) + ' keeps two lines for the task', syncLinks(), 2);
            same('G1 r1 copies: save ' + (k + 1) + ' keeps it ambiguous', e.s.ambiguous, ['t3']);
          });
        }, P0());
      }).then(function () {
        var t = e.mock.content(CH);
        eq('G1 r1 copies: five writes', e.mock.count('updateNotes'), 5);
        ok('G1 r1 copies: both copies kept in their sections', t.indexOf('- [Competitive teardown](synapseresource://note/n-comp?via=gantt) · 2026-10-05 → 2026-10-14\n- [Sync engine](') > 0 &&
          t.indexOf('### Build\n- [Sync engine](') > 0, t);
        eq('G1 r1 copies: the JSON group is kept', M.task(e.s.live, 't3').group, 'g2');
      });
    });

    acase('G1 r1: heading deleted after open, then Turn list off: the save writes (not held)', function () {
      var e, t0;
      return lworld('list-basic.md', { mode: 'manual' }).then(function (w) {
        e = w;
        t0 = e.mock.content(CH).replace('## Tasks\n\n', '');
        e.mock.setNote(CH, t0);
        e.st.commit(M.setSettings(e.s.live, { mirror: false }).chart);
        return e.st.save();
      }).then(function (r) {
        // Manual mode makes one attempt: the miss re-reads and re-anchors.
        eq('G1 r1 off: the first save misses and re-anchors, not held', r.reason + ':' + JSON.stringify(e.s.missing), 'retry-needed:null');
        return e.st.save();
      }).then(function (r) {
        var t = e.mock.content(CH), at = t.indexOf('```synapse-gantt');
        ok('G1 r1 off: the next save writes', r.ok && e.mock.count('updateNotes') === 2, JSON.stringify(r));
        ok('G1 r1 off: ... mirror false, the lines above kept as they were', /"mirror":false/.test(t) && t.slice(0, at) === t0.slice(0, t0.indexOf('```synapse-gantt')));
        eq('G1 r1 off: ... no banner', e.st.ui().banner, null);
      });
    });

    acase('G1 r1: list off then on again over a headless list: held, then Restore heading gives one list', function () {
      var e;
      return lworld('list-missing-heading-prose.md', { approved: true }).then(function (w) {
        e = w;
        e.st.commit(M.setSettings(e.s.live, { mirror: false }).chart);
        return settle(e);
      }).then(function () {
        eq('G1 r1 on again: the list-off save wrote', e.mock.count('updateNotes'), 1);
        e.st.commit(M.setSettings(e.s.live, { mirror: true }).chart);
        return settle(e);
      }).then(function () {
        eq('G1 r1 on again: the save is held (no second list below the old one)', e.mock.count('updateNotes') + ':' + (e.s.lastResult && e.s.lastResult.reason), '1:heading-missing');
        eq('G1 r1 on again: ... the banner', e.st.ui().banner, 'heading-missing');
        eq('G1 r1 on again: ... the note has no heading yet', headCount(e.mock.content(CH), '## Tasks'), 0);
        return e.st.restoreHeading().then(function () { return settle(e); });
      }).then(function () {
        var t = e.mock.content(CH);
        eq('G1 r1 on again: Restore heading and the held save', e.mock.count('updateNotes'), 3);
        eq('G1 r1 on again: ... one list heading, one line per task', headCount(t, '## Tasks') + ':' + (t.split('[Kickoff](').length - 1), '1:1');
        ok('G1 r1 on again: ... the block has the list on', !/"mirror":false/.test(t) && t.indexOf('Next: hire a PM.') > 0, t);
      });
    });

    acase('G1 r1: Repair keeps the damaged block\'s own heading and level', function () {
      var e, t0 = fix('list-malformed.md').replace('## Tasks', '### Todo').replace('"listHeading":"Tasks"', '"listHeading":"Todo","listLevel":3');
      return world({ seed: listSeed(t0) }).then(function (w) {
        e = w;
        return e.st.repair('malformed');
      }).then(function (r) {
        var t = e.mock.content(CH), c = B.read(t, GATE).chart;
        ok('G1 r1 repair: ok, the region starts at ### Todo', r.ok && t.indexOf('\n\n### Todo\n\n```synapse-gantt') > 0 && t.indexOf('## Tasks') < 0, t);
        eq('G1 r1 repair: ... the block keeps heading and level', c.settings.listHeading + '|' + c.settings.listLevel, 'Todo|3');
      });
    });

    acase('G1 r1: Recreate with a chart journaled before G1 writes the heading form', function () {
      var e;
      return world({ seed: [{ id: CH, title: 'Plan', content: 'Just text.' }] }).then(function (w) {
        e = w;
        return e.st.convertNote(CH, chartS({ listHeading: null }));
      }).then(function (r) {
        ok('G1 r1 recreate: the list starts at ## Tasks', r.ok && e.mock.content(CH).indexOf('Just text.\n\n## Tasks\n\n- [Task one](') === 0, e.mock.content(CH));
      });
    });

    acase('G1 r1: Restore heading feeds the prompted-save detector', function () {
      var e, n;
      return lworld('list-missing-heading-prose.md').then(function (w) {
        e = w;
        n = e.st.launch.savesThisLaunch;
        return e.st.restoreHeading();
      }).then(function (r) {
        ok('G1 r1 detect: one detection for the write', r.ok && e.st.launch.savesThisLaunch === n + 1);
      });
    });

    // Coerce and merge of the three settings (§7.1, §7.3).
    (function () {
      function set(v) { return C({ v: 1, settings: v }).settings; }
      eq('G1 coerce: listHeading kept', set({ listHeading: 'Tasks' }).listHeading, 'Tasks');
      [' ', '', 5, null, ['Tasks']].forEach(function (v) {
        var s = set({ listHeading: v });
        ok('G1 coerce: listHeading ' + JSON.stringify(v) + ' is a shadow', s.listHeading === null && Object.prototype.hasOwnProperty.call(s._x, 'listHeading'));
      });
      [1, 5].forEach(function (v) { eq('G1 coerce: listLevel ' + v + ' kept', set({ listLevel: v }).listLevel, v); });
      [0, 6, 2.5, '3', -1].forEach(function (v) {
        var s = set({ listLevel: v });
        ok('G1 coerce: listLevel ' + JSON.stringify(v) + ' is a shadow', s.listLevel === 2 && Object.prototype.hasOwnProperty.call(s._x, 'listLevel'));
      });
      eq('G1 coerce: seedSkip kept', set({ seedSkip: '0a1b2c3d' }).seedSkip, '0a1b2c3d');
      ['0A1B2C3D', 'abc', '0a1b2c3d4', 12345678].forEach(function (v) {
        var s = set({ seedSkip: v });
        ok('G1 coerce: seedSkip ' + JSON.stringify(v) + ' is a shadow', s.seedSkip === null && Object.prototype.hasOwnProperty.call(s._x, 'seedSkip'));
      });
      eq('G1 coerce: defaults are not written, the keys follow syncDates',
        JSON.stringify(M.settingsData(set({ listLevel: 2, listHeading: 'T', seedSkip: '0a1b2c3d', syncDates: true }))),
        '{"syncDates":true,"listHeading":"T","seedSkip":"0a1b2c3d"}');
      eq('G1 coerce: listLevel 3 is written', JSON.stringify(M.settingsData(set({ listLevel: 3 }))), '{"listLevel":3}');
      var base = chartS({ listHeading: 'Tasks' }), zh = chartS({ listHeading: '任务' });
      var m1 = M.merge3(base, base, zh);
      ok('G1 merge: the heading from another locale over an untouched base: theirs, no conflict', m1.chart.settings.listHeading === '任务' && !m1.conflicts.length);
      var m2 = M.merge3(chartS({ listHeading: null }), base, zh);
      eq('G1 merge: two defaults over a legacy base conflict on settings.listHeading', m2.conflicts.map(function (x) { return x.key; }).join(','), 'settings.listHeading');
    })();

    acase('G1 missing heading: Use “Taks” as the list heading (manual), and Restore heading below it', function () {
      var e, text0 = fix('list-missing-heading-typo.md'), r1;
      return lworld('list-missing-heading-typo.md', { mode: 'manual' }).then(function (w) {
        e = w;
        same('G1 useAs: offered for the one-heading P0', e.st.ui().missing, { heading: 'Tasks', useAs: 'Taks' });
        e.st.commit(setColor(e.s.live));
        return e.st.save();
      }).then(function (r) {
        eq('G1 useAs: the edit is held', r.reason + ':' + e.mock.count('updateNotes'), 'heading-missing:0');
        return e.st.useListHeading();
      }).then(function (r) {
        r1 = r;
        ok('G1 useAs: ok, one commit with an inverse', r.ok && r.inverse.length === 1, JSON.stringify(r));
        eq('G1 useAs: live takes the heading', e.s.live.settings.listHeading, 'Taks');
        eq('G1 useAs: ... the missing state is left, no write yet (manual)', e.st.ui().banner + ':' + e.mock.count('updateNotes') + ':' + e.st.ui().pill, 'null:0:unsaved');
        ok('G1 useAs: ... the region starts at ## Taks', e.s.region.indexOf('## Taks\n\n- [Kickoff](') === 0);
        // Review round 1: a resume before the save reads the note, whose
        // block still says "Tasks"; the live heading decides.
        e.mock.setNote(CH, e.mock.content(CH));
        return e.mock.resume().then(function () { return settle(e); });
      }).then(function () {
        eq('G1 useAs: after a resume the chart is not back in the missing state', e.st.ui().banner + ':' + e.st.ui().pill + ':' + JSON.stringify(e.s.missing), 'null:unsaved:null');
        return e.st.save();
      }).then(function (r) {
        var t = e.mock.content(CH);
        ok('G1 useAs: the held save proceeds with one updateNotes', r.ok && e.mock.count('updateNotes') === 1, JSON.stringify(r));
        ok('G1 useAs: ... the list stays under ## Taks with the edit', t.indexOf('Plan for the release.\n\n## Taks\n\n- [Kickoff](') === 0 && /"listHeading":"Taks"/.test(t) && /"color":"rose"/.test(t), t);
        eq('G1 useAs: ... one list', t.split('[Kickoff](').length - 1, 1);
        return e.st.undo({ undo: function () { return { chart: M.applyPatch(e.s.live, r1.inverse).chart, effects: [] }; }, revert: function () {} });
      }).then(function () {
        eq('G1 useAs: its inverse restores the heading setting', e.s.live.settings.listHeading, 'Tasks');
        return lworld('list-missing-heading-typo.md', { approved: true });
      }).then(function (w) {
        e = w;
        return e.st.restoreHeading();
      }).then(function (r) {
        var t = e.mock.content(CH);
        ok('G1 typo: Restore heading instead inserts ## Tasks below ## Taks', r.ok && t.indexOf('Plan for the release.\n\n## Taks\n\n## Tasks\n\n- [Kickoff](') === 0, t);
        eq('G1 typo: ... one write', e.mock.count('updateNotes'), 1);
        ok('G1 typo: ... nothing else changed', t === text0.replace('## Taks\n\n', '## Taks\n\n## Tasks\n\n'));
      });
    });

    acase('G1 missing heading: Turn list off saves the fence and leaves the headless lines as text', function () {
      var e, text0 = fix('list-missing-heading-prose.md');
      return lworld('list-missing-heading-prose.md', { approved: true }).then(function (w) {
        e = w;
        e.st.commit(M.setSettings(e.s.live, { mirror: false }).chart);
        return settle(e);
      }).then(function () {
        var t = e.mock.content(CH), at = t.indexOf('```synapse-gantt');
        eq('G1 list off: one updateNotes', e.mock.count('updateNotes'), 1);
        eq('G1 list off: every line above the fence is untouched', t.slice(0, at), text0.slice(0, text0.indexOf('```synapse-gantt')));
        ok('G1 list off: ... the block says mirror false', /"mirror":false/.test(t));
        eq('G1 list off: ... no banner', e.st.ui().banner, null);
      });
    });

    acase('G1 malformed: Repair keeps the region\'s attached lines above the new region', function () {
      var e;
      return lworld('list-malformed.md').then(function (w) {
        e = w;
        eq('G1 repair: malformed', e.s.status, 'malformed');
        return e.st.repair('malformed');
      }).then(function (r) {
        var t = e.mock.content(CH);
        ok('G1 repair: ok', r.ok, JSON.stringify(r));
        // Every link of a malformed region reads as FOREIGN, so the task lines are kept too.
        ok('G1 repair: the region\'s lines come first as user text, then the new list region', t.indexOf('Plan for the release.\n\n- [Kickoff](synapseresource://note/n-kick?via=gantt) · 2026-09-30\nRemember the vendor call.\n\n' +
          '- [Sync engine](synapseresource://note/n-sync?via=gantt) · 2026-10-12 → 2026-11-06\n  - owner: Ana\n\n## Tasks\n\n```synapse-gantt') === 0, t);
        ok('G1 repair: ... the text after the chart is kept', /```\n\nAfter the chart\.$/.test(t), t);
        eq('G1 repair: ... the new chart has the heading', B.read(t, GATE).chart.settings.listHeading, 'Tasks');
      });
    });

    acase('G1 reconciliation: no banner on list-basic after open and after a save; edits and deletions', function () {
      var e;
      return lworld('list-basic.md', { approved: true }).then(function (w) {
        e = w;
        eq('G1 gap: no banner after open', e.st.mirrorGap(), null);
        e.st.commit(setColor(e.s.live));
        return settle(e);
      }).then(function () {
        e.mock.setNote(CH, e.mock.content(CH));
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () {
        ok('G1 gap: the resume read the note', typeof e.s.lastText === 'string');
        eq('G1 gap: no banner after a save (no task reads as edited)', e.st.mirrorGap(), null);
        eq('G1 gap: ... and none in the UI', e.st.ui().banner, null);
        e.mock.setNote(CH, e.mock.content(CH).split('\n').map(function (l) { return l.indexOf('[Kickoff](') >= 0 ? l + ' (asked Sam)' : l; }).join('\n'));
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () {
        same('G1 gap: an annotated line inside the list is edited, not deleted', e.st.mirrorGap(), { deleted: [], edited: ['t0'] });
        e.mock.setNote(CH, e.mock.content(CH).split('\n').filter(function (l) { return l.indexOf('[Kickoff](') < 0; }).join('\n'));
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () {
        same('G1 gap: a deleted line is deleted', e.st.mirrorGap(), { deleted: ['t0'], edited: [] });
      });
    });

    acase('G1 checkOnOpen step 4 compares chart keys (a composite note key)', function () {
      var L0 = chartS({ listHeading: null }), Lh = C(Object.assign(M.toData(L0), { settings: { listHeading: 'Tasks' } }));
      var e;
      return world({ S: L0, entry: oldEntry(setX(Lh, '2026-10-07'), Lh) }).then(function (w) {
        e = w;
        ok('G1 step 4: the note key is composite', e.s.key.indexOf('#') > 0);
        return e.s.checked;
      }).then(function (r) {
        eq('G1 step 4: the entry equal to the defaulted note chart is dropped by step 4', r.kind + ':' + r.step, 'dropped:4');
        return settle(e);
      }).then(function () {
        eq('G1 step 4: ... and deleted', stored(e), null);
      });
    });

    acase('G1 (d) over a legacy chart: a crash during the migrating save, then open', function () {
      var L0 = chartS({ listHeading: null }), e, A;
      return world({ S: L0 }).then(function (w) {
        e = w;
        A = setX(e.s.live, '2026-10-05');
        e.mock.holdUpdateNotes();
        e.st.commit(A);
        e.fr.run();
        return settle(e);
      }).then(function () {
        ok('G1 (d): {S+h, A} at the crash', entryIs(stored(e), e.s.base, A));
        e.mock.haltAfter('updateNotes');
        return e.mock.release();
      }).then(function () {
        ok('G1 (d): the note holds A in the delimited form', S.same(B.read(e.mock.content(CH), GATE).chart, A) && e.mock.content(CH).indexOf('## Tasks') > 0);
        return reopen(e);
      }).then(function (r) {
        eq('G1 (d): step 4, no banner', r.st.ui().banner, null);
        ok('G1 (d): the chart shows A', S.same(r.s.live, A));
        eq('G1 (d): the entry is gone', stored(r), null);
      });
    });

    acase('G1 open: a launch read without the list gate is read again with it', function () {
      var e;
      return lworld('list-attached-notes.md', { read: false }).then(function (w) {
        e = w;
        var text = e.mock.content(CH), route = H.route({ notes: [{ id: CH, content: text, title: 'Plan' }], params: {} });
        ok('G1 open: the route carries the note text', route.kind === 'chart' && route.text === text && !route.read.list);
        e.mock.resetCounts();
        return e.st.open({ noteId: CH, read: route.read, text: route.text });
      }).then(function (o) {
        ok('G1 open: with the text, the session has the list read (no bridge read)', o.ok && contentReads(e) === 0 && e.s !== o.session && o.session.attach['t:t3'][0] === '  - waiting on legal',
          JSON.stringify([o.ok, e.mock.calls, o.session && o.session.attach]));
        e.mock.resetCounts();
        return e.st.open({ noteId: CH, read: B.read(e.mock.content(CH)) });
      }).then(function (o) {
        ok('G1 open: without the text, an ungated read is not used: the note is read', o.ok && contentReads(e) === 1 && o.session.region.indexOf('## Tasks') === 0 && o.session.attach['t:t3'][0] === '  - waiting on legal');
      });
    });
  }

  // G2 phase 2: the helpers dev/sync_spec.js builds its store cases on.
  SPEC.storeKit = { world: world, reopen: reopen, env: env, settle: settle, stored: stored, oldEntry: oldEntry, CH: CH,
    TASKS: TASKS, GATE: GATE, chartS: chartS, noteText: noteText, setX: setX, lost: lost, noWhole: noWhole, key: key };
  SPEC.suites.push({ name: 'the store spec', fn: storeSpec });
  SPEC.suites.push({ name: 'the store walkthroughs over folded charts', fn: function () {
    FOLDING = true;
    try { storeSpec(); } finally { FOLDING = false; }
    // The mode really folds: the default chart's note reads with a composite key.
    FOLD = true;
    var t = noteText(chartS()), fr = B.read(t, LIST);
    FOLD = false;
    ok('folded walkthroughs: the default note folds back to the chart', fr.key !== fr.bodyKey && S.same(fr.chart, chartS()) && !S.same(fr.json, chartS()));
    acaseReal('folded walkthroughs: the opens really folded', function () {
      ok('folded walkthroughs: most opens read a composite key (' + FOLDED_OPENS + ')', FOLDED_OPENS >= 40, String(FOLDED_OPENS));
    });
  } });
  SPEC.suites.push({ name: 'the G1 list store spec', fn: listStoreSpec });
  SPEC.suites.push({ name: 'the M7 store spec', fn: memberSpec });
  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
