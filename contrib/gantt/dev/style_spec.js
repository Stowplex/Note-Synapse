/*
 * Gantt M8 assertions: completion styles (layout.segmentStops, dotsOf,
 * styleOf), colorFor in each colorBy mode, the legend, ghost bars, the
 * name column and density metrics, the lite threshold, week numbers and
 * the settings patches' inverses. Runs under node (dev/run.js) and in the
 * browser (dev/auto_smoke.html).
 */
(function (global) {
  'use strict';
  var GT = global.GT, SPEC = GT.spec;
  var A = SPEC.api, ok = A.ok, eq = A.eq;
  var LY = GT.layout, R = GT.render, M = GT.model, D = GT.dates, I = GT.i18n;
  var P = D.parse;

  function chart() {
    return M.coerce({
      v: 1,
      groups: [{ id: 'g1', title: 'Discovery' }, { id: 'g2', title: 'Build', color: 'teal' }],
      tasks: [
        { id: 't1', note: 'n1', title: 'A', start: '2026-10-01', end: '2026-10-09', group: 'g1' },
        { id: 't2', note: 'n2', title: 'B', start: '2026-10-05', end: '2026-10-14', group: 'g1', color: 'amber' },
        { id: 't3', note: 'n3', title: 'C', start: '2026-10-12', end: '2026-11-06', group: 'g2' },
        { id: 't4', note: 'n4', title: 'D', start: '2026-11-09', group: 'g2', milestone: true },
        { id: 't5', note: 'n5', title: 'E' }
      ]
    }).chart;
  }

  function segmentSpec() {
    var s = LY.segmentStops('101');
    eq('segments: one cell per bit', s.n, 3);
    eq('segments: done cells counted', s.done, 2);
    eq('segments: the exact mask (cells opaque, 2 px gaps transparent)', s.mask,
      'linear-gradient(90deg, #000 0 calc(33.3333% - 1px), transparent 0 calc(33.3333% + 1px), #000 0 calc(66.6667% - 1px), ' +
      'transparent 0 calc(66.6667% + 1px), #000 0 100%)');
    eq('segments: the exact done layer (fill in bits order)', s.image,
      'linear-gradient(90deg, var(--h-fill) 0 calc(33.3333% - 1px), transparent 0 calc(66.6667% - 1px), var(--h-fill) 0 100%)');
    eq('segments: not late, no hatch', s.late + '|' + /repeating/.test(s.image), 'false|false');
    var l = LY.segmentStops('100', undefined, true);
    // M8 review: the calmer late treatment, a 2 px --warn stripe over the open cells only (no hatch).
    eq('segments: late open cells get a --warn stripe layer over the open cells', l.image,
      'linear-gradient(90deg, var(--h-fill) 0 calc(33.3333% - 1px), transparent 0 calc(66.6667% - 1px), transparent 0 100%), ' +
      'linear-gradient(90deg, transparent 0 calc(33.3333% - 1px), var(--warn) 0 calc(66.6667% - 1px), var(--warn) 0 100%)');
    ok('segments: no repeating hatch anywhere', !/repeating/.test(l.image) && l.late);
    eq('segments: late but all done has no hatch', LY.segmentStops('11', undefined, true).late, false);
    eq('segments: one cell has no gap', LY.segmentStops('1').mask, 'linear-gradient(90deg, #000 0 100%)');
    // Fallbacks (§12.4): empty bits, more than 24 cells, cells under 6 px, not 0/1.
    eq('segments fallback: empty bits', LY.segmentStops(''), null);
    eq('segments fallback: no bits', LY.segmentStops(null), null);
    eq('segments fallback: 25 cells', LY.segmentStops(new Array(26).join('1')), null);
    ok('segments: 24 cells still render', LY.segmentStops(new Array(25).join('0')).n === 24);
    eq('segments fallback: not binary', LY.segmentStops('10a'), null);
    // 3 cells in 22 px: (22 - 2*2)/3 = 6 px, fits; 21 px does not.
    eq('segments: 3 cells fit 22 px', LY.segFits(3, 22), true);
    eq('segments fallback: 3 cells in 21 px are under 6 px', LY.segFits(3, 21), false);
    eq('segments fallback: width passed to segmentStops', LY.segmentStops('101', 21), null);
    ok('segments: width passed and fitting', LY.segmentStops('101', 22) !== null);
    eq('segments: stops do not depend on the width', LY.segmentStops('101', 300).mask, s.mask);
    // Every stop count equals bits length, for all lengths 1..24.
    var bad = [];
    for (var n = 1; n <= 24; n++) {
      var bits = '';
      for (var k = 0; k < n; k++) bits += (k * 7 + n) % 3 ? '1' : '0';
      var st = LY.segmentStops(bits);
      var cells = (st.mask.match(/#000/g) || []).length;
      var fills = (st.image.match(/var\(--h-fill\)/g) || []).length;
      if (cells !== n || fills !== bits.split('').filter(function (c) { return c === '1'; }).length) bad.push(n);
    }
    eq('segments: mask cells = bits length and fill stops = done bits, 1..24', bad.join(','), '');
  }

  function dotsSpec() {
    eq('dots: bits order', LY.dotsOf({ total: 4, done: 2, bits: '0101', cls: 'doing' }).list, 'odod');
    eq('dots: done first without bits', LY.dotsOf({ total: 3, done: 1, bits: '', cls: 'doing' }).list, 'doo');
    eq('dots: late open dots are l', LY.dotsOf({ total: 3, done: 1, bits: '100', cls: 'late' }).list, 'dll');
    var many = LY.dotsOf({ total: 20, done: 5, bits: '', cls: 'doing' });
    eq('dots: at most 12, then +n', many.list.length + '|' + many.more, '12|8');
    eq('dots: none for no items', LY.dotsOf({ total: 0, done: 0 }).list, '');
    eq('dots: bits of the wrong length are ignored', LY.dotsOf({ total: 2, done: 1, bits: '011' }).list, 'do');
    eq('styleOf: fill, segments, dots, unknown', ['fill', 'segments', 'dots', 'bars', undefined].map(function (x) { return LY.styleOf({ progressStyle: x }); }).join(','),
      'fill,segments,dots,fill,fill');
  }

  function colorSpec() {
    var c = chart(), st = { colorBy: 'status' };
    eq('colorFor status: each class', ['done', 'doing', 'late', 'todo', 'none', 'dropped'].map(function (k) { return LY.colorFor(c.tasks[0], { cls: k }, 0, st); }).join(','),
      'emerald,blue,rose,slate,slate,slate');
    // Device feedback round 1: an explicit task colour wins in every mode;
    // a group colour wins in group mode for tasks without their own.
    eq('colorFor status: a stored task colour wins', LY.colorFor(c.tasks[1], { cls: 'doing' }, 0, st), 'amber');
    var own = { id: 'o', note: 'n-own', color: 'pink' }, bare = { id: 'b', note: 'n-bare' }, gc = { id: 'g', color: 'teal' }, gn = { id: 'g2' };
    eq('colorFor: an own colour wins in status, group and task modes, grouped or not',
      ['status', 'group', 'task'].map(function (by) {
        return [LY.colorFor(own, { cls: 'late' }, 1, { colorBy: by }, gc), LY.colorFor(own, { cls: 'done' }, -1, { colorBy: by }, null)].join('/');
      }).join(','), 'pink/pink,pink/pink,pink/pink');
    eq('colorFor: slate is a valid own colour in status mode', LY.colorFor({ id: 's', color: 'slate' }, { cls: 'done' }, 0, st), 'slate');
    eq('colorFor: an unknown own colour follows the mode', LY.colorFor({ id: 'u', color: 'plaid' }, { cls: 'done' }, 0, st), 'emerald');
    eq('colorFor status: no own colour follows the class, a group colour is ignored', LY.colorFor(bare, { cls: 'late' }, 1, st, gc), 'rose');
    eq('colorFor group: no own colour takes the group colour', LY.colorFor(bare, { cls: 'late' }, 1, { colorBy: 'group' }, gc), 'teal');
    eq('colorFor group: no own or group colour is automatic by index', LY.colorFor(bare, { cls: 'late' }, 2, { colorBy: 'group' }, gn), M.AUTO_HUES[2]);
    eq('colorFor group: no own colour and ungrouped is slate', LY.colorFor(bare, null, -1, { colorBy: 'group' }, null), 'slate');
    eq('colorFor task: no own colour ignores the group colour (automatic from the note)', LY.colorFor(bare, null, 1, { colorBy: 'task' }, gc), LY.colorFor(bare, null, 0, { colorBy: 'task' }, null));
    ok('colorFor task: ... and is an automatic hue', M.AUTO_HUES.indexOf(LY.colorFor(bare, null, 1, { colorBy: 'task' }, gc)) >= 0);
    eq('colorFor status: default settings are status', LY.colorFor(c.tasks[0], { cls: 'late' }, 0, {}), 'rose');
    var g = { colorBy: 'group' };
    eq('colorFor group: the stored group colour', LY.colorFor(c.tasks[2], { cls: 'late' }, 1, g, c.groups[1]), 'teal');
    eq('colorFor group: automatic by index', LY.colorFor(c.tasks[0], { cls: 'late' }, 0, g, c.groups[0]), M.AUTO_HUES[0]);
    eq('colorFor group: index wraps around the 10 hues', LY.colorFor(null, null, 13, g, { id: 'x' }), M.AUTO_HUES[3]);
    eq('colorFor group: an unknown stored colour is automatic', LY.colorFor(null, null, 2, g, { id: 'x', color: 'plaid' }), M.AUTO_HUES[2]);
    var t = { colorBy: 'task' };
    eq('colorFor task: the stored task colour', LY.colorFor(c.tasks[1], { cls: 'late' }, 0, t), 'amber');
    var a1 = LY.colorFor(c.tasks[0], null, 0, t), a2 = LY.colorFor(c.tasks[0], { cls: 'done' }, 5, t);
    ok('colorFor task: automatic, stable, from the note', a1 === a2 && M.AUTO_HUES.indexOf(a1) >= 0);
    var hues = {};
    for (var i = 0; i < 200; i++) hues[LY.colorFor({ id: 'x', note: 'note-' + i }, null, 0, t)] = 1;
    ok('colorFor task: automatic hues spread and never slate', Object.keys(hues).length >= 8 && !hues.slate);
    eq('colorFor task: slate only when stored', LY.colorFor({ id: 'x', note: 'n', color: 'slate' }, null, 0, t), 'slate');
    ok('every colour is a palette token', ['status', 'group', 'task'].every(function (by) {
      return c.tasks.every(function (x, k) { return M.COLORS.indexOf(LY.colorFor(x, { cls: 'doing' }, k, { colorBy: by }, c.groups[k % 2])) >= 0; });
    }));
  }

  function legendSpec() {
    var c = chart();
    var lg = LY.legend(c, ['late', 'done', 'missing'], { colorBy: 'status', progressStyle: 'dots' });
    eq('legend status: the present classes, in a fixed order', lg.rows.map(function (r) { return r.key + ':' + r.hue; }).join(','), 'done:emerald,late:rose,missing:slate');
    eq('legend: the modes', lg.by + '|' + lg.style, 'status|dots');
    eq('legend: today, weekend, milestone', lg.extras.join(','), 'today,weekend,milestone');
    eq('legend: no weekend row when weekends are off', LY.legend(c, [], {}, { weekends: false }).extras.join(','), 'today,milestone');
    var lgg = LY.legend(c, ['late'], { colorBy: 'group' });
    // M8 review: ungrouped tasks (t5) are slate with a "No group" row; the non-colour cues get rows.
    eq('legend group: one row per group with its hue, No group, then the overdue cue', lgg.rows.map(function (r) { return r.kind + ':' + r.label + ':' + r.hue; }).join(','),
      'group:Discovery:' + M.AUTO_HUES[0] + ',group:Build:teal,group:No group:slate,cue:Overdue:slate');
    eq('legend task: only the cue rows present', LY.legend(c, ['late', 'dropped', 'doing'], { colorBy: 'task' }).rows.map(function (r) { return r.kind + ':' + r.key; }).join(','), 'cue:late,cue:dropped');
    var cg = M.coerce({ v: 1, groups: [{ id: 'g1', title: 'A' }], tasks: [{ id: 't1', note: 'n', start: '2026-10-01', group: 'g1' }] }).chart;
    eq('legend group: no "No group" row when every task has a group', LY.legend(cg, [], { colorBy: 'group' }).rows.length, 1);
    // Device feedback round 1: the legend says own colours are kept.
    eq('legend owned: status and group modes with an own task colour; not task mode; not without one',
      [LY.legend(c, [], { colorBy: 'status' }).owned, LY.legend(c, [], { colorBy: 'group' }).owned, LY.legend(c, [], { colorBy: 'task' }).owned, LY.legend(cg, [], {}).owned].join(','),
      'true,true,false,false');
    // Review round 1: a missing note is drawn slate, so its colour is not "kept".
    eq('legend owned: a coloured task whose note is missing does not count', LY.legend(c, [], { colorBy: 'status' }, { missing: { t2: 1 } }).owned, false);
    eq('legend owned: ... another coloured task still does', LY.legend(M.setTask(c, 't1', { color: 'pink' }).chart, [], {}, { missing: { t2: 1 } }).owned, true);
    (function shellChecks(SH) {
      if (!SH) { ok('shell source checks need GT_SHELL (node only)', true); return; }
      var shellCss = SH.slice(0, SH.indexOf('</style>'));
      ok('shell: no top safe-area inset anywhere (the WebView sits below the host app bar)', shellCss.indexOf('safe-area-inset-top') < 0);
      var tbRules = shellCss.match(/#topbar\s*\{[^}]*\}/g) || [];
      ok('shell: the top bar keeps the side insets and a compact top padding', tbRules.some(function (r) { return /safe-area-inset-left/.test(r) && /safe-area-inset-right/.test(r) && /padding:\s*2px/.test(r); }), tbRules.join('\n'));
      ok('shell: --top-h is at most 52 px', /--top-h:\s*(\d+)px/.test(shellCss) && +/--top-h:\s*(\d+)px/.exec(shellCss)[1] <= 52);
      ok('shell: the corner has the name column toggle', /class="g-ntog"[^>]*data-i18n-label="Collapse task names"/.test(SH));
    })(global.GT_SHELL);
    eq('colorFor group: an ungrouped task is slate, not the first group\'s hue', LY.colorFor(c.tasks[4], null, -1, { colorBy: 'group' }, null), 'slate');
    // K4: every automatic hue is reachable from note ids.
    var seen10 = {};
    for (var h = 0; h < 2000; h++) seen10[LY.colorFor({ id: 'x', note: 'n-' + h }, null, 0, { colorBy: 'task' })] = 1;
    eq('colorFor task: all 10 AUTO_HUES are reachable', Object.keys(seen10).sort().join(','), M.AUTO_HUES.slice().sort().join(','));
    // Dots as background layers of one element (M8 review).
    var ds = LY.dotsStyle('dol');
    eq('dotsStyle: one layer per dot', (ds.image.match(/radial-gradient/g) || []).length, 3);
    eq('dotsStyle: 9 px apart', ds.pos, '0px 0, 9px 0, 18px 0');
    eq('dotsStyle: the late dot has a --warn centre in a --dot-on ring', /var\(--warn\) 0 1\.5px, var\(--dot-on\)/.test(ds.image.split('), ')[2]), true);
    eq('dotsStyle: width for the +n text', ds.width, 27);
    eq('dotsStyle: none for an empty list', LY.dotsStyle('').image, 'none');
    var saved = I.language;
    I.setLanguage('zh-CN');
    var missing = Object.keys(LY.CLASS_LABEL).map(function (k) { return LY.CLASS_LABEL[k]; })
      .concat(['Fill', 'Segments', 'Dots', 'Status', 'Group', 'Task', 'Today', 'Weekend', 'Milestone', 'Legend'])
      .filter(function (k) { return I.text(k) === k; });
    var foot = I.fmt('Colour by {by} · {style}', { by: 'x', style: 'y' });
    I.setLanguage(saved);
    eq('legend: every label has a zh-CN entry', missing.join(','), '');
    eq('legend: the footer pattern in zh-CN', foot, '颜色依据：x · y');
  }

  function stateSpec() {
    var dens = LY.DENSITY.comfortable, row = { y: 88, h: 44 };
    var cam = { sx: 0, sy: 0, ppd: 16, epoch: P('2026-09-01') };
    var gg = LY.ghostGeom(row, cam, dens, P('2026-10-20'));
    eq('ghost: at today, 5 days wide', gg.x + '|' + gg.w, ((P('2026-10-20') - cam.epoch) * 16) + '|80');
    eq('ghost: centred in its row', gg.y + '|' + gg.h, (88 + (44 - 26) / 2) + '|26');
    var b = LY.buildRows(chart(), [], 'comfortable');
    var un = b.rows.filter(function (r) { return r.kind === 'task' && typeof r.task.start !== 'number'; });
    eq('ghost: the unscheduled task sits in the synthetic Unscheduled group (D15)', un.length + '|' + b.rows[b.index.t5 - 1].id, '1|' + LY.UNSCHED);
    // Lite (§11.6): from 500 tasks, or 5 slow pan frames in a row.
    eq('lite: 499 tasks is not lite', R.isLite(499, 0), false);
    eq('lite: 500 tasks is lite', R.isLite(500, 0), true);
    eq('lite: 600 tasks is lite', R.isLite(600, 0), true);
    eq('lite: 4 slow frames are not', R.isLite(10, 4), false);
    eq('lite: 5 slow frames are', R.isLite(10, 5), true);
    eq('lite: constants', [R.LITE_TASKS, R.SLOW_FRAME_MS, R.SLOW_FRAMES].join(','), '500,24,5');
    // The name column (§14.2).
    eq('nameW: at least 56', R.clampNameW(10, 390), 56);
    eq('nameW: under 88 snaps to the mini column', R.clampNameW(87, 390), 56);
    eq('nameW: 88 stays', R.clampNameW(88, 390), 88);
    eq('nameW: at most half the width', R.clampNameW(400, 390), 195);
    var mp = R.metrics(390, 790, 'comfortable', { p: 200, l: 100 });
    eq('metrics: the portrait width override', mp.nameW + '|' + mp.mini, '195|false');
    var ml = R.metrics(844, 390, 'comfortable', { p: 200, l: 60 });
    eq('metrics: the landscape override, mini', ml.nameW + '|' + ml.mini, '56|true');
    eq('metrics: no override keeps the default', R.metrics(390, 790, 'comfortable', { l: 100 }).nameW, 117);
    // Device feedback round 1: portrait phones default to clamp(104px, 30vw, 150px).
    eq('metrics portrait default: 30vw between 104 and 150', [320, 360, 390, 430, 500, 600, 767].map(function (w) { return R.metrics(w, 900).nameW; }).join(','),
      '104,108,117,129,150,150,150');
    eq('metrics: landscape and tablet defaults unchanged', R.metrics(844, 390).nameW + '|' + R.metrics(1024, 700).nameW, '203|240');
    // Review round 1: D/W/M need 117 px beside the toggle; narrower (not mini) columns are narrow.
    eq('metrics narrow: 117 fits the presets, 116 and 104 do not, the mini column is not narrow',
      [R.metrics(390, 790).narrow, R.metrics(390, 790, 'comfortable', { p: 116 }).narrow, R.metrics(360, 790).narrow, R.metrics(390, 790, 'comfortable', { p: 56 }).narrow, R.metrics(844, 390).narrow].join(','),
      'false,true,true,false,false');
    eq('metrics narrow: SEG_FIT and GRP_TALL', R.SEG_FIT + '|' + R.GRP_TALL, '117|32');
    eq('metrics: the remembered width (pr) is not the width', R.metrics(390, 790, 'comfortable', { p: 56, pr: 160 }).nameW + '|' + R.metrics(390, 790, 'comfortable', { pr: 160 }).nameW, '56|117');
    // Density (Q8): 44 px rows in landscape by default, compact 36 everywhere.
    eq('metrics: landscape rows are 44 by default (Q8)', R.metrics(844, 390).rowH, 44);
    eq('metrics: landscape compact is 36', R.metrics(844, 390, 'compact').rowH, 36);
    eq('metrics: tablet compact is 36', R.metrics(1024, 700, 'compact').rowH, 36);
  }

  function weekSpec() {
    eq('isoWeek: 2026-01-01 (Thu) is week 1', D.isoWeek(P('2026-01-01')), 1);
    eq('isoWeek: 2026-12-31 is week 53', D.isoWeek(P('2026-12-31')), 53);
    eq('isoWeek: 2027-01-01 (Fri) is week 53 of 2026', D.isoWeek(P('2027-01-01')), 53);
    eq('isoWeek: 2021-01-03 (Sun) is week 53 of 2020', D.isoWeek(P('2021-01-03')), 53);
    eq('isoWeek: 2021-01-04 (Mon) is week 1', D.isoWeek(P('2021-01-04')), 1);
    eq('isoWeek: 2026-03-02 is week 10', D.isoWeek(P('2026-03-02')), 10);
    eq('weekNumber: a Sunday week counts its Monday', D.weekNumber(P('2026-03-01'), 0), 10);
    eq('weekNumber: a Monday week', D.weekNumber(P('2026-03-02'), 1), 10);
    var saved = I.language;
    I.setLanguage('zh-CN');
    var zh = I.date.week(10);
    I.setLanguage('en-US');
    var en = I.date.week(10);
    I.setLanguage(saved);
    eq('week labels W10 / 第10周', en + '|' + zh, 'W10|第10周');
  }

  // §13.6: settings changes are undoable through {op:'settings'} patches.
  function settingsSpec() {
    var c = chart();
    var cases = [
      { progressSource: 'checklist' }, { progressSection: '## Steps' }, { childTasks: false }, { progressStyle: 'segments' },
      { progressStyle: 'dots' }, { colorBy: 'group' }, { colorBy: 'task' }, { scale: 'month' }, { weekStart: 1 },
      { workdays: [0, 1, 2, 3, 4] }, { holidays: ['2026-12-25', '2027-01-01'] }, { mirror: false }, { embed: true }, { syncDates: false },
      { progressStyle: 'segments', colorBy: 'group', weekStart: 0 }
    ];
    var bad = [];
    cases.forEach(function (f) {
      var r = M.setSettings(c, f);
      var ok1 = r.inverse.length === 1 && r.inverse[0].op === 'settings';
      Object.keys(f).forEach(function (k) { if (!M.same(r.chart.settings[k], f[k])) ok1 = false; });
      var back = M.applyPatch(r.chart, r.inverse);
      var ok2 = JSON.stringify(M.toData(back.chart)) === JSON.stringify(M.toData(c));
      var redo = M.applyPatch(back.chart, back.inverse);
      var ok3 = JSON.stringify(M.toData(redo.chart)) === JSON.stringify(M.toData(r.chart));
      if (!(ok1 && ok2 && ok3)) bad.push(JSON.stringify(f) + ' ' + [ok1, ok2, ok3].join('/'));
    });
    eq('settings: every M8 key sets, its inverse restores, and redo reapplies', bad.join('\n'), '');
    eq('settings: setting the same value is a no-op', M.setSettings(c, { colorBy: 'status' }).inverse.length, 0);
    // A shadowed setting (§5.3): set drops the shadow, undo restores it.
    var sh = M.coerce({ v: 1, settings: { progressStyle: 7 } }).chart;
    var r2 = M.setSettings(sh, { progressStyle: 'dots' });
    var b2 = M.applyPatch(r2.chart, r2.inverse);
    eq('settings: undo restores a shadow byte-for-byte', JSON.stringify(M.settingsData(b2.chart.settings)), '{"progressStyle":7}');
    eq('settings: ... and the set wrote the new value', JSON.stringify(M.settingsData(r2.chart.settings)), '{"progressStyle":"dots"}');
    // A settings change after a merge brought other settings: undo touches only its own key.
    var r3 = M.setSettings(c, { colorBy: 'group' });
    var merged = M.setSettings(r3.chart, { mirror: false }).chart;
    var u3 = M.applyPatch(merged, r3.inverse).chart;
    eq('settings: undo after another change keeps it', u3.settings.colorBy + '|' + u3.settings.mirror, 'status|false');
  }

  SPEC.suites.push({ name: 'the M8 segments spec', fn: segmentSpec });
  SPEC.suites.push({ name: 'the M8 dots spec', fn: dotsSpec });
  SPEC.suites.push({ name: 'the M8 colour spec', fn: colorSpec });
  SPEC.suites.push({ name: 'the M8 legend spec', fn: legendSpec });
  SPEC.suites.push({ name: 'the M8 states spec', fn: stateSpec });
  SPEC.suites.push({ name: 'the M8 week number spec', fn: weekSpec });
  SPEC.suites.push({ name: 'the M8 settings spec', fn: settingsSpec });

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
