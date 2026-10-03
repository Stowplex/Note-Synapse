/*
 * Gantt - image export (plan §12.9, feature "Export image", v1).
 *
 * X.build(input) lays the chart out as one SVG in the light theme, always:
 * a title line, the two header tiers, the name column and the bars, for
 * either the whole chart (every group expanded, every dated day plus a
 * small margin) or exactly what is on screen (the camera's days and the
 * rows in view). Pure: no DOM at load or build time, so node tests it.
 * X.toPng(svg, w, h, doc) rasterizes it in the browser (Image + canvas).
 * Text widths come from input.measure when given (canvas measureText in
 * the app); the fallback estimates 1 em per CJK character and 0.56 em
 * otherwise.
 */
(function (global) {
  'use strict';
  var GT = (global.GT = global.GT || {});
  var X = (GT.exporter = {});

  X.PAD_DAYS = 3;          // whole chart: days of margin each side
  X.EMPTY_DAYS = 28;       // whole chart with no dated task: today .. +28
  X.MAX_CHART_W = 6000;    // whole chart: the day axis is zoomed out to fit this (CSS px)
  X.MIN_PPD = 1;
  X.TITLE_H = 48;
  X.HDR = [20, 24];
  X.NAME_MIN = 160;
  X.NAME_MAX = 300;
  X.MAX_SIDE = 8192;       // raster caps (device px)
  X.MAX_PX = 12e6;
  X.SCALE = 2;             // preferred raster scale
  X.FONT = '-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, Roboto, "Noto Sans", "PingFang SC", "Hiragino Sans GB", "Noto Sans CJK SC", "Microsoft YaHei", sans-serif';

  function I() { return GT.i18n; }
  function LY() { return GT.layout; }
  function SC() { return GT.scale; }
  function TH() { return GT.theme; }
  function DT() { return GT.dates; }

  // XML text: escaped, control characters dropped.
  function esc(s) {
    return String(s == null ? '' : s).replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, '')
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
  X.esc = esc;
  function n1(v) { return Math.round(v * 10) / 10; }

  // Wide: CJK, Hangul, full-width forms, and anything outside the BMP (emoji).
  function wide(c) {
    return (c >= 0x1100 && c <= 0x11ff) || (c >= 0x2e80 && c <= 0x9fff) || (c >= 0xac00 && c <= 0xd7af) ||
      (c >= 0xf900 && c <= 0xfaff) || (c >= 0xff00 && c <= 0xffef) || (c >= 0x2600 && c <= 0x27bf) || c > 0xffff;
  }
  // Per code point, so a surrogate pair counts once.
  X.estimate = function (text, px) {
    var w = 0;
    Array.from(String(text || '')).forEach(function (ch) { w += wide(ch.codePointAt(0)) ? px : px * 0.56; });
    return w;
  };
  // The longest prefix of text (plus an ellipsis) that fits max px.
  X.fit = function (text, max, px, weight, measure) {
    var m = measure || function (t, p) { return X.estimate(t, p); };
    var s = String(text || '');
    if (max <= 0) return '';
    if (m(s, px, weight) <= max) return s;
    var chars = Array.from(s), lo = 0, hi = chars.length;
    while (lo < hi) {
      var mid = (lo + hi + 1) >> 1;
      if (m(chars.slice(0, mid).join('') + '…', px, weight) <= max) lo = mid; else hi = mid - 1;
    }
    return lo ? chars.slice(0, lo).join('') + '…' : '';
  };

  /*
   * span(input) -> {from, to, ppd}: the days drawn, [from, to), and px a day.
   *   view: the camera's window, fractional days kept, so the image matches
   *         the screen; all: the dated range plus PAD_DAYS, today when the
   *         chart has no dates, the camera's ppd unless that is wider than
   *         MAX_CHART_W.
   */
  X.span = function (input) {
    var cam = input.cam;
    if (input.range === 'view') {
      var from = cam.epoch + cam.sx / cam.ppd;
      return { from: from, to: from + Math.max(1, input.bodyW) / cam.ppd, ppd: cam.ppd };
    }
    var r = GT.model.range(input.chart), t = input.today;
    var a = r ? r.min - X.PAD_DAYS : t - 1, b = r ? r.max + 1 + X.PAD_DAYS : t + X.EMPTY_DAYS;
    var ppd = Math.max(X.MIN_PPD, Math.min(cam.ppd, X.MAX_CHART_W / (b - a)));
    return { from: a, to: b, ppd: ppd };
  };

  /*
   * rows(input) -> {rows, dens}: every row with every group expanded (all),
   * or the rows that intersect the view, moved up so the first one is at 0.
   */
  X.rows = function (input) {
    if (input.range !== 'view') {
      var b = LY().buildRows(input.chart, [], input.density || 'comfortable', { rowH: input.rowH });
      return { rows: b.rows, dens: b.dens };
    }
    var all = input.viewRows || [], y0 = input.cam.sy, y1 = y0 + input.bodyH;
    var vr = LY().visibleRange(all, y0, y1), out = [], top = null;
    for (var i = vr.first; i <= vr.last; i++) {
      var r = all[i];
      if (top === null) top = r.y;
      var c = {};
      Object.keys(r).forEach(function (k) { c[k] = r[k]; });
      c.y = r.y - top;
      out.push(c);
    }
    return { rows: out, dens: LY().dens(input.density || 'comfortable', input.rowH) };
  };

  function pal(hue) { var p = TH().PALETTE[hue] || TH().PALETTE.slate; return p.light; }

  /*
   * build(input) -> {svg, w, h, from, to, ppd, rows, nameW}
   * input: {chart, title, range: 'all'|'view', cam {sx, sy, ppd, epoch},
   *   bodyW, bodyH, viewRows, density, rowH, info(id) -> render info,
   *   today, weekStart, showWeekends, measure(text, px, weight)}
   */
  X.build = function (input) {
    var T = TH().TOKENS.light, measure = input.measure || function (t, p) { return X.estimate(t, p); };
    var sp = X.span(input), rs = X.rows(input), rows = rs.rows, dens = rs.dens;
    var info = input.info || function () { return null; };
    function inf(t) {
      var v = info(t.id) || {};
      var title = v.title || t.title || I().text('Untitled');
      // The bar says "Missing note" for a missing note, as on screen.
      return { title: title, label: v.missing ? I().text('Missing note') : title, meta: v.meta || '', hue: v.hue || 'slate', ratio: typeof v.ratio === 'number' ? v.ratio : 0,
        cls: v.cls || 'none', chip: v.chip || '', missing: !!v.missing };
    }
    // A bar's label: the title and its chip, or "Missing note".
    function barLabel(v) { return v.missing ? v.label : v.title + (v.chip ? '  ' + v.chip : ''); }
    function groupTitle(r) { return r.unscheduled ? I().text('Unscheduled') : ((r.group && r.group.title) || I().text('Untitled')); }

    // The name column fits the longest title, within NAME_MIN..NAME_MAX.
    var need = 0;
    rows.forEach(function (r) {
      if (r.kind === 'task') need = Math.max(need, measure(inf(r.task).title, 14, 600) + 30);
      else need = Math.max(need, measure(groupTitle(r), 13, 700) + 52);
    });
    var nameW = Math.round(Math.max(X.NAME_MIN, Math.min(X.NAME_MAX, need)));
    var cam = { sx: 0, sy: 0, ppd: sp.ppd, epoch: sp.from };
    // Whole chart: a label right of a bar near the end widens the chart so it is not cut.
    if (input.range !== 'view') {
      var gg = {}, right = 0;
      rows.forEach(function (r) {
        if (r.kind !== 'task' || !LY().barGeom(r.task, r, cam, dens, gg)) return;
        var v = inf(r.task), lw = measure(barLabel(v), 12.5, 600);
        if (gg.ms || lw + 16 > gg.w) right = Math.max(right, gg.x + gg.w + 6 + lw + 12);
      });
      var extra = Math.ceil(right / sp.ppd) - (sp.to - sp.from);
      if (extra > 0) sp.to += extra;
    }
    var chartW = Math.max(1, Math.round((sp.to - sp.from) * sp.ppd));
    var hdrH = X.HDR[0] + X.HDR[1], top = X.TITLE_H, bodyTop = top + hdrH;
    var rowsH = rows.length ? rows[rows.length - 1].y + rows[rows.length - 1].h : 44;
    var W = nameW + chartW, H = bodyTop + rowsH + 1;
    function xOf(day) { return nameW + (day - sp.from) * sp.ppd; }

    var o = [];
    o.push('<svg xmlns="http://www.w3.org/2000/svg" width="' + W + '" height="' + H + '" viewBox="0 0 ' + W + ' ' + H + '">');
    o.push('<style>text{font-family:' + esc(X.FONT) + ';}</style>');
    o.push('<defs><clipPath id="gc"><rect x="' + nameW + '" y="' + top + '" width="' + chartW + '" height="' + (H - top) + '"/></clipPath></defs>');
    o.push('<rect width="' + W + '" height="' + H + '" fill="' + T['--g-bg'] + '"/>');

    // Title line: the chart title and the dates shown.
    var last = Math.ceil(sp.to) - 1, first = Math.floor(sp.from);
    var when = I().date.range(first, last);
    var whenW = measure(when, 12, 500);
    o.push('<rect width="' + W + '" height="' + top + '" fill="' + T['--surface'] + '"/>');
    o.push('<text x="14" y="30" font-size="17" font-weight="700" fill="' + T['--text'] + '">' +
      esc(X.fit(input.title || I().text('Untitled'), W - whenW - 44, 17, 700, measure)) + '</text>');
    o.push('<text x="' + (W - 14) + '" y="30" font-size="12" font-weight="500" text-anchor="end" fill="' + T['--muted'] + '">' + esc(when) + '</text>');
    o.push('<rect y="' + (top - 1) + '" width="' + W + '" height="1" fill="' + T['--border'] + '"/>');

    // Grid: group bands, alternate stripes, weekends, unit lines.
    o.push('<g clip-path="url(#gc)">');
    rows.forEach(function (r, i) {
      if (r.kind === 'group') o.push('<rect x="' + nameW + '" y="' + (bodyTop + r.y) + '" width="' + chartW + '" height="' + r.h + '" fill="' + T['--surface-2'] + '" fill-opacity=".6"/>');
      else if (i % 2 === 1) o.push('<rect x="' + nameW + '" y="' + (bodyTop + r.y) + '" width="' + chartW + '" height="' + r.h + '" fill="' + T['--g-stripe'] + '"/>');
    });
    var d0 = Math.floor(sp.from), d1 = Math.ceil(sp.to);
    if (sp.ppd >= 6 && input.showWeekends !== false) {
      var we = I().weekendDays();
      for (var d = d0; d < d1; d++) {
        if (we.indexOf(DT().dow(d)) >= 0) o.push('<rect x="' + n1(xOf(d)) + '" y="' + bodyTop + '" width="' + n1(sp.ppd) + '" height="' + (H - bodyTop) + '" fill="' + T['--g-weekend'] + '"/>');
      }
    }
    var tier = SC().tierFor(sp.ppd), ws = typeof input.weekStart === 'number' ? input.weekStart : 1;
    var buf = new Float64Array(4096), n, k;
    n = SC().ticks(tier.unit, d0, d1, ws, buf);
    for (k = 0; k < n; k++) o.push('<rect x="' + n1(xOf(buf[k])) + '" y="' + (top + X.HDR[0]) + '" width="1" height="' + (H - top - X.HDR[0]) + '" fill="' + T['--g-line'] + '"/>');
    var topUnit = tier.top, bufT = new Float64Array(512), nT = SC().ticks(topUnit, d0, d1, ws, bufT);
    for (k = 0; k < nT; k++) o.push('<rect x="' + n1(xOf(bufT[k])) + '" y="' + top + '" width="1" height="' + (H - top) + '" fill="' + T['--g-line-strong'] + '"/>');
    o.push('</g>');

    // Header labels (clipped to the chart area).
    o.push('<rect x="' + nameW + '" y="' + (bodyTop - 1) + '" width="' + chartW + '" height="1" fill="' + T['--border'] + '"/>');
    o.push('<g clip-path="url(#gc)">');
    var D = I().date;
    for (k = 0; k < nT; k++) {
      var tx = Math.max(xOf(bufT[k]), nameW) + 6, nextX = k + 1 < nT ? xOf(bufT[k + 1]) : W;
      var tl = topUnit === 'year' ? String(new Date(bufT[k] * 864e5).getUTCFullYear()) : D.monthYear(bufT[k]);
      // A label shows whole or not at all ("Sep…" over a 3-day stub says
      // nothing), unless it is the only one; then it is cut to fit.
      var room = nextX - tx - 6;
      if (measure(tl, 12, 700) <= room || (nT === 1 && room > 24)) {
        o.push('<text x="' + n1(tx) + '" y="' + (top + 15) + '" font-size="12" font-weight="700" fill="' + T['--text'] + '">' + esc(X.fit(tl, room, 12, 700, measure)) + '</text>');
      }
    }
    for (k = 0; k < n; k++) {
      var a = buf[k], bx = xOf(a), nx = k + 1 < n ? xOf(buf[k + 1]) : xOf(SC().unitNext(tier.unit, a));
      var lab = tier.unit === 'day' ? D.dayNum(a) : tier.unit === 'week' ? D.short(a) : tier.unit === 'month' ? D.monthShort(a)
        : tier.unit === 'quarter' ? D.quarter(a) : String(new Date(a * 864e5).getUTCFullYear());
      var lx = Math.max(bx, nameW) + 4;
      if (nx - lx >= measure(lab, 11.5, 500) + 2) o.push('<text x="' + n1(lx) + '" y="' + (top + X.HDR[0] + 16) + '" font-size="11.5" font-weight="500" fill="' + T['--muted'] + '">' + esc(lab) + '</text>');
    }
    o.push('</g>');

    // Name column.
    o.push('<rect y="' + top + '" width="' + nameW + '" height="' + (H - top) + '" fill="' + T['--surface'] + '"/>');
    rows.forEach(function (r) {
      var y = bodyTop + r.y;
      if (r.kind === 'group') {
        o.push('<rect y="' + y + '" width="' + nameW + '" height="' + r.h + '" fill="' + T['--surface-2'] + '"/>');
        o.push('<rect y="' + y + '" width="' + W + '" height="1" fill="' + T['--border'] + '"/>');
        var cnt = String(r.n), cw = Math.max(16, measure(cnt, 11, 650) + 8);
        o.push('<text x="10" y="' + n1(y + r.h / 2 + 4.5) + '" font-size="13" font-weight="700" fill="' + T['--muted'] + '">' +
          esc(X.fit(groupTitle(r), nameW - cw - 26, 13, 700, measure)) + '</text>');
        o.push('<rect x="' + n1(nameW - 10 - cw) + '" y="' + n1(y + r.h / 2 - 8) + '" width="' + n1(cw) + '" height="16" rx="8" fill="' + T['--surface-3'] + '"/>');
        o.push('<text x="' + n1(nameW - 10 - cw / 2) + '" y="' + n1(y + r.h / 2 + 4) + '" font-size="11" font-weight="650" text-anchor="middle" fill="' + T['--muted'] + '">' + esc(cnt) + '</text>');
        return;
      }
      var v = inf(r.task), p = pal(v.missing ? 'slate' : v.hue), two = r.h >= 40 && v.meta;
      o.push('<rect x="0" y="' + (y + 8) + '" width="4" height="' + (r.h - 16) + '" rx="2" fill="' + p.fill + '"/>');
      o.push('<text x="14" y="' + n1(two ? y + r.h / 2 - 3 : y + r.h / 2 + 5) + '" font-size="14" font-weight="600" fill="' + (v.missing ? T['--muted'] : T['--text']) + '">' +
        esc(X.fit(v.title, nameW - 24, 14, 600, measure)) + '</text>');
      if (two) o.push('<text x="14" y="' + n1(y + r.h / 2 + 13) + '" font-size="11.5" font-weight="500" fill="' + T['--muted'] + '">' + esc(X.fit(v.meta, nameW - 24, 11.5, 500, measure)) + '</text>');
      o.push('<rect x="' + nameW + '" y="' + (y + r.h - 1) + '" width="' + chartW + '" height="1" fill="' + T['--g-line'] + '"/>');
    });
    o.push('<rect x="' + (nameW - 1) + '" y="' + top + '" width="1" height="' + (H - top) + '" fill="' + T['--border'] + '"/>');
    o.push('<rect y="' + (bodyTop - 1) + '" width="' + nameW + '" height="1" fill="' + T['--border'] + '"/>');

    // Today, under the bars so it never crosses a label.
    o.push('<g clip-path="url(#gc)">');
    var td = input.today;
    if (typeof td === 'number' && td >= sp.from && td < sp.to) {
      var tx2 = n1(xOf(td) + sp.ppd / 2);
      o.push('<rect x="' + n1(tx2 - 1) + '" y="' + (bodyTop - 4) + '" width="2" height="' + (H - bodyTop + 4) + '" fill="' + T['--today'] + '"/>');
    }
    // Bars: tint with stroke, completion as fill, the label inside when it
    // fits (text over the tint, ink over the fill), else right of the bar.
    // A missing note's bar says "Missing note", italic and muted.
    var g = {}, id = 0;
    rows.forEach(function (r) {
      if (r.kind !== 'task') return;
      var t = r.task, v = inf(t);
      if (!LY().barGeom(t, r, cam, dens, g)) return;
      var p = pal(v.missing ? 'slate' : v.hue), x = nameW + g.x, y = bodyTop + g.y;
      var dropped = v.cls === 'dropped', dash = v.missing || dropped ? ' stroke-dasharray="4 3"' : '';
      var label = barLabel(v);
      var look = v.missing ? '" font-style="italic" fill="' + T['--muted'] : '" fill="' + T['--text'];
      if (g.ms) {
        var c = g.w / 2;
        o.push('<path d="M' + n1(x + c) + ' ' + y + 'L' + n1(x + g.w) + ' ' + n1(y + c) + 'L' + n1(x + c) + ' ' + (y + g.h) + 'L' + x + ' ' + n1(y + c) + 'Z" fill="' + p.fill + '"/>');
        o.push('<text x="' + n1(x + g.w + 6) + '" y="' + n1(y + c + 4.5) + '" font-size="12.5" font-weight="600' + look + '">' + esc(label) + '</text>');
        return;
      }
      id++;
      var op = dropped ? ' opacity=".55"' : '';
      o.push('<g' + op + '>');
      o.push('<clipPath id="b' + id + '"><rect x="' + x + '" y="' + y + '" width="' + g.w + '" height="' + g.h + '" rx="7"/></clipPath>');
      o.push('<rect x="' + x + '" y="' + y + '" width="' + g.w + '" height="' + g.h + '" rx="7" fill="' + p.tint + '" stroke="' + p.stroke + '"' + dash + '/>');
      var fw = Math.round(g.w * (v.cls === 'done' ? 1 : Math.max(0, Math.min(1, v.ratio))));
      if (fw > 0 && !v.missing) o.push('<rect x="' + x + '" y="' + y + '" width="' + fw + '" height="' + g.h + '" fill="' + p.fill + '" clip-path="url(#b' + id + ')"/>');
      var lw = measure(label, 12.5, 600), ty = n1(y + g.h / 2 + 4.5);
      if (lw + 16 <= g.w) {
        o.push('<text x="' + (x + 8) + '" y="' + ty + '" font-size="12.5" font-weight="600' + look + '">' + esc(label) + '</text>');
        if (fw > 0 && !v.missing) {
          o.push('<clipPath id="f' + id + '"><rect x="' + x + '" y="' + y + '" width="' + fw + '" height="' + g.h + '"/></clipPath>');
          o.push('<text x="' + (x + 8) + '" y="' + ty + '" font-size="12.5" font-weight="600" fill="' + p.ink + '" clip-path="url(#f' + id + ')">' + esc(label) + '</text>');
        }
      } else {
        o.push('<text x="' + (x + g.w + 6) + '" y="' + ty + '" font-size="12.5" font-weight="600' + look + '">' + esc(label) + '</text>');
      }
      o.push('</g>');
    });
    o.push('</g>');
    o.push('</svg>');
    return { svg: o.join(''), w: W, h: H, from: sp.from, to: sp.to, ppd: sp.ppd, rows: rows.length, nameW: nameW };
  };

  // The raster scale: SCALE unless the caps (MAX_SIDE, MAX_PX) need less.
  X.scaleFor = function (w, h) {
    return Math.max(0.1, Math.min(X.SCALE, X.MAX_SIDE / w, X.MAX_SIDE / h, Math.sqrt(X.MAX_PX / (w * h))));
  };

  /*
   * toPng(svg, w, h, doc) -> Promise {ok, dataUrl, w, h, scale} | {ok:false, error}
   * Browser only: the SVG as an <img>, drawn onto a canvas at scaleFor(w, h).
   */
  X.toPng = function (svg, w, h, doc) {
    return new Promise(function (res) {
      try {
        var img = new (doc.defaultView.Image)();
        var s = X.scaleFor(w, h);
        img.onload = function () {
          try {
            var cv = doc.createElement('canvas');
            cv.width = Math.max(1, Math.round(w * s));
            cv.height = Math.max(1, Math.round(h * s));
            var ctx = cv.getContext('2d');
            ctx.drawImage(img, 0, 0, cv.width, cv.height);
            var url = cv.toDataURL('image/png');
            cv.width = cv.height = 0;
            res({ ok: /^data:image\/png;base64,/.test(url), dataUrl: url, w: Math.round(w * s), h: Math.round(h * s), scale: s });
          } catch (e) { res({ ok: false, error: String((e && e.message) || e) }); }
        };
        img.onerror = function () { res({ ok: false, error: 'the image did not load' }); };
        img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
      } catch (e) { res({ ok: false, error: String((e && e.message) || e) }); }
    });
  };

  // "<chart title> YYYY-MM-DD.png", without characters file systems refuse
  // or a leading dot (a hidden file).
  X.fileName = function (title, today) {
    var t = String(title || '').replace(/[\\/:*?"<>|\u0000-\u001f]+/g, ' ').replace(/\s+/g, ' ').trim().replace(/^\.+/, '');
    // 80 code points, so a surrogate pair is never split; trimmed after the cut.
    t = Array.from(t).slice(0, 80).join('').trim() || 'Gantt';
    return t + ' ' + DT().format(today) + '.png';
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
