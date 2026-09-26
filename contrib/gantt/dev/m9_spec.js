/*
 * Gantt M9 assertions: the i18n coverage audit over every UI module and the
 * shell (with its own mutants), the en-US / zh-CN date formatters and week
 * rules from the raw host tag, the synapse:resumed trigger and both bridge
 * error forms (host.js), the resume tuning of store.refresh (bridge call
 * counts), the reconciliation banner's store half (mirrorGap, Restore list,
 * anchorToRead) and the cjk.json fixture. Runs under node (dev/run.js) and
 * in the browser (dev/auto_smoke.html); the source audit is node only.
 */
(function (global) {
  'use strict';
  var GT = global.GT, H = GT.host, B = GT.block, M = GT.model, S = GT.store, D = GT.dates, I = GT.i18n, SPEC = GT.spec;
  var A = SPEC.api, ok = A.ok, eq = A.eq, same = A.same, acase = A.acase;

  /* ------------------------------------------------ the source audit */

  // String literals of a JS source (comments, regex literals and template
  // expressions skipped). -> [{q, text}]
  function literals(code) {
    var out = [], i = 0, n = code.length, last = '';
    var KW = { 'return': 1, 'typeof': 1, 'case': 1, 'in': 1, 'of': 1, 'new': 1, 'delete': 1, 'void': 1, 'throw': 1, 'else': 1, 'do': 1 };
    function unesc(s) {
      return s.replace(/\\(u[0-9a-fA-F]{4}|x[0-9a-fA-F]{2}|[\s\S])/g, function (m, e) {
        if (e[0] === 'u' && e.length === 5) return String.fromCharCode(parseInt(e.slice(1), 16));
        if (e[0] === 'x' && e.length === 3) return String.fromCharCode(parseInt(e.slice(1), 16));
        return { n: '\n', t: '\t', r: '\r' }[e] || (e === '\n' ? '' : e);
      });
    }
    while (i < n) {
      var c = code[i];
      if (c === '/' && code[i + 1] === '/') { var nl = code.indexOf('\n', i); i = nl < 0 ? n : nl; continue; }
      if (c === '/' && code[i + 1] === '*') { var e2 = code.indexOf('*/', i + 2); i = e2 < 0 ? n : e2 + 2; continue; }
      if (c === '\'' || c === '"' || c === '`') {
        var j = i + 1, s = '', tpl = false;
        while (j < n && code[j] !== c) {
          if (code[j] === '\\') { s += code[j] + code[j + 1]; j += 2; continue; }
          if (c === '`' && code[j] === '$' && code[j + 1] === '{') tpl = true;
          s += code[j]; j++;
        }
        if (!tpl) out.push({ q: c, text: unesc(s) });
        i = j + 1; last = 'x';
        continue;
      }
      if (c === '/' && (last === '' || /[(,=:[!&|?{};+\-*%<>~^]/.test(last))) {
        var k = i + 1, cls = false;
        while (k < n) {
          var d = code[k];
          if (d === '\\') { k += 2; continue; }
          if (d === '[') cls = true; else if (d === ']') cls = false; else if ((d === '/' && !cls) || d === '\n') break;
          k++;
        }
        i = k + 1;
        while (i < n && /[a-z]/.test(code[i])) i++;
        last = 'x';
        continue;
      }
      if (/[A-Za-z_$]/.test(c)) {
        var w = /^[A-Za-z_$][\w$]*/.exec(code.slice(i, i + 40))[0];
        last = KW[w] ? '(' : 'x';
        i += w.length;
        continue;
      }
      if (/[0-9]/.test(c)) { last = 'x'; i++; continue; }
      if (!/\s/.test(c)) last = c === ')' || c === ']' ? 'x' : c;
      i++;
    }
    return out;
  }
  GT.m9 = { literals: literals };

  // Modules whose strings reach the screen: the three that write to the DOM
  // (§4.2 rule), layout.js (legend labels) and i18n.js (taskLabel).
  var UI_MODULES = ['app.js', 'render.js', 'sheet.js', 'layout.js', 'i18n.js'];
  // Literals that look like English but are not UI text.
  var NOT_UI = ['Escape', 'Delete', 'Backspace', 'Enter', 'Tab', 'Home', 'End', 'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown',
    'INPUT', 'TEXTAREA', 'BUTTON', 'SELECT', 'MOVE', 'RESIZE_S', 'RESIZE_E', 'REORDER', 'ARMED', 'UTC',
    'SF Pro Text', 'PingFang SC', 'Hiragino Sans GB', 'Noto Sans CJK SC', 'Microsoft YaHei', 'Noto Sans'];
  function uiLike(v) {
    if (!/[A-Za-z]{2}/.test(v) || NOT_UI.indexOf(v) >= 0) return false;
    if (/^M[\d.]/.test(v)) return false;                                  // SVG path data
    return /^[A-Z]/.test(v) || /^\{\w+\}[^{]*[A-Za-z]{2}/.test(v);
  }
  function slots(s) { return (String(s).match(/\{\w+\}/g) || []).sort().join(','); }

  /*
   * coverage(sources, shell, zh, patterns) -> [missing]: every English UI
   * string any UI module can show, and every label of the shell, must have
   * a zh-CN entry (a pattern for strings with {slots}).
   */
  function coverage(src, shell, zh, patterns) {
    var miss = [];
    function has(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }
    function need(where, v) {
      if (/\{\w+\}/.test(v)) { if (!has(patterns, v)) miss.push(where + ' pattern: ' + v); }
      else if (!has(zh, v)) miss.push(where + ': ' + v);
    }
    UI_MODULES.forEach(function (f) {
      var code = src[f] || '';
      // The tables themselves are the translations, not UI text to check.
      if (f === 'i18n.js') code = code.replace(/var ZH = \{[\s\S]*?\n {2}\};/, '').replace(/var ZH_PATTERNS = \{[\s\S]*?\n {2}\};/, '');
      literals(code).forEach(function (l) { if (uiLike(l.text)) need(f, l.text); });
      // Every argument of a translation call, whatever its case.
      code.replace(/\b(?:T|text)\('((?:[^'\\]|\\.)*)'\)/g, function (m, k) { need(f + ' T()', k.replace(/\\'/g, '\'')); return m; });
      code.replace(/\bfmt\('((?:[^'\\]|\\.)*)'/g, function (m, k) {
        k = k.replace(/\\'/g, '\'');
        if (!has(patterns, k)) miss.push(f + ' fmt(): ' + k);
        return m;
      });
    });
    var body = (shell.split(/<body[^>]*>/)[1] || '').replace(/<script[\s\S]*?<\/script>/g, '').replace(/<svg[\s\S]*?<\/svg>/g, '');
    body.replace(/data-i18n(?:-label)?="([^"]+)"/g, function (m, k) { need('gantt.html', k); return m; });
    // An aria-label in the shell is kept by data-i18n-label (applyI18n).
    body.replace(/<[^>]*\baria-label="([^"]+)"[^>]*>/g, function (m, k) {
      if (m.indexOf('data-i18n-label="' + k + '"') < 0) miss.push('gantt.html aria-label without data-i18n-label: ' + k);
      return m;
    });
    // Visible text sits on an element that names it in data-i18n. The top
    // bar title is written by app.js (T('Gantt') or the chart's title).
    body.replace(/<([a-z]+)([^>]*)>([^<]*[A-Za-z][^<]*)</g, function (m, tag, attrs, t) {
      t = t.trim();
      if (!t || /id="title"/.test(attrs)) return m;
      if (attrs.indexOf('data-i18n="' + t + '"') < 0) miss.push('gantt.html text without data-i18n: ' + t);
      return m;
    });
    Object.keys(patterns).forEach(function (k) { if (slots(k) !== slots(patterns[k])) miss.push('pattern slots differ: ' + k); });
    return miss;
  }

  function coverageSpec() {
    var src = global.GT_SOURCES, shell = global.GT_SHELL;
    if (!src || !shell) { ok('the i18n audit needs GT_SOURCES and GT_SHELL (node only)', true); return; }
    // The tokenizer itself.
    var lit = literals("var a = 'x // y', b = /['\"]z/g; // 'not me'\n/* 'nor me' */ c(\"Say \\\"hi\\\"\", `t`, `u${v}`); d = x / 2 / 'k';");
    eq('audit: literals skip comments, regexes and template expressions', lit.map(function (l) { return l.text; }).join('|'), 'x // y|Say "hi"|t|k');
    var found = 0;
    UI_MODULES.forEach(function (f) { found += literals(src[f] || '').filter(function (l) { return uiLike(l.text); }).length; });
    ok('audit: the UI modules hold at least 350 English UI strings', found >= 350, String(found));
    ok('audit: every module that writes to the DOM is audited', ['app.js', 'render.js', 'sheet.js'].every(function (f) { return UI_MODULES.indexOf(f) >= 0; }));
    var miss = coverage(src, shell, I.ZH, I.PATTERNS);
    eq('i18n coverage: every UI string of every module and of the shell has a zh-CN entry', miss.join('\n'), '');
    // Mutants: the audit fails on a deliberately missing entry.
    var zh = Object.assign({}, I.ZH); delete zh['Task list'];
    ok('audit mutant: a removed ZH entry is reported', coverage(src, shell, zh, I.PATTERNS).indexOf('app.js: Task list') >= 0);
    var zh2 = Object.assign({}, I.ZH); delete zh2['Name column width'];
    ok('audit mutant: a removed entry of a shell label is reported', coverage(src, shell, zh2, I.PATTERNS).some(function (x) { return /gantt\.html: Name column width/.test(x); }));
    var pt = Object.assign({}, I.PATTERNS); delete pt['{title}, {n} task(s)'];
    ok('audit mutant: a removed pattern is reported', coverage(src, shell, I.ZH, pt).some(function (x) { return /fmt\(\): \{title\}, \{n\} task\(s\)/.test(x); }));
    var src2 = Object.assign({}, src); src2['sheet.js'] = src['sheet.js'] + "\nel('div', null, 'A brand new label');";
    ok('audit mutant: a new English literal without an entry is reported', coverage(src2, shell, I.ZH, I.PATTERNS).indexOf('sheet.js: A brand new label') >= 0);
    var shell2 = shell.replace('data-i18n-label="Zoom level" aria-label="Zoom level"', 'aria-label="Zoom level"');
    ok('audit mutant: an aria-label the shell cannot relabel is reported', coverage(src, shell2, I.ZH, I.PATTERNS).some(function (x) { return /without data-i18n-label: Zoom level/.test(x); }));
    var pt2 = Object.assign({}, I.PATTERNS); pt2['{n} more'] = '另外 {m} 个';
    ok('audit mutant: a pattern whose slots differ is reported', coverage(src, shell, I.ZH, pt2).indexOf('pattern slots differ: {n} more') >= 0);
  }

  /* ------------------------------------------- dates and week rules */

  function datesSpec() {
    var d = D.parse('2026-03-03'), e = D.parse('2026-04-09'), saved = I.language;
    function sp(x) { return String(x).replace(/[    ]/g, ' '); }
    I.setLanguage('en-US');
    eq('en-US: dates follow the host tag', I.dateTag, 'en-US');
    eq('en-US formatters', [I.date.monthYear(d), I.date.monthShort(d), I.date.dayNum(d), I.date.weekdayNarrow(d), I.date.short(d), I.date.long(d), I.date.week(10), I.date.quarter(d)].join('|'),
      'March 2026|Mar|3|T|Mar 3|Tue, Mar 3, 2026|W10|Q1');
    eq('en-US range across months', sp(I.date.range(d, e)), sp('Mar 3 – Apr 9'));
    eq('en-US weekdayLong', I.date.weekdayLong(d), 'Tuesday');
    eq('en-US list', I.list(['A', 'B', 'C']), 'A, B, and C');
    eq('en-US: weeks start on Sunday, weekend Sat and Sun', I.weekStart({}) + '|' + I.weekendDays().slice().sort().join(','), '0|0,6');
    I.setLanguage('zh-CN');
    eq('zh-CN formatters', [I.date.monthYear(d), I.date.monthShort(d), I.date.dayNum(d), I.date.weekdayNarrow(d), I.date.short(d), I.date.long(d), I.date.week(10), I.date.quarter(d)].join('|'),
      '2026年3月|3月|3|二|3月3日|2026年3月3日 周二|第10周|第1季度');
    eq('zh-CN range across months (with 至, like the single date)', I.date.range(d, e), '3月3日至4月9日');
    eq('zh-CN range within a month drops the repeated month', I.date.range(d, D.parse('2026-03-09')), '3月3日至9日');
    eq('zh-CN range across years keeps both', I.date.range(D.parse('2026-12-30'), D.parse('2027-01-02')), '12月30日至1月2日');
    eq('zh-CN weekdayLong', I.date.weekdayLong(d), '星期二');
    eq('zh-CN list', I.list(['甲', '乙', '丙']), '甲、乙和丙');
    eq('zh-CN: weeks start on Monday', I.weekStart({}), 1);
    eq('zh-CN: settings.weekStart still wins', I.weekStart({ weekStart: 0 }), 0);
    // The raw host tag: en-GB keeps the English UI and writes British dates.
    I.setLanguage('en-GB');
    eq('en-GB: English UI, en-GB dates', I.language + '|' + I.dateTag + '|' + I.text('Undo'), 'en-US|en-GB|Undo');
    ok('en-GB short and long (day before month)', /^3 Mar\|Tue,? 3 Mar 2026$/.test(I.date.short(d) + '|' + I.date.long(d)), I.date.short(d) + '|' + I.date.long(d));
    eq('en-GB: Monday weeks', I.weekStart({}), 1);
    I.setLanguage('fr-FR');
    eq('fr-FR: an English UI never shows French month names', I.language + '|' + I.dateTag + '|' + I.date.short(d), 'en-US|en-US|Mar 3');
    I.setLanguage('zh-Hans-CN');
    eq('zh-Hans-CN: the zh-CN UI with the raw tag for dates', I.language + '|' + I.dateTag + '|' + I.date.short(d), 'zh-CN|zh-Hans-CN|3月3日');
    I.setLanguage('zh-TW');
    eq('zh-TW: the English UI (only zh-CN is translated)', I.language + '|' + I.dateTag, 'en-US|en-US');
    I.setLanguage('ar-EG');
    eq('ar-EG: the weekend from the region (Fri, Sat)', I.weekendDays().join(','), '5,6');
    I.setLanguage(saved);
    // Mirror lines are never localised (§5.1): the same text in any language.
    var c = M.coerce({ v: 1, tasks: [{ id: 't1', note: 'n1', title: 'A', start: '2026-10-01', end: '2026-10-09' }] }).chart;
    I.setLanguage('en-US');
    var en = B.region(c, function () { return { done: 3, total: 5 }; }, {});
    I.setLanguage('zh-CN');
    var zh = B.region(c, function () { return { done: 3, total: 5 }; }, {});
    I.setLanguage(saved);
    ok('mirror lines are the same in every UI language', en === zh && en.indexOf(' · 2026-10-01 → 2026-10-09 · 3/5') > 0, zh);
  }

  /* ---------------------------------------------------- the CJK fixture */

  function cjkSpec() {
    var raw = SPEC.api.fix('cjk.json'), data = JSON.parse(raw);
    var r = M.coerce(data);
    eq('cjk.json: coerces with nothing dropped', r.dropped, 0);
    var c = r.chart, text = '季度计划说明。\n\n' + B.region(c, null, {});
    var fr = B.read(text);
    ok('cjk.json: the region round-trips', fr.status === 'ok' && S.same(fr.chart, c) && fr.region.text === B.region(c, null, {}));
    ok('cjk.json: the mirror carries the CJK titles as typed', text.indexOf('- **需求调研**') >= 0 && text.indexOf('[用户访谈（二十位核心用户，覆盖三个城市）](synapseresource://note/cjk-note-2?via=gantt)') >= 0);
    eq('cjk.json: a note-less milestone has no mirror line', text.indexOf('正式发布](') < 0 && text.indexOf('"title":"正式发布"') > 0, true);
    var saved = I.language;
    I.setLanguage('zh-CN');
    var t = M.task(c, 't3');
    eq('cjk.json: the zh-CN task label', I.taskLabel(t, { done: 1, total: 4 }).replace(/[    ]/g, ' '), '竞品分析，10月12日至19日，8 天，已完成 1/4');
    I.setLanguage(saved);
    eq('cjk.json: no mirror gap in a region the plugin wrote', JSON.stringify(B.mirrorGap(text)), JSON.stringify({ key: fr.key, deleted: [], edited: [] }));
  }

  /* ------------------------------------------------ host: resumed, errors */

  function mk(seed, o) { return H.installMock(seed, Object.assign({ storage: new Map(), global: false }, o || {})); }

  function hostSpec() {
    acase('M9 host: synapse:resumed fires onResume once, coalesced with the other triggers', function () {
      var t = 0, m = mk([{ id: 'a' }], { now: function () { return t; } }), h = m.host, got = [];
      var off = h.onResume(function (why) { got.push(why); });
      m.dispatch('synapse:resumed');
      eq('resumed: fires onResume', got.join(','), 'resumed');
      t = 100; m.dispatch('focus'); m.setVisible(true);
      eq('resumed: focus and visible within 250 ms coalesce with it', got.length, 1);
      t = 400; m.dispatch('synapse:resumed');
      t = 450; m.dispatch('synapse:resumed');
      eq('resumed: two within 250 ms fire once', got.join(','), 'resumed,resumed');
      return h.openNote('a').then(function () {
        t = 1000; m.dispatch('synapse:resumed');
        t = 1400; m.dispatch('pointerdown');
        eq('resumed: after openNote it disarms the first-pointer trigger (no second refresh)', got.join(','), 'resumed,resumed,resumed');
        off();
        t = 3000; m.dispatch('synapse:resumed');
        eq('resumed: off() removes the listener', got.length, 3);
        eq('resumed: no listener left', m.win.count('synapse:resumed'), 0);
      });
    });

    acase('M9 host: saveRegion reads both bridge error forms (before and since M10)', function () {
      var chart = M.coerce({ v: 1, settings: { mirror: false }, tasks: [{ id: 't1', note: 'task-1', title: 'A', start: '2026-10-01' }] }).chart;
      var region = B.region(chart, null, {});
      function run(style) {
        var m = mk([{ id: 'chart-1', content: 'Intro.\n\n' + region }, { id: 'task-1', type: 'task' }], { errors: style, sessionApproved: true });
        return m.host.saveRegion('chart-1', 'not in the note', region, [{ id: 'task-1', scheduledAt: '2026-10-02', completeBy: '2026-10-02' }]).then(function (r) {
          ok(style + ': a missing region fails the chart', !r.ok && !r.denied, JSON.stringify(r));
          ok(style + ': its error names the chart', /^Updating note chart-1 failed/.test(r.error || ''), r.error);
          if (style === 'verbatim') ok('verbatim: the message follows a colon', /^Updating note chart-1 failed: \S/.test(r.error), r.error);
          else eq('redacted: the old text', r.error, 'Updating note chart-1 failed. See the app log for details.');
        });
      }
      return run('redacted').then(function () { return run('verbatim'); }).then(function () {
        // A message that quotes another note's id does not name that note.
        var m = mk([{ id: 'c', content: 'x' }, { id: 'task-9', type: 'task' }], { sessionApproved: true });
        m.script('updateNotes', [{ success: true, updatedCount: 1, errors: ['Updating note c failed: old_text not found: [T](synapseresource://note/task-9?via=gantt)'] }]);
        return m.host.saveRegion('c', 'x', 'y', [{ id: 'task-9', scheduledAt: '2026-01-01' }]);
      }).then(function (r) {
        ok('verbatim: the chart failed', !r.ok && /^Updating note c failed: /.test(r.error));
        eq('verbatim: a quoted id is not a failed date entry (all are resent, as for any chart failure)', r.failedDates.length, 1);
        var m = mk([{ id: 'c', content: 'x' }, { id: 'task-9', type: 'task' }], { sessionApproved: true });
        m.script('updateNotes', [{ success: true, updatedCount: 1, errors: ['Updating note task-9 failed: Note is read-only'] }]);
        return m.host.saveRegion('c', 'x', 'y', [{ id: 'task-9', scheduledAt: '2026-01-01' }]);
      }).then(function (r) {
        ok('verbatim: a failed date entry never fails the chart', r.ok && r.failedDates.length === 1 && r.failedDates[0].id === 'task-9', JSON.stringify(r));
        // A date entry's message that quotes the chart id names the date
        // entry only (the old whole-text search would fail the chart).
        var m = mk([{ id: 'chart-7', content: 'x' }, { id: 'task-9', type: 'task' }], { sessionApproved: true });
        m.script('updateNotes', [{ success: true, updatedCount: 1, errors: ['Updating note task-9 failed: it is not linked from chart-7'] }]);
        return m.host.saveRegion('chart-7', 'x', 'y', [{ id: 'task-9', scheduledAt: '2026-01-01' }]);
      }).then(function (r) {
        ok('verbatim: a message quoting the chart id does not fail the chart', r.ok && r.failedDates.length === 1, JSON.stringify(r));
      });
    });
  }

  /* ------------------------------------------------ store: resume tuning */

  var CH = 'chart-1';
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function chartS(settings) {
    return M.coerce({ v: 1, settings: settings || {}, tasks: [
      { id: 't1', note: 'n1', title: 'Task one', start: '2026-10-03', end: '2026-10-10' },
      { id: 't2', note: 'n2', title: 'Task two', start: '2026-10-05', end: '2026-10-12' }] }).chart;
  }
  function noteText(c) { return 'Intro text.\n\n' + B.region(c, null, {}); }
  function env(o) {
    o = o || {};
    var storage = o.storage || new Map(), q = [], flags = { hidden: false }, tq = [];
    var mo = Object.assign({ storage: storage, global: false, appId: 'gantt-m9-test' }, o.mock || {});
    if (o.db) mo.db = o.db;
    var mock = H.installMock(o.db ? null : o.seed, mo);
    var t = 1790000000000;
    var st = S.create({
      host: mock.host, frame: function (f) { var h = { f: f }; q.push(h); return h; }, cancelFrame: function (h) { var i = q.indexOf(h); if (i >= 0) q.splice(i, 1); },
      now: function () { t += 7; return t; }, hidden: function () { return flags.hidden; },
      setTimeout: function (f, ms) { var x = { f: f, ms: ms }; tq.push(x); return x; }, clearTimeout: function (x) { var i = tq.indexOf(x); if (i >= 0) tq.splice(i, 1); }
    });
    var e = { mock: mock, st: st, storage: storage, flags: flags, events: [] };
    e.frames = function () { var a = q.splice(0); a.forEach(function (h) { h.f(); }); return a.length; };
    // Fires the pending timers of one delay (the 2 s cache write, S.CACHE_MS).
    e.fire = function (ms) { var a = tq.filter(function (x) { return x.ms === ms; }); a.forEach(function (x) { tq.splice(tq.indexOf(x), 1); x.f(); }); return a.length; };
    ['live', 'facts', 'read'].forEach(function (n) { st.on(n, function () { e.events.push(n); }); });
    return e;
  }
  function settle(e) {
    var p = Promise.resolve();
    for (var i = 0; i < 6; i++) p = p.then(function () { return sleep(0); });
    return p.then(function () { e.frames(); return e.st.state.idle(); }).then(function () { return sleep(0); });
  }
  function world(o) {
    o = o || {};
    var S0 = o.S || chartS();
    var e = env({ seed: o.seed || [{ id: CH, title: 'Plan', content: o.text || noteText(S0) },
      { id: 'n1', title: 'Task one', type: 'task' }, { id: 'n2', title: 'Task two', type: 'task' }], storage: o.storage, db: o.db, mock: o.mock });
    if (o.approved !== false) { e.st.launch.sessionApproved = true; e.mock.sessionApproved = true; }
    return e.st.boot().then(function () { return e.st.open(o.read ? { noteId: CH, read: B.read(e.mock.content(CH)) } : CH); }).then(function (r) {
      e.s = r.session;
      return Promise.all([e.s.checked, e.s.resolved]);
    }).then(function () { return settle(e); }).then(function () { return e; });
  }
  function contentReads(e) { return e.mock.queries.filter(function (q) { return /SELECT content,/.test(String(q.sql || q)); }).length; }

  function tuningSpec() {
    acase('M9 resume: nothing changed means no content read, no appState write, no re-render', function () {
      var e;
      return world({ read: true }).then(function (w) {
        e = w;
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () {
        e.mock.resetCounts(); e.events.length = 0;
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () {
        eq('resume: one loadAppState (the journal refresh, §9.1.4 rule 5)', e.mock.count('loadAppState'), 1);
        eq('resume: no chart note content read (probed by updatedAt and length)', contentReads(e), 0);
        eq('resume: three queries in all (7.1 with the chart note, 7.2, 7.3)', e.mock.count('runQuery'), 3);
        eq('resume: no storeAppState', e.mock.count('storeAppState'), 0);
        eq('resume: no updateNotes', e.mock.count('updateNotes'), 0);
        eq('resume: no live, facts or read event (nothing re-renders)', e.events.join(','), '');
        // A change to the chart note is still seen at the next resume.
        e.mock.setNote(CH, noteText(M.moveTask(chartS(), 't1', 2).chart));
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () {
        eq('resume: a changed chart note is read', contentReads(e), 1);
        eq('resume: ... and reloaded silently', M.task(e.s.live, 't1').start, D.parse('2026-10-05'));
        ok('resume: ... with a live and a read event', e.events.indexOf('live') >= 0 && e.events.indexOf('read') >= 0, e.events.join(','));
      });
    });

    acase('M9 resume: the 30 s interval only while shown; one refresh at a time', function () {
      var e;
      return world({ read: true }).then(function (w) {
        e = w;
        return e.st.onHide('pagehide');
      }).then(function () { return settle(e); }).then(function () {
        e.mock.resetCounts();
        e.mock.tickInterval();
        return settle(e);
      }).then(function () {
        eq('interval after pagehide: no bridge call', Object.keys(e.mock.calls).length, 0);
        return e.st.refresh('interval');
      }).then(function () {
        eq('interval again: still none (pagehide is not undone by a tick)', Object.keys(e.mock.calls).length, 0);
        return e.st.refresh('focus');
      }).then(function () { return settle(e); }).then(function () {
        ok('focus: the page is back and refreshes', e.mock.count('loadAppState') === 1 && e.mock.count('runQuery') >= 1);
        e.mock.resetCounts();
        var p1 = e.st.refresh('focus'), p2 = e.st.refresh('visible');
        ok('a trigger during a refresh joins it (the same promise)', p1 === p2);
        return p1;
      }).then(function () { return settle(e); }).then(function () {
        eq('... and one more refresh runs after it, not alongside', e.mock.count('loadAppState'), 2);
      });
    });
  }

  /* ------------------------------------------------ M9 review round 1 */

  function reviewSpec() {
    acase('M9 r1: a silent reload deferred by unsaved edits runs once they are gone', function () {
      var e, S0 = chartS(), E = M.moveTask(chartS(), 't2', 3).chart;
      return world({ read: true }).then(function (w) {
        e = w;
        e.st.launch.mode = 'manual';
        ok('(setup) an unsaved edit', e.st.commit(M.moveTask(e.s.live, 't1', 1).chart, { save: 'none' }));
        e.mock.setNote(CH, noteText(E));
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () {
        eq('the resume defers the reload while live differs from base', M.task(e.s.live, 't2').start, M.task(S0, 't2').start);
        ok('(setup) back to base', e.st.commit(e.s.base, { save: 'none' }) && S.same(e.s.live, e.s.base));
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () {
        ok('the next resume reloads although the note is as last read', S.same(e.s.live, E), JSON.stringify(M.toData(e.s.live)));
        e.mock.resetCounts();
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () {
        eq('after it, an unchanged note is not read again', contentReads(e), 0);
      });
    });

    acase('M9 r1: an interval tick joined before pagehide does not wake the page', function () {
      var e;
      return world({ read: true }).then(function (w) {
        e = w;
        var p = e.st.refresh('focus');
        e.st.refresh('interval');
        e.st.onHide('pagehide');
        return p;
      }).then(function () { return settle(e); }).then(function () {
        e.mock.resetCounts();
        return e.st.refresh('interval');
      }).then(function () { return settle(e); }).then(function () {
        eq('a later tick still makes no bridge call (pagehide kept)', e.mock.count('loadAppState') + e.mock.count('runQuery'), 0);
      });
    });

    acase('M9 r1: the cache keeps the latest written key, not an older one', function () {
      var e, A1 = M.moveTask(chartS(), 't1', 2).chart, A2;
      return world({ read: true }).then(function (w) {
        e = w;
        e.st.commit(A1);
        return settle(e);
      }).then(function () { return e.mock.resume(); }).then(function () { return settle(e); }).then(function () {
        eq('(setup) first key cached', e.st.cache.get(CH).wk, S.keyOf(A1));
        A2 = M.moveTask(e.s.live, 't2', 1).chart;
        e.st.commit(A2);
        return settle(e);
      }).then(function () { return e.mock.resume(); }).then(function () { return settle(e); }).then(function () {
        eq('the second save replaces the cached key', e.st.cache.get(CH).wk, S.keyOf(A2));
      });
    });

    acase('M9 r1: synapse:resumed right after an interval tick still refreshes', function () {
      var t = 0, m = mk([{ id: 'a' }], { now: function () { return t; } }), got = [];
      m.host.onResume(function (why) { got.push(why); });
      m.tickInterval();
      t = 50; m.dispatch('synapse:resumed');
      eq('resumed is not dropped behind a tick', got.join(','), 'interval,resumed');
      t = 100; m.dispatch('focus');
      eq('... and triggers after it coalesce with it', got.length, 2);
    });

    acase('M9 r1: verbatim errors (M10 texts), plugin-facing only', function () {
      var m = mk([{ id: 'c', content: 'one\ntwo two' }, { id: 'r', content: 'x' }], { errors: 'verbatim', sessionApproved: true });
      m.refuse('r');
      return m.host.replaceText('c', 'three', 'four').then(function (r) {
        eq('not found', r.error, 'Updating note c failed: replace_text: "old_text" was not found in the note; no changes were made. Read the note and copy the text to replace exactly. If you already applied this edit, no further action is needed.');
        return m.host.replaceText('c', 'two', 'x');
      }).then(function (r) {
        eq('two matches', r.error, 'Updating note c failed: replace_text: "old_text" matched 2 places in the note; no changes were made. Provide a longer, unique old_text or add "section" to disambiguate.');
        return m.host.replaceText('c', 'one', 'x', '## Z');
      }).then(function (r) {
        eq('section not found', r.error, 'Updating note c failed: Section not found: ## Z');
        return m.host.replaceText('r', 'x', 'y');
      }).then(function (r) {
        eq('any other failure stays redacted', r.error, 'Updating note r failed. See the app log for details.');
      });
    });
  }
  SPEC.suites.push({ name: 'the M9 review round 1', fn: reviewSpec });

  /* --------------------------------------- store: the reconciliation half */

  function dropLine(text, noteId) {
    return text.split('\n').filter(function (l) { return l.indexOf('synapseresource://note/' + noteId + '?via=gantt') < 0; }).join('\n');
  }
  function reconcileSpec() {
    acase('M9 reconciliation: a deleted line is reported, never removed, and Restore list rewrites it', function () {
      var e, A5 = M.moveTask(chartS(), 't1', 2).chart;
      return world({ read: true }).then(function (w) {
        e = w;
        eq('open: no gap before the plugin wrote this block', e.st.mirrorGap(), null);
        ok('commit', e.st.commit(A5));
        return settle(e);
      }).then(function () {
        eq('the save wrote the block (wroteKey)', e.s.wroteKey, S.keyOf(A5));
        e.mock.setNote(CH, dropLine(e.mock.content(CH), 'n2'));
        e.mock.resetCounts();
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () {
        same('the deleted line is reported', e.st.mirrorGap(), { deleted: ['t2'], edited: [] });
        eq('nothing is written without a tap', e.mock.count('updateNotes'), 0);
        ok('the task stays on the chart', !!M.task(e.s.live, 't2'));
        return sleep(20).then(function () { return e.mock.resume(); }).then(function () { return settle(e); });
      }).then(function () {
        eq('... also after another resume', e.mock.count('updateNotes') + '|' + !!M.task(e.s.live, 't2'), '0|true');
        return e.st.restoreMirror();
      }).then(function (r) {
        ok('Restore list saves', r && r.ok, JSON.stringify(r));
        eq('Restore list: one updateNotes', e.mock.count('updateNotes'), 1);
        ok('the note has the line again', e.mock.content(CH).indexOf('synapseresource://note/n2?via=gantt') > 0);
        ok('the chart is unchanged', S.same(e.s.live, A5));
        eq('no gap after', e.st.mirrorGap(), null);
        same('and the note reads without a gap', B.mirrorGap(e.mock.content(CH)).deleted, []);
      });
    });

    acase('M9 reconciliation: an edited line is kept text; foreign and hand-written blocks never count', function () {
      var e, A5 = M.moveTask(chartS(), 't1', 2).chart;
      return world({ read: true }).then(function (w) {
        e = w;
        e.st.commit(A5);
        return settle(e);
      }).then(function () {
        // Text after the first line's progress breaks the grammar: kept.
        var lines = e.mock.content(CH).split('\n');
        var i = lines.findIndex(function (l) { return l.indexOf('note/n1?via=gantt') > 0; });
        lines[i] += ' (asked Sam)';
        e.mock.setNote(CH, lines.join('\n'));
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () {
        same('an edited line is reported as edited, not deleted', e.st.mirrorGap(), { deleted: [], edited: ['t1'] });
        // Another device changed the block and dropped a line: not ours.
        var other = M.moveTask(A5, 't2', 1).chart;
        e.mock.setNote(CH, dropLine('Intro text.\n\n' + B.region(other, null, {}), 'n2'));
        return e.mock.resume();
      }).then(function () { return settle(e); }).then(function () {
        eq('a block changed elsewhere is not compared (its key is not the one written)', e.st.mirrorGap(), null);
      }).then(function () {
        // A hand-written chart with the mirror on but no list at all.
        var c = chartS();
        return world({ text: 'Hand made.\n\n' + B.fence(c) });
      }).then(function (h) {
        eq('a block the plugin never wrote has no gap', h.st.mirrorGap(), null);
        ok('(its lines are indeed absent)', B.mirrorGap(h.mock.content(CH)).deleted.length === 2);
      });
    });

    acase('M9 reconciliation: the written key survives a reload; anchorToRead lets a one-try save land', function () {
      var e, storage = new Map(), A5 = M.moveTask(chartS(), 't1', 2).chart;
      return world({ read: true, storage: storage }).then(function (w) {
        e = w;
        e.st.commit(A5);
        return settle(e);
      }).then(function () { return e.mock.resume(); }).then(function () { return settle(e); }).then(function () {
        var ce = e.st.cache.get(CH);
        eq('the cache keeps the written key (wk)', ce && ce.wk, S.keyOf(A5));
        e.fire(S.CACHE_MS);
        return settle(e);
      }).then(function () {
        var stored = e.mock.state();
        eq('... and appState stores it', stored && stored.charts && stored.charts[CH] && stored.charts[CH].wk, S.keyOf(A5));
        e.mock.setNote(CH, dropLine(e.mock.content(CH), 'n2'));
        return world({ db: e.mock.db, storage: storage, approved: false });
      }).then(function (r) {
        same('a reload reports the deleted line at open', r.st.mirrorGap(), { deleted: ['t2'], edited: [] });
        return r;
      }).then(function (r) {
        // In the same launch: a resume read finds the gap while s.region
        // still holds the old text. A one-try save (auto before approval)
        // would miss; re-anchored first, it writes.
        e.mock.setNote(CH, dropLine(e.mock.content(CH), 'n2'));
        e.st.launch.sessionApproved = false;
        return e.mock.resume().then(function () { return settle(e); }).then(function () {
          ok('the gap is seen in the running store', !!e.st.mirrorGap());
          ok('anchorToRead re-anchors to the note', e.st.anchorToRead() && e.s.region.indexOf('note/n2?via=gantt') < 0);
          var gone = M.removeTask(e.s.live, 't2');
          e.mock.resetCounts();
          ok('Remove commits', e.st.commit(gone.chart));
          return settle(e);
        }).then(function () {
          eq('one updateNotes, and it landed', e.mock.count('updateNotes') + '|' + (e.s.lastResult && e.s.lastResult.ok), '1|true');
          ok('the task is off the chart and the note', !M.task(e.s.live, 't2') && e.mock.content(CH).indexOf('"note":"n2"') < 0);
          ok('the task note itself is kept', !!e.mock.note('n2'));
          eq('no gap left', e.st.mirrorGap(), null);
        });
      });
    });
  }

  SPEC.suites.push({ name: 'the M9 i18n audit', fn: coverageSpec });
  SPEC.suites.push({ name: 'the M9 dates and week rules', fn: datesSpec });
  SPEC.suites.push({ name: 'the M9 CJK fixture', fn: cjkSpec });
  SPEC.suites.push({ name: 'the M9 host additions', fn: hostSpec });
  SPEC.suites.push({ name: 'the M9 resume tuning', fn: tuningSpec });
  SPEC.suites.push({ name: 'the M9 reconciliation (store)', fn: reconcileSpec });

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
