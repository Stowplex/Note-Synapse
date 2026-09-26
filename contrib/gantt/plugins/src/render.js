/*
 * Gantt renderer (plan §11, §12.4, §12.8, §14.3, D12): two viewport-sized
 * canvases (grid, header) plus pooled, virtualized DOM bars and name rows.
 *
 * A pan is one translate3d on .g-bars and one on .g-names-inner plus two
 * canvas redraws. Leaving the rendered window (the view plus 0.75 viewport
 * horizontally and 6 rows vertically) calls syncWindow(), which recycles
 * pooled elements. One requestAnimationFrame scheduler with dirty flags;
 * event handlers only change state and set flags. Sizes come from the
 * caller (a ResizeObserver in app.js): nothing here reads layout.
 *
 * Note-derived text is written with textContent only.
 */
(function (global) {
  'use strict';
  var GT = (global.GT = global.GT || {});
  var R = (GT.render = {});

  var F = (R.FLAGS = { CAM: 1, WIN: 2, GEOM: 4, DATA: 8, SEL: 16, THEME: 32, LOCALE: 64, SIZE: 128 });
  var ALL = 255;
  R.POOL_CAP = 160;              // bars, names and group headers each (§11.6)
  R.WIN_X = 0.75;                // rendered window: viewports each side
  R.WIN_ROWS = 6;                // rendered window: rows above and below
  R.CANVAS_MAX_PX = 8e6;         // §11.7
  R.CANVAS_MAX_SIDE = 4096;
  R.DPR_MAX = 3;
  R.LRU_CAP = 2000;              // header label cache (§11.7)
  R.TODAY_MS = 60000;            // today-line timer (§11.7)
  R.LABEL_PAD = 16;              // .g-lab padding, both sides: a label fits inside from text + 16
  R.CHIP_GAP = 6;                // the chip's gap after the title
  R.BACKING_PAD = 10;            // the label backing (segments, lite): 5 px each side
  R.SEL_PAD = 16;                // a selected bar's label steps clear of its handles
  R.OUT_GAP = 6;                 // an outside label's gap after the bar

  function SC() { return GT.scale; }
  function LY() { return GT.layout; }
  function DT() { return GT.dates; }

  /*
   * The device pixel ratio a canvas of cssW x cssH may use: min(dpr, 3),
   * lowered until width x height x dpr^2 <= 8e6 and each side <= 4096
   * (§11.7). Backing sizes are floored, so they never exceed the caps.
   */
  R.capDpr = function (cssW, cssH, dpr) {
    var d = Math.min(typeof dpr === 'number' && dpr > 0 ? dpr : 1, R.DPR_MAX);
    var w = Math.max(1, cssW), h = Math.max(1, cssH);
    d = Math.min(d, Math.sqrt(R.CANVAS_MAX_PX / (w * h)), R.CANVAS_MAX_SIDE / w, R.CANVAS_MAX_SIDE / h);
    return d;
  };

  // A least-recently-used cache on a Map: a hit moves the key to the end,
  // a put past the cap evicts the first (oldest-used) key.
  R.lruGet = function (map, key) {
    var v = map.get(key);
    if (v === undefined) return undefined;
    map.delete(key);
    map.set(key, v);
    return v;
  };
  R.lruPut = function (map, key, value, cap) {
    if (map.has(key)) map.delete(key);
    else if (map.size >= cap) map.delete(map.keys().next().value);
    map.set(key, value);
  };

  /*
   * Layout metrics for a #gantt box of w x h (§14.1): landscape phone when
   * wider than tall and under 500 px high; tablet from 768 px wide.
   */
  function clamp(lo, v, hi) { return Math.max(lo, Math.min(hi, v)); }
  R.metrics = function (w, h, density, nameW) {
    var landscape = w > h && h < 500;
    var tablet = !landscape && w >= 768;
    // Portrait phones default narrower (device feedback round 1): more room for bars.
    var nw = landscape ? clamp(150, 0.24 * w, 240) : (tablet ? 240 : clamp(104, 0.30 * w, 150));
    // The user's width for this orientation (the divider, §14.2), if any.
    var own = nameW && typeof nameW === 'object' ? nameW[landscape ? 'l' : 'p'] : null;
    if (typeof own === 'number' && isFinite(own)) nw = R.clampNameW(own, w);
    nw = Math.round(nw);
    var tiers = landscape ? [18, 22] : [20, 24];
    // Q8: 44 px rows in landscape too; compact (36) is one tap away in Display.
    var rowH = density === 'compact' ? 36 : (tablet ? 40 : 44);
    var mini = nw <= R.NAME_MIN;
    return { landscape: landscape, tablet: tablet, nameW: nw, tiers: tiers, hdrH: tiers[0] + tiers[1], rowH: rowH, mini: mini,
      narrow: !mini && nw < R.SEG_FIT };
  };
  /*
   * SEG_FIT: the narrowest column whose corner holds D/W/M at 24 px each
   * beside the 36 px toggle (1 border + 2 padding + 36 + 2 gap + 3 x 24 + 4);
   * narrower columns hide the presets (.narrow). GRP_TALL: a group header
   * this high lets its title take two 14 px lines.
   */
  R.SEG_FIT = 117;
  R.GRP_TALL = 32;
  /*
   * The name column a divider drag asks for (§14.2): between 56 px and half
   * the width; below 88 px it snaps to the 56 px mini column (colour dot and
   * progress ring).
   */
  R.NAME_MIN = 56;
  R.NAME_SNAP = 88;
  R.clampNameW = function (px, w) {
    var x = Math.max(R.NAME_MIN, Math.min(Math.max(R.NAME_MIN, 0.5 * w), px));
    return x < R.NAME_SNAP ? R.NAME_MIN : Math.round(x);
  };

  /*
   * body.lite (§11.6, §14.3 rule 10): from 500 tasks, or after 5
   * consecutive pan frames over 24 ms, the sheen, shadows and the inverted
   * label copy go.
   */
  R.LITE_TASKS = 500;
  R.SLOW_FRAME_MS = 24;
  R.SLOW_FRAMES = 5;
  R.isLite = function (tasks, slowFrames) { return tasks >= R.LITE_TASKS || slowFrames >= R.SLOW_FRAMES; };

  /* ================================================================ create */

  /*
   * create(root, opts) -> view. root is #gantt with the §12.8 children.
   * opts: {i18n, theme, now, frame, cancelFrame, setInterval, clearInterval,
   * setTimeout, dpr, onDay(today), perf, onSettle()}. Every opt defaults to
   * the page's own; onDay fires when the date changes, so the owner can
   * re-derive classes; perf is the animation clock (performance.now);
   * onSettle fires when a zoomBy animation ends.
   */
  R.create = function (root, opts) {
    opts = opts || {};
    var doc = root.ownerDocument, win = doc.defaultView || global;
    var I = opts.i18n || GT.i18n, TH = opts.theme || GT.theme;
    var now = opts.now || function () { return Date.now(); };
    var raf = opts.frame || function (f) { return win.requestAnimationFrame(f); };
    var caf = opts.cancelFrame || function (h) { win.cancelAnimationFrame(h); };
    var dprOf = function () { return typeof opts.dpr === 'number' ? opts.dpr : (win.devicePixelRatio || 1); };

    var q = function (sel) { return root.querySelector(sel); };
    var els = {
      hdr: q('.g-hdr-cv'), grid: q('.g-grid-cv'), names: q('.g-names'), namesInner: q('.g-names-inner'),
      body: q('.g-body'), bars: q('.g-bars'), empty: q('.g-empty'), overlay: q('.g-overlay'), handles: q('.g-handles'),
      allc: q('.g-allc')
    };
    var hctx = els.hdr.getContext('2d'), gctx = els.grid.getContext('2d');
    // The overlay (ghost, snap guides, date bubble) and the resize handles
    // live in content pixels, so they move inside the bars layer: a pan
    // stays one transform (§11.1).
    if (els.overlay && els.overlay.parentNode !== els.bars) els.bars.appendChild(els.overlay);
    if (els.handles && els.handles.parentNode !== els.bars) els.bars.appendChild(els.handles);

    var counters = { frames: 0, domWrites: 0, layoutReads: 0, syncWindow: 0, canvasDraws: 0, lastFrameMs: 0, maxFrameMs: 0 };
    var dirty = 0, pending = null, suspended = false;
    var size = { ok: false, w: 0, h: 0, bodyW: 0, bodyH: 0, m: null, dpr: 1, hdrDpr: 1, gridDpr: 1 };
    var today = DT().today(now());
    var cam = { sx: 0, sy: 0, ppd: SC().PRESETS.week, epoch: today - SC().EPOCH_PAD };
    var data = { chart: null, built: null, info: {}, settings: {}, density: 'comfortable', collapsed: [], showWeekends: true,
      style: 'fill', weekNumbers: false, nameW: null, editable: false };
    // body.lite: slow pan frames in a row, and whether it is on (M8).
    var slowFrames = 0, liteOn = null;
    var win0 = null;                 // the rendered window {x0, x1, r0, r1}
    var initial = null;              // camera request applied once sized
    var flashIds = null, flashUntil = 0;     // {taskId: 1} while a flash runs
    // M6: the selected task (ring, raised, handles when editable) and the
    // drag preview. pv is null or
    //   {kind: 'lift', id}                          a long-pressed bar
    //   {kind: 'move'|'resize', id, start, end, edge?, bubble?, bx?, by?}
    //   {kind: 'reorder', id, dy, from, lo, hi, dir, hd, bubble?, bx?, by?}
    // bx, by: the pointer in body px (the date bubble sits above it).
    var sel = null, selHandles = false, pv = null;
    var pvTask = { id: null, start: null, end: null, milestone: false };
    var tokens = null;
    var lru = new Map(), lruName = '', lruUnit = '', lruWd = false, lruLang = '';
    var KINDS = ['month-year', 'year', 'day', 'day-wd', 'week', 'month', 'quarter', 'today'];
    var tickBuf = new Float64Array(512);
    var scratch = {};
    // The layer transforms, as numbers: a string is built only when they change.
    var layerMemo = { bx: NaN, by: NaN, ny: NaN };
    var pillBuf = { x: 0, y: 0, w: 0, h: 0, text: '' };

    /* ---- counted DOM writes (memoised per element) ---- */
    function wStyle(el, memo, key, prop, val) {
      if (memo[key] === val) return;
      memo[key] = val;
      el.style[prop] = val;
      counters.domWrites++;
    }
    function wVar(el, memo, key, name, val) {
      if (memo[key] === val) return;
      memo[key] = val;
      el.style.setProperty(name, val);
      counters.domWrites++;
    }
    function wClass(el, memo, val) {
      if (memo.cls === val) return;
      memo.cls = val;
      el.className = val;
      counters.domWrites++;
    }
    function wText(el, memo, key, val) {
      if (memo[key] === val) return;
      memo[key] = val;
      el.textContent = val;
      counters.domWrites++;
    }
    function wAttr(el, memo, key, name, val) {
      if (memo[key] === val) return;
      memo[key] = val;
      el.setAttribute(name, val);
      counters.domWrites++;
    }
    function node(tag, cls, parent) {
      var e = doc.createElement(tag);
      if (cls) e.className = cls;
      if (parent) parent.appendChild(e);
      counters.domWrites++;
      return e;
    }

    /* ---- scheduler ---- */
    function schedule() {
      if (pending !== null || suspended) return;
      pending = raf(frame);
    }
    function invalidate(flags) {
      dirty |= (flags || ALL);
      schedule();
    }

    /* ---- pools ---- */
    var barPool = [], namePool = [], groupPool = [];
    function makeBar() {
      var el = node('div', 'g-bar', els.bars);
      el.setAttribute('role', 'button');
      el.setAttribute('tabindex', '-1');
      var fill = node('div', 'g-fill', el);
      // M8: the segments cells (one gradient plus a mask) and the dots row.
      var seg = node('div', 'g-seg', el);
      var lab = node('div', 'g-lab', el);
      var t = node('span', 'g-t', lab), chip = node('span', 'g-chip', lab);
      var inv = node('div', 'g-lab-inv', el);
      inv.setAttribute('aria-hidden', 'true');
      var t2 = node('span', 'g-t', inv), chip2 = node('span', 'g-chip', inv);
      var dots = node('div', 'g-dots', el);
      dots.setAttribute('aria-hidden', 'true');
      return { el: el, fill: fill, seg: seg, dots: dots, t: t, chip: chip, t2: t2, chip2: chip2, m: {}, fm: {}, sm: {}, id: null };
    }
    // M9 (§15.2): name rows and group headers are buttons in a roving
    // tabindex: one row of the column is a tab stop (tabindex 0).
    function makeName() {
      var el = node('div', 'g-name', els.namesInner);
      el.setAttribute('role', 'button');
      el.setAttribute('tabindex', '-1');
      node('div', 'g-rail', el);
      // The mini column's progress ring (§14.2), hidden otherwise.
      node('div', 'g-ring', el);
      var t = node('div', 'g-nt', el), meta = node('div', 'g-nm', el);
      return { el: el, t: t, meta: meta, m: {}, id: null };
    }
    function makeGroup() {
      var el = node('div', 'g-grp', els.namesInner);
      el.setAttribute('role', 'button');
      el.setAttribute('tabindex', '-1');
      var chev = node('span', 'g-chev', el);
      chev.textContent = '▾';
      chev.setAttribute('aria-hidden', 'true');
      node('span', 'g-dot', el);
      var t = node('span', 'g-gt', el), n = node('span', 'g-gn', el);
      return { el: el, t: t, n: n, m: {}, id: null };
    }
    function take(pool, make, k) {
      if (k >= R.POOL_CAP) return null;
      if (!pool[k]) pool[k] = make();
      return pool[k];
    }
    function hideFrom(pool, k) {
      for (var i = k; i < pool.length; i++) {
        var p = pool[i];
        if (p.id !== null) { p.id = null; wStyle(p.el, p.m, 'disp', 'display', 'none'); }
      }
    }

    /* ---- data ---- */

    // Per-task derived text and classes, rebuilt on every setData.
    function derive(chart, summaries, facts) {
      var info = {}, set = chart.settings || {};
      var gIndex = {};
      chart.groups.forEach(function (g, i) { gIndex[g.id] = i; });
      chart.tasks.forEach(function (t) {
        var s = summaries ? summaries(t) : null;
        s = s || { cls: 'none', ratio: null, chip: '', missing: false, loading: !!t.note, total: 0, done: 0 };
        var f = t.note && facts ? facts[t.note] : null;
        var title = f && !f.missing && typeof f.title === 'string' && f.title ? f.title : (t.title || I.text('Untitled'));
        var gi = t.group && Object.prototype.hasOwnProperty.call(gIndex, t.group) ? gIndex[t.group] : -1;
        var hue = LY().colorFor(t, s, gi, set, gi >= 0 ? chart.groups[gi] : null);
        var ratio = s.cls === 'done' ? 1 : (typeof s.ratio === 'number' && !s.loading ? Math.max(0, Math.min(1, s.ratio)) : 0);
        // The status word comes first: a narrow name column cuts the end of the line.
        var parts = [];
        if (s.missing) parts.push(I.text('Missing note'));
        else if (s.cls === 'late') parts.push(I.text('Overdue'));
        else if (s.cls === 'dropped') parts.push(I.text('Dropped'));
        if (typeof t.start === 'number') {
          var end = typeof t.end === 'number' ? t.end : t.start;
          parts.push(end === t.start ? I.date.short(t.start) : I.date.range(t.start, end));
        } else parts.push(I.text('Unscheduled'));
        if (s.chip) parts.push(s.chip);
        var loading = !!s.loading && !s.missing && !!t.note;
        info[t.id] = {
          title: title, label: s.missing ? I.text('Missing note') : title, sum: s, hue: s.missing ? 'slate' : hue,
          cls: s.cls || 'none', ratio: ratio, chip: s.chip || '', missing: !!s.missing, loading: loading,
          // M8: the segments stops (null falls back to fill) and the dots row.
          seg: data.style === 'segments' && !loading && !s.missing ? segFor(s.bits, s.cls === 'late') : null,
          dots: data.style === 'dots' && !loading && !s.missing ? LY().dotsOf(s) : null,
          meta: parts.join(' · '), aria: I.taskLabel({ title: title, start: t.start, end: t.end, milestone: t.milestone }, s)
        };
      });
      return info;
    }
    // Segment gradients are shared by every bar with the same bits and
    // lateness (§14.3 rule 7: rebuilt only when bits, class or style change).
    var segCache = new Map();
    function segFor(bits, late) {
      if (!bits) return null;
      var key = bits + (late ? '|l' : '|o');
      var hit = segCache.get(key);
      if (hit !== undefined) return hit;
      hit = LY().segmentStops(bits, undefined, late);
      R.lruPut(segCache, key, hit, 1000);
      return hit;
    }

    /*
     * setData({chart, summaries, facts, today, collapsed, density,
     * showWeekends}). summaries is task -> §6.3 summary (store's
     * s.summaries(chart)); facts is noteId -> fact (for live titles).
     */
    function setData(d) {
      var chart = d.chart;
      data.chart = chart;
      if (typeof d.today === 'number') today = d.today;
      if (d.collapsed) data.collapsed = d.collapsed;
      if (d.density) data.density = d.density;
      if (typeof d.showWeekends === 'boolean') data.showWeekends = d.showWeekends;
      if (typeof d.editable === 'boolean') data.editable = d.editable;
      // unknown: the counts could not be read (a failed resolve): loading
      // bars show a static track, not an endless shimmer (M8 review).
      data.unknown = !!d.unknown;
      data.settings = chart ? chart.settings || {} : {};
      data.style = LY().styleOf(data.settings);
      if (!chart) {
        slowFrames = 0;
        // Nothing to show (switching charts, a damaged block): drop the old rows now.
        data.built = null; data.info = {}; win0 = null;
        hideFrom(barPool, 0); hideFrom(namePool, 0); hideFrom(groupPool, 0);
        if (els.empty && !els.empty.hidden) { els.empty.hidden = true; counters.domWrites++; }
        invalidate(ALL);
        return;
      }
      data.info = derive(chart, d.summaries, d.facts);
      data.range = GT.model.range(chart);
      rebuild();
      var e = LY().epochFor(chart, today);
      if (e !== cam.epoch) setCam(SC().rebase(cam, e));
      if (els.empty) {
        var none = chart.tasks.length === 0;
        if (els.empty.hidden === none) { els.empty.hidden = !none; counters.domWrites++; }
      }
      states();
      invalidate(F.DATA | F.GEOM | F.WIN | F.CAM);
    }
    // "All groups are collapsed" (§12.6) and body.lite (§11.6).
    function states() {
      var chart = data.chart, b = data.built;
      if (els.allc) {
        var shut = !!chart && !!b && chart.tasks.length > 0 && !b.rows.some(function (r) { return r.kind === 'task'; });
        if (els.allc.hidden === shut) { els.allc.hidden = !shut; counters.domWrites++; }
      }
      setLite(R.isLite(chart ? chart.tasks.length : 0, slowFrames));
    }
    function setLite(on) {
      if (on === liteOn) return;
      liteOn = on;
      if (doc.body) { doc.body.classList.toggle('lite', on); counters.domWrites++; }
      invalidate(F.WIN);          // lite labels carry a backing: placements change
    }
    function rebuild() {
      var m = size.m;
      data.built = LY().buildRows(data.chart, data.collapsed, data.density, { rowH: m ? m.rowH : undefined });
    }
    function setCollapsed(list) {
      data.collapsed = list;
      if (data.chart) rebuild();
      states();
      clampNow();
      invalidate(F.GEOM | F.WIN | F.CAM);
    }
    /*
     * setDisplay({density, showWeekends, weekNumbers, nameW}) applies the
     * Display prefs (D5, device view state): row density, weekend bands,
     * week numbers in the header, the name column width per orientation
     * ({p, l} in px, null for the default).
     */
    function setDisplay(o) {
      o = o || {};
      var relayout = false;
      if (o.density && o.density !== data.density) { data.density = o.density; relayout = true; }
      if (o.nameW !== undefined && JSON.stringify(o.nameW || null) !== JSON.stringify(data.nameW)) { data.nameW = o.nameW || null; relayout = true; }
      if (typeof o.showWeekends === 'boolean' && o.showWeekends !== data.showWeekends) { data.showWeekends = o.showWeekends; invalidate(F.CAM); }
      if (typeof o.weekNumbers === 'boolean' && o.weekNumbers !== data.weekNumbers) { data.weekNumbers = o.weekNumbers; lru.clear(); invalidate(F.CAM); }
      if (relayout && size.w > 0) {
        var w = size.w, h = size.h;
        size.ok = false;
        size.w = -1;
        setSize(w, h);
        states();
      }
    }

    /* ---- camera ---- */
    // The camera object is mutated in place; a pan frame allocates nothing (§14.3 rule 4).
    function setCam(o) { cam.sx = o.sx; cam.sy = o.sy; cam.ppd = o.ppd; cam.epoch = o.epoch; }
    var boundsBuf = { minX: 0, maxX: 0, totalH: 0 }, viewBuf = { w: 0, h: 0 };
    function bounds() {
      var r = data.range, b = boundsBuf;
      var lo = r ? Math.min(r.min, today) : today, hi = r ? Math.max(r.max, today) : today;
      b.minX = (lo - cam.epoch) * cam.ppd;
      b.maxX = (hi + 1 - cam.epoch) * cam.ppd;
      b.totalH = data.built ? data.built.totalH : 0;
      return b;
    }
    function clampNow() {
      if (!size.ok) return;
      viewBuf.w = size.bodyW;
      viewBuf.h = size.bodyH;
      SC().clampCamera(cam, bounds(), viewBuf, cam);
    }
    function setCamera(c) {
      anim.on = false;
      setCam({ sx: c.sx, sy: c.sy, ppd: SC().clampPpd(c.ppd), epoch: typeof c.epoch === 'number' ? c.epoch : cam.epoch });
      clampNow();
      invalidate(F.CAM | F.GEOM);
    }
    // -> the axes that moved (1 x, 2 y), so a fling stops at an edge.
    function panBy(dx, dy) {
      anim.on = false;
      var bx = cam.sx, by = cam.sy;
      cam.sx += dx;
      cam.sy += dy;
      clampNow();
      var moved = (cam.sx !== bx ? 1 : 0) | (cam.sy !== by ? 2 : 0);
      if (moved) invalidate(F.CAM);
      return moved;
    }
    // In place: a pinch frame allocates nothing (§14.3 rule 4).
    function zoomCore(f, fx) {
      var ppd = cam.ppd, sx = cam.sx;
      SC().zoomAt(cam, f, fx === undefined ? size.bodyW / 2 : fx, cam);
      clampNow();
      if (cam.ppd !== ppd || cam.sx !== sx) invalidate(F.CAM | F.GEOM | F.WIN);
      return cam.ppd !== ppd;
    }
    function zoomAt(f, fx) {
      anim.on = false;
      return zoomCore(f, fx);
    }
    /*
     * The +/- buttons (§11.4): multiply by f, anchored on today when it is
     * in view, else the view centre, animated over `ms` in log(ppd) (0 is
     * instant, for reduced motion). Taps during the animation compound.
     */
    var anim = { on: false, from: 0, to: 0, x: 0, t0: 0, ms: 0 };
    var perf = opts.perf || function () { return win.performance && win.performance.now ? win.performance.now() : Date.now(); };
    function anchorX() {
      var tx = SC().xOf(cam, today + 0.5);
      return tx >= 0 && tx <= size.bodyW ? tx : size.bodyW / 2;
    }
    function zoomBy(f, ms) {
      var target = SC().clampPpd((anim.on ? anim.to : cam.ppd) * f);
      var x = anim.on ? anim.x : anchorX();
      if (!(ms > 0) || suspended) { anim.on = false; zoomCore(target / cam.ppd, x); if (opts.onSettle) opts.onSettle(); return; }
      anim.on = true; anim.from = cam.ppd; anim.to = target; anim.x = x; anim.t0 = perf(); anim.ms = ms;
      invalidate(F.CAM);
    }
    function stepAnim() {
      var p = Math.min(1, (perf() - anim.t0) / anim.ms);
      var e = 1 - (1 - p) * (1 - p) * (1 - p);
      var lf = Math.log(anim.from), ppd = p >= 1 ? anim.to : Math.exp(lf + (Math.log(anim.to) - lf) * e);
      if (p >= 1) anim.on = false;
      zoomCore(ppd / cam.ppd, anim.x);
      if (anim.on) invalidate(F.CAM);
      else if (opts.onSettle) opts.onSettle();
    }
    // Put `day` at viewport x `at` (default the left third).
    function showDay(day, at) {
      anim.on = false;
      var x = typeof at === 'number' ? at : size.bodyW / 3;
      setCam({ sx: (day - cam.epoch) * cam.ppd - x, sy: cam.sy, ppd: cam.ppd, epoch: cam.epoch });
      clampNow();
      invalidate(F.CAM);
    }
    function setPpd(ppd, ax) {
      var f = SC().clampPpd(ppd) / cam.ppd;
      zoomAt(f, ax);
    }
    // D/W/M: anchored on today when visible, else the view centre (§11.4).
    function setPreset(name) {
      var p = SC().PRESETS[name];
      if (!p) return;
      setPpd(p, anchorX());
    }
    // A header tap (§13.2): the bottom-tier unit under x goes to the left third.
    function jumpToUnit(x) {
      if (!size.ok) return null;
      var tier = SC().tierFor(cam.ppd);
      var start = SC().unitStart(tier.unit, SC().dayAt(cam, x), I.weekStart(data.settings));
      showDay(start);
      return start;
    }
    function fitAll() {
      anim.on = false;
      if (!size.ok || !data.chart) { initial = { fit: true }; return; }
      var r = GT.model.range(data.chart);
      var lo = r ? r.min : today - 7, hi = r ? r.max : today + 7;
      var f = SC().fitRange(lo, hi, size.bodyW, cam.epoch);
      setCam({ sx: f.sx, sy: 0, ppd: f.ppd, epoch: cam.epoch });
      clampNow();
      invalidate(F.CAM | F.GEOM | F.WIN);
    }
    /*
     * home(spec): the camera to open with, applied once the view has a
     * size. {fit: true} | {ppd, day, sy} (day = the left edge day).
     */
    function home(spec) {
      initial = spec || { fit: true };
      if (size.ok && data.chart) applyInitial();
    }
    function applyInitial() {
      var s = initial;
      initial = null;
      if (!s) return;
      if (s.fit) fitAll();
      else {
        var ppd = SC().clampPpd(s.ppd);
        var day = typeof s.day === 'number' ? s.day : today - 7;
        setCam({ sx: (day - cam.epoch) * ppd, sy: s.sy || 0, ppd: ppd, epoch: cam.epoch });
        clampNow();
        invalidate(F.CAM | F.GEOM | F.WIN);
      }
      // "Open in <chart>" scrolls to the row and flashes it (§10.3).
      if (s.focus && scrollToTask(s.focus)) flash(s.focus);
    }
    function scrollToTask(id) {
      var b = data.built;
      if (!b || !Object.prototype.hasOwnProperty.call(b.index, id)) return false;
      var row = b.rows[b.index[id]];
      var sy = cam.sy;
      if (row.y < sy || row.y + row.h > sy + size.bodyH) sy = Math.max(0, row.y - size.bodyH / 3);
      setCam({ sx: cam.sx, sy: sy, ppd: cam.ppd, epoch: cam.epoch });
      var t = row.task;
      if (t && typeof t.start === 'number') {
        var x = SC().xOf(cam, t.start);
        if (x < 0 || x > size.bodyW * 0.8) cam.sx = (t.start - cam.epoch) * cam.ppd - size.bodyW / 3;
      }
      clampNow();
      invalidate(F.CAM);
      return true;
    }
    // flash(id | [ids], ms): the rows glow once (M7: every row just added).
    function flash(ids, ms) {
      ms = ms || 2200;
      flashIds = Object.create(null);
      (Array.isArray(ids) ? ids : [ids]).forEach(function (x) { if (x) flashIds[x] = 1; });
      flashUntil = now() + ms;
      invalidate(F.WIN);
      setTimer(function () { invalidate(F.WIN); }, ms + 20);
    }

    /* ---- size ---- */
    function setSize(w, h) {
      w = Math.floor(w); h = Math.floor(h);
      if (w === size.w && h === size.h && size.ok) return;
      // A height-only change is the keyboard (§14.2): new grid height,
      // same rows and camera x, unless it crosses the landscape rule.
      if (size.ok && w === size.w) {
        var mh = R.metrics(w, h, data.density, data.nameW);
        if (mh.landscape === size.m.landscape && mh.tablet === size.m.tablet) {
          size.h = h;
          size.bodyH = Math.max(0, h - size.m.hdrH);
          size.ok = size.bodyH > 0;
          clampNow();
          invalidate(F.SIZE | F.CAM);
          return;
        }
      }
      // A running +/- animation lands on its target first, in the old coordinates.
      if (anim.on && size.ok) { anim.on = false; zoomCore(anim.to / cam.ppd, anim.x); }
      var oldBodyW = size.bodyW, leftThirdDay = size.ok ? SC().dayAt(cam, size.bodyW / 3) : null;
      size.w = w; size.h = h;
      var m = R.metrics(w, h, data.density, data.nameW);
      size.m = m;
      size.bodyW = Math.max(0, w - m.nameW);
      size.bodyH = Math.max(0, h - m.hdrH);
      size.ok = size.bodyW > 0 && size.bodyH > 0;
      if (data.chart) rebuild();
      // A width change (rotation) keeps the date at the left third (§14.2).
      if (leftThirdDay !== null && oldBodyW !== size.bodyW) {
        setCam({ sx: (leftThirdDay - cam.epoch) * cam.ppd - size.bodyW / 3, sy: cam.sy, ppd: cam.ppd, epoch: cam.epoch });
        clampNow();
      }
      invalidate(ALL);
    }
    var rootMemo = {};
    function applySize() {
      var m = size.m;
      var dens = LY().dens(data.density, m.rowH);
      wVar(root, rootMemo, 'nw', '--name-w', m.nameW + 'px');
      // Also on <html>, for fixed controls outside #gantt (the landscape
      // save pill sits right of the name column; M9 review round 1).
      if (root.ownerDocument) wVar(root.ownerDocument.documentElement, rootMemo, 'gnw', '--g-name-w', m.nameW + 'px');
      wVar(root, rootMemo, 'hh', '--hdr-h', m.hdrH + 'px');
      wVar(root, rootMemo, 'rh', '--row-h', dens.row + 'px');
      wVar(root, rootMemo, 'bh', '--bar-h', dens.bar + 'px');
      if (rootMemo.narrow !== m.narrow) { rootMemo.narrow = m.narrow; root.classList.toggle('narrow', m.narrow); counters.domWrites++; }
      if (rootMemo.mini !== m.mini) {
        rootMemo.mini = m.mini; root.classList.toggle('mini', m.mini); counters.domWrites++;
        // The corner toggle names what it will do; data-i18n-label keeps it right across a locale switch.
        var tog = root.querySelector ? root.querySelector('.g-ntog') : null;
        if (tog) {
          var lab = m.mini ? 'Expand task names' : 'Collapse task names';
          tog.setAttribute('data-i18n-label', lab);
          tog.setAttribute('aria-label', I.text(lab));
          tog.setAttribute('aria-expanded', m.mini ? 'false' : 'true');
        }
      }
      sizeCanvas(els.hdr, hctx, size.bodyW, m.hdrH, 'hdrDpr');
      sizeCanvas(els.grid, gctx, size.bodyW, size.bodyH, 'gridDpr');
    }
    var cvMemo = { hdr: {}, grid: {} };
    function sizeCanvas(cv, ctx, cssW, cssH, key) {
      var d = R.capDpr(cssW, cssH, dprOf());
      var bw = Math.max(0, Math.floor(cssW * d)), bh = Math.max(0, Math.floor(cssH * d));
      var memo = cv === els.hdr ? cvMemo.hdr : cvMemo.grid;
      if (cv.width !== bw) { cv.width = bw; counters.domWrites++; }
      if (cv.height !== bh) { cv.height = bh; counters.domWrites++; }
      wStyle(cv, memo, 'w', 'width', cssW + 'px');
      wStyle(cv, memo, 'h', 'height', cssH + 'px');
      ctx.setTransform(d, 0, 0, d, 0, 0);
      size[key] = d;
    }

    /* ---- the rendered window ---- */
    var visBuf = { first: 0, last: -1 };
    function visibleRows() {
      return LY().visibleRange(data.built.rows, cam.sy, cam.sy + size.bodyH, visBuf);
    }
    function inWindow(vis) {
      if (!win0) return false;
      if (cam.sx < win0.x0 || cam.sx + size.bodyW > win0.x1) return false;
      if (data.built.rows.length && (vis.first < win0.r0 || vis.last > win0.r1)) return false;
      return true;
    }
    function syncWindow(vis) {
      counters.syncWindow++;
      var rows = data.built.rows, n = rows.length, dens = data.built.dens;
      var mx = R.WIN_X * size.bodyW;
      win0 = {
        x0: cam.sx - mx, x1: cam.sx + size.bodyW + mx,
        r0: Math.max(0, vis.first - R.WIN_ROWS), r1: Math.min(n - 1, vis.last + R.WIN_ROWS)
      };
      var kb = 0, kn = 0, kg = 0;
      var flashing = flashIds !== null && now() < flashUntil;
      if (!flashing) flashIds = null;
      var reo = pv && pv.kind === 'reorder' ? pv : null;
      // The roving row (M9): the owner's row when it is rendered, else the
      // first rendered row, so Tab always reaches the name column.
      var ri = roveIndex();
      var tabAt = ri >= win0.r0 && ri <= win0.r1 ? ri : win0.r0;
      function one(i) {
        var row = rows[i], off = rowOff(i);
        if (row.kind === 'group') {
          var gp = take(groupPool, makeGroup, kg);
          if (gp) { kg++; paintGroup(gp, row, off, i === tabAt); }
          return;
        }
        var np = take(namePool, makeName, kn);
        if (np) { kn++; paintName(np, row, flashing, off, i === tabAt); }
        var task = taskFor(row.task);
        var g = LY().barGeom(task, row, cam, dens, scratch), ghost = false;
        // An unscheduled task: a dashed 5-day ghost bar at today (§12.6).
        if (!g) { g = LY().ghostGeom(row, cam, dens, today, scratch); ghost = true; }
        // Outside labels reach right of a narrow bar; keep those bars a
        // little longer. The dragged bar is always kept.
        var reach = g.w < LY().LABEL_INSIDE_MIN || g.ms ? 240 : 0;
        if ((g.x + g.w + reach < win0.x0 || g.x > win0.x1) && !(pv && pv.id === row.id)) return;
        var bp = take(barPool, makeBar, kb);
        if (bp) { kb++; paintBar(bp, row, g, flashing, off, ghost); }
      }
      for (var i = win0.r0; i <= win0.r1; i++) one(i);
      // A row dragged (or autoscrolled) out of the window stays painted.
      if (reo && (reo.from < win0.r0 || reo.from > win0.r1) && reo.from < n) one(reo.from);
      hideFrom(barPool, kb);
      hideFrom(namePool, kn);
      hideFrom(groupPool, kg);
    }
    // A reorder preview: the dragged row follows the pointer, rows between
    // it and the target shift by its height (§13.3).
    function rowOff(i) {
      if (!pv || pv.kind !== 'reorder') return 0;
      if (i === pv.from) return pv.dy;
      if (i >= pv.lo && i <= pv.hi) return pv.dir * pv.hd;
      return 0;
    }
    // The task as the preview shows it (move and resize), else itself.
    function taskFor(t) {
      if (!pv || pv.id !== t.id || (pv.kind !== 'move' && pv.kind !== 'resize')) return t;
      pvTask.id = t.id; pvTask.start = pv.start; pvTask.end = pv.end; pvTask.milestone = t.milestone;
      return pvTask;
    }
    function dragCls(id) {
      if (!pv) return sel === id ? ' sel' : '';
      if (pv.id === id) return ' sel lift';
      return (sel === id ? ' sel' : '') + (pv.kind === 'reorder' ? ' g-shift' : '');
    }
    // Label widths, measured once per text (M4 review follow-up): a title
    // that does not fit inside its bar goes outside, like a narrow bar's.
    var measureCache = new Map();
    // Chips are 650 11px, titles 600 12.5px: each font has its own entries.
    var TITLE_FONT = '600 12.5px ', CHIP_FONT = '650 11px ';
    function textW(text, chip) {
      var key = (chip ? 'c|' : 't|') + text;
      var w = R.lruGet(measureCache, key);
      if (w !== undefined) return w;
      if (!gctx || !gctx.measureText) return 0;
      gctx.font = (chip ? CHIP_FONT : TITLE_FONT) + FONT;   // a canvas resize resets the font
      w = gctx.measureText(text).width;
      R.lruPut(measureCache, key, w, R.LRU_CAP);
      return w;
    }
    // pad: the label's extra padding (the segments backing, a selected bar's handles).
    function fits(text, chip, w, pad) {
      return textW(text) + R.LABEL_PAD + (pad || 0) + (chip ? textW(chip, true) + R.CHIP_GAP : 0) <= w;
    }
    /*
     * Where a bar's label goes (M4 follow-up, M8 review): inside when title
     * and chip fit; else inside without the chip when the title fits; else
     * outside when the bar is under 56 px or the slot right of it is inside
     * the rendered window; else inside with an ellipsis (an edge bar keeps
     * its name).  -> 'in' | 'in-nochip' | 'out' | 'clip'
     */
    function labelPlace(label, chip, g, pad, ghost) {
      if (g.w < LY().LABEL_INSIDE_MIN) return 'out';
      if (ghost) return 'clip';
      if (chip && fits(label, chip, g.w, pad)) return 'in';
      if (fits(label, '', g.w, pad)) return chip ? 'in-nochip' : 'in';
      var right = g.x + g.w + R.OUT_GAP + textW(label) + R.LABEL_PAD;
      return win0 && right <= win0.x1 ? 'out' : 'clip';
    }
    function paintBar(p, row, g, flashing, off, ghost) {
      var t = row.task, inf = data.info[t.id], m = p.m;
      if (p.id === null) wStyle(p.el, m, 'disp', 'display', '');
      p.id = t.id;
      // A ghost's hint is short, so a 5-day ghost reads it whole at Week zoom.
      var label = ghost ? (data.editable ? '+ ' + I.text('Schedule') : I.text('Unscheduled')) : inf.label;
      // The completion style (§12.4): segments fall back to fill when the
      // cells do not fit; milestones, ghosts, missing and loading bars are fill.
      var mode = 'fill';
      if (!g.ms && !ghost && !inf.missing && !inf.loading) {
        if (data.style === 'segments' && inf.seg && LY().segFits(inf.seg.n, g.w)) mode = 'segments';
        else if (data.style === 'dots') mode = 'dots';
      }
      var chipOn = !ghost && !g.ms && g.w >= LY().CHIP_MIN && !!inf.chip;
      var pad = (mode === 'segments' || liteOn ? R.BACKING_PAD : 0) + (sel === t.id ? R.SEL_PAD : 0);
      var place = g.ms ? 'in' : labelPlace(label, chipOn ? inf.chip : '', g, pad, ghost);
      var narrow = place === 'out';
      if (place === 'in-nochip') chipOn = false;
      var cls = 'g-bar c-' + inf.hue + ' pm-' + mode + ' cls-' + inf.cls + (g.ms ? ' ms' : '') + (narrow ? ' narrow' : '') +
        (!chipOn ? ' nochip' : '') + (inf.missing ? ' missing' : '') + (ghost ? ' ghost' : '') +
        (inf.loading && !ghost ? (data.unknown ? ' unknown' : ' loading') : '') +
        (mode === 'dots' && g.h < LY().DOTS_INSIDE_MIN_H ? ' dots-under' : '') +
        (flashing && flashIds[t.id] === 1 ? ' flash' : '') + dragCls(t.id);
      wClass(p.el, m, cls);
      wAttr(p.el, m, 'id', 'data-id', t.id);
      wAttr(p.el, m, 'aria', 'aria-label', ghost ? inf.title + ', ' + I.text(data.editable ? 'Tap to schedule' : 'Unscheduled') : inf.aria);
      wAttr(p.el, m, 'tab', 'tabindex', sel === t.id ? '0' : '-1');
      wStyle(p.el, m, 'tf', 'transform', 'translate3d(' + g.x + 'px,' + (g.y + (off || 0)) + 'px,0)');
      wStyle(p.el, m, 'w', 'width', g.w + 'px');
      if (g.ms) wStyle(p.el, m, 'h', 'height', g.h + 'px'); else wStyle(p.el, m, 'h', 'height', '');
      wStyle(p.fill, p.fm, 'tf', 'transform', 'scaleX(' + (ghost ? 0 : inf.ratio) + ')');
      // Dots mode puts the whole label in --h-ink (§12.4: --p is 1).
      wVar(p.el, m, 'p', '--p', mode === 'dots' ? '1' : String(inf.ratio));
      if (mode === 'segments') paintSeg(p, inf.seg);
      if (mode === 'dots') paintDots(p, inf.dots);
      wText(p.t, m, 't', label);
      wText(p.chip, m, 'c', ghost ? '' : inf.chip);
      wText(p.t2, m, 't2', label);
      wText(p.chip2, m, 'c2', ghost ? '' : inf.chip);
    }
    // One gradient and one mask per bits string, written only when it changes.
    function paintSeg(p, sg) {
      var sm = p.sm;
      if (sm.seg === sg) return;
      sm.seg = sg;
      p.seg.style.backgroundImage = sg.image;
      p.seg.style.webkitMaskImage = sg.mask;
      p.seg.style.maskImage = sg.mask;
      p.seg.setAttribute('data-cells', String(sg.n));
      p.seg.classList.toggle('late', sg.late);
      counters.domWrites += 4;
    }
    // One element per bar: the dots are background layers (layout.dotsStyle,
    // shared per list string), "+n" is its text (M8 review: no span per dot).
    var dotsCache = new Map();
    function paintDots(p, dt) {
      var sm = p.sm, list = dt ? dt.list : '', key = list + '+' + (dt ? dt.more : 0);
      if (sm.dots === key) return;
      sm.dots = key;
      var ds = dotsCache.get(list);
      if (!ds) { ds = LY().dotsStyle(list); R.lruPut(dotsCache, list, ds, 200); }
      p.dots.style.backgroundImage = ds.image;
      p.dots.style.backgroundPosition = ds.pos;
      p.dots.style.paddingLeft = ds.width + 'px';
      p.dots.setAttribute('data-dots', list);
      p.dots.textContent = dt && dt.more > 0 ? '+' + dt.more : '';
      counters.domWrites += 5;
    }
    function paintName(p, row, flashing, off, tab) {
      var t = row.task, inf = data.info[t.id], m = p.m;
      if (p.id === null) wStyle(p.el, m, 'disp', 'display', '');
      p.id = t.id;
      wClass(p.el, m, 'g-name c-' + inf.hue + (inf.missing ? ' missing' : '') + (row.h < 40 ? ' short' : '') +
        (flashing && flashIds[t.id] === 1 ? ' flash' : '') + dragCls(t.id));
      wAttr(p.el, m, 'id', 'data-id', t.id);
      wAttr(p.el, m, 'aria', 'aria-label', inf.aria);
      wAttr(p.el, m, 'tab', 'tabindex', tab ? '0' : '-1');
      wAttr(p.el, m, 'cur', 'aria-current', sel === t.id ? 'true' : 'false');
      wVar(p.el, m, 'p', '--p', String(inf.ratio));
      wStyle(p.el, m, 'tf', 'transform', 'translate3d(0,' + (row.y + (off || 0)) + 'px,0)');
      wStyle(p.el, m, 'h', 'height', row.h + 'px');
      wText(p.t, m, 't', inf.title);
      wText(p.meta, m, 'meta', inf.meta);
    }
    function paintGroup(p, row, off, tab) {
      var m = p.m, g = row.group;
      var gt = row.unscheduled ? I.text('Unscheduled') : (g.title || I.text('Untitled'));
      wAttr(p.el, m, 'tab', 'tabindex', tab ? '0' : '-1');
      wAttr(p.el, m, 'aria', 'aria-label', I.fmt('{title}, {n} task(s)', { title: gt, n: row.n }));
      if (p.id === null) wStyle(p.el, m, 'disp', 'display', '');
      p.id = row.id;
      var hue = g ? LY().colorFor(null, null, row.gi, { colorBy: 'group' }, g) : 'slate';
      wClass(p.el, m, 'g-grp c-' + hue + (row.h >= R.GRP_TALL ? ' tall' : '') + (row.collapsed ? ' collapsed' : '') + (row.unscheduled ? ' unscheduled' : '') +
        (pv && pv.kind === 'reorder' ? ' g-shift' : ''));
      wAttr(p.el, m, 'id', 'data-group', row.id);
      wAttr(p.el, m, 'exp', 'aria-expanded', row.collapsed ? 'false' : 'true');
      wStyle(p.el, m, 'tf', 'transform', 'translate3d(0,' + (row.y + (off || 0)) + 'px,0)');
      wStyle(p.el, m, 'h', 'height', row.h + 'px');
      wText(p.t, m, 't', gt);
      wText(p.n, m, 'n', String(row.n));
    }

    /* ---- selection overlay: handles, ghost, snap guides, date bubble (M6) ---- */
    var ov = null;
    function makeOverlay() {
      ov = { m: {} };
      ov.ghost = node('div', 'g-ghost', els.overlay);
      ov.gs = node('div', 'g-guide', els.overlay);
      ov.ge = node('div', 'g-guide', els.overlay);
      ov.bubble = node('div', 'g-bubble', els.overlay);
      ov.bubble.setAttribute('aria-hidden', 'true');
      // The text, and the delta ("+2d") in accent (§13.3).
      ov.bt = node('span', 'g-bt', ov.bubble);
      ov.bd = node('span', 'g-bd', ov.bubble);
      ov.hs = node('div', 'g-handle s', els.handles);
      ov.he = node('div', 'g-handle e', els.handles);
      ov.hs.setAttribute('data-edge', 's');
      ov.he.setAttribute('data-edge', 'e');
      ov.hs.appendChild(doc.createElement('span'));
      ov.he.appendChild(doc.createElement('span'));
      [ov.ghost, ov.gs, ov.ge, ov.bubble, ov.hs, ov.he].forEach(function (e) { e.style.display = 'none'; });
      ov.ms = {}; ov.mg = {}; ov.mb = {}; ov.mhs = {}; ov.mhe = {}; ov.mge = {};
    }
    function show(el, memo, on) { wStyle(el, memo, 'disp', 'display', on ? '' : 'none'); }
    function box(el, memo, x, y, w, h) {
      wStyle(el, memo, 'tf', 'transform', 'translate3d(' + Math.round(x) + 'px,' + Math.round(y) + 'px,0)');
      if (w !== null) wStyle(el, memo, 'w', 'width', Math.round(w) + 'px');
      if (h !== null) wStyle(el, memo, 'h', 'height', Math.round(h) + 'px');
    }
    var geomBuf = {}, geom0 = {};
    function paintOverlay() {
      if (!els.overlay || !els.handles) return;
      if (!ov) { if (!sel && !pv) return; makeOverlay(); }
      var b = data.built, row = null, id = pv ? pv.id : sel;
      if (id && b && Object.prototype.hasOwnProperty.call(b.index, id)) row = b.rows[b.index[id]];
      var t = row ? row.task : null;
      var dated = !!pv && (pv.kind === 'move' || pv.kind === 'resize') && !!t;
      // Ghost at the original place, guides at the new start and end.
      var g0 = dated ? LY().barGeom(t, row, cam, b.dens, geom0) : null;
      var g1 = dated ? LY().barGeom(taskFor(t), row, cam, b.dens, geomBuf) : null;
      show(ov.ghost, ov.mg, !!g0);
      if (g0) box(ov.ghost, ov.mg, g0.x, g0.y, g0.w, g0.h);
      show(ov.gs, ov.ms, !!g1);
      show(ov.ge, ov.mge, !!g1 && !g1.ms);
      if (g1) {
        var gx0 = (pv.start - cam.epoch) * cam.ppd;
        box(ov.gs, ov.ms, gx0, cam.sy, null, size.bodyH);
        if (!g1.ms) box(ov.ge, ov.mge, ((pv.end === null ? pv.start : pv.end) + 1 - cam.epoch) * cam.ppd - 1, cam.sy, null, size.bodyH);
      }
      // The date bubble, 56 px above the pointer, kept inside the view.
      var bub = !!pv && typeof pv.bubble === 'string' && pv.bubble !== '' && typeof pv.bx === 'number';
      show(ov.bubble, ov.mb, bub);
      if (bub) {
        wText(ov.bt, ov.mb, 't', pv.bubble);
        wText(ov.bd, ov.mb, 'd', typeof pv.delta === 'string' ? pv.delta : '');
        var bx = Math.max(90, Math.min(size.bodyW - 90, pv.bx)) + cam.sx;
        var by = Math.max(40, pv.by - 56) + cam.sy;
        box(ov.bubble, ov.mb, bx, by, null, null);
      }
      // Handles: on the selected bar when editable, following a resize.
      var hg = null;
      if (selHandles && sel && row && t && sel === t.id && (!pv || pv.kind === 'resize' || pv.kind === 'lift') && !t.milestone && typeof t.start === 'number') {
        var gg = LY().barGeom(taskFor(t), row, cam, b.dens, geomBuf);
        hg = gg ? LY().handleRects(gg) : null;
      }
      show(ov.hs, ov.mhs, !!hg);
      show(ov.he, ov.mhe, !!hg);
      if (hg) {
        wAttr(ov.hs, ov.mhs, 'id', 'data-id', sel);
        wAttr(ov.he, ov.mhe, 'id', 'data-id', sel);
        wClass(ov.hs, ov.mhs, 'g-handle s' + (hg.outside ? ' out' : ''));
        wClass(ov.he, ov.mhe, 'g-handle e' + (hg.outside ? ' out' : ''));
        box(ov.hs, ov.mhs, hg.s.x, hg.s.y, null, null);
        box(ov.he, ov.mhe, hg.e.x, hg.e.y, null, null);
      }
    }
    // The dated span of a move or resize preview, for the canvas bands.
    var spanBuf = { a: 0, b: 0 };
    function dragSpan() {
      if (!pv || (pv.kind !== 'move' && pv.kind !== 'resize') || typeof pv.start !== 'number') return null;
      spanBuf.a = pv.start;
      spanBuf.b = (pv.end === null || pv.end === undefined ? pv.start : pv.end) + 1;
      return spanBuf;
    }
    // The spanned range of a drag as a band on a canvas (§13.3).
    function dragBand(ctx, y, h) {
      var sp = dragSpan();
      if (!sp) return;
      var ax = SC().xOf(cam, sp.a), bx = SC().xOf(cam, sp.b);
      ctx.fillStyle = tok('--g-drag-band');
      ctx.fillRect(ax, y, bx - ax, h);
    }

    /* ---- canvases ---- */
    var FONT = '-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, Roboto, "Noto Sans", "PingFang SC", "Hiragino Sans GB", "Noto Sans CJK SC", "Microsoft YaHei", sans-serif';
    function tok(k) { return tokens[k]; }
    function label(unit, day, ctx) {
      var key = day * 16 + KINDS.indexOf(unit);           // numeric: no string per label
      var hit = R.lruGet(lru, key);
      if (hit) return hit;
      var text;
      var D = I.date;
      if (unit === 'month-year') text = D.monthYear(day);
      else if (unit === 'year') text = String(new Date(day * 864e5).getUTCFullYear());
      else if (unit === 'day') text = D.dayNum(day);
      else if (unit === 'day-wd') text = D.weekdayNarrow(day) + ' ' + D.dayNum(day);
      else if (unit === 'week') text = data.weekNumbers ? D.week(DT().weekNumber(day, I.weekStart(data.settings))) : D.short(day);
      else if (unit === 'month') text = D.monthShort(day);
      else if (unit === 'quarter') text = D.quarter(day);
      else if (unit === 'today') text = D.short(day);
      else text = D.short(day);
      hit = { text: text, w: ctx.measureText(text).width };
      R.lruPut(lru, key, hit, R.LRU_CAP);
      return hit;
    }
    function vline(ctx, x, y0, y1) {
      var px = Math.round(x) + 0.5;
      ctx.moveTo(px, y0);
      ctx.lineTo(px, y1);
    }
    function drawGrid(vis) {
      counters.canvasDraws++;
      var ctx = gctx, W = size.bodyW, H = size.bodyH, rows = data.built.rows;
      ctx.fillStyle = tok('--g-bg');
      ctx.fillRect(0, 0, W, H);
      // Row stripes and group bands.
      ctx.fillStyle = tok('--g-stripe');
      for (var i = vis.first; i <= vis.last; i++) {
        var r = rows[i];
        if (r.kind === 'group' || i % 2 === 1) {
          var y = r.y - cam.sy;
          ctx.fillRect(0, y, W, r.h);
          if (r.kind === 'group') ctx.fillRect(0, y, W, r.h);   // group rows: stripe drawn twice, a slightly stronger band
        }
      }
      var d0 = Math.floor(SC().dayAt(cam, 0)), d1 = Math.ceil(SC().dayAt(cam, W));
      // Weekend bands (ppd >= 6).
      if (cam.ppd >= 6 && data.showWeekends) {
        var we = weekend || (weekend = I.weekendDays());
        ctx.fillStyle = tok('--g-weekend');
        for (var d = d0; d <= d1; d++) {
          if (we.indexOf(DT().dow(d)) >= 0) ctx.fillRect(SC().xOf(cam, d), 0, cam.ppd, H);
        }
      }
      dragBand(ctx, 0, H);
      var tier = SC().tierFor(cam.ppd), ws = I.weekStart(data.settings);
      ctx.lineWidth = 1;
      if (tier.minor) {
        ctx.strokeStyle = tok('--g-line');
        ctx.beginPath();
        var nm = SC().ticks(tier.minor, d0, d1 + 1, ws, tickBuf);
        for (var a = 0; a < nm; a++) vline(ctx, SC().xOf(cam, tickBuf[a]), 0, H);
        ctx.stroke();
      }
      ctx.strokeStyle = tok('--g-line-strong');
      ctx.beginPath();
      var nM = SC().ticks(tier.major, d0, d1 + 1, ws, tickBuf);
      for (var b = 0; b < nM; b++) vline(ctx, SC().xOf(cam, tickBuf[b]), 0, H);
      ctx.stroke();
      // Today line, 2 px.
      var tx = SC().xOf(cam, today + DT().dayFraction(now()));
      if (tx >= -2 && tx <= W + 2) {
        ctx.fillStyle = tok('--today');
        ctx.fillRect(Math.round(tx) - 1, 0, 2, H);
      }
    }
    function drawHeader() {
      counters.canvasDraws++;
      var ctx = hctx, W = size.bodyW, t0 = size.m.tiers[0], t1 = size.m.tiers[1], H = t0 + t1;
      var tier = SC().tierFor(cam.ppd), ws = I.weekStart(data.settings);
      if (tier.name !== lruName || tier.unit !== lruUnit || (cam.ppd >= 36) !== lruWd || I.language !== lruLang) {
        lru.clear();
        lruName = tier.name; lruUnit = tier.unit; lruWd = cam.ppd >= 36; lruLang = I.language;
      }
      ctx.fillStyle = tok('--g-bg');
      ctx.fillRect(0, 0, W, H);
      ctx.fillStyle = tok('--g-header-bg');
      ctx.fillRect(0, 0, W, H);
      dragBand(ctx, 0, H);
      var d0 = Math.floor(SC().dayAt(cam, 0)), d1 = Math.ceil(SC().dayAt(cam, W));
      ctx.textBaseline = 'middle';
      // Top tier: month-year or year, sticky inside its span.
      ctx.font = '700 11.5px ' + FONT;
      var topUnit = tier.top === 'month' ? 'month' : 'year';
      var nT = SC().ticks(topUnit, d0, d1 + 1, ws, tickBuf);
      ctx.strokeStyle = tok('--g-line-strong');
      ctx.beginPath();
      for (var i = 0; i < nT; i++) {
        var s = tickBuf[i], e = SC().unitNext(topUnit, s);
        var x0 = SC().xOf(cam, s), x1 = SC().xOf(cam, e);
        if (i > 0 || x0 >= 0) vline(ctx, x0, 0, H);
        var lb = label(topUnit === 'month' ? 'month-year' : 'year', s, ctx);
        var lx = Math.max(x0, 0) + 8;
        if (lx + lb.w > x1 - 6) lx = x1 - 6 - lb.w;
        // A label that no longer fits the visible part of its span is dropped, not clipped.
        if (lx < 2 || lx + lb.w > W - 2) continue;
        ctx.fillStyle = tok('--text');
        ctx.fillText(lb.text, lx, t0 / 2 + 1);
        if (trace) trace.push({ tier: 'top', text: lb.text, x: lx, w: lb.w, W: W });
      }
      ctx.stroke();
      // Where the today pill goes, so no unit label is drawn under it.
      var tx = SC().xOf(cam, today + 0.5), pill = null;
      if (tx >= -40 && tx <= W + 40) {
        ctx.font = '700 10.5px ' + FONT;
        var tl = label('today', today, ctx);
        var pw = tl.w + 12, ph = Math.min(18, t1 - 4);
        pill = pillBuf;
        pill.x = Math.max(2, Math.min(W - pw - 2, tx - pw / 2)); pill.y = t0 + (t1 - ph) / 2; pill.w = pw; pill.h = ph; pill.text = tl.text;
      }
      // Bottom tier: the unit labels.
      ctx.font = '500 11px ' + FONT;
      var unit = tier.unit;
      var nB = SC().ticks(unit, d0, d1 + 1, ws, tickBuf);
      ctx.strokeStyle = tok('--g-line');
      ctx.beginPath();
      var kind = unit === 'day' ? (cam.ppd >= 36 ? 'day-wd' : 'day') : unit;
      for (var j = 0; j < nB; j++) {
        var bs = tickBuf[j], be = SC().unitNext(unit, bs);
        var bx0 = SC().xOf(cam, bs), bx1 = SC().xOf(cam, be);
        vline(ctx, bx0, t0, H);
        var bl = label(kind, bs, ctx);
        var cx = bx1 - bx0 >= bl.w + 8 && unit !== 'week' ? (bx0 + bx1) / 2 - bl.w / 2 : bx0 + 4;
        if (cx < 2) {
          if (2 + bl.w > bx1 - 2) continue;
          cx = 2;
        }
        if (cx + bl.w > W - 2) continue;              // dropped at the right edge, never clipped
        if (pill && cx < pill.x + pill.w + 3 && cx + bl.w > pill.x - 3) continue;
        ctx.fillStyle = tok('--muted');
        ctx.fillText(bl.text, cx, t0 + t1 / 2);
        if (trace) trace.push({ tier: 'bottom', text: bl.text, x: cx, w: bl.w, W: W });
      }
      ctx.stroke();
      bandLabels(ctx, t0, t1, W);
      // Divider between the header and the grid.
      ctx.fillStyle = tok('--border');
      ctx.fillRect(0, H - 1, W, 1);
      // Today pill in the bottom tier.
      if (pill) {
        ctx.font = '700 10.5px ' + FONT;
        ctx.fillStyle = tok('--today');
        roundRect(ctx, pill.x, pill.y, pill.w, pill.h, pill.h / 2);
        ctx.fill();
        ctx.fillStyle = tok('--today-ink');
        ctx.fillText(pill.text, pill.x + 6, pill.y + pill.h / 2 + 0.5);
      }
    }
    // §13.3: during a move or resize the header bolds the band's end dates,
    // start at the band's left edge and end at its right edge, over the unit
    // labels (a patch of header background under each). A short band that
    // cannot hold both shows the start only.
    function bandLabels(ctx, t0, t1, W) {
      var sp = dragSpan();
      if (!sp) return;
      ctx.font = '700 11px ' + FONT;
      var y = t0 + t1 / 2, ax = SC().xOf(cam, sp.a), bx = SC().xOf(cam, sp.b);
      var sl = label('today', sp.a, ctx), el = label('today', sp.b - 1, ctx);
      var sx = Math.max(2, Math.min(W - 2 - sl.w, ax + 3));
      var ex = Math.max(2, Math.min(W - 2 - el.w, bx - 3 - el.w));
      var both = sp.b - 1 !== sp.a && ex > sx + sl.w + 6;
      function one(text, x, w) {
        ctx.fillStyle = tok('--g-header-bg');
        ctx.fillRect(x - 3, t0 + 2, w + 6, t1 - 4);
        ctx.fillStyle = tok('--text');
        ctx.fillText(text, x, y);
        if (trace) trace.push({ tier: 'band', text: text, x: x, w: w, W: W, bold: true });
      }
      one(sl.text, sx, sl.w);
      if (both) one(el.text, ex, el.w);
    }
    function roundRect(ctx, x, y, w, h, r) {
      ctx.beginPath();
      ctx.moveTo(x + r, y);
      ctx.arcTo(x + w, y, x + w, y + h, r);
      ctx.arcTo(x + w, y + h, x, y + h, r);
      ctx.arcTo(x, y + h, x, y, r);
      ctx.arcTo(x, y, x + w, y, r);
      ctx.closePath();
    }

    /* ---- the frame ---- */
    function frame() {
      pending = null;
      if (suspended) return;
      // Nothing to draw yet (no size, or the chart is still loading): keep
      // every flag, so SIZE, THEME and LOCALE still apply on the first real frame.
      if (!size.ok || !data.chart || !data.built) return;
      if (anim.on) stepAnim();
      var t0 = now();
      var f = dirty;
      dirty = 0;
      counters.frames++;
      if (f & F.SIZE) applySize();
      if (initial) applyInitial();
      if ((f & F.THEME) || !tokens) { tokens = TH.tokens(); }
      if (f & (F.LOCALE | F.THEME)) { lru.clear(); weekend = null; }
      if (f & F.LOCALE) data.info = derive(data.chart, lastSummaries, lastFacts);
      var vis = visibleRows();
      if ((f & (F.WIN | F.GEOM | F.DATA | F.SIZE | F.LOCALE)) || !inWindow(vis)) syncWindow(vis);
      if ((f & (F.SEL | F.WIN | F.GEOM | F.DATA | F.SIZE)) || (pv && (f & F.CAM))) paintOverlay();
      if (layerMemo.bx !== cam.sx || layerMemo.by !== cam.sy) {
        layerMemo.bx = cam.sx; layerMemo.by = cam.sy;
        els.bars.style.transform = 'translate3d(' + (-cam.sx) + 'px,' + (-cam.sy) + 'px,0)';
        counters.domWrites++;
      }
      if (layerMemo.ny !== cam.sy) {
        layerMemo.ny = cam.sy;
        els.namesInner.style.transform = 'translate3d(0,' + (-cam.sy) + 'px,0)';
        counters.domWrites++;
      }
      drawGrid(vis);
      drawHeader();
      var ms = now() - t0;
      counters.lastFrameMs = ms;
      if (ms > counters.maxFrameMs) counters.maxFrameMs = ms;
      // Pan frames (camera and window only): 5 slow ones in a row turn on
      // body.lite for this chart (§11.6).
      if (!(f & ~(F.CAM | F.WIN)) && slowFrames < R.SLOW_FRAMES) {
        slowFrames = ms > R.SLOW_FRAME_MS ? slowFrames + 1 : 0;
        if (slowFrames >= R.SLOW_FRAMES) setLite(true);
      }
    }
    var lastSummaries = null, lastFacts = null, weekend = null, trace = null;
    var setTimer = opts.setTimeout || function (fn, ms) { return win.setTimeout(fn, ms); };
    function flushNow() {
      if (pending !== null) { caf(pending); pending = null; }
      frame();
    }

    /* ---- hit testing (camera math only, no DOM reads) ---- */
    function hitAt(x, y) {
      if (!size.ok || !data.built) return { kind: 'none' };
      var m = size.m;
      if (y < m.hdrH) return x >= m.nameW ? { kind: 'header', day: Math.floor(SC().dayAt(cam, x - m.nameW)) } : { kind: 'corner' };
      var cy = y - m.hdrH + cam.sy;
      var ri = LY().rowAt(data.built.rows, cy), row = ri >= 0 ? data.built.rows[ri] : null;
      var res = { kind: 'grid', rowIndex: ri, day: null, taskId: null, groupId: null };
      if (row && row.kind === 'group') res.groupId = row.id;
      if (row && row.kind === 'task') res.taskId = row.id;
      if (x < m.nameW) {
        res.kind = !row ? 'none' : (row.kind === 'group' ? 'group' : 'name');
        return res;
      }
      var cx = x - m.nameW + cam.sx;
      res.day = Math.floor(SC().dayAt(cam, x - m.nameW));
      if (row && row.kind === 'group') { res.kind = 'group'; return res; }
      if (row && row.kind === 'task') {
        var g = LY().barGeom(row.task, row, cam, data.built.dens, {});
        if (g) {
          var hb = LY().hitBox(g, row);
          if (cx >= hb.x && cx <= hb.x + hb.w) res.kind = 'bar';
        }
      }
      if (res.kind !== 'bar') res.taskId = row && row.kind === 'task' ? row.id : null;
      return res;
    }

    /* ---- lifecycle ---- */
    var todayTimer = null;
    var si = opts.setInterval || function (fn, ms) { return win.setInterval(fn, ms); };
    var ci = opts.clearInterval || function (h) { win.clearInterval(h); };
    function startTimer() {
      if (todayTimer !== null) return;
      todayTimer = si(tick, R.TODAY_MS);
    }
    function tick() {
      var t = DT().today(now());
      if (t !== today) {
        today = t;
        invalidate(F.DATA | F.CAM);
        // Classes (overdue) depend on today: the owner re-runs setData.
        if (opts.onDay) opts.onDay(t);
      }
      else if (SC().tierFor(cam.ppd).name === 'day') invalidate(F.CAM);
    }
    // Hidden: free the canvas backing stores (WebKit keeps them otherwise).
    function suspend() {
      if (suspended) return;
      // A zoom animation ends at its target (§14.3 rule 9).
      if (anim.on) { anim.on = false; zoomCore(anim.to / cam.ppd, anim.x); }
      suspended = true;
      if (pending !== null) { caf(pending); pending = null; }
      if (todayTimer !== null) { ci(todayTimer); todayTimer = null; }
      els.hdr.width = 0; els.hdr.height = 0;
      els.grid.width = 0; els.grid.height = 0;
    }
    function resume() {
      if (!suspended) return;
      suspended = false;
      startTimer();
      invalidate(ALL);
    }
    startTimer();

    /*
     * setSelection(id, {handles}) selects a task (null clears); handles
     * shows the resize handles on it (an editable chart, not a milestone).
     * setPreview(p) shows a drag preview (see pv above) or clears it (null).
     */
    function setSelection(id, o) {
      var h = !!(o && o.handles);
      if ((id || null) === sel && h === selHandles) return;
      sel = id || null;
      selHandles = h;
      invalidate(F.SEL | F.WIN);
    }
    function setPreview(p) {
      pv = p || null;
      invalidate(F.SEL | F.WIN | F.CAM);
    }

    /*
     * M9 roving focus (§15.2): setRove(kind, id) names the name-column row
     * that is the tab stop ('task' or 'group'; null: the selected task, else
     * the first rendered row). focusRow(kind, id) makes it the tab stop,
     * scrolls it into view, renders and focuses its pooled element.
     */
    var rove = { kind: null, id: null };
    function roveIndex() {
      var b = data.built;
      if (!b) return -1;
      var kind = rove.kind, id = rove.id;
      if (!kind && sel) { kind = 'task'; id = sel; }
      if (kind === 'task' && Object.prototype.hasOwnProperty.call(b.index, id)) return b.index[id];
      if (kind === 'group' && Object.prototype.hasOwnProperty.call(b.groups, id)) return b.groups[id];
      return -1;
    }
    function setRove(kind, id) {
      kind = kind === 'task' || kind === 'group' ? kind : null;
      if (rove.kind === kind && rove.id === (kind ? id : null)) return;
      rove.kind = kind;
      rove.id = kind ? id : null;
      invalidate(F.WIN);
    }
    function focusRow(kind, id) {
      var b = data.built;
      if (!b) return false;
      setRove(kind, id);
      var i = roveIndex();
      if (i < 0) return false;
      var row = b.rows[i];
      if (kind === 'task') scrollToTask(id);
      else if (row.y < cam.sy || row.y + row.h > cam.sy + size.bodyH) {
        setCam({ sx: cam.sx, sy: Math.max(0, row.y - size.bodyH / 3), ppd: cam.ppd, epoch: cam.epoch });
        clampNow();
        invalidate(F.CAM);
      }
      flushNow();
      var pool = kind === 'group' ? groupPool : namePool;
      for (var k = 0; k < pool.length; k++) {
        if (pool[k].id === id) {
          try { pool[k].el.focus({ preventScroll: true }); } catch (e) { pool[k].el.focus(); }
          return true;
        }
      }
      return false;
    }

    var view = {
      setData: function (d) { lastSummaries = d.summaries || null; lastFacts = d.facts || null; setData(d); },
      setSelection: setSelection,
      setPreview: setPreview,
      setRove: setRove,
      focusRow: focusRow,
      rove: function () { return { kind: rove.kind, id: rove.id }; },
      selection: function () { return sel; },
      preview: function () { return pv; },
      // Body px of the header's bottom edge and the name column width, for
      // the owner's pointer math (cached sizes, no layout read).
      hdrH: function () { return size.m ? size.m.hdrH : 0; },
      setSize: setSize,
      setCollapsed: setCollapsed,
      setDisplay: setDisplay,
      display: function () { return { density: data.density, showWeekends: data.showWeekends, weekNumbers: data.weekNumbers, nameW: data.nameW }; },
      lite: function () { return !!liteOn; },
      // Test hook: n slow pan frames as if measured (the lite rule).
      slowFrames: function (n) { if (typeof n === 'number') { slowFrames = n; states(); } return slowFrames; },
      textW: textW,
      setCamera: setCamera,
      camera: function () { return { sx: cam.sx, sy: cam.sy, ppd: cam.ppd, epoch: cam.epoch }; },
      panBy: panBy,
      zoomAt: zoomAt,
      setPpd: setPpd,
      setPreset: setPreset,
      fitAll: fitAll,
      home: home,
      showDay: showDay,
      zoomBy: zoomBy,
      animating: function () { return anim.on; },
      jumpToUnit: jumpToUnit,
      goToday: function () { showDay(today); },
      scrollIntoView: scrollToTask,
      flash: flash,
      invalidate: invalidate,
      flushNow: flushNow,
      viewSize: function () { return { w: size.w, h: size.h, bodyW: size.bodyW, bodyH: size.bodyH, metrics: size.m }; },
      hitAt: hitAt,
      suspend: suspend,
      resume: resume,
      today: function () { return today; },
      leftDay: function () { return SC().dayAt(cam, 0); },
      // A layout read the owner made outside a frame (counted, §14.3 rule 1).
      countLayoutRead: function (n) { counters.layoutReads += n || 1; },
      // The name column width without allocating (the gesture move path).
      nameW: function () { return size.m ? size.m.nameW : 0; },
      // Test hooks: the today-timer body, header labels of the next frames, the camera object.
      tick: tick,
      traceLabels: function (on) { var t = trace; trace = on ? [] : null; return t; },
      camRef: function () { return cam; },
      counters: function () { var c = {}; Object.keys(counters).forEach(function (k) { c[k] = counters[k]; }); return c; },
      resetCounters: function () { Object.keys(counters).forEach(function (k) { counters[k] = 0; }); },
      canvases: function () {
        return {
          hdr: { w: els.hdr.width, h: els.hdr.height, dpr: size.hdrDpr },
          grid: { w: els.grid.width, h: els.grid.height, dpr: size.gridDpr }
        };
      },
      debug: function () {
        var live = function (p) { return p.filter(function (x) { return x.id !== null; }).length; };
        return {
          rows: data.built ? data.built.rows.length : 0, window: win0 ? Object.assign({}, win0) : null,
          pools: { bars: barPool.length, names: namePool.length, groups: groupPool.length },
          live: { bars: live(barPool), names: live(namePool), groups: live(groupPool) },
          dirty: dirty, pending: pending !== null, suspended: suspended
        };
      },
      // Geometry of a task's bar in viewport pixels relative to #gantt, from the model.
      barRect: function (id) {
        var b = data.built;
        if (!b || !Object.prototype.hasOwnProperty.call(b.index, id)) return null;
        var row = b.rows[b.index[id]], g = LY().barGeom(row.task, row, cam, b.dens, {}) || LY().ghostGeom(row, cam, b.dens, today, {});
        return { x: g.x - cam.sx + size.m.nameW, y: g.y - cam.sy + size.m.hdrH, w: g.w, h: g.h, ms: g.ms };
      },
      info: function (id) { return data.info[id] || null; },
      rows: function () { return data.built ? data.built.rows : []; }
    };
    return view;
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
