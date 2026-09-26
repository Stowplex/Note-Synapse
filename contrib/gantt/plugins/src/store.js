/*
 * Gantt - the store (plan §4.2 store row): chart sessions, open (§7.5),
 * fact resolution and the cache (§7.1 to §7.5), resume (§7.6), commits and
 * autosave (§9.1.2), the CAS save of §9.2 with merge and conflicts, save
 * modes and prompted-save detection (§9.1.3), the appState write queue
 * (§9.1.4) and the unsaved-edits journal (§9.1.5), plus the note actions of
 * §8 (create, convert, add, toggles, rename) and host-effect undo (§6.1).
 *
 * Only this file calls host.js write methods. Nothing here touches the
 * DOM; the environment is injected so node can run it against installMock:
 *   create({host, frame, cancelFrame, now, hidden, setTimeout, clearTimeout, embed})
 * host defaults to GT.host, frame to requestAnimationFrame (setImmediate in
 * node), now to Date.now, hidden to "the page was hidden or the host says so".
 */
(function (global) {
  'use strict';
  var GT = (global.GT = global.GT || {});
  var S = (GT.store = {});

  S.DEBOUNCE_MS = 800;        // bursty input (§9.1.2)
  S.CACHE_MS = 2000;          // cache, recents and prefs writes (§7.5)
  S.JOURNAL_CAP = 4;          // §9.1.4 rule 4
  S.CHART_CAP = 12;           // cached charts (§7.5)
  S.RECENT_CAP = 12;          // §7.5
  S.PROMPT_FACTOR = 4;        // §9.1.3
  S.PROMPT_FLOOR_MS = 400;    // §9.1.3
  S.TRIES = 3;                // §9.2
  S.EMPTY_KEY = '∅';     // baseKey of a note with no block yet (§9.1.5)

  function B() { return GT.block; }
  function M() { return GT.model; }
  function MD() { return GT.md; }
  function D() { return GT.dates; }

  function isObj(x) { return !!x && typeof x === 'object' && !Array.isArray(x); }
  function sqlId(id) { return typeof id === 'string' && /^[A-Za-z0-9_-]+$/.test(id); }
  function has(o, k) { return !!o && Object.prototype.hasOwnProperty.call(o, k); }
  function clone(x) { return x === undefined ? undefined : JSON.parse(JSON.stringify(x)); }
  function P(v) { return Promise.resolve(v); }
  function noop() {}
  function clock() {
    var p = global.performance;
    return p && typeof p.now === 'function' ? p.now() : Date.now();
  }

  // A save is prompted when its round trip exceeds max(4 x baseline, 400 ms).
  S.isPrompted = function (ms, baselineMs) {
    if (typeof ms !== 'number' || !isFinite(ms)) return false;
    var b = typeof baselineMs === 'number' && isFinite(baselineMs) ? baselineMs : 0;
    return ms > Math.max(S.PROMPT_FACTOR * b, S.PROMPT_FLOOR_MS);
  };

  // The progress key of §7.5: cached progress is valid only for it.
  S.pk = function (settings) {
    var s = settings || {};
    return B().hash(String(s.progressSource) + '|' + String(s.progressSection) + '|' + String(s.childTasks !== false));
  };

  // same(a, b) of §9.1.5: equal canonical block keys.
  // Charts are immutable (§6.1), so the key is memoised per chart object.
  var KEYS = typeof WeakMap === 'function' ? new WeakMap() : null;
  S.keyOf = function (chart) {
    if (!chart) return null;
    if (KEYS && KEYS.has(chart)) return KEYS.get(chart);
    var k = B().key(B().serialize(chart));
    if (KEYS && typeof chart === 'object') KEYS.set(chart, k);
    return k;
  };
  S.same = function (a, b) {
    if (!a || !b) return a === b;
    return a === b || S.keyOf(a) === S.keyOf(b);
  };

  // A journal chart (JSON data) back to a chart, or null.
  function chartOf(data) {
    if (!isObj(data)) return null;
    try { return M().coerce(data).chart; } catch (e) { return null; }
  }
  S.chartOf = chartOf;

  function flipBox(line) {
    return String(line).replace(/\[( |x|X)\]/, function (m, c) { return c === ' ' ? '[x]' : '[ ]'; });
  }

  function defaultFrame() {
    if (typeof global.requestAnimationFrame === 'function') return function (f) { return global.requestAnimationFrame(f); };
    if (typeof global.setImmediate === 'function') return function (f) { return global.setImmediate(f); };
    return function (f) { return setTimeout(f, 16); };
  }
  function defaultCancel() {
    if (typeof global.cancelAnimationFrame === 'function') return function (h) { global.cancelAnimationFrame(h); };
    if (typeof global.clearImmediate === 'function') return function (h) { global.clearImmediate(h); };
    return function (h) { clearTimeout(h); };
  }

  /* ================================================================ create */

  S.create = function (opts) {
    opts = opts || {};
    var H = opts.host || GT.host;
    var now = typeof opts.now === 'function' ? opts.now : function () { return Date.now(); };
    var frame = opts.frame || defaultFrame();
    var cancelFrame = opts.cancelFrame || defaultCancel();
    var setT = opts.setTimeout || function (f, ms) { return setTimeout(f, ms); };
    var clearT = opts.clearTimeout || function (t) { clearTimeout(t); };
    var pageHidden = false;
    var hiddenFn = typeof opts.hidden === 'function' ? opts.hidden : function () {
      return pageHidden || (typeof H.visible === 'function' && !H.visible());
    };
    var embed = typeof opts.embed === 'boolean' ? opts.embed : (function () {
      try { var l = H.launch(); return !!(l && l.embed); } catch (e) { return false; }
    })();

    var st = {};
    st.id = 'st' + Math.random().toString(36).slice(2, 10) + now().toString(36);
    st.session = null;

    /* ---- launch-level state (§9.1.1) ---- */
    var L = (st.launch = {
      sessionApproved: false, mode: 'auto', savesThisLaunch: 0, lastSavePrompted: null, embed: embed
    });
    Object.defineProperty(L, 'baselineMs', {
      get: function () { return typeof H.baselineMs === 'number' ? H.baselineMs : null; }, enumerable: true
    });
    st.saveMode = function () { return L.mode; };
    st.hidden = function () { return !!hiddenFn(); };

    /* ---- events ---- */
    var listeners = {};
    st.on = function (name, cb) {
      (listeners[name] = listeners[name] || []).push(cb);
      return function () { var a = listeners[name] || [], i = a.indexOf(cb); if (i >= 0) a.splice(i, 1); };
    };
    function emit(name, arg) {
      (listeners[name] || []).slice().forEach(function (cb) { try { cb(arg); } catch (e) { /* a listener bug */ } });
    }

    /* ============================================ appState queue (§9.1.4) */

    var J = (st.journal = { map: {}, loaded: false, seen: {}, evaluations: 0 });
    var ops = {};          // chartId -> pending own op {kind:'W'|'D', entry?, failed}
    var flying = {};       // chartId -> own op in flight
    var unanswered = {};   // chartId -> true while an offered or kept entry is unanswered
    var blob = {};         // the last loaded appState (cache and prefs are read from it)
    var other = { charts: {}, recents: null, prefs: null, any: false, due: false, timer: null };
    var chain = P(), scheduled = false;

    function foreign(c, e) {
      if (!isObj(e) || e.owner === st.id) return false;
      var sn = J.seen[c];
      return !(sn && sn.owner === e.owner && sn.at === e.at);
    }
    // An own op for chart c does not replace or delete what is stored when
    // the stored entry is another store's and unseen (rule 6), or when it is
    // another store's entry that this store offers or keeps and the user has
    // not answered yet (a late check's step 6 marks it seen). An entry of this
    // store's own, or no entry, never blocks its own ops.
    function blocked(c, e) {
      return foreign(c, e) || (!!unanswered[c] && isObj(e) && e.owner !== st.id);
    }
    function applyOp(map, c, op) {
      if (op.kind === 'W') map[c] = clone(op.entry);
      else delete map[c];
    }
    function capBy(obj, cap) {
      var keys = Object.keys(obj);
      if (keys.length <= cap) return [];
      keys.sort(function (a, b) { return ((obj[a] && obj[a].at) || 0) - ((obj[b] && obj[b].at) || 0); });
      var gone = keys.slice(0, keys.length - cap);
      gone.forEach(function (k) { delete obj[k]; });
      return gone;
    }

    // Rule 5: the map is the loaded journal plus this store's own queued,
    // in-flight or failed operations (unless blocked) and cap evictions.
    function loadedIntoMap(data) {
      blob = isObj(data) ? data : {};
      var map = clone(isObj(blob.journal) ? blob.journal : {});
      var charts = {};
      Object.keys(flying).forEach(function (c) { charts[c] = 1; });
      Object.keys(ops).forEach(function (c) { charts[c] = 1; });
      Object.keys(charts).forEach(function (c) {
        [flying[c], ops[c]].forEach(function (op) { if (op && !blocked(c, map[c])) applyOp(map, c, op); });
      });
      capBy(map, S.JOURNAL_CAP);
      J.map = map;
      J.loaded = true;
    }

    function queueOp(c, op) {
      if (L.embed) return P();
      op.failed = false;
      ops[c] = op;                                   // a later op replaces a pending one
      if (!blocked(c, J.map[c])) { applyOp(J.map, c, op); capBy(J.map, S.JOURNAL_CAP); }
      return kick();
    }
    st.state = {};

    function kick() {
      if (L.embed) return P();
      if (!scheduled) {
        scheduled = true;
        chain = chain.then(function () { scheduled = false; return runOnce(); }).catch(noop);
      }
      return chain;
    }

    // The prefs of a load-merge-store in flight: prefs.get still sees them
    // until the store lands (M7: a dismissed notice never comes back mid-write).
    var otherFlying = null;
    function takeOther() {
      var o = { charts: other.charts, recents: other.recents, prefs: other.prefs };
      otherFlying = o;
      other.charts = {}; other.recents = null; other.prefs = null; other.any = false; other.due = false;
      return o;
    }
    function putBackOther(o) {
      if (otherFlying === o) otherFlying = null;
      Object.keys(o.charts).forEach(function (c) { if (!has(other.charts, c)) other.charts[c] = o.charts[c]; });
      if (o.recents && !other.recents) other.recents = o.recents;
      if (o.prefs) other.prefs = Object.assign({}, o.prefs, other.prefs || {});
      scheduleOther();                        // retried after the debounce
    }
    function mergeRecents(mine, theirs) {
      var out = [], seenIds = {};
      (mine || []).concat(Array.isArray(theirs) ? theirs : []).forEach(function (r) {
        if (!isObj(r) || typeof r.id !== 'string' || seenIds[r.id]) return;
        seenIds[r.id] = 1;
        out.push(r);
      });
      out.sort(function (a, b) { return (b.at || 0) - (a.at || 0); });
      return out.slice(0, S.RECENT_CAP);
    }
    function mergeOther(out, o) {
      var names = Object.keys(o.charts);
      if (names.length) {
        out.charts = isObj(out.charts) ? out.charts : {};
        names.forEach(function (c) { if (o.charts[c] === null) delete out.charts[c]; else out.charts[c] = clone(o.charts[c]); });
        capBy(out.charts, S.CHART_CAP);
      }
      if (o.recents) {
        var dropped = o.recents.dropped || [];
        out.recents = mergeRecents(o.recents.list, (Array.isArray(out.recents) ? out.recents : []).filter(function (r) {
          return isObj(r) && dropped.indexOf(r.id) < 0;
        }));
      }
      if (o.prefs) out.prefs = Object.assign({}, isObj(out.prefs) ? out.prefs : {}, clone(o.prefs));
    }

    // One load-merge-store (rules 2 and 3): every pending journal op plus the
    // cache, recents and prefs writes when they are due.
    function runOnce() {
      var batch = {}, cs = Object.keys(ops).filter(function (c) { return !blocked(c, J.map[c]); });
      var o = other.any && other.due ? takeOther() : null;
      if (!cs.length && !o) return P();
      cs.forEach(function (c) { batch[c] = ops[c]; delete ops[c]; flying[c] = batch[c]; });
      function requeue(list, failed) {
        list.forEach(function (c) {
          if (flying[c] === batch[c]) delete flying[c];
          if (!ops[c]) { ops[c] = batch[c]; ops[c].failed = failed; }
        });
      }
      return H.loadState().then(function (r) {
        if (!r.ok) {                                    // a failed load aborts the write
          requeue(cs, true);
          if (o) putBackOther(o);
          return;
        }
        var data = isObj(r.data) ? r.data : {};
        var out = clone(data), journal = isObj(out.journal) ? out.journal : {};
        var applied = [], held = [];
        cs.forEach(function (c) {
          if (blocked(c, journal[c])) held.push(c);
          else { applyOp(journal, c, batch[c]); applied.push(c); }
        });
        capBy(journal, S.JOURNAL_CAP);
        out.journal = journal;
        out.v = 1;
        if (o) mergeOther(out, o);
        requeue(held, false);
        loadedIntoMap(data);
        if (!applied.length && !o) return afterRefresh();
        return H.storeState(out).then(function (w) {
          if (w.ok) {
            applied.forEach(function (c) { if (flying[c] === batch[c]) delete flying[c]; });
            blob = out;
            if (o && otherFlying === o) otherFlying = null;
          } else {
            requeue(applied, true);
            if (o) putBackOther(o);
          }
          return afterRefresh();
        });
      });
    }

    function scheduleOther() {
      if (L.embed) return;
      other.any = true;
      if (other.timer !== null) return;
      other.timer = setT(function () { other.timer = null; other.due = true; kick(); }, S.CACHE_MS);
    }
    // state.write({charts:{id: entry|null}, recents, prefs}, {now}) queues
    // writes of the keys this store owns; they ride the next load-merge-store.
    st.state.write = function (keys, o2) {
      if (L.embed || !isObj(keys)) return P();
      if (isObj(keys.charts)) Object.keys(keys.charts).forEach(function (c) { other.charts[c] = keys.charts[c]; });
      if (keys.recents) other.recents = keys.recents;
      if (isObj(keys.prefs)) other.prefs = Object.assign({}, other.prefs || {}, keys.prefs);
      scheduleOther();
      return o2 && o2.now ? st.state.flush() : P();
    };
    // Runs every pending write now (cancels the 2 s debounce).
    st.state.flush = function () {
      if (L.embed) return P();
      if (other.timer !== null) { clearT(other.timer); other.timer = null; }
      if (other.any) other.due = true;
      return kick();
    };
    // Resolves when the queue has nothing running.
    st.state.idle = function () {
      var c = chain;
      return c.then(function () { return c === chain ? undefined : st.state.idle(); });
    };
    st.state.pending = function () {
      return { journal: Object.keys(ops).map(function (c) { return { chart: c, kind: ops[c].kind, failed: ops[c].failed }; }), flying: Object.keys(flying), other: other.any };
    };
    st.state.blob = function () { return blob; };

    /* ================================================= journal (§9.1.5) */

    // The entry to show for a chart: the map's, except that this store's own
    // pending W comes first while the map shows another owner's entry (rule 6
    // keeps the own W out of the map); the other entry waits behind it.
    function ownPendingW(c) { var o = ops[c] || flying[c]; return o && o.kind === 'W' ? o : null; }
    function shownEntry(c) {
      var e = has(J.map, c) ? J.map[c] : null, own = ownPendingW(c);
      return e && e.owner !== st.id && own ? own.entry : e;
    }
    J.pendingForNote = function (id) { return shownEntry(id); };
    J.hasOwnOp = function (c) { return !!(ops[c] || flying[c]); };

    // Rule 5 refresh: a fresh loadAppState into the map. quiet: the caller
    // (open) runs checkOnOpen itself instead of the rule 6 handling.
    J.refresh = function (quiet) {
      return H.loadState().then(function (r) {
        if (!r.ok) return { ok: false, error: r.error };
        loadedIntoMap(r.data);
        if (quiet || L.embed) return { ok: true };
        return afterRefresh().then(function () { return { ok: true }; });
      });
    };

    function entryOf(s) {
      return {
        at: now(), owner: st.id, baseKey: s.key,
        base: M().toData(s.base || M().empty()), chart: M().toData(s.live)
      };
    }
    // Evaluate: D when live equals base, else W. A no-op for an embed or
    // under hold. A D with nothing stored or queued for the chart is skipped.
    J.evaluate = function (s) {
      s = s || st.session;
      J.evaluations++;
      if (L.embed || !s || s.journalHold || !s.live) return null;
      var c = s.noteId;
      if (S.same(s.live, s.base)) {
        if (!has(J.map, c) && !ops[c] && !flying[c]) return 'none';
        queueOp(c, { kind: 'D' });
        return 'D';
      }
      queueOp(c, { kind: 'W', entry: entryOf(s) });
      return 'W';
    };
    J.reschedule = function (s) {
      s = s || st.session;
      if (L.embed || !s) return;
      if (s.journalFrame !== null) cancelFrame(s.journalFrame);
      s.journalFrame = frame(function () { s.journalFrame = null; J.evaluate(s); });
    };

    function markSeen(c, e) { if (isObj(e)) J.seen[c] = { owner: e.owner, at: e.at }; }

    // Open steps 1 to 6 (steps 0 and 2 are in open(), which opens no session).
    J.checkOnOpen = function (s, fr) {
      s.checkedOnce = true;
      s.checkFailed = false;
      s.openRead = fr;
      if (L.embed) { s.journalHold = false; return { kind: 'embed' }; }
      var c = s.noteId, e = has(J.map, c) ? J.map[c] : null;
      delete unanswered[c];
      s.offer = null; s.kept = null;
      // The map shows another store's entry while this store still has its
      // own W for the chart pending (blocked by rule 6): offer the own W
      // first and defer the other entry, as afterRefresh does, so a switch
      // away and back never answers the other entry with the own W unseen.
      var own = ops[c] || flying[c];
      var ownFirst = !!e && e.owner !== st.id && !!own && own.kind === 'W';
      if (ownFirst) e = own.entry;
      if (!e) {                                                  // step 1
        s.journalHold = false;
        kick();
        emit('ui');
        return { kind: 'none' };
      }
      markSeen(c, e);
      if (ownFirst) s.foreignPending = true;
      if (!fr || fr.status !== 'ok') {                            // step 3
        s.kept = e;
        unanswered[c] = true;
        emit('ui');
        return { kind: 'kept', entry: e };
      }
      var ec = chartOf(e.chart), eb = chartOf(e.base) || M().empty();
      // Steps 4 and 5 drop the entry; a deferred other entry is handled now.
      function dropped(step) {
        s.journalHold = false;
        queueOp(c, { kind: 'D' });
        emit('ui');
        var out = { kind: 'dropped', step: step };
        if (ownFirst) out.deferred = afterRefresh();
        return out;
      }
      if (!ec || B().key(B().serialize(ec)) === fr.key) return dropped(4);   // step 4
      var r = M().merge3(eb, ec, fr.chart);
      if (!r.conflicts.length && M().sameIgnoringTitles(r.chart, fr.chart)) return dropped(5);   // step 5
      s.offer = { entry: e, r: r, late: false };                 // step 6
      unanswered[c] = true;
      emit('ui');
      return { kind: 'offer', offer: s.offer };
    };

    // Late check (Other instances): steps 4 to 6 against s.live.
    function lateCheck(s, e) {
      var c = s.noteId;
      markSeen(c, e);
      delete unanswered[c];
      var ec = chartOf(e.chart), eb = chartOf(e.base) || M().empty();
      if (!ec || S.keyOf(ec) === S.keyOf(s.live)) {
        s.journalHold = false;
        J.evaluate(s);
        emit('ui');
        return { kind: 'late-match', step: 4 };
      }
      var r = M().merge3(eb, ec, s.live);
      if (!r.conflicts.length && M().sameIgnoringTitles(r.chart, s.live)) {
        s.journalHold = false;
        J.evaluate(s);
        emit('ui');
        return { kind: 'late-match', step: 5 };
      }
      s.journalHold = true;
      s.offer = { entry: e, r: r, late: true };
      unanswered[c] = true;
      emit('ui');
      return { kind: 'offer', offer: s.offer, late: true };
    }

    function closeSheet() {
      var s = st.session;
      if (s && s.sheet) { s.sheet = null; emit('sheet', null); }
    }

    // Re-open: re-read the note, then the open row and checkOnOpen.
    function reopen(s) {
      s.journalHold = true;
      s.offer = null; s.kept = null;
      emit('ui');
      return H.readNote(s.noteId).then(function (r) {
        if (st.session !== s) return null;
        var e = J.map[s.noteId];
        // A failed re-read: late-check the entry against live; with no entry
        // left (a concurrent refresh removed it) run the open steps again on
        // the open-time read, which clears the hold.
        if (!r.ok) return e ? lateCheck(s, e) : J.checkOnOpen(s, s.openRead);
        var fr = B().read(r.content);
        initFrom(s, fr);
        emit('live', { reopen: true });
        if (fr.status === 'none') {
          markSeen(s.noteId, e);
          s.kept = e || null;
          if (e) unanswered[s.noteId] = true;
          emit('ui');
          return { kind: 'kept', entry: e };
        }
        return J.checkOnOpen(s, fr);
      });
    }

    // After every successful refresh: rule 6 for the open chart.
    function afterRefresh() {
      var s = st.session;
      if (!s || L.embed) return P();
      if (!s.checkedOnce && !s.lateArmed) {
        return P();
      }
      var c = s.noteId, e = has(J.map, c) ? J.map[c] : null;
      if (e && foreign(c, e)) {
        if (s.writing !== null || s.busy) { s.foreignPending = true; return P(); }
        // This store is offering (or keeping) its OWN entry, whose edits are
        // not in s.live yet: a late check now would merge the other entry
        // against the note chart and the own edits would be replaced by the
        // answer. Defer until the own offer is answered (Restore or Discard
        // run afterRefresh again), so the late check sees live with them.
        var own = (s.offer && s.offer.entry.owner === st.id) || (s.kept && s.kept.owner === st.id);
        if (own) { s.foreignPending = true; return P(); }
        s.foreignPending = false;
        closeSheet();
        var armed = s.lateArmed;
        s.lateArmed = false;
        if (!armed && !J.hasOwnOp(c) && S.same(s.live, s.base)) return reopen(s);
        return P(lateCheck(s, e));
      }
      s.foreignPending = false;               // the other entry is gone or answered
      if (s.lateArmed) { s.lateArmed = false; kick(); }
      return P();
    }

    // Restore: merge3(entry.base, entry.chart, live, {resolutions}); with
    // conflicts the sheet opens first, still under hold.
    J.restore = function (resolutions) {
      var s = st.session;
      if (!s || !s.offer) return { ok: false, reason: 'no-offer' };
      if (resolutions && (!s.sheet || s.sheet.offer !== s.offer)) return { ok: false, reason: 'no-sheet' };
      var e = s.offer.entry;
      var r = M().merge3(chartOf(e.base) || M().empty(), chartOf(e.chart), s.live, { resolutions: resolutions || undefined });
      if (r.conflicts.length) {
        s.sheet = { offer: s.offer, conflicts: r.conflicts };
        emit('sheet', s.sheet);
        return { ok: false, reason: 'conflict', conflicts: r.conflicts };
      }
      markSeen(s.noteId, e);
      delete unanswered[s.noteId];
      s.live = r.chart;
      s.offer = null; s.sheet = null; s.journalHold = false;
      J.reschedule(s);
      emit('live', { restore: true });
      emit('ui');
      var out = { ok: true, clearUndo: true, save: null };
      if (L.mode === 'auto') out.save = requestSave(s, {}, false);
      // A foreign entry deferred behind this (own) offer is handled now, or
      // after the save above ends (requestSave runs afterRefresh then).
      if (s.foreignPending) out.deferred = afterRefresh();
      return out;
    };
    // Cancelling the conflict sheet changes nothing; the hold stays.
    J.cancelSheet = function () { closeSheet(); return { ok: true }; };

    // Discard: D, then evaluate (a late check keeps the session's edits).
    J.discard = function (noteId) {
      var s = st.session;
      if (s && (!noteId || noteId === s.noteId) && s.offer) {
        var c = s.noteId;
        markSeen(c, s.offer.entry);
        delete unanswered[c];
        s.offer = null; s.sheet = null; s.journalHold = false;
        queueOp(c, { kind: 'D' });
        // Evaluate at once, so after a late check the W of live replaces the
        // pending D before the queue runs (the D is never stored first).
        if (s.journalFrame !== null) { cancelFrame(s.journalFrame); s.journalFrame = null; }
        J.evaluate(s);
        emit('ui');
        var res = { ok: true };
        if (s.foreignPending) res.deferred = afterRefresh();
        return res;
      }
      // An entry with no session: a deleted chart note or a block that is gone.
      if (noteId && has(J.map, noteId) && !(s && s.noteId === noteId)) {
        // The shown entry is this store's own pending W (another owner's
        // entry waits behind it): drop only the own W; the other entry stays
        // stored, unseen, and is shown next.
        var mapE = J.map[noteId];
        if (mapE.owner !== st.id && ops[noteId] && ops[noteId].kind === 'W' && !flying[noteId]) {
          delete ops[noteId];
          emit('ui');
          return { ok: true, own: true };
        }
        markSeen(noteId, J.map[noteId]);
        delete unanswered[noteId];
        queueOp(noteId, { kind: 'D' });
        return { ok: true };
      }
      return { ok: false, reason: 'no-offer' };
    };
    // "Couldn't check for unsaved changes": Retry and Edit anyway.
    J.retry = function () {
      var s = st.session;
      if (!s || !s.checkFailed) return P({ kind: 'noop' });
      return J.refresh(true).then(function (r) {
        if (st.session !== s) return { kind: 'superseded' };
        if (!r.ok) { emit('ui'); return { kind: 'check-failed' }; }
        return J.checkOnOpen(s, s.openRead);
      });
    };
    J.editAnyway = function () {
      var s = st.session;
      if (!s || !s.checkFailed) return { ok: false };
      s.checkFailed = false;
      s.journalHold = false;
      s.lateArmed = true;
      // Rule 6 applies to this session from now on, also after the armed
      // late check disarms.
      s.checkedOnce = true;
      emit('ui');
      return { ok: true };
    };

    /* ============================================================ sessions */

    function newSession(noteId) {
      var s = {
        noteId: noteId, status: 'none', region: null, key: null, base: null, live: null, writing: null,
        conflictRead: null, embedOutside: false, extra: 0, readOnly: false, journalHold: !L.embed,
        offer: null, kept: null, sheet: null, queued: false, pendingDates: [], journalFrame: null,
        facts: {}, factPk: null, title: '', busy: null, debounce: null, lateArmed: false,
        checkFailed: false, checkedOnce: false, foreignPending: false, openRead: null, lastResult: null,
        resolved: P(null), checked: P(null),
        // M9: the chart note's text from the last read (null once a save
        // agreed), the block key of the last region this store wrote (the
        // reconciliation banner), the note's {u, l} at that read (resume).
        lastText: null, wroteKey: null, stamp: null, factsSig: null, readKey: null
      };
      s.summaries = function (chart) {
        chart = chart || s.live;
        var set = chart ? chart.settings : {}, today = D().today(now());
        return function (task) { return M().summarize(task.note ? (s.facts[task.note] || null) : null, task, set, today); };
      };
      return s;
    }
    // The open row: live = base = the note chart, key, region, writing null.
    function initFrom(s, fr) {
      s.status = fr.status;
      s.region = fr.region ? fr.region.text : null;
      s.key = fr.key;
      s.base = fr.chart || null;
      s.live = fr.chart || null;
      s.writing = null;
      s.conflictRead = null;
      s.embedOutside = !!fr.embedOutside;
      s.extra = fr.extra || 0;
      s.readOnly = fr.status === 'future';
    }
    function stopSession(s) {
      if (!s) return;
      if (s.debounce !== null) { clearT(s.debounce); s.debounce = null; }
      if (s.journalFrame !== null) { cancelFrame(s.journalFrame); s.journalFrame = null; J.evaluate(s); }
    }
    function canEdit(s) { return !!s && !L.embed && !s.journalHold && !s.readOnly && s.status === 'ok' && !!s.live; }
    st.canEdit = function () { return canEdit(st.session); };

    /* ---- facts and cache (§7.5) ---- */

    function factToCache(f) {
      var o = { u: f.updatedAt, l: f.clen, t: f.title, ty: f.type, st: f.status, a: !!f.archived };
      if (f.missing) o.m = 1;
      if (f.prog) {
        o.src = f.prog.src;
        o.p = [f.prog.done, f.prog.total];
        o.b = f.prog.bits || '';
        if (f.prog.found === false) o.f = 0;
        if (f.prog.partial) o.pp = 1;
        if (f.prog.child) o.c = [f.prog.child.done, f.prog.child.total, f.prog.child.bits || ''];
      }
      return o;
    }
    function factFromCache(c) {
      var f = {
        title: typeof c.t === 'string' ? c.t : '', type: c.ty === 'task' ? 'task' : 'note', status: c.st || null,
        archived: !!c.a, missing: !!c.m, updatedAt: typeof c.u === 'number' ? c.u : null, clen: typeof c.l === 'number' ? c.l : null,
        sched: null, due: null, prog: null, cached: true
      };
      if (typeof c.src === 'string' && Array.isArray(c.p)) {
        f.prog = { src: c.src, done: c.p[0] | 0, total: c.p[1] | 0, bits: typeof c.b === 'string' ? c.b : '', found: c.f !== 0, partial: !!c.pp, child: null };
        if (Array.isArray(c.c)) f.prog.child = { done: c.c[0] | 0, total: c.c[1] | 0, bits: typeof c.c[2] === 'string' ? c.c[2] : '' };
      }
      return f;
    }
    var cacheLocal = {};
    st.cache = {
      get: function (c) {
        if (has(cacheLocal, c)) return cacheLocal[c];
        return isObj(blob.charts) && isObj(blob.charts[c]) ? blob.charts[c] : null;
      },
      put: function (c, entry) {
        if (L.embed) return;
        cacheLocal[c] = entry;
        var w = {}; w[c] = entry;
        st.state.write({ charts: w });
      },
      setView: function (c, view) {
        var cur = st.cache.get(c);
        var e = Object.assign({}, cur || { at: now(), facts: {} }, { view: clone(view), at: now() });
        st.cache.put(c, e);
      },
      flush: function () { return st.state.flush(); }
    };
    function paintFromCache(s) {
      var c = st.cache.get(s.noteId);
      if (!c || !isObj(c.facts) || !s.live) return;
      var pkNow = S.pk(s.live.settings), pkOk = c.pk === pkNow;
      s.live.tasks.forEach(function (t) {
        if (!t.note || !isObj(c.facts[t.note])) return;
        var f = factFromCache(c.facts[t.note]);
        if (!pkOk || (f.prog && f.prog.src !== M().sourceOf(t, s.live.settings))) f.prog = null;
        s.facts[t.note] = f;
      });
      s.factPk = pkOk ? pkNow : null;
    }
    function cachePut(s) {
      if (L.embed || !s.live || s.status !== 'ok') return;
      var facts = {};
      s.live.tasks.forEach(function (t) { var f = t.note && s.facts[t.note]; if (f) facts[t.note] = factToCache(f); });
      var prev = st.cache.get(s.noteId);
      var region = B().hash(s.region || '');
      // Nothing changed since the last write (a resume that found nothing
      // new): no appState round trip.
      var wk = s.wroteKey || (prev && typeof prev.wk === 'string' ? prev.wk : null);
      if (prev && prev.pk === s.factPk && prev.region === region && (prev.wk || null) === wk && JSON.stringify(prev.facts) === JSON.stringify(facts)) return;
      var entry = { at: now(), region: region, pk: s.factPk, facts: facts, view: prev && prev.view ? prev.view : null };
      if (wk) entry.wk = wk;
      st.cache.put(s.noteId, entry);
    }

    function progOf(cl, partial) {
      return { src: 'checklist', done: cl.done, total: cl.total, bits: cl.bits, found: cl.found, partial: !!partial, child: null };
    }
    // A §7.4 window, or null when the paged fallback is needed.
    function fromWindow(w, section) {
      var cl = MD().checklist(w.win, section);
      if (w.whole) return progOf(cl, false);
      var atEnd = w.off - 1 + Array.from(w.win).length >= w.clen;
      if (!cl.found) return atEnd && w.off === 1 ? progOf(cl, false) : null;
      var sec = MD().findSection(w.win, section);
      if (atEnd || sec.bodyEnd < w.win.split('\n').length) return progOf(cl, false);
      return null;
    }

    /*
     * resolve(s, {ids}): steps 2 to 5 of §7.5. Query 7.1 in chunks of 99;
     * 7.2 and 7.3 for the subnotes source (always re-run); 7.4 for stale
     * checklist notes, with the paged fallback. A failed read resolves
     * nothing. -> {ok, calls}
     */
    st.resolve = function (s, o) {
      s = s || st.session;
      o = o || {};
      if (!s || !s.live) return P({ ok: false, calls: 0 });
      var chart = s.live, set = chart.settings, pkNow = S.pk(set);
      var tasks = chart.tasks.filter(function (t) { return t.note && sqlId(t.note); });
      if (Array.isArray(o.ids)) tasks = tasks.filter(function (t) { return o.ids.indexOf(t.note) >= 0; });
      var ids = tasks.map(function (t) { return t.note; });
      var calls = 0, pkChanged = s.factPk !== pkNow, changed = {}, ok = true, probeRow = null;
      // M9 (§7.6 tuning): o.probe, a note id (the chart note) read in the
      // same 7.1 query; its {u, l} comes back as `probe`, not as a fact.
      var probe = o.probe && sqlId(o.probe) ? o.probe : null, extra = probe && ids.indexOf(probe) < 0;
      if (!ids.length && !probe) { s.factPk = pkNow; return P({ ok: true, calls: 0 }); }
      return H.meta(extra ? ids.concat([probe]) : ids).then(function (mr) {
        calls += mr.calls || 0;
        if (!mr.ok) ok = false;
        var pr = null;
        if (probe && mr.ok && mr.rows && mr.rows[probe]) pr = { u: mr.rows[probe].updatedAt, l: mr.rows[probe].clen };
        else if (probe && mr.ok && (mr.missing || []).indexOf(probe) >= 0) pr = { missing: true };
        if (extra) {
          mr = Object.assign({}, mr, { rows: Object.assign({}, mr.rows || {}), missing: (mr.missing || []).filter(function (x) { return x !== probe; }) });
          delete mr.rows[probe];
        }
        probeRow = pr;
        Object.keys(mr.rows || {}).forEach(function (id) {
          var row = mr.rows[id], f = s.facts[id] || {};
          if (f.updatedAt !== row.updatedAt || f.clen !== row.clen || f.missing) changed[id] = true;
          s.facts[id] = {
            title: row.title, type: row.type, status: row.status, archived: row.isArchived, missing: false,
            sched: row.scheduledAt, due: row.completeBy, updatedAt: row.updatedAt, clen: row.clen, prog: f.prog || null
          };
        });
        (mr.missing || []).forEach(function (id) {
          var f = s.facts[id] || {};
          s.facts[id] = { title: f.title || '', type: f.type || 'note', status: null, archived: false, missing: true, updatedAt: null, clen: null, prog: null };
        });
        var alive = tasks.filter(function (t) { var f = s.facts[t.note]; return f && !f.missing && (mr.failed || []).indexOf(t.note) < 0 && f.updatedAt !== undefined && !f.cached; });
        var sub = alive.filter(function (t) { return M().sourceOf(t, set) === 'subnotes'; }).map(function (t) { return t.note; });
        var chk = alive.filter(function (t) {
          if (M().sourceOf(t, set) !== 'checklist') return false;
          var f = s.facts[t.note];
          return pkChanged || changed[t.note] || !f.prog || f.prog.src !== 'checklist';
        }).map(function (t) { return t.note; });
        var step = P();
        if (sub.length) {
          step = step.then(function () { return H.subnoteCounts(sub); }).then(function (c) {
            calls += c.calls || 0;
            var want = set.childTasks !== false;
            return (want ? H.childCounts(sub) : P(null)).then(function (k) {
              if (k) calls += k.calls || 0;
              if (!c.ok || (k && !k.ok)) ok = false;
              sub.forEach(function (id) {
                var n = c.counts && c.counts[id];
                if (!n || !s.facts[id]) return;
                var ch = k ? (k.counts && k.counts[id]) || null : null;
                s.facts[id].prog = { src: 'subnotes', done: n.done, total: n.total, bits: n.bits, found: true, partial: false, child: ch };
              });
            });
          });
        }
        if (chk.length) {
          var section = set.progressSection;
          step = step.then(function () { return H.checklistWindows(chk, section); }).then(function (w) {
            calls += w.calls || 0;
            if (!w.ok) ok = false;
            var pages = [];
            chk.forEach(function (id) {
              var win = w.windows && w.windows[id];
              if (!win || !s.facts[id]) return;
              var p = fromWindow(win, section);
              if (p) s.facts[id].prog = p;
              else pages.push({ id: id, off: win.off });
            });
            return pages.reduce(function (acc, pg) {
              return acc.then(function () {
                return H.readPaged(pg.id, pg.off).then(function (r) {
                  calls += r.pages || 0;
                  if (!r.ok) { ok = false; return; }
                  s.facts[pg.id].prog = progOf(MD().checklist(r.text, section), !r.complete);
                });
              });
            }, P());
          });
        }
        return step;
      }).then(function () {
        tasks.forEach(function (t) { var f = s.facts[t.note]; if (f) delete f.cached; });
        if (ok) s.factPk = pkNow;
        if (st.session === s) {
          cachePut(s);
          // M9 (§7.6 tuning): a resolve that found nothing new (a resume
          // over unchanged notes) re-renders nothing.
          var sig = JSON.stringify([s.factPk, ok, s.facts]);
          if (sig !== s.factsSig) { s.factsSig = sig; emit('facts', s); }
        }
        return { ok: ok, calls: calls, probe: probeRow };
      });
    };

    /* ---- recents and prefs ---- */

    function recentsNow() {
      var list = other.recents ? other.recents.list : [];
      var dropped = other.recents ? other.recents.dropped : [];
      return mergeRecents(list, (Array.isArray(blob.recents) ? blob.recents : []).filter(function (r) { return isObj(r) && dropped.indexOf(r.id) < 0; }));
    }
    st.recents = recentsNow;
    function touchRecent(id, title, drop) {
      if (L.embed) return;
      var cur = other.recents || { list: [], dropped: [] };
      var list = cur.list.filter(function (r) { return r.id !== id; });
      var dropped = cur.dropped.filter(function (x) { return x !== id; });
      if (drop) dropped.push(id);
      else {
        var old = recentsNow().filter(function (r) { return r.id === id; })[0];
        list.unshift({ id: id, title: title || (old && old.title) || '', at: now() });
      }
      st.state.write({ recents: { list: list.slice(0, S.RECENT_CAP), dropped: dropped } });
    }
    st.prefs = {
      all: function () { return Object.assign({}, isObj(blob.prefs) ? blob.prefs : {}, (otherFlying && otherFlying.prefs) || {}, other.prefs || {}); },
      get: function (k) { return st.prefs.all()[k]; },
      set: function (patch) { return st.state.write({ prefs: patch }); }
    };

    /* ================================================================ open */

    /*
     * open(target): target is a note id or a route result {noteId, read?,
     * title?}. The §7.5 open sequence: the session is created held (step 0),
     * painted from the chart plus cached facts (step 1), resolved in the
     * background (steps 2 to 5, s.resolved), and checkOnOpen runs once this
     * open's refresh resolves (step 6, s.checked).
     * -> {ok, session} | {ok:false, reason:'missing'|'none'|'read-failed'|'bad-id', entry}
     */
    st.open = function (target) {
      if (typeof target === 'string') target = { noteId: target };
      target = target || {};
      var noteId = target.noteId;
      if (!sqlId(noteId)) return P({ ok: false, reason: 'bad-id' });
      stopSession(st.session);
      var s = newSession(noteId);
      st.session = s;
      var fr0 = target.read && target.read.status ? target.read : null;
      var readP = fr0 ? P({ ok: true, fr: fr0, text: typeof target.text === 'string' ? target.text : null }) : H.readNote(noteId).then(function (r) {
        return r.ok ? { ok: true, fr: B().read(r.content), text: r.content, stamp: { u: r.updatedAt, l: r.clen } } : { ok: false, r: r };
      });
      return readP.then(function (rd) {
        if (st.session !== s) return { ok: false, reason: 'superseded' };
        if (!rd.ok || rd.fr.status === 'none') {
          st.session = null;
          var reason = !rd.ok ? (rd.r.missing ? 'missing' : 'read-failed') : 'none';
          if (L.embed || reason === 'read-failed') return { ok: false, reason: reason, entry: null };
          return J.refresh(true).then(function () {
            var e = shownEntry(noteId);             // the own pending W first (rule 6)
            if (e) unanswered[noteId] = true;
            if (reason === 'missing' && !e) touchRecent(noteId, '', true);
            emit('ui');
            return { ok: false, reason: reason, entry: e };
          });
        }
        var fr = rd.fr;
        initFrom(s, fr);
        s.openRead = fr;
        // M9: the text and stamp of this read (reconciliation, resume), and
        // the block key this store last wrote, kept in the cache (wk).
        s.lastText = rd.text;
        s.stamp = rd.stamp || null;
        s.readKey = fr.key;
        var ce = st.cache.get(noteId);
        s.wroteKey = ce && typeof ce.wk === 'string' ? ce.wk : null;
        s.title = typeof target.title === 'string' ? target.title : '';
        paintFromCache(s);
        if (!L.embed && fr.status === 'ok') touchRecent(noteId, s.title, false);
        s.resolved = s.live ? st.resolve(s) : P(null);
        s.checked = L.embed ? P({ kind: 'embed' }) : J.refresh(true).then(function (r) {
          if (st.session !== s) return { kind: 'superseded' };
          if (!r.ok) { s.checkFailed = true; emit('ui'); return { kind: 'check-failed' }; }
          return J.checkOnOpen(s, fr);
        });
        emit('live', { open: true });
        return { ok: true, session: s };
      });
    };

    /* ================================================== commits and saves */

    function queueDates(s, prev, next) {
      if (!next.settings.syncDates) return;
      next.tasks.forEach(function (t) {
        if (!t.note || t.start === null) return;
        var o = M().task(prev, t.id);
        if (o && o.start === t.start && o.end === t.end && o.milestone === t.milestone) return;
        var f = s.facts[t.note];
        if (!f || f.type !== 'task') return;
        s.pendingDates = s.pendingDates.filter(function (d) { return d.id !== t.note; });
        s.pendingDates.push({ id: t.note, scheduledAt: D().toHost(t.start), completeBy: D().toHost(t.end !== null ? t.end : t.start) });
      });
    }

    /*
     * commit(chart, {save}): the commit row (live = new chart, evaluate).
     * save: 'now' (default, a gesture commit), 'debounce' (bursty input) or
     * 'none'. Refused (false) under hold, read-only or in an embed.
     */
    st.commit = function (next, o) {
      var s = st.session;
      o = o || {};
      if (!canEdit(s) || !next) return false;
      var prev = s.live;
      next = M().titlesFrom(next, s.facts);
      s.live = next;
      queueDates(s, prev, next);
      var srcChanged = S.pk(prev.settings) !== S.pk(next.settings) || next.tasks.some(function (t) {
        var p = M().task(prev, t.id);
        return !p || M().sourceOf(p, prev.settings) !== M().sourceOf(t, next.settings);
      });
      if (S.pk(prev.settings) !== S.pk(next.settings)) {
        Object.keys(s.facts).forEach(function (id) { if (s.facts[id]) s.facts[id].prog = null; });
        s.factPk = null;
      }
      J.reschedule(s);
      if (srcChanged) s.resolved = st.resolve(s);
      var mode = o.save || 'now';
      if (mode === 'debounce') st.scheduleSave();
      else if (mode === 'now' && L.mode === 'auto') requestSave(s, {}, false);
      return true;
    };
    // scheduleSave(chart?): commit a burst edit, or re-arm the 800 ms debounce.
    st.scheduleSave = function (chart) {
      if (chart) return st.commit(chart, { save: 'debounce' });
      var s = st.session;
      if (!s || L.mode !== 'auto') return false;
      if (s.debounce !== null) clearT(s.debounce);
      s.debounce = setT(function () { s.debounce = null; requestSave(s, {}, false); }, S.DEBOUNCE_MS);
      return true;
    };
    // Flush: cancel the debounce and save the latest chart now (auto only).
    st.flush = function () {
      var s = st.session;
      if (!s) return P(null);
      var pending = s.debounce !== null;
      if (pending) { clearT(s.debounce); s.debounce = null; }
      if (L.mode !== 'auto' || !canEdit(s)) return P(null);
      if (!pending && !s.busy && S.same(s.live, s.base) && !s.pendingDates.length) return P(null);
      return requestSave(s, {}, false);
    };

    // One save in flight per session; a save asked for meanwhile coalesces
    // to the latest chart (auto) and runs after it.
    function requestSave(s, o, explicit) {
      if (!s) return P({ ok: false, reason: 'no-session' });
      if (s.journalHold) return P({ ok: false, reason: 'held' });
      if (s.busy) {
        if (explicit) return s.busy.then(function () { return requestSave(s, o, true); });
        s.queued = true;
        return s.busy;
      }
      var first = o || {};
      function once() {
        s.queued = false;
        return saveCore(s, first).then(function (r) {
          first = {};
          if (s.queued && r.ok && L.mode === 'auto' && !s.journalHold && st.session === s) return once();
          return r;
        });
      }
      s.busy = once().then(function (r) {
        s.busy = null;
        s.queued = false;
        s.lastResult = r;
        emit('save', r);
        emit('ui');
        if (s.foreignPending && st.session === s) afterRefresh();
        return r;
      });
      emit('ui');
      return s.busy;
    }
    // The pill tap, and saveOnce(session, opts) of §4.2 (serialised).
    st.save = function (o) { return requestSave(st.session, o || {}, true); };
    st.saveOnce = function (s, o) { return requestSave(s || st.session, o || {}, true); };

    function forced(o, what) { return !!o && o.force === what; }
    function fail(s, reason, merged) {
      s.writing = null;
      return { ok: false, reason: reason, merged: merged || null, conflicts: merged ? merged.conflicts : [] };
    }
    function agree(s, text) {
      s.region = text;
      s.base = s.writing;
      s.key = S.keyOf(s.writing);
      s.writing = null;
      s.conflictRead = null;
      s.status = 'ok';
      s.extra = 0;
      // M9: the note now holds exactly this region (a full mirror); the next
      // resume reads it again, since its updatedAt is not known here.
      s.wroteKey = s.key;
      s.lastText = null;
      s.stamp = null;
      J.reschedule(s);
      return { ok: true };
    }
    function rebase(s, fr, chart) {
      s.live = chart;
      s.base = fr.chart;
      s.key = fr.key;
      s.writing = null;
      s.conflictRead = null;
      J.reschedule(s);
      emit('live', { rebase: true });
    }
    function denied() {
      if (hiddenFn()) return 'denied-hidden';
      L.mode = 'paused';
      emit('mode', L.mode);
      return 'denied';
    }
    // §9.1.3 detector, after a write the host accepted.
    function detect(ms, base0) {
      var prompted = S.isPrompted(ms, base0);
      var n = L.savesThisLaunch++;
      L.lastSavePrompted = prompted;
      var before = L.mode;
      if (L.mode === 'auto') {
        if (n >= 1 && !L.sessionApproved) {
          if (prompted) L.mode = 'manual';
          else L.sessionApproved = true;
        }
      } else if (prompted) L.mode = 'manual';
      else { L.sessionApproved = true; L.mode = 'auto'; }
      if (before !== L.mode) emit('mode', L.mode);
    }
    function absorb(s, fr, o) {
      if (fr.status === 'future') { s.readOnly = true; s.status = 'future'; return fail(s, 'read-only'); }
      if (fr.extra && !forced(o, 'extra')) return fail(s, 'extra');
      if (fr.status === 'malformed' && !forced(o, 'malformed')) return fail(s, 'malformed');
      if (fr.status === 'none') return fail(s, s.region ? 'removed' : 'write-failed');
      if (fr.key !== s.key && fr.chart) {
        var mine = s.writing || s.live;
        var res = o.resolutions || undefined;
        var m = M().merge3(s.base || M().empty(), mine, fr.chart, { resolutions: res });
        if (m.conflicts.length) { s.conflictRead = fr; return fail(s, 'conflict', m); }
        var r = M().merge3(mine, s.live, m.chart, { resolutions: res });
        if (r.conflicts.length) { s.conflictRead = fr; return fail(s, 'conflict', r); }
        rebase(s, fr, r.chart);
      }
      s.region = fr.region.text;
      s.embedOutside = fr.embedOutside;
      return null;
    }
    function settleDates(s, sent, failedDates) {
      s.pendingDates = s.pendingDates.filter(function (d) { return sent.indexOf(d) < 0; });
      (failedDates || []).forEach(function (d) {
        if (!s.pendingDates.some(function (x) { return x.id === d.id; })) s.pendingDates.unshift(d);
      });
    }

    // §9.2 saveOnce: never throws; always writes s.live.
    function saveCore(s, o) {
      o = o || {};
      if (s.journalHold) return P({ ok: false, reason: 'held' });
      if (s.readOnly || s.status === 'future') return P(fail(s, 'read-only'));
      if (s.status === 'malformed' && !forced(o, 'malformed')) return P(fail(s, 'malformed'));
      if (s.extra && !forced(o, 'extra')) return P(fail(s, 'extra'));
      if (!s.live) return P(fail(s, 'no-chart'));
      var tries = (L.mode === 'auto' && L.sessionApproved) ? S.TRIES : 1;
      var kept = o.resolutions ? s.conflictRead : null;
      s.conflictRead = null;
      if (kept) { var f0 = absorb(s, kept, o); if (f0) return P(f0); }
      var attempt = 0;
      function step() {
        if (attempt >= tries) {
          if (tries === S.TRIES) s.readOnly = true;
          return fail(s, tries === 1 ? 'retry-needed' : 'write-failed');
        }
        attempt++;
        s.writing = s.live;
        var next = B().region(s.writing, s.summaries(s.writing), { embedOutside: s.embedOutside });
        if (next === s.region && !s.pendingDates.length) return agree(s, next);
        var sent = s.pendingDates.slice(), base0 = L.baselineMs, t0 = clock();
        var wp = s.region ? H.saveRegion(s.noteId, s.region, next, sent) : H.appendContent(s.noteId, '\n' + next);
        return wp.then(function (w) {
          var ms = typeof w.roundTripMs === 'number' ? w.roundTripMs : clock() - t0;
          if (w.ok) {
            detect(ms, base0);
            settleDates(s, sent, w.failedDates);
            var ok = agree(s, next);
            // The date entries this save sent and the host refused (the
            // chart itself was written); entries queued meanwhile are not counted.
            ok.datesFailed = (w.failedDates || []).length;
            return ok;
          }
          if (w.denied) return fail(s, denied());
          return H.readNote(s.noteId).then(function (r) {
            if (!r.ok) return fail(s, 'read-failed');
            var f = absorb(s, B().read(r.content), o);
            if (f) return f;
            return step();
          });
        });
      }
      return P(step());
    }

    /* ================================================= hide and resume */

    // onHide(kind): 'hidden', 'pagehide', 'switch' or 'home' (the hide row).
    st.onHide = function (kind) {
      if (kind === 'pagehide') pageHidden = true;
      var s = st.session;
      if (L.embed || !s) return P({ journal: null, flushed: false });
      if (s.journalHold) return P({ journal: null, flushed: false, held: true });
      if (s.journalFrame !== null) { cancelFrame(s.journalFrame); s.journalFrame = null; }
      var what = J.evaluate(s);
      var p = what === 'W' || what === 'D' ? kick() : P();
      return p.then(function () {
        if (L.mode !== 'auto' || st.session !== s) return { journal: what, flushed: false };
        return st.flush().then(function (r) { return { journal: what, flushed: !!r, result: r }; });
      });
    };

    function silentReload(s, fr) {
      initFrom(s, fr);
      emit('live', { reload: true });
    }
    // §7.6: refresh the journal map (rule 5, then rule 6), re-resolve,
    // re-read the chart note and reload silently when nothing is unsaved.
    /*
     * M9 tuning: refresh(reason). The 30 s interval counts only while the
     * page is shown (not after pagehide); a trigger during a refresh runs
     * one more refresh after it instead of a second one alongside; and the
     * chart note is read only when its updatedAt or length changed since
     * the last read (probed in the 7.1 query), so a resume over unchanged
     * notes makes no content read, no appState write and no re-render.
     */
    var refreshing = null, refreshAgain = null;
    st.refresh = function (reason) {
      reason = reason || 'resume';
      if (reason === 'interval' && (pageHidden || hiddenFn())) return P(null);
      // A joined trigger runs once more after this refresh, with its own
      // reason (an interval tick stays gated by pagehide; review round 1).
      if (refreshing) { if (!refreshAgain || refreshAgain === 'interval') refreshAgain = reason; return refreshing; }
      // Only a real return (focus, visible, pageshow, pointer, resumed)
      // undoes pagehide, never an interval tick.
      if (reason !== 'interval') pageHidden = false;
      function done(v) {
        refreshing = null;
        if (refreshAgain) { var r = refreshAgain; refreshAgain = null; return st.refresh(r); }
        return v;
      }
      refreshing = refreshOnce().then(done, function () { return done(null); });
      return refreshing;
    };
    function refreshOnce() {
      var p = L.embed ? P({ ok: true }) : J.refresh(false);
      return p.then(function () {
        var s = st.session;
        if (!s) return null;
        if (!L.embed && Object.keys(ops).length) kick();
        return (s.live ? st.resolve(s, { probe: s.noteId }) : P(null)).then(function (rr) {
          var pr = rr && rr.probe;
          // Skipped only when the note is as last read AND that read's block
          // is the one the session holds: a silent reload an earlier resume
          // had to defer (unsaved edits, hold, a save in flight) is retried
          // once its blocker clears (review round 1).
          if (pr && !pr.missing && s.stamp && pr.u === s.stamp.u && pr.l === s.stamp.l && s.readKey === s.key) return { skipped: true };
          return H.readNote(s.noteId);
        }).then(function (r) {
          if (st.session !== s) return null;
          if (r.skipped) return afterRead(s);
          if (!r.ok) return null;
          var fr = B().read(r.content);
          s.lastText = r.content;
          s.stamp = { u: r.updatedAt, l: r.clen };
          s.readKey = fr.key;
          if (fr.status === 'ok') s.embedOutside = fr.embedOutside;       // §5.6: refreshed on every read
          if (fr.status === 'ok' && s.status === 'ok' && fr.key !== s.key && s.writing === null && !s.busy &&
              S.same(s.live, s.base) && !s.journalHold) silentReload(s, fr);
          emit('read', s);
          return afterRead(s);
        });
      });
    }
    function afterRead(s) {
      // §7.6: only edits left unsaved by a denial that arrived while
      // hidden are saved on resume (auto). Any other unsaved state (a
      // conflict, retry-needed, ...) waits for the user: a resume must
      // never raise an approval dialog on its own.
      if (L.mode === 'auto' && canEdit(s) && !s.busy && s.lastResult && s.lastResult.reason === 'denied-hidden' &&
          !S.same(s.live, s.base)) return requestSave(s, {}, false);
      return null;
    }

    /*
     * M9 reconciliation banner (§5.1, §5.6): mirrorGap() -> null or
     * {deleted, edited} (task ids) for the open chart, from the last read of
     * the chart note, only while that read's block is the one this store
     * last wrote (so a hand-written block, or one another device changed,
     * never counts) and the session is editable. It never changes the chart.
     */
    st.mirrorGap = function () {
      var s = st.session;
      if (!canEdit(s) || s.extra || typeof s.lastText !== 'string' || !s.wroteKey) return null;
      var memo = s.gapMemo;
      if (!memo || memo.text !== s.lastText) memo = s.gapMemo = { text: s.lastText, gap: B().mirrorGap(s.lastText) };
      var g = memo.gap;
      if (!g || g.key !== s.key || g.key !== s.wroteKey) return null;
      function alive(id) { var t = M().task(s.live, id); return !!t && !!t.note; }
      var out = { deleted: g.deleted.filter(alive), edited: g.edited.filter(alive) };
      return out.deleted.length || out.edited.length ? out : null;
    };
    // The region as the last read found it, when its block is ours: the
    // next replace_text then matches the note (as absorb re-anchors).
    function anchorToRead(s) {
      if (typeof s.lastText !== 'string' || s.busy || s.writing !== null) return false;
      var fr = B().read(s.lastText);
      if (fr.status !== 'ok' || fr.key !== s.key || !fr.region) return false;
      s.region = fr.region.text;
      s.embedOutside = fr.embedOutside;
      return true;
    }
    st.anchorToRead = function () { var s = st.session; return !!s && anchorToRead(s); };
    // "Restore list": write the region again, so the mirror has every line.
    st.restoreMirror = function () {
      var s = st.session;
      if (!canEdit(s)) return P({ ok: false, reason: 'held' });
      return (s.busy || P()).then(function () {
        if (st.session !== s) return { ok: false, reason: 'superseded' };
        anchorToRead(s);
        return requestSave(s, {}, true);
      });
    };

    var offResume = null;
    // Boot: seed the baseline, load appState once, wire the resume triggers.
    st.boot = function () {
      if (!offResume && typeof H.onResume === 'function') offResume = H.onResume(function (reason) { return st.refresh(reason); });
      var seed = typeof H.seedBaseline === 'function' ? H.seedBaseline() : P();
      return Promise.all([seed, J.refresh(true)]).then(function (r) { return { ok: r[1].ok }; });
    };
    st.dispose = function () {
      if (offResume) { offResume(); offResume = null; }
      stopSession(st.session);
      if (other.timer !== null) { clearT(other.timer); other.timer = null; }
    };

    /* ================================================ UI state (for M6) */

    st.ui = function () {
      var s = st.session;
      var dirty = !!s && !!s.live && !S.same(s.live, s.base);
      var banner = null;
      if (s) {
        if (s.checkFailed) banner = 'check-failed';
        else if (s.offer) banner = 'restore';
        else if (s.kept) banner = 'kept';
        else if (s.status === 'future') banner = 'future';
        else if (s.status === 'malformed') banner = 'malformed';
        else if (s.readOnly) banner = 'read-only';
      }
      var unsaved = dirty || !!(s && (s.offer || s.kept));
      var pill = 'saved';
      if (L.mode === 'paused') pill = unsaved ? 'not-saved' : 'saved';
      else if (L.mode === 'manual') pill = unsaved ? 'unsaved' : 'saved';
      else pill = s && s.busy ? 'saving' : (dirty ? 'unsaved' : 'saved');
      return {
        banner: banner, readOnly: !canEdit(s), pill: pill, mode: L.mode, sheet: !!(s && s.sheet),
        offer: s && s.offer ? { at: s.offer.entry.at, owner: s.offer.entry.owner, late: s.offer.late } : null
      };
    };

    /* ================================================ note actions (§8) */

    // Task specs for notes: dates from scheduledAt / completeBy, else `from`
    // (default today) for 5 days (§8).
    function seedSpecs(notes, from) {
      var ids = notes.map(function (n) { return n.id; });
      return H.meta(ids).then(function (mr) {
        var today = typeof from === 'number' && isFinite(from) ? from : D().today(now());
        return notes.map(function (n) {
          var row = mr.rows && mr.rows[n.id];
          var st0 = row ? D().fromHost(row.scheduledAt) : null, en = row ? D().fromHost(row.completeBy) : null;
          if (st0 === null) st0 = en !== null ? en : today;
          if (en === null) en = st0 + 4;
          return { note: n.id, title: (row && row.title) || n.title || '', start: st0, end: en };
        });
      });
    }
    function newChartData(spec) {
      var c = M().empty();
      var fields = { progressSection: MD().defaultSection(H.locale ? H.locale() : 'en-US') };
      if (isObj(spec.settings)) Object.keys(spec.settings).forEach(function (k) { fields[k] = spec.settings[k]; });
      return M().setSettings(c, fields).chart;
    }

    // New chart: saveNotes a note holding an empty region, then open it.
    st.createChart = function (spec) {
      spec = spec || {};
      if (L.embed) return P({ ok: false, reason: 'embed' });
      var notes = Array.isArray(spec.notes) ? spec.notes.filter(function (n) { return isObj(n) && sqlId(n.id); }) : [];
      return (notes.length ? seedSpecs(notes) : P([])).then(function (specs) {
        var c = newChartData(spec);
        if (specs.length) c = M().addTasks(c, specs).chart;
        var intro = String(spec.intro == null ? '' : spec.intro).trim();
        var content = (intro ? intro + '\n\n' : '') + B().region(c, null, {});
        var title = String(spec.title == null ? '' : spec.title).trim() || 'Gantt';
        return H.createNote({ title: title, content: content }).then(function (r) {
          if (!r.ok) return { ok: false, reason: 'create-failed', error: r.error };
          return st.open({ noteId: r.id, title: title }).then(function (o) {
            return { ok: o.ok, id: r.id, session: o.session || null, reason: o.reason };
          });
        });
      });
    };

    // Turn a plain note into a chart: append a region after a blank line.
    // `chart` (Recreate) is the journaled chart; else a new one, with the
    // note's linked notes as tasks when spec.importLinks is set. spec.title
    // (M7) is the note's title, for the session that opens afterwards.
    st.convertNote = function (noteId, chart, spec) {
      spec = spec || {};
      if (L.embed || !sqlId(noteId)) return P({ ok: false, reason: 'bad-id' });
      return H.readNote(noteId).then(function (r) {
        if (!r.ok) return { ok: false, reason: r.missing ? 'missing' : 'read-failed' };
        var fr = B().read(r.content);
        if (fr.status !== 'none') return { ok: false, reason: 'already-chart' };
        var links = spec.importLinks ? MD().noteLinkIds(r.content, { exclude: noteId }).map(function (id) { return { id: id }; }) : [];
        return (links.length && !chart ? seedSpecs(links) : P([])).then(function (specs) {
          var c = chart || newChartData(spec);
          if (specs.length) c = M().addTasks(c, specs).chart;
          // Recreate answers the entry that was shown (the own pending W when
          // another owner's entry waits behind it); that other entry stays
          // unseen and is late-checked by the open that follows.
          var e = shownEntry(noteId);
          if (e) markSeen(noteId, e);
          delete unanswered[noteId];
          stopSession(st.session);
          var s = newSession(noteId);
          s.journalHold = false;
          s.status = 'ok';
          s.base = M().empty();
          s.key = S.EMPTY_KEY;
          s.region = null;
          s.live = c;
          s.embedOutside = fr.embedOutside;
          s.checkedOnce = true;
          st.session = s;
          J.reschedule(s);
          return requestSave(s, {}, true).then(function (res) {
            if (!res.ok) return { ok: false, reason: res.reason, session: s };
            return st.open({ noteId: noteId, title: typeof spec.title === 'string' ? spec.title : undefined }).then(function (o) { return { ok: o.ok, session: o.session || null, converted: true }; });
          });
        });
      });
    };

    // Add notes to a chart (opens it when it is not the open one).
    // opts (M7): {index, group, from}: where the rows go in the task list,
    // their group, and the first day for notes with no dates (§8: after the
    // selected row, else today).
    st.addToChart = function (chartId, notes, opts) {
      opts = opts || {};
      var s = st.session && st.session.noteId === chartId ? st.session : null;
      var p = s ? P({ ok: true, session: s }) : st.open({ noteId: chartId });
      return p.then(function (o) {
        if (!o.ok) return { ok: false, reason: o.reason };
        s = o.session;
        return s.checked.then(function () {
          if (!canEdit(s) || st.session !== s) return { ok: false, reason: 'held' };
          var list = (notes || []).map(function (n) { return typeof n === 'string' ? { id: n } : n; }).filter(function (n) { return isObj(n) && sqlId(n.id); });
          if (!list.length) return { ok: true, added: [], skipped: 0, inverse: [] };
          return seedSpecs(list, opts.from).then(function (specs) {
            if (!canEdit(s) || st.session !== s) return { ok: false, reason: 'held' };
            if (opts.group !== undefined) specs.forEach(function (sp) { sp.group = opts.group; });
            var r = M().addTasks(s.live, specs, typeof opts.index === 'number' ? { index: opts.index } : {});
            if (!r.added.length) return { ok: true, added: [], skipped: r.skipped, inverse: [] };
            st.commit(r.chart);
            return { ok: true, added: r.added, skipped: r.skipped, inverse: r.inverse, save: s.busy };
          });
        });
      });
    };

    // Create a task note from the template and add it (§8).
    st.createTaskNote = function (spec) {
      spec = spec || {};
      var s = st.session;
      if (!canEdit(s)) return P({ ok: false, reason: 'held' });
      var set = s.live.settings, today = D().today(now());
      var start = typeof spec.start === 'number' ? spec.start : today;
      // An end before the start is clamped to a one-day task: the note never
      // gets completeBy before scheduledAt (M7 review).
      var end = typeof spec.end === 'number' ? Math.max(spec.end, start) : start + 4;
      var title = String(spec.title == null ? '' : spec.title).trim();
      if (!title) return P({ ok: false, reason: 'no-title' });
      // The section is always the chart's progressSection (§15.1): a heading
      // the chart does not count would make the note's items invisible to it.
      // The backlink names the chart; an open from a bare id reads its title.
      var known = s.title ? P() : H.meta([s.noteId]).then(function (mr) {
        var row = mr.rows && mr.rows[s.noteId];
        if (row && !s.title) s.title = row.title;
      });
      return known.then(function () {
        var t = MD().template({
          source: set.progressSource, section: set.progressSection, steps: spec.steps, intro: spec.intro,
          backlink: spec.backlink === false ? null : { chartId: s.noteId, title: s.title || 'Gantt' }
        });
        return H.createNote({
          title: title, type: 'task', status: 'todo', scheduledAt: D().toHost(start), completeBy: D().toHost(end),
          content: t.content, subNotes: t.subNotes
        });
      }).then(function (r) {
        if (!r.ok) return { ok: false, reason: 'create-failed', error: r.error };
        if (st.session !== s || !canEdit(s)) return { ok: false, reason: 'held', id: r.id };
        var a = M().addTasks(s.live, [{ note: r.id, title: title, start: start, end: end, group: spec.group }],
          typeof spec.index === 'number' ? { index: spec.index } : {});
        // The note already has these dates: its fact is set after the commit,
        // so syncDates queues no second date entry for it.
        st.commit(a.chart);
        if (!s.facts[r.id]) s.facts[r.id] = { title: title, type: 'task', status: 'todo', archived: false, missing: false, updatedAt: null, clen: null, prog: null };
        return { ok: true, id: r.id, added: a.added, inverse: a.inverse, save: s.busy };
      });
    };

    function sectionOf(o) {
      var s = st.session;
      if (o && typeof o.section === 'string') return o.section;
      return s && s.live ? s.live.settings.progressSection : 'Checklist';
    }
    function refreshChecklist(noteId, content, section) {
      var s = st.session;
      if (!s || !s.facts[noteId]) return;
      s.facts[noteId].prog = progOf(MD().checklist(content, section), false);
      emit('facts', s);
    }
    // One checkbox edit: read (guarded), build with toggleEdit, write, then
    // re-read and check the line (§8: a no-op or a not-found is verified).
    function toggleOnce(noteId, section, target) {
      return H.readNote(noteId).then(function (r) {
        if (!r.ok) return { ok: false, reason: r.missing ? 'changed' : 'read-failed' };
        var e = MD().toggleEdit(r.content, section, target);
        if (!e.ok) return { ok: false, reason: e.reason === 'no-section' || e.reason === 'gone' || e.reason === 'ambiguous' ? 'changed' : e.reason };
        // Verification with the edit's own context, not the bare line: the
        // re-read must differ from the read before the write (a no-op answer
        // leaves it equal, even when a twin is already in the new state), and
        // either be exactly the edited text or, after other concurrent edits,
        // hold new_text once and old_text nowhere.
        function count(hay, needle) {
          var n = 0, i = hay.indexOf(needle);
          while (i >= 0 && n < 2) { n++; i = hay.indexOf(needle, i + 1); }
          return n;
        }
        var at = r.content.indexOf(e.old_text);
        var expected = at < 0 ? null : r.content.slice(0, at) + e.new_text + r.content.slice(at + e.old_text.length);
        // The fallback counts inside the section the edit was scoped to (the
        // same line may appear in another section), else the whole note.
        function scope(c2) {
          if (!e.section) return c2;
          // The host's own scope for e.section (fence-blind, like the host).
          var hs = MD().hostScope(c2, e.section);
          return hs ? c2.split('\n').slice(hs.from, hs.to).join('\n') : c2;
        }
        function applied(c2) {
          if (c2 === r.content) return false;
          if (c2 === expected) return true;
          var hay = scope(c2);
          return count(hay, e.old_text) === 0 && count(hay, e.new_text) === 1;
        }
        return H.replaceText(noteId, e.old_text, e.new_text, e.section).then(function (w) {
          if (w.denied) return { ok: false, reason: 'denied' };
          return H.readNote(noteId).then(function (r2) {
            if (!r2.ok) return { ok: false, reason: 'read-failed' };
            refreshChecklist(noteId, r2.content, section);
            // The re-read also gives the sheet its list (no fourth read, M7 review).
            var list = checkItems(r2.content, section);
            if (!applied(r2.content)) return { ok: false, reason: 'changed', list: list };
            return { ok: true, edit: e, written: !!w.ok, list: list };
          });
        });
      });
    }
    // toggleItem(noteId, target, {section}): target {index} or {line, prevLine}.
    st.toggleItem = function (noteId, target, o) {
      if (!canEdit(st.session)) return P({ ok: false, reason: 'held' });
      var section = sectionOf(o);
      return toggleOnce(noteId, section, target || {}).then(function (r) {
        if (!r.ok) return r;
        var patch = { op: 'host', kind: 'toggleItem', args: { noteId: noteId, section: section, line: r.edit.newLine, prevLine: r.edit.prevLine, checked: r.edit.checked } };
        return { ok: true, patch: patch, inverse: [M().invertHost(patch)], list: r.list };
      });
    };
    st.toggleSubnote = function (noteId, subId, done) {
      if (!canEdit(st.session)) return P({ ok: false, reason: 'held' });
      return H.setSubnoteDone(noteId, subId, done).then(function (w) {
        if (!w.ok) return { ok: false, reason: w.denied ? 'denied' : 'failed' };
        var patch = { op: 'host', kind: 'toggleSubnote', args: { noteId: noteId, subId: subId, done: !!done } };
        var s = st.session;
        return st.resolve(s, { ids: [noteId] }).then(function () { return { ok: true, patch: patch, inverse: [M().invertHost(patch)] }; });
      });
    };
    st.setChildStatus = function (childId, status, prev, parentId) {
      if (!canEdit(st.session)) return P({ ok: false, reason: 'held' });
      return H.setTaskFields(childId, { status: status }).then(function (w) {
        if (!w.ok) return { ok: false, reason: w.denied ? 'denied' : 'failed' };
        // `parent` lets an undo re-read the parent's child counts (M7).
        var patch = { op: 'host', kind: 'setChildStatus', args: { noteId: childId, status: status, prev: prev, parent: sqlId(parentId) ? parentId : null } };
        var s = st.session;
        var p = parentId ? st.resolve(s, { ids: [parentId] }) : P();
        return p.then(function () { return { ok: true, patch: patch, inverse: [M().invertHost(patch)] }; });
      });
    };

    /*
     * loadItems(noteId, {src, section, childTasks}) -> {ok, src, found,
     * items:[{key, kind, text, done, ...}]}: the task sheet's completion list
     * (§13.4), read when the sheet opens. kind 'check' carries {index, line,
     * prevLine} (md.checklist), 'sub' {id}, 'child' {id, status}. A checklist
     * read also refreshes the note's counts, so the bar and the list agree.
     */
    function checkItems(content, section) {
      var cl = MD().checklist(content, section);
      return {
        found: cl.found, items: cl.items.map(function (it) {
          return { key: 'c' + it.index, kind: 'check', index: it.index, line: it.line, prevLine: it.prevLine, text: it.text, done: it.checked };
        })
      };
    }
    st.loadItems = function (noteId, o) {
      o = o || {};
      var s = st.session;
      if (!sqlId(noteId)) return P({ ok: false, items: [], reason: 'bad-id' });
      if (o.src === 'checklist') {
        var section = typeof o.section === 'string' ? o.section : sectionOf();
        return H.readNote(noteId).then(function (r) {
          // A note too large for one read (the ~2 MB cursor window) is
          // 'too-large': its items are ticked in the note itself.
          if (!r.ok) return { ok: false, src: 'checklist', items: [], reason: r.missing ? 'missing' : (r.truncated ? 'too-large' : 'read-failed') };
          if (st.session === s) refreshChecklist(noteId, r.content, section);
          var l = checkItems(r.content, section);
          return { ok: true, src: 'checklist', found: l.found, items: l.items };
        });
      }
      if (o.src === 'subnotes') {
        var kids = o.childTasks === false ? P({ ok: true, items: [] }) : H.childItems(noteId);
        return Promise.all([H.subnoteItems(noteId), kids]).then(function (rs) {
          if (!rs[0].ok || !rs[1].ok) return { ok: false, src: 'subnotes', items: [], reason: 'read-failed' };
          var items = rs[0].items.map(function (x) { return { key: 's' + x.id, kind: 'sub', id: x.id, text: x.name, done: x.done }; })
            .concat(rs[1].items.map(function (x) { return { key: 'k' + x.id, kind: 'child', id: x.id, text: x.title, done: x.status === 'complete', status: x.status }; }));
          return { ok: true, src: 'subnotes', found: true, items: items };
        });
      }
      return P({ ok: true, src: o.src || 'none', found: true, items: [] });
    };

    /*
     * markItem(noteId, kind, pos, done): the tap's own frame (§18 M7): the
     * note's counts show item `pos` (its place among items of `kind`) in its
     * new state before the host answers, and 'facts' fires so the bar is
     * redrawn at once. -> revert() or null. revert() puts the counts back
     * unless a read replaced them meanwhile (then that read is the truth).
     */
    st.markItem = function (noteId, kind, pos, done) {
      var s = st.session, f = s && s.facts[noteId];
      if (!f || !f.prog) return null;
      var want = kind === 'check' ? 'checklist' : 'subnotes';
      if (f.prog.src !== want || (kind === 'child' && !f.prog.child)) return null;
      var prev = f.prog, next = clone(prev);
      var p = kind === 'child' ? next.child : next;
      var bit = done ? '1' : '0';
      if (typeof p.bits === 'string' && pos >= 0 && pos < p.bits.length) {
        if (p.bits[pos] === bit) return null;
        p.bits = p.bits.slice(0, pos) + bit + p.bits.slice(pos + 1);
      }
      p.done = Math.max(0, Math.min(p.total, p.done + (done ? 1 : -1)));
      f.prog = next;
      emit('facts', s);
      return function revert() {
        if (f.prog !== next) return false;
        f.prog = prev;
        if (st.session === s) emit('facts', s);
        return true;
      };
    };

    /*
     * Export image: adds a PNG to the chart note's attachments. Pending
     * chart edits are saved first, so the note's history reads in order
     * (that save can raise its own approval; if it is denied, the image is
     * not attached). Not undoable (the chart itself does not change).
     * -> {ok} | {ok:false, reason:'held'|'denied'|'failed', error}
     */
    st.attachImage = function (dataUrl, fileName) {
      var s = st.session;
      if (!canEdit(s)) return P({ ok: false, reason: 'held' });
      return st.flush().then(function (f) {
        if (st.session !== s) return { ok: false, reason: 'held' };
        // The user just said no to saving this chart: do not ask again for the image.
        if (f && f.ok === false && /^denied/.test(String(f.reason))) return { ok: false, reason: 'denied', flush: f.reason };
        return H.attachFile(s.noteId, dataUrl, fileName).then(function (w) {
          return w.ok ? { ok: true } : { ok: false, reason: w.denied ? 'denied' : 'failed', error: w.error || null };
        });
      });
    };

    st.renameChart = function (title) {
      var s = st.session;
      if (!canEdit(s)) return P({ ok: false, reason: 'held' });
      var prev = s.title;
      // The previous title is needed for undo; an open from a bare id has none yet.
      var known = prev ? P() : H.meta([s.noteId]).then(function (mr) {
        var row = mr.rows && mr.rows[s.noteId];
        if (row) prev = s.title = row.title;
      });
      return known.then(function () { return H.rename(s.noteId, title); }).then(function (w) {
        if (!w.ok) return { ok: false, reason: w.denied ? 'denied' : 'failed' };
        s.title = title;
        touchRecent(s.noteId, title, false);
        var patch = { op: 'host', kind: 'renameChart', args: { title: title, prev: prev } };
        return { ok: true, patch: patch, inverse: [M().invertHost(patch)] };
      });
    };

    /*
     * applyEffects(effects): performs host patches in order through the same
     * calls as the original actions. A toggle re-resolves its item by line
     * and prevLine; a target that is gone or ambiguous fails.
     * -> {ok} | {ok:false, reason:'changed'|'denied'|'failed'|'held', index}
     */
    st.applyEffects = function (effects) {
      var list = Array.isArray(effects) ? effects : [];
      var s = st.session;
      if (!canEdit(s)) return P({ ok: false, reason: 'held', index: 0 });
      return list.reduce(function (acc, p, i) {
        return acc.then(function (res) {
          if (!res.ok) return res;
          var a = (p && p.args) || {};
          var run;
          if (p.kind === 'toggleItem') {
            run = toggleOnce(a.noteId, typeof a.section === 'string' ? a.section : sectionOf(), { line: flipBox(a.line), prevLine: a.prevLine });
          } else if (p.kind === 'toggleSubnote') {
            // The counts are read again, so the bar shows the undone value (M7).
            run = H.setSubnoteDone(a.noteId, a.subId, a.done).then(function (w) {
              if (!w.ok) return { ok: false, reason: w.denied ? 'denied' : 'failed' };
              return st.resolve(s, { ids: [a.noteId] }).then(function () { return { ok: true }; });
            });
          } else if (p.kind === 'setChildStatus') {
            run = H.setTaskFields(a.noteId, { status: a.status }).then(function (w) {
              if (!w.ok) return { ok: false, reason: w.denied ? 'denied' : 'changed' };
              return (sqlId(a.parent) ? st.resolve(s, { ids: [a.parent] }) : P()).then(function () { return { ok: true }; });
            });
          } else if (p.kind === 'renameChart') {
            run = H.rename(s.noteId, a.title).then(function (w) {
              if (w.ok) { s.title = a.title; touchRecent(s.noteId, a.title, false); }
              return w.ok ? { ok: true } : { ok: false, reason: w.denied ? 'denied' : 'failed' };
            });
          } else run = P({ ok: false, reason: 'failed' });
          return run.then(function (r) { return r.ok ? { ok: true } : { ok: false, reason: r.reason, index: i }; });
        });
      }, P({ ok: true }));
    };

    /*
     * undo(stack) / redo(stack): one step of an undo.createStack. Host
     * effects run first; a failed effect puts the entry back (revert) and
     * the chart is left alone. A chart change commits and saves at once.
     */
    function stepStack(stack, which) {
      var s = st.session;
      if (!canEdit(s)) return P({ ok: false, reason: 'held' });
      var r = which === 'redo' ? stack.redo(s.live) : stack.undo(s.live);
      if (!r) return P({ ok: false, reason: 'empty' });
      var eff = r.effects.length ? st.applyEffects(r.effects) : P({ ok: true });
      return eff.then(function (res) {
        if (!res.ok) { stack.revert(r); return { ok: false, reason: res.reason, label: r.label }; }
        if (!S.same(r.chart, s.live) && st.session === s) st.commit(r.chart);
        return { ok: true, label: r.label };
      });
    }
    st.undo = function (stack) { return stepStack(stack, 'undo'); };
    st.redo = function (stack) { return stepStack(stack, 'redo'); };

    // Forced Repair of a malformed block, or "Use the first block" (§5.5).
    st.repair = function (what, chart) {
      var s = st.session;
      if (!s || s.journalHold || L.embed) return P({ ok: false, reason: 'held' });
      if (what === 'malformed') {
        if (s.status !== 'malformed') return P({ ok: false, reason: 'not-malformed' });
        s.live = chart || newChartData({});
        s.base = M().empty();
      }
      return requestSave(s, { force: what }, true);
    };

    return st;
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
