/*
 * Dev loader for the real shell (plugins/gantt.html) over the mock host.
 * Used by dev/shot.html (screenshots, app_smoke frames) and dev/harness.html.
 *
 * GTDev.writeShell(opts) must run from a script in the <head> of a dev page
 * while it parses: it reads gantt.html with a synchronous request, points
 * its module tags at ../plugins/src/, swaps the boot line for GTDev.boot()
 * and writes the whole document in. No frame navigation happens from
 * script, which headless Chrome under --virtual-time-budget cannot finish.
 *
 * Query parameters (all optional):
 *   fixture  a file in dev/fixtures (.md chart note or .json chart), or
 *            'empty' (default region-basic.md, the §5.2 example)
 *   launch   note | home | embed | chooser | resolve | resolve-plain | chart | multi
 *   theme    light | dark (an in-app override, not stored)
 *   today    YYYY-MM-DD (default 2026-10-20)
 *   locale   en-US | zh-CN
 *   space    a Space tag: the chart gets it, a second chart is in another
 *            Space and a third is tagged all-spaces
 *   app      the mock app id (appState key); default derived from the page
 *   persist  1 keeps appState in sessionStorage (default a fresh Map)
 *   latency  bridge delays, for example runQuery:300,loadAppState:300
 *   dpr      a device pixel ratio for the canvases (the app's dpr option)
 *   frame    timer: frames run on a 16 ms setTimeout instead of
 *            requestAnimationFrame, which headless Chrome under
 *            --virtual-time-budget barely runs (flings and animations)
 * M6:
 *   hold     a name: boot waits until parent.GT_RELEASE[name] is set, so a
 *            page can play a "reload" (a fresh mock and store over the same
 *            sessionStorage) after another frame wrote appState
 *   approve, approvalMs, approvals   the mock's approval dialog: default
 *            answer, how long it stays up, and the next answers
 *            (approvals=once,once)
 *   failLoads  the next n loadAppState calls fail ("Couldn't check")
 *   entry    move:<taskId>:<days> seeds appState with an unsaved-edits
 *            journal entry {S, S with that task moved} from an earlier launch
 *   noteMove <taskId>:<days> the chart note holds that task moved (a note
 *            that changed after the entry's base: Restore conflicts)
 *   do       actions after the chart opened, comma separated:
 *            sel:<id>, sheet:<id>:<peek|full>, lift:<id>, drag:<id>:<days>,
 *            notice, manual (save mode), commit:<id>:<days>, zoom:<preset>,
 *            fit, day:<YYYY-MM-DD>; M7: fab, create[:<selected id>], newchart, quiet (dismiss the notice)
 * With persist=1 the chart note's content saved by GTDev.keepNotes() is
 * used instead of the fixture's, so a "reload" sees what the last frame saved.
 * M8:
 *   set      chart settings for the fixture, for example
 *            set=progressStyle:segments,colorBy:group (true/false/digits typed)
 *   prefs    appState prefs the launch starts with, for example
 *            prefs=legend:false,density:compact,theme:dark
 *   do       also: settings, display, appearance, more, legend:on|off,
 *            skeleton (the loading rows), collapse (every group), names:<px>,
 *            ntog (the name column toggle), pick:<colour> (a swatch in the open task sheet)
 * M9:
 *   do       also: tasklist (More > Task list), locale:<tag> (a live
 *            synapse:localechanged)
 * Task notes whose id starts with "missing-" are not created (missing notes).
 */
