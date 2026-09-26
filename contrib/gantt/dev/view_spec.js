/*
 * Gantt view-stack assertions (M4): scale.js, layout.js, theme.js and the
 * pure helpers of render.js, plus the shell's CSS tables against theme.js
 * and the i18n coverage of the M4 strings. Runs under node (dev/run.js) and
 * in the browser (dev/auto_smoke.html); the shell and source checks need
 * node (GT_SHELL, GT_SOURCES).
 */
(function (global) {
  'use strict';
  var GT = global.GT, SPEC = GT.spec;
  var A = SPEC.api, ok = A.ok, eq = A.eq;
  var SC = GT.scale, LY = GT.layout, TH = GT.theme, R = GT.render, M = GT.model, D = GT.dates, I = GT.i18n;
  var P = D.parse;

  // A seeded PRNG so failures reproduce.
  function rng(seed) {
    var s = seed >>> 0 || 1;
    return function () { s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0; return s / 4294967296; };
  }
  function example() {
    return M.coerce({
      v: 1,
      groups: [{ id: 'g1', title: 'Discovery' }, { id: 'g2', title: 'Build', color: 'teal' }],
      tasks: [
        { id: 't1', note: 'n1', title: 'Customer interviews', start: '2026-10-01', end: '2026-10-09', group: 'g1' },
        { id: 't2', note: 'n2', title: 'Competitive teardown', start: '2026-10-05', end: '2026-10-14', group: 'g1', color: 'amber' },
        { id: 't3', note: 'n3', title: 'Sync engine', start: '2026-10-12', end: '2026-11-06', group: 'g2' },
        { id: 't4', note: 'n4', title: 'Beta cut', start: '2026-11-09', group: 'g2', milestone: true }
      ]
    }).chart;
  }

  function scaleSpec() {
    // tierFor boundaries (§11.3).
    eq('tier at 120 is day', SC.tierFor(120).name, 'day');
    eq('tier at 28 is day', SC.tierFor(28).name, 'day');
    eq('tier at 27.99 is week', SC.tierFor(27.99).name, 'week');
    eq('tier at 9 is week', SC.tierFor(9).name, 'week');
    eq('tier at 8.99 is month', SC.tierFor(8.99).name, 'month');
    eq('tier at 3 is month', SC.tierFor(3).name, 'month');
    eq('tier at 2.99 is quarter', SC.tierFor(2.99).name, 'quarter');
    eq('tier below the minimum clamps to quarter', SC.tierFor(0.1).name, 'quarter');
    eq('tier above the maximum clamps to day', SC.tierFor(500).name, 'day');
    eq('week tier has faint day lines from ppd 14', SC.tierFor(14).minor + '|' + SC.tierFor(13.9).minor, 'day|null');
    eq('day and week tiers snap 1 day, month and quarter 7', [SC.tierFor(40).snap, SC.tierFor(16).snap, SC.tierFor(5).snap, SC.tierFor(2).snap].join(','), '1,1,7,7');
    eq('top labels: month for day/week, year for month/quarter', [SC.tierFor(40).top, SC.tierFor(16).top, SC.tierFor(5).top, SC.tierFor(2).top].join(','), 'month,month,year,year');
    var narrow = [];
    for (var p = SC.MIN_PPD; p <= SC.MAX_PPD; p *= 1.07) {
      var t = SC.tierFor(p), days = { day: 1, week: 7, month: 28, quarter: 90, year: 365 }[t.unit];
      if (days * p < (SC.MIN_LABEL_PX[t.unit] || 0)) narrow.push(p.toFixed(2) + ':' + t.unit);
    }
    eq('the bottom unit is never narrower than MIN_LABEL_PX', narrow.join(' '), '');
    eq('clampPpd bounds', [SC.clampPpd(0), SC.clampPpd(1000), SC.clampPpd(NaN)].join(','), [SC.MIN_PPD, SC.MAX_PPD, SC.PRESETS.week].join(','));
    eq('presets D/W/M are 44, 16, 5', [SC.PRESETS.day, SC.PRESETS.week, SC.PRESETS.month].join(','), '44,16,5');

    // ticks over one year.
    var buf = new Float64Array(1000), y0 = P('2026-01-01'), y1 = P('2027-01-01');
    eq('ticks: 365 days in 2026', SC.ticks('day', y0, y1, 0, buf), 365);
    eq('ticks: 53 Sunday weeks overlap 2026', SC.ticks('week', y0, y1, 0, buf), 53);
    eq('ticks: the first Sunday week starts 2025-12-28', D.format(buf[0]), '2025-12-28');
    eq('ticks: 53 Monday weeks overlap 2026', SC.ticks('week', y0, y1, 1, buf), 53);
    eq('ticks: the first Monday week starts 2025-12-29', D.format(buf[0]), '2025-12-29');
    eq('ticks: 12 months', SC.ticks('month', y0, y1, 0, buf), 12);
    eq('ticks: months start on the 1st', D.format(buf[1]) + ' ' + D.format(buf[11]), '2026-02-01 2026-12-01');
    eq('ticks: 4 quarters', SC.ticks('quarter', y0, y1, 0, buf), 4);
    eq('ticks: quarter starts', [0, 1, 2, 3].map(function (i) { return D.format(buf[i]); }).join(','), '2026-01-01,2026-04-01,2026-07-01,2026-10-01');
    eq('ticks: 1 year', SC.ticks('year', y0, y1, 0, buf), 1);
    eq('ticks: a range starting mid-month starts with that month', (SC.ticks('month', P('2026-03-15'), P('2026-05-02'), 0, buf), D.format(buf[0])), '2026-03-01');
    eq('ticks: never writes past the buffer', SC.ticks('day', y0, y1, 0, new Float64Array(10)), 10);
    eq('ticks: leap year February', (SC.ticks('month', P('2028-02-01'), P('2028-03-02'), 0, buf), D.format(buf[1])), '2028-03-01');

    // snapDelta.
    var asym = [], negZero = false;
    for (var dx = -500; dx <= 500; dx += 3.7) {
      [1, 7].forEach(function (s) {
        [5, 16, 44].forEach(function (ppd) {
          var a = SC.snapDelta(dx, ppd, s), b = SC.snapDelta(-dx, ppd, s);
          if (a !== -b && !(a === 0 && b === 0)) asym.push(dx + '/' + ppd + '/' + s);
          if (Object.is(a, -0)) negZero = true;
          if (a % s !== 0) asym.push('not a multiple ' + a);
        });
      });
    }
    eq('snapDelta is symmetric and whole snap units', asym.join(' '), '');
    ok('snapDelta never returns -0', !negZero);
    eq('snapDelta rounds to the nearest day', [SC.snapDelta(24, 16, 1), SC.snapDelta(23, 16, 1), SC.snapDelta(-24, 16, 1)].join(','), '2,1,-2');
    eq('snapDelta at coarse zoom moves whole weeks', SC.snapDelta(5 * 20, 5, 7), 21);

    // zoomAt keeps the day under the anchor.
    var r = rng(7), worst = 0;
    for (var i = 0; i < 400; i++) {
      var cam = { sx: (r() - 0.3) * 20000, sy: r() * 500, ppd: SC.MIN_PPD + r() * 100, epoch: 20000 + Math.floor(r() * 100) };
      var fx = r() * 400, f = Math.exp((r() - 0.5) * 3);
      var before = SC.dayAt(cam, fx), next = SC.zoomAt(cam, f, fx);
      if (next.ppd > SC.MIN_PPD && next.ppd < SC.MAX_PPD) worst = Math.max(worst, Math.abs(SC.dayAt(next, fx) - before));
    }
    ok('zoomAt keeps dayAt(fx) within 1e-9 (worst ' + worst + ')', worst < 1e-9);
    var clampZ = SC.zoomAt({ sx: 0, sy: 0, ppd: 100, epoch: 0 }, 10, 0);
    eq('zoomAt clamps ppd', clampZ.ppd, SC.MAX_PPD);
    var cam0 = { sx: 1234, sy: 5, ppd: 16, epoch: 20000 };
    var rb = SC.rebase(cam0, 19950);
    ok('rebase keeps every day where it was', Math.abs(SC.xOf(rb, 20500) - SC.xOf(cam0, 20500)) < 1e-9);
    eq('xOf and dayAt invert', SC.dayAt(cam0, SC.xOf(cam0, 20123.25)), 20123.25);

    // clampCamera.
    var bnd = { minX: 1000, maxX: 3000, totalH: 2000 }, vw = { w: 300, h: 500 };
    eq('clampCamera: one viewport before the content', SC.clampCamera({ sx: -5000, sy: 0, ppd: 16, epoch: 0 }, bnd, vw).sx, 700);
    eq('clampCamera: up to the content end', SC.clampCamera({ sx: 9000, sy: 0, ppd: 16, epoch: 0 }, bnd, vw).sx, 3000);
    eq('clampCamera: vertical max keeps room for the FAB', SC.clampCamera({ sx: 1500, sy: 9999, ppd: 16, epoch: 0 }, bnd, vw).sy, 2000 - 500 + SC.FAB_ROOM);
    eq('clampCamera: never above the top', SC.clampCamera({ sx: 1500, sy: -40, ppd: 16, epoch: 0 }, bnd, vw).sy, 0);
    eq('clampCamera: a short chart cannot scroll', SC.clampCamera({ sx: 1500, sy: 50, ppd: 16, epoch: 0 }, { minX: 0, maxX: 10, totalH: 100 }, vw).sy, 0);

    // fitRange.
    var ep = 20000, fr = SC.fitRange(20100, 20199, 400, ep);
    var cf = { sx: fr.sx, sy: 0, ppd: fr.ppd, epoch: ep };
    ok('fitRange: the first day is in view', SC.xOf(cf, 20100) >= 11.9);
    ok('fitRange: the last day ends in view', SC.xOf(cf, 20200) <= 400 - 11.9);
    ok('fitRange: centred', Math.abs(SC.xOf(cf, 20100) - (400 - SC.xOf(cf, 20200))) < 1e-6);
    eq('fitRange: a huge range clamps to the minimum ppd', SC.fitRange(0, 100000, 400, 0).ppd, SC.MIN_PPD);

    // fling at 60 vs 120 Hz.
    function travel(hz) {
      var v = 3, x = 0, dt = 1000 / hz, n = 0;
      while (n++ < 5000) { var s = SC.fling(v, dt); x += s.dx; v = s.v; if (s.done) break; }
      return x;
    }
    var t60 = travel(60), t120 = travel(120);
    ok('fling: 60 Hz and 120 Hz travel within 2% (' + t60.toFixed(1) + ' vs ' + t120.toFixed(1) + ')', Math.abs(t60 - t120) / t60 < 0.02);
    ok('fling: decays by FLING_DECAY per 60 Hz frame', Math.abs(SC.fling(1, 1000 / 60).v - SC.FLING_DECAY) < 1e-12);
  }

  function layoutSpec() {
    var c = example();
    var b = LY.buildRows(c, [], 'comfortable');
    eq('rows: headers then tasks in D15 order', b.rows.map(function (r) { return r.kind[0] + ':' + r.id; }).join(' '), 'g:g1 t:t1 t:t2 g:g2 t:t3 t:t4');
    eq('rows: prefix-sum y', b.rows.map(function (r) { return r.y; }).join(','), '0,32,76,120,152,196');
    eq('rows: total height', b.totalH, 240);
    eq('rows: index maps tasks to rows', b.index.t3, 4);
    eq('rows: group count', b.rows[0].n, 2);
    var bc = LY.buildRows(c, new Set(['g1']), 'compact');
    eq('rows: a collapsed group keeps only its header', bc.rows.map(function (r) { return r.id; }).join(' '), 'g1 g2 t3 t4');
    ok('rows: a collapsed task has no index', !Object.prototype.hasOwnProperty.call(bc.index, 't1'));
    eq('rows: compact heights', bc.rows.map(function (r) { return r.h; }).join(','), '28,28,36,36');
    eq('rows: tablet row height override', LY.buildRows(c, [], 'comfortable', { rowH: 40 }).rows[1].h, 40);

    var mixed = M.coerce({
      v: 1, groups: [{ id: 'g1', title: 'A' }, { id: 'g2', title: 'Empty' }],
      tasks: [
        { id: 'u1', note: 'a', title: 'Loose', start: '2026-10-01' },
        { id: 'x1', note: 'b', title: 'In A', start: '2026-10-02', group: 'g1' },
        { id: 'n1', note: 'c', title: 'No date' },
        { id: 'n2', note: 'd', title: 'No date in A', group: 'g1' },
        { id: 'u2', note: 'e', title: 'Loose 2', start: '2026-10-03', end: '2026-10-04' }
      ]
    }).chart;
    var bm = LY.buildRows(mixed, {}, 'comfortable');
    eq('rows: ungrouped first, empty groups keep a header, Unscheduled last', bm.rows.map(function (r) { return r.id; }).join(' '), 'u1 u2 g1 x1 g2 ' + LY.UNSCHED + ' n1 n2');
    ok('rows: the Unscheduled header is flagged', bm.rows[5].unscheduled === true && bm.rows[5].n === 2);
    eq('rows: collapsing Unscheduled hides its tasks', LY.buildRows(mixed, [LY.UNSCHED], 'comfortable').rows.length, 6);

    // visibleRange vs brute force on 1000 rows.
    var rr = rng(11), rows = [], y = 0;
    for (var i = 0; i < 1000; i++) { var h = rr() < 0.2 ? 32 : 44; rows.push({ y: y, h: h }); y += h; }
    var bad = 0;
    for (var k = 0; k < 300; k++) {
      var y0 = rr() * (y + 200) - 100, y1 = y0 + rr() * 900;
      var first = -1, last = -2;
      for (var j = 0; j < rows.length; j++) {
        if (rows[j].y + rows[j].h > y0 && rows[j].y < y1) { if (first < 0) first = j; last = j; }
      }
      var got = LY.visibleRange(rows, y0, y1);
      if (first < 0) { if (got.first <= got.last) bad++; } else if (got.first !== first || got.last !== last) bad++;
    }
    eq('visibleRange matches brute force on 1000 rows', bad, 0);
    eq('rowAt finds the row', LY.rowAt(rows, rows[500].y + 1), 500);
    eq('rowAt below the last row is -1', LY.rowAt(rows, y + 5), -1);

    // Geometry: inclusive end (D16), milestones.
    var cam = { sx: 0, sy: 0, ppd: 16, epoch: P('2026-09-01') }, dens = LY.DENSITY.comfortable;
    var row = { y: 100, h: 44 };
    var one = LY.barGeom({ start: P('2026-10-01'), end: null }, row, cam, dens);
    eq('geom: a one-day task is one day wide', one.w, 16);
    eq('geom: x of its day', one.x, 30 * 16);
    var ranged = LY.barGeom({ start: P('2026-10-01'), end: P('2026-10-09') }, row, cam, dens);
    eq('geom: an inclusive range is 9 days wide', ranged.w, 9 * 16);
    eq('geom: the bar is centred in its row', ranged.y, 100 + (44 - 26) / 2);
    var ms = LY.barGeom({ start: P('2026-10-01'), milestone: true }, row, cam, dens);
    ok('geom: a milestone is a 16 px box centred on its day', ms.ms && ms.w === 16 && ms.x + 8 === 30 * 16 + 8);
    eq('geom: unscheduled has none', LY.barGeom({ start: null }, row, cam, dens), null);
    var hb = LY.hitBox(one, row);
    eq('hit box: at least 44 wide and the row high', hb.w + 'x' + hb.h, '44x44');
    var hs = LY.handleRects({ x: 100, y: 10, w: 60, h: 26, ms: false });
    ok('handles: outside the ends below 88 px', hs.outside && hs.s.x === 56 && hs.e.x === 160);
    var hw = LY.handleRects({ x: 100, y: 10, w: 200, h: 26, ms: false });
    ok('handles: inside the ends from 132 px', !hw.outside && hw.s.x === 100 && hw.e.x === 256);
    // M6 review round 1: inside handles leave at least 44 px of bar to press for MOVE.
    var h120 = LY.handleRects({ x: 100, y: 10, w: 120, h: 26, ms: false });
    ok('handles: outside below 132 px (120 px bar)', h120.outside && h120.s.x === 56 && h120.e.x === 220);
    var h132 = LY.handleRects({ x: 100, y: 10, w: 132, h: 26, ms: false });
    ok('handles: inside at 132 px leaves 44 px between them', !h132.outside && h132.e.x - (h132.s.x + 44) === 44);
    eq('handles: 44 x 44 centred on the bar', hw.s.w + 'x' + hw.s.h + '@' + hw.s.y, '44x44@1');
    eq('handles: none for a milestone', LY.handleRects(ms), null);

    // Colours.
    var set = { colorBy: 'status' };
    eq('colour: done is emerald', LY.colorFor(c.tasks[0], { cls: 'done' }, 0, set), 'emerald');
    eq('colour: late is rose', LY.colorFor(c.tasks[0], { cls: 'late' }, 0, set), 'rose');
    eq('colour: doing is blue', LY.colorFor(c.tasks[0], { cls: 'doing' }, 0, set), 'blue');
    eq('colour: todo, none and dropped are slate', ['todo', 'none', 'dropped'].map(function (k) { return LY.colorFor(c.tasks[0], { cls: k }, 0, set); }).join(','), 'slate,slate,slate');
    eq('colour: a task colour overrides status (device feedback round 1)', LY.colorFor(c.tasks[1], { cls: 'doing' }, 0, set), 'amber');
    eq('colour: group uses the group colour', LY.colorFor(c.tasks[2], null, 1, { colorBy: 'group' }, c.groups[1]), 'teal');
    eq('colour: group without a colour is automatic', LY.colorFor(c.tasks[0], null, 0, { colorBy: 'group' }, c.groups[0]), M.AUTO_HUES[0]);
    eq('colour: task uses the task colour', LY.colorFor(c.tasks[1], null, 0, { colorBy: 'task' }), 'amber');
    var autos = {};
    for (var n = 0; n < 300; n++) {
      autos[LY.colorFor({ id: 't' + n, note: 'note-' + n }, null, n, { colorBy: 'task' })] = 1;
      autos[LY.colorFor({ id: 't' + n }, null, n, { colorBy: 'group' }, { id: 'g', title: 'x' })] = 1;
    }
    ok('colour: automatic hues never pick slate', !autos.slate && Object.keys(autos).length === 10, Object.keys(autos).join(','));
    eq('colour: an unknown stored colour falls back', LY.colorFor({ id: 'x', note: 'n', color: 'plaid' }, null, 0, { colorBy: 'task' }) !== 'plaid', true);

    var today = P('2026-12-20');
    var bb = LY.contentBounds(c, b, cam, today);
    eq('bounds: from the first date', bb.minX, (P('2026-10-01') - cam.epoch) * 16);
    eq('bounds: widened to include today', bb.maxX, (today + 1 - cam.epoch) * 16);
    eq('epoch: 60 days before the earliest date', LY.epochFor(c, today), P('2026-10-01') - 60);
    eq('epoch: or before today', LY.epochFor(c, P('2026-01-01')), P('2026-01-01') - 60);
  }

  function themeSpec() {
    eq('contrast black on white is 21', Math.round(TH.contrast('#000000', '#ffffff') * 100) / 100, 21);
    eq('contrast is symmetric', TH.contrast('#4f46e5', '#fff'), TH.contrast('#ffffff', '#4f46e5'));
    ['light', 'dark'].forEach(function (th) {
      var tk = TH.TOKENS[th];
      Object.keys(TH.PALETTE).forEach(function (name) {
        var p = TH.PALETTE[name][th];
        var a = TH.contrast(p.fill, p.ink), b = TH.contrast(p.tint, tk['--text']);
        ok('contrast ' + th + ' ' + name + ': fill/ink >= 4.5 (' + a.toFixed(2) + ')', a >= 4.5);
        ok('contrast ' + th + ' ' + name + ': tint/--text >= 7 (' + b.toFixed(2) + ')', b >= 7);
      });
      var t = TH.contrast(tk['--today'], tk['--g-bg']);
      ok('contrast ' + th + ': --today on --g-bg >= 3 (' + t.toFixed(2) + ')', t >= 3);
    });
    eq('palette has the 11 named hues of D2', Object.keys(TH.PALETTE).join(','), M.COLORS.join(','));
    eq('dark tint is the hue at 22% over --g-bg', TH.PALETTE.teal.dark.tint, TH.blend('#2dd4bf', 0.22, '#12151a'));
    eq('resolve: the override wins', TH.resolve('dark', 'light', false), 'dark');
    eq('resolve: then the host theme', TH.resolve('auto', 'dark', false), 'dark');
    eq('resolve: then the media query', TH.resolve('auto', null, true) + TH.resolve(null, null, false), 'darklight');
    eq('parse rgba', JSON.stringify(TH.parse('rgba(16,24,40,.025)')), '{"r":16,"g":24,"b":40,"a":0.025}');

    // The shell spells the same tables (node only).
    var shell = global.GT_SHELL;
    if (!shell) { ok('shell checks need GT_SHELL (node only)', true); return; }
    function block(sel) {
      var i = shell.indexOf(sel + ' {');
      if (i < 0) return null;
      var body = shell.slice(i + sel.length + 2, shell.indexOf('}', i));
      var out = {};
      body.replace(/(--[a-z0-9-]+):\s*([^;]+);/g, function (m, k, v) { out[k] = v.trim(); return m; });
      return out;
    }
    var light = block(':root'), dark = block(':root[data-theme=dark]');
    ['light', 'dark'].forEach(function (th) {
      var css = th === 'light' ? light : dark, diffs = [];
      Object.keys(TH.TOKENS[th]).forEach(function (k) {
        if (!css || css[k] !== TH.TOKENS[th][k]) diffs.push(k + ' css=' + (css && css[k]) + ' js=' + TH.TOKENS[th][k]);
      });
      eq('gantt.html ' + th + ' tokens equal theme.TOKENS', diffs.join('; '), '');
      var pd = [];
      Object.keys(TH.PALETTE).forEach(function (name) {
        var sel = (th === 'dark' ? ':root[data-theme=dark] ' : '') + '.c-' + name;
        var got = block(sel), p = TH.PALETTE[name][th];
        if (!got || got['--h-fill'] !== p.fill || got['--h-tint'] !== p.tint || got['--h-stroke'] !== p.stroke || got['--h-ink'] !== p.ink) {
          pd.push(sel + ' ' + JSON.stringify(got));
        }
      });
      eq('gantt.html ' + th + ' palette classes equal theme.PALETTE', pd.join('\n'), '');
    });
    ok('gantt.html sets the theme before first paint', /<head>[\s\S]*prefers-color-scheme[\s\S]*setAttribute\('data-theme'[\s\S]*<style>/.test(shell));
    ok('gantt.html hides the shell for at most 300 ms', /class="boot"/.test(shell) && /html\.boot body \{ visibility: hidden; \}/.test(shell) && /remove\('boot'\); \}, 300\)/.test(shell));
    ok('gantt.html disables page zoom', /user-scalable=no/.test(shell) && /viewport-fit=cover/.test(shell));
    var order = [];
    shell.replace(/<script src="src\/([a-z0-9]+)\.js"><\/script>/g, function (m, n) { order.push(n); return m; });
    eq('gantt.html loads the modules in the D18 order', order.join(','), 'i18n,dates,model,undo,block,md,host,store,scale,layout,theme,render,gestures,sheet,exporter,app');
    ok('gantt.html boots the app last', /<script src="src\/app\.js"><\/script>\n<script>GT\.app\.boot\(\);<\/script>/.test(shell));
    ok('gantt.html has the §12.8 structure', ['id="topbar"', 'id="gantt" class="g-root"', 'class="g-corner"', 'class="g-hdr-cv"', 'class="g-names"',
      'class="g-names-inner"', 'class="g-divider"', 'class="g-body"', 'class="g-grid-cv"', 'class="g-bars"', 'id="empty"', 'id="banner"', 'id="home"'].every(function (x) { return shell.indexOf(x) >= 0; }));
    ok('bars never use paint containment (outside labels, §12.8)', /\.g-bar \{[^}]*contain: layout style;/.test(shell) && !/contain:[^;]*paint/.test(shell));
    ok('will-change only on the two moving layers', (shell.match(/will-change/g) || []).length === 2);
  }

  // Review round 1: no allocation on the pan path, a true LRU.
  function allocSpec() {
    ok('tierFor returns the same object for the same ppd', SC.tierFor(16) === SC.tierFor(16));
    ok('tierFor still answers a new ppd', SC.tierFor(40).name === 'day' && SC.tierFor(16).name === 'week');
    var rows = [{ y: 0, h: 44 }, { y: 44, h: 44 }, { y: 88, h: 44 }], out = { first: 9, last: 9 };
    var r = LY.visibleRange(rows, 50, 60, out);
    ok('visibleRange writes into `out`', r === out && out.first === 1 && out.last === 1);
    var cam = { sx: -99999, sy: 0, ppd: 16, epoch: 0 };
    var c = SC.clampCamera(cam, { minX: 0, maxX: 100, totalH: 10 }, { w: 50, h: 50 }, cam);
    ok('clampCamera can clamp a camera in place', c === cam && cam.sx === -50);
    var bo = {};
    ok('contentBounds writes into `out`', LY.contentBounds(example(), { totalH: 7 }, { ppd: 1, epoch: 0 }, 0, bo) === bo && bo.totalH === 7);
    var m = new Map();
    R.lruPut(m, 1, 'a', 2);
    R.lruPut(m, 2, 'b', 2);
    eq('lru: a hit returns the value', R.lruGet(m, 1), 'a');
    R.lruPut(m, 3, 'c', 2);
    ok('lru: the least recently used key goes, not the oldest inserted', m.has(1) && !m.has(2) && m.has(3));
    eq('lru: a miss is undefined', R.lruGet(m, 2), undefined);
  }

  function renderSpec() {
    eq('capDpr: a phone canvas keeps dpr 3', R.capDpr(256, 700, 3), 3);
    eq('capDpr: never above 3', R.capDpr(100, 100, 4), 3);
    var big = [[3000, 3000, 3], [4000, 1000, 3], [5000, 20, 2], [1300, 1000, 3], [390, 844, 3], [844, 390, 3], [1, 1, 3]];
    var over = big.filter(function (x) {
      var d = R.capDpr(x[0], x[1], x[2]), w = Math.floor(x[0] * d), h = Math.floor(x[1] * d);
      return w * h > R.CANVAS_MAX_PX || w > R.CANVAS_MAX_SIDE || h > R.CANVAS_MAX_SIDE;
    });
    eq('capDpr: backing stores stay within 8 Mpx and 4096 a side', over.map(String).join(' | '), '');
    var mp = R.metrics(390, 790);
    eq('metrics portrait: name column clamp(104, 30vw, 150), tiers 20+24, row 44', [mp.landscape, mp.nameW, mp.hdrH, mp.rowH].join(','), 'false,117,44,44');
    var ml = R.metrics(844, 346);
    eq('metrics landscape phone: clamp(150, 24vw, 240), tiers 18+22', [ml.landscape, ml.nameW, ml.hdrH, ml.tiers.join('+')].join(','), 'true,203,40,18+22');
    var mt = R.metrics(1024, 700);
    eq('metrics tablet: 240 px names, 40 px rows', [mt.tablet, mt.nameW, mt.rowH].join(','), 'true,240,40');
    eq('metrics: compact density', R.metrics(390, 790, 'compact').rowH, 36);
  }

  // Every M4 string has a ZH entry (node only; M9 widens this to all of src/).
  function i18nM4Spec() {
    var src = global.GT_SOURCES, shell = global.GT_SHELL;
    if (!src || !shell) { ok('i18n coverage needs GT_SOURCES and GT_SHELL (node only)', true); return; }
    var keys = [];
    function unq(s) { return JSON.parse('"' + s.replace(/\\'/g, '\'').replace(/"/g, '\\"') + '"'); }
    ['app.js', 'render.js', 'sheet.js'].forEach(function (f) {
      var s = src[f] || '';
      s.replace(/\b(?:T|I\.text|I\(\)\.text|text)\('((?:[^'\\]|\\.)*)'\)/g, function (m, k) { keys.push([f, unq(k)]); return m; });
      s.replace(/\bfmt\('((?:[^'\\]|\\.)*)'/g, function (m, k) { keys.push([f + ' fmt', unq(k)]); return m; });
    });
    shell.replace(/data-i18n(?:-label)?="([^"]+)"/g, function (m, k) { keys.push(['gantt.html', k]); return m; });
    ok('i18n coverage found the M4 strings', keys.length >= 25, String(keys.length));
    // §17.3 (corrected in M4 review round 1): locale following is checked on code, not comments.
    var hostCode = (src['host.js'] || '').replace(/\/\*[\s\S]*?\*\/|\/\/.*$/gm, '');
    var appCode = (src['app.js'] || '').replace(/\/\*[\s\S]*?\*\/|\/\/.*$/gm, '');
    ok('host.js code reads the bootstrap locale (s.locale)', /\bs\.locale\b/.test(hostCode));
    ok("host.js code listens to 'synapse:' + name", /addEventListener\('synapse:' \+ name/.test(hostCode));
    // M9: the handler goes through A.setLocale, which calls setLanguage first.
    ok("app.js code follows on('localechanged')", /\bH\.on\('localechanged'/.test(appCode) && /A\.setLocale\(v \|\| H\.locale\(\)\)/.test(appCode) &&
      /A\.setLocale = function \(tag\) \{\s*I\(\)\.setLanguage\(tag\);/.test(appCode));
    var saved = I.language;
    I.setLanguage('zh-CN');
    var missing = keys.filter(function (k) {
      if (/fmt$/.test(k[0])) return I.fmt(k[1], { n: 2, title: 'x' }) === k[1].replace('{n}', '2').replace('{title}', 'x').replace('(s)', 's');
      return I.text(k[1]) === k[1];
    }).map(function (k) { return k[0] + ': ' + k[1]; });
    var banners = ['future', 'malformed', 'check-failed', 'restore', 'kept', 'read-only'].filter(function (k) {
      var zh = GT.app.bannerText(k);
      I.setLanguage('en-US');
      var en = GT.app.bannerText(k);
      I.setLanguage('zh-CN');
      return !zh || zh === en;
    });
    I.setLanguage(saved);
    eq('every M4 UI string has a zh-CN entry', missing.join('\n'), '');
    eq('every banner has a zh-CN text', banners.join(','), '');
  }

  SPEC.suites.push({ name: 'the scale spec', fn: scaleSpec });
  SPEC.suites.push({ name: 'the layout spec', fn: layoutSpec });
  SPEC.suites.push({ name: 'the theme spec', fn: themeSpec });
  SPEC.suites.push({ name: 'the render helpers spec', fn: renderSpec });
  SPEC.suites.push({ name: 'the pan allocation spec', fn: allocSpec });
  SPEC.suites.push({ name: 'the M4 i18n spec', fn: i18nM4Spec });

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
