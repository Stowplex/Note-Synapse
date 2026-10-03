/*
 * Gantt date sync assertions (task-groups plan §8.12): the syncDates
 * default, M.noteDates, forward date entries (task notes only), note dates
 * applied to the chart against the agreed dates (never against the chart),
 * the toast key `ld`, and the banner for charts whose dates already differ.
 * Built on store_spec.js's helpers (SPEC.storeKit), against the mock host.
 * Runs under node (dev/run.js) and in the browser (dev/auto_smoke.html).
 */
(function (global) {
  'use strict';
  var GT = global.GT, B = GT.block, M = GT.model, D = GT.dates, SPEC = GT.spec;
  var A = SPEC.api, ok = A.ok, eq = A.eq, acase = A.acase;
  var K = null, CH = 'chart-1';

  function day(s) { return s === null ? null : D.parse(s); }
  function fmt(d) { return d === null ? null : D.format(d); }
  function span(c, id) { var t = M.task(c, id); return fmt(t.start) + '/' + fmt(t.end); }
  function json(x) { return JSON.stringify(x); }
  function ups(e) { return e.mock.count('updateNotes'); }
  function lastUpdate(e) { return e.mock.updates[e.mock.updates.length - 1] || []; }
  function noteDates(e, id) { var n = e.mock.note(id); return n.scheduledAt + '/' + n.completeBy; }
  // A chart: t1 (n1) Oct 3 to 10, t2 (n2) Oct 5 to 12, t3 (n3) a milestone
  // on Oct 20, t4 (n4) unscheduled, t5 (n5, a plain note) Oct 6 to 8.
  function chart(settings) {
    return M.coerce({ v: 1, settings: Object.assign({ listHeading: 'Tasks' }, settings || {}), tasks: [
      { id: 't1', note: 'n1', title: 'One', start: '2026-10-03', end: '2026-10-10' },
      { id: 't2', note: 'n2', title: 'Two', start: '2026-10-05', end: '2026-10-12' },
      { id: 't3', note: 'n3', title: 'Three', start: '2026-10-20', milestone: true },
      { id: 't4', note: 'n4', title: 'Four' },
      { id: 't5', note: 'n5', title: 'Five', start: '2026-10-06', end: '2026-10-08' }] }).chart;
  }
  // Note dates by id: [scheduledAt, completeBy]; `sync` = the chart's own.
  var SYNC = { n1: ['2026-10-03', '2026-10-10'], n2: ['2026-10-05', '2026-10-12'], n3: ['2026-10-20', '2026-10-20'] };
  function seed(c, dates) {
    var notes = [{ id: CH, title: 'Plan', content: 'Intro.\n\n' + B.region(c, null, { list: true }) }];
    ['n1', 'n2', 'n3', 'n4', 'n5'].forEach(function (id, i) {
      var n = { id: id, title: ['One', 'Two', 'Three', 'Four', 'Five'][i], type: id === 'n5' ? 'note' : 'task' };
      var d = dates && dates[id];
      if (d) { n.scheduledAt = d[0]; n.completeBy = d[1]; }
      notes.push(n);
    });
    return notes;
  }
  function open(o) {
    o = o || {};
    var e = K.env({ seed: o.db ? null : seed(o.chart || chart(o.settings), o.dates || SYNC), db: o.db, storage: o.storage, mock: o.mock });
    e.dates = [];
    e.st.on('dates', function (x) { e.dates.push(x); });
    if (o.mode) e.st.launch.mode = o.mode;
    if (o.approved !== false) { e.st.launch.sessionApproved = true; e.mock.sessionApproved = true; }
    return e.st.boot().then(function () {
      var t = e.mock.content(CH);
      return e.st.open({ noteId: CH, read: B.read(t), text: t });
    }).then(function (r) {
      e.s = r.session;
      return Promise.all([e.s.checked, e.s.resolved]);
    }).then(function () { return K.settle(e); }).then(function () { return e; });
  }
  function again(e, o) { return open(Object.assign({ db: e.mock.db, storage: e.storage }, o || {})); }
  function setND(e, id, s, d) {
    var n = e.mock.note(id);
    n.scheduledAt = s;
    n.completeBy = d;
    n.updatedAt = e.mock.db.tick();
  }
  function resume(e) { return e.mock.resume().then(function () { return K.settle(e); }); }
  function saved(e) { return (e.s.busy || Promise.resolve()).then(function () { return K.settle(e); }); }
  function noteChart(e) { return B.read(e.mock.content(CH), { list: true }).chart; }
  function cacheFacts(e) { var c = e.st.cache.get(CH); return c && c.facts ? c.facts : {}; }

  function datesSpec() {
    K = SPEC.storeKit;
    CH = K.CH;

    /* ---- 1. the default ---- */
    eq('dates: syncDates is on in an empty chart', M.empty().settings.syncDates, true);
    eq('dates: an omitted key means on', M.coerce({ v: 1, settings: {} }).chart.settings.syncDates, true);
    eq('dates: on is not written (omit when default)', json(M.toData(M.coerce({ v: 1, settings: { syncDates: true } }).chart)), '{"v":1}');
    var off = M.coerce({ v: 1, settings: { syncDates: false } }).chart;
    eq('dates: off is kept', off.settings.syncDates, false);
    eq('dates: off is written as false', json(M.toData(off)), '{"v":1,"settings":{"syncDates":false}}');
    var offText = B.serialize(off);
    eq('dates: an explicit false serialises byte-identically twice', B.serialize(M.coerce(JSON.parse(offText)).chart), offText);
    var r1 = M.setSettings(M.empty(), { syncDates: false });
    ok('dates: turning it off stores false, undo removes the key', json(M.toData(r1.chart).settings) === '{"syncDates":false}' &&
      json(M.toData(M.applyPatch(r1.chart, r1.inverse).chart)) === '{"v":1}');

    /* ---- M.noteDates ---- */
    var c0 = chart(), t1 = M.task(c0, 't1'), t3 = M.task(c0, 't3'), t4 = M.task(c0, 't4');
    function nd(t, s, d) { var r = M.noteDates(t, day(s), day(d)); return r ? fmt(r.start) + '/' + fmt(r.end) : null; }
    eq('noteDates: the chart already agrees', nd(t1, '2026-10-03', '2026-10-10'), null);
    eq('noteDates: a note with no dates keeps the chart', nd(t1, null, null), null);
    eq('noteDates: both dates', nd(t1, '2026-10-06', '2026-10-12'), '2026-10-06/2026-10-12');
    eq('noteDates: a null scheduledAt keeps the chart start', nd(t1, null, '2026-10-15'), '2026-10-03/2026-10-15');
    eq('noteDates: a null completeBy keeps the chart end', nd(t1, '2026-10-05', null), '2026-10-05/2026-10-10');
    eq('noteDates: a start past the kept end moves the end to it', nd(t1, '2026-10-14', null), '2026-10-14/2026-10-14');
    eq('noteDates: a milestone follows scheduledAt', nd(t3, '2026-10-22', '2026-10-30'), '2026-10-22/null');
    eq('noteDates: a milestone ignores completeBy alone', nd(t3, null, '2026-10-30'), null);
    eq('noteDates: an unscheduled task is scheduled (5 days without completeBy)', nd(t4, '2026-10-07', null), '2026-10-07/2026-10-11');
    eq('noteDates: an unscheduled task with both dates', nd(t4, '2026-10-07', '2026-10-09'), '2026-10-07/2026-10-09');

    /* ---- 2. forward ---- */
    acase('dates forward: a chart with no syncDates key writes the moved task note\'s dates in the same array', function () {
      var e;
      return open().then(function (w) {
        e = w;
        eq('forward: nothing written at open (all in sync)', ups(e), 0);
        e.st.commit(M.moveTask(e.s.live, 't1', 2).chart);
        return saved(e);
      }).then(function () {
        var list = lastUpdate(e);
        eq('forward: one array, the chart entry then the date entry', json(list.map(function (x) { return x.id; })), json([CH, 'n1']));
        eq('forward: the note has the new dates', noteDates(e, 'n1'), '2026-10-05/2026-10-12');
        eq('forward: the agreed dates follow the write (cached ds)', json(cacheFacts(e).n1.ds), json(['2026-10-05', '2026-10-12']));
        e.st.commit(M.moveTask(e.s.live, 't3', 1).chart);
        return saved(e);
      }).then(function () {
        eq('forward: a milestone sends completeBy = scheduledAt', json(lastUpdate(e)[1]), json({ id: 'n3', scheduledAt: '2026-10-21', completeBy: '2026-10-21' }));
        return resume(e);
      }).then(function () {
        eq('forward: the resume that reads our own writes changes nothing', e.dates.length + '|' + span(e.s.live, 't1'), '0|2026-10-05/2026-10-12');
      });
    });

    acase('dates forward: a plain note (not type task) gets no date entry', function () {
      var e;
      return open().then(function (w) {
        e = w;
        e.st.commit(M.moveTask(e.s.live, 't5', 3).chart);
        return saved(e);
      }).then(function () {
        eq('forward plain: the chart entry only', json(lastUpdate(e).map(function (x) { return x.id; })), json([CH]));
        eq('forward plain: the plain note keeps no dates', noteDates(e, 'n5'), 'null/null');
        eq('forward plain: no sheet line for it', e.st.noteDatesOf('t5'), null);
      });
    });

    acase('dates forward: a move undone before the save sends no date entry', function () {
      var e;
      return open({ mode: 'manual', approved: false }).then(function (w) {
        e = w;
        var a = M.moveTask(e.s.live, 't1', 2);
        e.st.commit(a.chart);
        eq('forward undo: one pending entry', e.s.pendingDates.length, 1);
        e.st.commit(M.applyPatch(e.s.live, a.inverse).chart);
        eq('forward undo: back at the note\'s dates, nothing pending', e.s.pendingDates.length, 0);
      });
    });

    acase('dates forward: syncDates off writes no dates', function () {
      var e;
      return open({ settings: { syncDates: false } }).then(function (w) {
        e = w;
        e.st.commit(M.moveTask(e.s.live, 't1', 2).chart);
        return saved(e);
      }).then(function () {
        eq('forward off: the chart entry only', lastUpdate(e).length, 1);
        eq('forward off: the note keeps its dates', noteDates(e, 'n1'), '2026-10-03/2026-10-10');
      });
    });

    /* ---- 3. note to chart ---- */
    acase('dates reverse: a note changed elsewhere gives its dates to the chart, with a toast and Undo', function () {
      var e, e2, n;
      return open().then(function (w) {
        e = w;
        eq('reverse: agreed dates are cached at open', json(cacheFacts(e).n1.ds), json(['2026-10-03', '2026-10-10']));
        setND(e, 'n1', '2026-10-06', '2026-10-14');
        return resume(e);
      }).then(function () {
        eq('reverse: the chart took the note\'s dates', span(e.s.live, 't1'), '2026-10-06/2026-10-14');
        eq('reverse: one dates event', e.dates.length, 1);
        n = e.st.takeDates();
        eq('reverse: the toast item', json(n && n.items), json([{ id: 't1', start: day('2026-10-06'), end: day('2026-10-14') }]));
        eq('reverse: taken once', e.st.takeDates(), null);
        eq('reverse: approved auto saves on the debounce (followTitles rule), not at once', ups(e) + '|' + e.tm.count(GT.store.DEBOUNCE_MS), '0|1');
        ok('reverse: the applied dates are not cached before the save', json(cacheFacts(e).n1.ds) === json(['2026-10-03', '2026-10-10']));
        e.tm.fire(GT.store.DEBOUNCE_MS);
        return saved(e);
      }).then(function () {
        eq('reverse: saved through the normal path, the chart entry only (the note has these dates)', json(lastUpdate(e).map(function (x) { return x.id; })), json([CH]));
        eq('reverse: the chart note holds them', span(noteChart(e), 't1'), '2026-10-06/2026-10-14');
        ok('reverse: ld is cached', typeof e.st.cache.get(CH).ld === 'string');
        return resume(e);
      }).then(function () {
        eq('reverse: a second resume shows nothing', e.dates.length, 1);
        e.st.commit(M.applyPatch(e.s.live, n.inverse).chart);
        return saved(e);
      }).then(function () {
        eq('reverse undo: the chart dates are back', span(e.s.live, 't1'), '2026-10-03/2026-10-10');
        eq('reverse undo: its save writes the note dates back', noteDates(e, 'n1'), '2026-10-03/2026-10-10');
        return resume(e);
      }).then(function () {
        eq('reverse undo: no bounce on the next resume', e.dates.length + '|' + span(e.s.live, 't1'), '1|2026-10-03/2026-10-10');
        return again(e);
      }).then(function (w) {
        e2 = w;
        eq('reverse: a reopen changes nothing and shows nothing', e2.dates.length + '|' + span(e2.s.live, 't1') + '|' + json(e2.st.dateGap()), '0|2026-10-03/2026-10-10|null');
      });
    });

    acase('dates reverse: a denied forward write does not pull the chart back', function () {
      var e;
      return open({ approved: false, mock: { approve: 'deny' } }).then(function (w) {
        e = w;
        e.st.commit(M.moveTask(e.s.live, 't1', 2).chart);
        return saved(e);
      }).then(function () {
        eq('denied: the save was denied', e.st.launch.mode, 'paused');
        eq('denied: the note kept its dates', noteDates(e, 'n1'), '2026-10-03/2026-10-10');
        return resume(e);
      }).then(function () {
        eq('denied: the chart keeps the move', span(e.s.live, 't1'), '2026-10-05/2026-10-12');
        eq('denied: no dates event', e.dates.length, 0);
      });
    });

    acase('dates reverse: a refused date entry does not pull the chart back, now or on reopen', function () {
      var e, e2;
      return open().then(function (w) {
        e = w;
        e.mock.refuse('n1');
        e.st.commit(M.moveTask(e.s.live, 't1', 2).chart);
        return saved(e);
      }).then(function () {
        eq('refused: the chart saved', span(noteChart(e), 't1'), '2026-10-05/2026-10-12');
        return resume(e);
      }).then(function () {
        eq('refused: no bounce', span(e.s.live, 't1') + '|' + e.dates.length, '2026-10-05/2026-10-12|0');
        ok('refused: the sheet line shows the note\'s dates', json(e.st.noteDatesOf('t1')) === json({ start: day('2026-10-03'), end: day('2026-10-10'), noteStart: day('2026-10-03'), noteEnd: day('2026-10-10') }));
        return e.st.state.flush().then(function () { return again(e); });
      }).then(function (w) {
        e2 = w;
        eq('refused: a reopen keeps the chart, no toast, no banner', span(e2.s.live, 't1') + '|' + e2.dates.length + '|' + json(e2.st.dateGap()), '2026-10-05/2026-10-12|0|null');
      });
    });

    acase('dates reverse: null note dates keep the chart\'s; a milestone follows scheduledAt', function () {
      var e;
      return open().then(function (w) {
        e = w;
        setND(e, 'n1', null, '2026-10-15');
        setND(e, 'n2', null, null);
        setND(e, 'n3', '2026-10-24', '2026-10-24');
        return resume(e);
      }).then(function () {
        eq('null: completeBy only moves the end', span(e.s.live, 't1'), '2026-10-03/2026-10-15');
        eq('null: both null keeps the task', span(e.s.live, 't2'), '2026-10-05/2026-10-12');
        eq('milestone: follows scheduledAt', span(e.s.live, 't3'), '2026-10-24/null');
        eq('null: one toast for both changes', json(e.dates.map(function (x) { return x.items.map(function (i) { return i.id; }); })), json([['t1', 't3']]));
        setND(e, 'n3', '2026-10-24', '2026-11-02');
        return resume(e);
      }).then(function () {
        eq('milestone: completeBy alone changes nothing', span(e.s.live, 't3') + '|' + e.dates.length, '2026-10-24/null|1');
      });
    });

    acase('dates reverse: an unscheduled task whose note has dates is scheduled, with the toast', function () {
      var e;
      return open({ dates: Object.assign({ n4: ['2026-10-08', '2026-10-09'] }, SYNC) }).then(function (w) {
        e = w;
        eq('unscheduled: scheduled at open', span(e.s.live, 't4'), '2026-10-08/2026-10-09');
        eq('unscheduled: one dates event', e.dates.length, 1);
        eq('unscheduled: not a banner', e.st.dateGap(), null);
      });
    });

    acase('dates reverse: the toast shows once per key (ld): a change already shown applies silently', function () {
      var st = { v: 1, charts: {} };
      st.charts[CH] = { at: 1, facts: {}, ld: B.hash('n4@2026-10-08/2026-10-09') };
      var e = K.env({ seed: seed(chart(), Object.assign({ n4: ['2026-10-08', '2026-10-09'] }, SYNC)) });
      e.dates = [];
      e.st.on('dates', function (x) { e.dates.push(x); });
      e.mock.setState(st);
      e.st.launch.sessionApproved = true;
      e.mock.sessionApproved = true;
      return e.st.boot().then(function () {
        var t = e.mock.content(CH);
        return e.st.open({ noteId: CH, read: B.read(t), text: t });
      }).then(function (r) {
        e.s = r.session;
        return Promise.all([e.s.checked, e.s.resolved]);
      }).then(function () { return K.settle(e); }).then(function () {
        eq('ld: applied without a toast', span(e.s.live, 't4') + '|' + e.dates.length, '2026-10-08/2026-10-09|0');
      });
    });

    acase('dates reverse: nothing with syncDates off, and a note change made while held waits', function () {
      var e;
      return open({ settings: { syncDates: false } }).then(function (w) {
        e = w;
        setND(e, 'n1', '2026-10-06', '2026-10-14');
        return resume(e);
      }).then(function () {
        eq('off: the chart keeps its dates', span(e.s.live, 't1') + '|' + e.dates.length, '2026-10-03/2026-10-10|0');
        ok('off: the sheet line still shows them', !!e.st.noteDatesOf('t1'));
      });
    });

    acase('dates reverse: the list fold toast key does not hide a date toast', function () {
      var e;
      return open().then(function (w) {
        e = w;
        e.s.la = 'x';
        e.st.cache.put(CH, Object.assign({}, e.st.cache.get(CH), { la: 'x' }));
        setND(e, 'n2', '2026-10-07', '2026-10-12');
        return resume(e);
      }).then(function () {
        eq('keys: the date toast shows with a list key recorded', e.dates.length, 1);
      });
    });

    /* ---- review round 1 ---- */
    eq('noteDates: both dates with the end before the start: the end moves to the start', nd(t1, '2026-10-12', '2026-10-08'), '2026-10-12/2026-10-12');

    acase('dates review RV-A: a move undone while its save is in flight writes the note back', function () {
      var e, a;
      return open().then(function (w) {
        e = w;
        e.mock.holdUpdateNotes();
        a = M.moveTask(e.s.live, 't1', 2);
        e.st.commit(a.chart);
        return K.settle(e);
      }).then(function () {
        e.st.commit(M.applyPatch(e.s.live, a.inverse).chart);
        eq('RV-A: the undo queues the old dates (the note is getting the moved ones)', json(e.s.pendingDates), json([{ id: 'n1', scheduledAt: '2026-10-03', completeBy: '2026-10-10' }]));
        return K.settle(e);
      }).then(function () { return e.mock.release(); }).then(function () { return saved(e); }).then(function () { return saved(e); }).then(function () { return resume(e); }).then(function () {
        eq('RV-A: chart, chart note and note agree on the old dates', span(e.s.live, 't1') + '|' + span(noteChart(e), 't1') + '|' + noteDates(e, 'n1'), '2026-10-03/2026-10-10|2026-10-03/2026-10-10|2026-10-03/2026-10-10');
        eq('RV-A: no sheet line', e.st.noteDatesOf('t1'), null);
      });
    });

    acase('dates review R2: move, save, undo, save: the note is written back', function () {
      var e, a;
      return open().then(function (w) {
        e = w;
        a = M.moveTask(e.s.live, 't2', 3);
        e.st.commit(a.chart);
        return saved(e);
      }).then(function () {
        eq('R2: the note moved', noteDates(e, 'n2'), '2026-10-08/2026-10-15');
        e.st.commit(M.applyPatch(e.s.live, a.inverse).chart);
        return saved(e);
      }).then(function () {
        eq('R2: the undo wrote the old dates back', noteDates(e, 'n2'), '2026-10-05/2026-10-12');
      });
    });

    acase('dates review RV-B: another device\'s move is not read as a note edit (auto)', function () {
      var a, b;
      return open().then(function (w) { a = w; return again(a, { storage: new Map() }); }).then(function (w) {
        b = w;
        a.st.commit(M.moveTask(a.s.live, 't1', 2).chart);
        return saved(a);
      }).then(function () { return resume(b); }).then(function () {
        eq('RV-B: B shows the move', span(b.s.live, 't1'), '2026-10-05/2026-10-12');
        eq('RV-B: no toast, no write on B', b.dates.length + '|' + b.mock.count('updateNotes'), '0|0');
        eq('RV-B: B is clean', b.st.ui().pill, 'saved');
      });
    });

    acase('dates review RV-B2: another device\'s move while this one has unsaved edits (manual)', function () {
      var a, b, n0;
      return open().then(function (w) { a = w; return again(a, { storage: new Map(), mode: 'manual' }); }).then(function (w) {
        b = w;
        b.st.commit(M.setTask(b.s.live, 't2', { color: 'rose' }).chart);
        a.st.commit(M.moveTask(a.s.live, 't1', 2).chart);
        return saved(a);
      }).then(function () {
        n0 = b.mock.count('updateNotes');
        return resume(b);
      }).then(function () {
        eq('RV-B2: no toast and no apply before the merge', b.dates.length + '|' + span(b.s.live, 't1'), '0|2026-10-03/2026-10-10');
        return b.st.save();
      }).then(function () { return K.settle(b); }).then(function () {
        eq('RV-B2: the save merged the move, one write, no date entry', span(b.s.live, 't1') + '|' + (b.mock.count('updateNotes') - n0) + '|' + lastUpdate(b).length, '2026-10-05/2026-10-12|1|1');
        return resume(b);
      }).then(function () {
        eq('RV-B2: still no toast after the merge', b.dates.length, 0);
      });
    });

    acase('dates review RV-C: applied dates are cached only after their save; Discard re-applies', function () {
      var e, e2;
      return open({ mode: 'manual' }).then(function (w) {
        e = w;
        setND(e, 'n1', '2026-10-06', '2026-10-14');
        return resume(e);
      }).then(function () {
        eq('RV-C: applied, unsaved', span(e.s.live, 't1') + '|' + e.st.ui().pill, '2026-10-06/2026-10-14|unsaved');
        eq('RV-C: the agreed dates in the cache are the old ones', json(cacheFacts(e).n1.ds), json(['2026-10-03', '2026-10-10']));
        e.fr.run();
        return K.settle(e).then(function () { return e.st.onHide('home'); }).then(function () { return e.st.state.flush(); }).then(function () { return K.settle(e); });
      }).then(function () { return again(e, { mode: 'manual' }); }).then(function (w) {
        e2 = w;
        ok('RV-C: Restore is offered', !!e2.s.offer);
        e2.st.journal.discard(CH);
        return K.settle(e2);
      }).then(function () {
        eq('RV-C: right after Discard (no resume) the note dates are applied again', span(e2.s.live, 't1'), '2026-10-06/2026-10-14');
        eq('RV-C: ... with the toast again', e2.dates.length, 1);
        return e2.st.save();
      }).then(function () { return K.settle(e2); }).then(function () {
        eq('RV-C: saved, now agreed and cached', json(cacheFacts(e2).n1.ds), json(['2026-10-06', '2026-10-14']));
      });
    });

    acase('dates review RV-H: an unsaved apply lost to a kill is applied again on reopen', function () {
      var e, e2;
      return open({ mode: 'manual' }).then(function (w) {
        e = w;
        setND(e, 'n1', '2026-10-06', '2026-10-14');
        return resume(e);
      }).then(function () { return e.st.state.flush(); }).then(function () { return again(e, { mode: 'manual' }); }).then(function (w) {
        e2 = w;
        eq('RV-H: applied again, no banner', span(e2.s.live, 't1') + '|' + json(e2.st.dateGap()), '2026-10-06/2026-10-14|null');
      });
    });

    acase('dates review RV-D: a note edited after this store\'s write landed is not overwritten by the answer', function () {
      var e;
      return open().then(function (w) {
        e = w;
        e.mock.holdUpdateNotes();
        e.st.commit(M.moveTask(e.s.live, 't1', 2).chart);
        return K.settle(e);
      }).then(function () { return e.mock.release('apply'); }).then(function () {
        setND(e, 'n1', '2026-10-20', '2026-10-25');
        return e.mock.resume().then(function () { return K.settle(); });
      }).then(function () { return e.mock.release(); }).then(function () { return saved(e); }).then(function () {
        eq('RV-D: the chart keeps its move', span(e.s.live, 't1'), '2026-10-05/2026-10-12');
        ok('RV-D: the fact keeps the newer note dates (sheet line)', !!e.st.noteDatesOf('t1'));
        return resume(e);
      }).then(function () {
        eq('RV-D: the next resume applies the note edit', span(e.s.live, 't1') + '|' + noteDates(e, 'n1'), '2026-10-20/2026-10-25|2026-10-20/2026-10-25');
      });
    });

    acase('dates review RV-G: before session approval an applied note date raises no dialog', function () {
      var e;
      return open({ approved: false }).then(function (w) {
        e = w;
        setND(e, 'n1', '2026-10-06', '2026-10-14');
        return resume(e);
      }).then(function () {
        eq('RV-G: applied, no dialog, no write, still auto', span(e.s.live, 't1') + '|' + e.mock.dialogs + '|' + e.mock.count('updateNotes') + '|' + e.st.launch.mode, '2026-10-06/2026-10-14|0|0|auto');
        eq('RV-G: the pill shows it unsaved', e.st.ui().pill, 'unsaved');
      });
    });

    acase('dates review R5: an entry in flight (a resend, the chart note unchanged) keeps the chart\'s dates over a note edit', function () {
      var e;
      return open().then(function (w) {
        e = w;
        e.mock.refuse('n1');
        e.st.commit(M.moveTask(e.s.live, 't1', 2).chart);
        return saved(e);
      }).then(function () {
        eq('R5: the refused entry is kept', e.s.pendingDates.length, 1);
        e.mock.refuse('n1', false);
        e.mock.holdUpdateNotes();
        e.st.save();
        return K.settle(e);
      }).then(function () {
        eq('R5: the resend is in flight', e.s.sending.length, 1);
        setND(e, 'n1', '2026-10-20', '2026-10-25');
        return resume(e);
      }).then(function () {
        eq('R5: the chart keeps its dates, no toast', span(e.s.live, 't1') + '|' + e.dates.length, '2026-10-05/2026-10-12|0');
        return e.mock.release();
      }).then(function () { return saved(e); });
    });

    acase('dates review R5b: moved back to the dates in flight (nothing queued) keeps the chart\'s dates over a note edit', function () {
      var e;
      return open().then(function (w) {
        e = w;
        e.mock.holdUpdateNotes();
        e.st.commit(M.moveTask(e.s.live, 't1', 2).chart);
        return K.settle(e);
      }).then(function () {
        e.st.commit(M.moveTask(e.s.live, 't1', 1).chart);
        e.st.commit(M.moveTask(e.s.live, 't1', -1).chart);
        eq('R5b: back at the dates in flight: nothing queued', e.s.pendingDates.length + '|' + e.s.sending.length, '0|1');
        setND(e, 'n1', '2026-10-20', '2026-10-25');
        return resume(e);
      }).then(function () {
        eq('R5b: the chart keeps its dates, no toast', span(e.s.live, 't1') + '|' + e.dates.length, '2026-10-05/2026-10-12|0');
        return e.mock.release();
      }).then(function () { return saved(e); }).then(function () { return saved(e); });
    });

    acase('dates review R6: a queued (unsent) entry keeps the chart\'s dates over a note edit', function () {
      var e;
      return open({ mode: 'manual', approved: false }).then(function (w) {
        e = w;
        e.st.commit(M.moveTask(e.s.live, 't1', 2).chart);
        setND(e, 'n1', '2026-10-20', '2026-10-25');
        return resume(e);
      }).then(function () {
        eq('R6: the chart keeps its unsaved move, no toast', span(e.s.live, 't1') + '|' + e.dates.length, '2026-10-05/2026-10-12|0');
      });
    });

    acase('dates review R7: a note edit is not applied while the chart is held; it applies after', function () {
      var e, e2, S1 = chart(), A1 = M.moveTask(S1, 't2', 1).chart;
      return open().then(function (w) {
        e = w;
        return e.st.state.flush();
      }).then(function () {
        setND(e, 'n1', '2026-10-06', '2026-10-14');
        var st = e.mock.state();
        st.journal = {};
        st.journal[CH] = K.oldEntry(S1, A1);
        e.mock.setState(st);
        return again(e);
      }).then(function (w) {
        e2 = w;
        ok('R7: held (Restore offered)', !!e2.s.offer && e2.s.journalHold);
        eq('R7: not applied while held', span(e2.s.live, 't1') + '|' + e2.dates.length, '2026-10-03/2026-10-10|0');
        e2.st.journal.discard(CH);
        return K.settle(e2);
      }).then(function () {
        eq('R7: applied once editable, right after Discard (no resume)', span(e2.s.live, 't1') + '|' + e2.dates.length, '2026-10-06/2026-10-14|1');
      });
    });

    acase('dates review RV-F: moves made while sync was off are sent when it is turned on', function () {
      var e;
      return open({ settings: { syncDates: false } }).then(function (w) {
        e = w;
        e.st.commit(M.moveTask(e.s.live, 't1', 2).chart);
        return saved(e);
      }).then(function () {
        eq('RV-F: off, the note is not written', noteDates(e, 'n1'), '2026-10-03/2026-10-10');
        e.st.commit(M.setSettings(e.s.live, { syncDates: true }).chart);
        return saved(e);
      }).then(function () {
        eq('RV-F: turning it on sends the differing task in the settings save', json(lastUpdate(e).map(function (x) { return x.id; })), json([CH, 'n1']));
        eq('RV-F: the note has the chart dates', noteDates(e, 'n1'), '2026-10-05/2026-10-12');
        return resume(e);
      }).then(function () {
        eq('RV-F: no toast, no banner', e.dates.length + '|' + json(e.st.dateGap()), '0|null');
      });
    });

    /* ---- review round 2 ---- */
    function sleepMs(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

    acase('dates review 2 X-b: an undo during the re-read after a missed save still writes the note back', function () {
      var e, a, slow = false;
      return open().then(function (w) {
        e = w;
        var c2 = M.setTask(e.s.live, 't2', { color: 'rose' }).chart;
        e.mock.outsideEdit(function (m) { m.setNote(CH, 'Intro.\n\n' + B.region(c2, null, { list: true })); slow = true; });
        e.mock.latency = function (name) { return slow && name === 'runQuery' ? 60 : 0; };
        a = M.moveTask(e.s.live, 't1', 2);
        e.st.commit(a.chart);
        return sleepMs(20);
      }).then(function () {
        eq('X-b: in the re-read: the missed attempt applied the date entry, still counted in flight', e.s.sending.length + '|' + noteDates(e, 'n1'), '1|2026-10-05/2026-10-12');
        e.st.commit(M.applyPatch(e.s.live, a.inverse).chart);
        eq('X-b: the undo queues the old dates', json(e.s.pendingDates), json([{ id: 'n1', scheduledAt: '2026-10-03', completeBy: '2026-10-10' }]));
        return sleepMs(300);
      }).then(function () { slow = false; return saved(e); }).then(function () { return saved(e); }).then(function () {
        eq('X-b: chart, chart note and note agree, the outside edit merged', span(e.s.live, 't1') + '|' + span(noteChart(e), 't1') + '|' + noteDates(e, 'n1') + '|' + M.task(e.s.live, 't2').color,
          '2026-10-03/2026-10-10|2026-10-03/2026-10-10|2026-10-03/2026-10-10|rose');
        return resume(e);
      }).then(function () {
        eq('X-b: no pull back, no toast on the next resume', span(e.s.live, 't1') + '|' + e.dates.length, '2026-10-03/2026-10-10|0');
      });
    });

    acase('dates review 2 X-a3: Restore applies held-back note dates at once', function () {
      var e, e2, S1 = chart(), A1 = M.moveTask(S1, 't2', 1).chart;
      return open().then(function (w) {
        e = w;
        return e.st.state.flush();
      }).then(function () {
        setND(e, 'n1', '2026-10-06', '2026-10-14');
        var st = e.mock.state();
        st.journal = {};
        st.journal[CH] = K.oldEntry(S1, A1);
        e.mock.setState(st);
        return again(e, { mode: 'manual' });
      }).then(function (w) {
        e2 = w;
        ok('X-a3: Restore offered, nothing applied', !!e2.s.offer && span(e2.s.live, 't1') === '2026-10-03/2026-10-10');
        ok('X-a3: restored', e2.st.journal.restore().ok);
        eq('X-a3: right after Restore (no resume): the entry and the note dates', span(e2.s.live, 't2') + '|' + span(e2.s.live, 't1') + '|' + e2.dates.length, '2026-10-06/2026-10-13|2026-10-06/2026-10-14|1');
      });
    });

    acase('dates review 2 X-e: sync turned on then off again before a save sends no date entry', function () {
      var e, r;
      return open({ settings: { syncDates: false }, mode: 'manual' }).then(function (w) {
        e = w;
        e.st.commit(M.moveTask(e.s.live, 't1', 2).chart);
        return e.st.save();
      }).then(function () { return K.settle(e); }).then(function () {
        r = M.setSettings(e.s.live, { syncDates: true });
        // The pill-tap save above returned the session to auto: these two
        // commits are not saved on their own.
        e.st.commit(r.chart, { save: 'none' });
        eq('X-e: turning it on queued the entry', e.s.pendingDates.length, 1);
        e.st.commit(M.applyPatch(e.s.live, r.inverse).chart, { save: 'none' });
        eq('X-e: undone before a save: nothing queued', e.s.pendingDates.length, 0);
        return e.st.save();
      }).then(function () { return K.settle(e); }).then(function () {
        eq('X-e: the note keeps its dates', noteDates(e, 'n1'), '2026-10-03/2026-10-10');
      });
    });

    acase('dates review 2 X-f: a denied Update notes keeps an entry a move queued', function () {
      var e;
      var DIFF1 = Object.assign({}, SYNC, { n1: ['2026-10-01', '2026-10-08'] });
      return open({ dates: DIFF1, mode: 'manual', approved: false, mock: { approve: 'deny' } }).then(function (w) {
        e = w;
        e.st.commit(M.moveTask(e.s.live, 't1', 2).chart);
        eq('X-f: the move queued n1', json(e.s.pendingDates.map(function (d) { return d.id; })), json(['n1']));
        return e.st.pushDates(['t1']);
      }).then(function (r) {
        ok('X-f: denied', !r.ok);
        eq('X-f: the move\'s entry is still queued', json(e.s.pendingDates), json([{ id: 'n1', scheduledAt: '2026-10-05', completeBy: '2026-10-12' }]));
        e.mock.approve = 'session';
        return e.st.save();
      }).then(function () { return K.settle(e); }).then(function () {
        eq('X-f: the next save writes the note', noteDates(e, 'n1'), '2026-10-05/2026-10-12');
      });
    });

    acase('dates review 2 X-g: a hide before approval does not flush automatic changes', function () {
      var e;
      return open({ approved: false }).then(function (w) {
        e = w;
        setND(e, 'n1', '2026-10-06', '2026-10-14');
        return resume(e);
      }).then(function () {
        eq('X-g: applied, unsaved, no dialog', e.st.ui().pill + '|' + e.mock.dialogs, 'unsaved|0');
        return e.st.onHide('home');
      }).then(function (r) {
        return K.settle(e).then(function () {
          eq('X-g: the hide flushed nothing: no dialog, no write', !!(r && r.flushed) + '|' + e.mock.dialogs + '|' + ups(e), 'false|0|0');
          e.st.commit(M.setTask(e.s.live, 't2', { color: 'rose' }).chart, { save: 'none' });
          return e.st.onHide('home');
        });
      }).then(function (r) {
        return K.settle(e).then(function () {
          ok('X-g: after a user edit the hide flushes as before', !!(r && r.flushed) && ups(e) === 1);
        });
      });
    });

    /* ---- 4. the banner ---- */
    var DIFF = Object.assign({}, SYNC, { n1: ['2026-10-01', '2026-10-08'] });
    function uncached(e) { return !Object.prototype.hasOwnProperty.call(cacheFacts(e).n1 || {}, 'ds'); }

    acase('dates banner: shown when a note differs and no agreed dates are known, nothing guessed', function () {
      var e, e2;
      return open({ dates: DIFF }).then(function (w) {
        e = w;
        var g = e.st.dateGap();
        eq('banner: one task', json(g && g.tasks.map(function (x) { return x.id; })), json(['t1']));
        eq('banner: the chart is unchanged, nothing written', span(e.s.live, 't1') + '|' + ups(e) + '|' + e.dates.length, '2026-10-03/2026-10-10|0|0');
        ok('banner: n1 has no agreed dates in the cache, n2 does', uncached(e) && !!cacheFacts(e).n2.ds);
        return e.st.state.flush().then(function () { return again(e); });
      }).then(function (w) {
        e2 = w;
        ok('banner: offered again on the next open', !!e2.st.dateGap());
      });
    });

    acase('dates banner: not with syncDates off, not in manual read-only states', function () {
      return open({ dates: DIFF, settings: { syncDates: false } }).then(function (e) {
        eq('banner off: none', e.st.dateGap(), null);
      });
    });

    acase('dates banner: Update notes writes the chart dates in one array, once', function () {
      var e, e2;
      return open({ dates: DIFF }).then(function (w) {
        e = w;
        return e.st.pushDates(['t1']);
      }).then(function (r) {
        ok('update: saved', r.ok);
        eq('update: one array, chart then n1', json(lastUpdate(e).map(function (x) { return x.id; })), json([CH, 'n1']));
        eq('update: the note has the chart dates', noteDates(e, 'n1'), '2026-10-03/2026-10-10');
        eq('update: the banner is gone', e.st.dateGap(), null);
        return e.st.state.flush().then(function () { return again(e); });
      }).then(function (w) {
        e2 = w;
        eq('update: not offered again', e2.st.dateGap(), null);
      });
    });

    acase('dates banner: Update notes denied keeps the banner', function () {
      var e;
      return open({ dates: DIFF, approved: false, mock: { approve: 'deny' } }).then(function (w) {
        e = w;
        return e.st.pushDates(['t1']);
      }).then(function (r) {
        ok('update denied: not saved', !r.ok);
        ok('update denied: the banner stays', !!e.st.dateGap());
        eq('update denied: its entries are dropped', e.s.pendingDates.length, 0);
        return resume(e);
      }).then(function () {
        ok('update denied: ... and the banner stays after a resume', !!e.st.dateGap());
      });
    });

    acase('dates banner: Use note dates takes them with an undoable commit, once', function () {
      var e, e2, r;
      return open({ dates: DIFF }).then(function (w) {
        e = w;
        r = e.st.useNoteDates(['t1']);
        ok('use: committed', r.ok);
        eq('use: the chart has the note dates', span(e.s.live, 't1'), '2026-10-01/2026-10-08');
        eq('use: the banner is gone', e.st.dateGap(), null);
        return saved(e);
      }).then(function () {
        eq('use: the save sends no date entry', json(lastUpdate(e).map(function (x) { return x.id; })), json([CH]));
        eq('use: undo restores the chart dates', span(M.applyPatch(e.s.live, r.inverse).chart, 't1'), '2026-10-03/2026-10-10');
        return e.st.state.flush().then(function () { return again(e); });
      }).then(function (w) {
        e2 = w;
        eq('use: not offered again', e2.st.dateGap(), null);
      });
    });

    acase('dates banner: Keep both dismisses it, changes nothing, and later note edits apply', function () {
      var e, e2;
      return open({ dates: DIFF }).then(function (w) {
        e = w;
        ok('keep: done', e.st.keepDates());
        eq('keep: gone, nothing changed or written', json(e.st.dateGap()) + '|' + span(e.s.live, 't1') + '|' + ups(e), 'null|2026-10-03/2026-10-10|0');
        eq('keep: syncDates stays on', e.s.live.settings.syncDates, true);
        return e.st.state.flush().then(function () { return again(e); });
      }).then(function (w) {
        e2 = w;
        eq('keep: not offered again', e2.st.dateGap(), null);
        setND(e2, 'n1', '2026-10-02', '2026-10-08');
        return resume(e2);
      }).then(function () {
        eq('keep: a later note edit applies', span(e2.s.live, 't1') + '|' + e2.dates.length, '2026-10-02/2026-10-08|1');
      });
    });
  }

  SPEC.suites.push({ name: 'the date sync spec (task-groups §8.12)', fn: datesSpec });
  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