(function (global) {
  'use strict';

  var N1 = '8f0c1e2a-5b7d-4c11-9a0e-2f6b3c9d1e01', N2 = '1b7d4e90-0c2a-4f5e-8d61-7a3b2c1d0e02',
    N3 = '77aa3c21-9e4f-4b6d-a0c8-5d2e1f3a4b03', N4 = 'c3e98a10-6d5b-4e2f-b1a7-0c9d8e7f6a04';
  // The §5.2 mirror's counts: 3/5, 0/4, 6/10 and a milestone with no items.
  var EXAMPLE = {};
  EXAMPLE[N1] = { done: 3, total: 5, status: 'in_progress' };
  EXAMPLE[N2] = { done: 0, total: 4, status: 'todo' };
  EXAMPLE[N3] = { done: 6, total: 10, status: 'in_progress' };
  EXAMPLE[N4] = { done: 0, total: 0, status: 'todo' };

  function get(url) {
    var x = new XMLHttpRequest();
    x.open('GET', url, false);
    x.send(null);
    if (x.status !== 200 && x.status !== 0) throw new Error('GET ' + url + ' -> ' + x.status);
    return x.responseText;
  }
  function params() {
    var q = new URLSearchParams(global.location.search), o = {};
    q.forEach(function (v, k) { o[k] = v; });
    return o;
  }
  function checklist(done, total) {
    var lines = [];
    for (var i = 0; i < total; i++) lines.push('- [' + (i < done ? 'x' : ' ') + '] step ' + (i + 1));
    return lines.join('\n');
  }

  var GTDev = (global.GTDev = { params: params(), EXAMPLE_IDS: [N1, N2, N3, N4] });

  /*
   * seed(opts) -> {notes, chartId}: the mock's notes for a fixture. Task
   * notes get checklists under "## Checklist" and a few subnotes, so every
   * progress source has something to count.
   */
  GTDev.seed = function (o) {
    var GT = global.GT, B = GT.block, M = GT.model;
    var fixture = o.fixture || 'region-basic.md';
    var content, title = 'Q4 Launch', chart;
    if (fixture === 'empty') {
      chart = M.empty();
      content = 'An empty chart.\n\n' + B.region(chart, null, {});
      title = 'Empty chart';
    } else if (/\.json$/.test(fixture)) {
      chart = M.coerce(JSON.parse(get('fixtures/' + fixture))).chart;
      content = 'A generated chart.\n\n' + B.region(chart, null, {});
      title = fixture === 'big.json' ? 'Platform roadmap' : { 'unscheduled.json': 'Vendor rollout', 'lite.json': 'Big programme', 'empty.json': 'New plan', 'cjk.json': '季度发布计划' }[fixture] || fixture;
    } else {
      content = get('fixtures/' + fixture).split('{{APP_UUID}}').join(GT.APP_UUID);
      var fr = B.read(content);
      chart = fr.chart;
      if (fixture !== 'region-basic.md') title = fixture.replace(/\.md$/, '');
    }
    var tags = o.space ? [o.space] : [];
    var notes = [{ id: 'chart-note', title: title, content: content, tags: tags }];
    (chart ? chart.tasks : []).forEach(function (t, i) {
      if (!t.note || /^missing-/.test(t.note)) return;
      var ex = EXAMPLE[t.note];
      var total = ex ? ex.total : (i % 5) + 1, done = ex ? ex.done : Math.min(total, i % 4);
      var status = ex ? ex.status : ['todo', 'in_progress', 'todo', 'complete', 'todo', 'abandoned', 'todo'][i % 7];
      var n = {
        id: t.note, title: t.title || ('Task ' + i), type: 'task', status: status, tags: tags,
        content: 'Notes for ' + (t.title || 'this task') + '.\n\n## Checklist\n' + checklist(done, total)
      };
      if (!ex) n.subnotes = [{ name: 'a', isCompleted: i % 2 === 0 }, { name: 'b', isCompleted: false }];
      notes.push(n);
    });
    if (o.space) {
      var other = M.coerce({ v: 1, tasks: [] }).chart;
      notes.push({ id: 'other-chart', title: 'Other Space chart', content: B.region(other, null, {}), tags: ['elsewhere'] });
      notes.push({ id: 'shared-chart', title: 'Shared chart', content: B.region(other, null, {}), tags: ['all-spaces'] });
    }
    notes.push({ id: 'plain-note', title: 'A plain note', content: 'Nothing to chart here.', tags: tags });
    if (o.kept) notes[0].content = o.kept;
    return { notes: notes, chartId: 'chart-note', chart: chart };
  };

  // The launch context (Notes and Params) for opts.launch.
  GTDev.launchOf = function (o, seed) {
    var l = o.launch || 'note';
    if (l === 'home') return { Notes: [], Params: {} };
    if (l === 'embed') return { Notes: ['chart-note'], Params: { mode: 'embed' } };
    if (l === 'chart') return { Notes: [], Params: { chart: o.chart || 'chart-note' } };
    if (l === 'chooser') return { Notes: [o.note || N1], Params: {} };
    if (l === 'multi') return { Notes: [N1, N2], Params: {} };
    if (l === 'resolve' || l === 'resolve-plain') {
      var parent = l === 'resolve' ? 'chart-note' : 'plain-note';
      return { Notes: [{ id: 'transient-block-1', title: 'Block', content: '- a selected line', isBlockScope: true, parentNoteId: parent }], Params: {} };
    }
    return { Notes: ['chart-note'], Params: {} };
  };

  // Local noon of `today`, advancing with real time; GTDev.shift(ms) jumps it.
  var shifted = 0;
  GTDev.shift = function (ms) { shifted += ms; };
  GTDev.clock = function (today) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(today || '2026-10-20');
    var base = new Date(+m[1], +m[2] - 1, +m[3], 12, 0, 0).getTime(), t0 = Date.now();
    return function () { if (stepMs) shifted += stepMs; return base + shifted + (Date.now() - t0); };
  };
  // GTDev.step(ms): every clock read advances ms (M8 review: slow frames
  // measured by the renderer's own clock); 0 stops it.
  var stepMs = 0;
  GTDev.step = function (ms) { stepMs = ms || 0; };
  // ?latency=runQuery:300,loadAppState:300 -> {runQuery: 300, ...}
  function latencyOf(v) {
    var out = {};
    String(v || '').split(',').forEach(function (kv) { var p = kv.split(':'); if (p[0] && +p[1] > 0) out[p[0]] = +p[1]; });
    return out;
  }

  GTDev.writeShell = function (extra) {
    var o = Object.assign({}, GTDev.params, extra || {});
    GTDev.opts = o;
    var html = get('../plugins/gantt.html');
    html = html.replace(/^<!doctype html>\n?/i, '')
      .split('src="src/').join('src="../plugins/src/')
      .replace('<script>GT.app.boot();</script>', '<script>GTDev.boot();</script>');
    if (html.indexOf('GTDev.boot()') < 0) throw new Error('gantt.html has no GT.app.boot() line to replace');
    global.document.write(html);
  };

  // An iframe of exactly w x h holding this page with &inner=1.
  GTDev.writeFrame = function (w, h) {
    var q = global.location.search + (global.location.search ? '&' : '?') + 'inner=1';
    // Centred in the window, so a centred crop of the screenshot is the frame.
    global.document.write('<style>html,body{margin:0;height:100%;background:#888}body{display:flex;align-items:center;justify-content:center}</style>' +
      '<iframe id="app" src="shot.html' + q + '" style="border:0;display:block;flex:none;width:' + (+w) + 'px;height:' + (+h) + 'px"></iframe>');
  };

  function appIdOf(o) { return o.app || ('gantt-dev-' + (o.fixture || 'basic') + '-' + (o.launch || 'note')); }
  // The chart note as the last frame saved it (persist=1 "reloads").
  GTDev.keepNotes = function () {
    var n = GTDev.mock && GTDev.mock.db.notes['chart-note'];
    if (n) global.sessionStorage.setItem('gt-dev-notes:' + appIdOf(GTDev.opts || GTDev.params), n.content);
  };
  // A journal entry {S, S with one task moved} written by an earlier launch.
  function seedEntry(o, seed, storage) {
    var m = /^move:([A-Za-z0-9_-]+):(-?\d+)$/.exec(o.entry || '');
    if (!m || !seed.chart) return;
    var GT = global.GT, B = GT.block, M = GT.model;
    var S0 = seed.chart, A = M.moveTask(S0, m[1], +m[2]).chart;
    var key = 'gt-mock-appstate:' + appIdOf(o);
    var blob = { v: 1, journal: {} };
    blob.journal['chart-note'] = { at: GTDev.clock(o.today)() - 2 * 3600e3, owner: 'an-earlier-launch', baseKey: B.key(B.serialize(S0)), base: M.toData(S0), chart: M.toData(A) };
    if (storage && typeof storage.set === 'function') storage.set(key, JSON.stringify(blob));
    else global.sessionStorage.setItem(key, JSON.stringify(blob));
  }

  function typed(v) { return v === 'true' ? true : v === 'false' ? false : /^\d+$/.test(v) ? +v : v; }
  function pairs(list) {
    var o = {};
    String(list || '').split(',').forEach(function (kv) { var i = kv.indexOf(':'); if (i > 0) o[kv.slice(0, i)] = typed(kv.slice(i + 1)); });
    return o;
  }
  // set=<k:v,...>: the chart note's settings changed before the launch.
  function applySet(o, seed) {
    if (!o.set || !seed.chart) return;
    var GT = global.GT, B = GT.block, fr = B.read(seed.notes[0].content);
    var ch = GT.model.setSettings(fr.chart, pairs(o.set)).chart;
    seed.notes[0].content = seed.notes[0].content.replace(fr.region.text, B.region(ch, null, {}));
    seed.chart = ch;
  }
  // prefs=<k:v,...>: appState prefs written by an earlier launch.
  function seedPrefs(o, storage) {
    if (!o.prefs) return;
    var key = 'gt-mock-appstate:' + appIdOf(o), raw = null;
    try { raw = storage && typeof storage.get === 'function' ? storage.get(key) : global.sessionStorage.getItem(key); } catch (e) { raw = null; }
    var blob = raw ? JSON.parse(raw) : { v: 1 };
    blob.prefs = Object.assign({}, blob.prefs || {}, pairs(o.prefs));
    if (storage && typeof storage.set === 'function') storage.set(key, JSON.stringify(blob));
    else global.sessionStorage.setItem(key, JSON.stringify(blob));
  }

  // Installs the mock over the fixture and boots the app. -> the boot promise
  GTDev.boot = function () {
    var o = GTDev.opts || GTDev.params;
    // hold=<name>: wait for the parent page to release this "reload".
    if (o.hold) {
      return new Promise(function (res) {
        (function poll() {
          var r = null;
          try { r = global.parent && global.parent.GT_RELEASE; } catch (e) { r = null; }
          if (r && r[o.hold]) res(bootNow(o)); else global.setTimeout(poll, 20);
        })();
      });
    }
    return bootNow(o);
  };
  function bootNow(o) {
    var GT = global.GT;
    var appId = appIdOf(o);
    if (o.persist === '1') {
      var kept = null;
      try { kept = global.sessionStorage.getItem('gt-dev-notes:' + appId); } catch (e) { kept = null; }
      if (kept) o = Object.assign({}, o, { kept: kept });
    }
    var seed = GTDev.seed(o);
    var launch = GTDev.launchOf(o, seed);
    var storage = o.persist === '1' ? undefined : new Map();
    if (o.entry) seedEntry(o, seed, storage);
    applySet(o, seed);
    seedPrefs(o, storage);
    // noteMove=<taskId>:<days>: the chart note already holds that task moved
    // (an edit elsewhere since the journal entry's base), for Restore conflicts.
    var nm = /^([A-Za-z0-9_-]+):(-?\d+)$/.exec(o.noteMove || '');
    if (nm && seed.chart) {
      var B = GT.block, fr = B.read(seed.notes[0].content);
      seed.notes[0].content = seed.notes[0].content.replace(fr.region.text, B.region(GT.model.moveTask(seed.chart, nm[1], +nm[2]).chart, null, {}));
    }
    var mock = GT.host.installMock(seed.notes, {
      appId: appId, Notes: launch.Notes, Params: launch.Params, locale: o.locale || 'en-US',
      space: o.space ? { id: 'sp-' + o.space, name: o.space, tags: [o.space] } : null,
      storage: storage, latency: latencyOf(o.latency),
      approve: o.approve || undefined, approvalMs: +o.approvalMs > 0 ? +o.approvalMs : 0
    });
    if (o.approvals) mock.approvals = o.approvals.split(',');
    if (+o.failLoads > 0) mock.failLoads(+o.failLoads);
    GTDev.mock = mock;
    GTDev.seedData = seed;
    GTDev.booting = GT.app.boot({
      now: GTDev.clock(o.today), theme: o.theme === 'light' || o.theme === 'dark' ? o.theme : undefined,
      dpr: +o.dpr > 0 ? +o.dpr : undefined,
      frame: o.frame === 'timer' ? function (f) { return global.setTimeout(function () { f(global.performance.now()); }, 16); } : undefined,
      cancelFrame: o.frame === 'timer' ? function (h) { global.clearTimeout(h); } : undefined
    });
    GTDev.booting.then(function () { return o.do ? GTDev.act(o.do) : null; })
      .then(function () { global.document.documentElement.setAttribute('data-booted', '1'); });
    return GTDev.booting;
  }

  // ?do= actions, for screenshots of states that need a gesture or a save.
  GTDev.act = function (list) {
    var GT = global.GT, A = GT.app, S = A.S, s = S.session;
    if (!s) {
      // Home and chooser pages have no session; only the New chart form applies.
      if (/(^|,)newchart(,|$)/.test(String(list))) A.newChartForm();
      return Promise.resolve();
    }
    return Promise.all([s.resolved, s.checked]).then(function () {
      String(list).split(',').forEach(function (a) {
        var p = a.split(':'), c = s.live, t = c && p[1] ? GT.model.task(c, p[1]) : null;
        if (p[0] === 'sel') A.select(p[1]);
        else if (p[0] === 'sheet') { A.select(p[1]); A.openSheet(p[1], p[2] || 'peek'); }
        else if (p[0] === 'lift') { A.select(p[1]); S.view.setPreview({ kind: 'lift', id: p[1] }); }
        else if (p[0] === 'drag' && t) {
          var d = +p[2], r = { start: t.start + d, end: t.end === null ? null : t.end + d, delta: d };
          var rect = S.view.barRect(p[1]), vs = S.view.viewSize();
          A.select(p[1]);
          S.view.setPreview({ kind: 'move', id: p[1], start: r.start, end: r.end,
            bubble: GT.i18n.date.range(r.start, r.end === null ? r.start : r.end) + ' · ' + GT.i18n.fmt('{n}d', { n: r.end === null ? 1 : r.end - r.start + 1 }),
            delta: GT.i18n.fmt('+{n}d', { n: d }),
            bx: rect ? rect.x - vs.metrics.nameW + rect.w / 2 + d * S.view.camera().ppd : 100, by: rect ? rect.y - vs.metrics.hdrH : 100 });
          S.gestures && global.document.getElementById('gantt').classList.add('live');
        }
        else if (p[0] === 'notice') A.showNotice();
        else if (p[0] === 'manual') { S.store.launch.mode = 'manual'; S.store.launch.sessionApproved = false; A.syncUi(); }
        else if (p[0] === 'commit' && t) A.commitEdit(GT.model.moveTask(c, p[1], +p[2]), 'Move', p[1]);
        else if (p[0] === 'zoom') S.view.setPreset(p[1]);
        else if (p[0] === 'fit') S.view.fitAll();
        else if (p[0] === 'day') S.view.showDay(GT.dates.parse(p[1]));
        // M7: the FAB menu, the create sheet, the new chart form.
        else if (p[0] === 'fab') A.openFab();
        else if (p[0] === 'create') { if (p[1]) A.select(p[1]); A.createTaskForm(); }
        else if (p[0] === 'newchart') A.newChartForm();
        else if (p[0] === 'quiet') A.dismissNotice();
        // M8: the settings, display and appearance sheets, the legend, the loading rows.
        else if (p[0] === 'settings') A.openSettings();
        else if (p[0] === 'display') A.openDisplay();
        else if (p[0] === 'appearance') A.openAppearance();
        else if (p[0] === 'more') A.openMore();
        else if (p[0] === 'legend') A.setPref('legend', p[1] !== 'off');
        else if (p[0] === 'skeleton') { S.view.setData({ chart: null }); A.skeleton(true); }
        else if (p[0] === 'collapse') A.setAllGroups(true);
        else if (p[0] === 'names') A.setNameW(+p[1], false);
        // Device feedback round 1: the corner toggle (collapse / expand the name column).
        else if (p[0] === 'ntog') A.toggleNames();
        // Export image: the PNG the export would attach, shown over the page at its CSS size.
        else if (p[0] === 'exportshow') {
          var ex = A.exportSvg(p[1] === 'view' ? 'view' : 'all');
          GT.exporter.toPng(ex.svg, ex.w, ex.h, document).then(function (png) {
            var im = document.createElement('img');
            im.src = png.dataUrl;
            im.id = 'export-preview';
            im.style.cssText = 'position:fixed;left:0;top:0;z-index:99;width:' + ex.w + 'px;height:' + ex.h + 'px;background:#888';
            document.body.appendChild(im);
          });
        }
        else if (p[0] === 'pick') {
          var sw = document.querySelector('#sheet .sw[data-color="' + p[1] + '"]');
          if (sw) { sw.click(); sw.scrollIntoView({ block: 'nearest', inline: 'center' }); }
          if (p[2] === 'close') S.sheet.close();
        }
        // M9: the Task list view, and a live locale switch.
        else if (p[0] === 'tasklist') A.openTaskList();
        else if (p[0] === 'locale') GTDev.mock.emit('localechanged', p[1]);
      });
      A.syncUi();
    });
  };
})(typeof window !== 'undefined' ? window : globalThis);
