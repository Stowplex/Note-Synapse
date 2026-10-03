/*
 * Gantt export image assertions (§12.9): exporter.span, rows, build, fit,
 * scaleFor, fileName; host.attachFile and the mock's attachments; store
 * attachImage (flush first, then one updateNotes). Runs under node
 * (dev/run.js) and in the browser (dev/auto_smoke.html).
 */
(function (global) {
  'use strict';
  var GT = global.GT, SPEC = GT.spec;
  var A = SPEC.api, ok = A.ok, eq = A.eq, acase = A.acase;
  var X = GT.exporter, LY = GT.layout, M = GT.model, D = GT.dates, H = GT.host, TH = GT.theme;
  var P = D.parse;

  function chart(extra) {
    return M.coerce({
      v: 1,
      groups: [{ id: 'g1', title: 'Discovery' }, { id: 'g2', title: 'Build <&> "x"', color: 'teal' }],
      tasks: [
        { id: 't1', note: 'n1', title: 'Alpha', start: '2026-10-01', end: '2026-10-09', group: 'g1' },
        { id: 't2', note: 'n2', title: 'Beta', start: '2026-10-05', end: '2026-10-14', group: 'g1', color: 'pink' },
        { id: 't3', note: 'n3', title: 'Gamma', start: '2026-10-12', end: '2026-11-06', group: 'g2' },
        { id: 't4', note: 'n4', title: 'Launch', start: '2026-11-09', group: 'g2', milestone: true },
        { id: 't5', note: 'n5', title: 'Someday' }
      ].concat(extra || [])
    }).chart;
  }
  var INFO = {
    t1: { title: 'Alpha', meta: 'Overdue · Oct 1 to 9', hue: 'rose', ratio: 0.6, cls: 'late', chip: '3/5' },
    t2: { title: 'Beta', meta: 'Oct 5 to 14', hue: 'pink', ratio: 0, cls: 'todo' },
    t3: { title: 'Gamma', meta: 'Oct 12 to Nov 6', hue: 'blue', ratio: 0.5, cls: 'doing' },
    t4: { title: 'Launch', meta: 'Nov 9', hue: 'slate', ratio: 0, cls: 'none', missing: true },
    t5: { title: 'Someday', meta: 'Unscheduled', hue: 'slate', ratio: 0, cls: 'none' }
  };
  function input(o) {
    var c = o && o.chart || chart();
    return Object.assign({
      chart: c, title: 'Q4 <Launch>', range: 'all', cam: { sx: 0, sy: 0, ppd: 16, epoch: P('2026-08-01') },
      bodyW: 273, bodyH: 600, viewRows: LY.buildRows(c, ['g2'], 'comfortable').rows, density: 'comfortable',
      info: function (id) { return INFO[id] || null; }, today: P('2026-10-20'), weekStart: 1, showWeekends: true
    }, o || {});
  }
  function count(s, re) { return (s.match(re) || []).length; }
  /*
   * A small XML well-formedness check (no DOMParser in node): tags nest,
   * text holds no '<', every '&' starts an entity. wellFormed.last says why.
   */
  function wellFormed(s) {
    var stack = [], i = 0, re = /<(\/?)([A-Za-z][\w:-]*)((?:\s+[\w:-]+="[^"<]*")*)\s*(\/?)>/y;
    function fail(why) { wellFormed.last = why + ' at ' + i + ': ' + s.slice(Math.max(0, i - 30), i + 30); return false; }
    while (i < s.length) {
      if (s[i] === '<') {
        re.lastIndex = i;
        var m = re.exec(s);
        if (!m) return fail('bad tag');
        if (m[1]) { if (stack.pop() !== m[2]) return fail('unbalanced ' + m[2]); }
        else if (!m[4]) stack.push(m[2]);
        if (/&(?!(amp|lt|gt|quot|apos|#\d+);)/.test(m[3])) return fail('raw & in an attribute');
        i = re.lastIndex;
      } else {
        var j = s.indexOf('<', i), text = s.slice(i, j < 0 ? s.length : j);
        if (/&(?!(amp|lt|gt|quot|apos|#\d+);)/.test(text)) return fail('raw &');
        if (j < 0) break;
        i = j;
      }
    }
    return stack.length ? fail('unclosed ' + stack.join(',')) : true;
  }

  function exportSpec() {
    eq('esc: XML specials', X.esc('a<b>&"c"\u0001'), 'a&lt;b&gt;&amp;&quot;c&quot;');
    eq('estimate: CJK is 1 em, Latin 0.56 em', X.estimate('中文', 10) + '|' + Math.round(X.estimate('ab', 10) * 100) / 100, '20|11.2');
    eq('fit: a text that fits is kept', X.fit('Alpha', 100, 14), 'Alpha');
    var f = X.fit('A very long task title indeed', 80, 14);
    ok('fit: a long text is cut with an ellipsis within the width', /…$/.test(f) && X.estimate(f, 14) <= 80 && f.length > 3, f);
    eq('fit: no room at all', X.fit('Alpha', 0, 14), '');

    // span
    var sa = X.span(input());
    eq('span all: the dated range plus 3 days each side', [D.format(sa.from), D.format(sa.to - 1), sa.ppd].join('|'), '2026-09-28|2026-11-12|16');
    var wide = X.span(input({ cam: { sx: 0, sy: 0, ppd: 200, epoch: 0 } }));
    ok('span all: a zoom wider than MAX_CHART_W is zoomed out to fit', Math.abs((wide.to - wide.from) * wide.ppd - X.MAX_CHART_W) < 1e-6 && wide.ppd < 200);
    var none = X.span(input({ chart: M.coerce({ v: 1, tasks: [{ id: 'u', note: 'n', title: 'U' }] }).chart }));
    eq('span all: no dated task shows today - 1 .. today + 28', D.format(none.from) + '|' + D.format(none.to), '2026-10-19|2026-11-17');
    var sv = X.span(input({ range: 'view', cam: { sx: 160, sy: 0, ppd: 16, epoch: P('2026-09-01') } }));
    eq('span view: the camera window, fractional days kept', [D.format(sv.from), sv.to - sv.from, sv.ppd].join('|'), '2026-09-11|' + (273 / 16) + '|16');

    // rows
    var ra = X.rows(input());
    eq('rows all: every group expanded (the view had g2 collapsed)', ra.rows.map(function (r) { return r.kind === 'task' ? r.id : '[' + r.id + ']'; }).join(','),
      '[g1],t1,t2,[g2],t3,t4,[' + LY.UNSCHED + '],t5');
    var vr = LY.buildRows(chart(), [], 'comfortable').rows;
    var rv = X.rows(input({ range: 'view', viewRows: vr, cam: { sx: 0, sy: 40, ppd: 16, epoch: 0 }, bodyH: 100 }));
    eq('rows view: the rows in view, the first moved to y 0', rv.rows.map(function (r) { return r.id + '@' + r.y; }).join(','), 't1@0,t2@44,g2@88');

    // build
    var b = X.build(input());
    ok('build: one svg of the stated size', /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg" width="\d+" height="\d+"/.test(b.svg) && /<\/svg>$/.test(b.svg) &&
      b.svg.indexOf('width="' + b.w + '" height="' + b.h + '"') > 0);
    eq('build: width is the name column plus the days', b.w, b.nameW + Math.round((b.to - b.from) * b.ppd));
    var rowsH = ra.rows.reduce(function (n, r) { return n + r.h; }, 0);
    eq('build: height is title, header and every row', b.h, X.TITLE_H + X.HDR[0] + X.HDR[1] + rowsH + 1);
    ok('build: the name column is between 160 and 300', b.nameW >= X.NAME_MIN && b.nameW <= X.NAME_MAX);
    ok('build: the title is escaped', b.svg.indexOf('Q4 &lt;Launch&gt;') > 0 && b.svg.indexOf('Build &lt;&amp;&gt; &quot;x&quot;') > 0);
    ok('build: every task title is in the name column', ['Alpha', 'Beta', 'Gamma', 'Launch', 'Someday'].every(function (t) { return b.svg.indexOf('>' + t + '</text>') > 0; }));
    ok('build: ... with its meta line', b.svg.indexOf('>Overdue · Oct 1 to 9</text>') > 0);
    var L = TH.PALETTE;
    ok('build: bars use the light palette of their hue', b.svg.indexOf('fill="' + L.rose.light.tint + '" stroke="' + L.rose.light.stroke + '"') > 0 &&
      b.svg.indexOf('fill="' + L.pink.light.tint + '"') > 0 && b.svg.indexOf('fill="' + L.blue.light.fill + '"') > 0);
    var DK = TH.TOKENS.dark;
    ok('build: always the light theme (no dark token)', ['--g-bg', '--surface', '--text', '--today'].every(function (k) { return b.svg.indexOf(DK[k]) < 0; }) &&
      b.svg.indexOf('fill="' + TH.TOKENS.light['--g-bg'] + '"') > 0);
    ok('build: the completion fill is ratio x width (t1 at 60%)', (function () {
      var g = LY.barGeom(chart().tasks[0], ra.rows[1], { sx: 0, sy: 0, ppd: b.ppd, epoch: b.from }, ra.dens, {});
      return b.svg.indexOf('width="' + Math.round(g.w * 0.6) + '" height="' + g.h + '" fill="' + L.rose.light.fill + '"') > 0;
    })());
    ok('build: the chip joins the bar label', b.svg.indexOf('Alpha  3/5') > 0);
    eq('build: one diamond for the milestone', count(b.svg, /<path d="M/g), 1);
    ok('build: a missing note is slate (t4, a milestone, is missing)', /<path d="M[^"]*" fill="([^"]+)"/.exec(b.svg)[1] === L.slate.light.fill);
    var mc = chart();
    var bm = X.build(input({ info: function (id) { return id === 't3' ? Object.assign({}, INFO.t3, { missing: true }) : INFO[id]; }, chart: mc }));
    ok('build: a missing bar is dashed with no fill', bm.svg.indexOf('fill="' + L.slate.light.tint + '" stroke="' + L.slate.light.stroke + '" stroke-dasharray="4 3"') > 0 &&
      bm.svg.indexOf('fill="' + L.blue.light.fill + '"') < 0);
    eq('build: the today line (today in range)', count(b.svg, new RegExp('fill="' + TH.TOKENS.light['--today'] + '"', 'g')), 1);
    var past = X.build(input({ today: P('2027-06-01') }));
    eq('build: no today line when today is outside', count(past.svg, new RegExp('fill="' + TH.TOKENS.light['--today'] + '"', 'g')), 0);
    ok('build: month labels in the header', b.svg.indexOf('>October 2026</text>') > 0 && b.svg.indexOf('>November 2026</text>') > 0);
    var bv = X.build(input({ range: 'view', viewRows: vr, cam: { sx: 0, sy: 40, ppd: 16, epoch: P('2026-09-28') }, bodyH: 100 }));
    ok('build view: only the rows in view', bv.rows === 3 && bv.svg.indexOf('>Alpha</text>') > 0 && bv.svg.indexOf('>Gamma</text>') < 0);
    eq('build view: the width is the name column plus the screen', bv.w, bv.nameW + 273);
    var longC = chart([{ id: 't9', note: 'n9', title: 'An extraordinarily long task title that will not fit in any name column at all', start: '2026-10-02', end: '2026-10-03' }]);
    var bl = X.build(input({ chart: longC }));
    ok('build: the name column stops at 300 and cuts a long title', bl.nameW === X.NAME_MAX && bl.svg.indexOf('An extraordinarily long task title that will not fit in any name column at all</text>') > 0 &&
      /An extraordinarily[^<]*…<\/text>/.test(bl.svg));
    ok('build: a CJK title is measured wide (1 em a character)', X.build(input({ chart: chart([{ id: 'tz', note: 'nz', title: '用户访谈二十位核心用户覆盖三个城市', start: '2026-10-02' }]) })).nameW >= 16 * 14);
    var endC = chart([{ id: 'te', note: 'ne', title: 'A last short task with a long outside label', start: '2026-11-20' }]);
    var be = X.build(input({ chart: endC })), se = X.span(input({ chart: endC }));
    var ge = LY.barGeom(endC.tasks[5], { y: 0, h: 44 }, { sx: 0, sy: 0, ppd: be.ppd, epoch: be.from }, LY.dens('comfortable'), {});
    ok('build all: the chart widens so a label right of the last bar is not cut', be.to > se.to &&
      be.w >= be.nameW + ge.x + ge.w + 6 + X.estimate('A last short task with a long outside label', 12.5), be.w + ' ' + (be.nameW + ge.x + ge.w));
    eq('build view: never widens', X.build(input({ chart: endC, range: 'view' })).w, X.build(input({ chart: endC, range: 'view' })).nameW + 273);
    var mw = X.build(input({ measure: function (t, px) { return String(t).length * px; } }));
    ok('build: a measure function is used when given', mw.nameW > b.nameW);
    var zh = GT.i18n.language;
    GT.i18n.setLanguage('zh-CN');
    var bz = X.build(input());
    GT.i18n.setLanguage(zh);
    ok('build: zh-CN header labels', bz.svg.indexOf('>2026年10月</text>') > 0);

    // Review round 1: every text place is escaped and the SVG is well formed.
    var BAD = 'R&D <x> "q"', BADE = 'R&amp;D &lt;x&gt; &quot;q&quot;';
    var badC = M.coerce({ v: 1, groups: [{ id: 'g1', title: BAD }], tasks: [
      { id: 'a', note: 'na', title: BAD, start: '2026-10-01', end: '2026-10-30', group: 'g1' },
      { id: 'b', note: 'nb', title: BAD, start: '2026-10-02', end: '2026-10-02', group: 'g1' },
      { id: 'm', note: 'nm', title: BAD, start: '2026-10-10', milestone: true, group: 'g1' }
    ] }).chart;
    var badI = { a: { title: BAD, meta: 'meta ' + BAD, hue: 'blue', ratio: 0.5, cls: 'doing', chip: '1<2' }, b: { title: BAD, meta: 'x', hue: 'blue', ratio: 0, cls: 'todo' }, m: { title: BAD, meta: 'y', hue: 'slate', ratio: 0, cls: 'none' } };
    var bb = X.build(input({ chart: badC, title: BAD, info: function (id) { return badI[id]; }, measure: function (t, px) { return String(t).length * px * 0.3; } }));
    function texts(re) { var out = [], m, r = new RegExp(re, 'g'); while ((m = r.exec(bb.svg))) out.push(m[1]); return out; }
    ok('escape: task titles in the name column', texts('<text x="14" y="[^"]*" font-size="14"[^>]*>([^<]*)</text>').filter(function (t) { return t === BADE; }).length === 3);
    ok('escape: meta lines', texts('<text x="14" y="[^"]*" font-size="11.5"[^>]*>([^<]*)</text>').indexOf('meta ' + BADE) >= 0);
    ok('escape: a bar label inside the bar (and its ink copy)', texts('<text [^>]*font-size="12.5"[^>]*>([^<]*)</text>').filter(function (t) { return t === BADE + '  1&lt;2'; }).length === 2);
    ok('escape: a bar label right of a short bar', /<\/clipPath><rect[^>]*\/><text [^>]*>R&amp;D &lt;x&gt; &quot;q&quot;<\/text><\/g>/.test(bb.svg));
    ok('escape: the milestone label', /<path d="M[^"]*" fill="[^"]*"\/><text [^>]*>R&amp;D &lt;x&gt; &quot;q&quot;<\/text>/.test(bb.svg));
    ok('escape: the group title and the chart title', texts('<text x="10" [^>]*>([^<]*)</text>').indexOf(BADE) >= 0 && texts('<text x="14" y="30"[^>]*>([^<]*)</text>').indexOf(BADE) >= 0);
    ok('escape: no raw text anywhere (well formed)', wellFormed(bb.svg), wellFormed.last);
    ok('well-formed checker: catches a raw < and &', !wellFormed('<svg><text>a<b</text></svg>') && !wellFormed('<svg><text>R&D</text></svg>') && wellFormed('<svg><text>R&amp;D</text></svg>'));
    // Missing note label; today under the bars; the top tier label shows whole or not at all.
    var bmi = X.build(input({ info: function (id) { return id === 't3' ? Object.assign({}, INFO.t3, { missing: true }) : INFO[id]; } }));
    ok("build: a missing note's bar says Missing note, italic and muted", bmi.svg.indexOf('font-style="italic" fill="' + TH.TOKENS.light['--muted'] + '">Missing note</text>') > 0 &&
      bmi.svg.indexOf('>Gamma</text>') > 0 && bmi.svg.indexOf('>Gamma  </text>') < 0);
    var tIdx = b.svg.indexOf('fill="' + TH.TOKENS.light['--today'] + '"'), barIdx = b.svg.indexOf('fill="' + L.rose.light.tint + '"');
    ok('build: the today line is drawn before (under) the bars', tIdx > 0 && barIdx > tIdx);
    ok('build: a 3-day first month has no cut label ("Sep…")', b.svg.indexOf('>Sep…</text>') < 0 && b.svg.indexOf('>September 2026</text>') < 0 && b.svg.indexOf('>October 2026</text>') > 0);
    var one = X.build(input({ range: 'view', cam: { sx: 0, sy: 0, ppd: 44, epoch: P('2026-10-10') }, bodyW: 120, viewRows: vr }));
    ok('build: a lone top-tier label is cut to fit instead', /<text [^>]*font-size="12" font-weight="700"[^>]*>October[^<]*<\/text>/.test(one.svg));
    eq('estimate: Hangul is wide, an emoji counts once', X.estimate('한글', 10) + '|' + X.estimate('🚀', 10), '20|10');

    // raster scale, file name
    eq('scaleFor: 2 for a phone-sized chart', X.scaleFor(800, 600), 2);
    eq('scaleFor: the side cap', X.scaleFor(8192, 100), 1);
    ok('scaleFor: the area cap', Math.abs(X.scaleFor(4000, 3000) * X.scaleFor(4000, 3000) * 12e6 - X.MAX_PX) < 1);
    eq('fileName: sanitized, dated', X.fileName('Q4: plan / "v2"?', P('2026-10-20')), 'Q4 plan v2 2026-10-20.png');
    eq('fileName: empty title', X.fileName('  ', P('2026-10-20')), 'Gantt 2026-10-20.png');
    var emo = X.fileName(new Array(80).join('a') + '🚀🚀', P('2026-10-20'));
    ok('fileName: cut at 80 code points, never inside a surrogate pair', emo === new Array(80).join('a') + '🚀 2026-10-20.png', emo);
    eq('fileName: no leading dot, trimmed after the cut', X.fileName('..hidden', P('2026-10-20')) + '|' + X.fileName(new Array(80).join('a') + ' b', P('2026-10-20')).length,
      'hidden 2026-10-20.png|' + (79 + 15));
  }

  function attachSpec() {
    var PNG = 'data:image/png;base64,iVBORw0KGgo=';
    acase('attachFile: one base64 attachment, content untouched', function () {
      var m = H.installMock([{ id: 'c', content: 'chart body' }], { storage: new Map(), global: false });
      return m.host.attachFile('c', PNG, 'Q4 2026-10-20.png').then(function (r) {
        ok('attachFile: ok', r.ok);
        // Review round 1: fileName before data, so the approval dialog's cut text shows the name.
        eq('attachFile: the entry, fileName before the base64', JSON.stringify(m.updates[0]), JSON.stringify([{ id: 'c', modification: { attachments: { added: [{ type: 'base64', fileName: 'Q4 2026-10-20.png', data: PNG }] } } }]));
        eq('attachFile: the mock keeps the file and the content', JSON.stringify(m.note('c').attachments.map(function (a) { return [a.fileName, a.mimeType]; })) + '|' + m.note('c').content,
          '[["Q4 2026-10-20.png","image/png"]]|chart body');
        ok('mock: stored as <stem>_<uuid>.<ext>, like generateUniqueFileName', /^attachments\/Q4 2026-10-20_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}\.png$/.test(m.note('c').attachments[0].path), m.note('c').attachments[0].path);
        return m.host.attachFile('c', 'not a data url', 'x.png');
      }).then(function (r) {
        ok('attachFile: a bad data url is refused before the bridge', !r.ok && m.count('updateNotes') === 1);
        return m.host.attachFile('c', PNG, ' ');
      }).then(function (r) {
        ok('attachFile: an empty file name is refused', !r.ok && m.count('updateNotes') === 1);
        return m.synapse.updateNotes([{ id: 'c', modification: { attachments: { added: [{ type: 'base64', data: PNG }] } } }]);
      }).then(function (r) {
        ok('mock: a base64 attachment without a file name fails the entry, like processAttachment', r.success && r.errors && r.errors.length === 1);
      });
    });
    acase('attachFile: a denial', function () {
      var m = H.installMock([{ id: 'c', content: 'x' }], { storage: new Map(), global: false, approve: 'deny' });
      return m.host.attachFile('c', PNG, 'a.png').then(function (r) {
        ok('attachFile: denied', !r.ok && r.denied && !m.note('c').attachments);
      });
    });
  }

  SPEC.suites.push({ name: 'the export spec', fn: exportSpec });
  SPEC.suites.push({ name: 'the export attach spec', fn: attachSpec });

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
