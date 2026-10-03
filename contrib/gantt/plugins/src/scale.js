/*
 * Gantt pixel math (plan §11.2 to §11.4, D8): pixels per day, zoom tiers,
 * tick generation, the camera, snapping and fling. Calendar arithmetic
 * stays in dates.js; this module only turns days into pixels and back.
 *
 * Camera: {sx, sy, ppd, epoch}. Content x of a day is (day - epoch) * ppd;
 * its viewport x is that minus sx. Days may be fractional.
 */
(function (global) {
  'use strict';
  var GT = (global.GT = global.GT || {});
  var SC = (GT.scale = {});

  SC.MIN_PPD = 1.5;
  SC.MAX_PPD = 120;
  // D/W/M control presets (§11.3); quarter is the `scale: quarter` setting.
  SC.PRESETS = { day: 44, week: 16, month: 5, quarter: 2 };
  SC.MIN_LABEL_PX = { day: 22, week: 44, month: 34, quarter: 40 };
  SC.EPOCH_PAD = 60;          // days before the earliest date (§11.2)
  SC.FAB_ROOM = 96;           // px kept below the last row (§11.2)
  SC.FLING_DECAY = 0.94;      // per 60 Hz frame (§13.1)
  SC.FLING_MIN_V = 0.25;      // px/ms: a release slower than this does not fling
  SC.FLING_STOP_V = 0.02;     // px/ms: a fling ends below this (M5 review: no abrupt stop)

  var UNITS = ['day', 'week', 'month', 'quarter', 'year'];
  // Nominal unit lengths in days, for the minimum label width rule.
  var UNIT_DAYS = { day: 1, week: 7, month: 28, quarter: 90, year: 365 };

  SC.clampPpd = function (p) {
    if (typeof p !== 'number' || !isFinite(p)) return SC.PRESETS.week;
    return Math.max(SC.MIN_PPD, Math.min(SC.MAX_PPD, p));
  };

  /*
   * tierFor(ppd) -> {name, top, unit, snap, minor, faint}
   *   name  day | week | month | quarter (§11.3 table)
   *   top   the upper header unit (month or year)
   *   unit  the lower header unit, coarsened until it is MIN_LABEL_PX wide
   *   snap  delta snapping in days
   *   minor grid unit drawn faint (null for none)
   */
  // The last answer is reused for the same ppd, so a pan frame allocates
  // nothing here (§14.3 rule 4). Callers must not mutate the result.
  var lastPpd = null, lastTier = null;
  SC.tierFor = function (ppd) {
    ppd = SC.clampPpd(ppd);
    if (ppd === lastPpd) return lastTier;
    var t;
    if (ppd >= 28) t = { name: 'day', top: 'month', unit: 'day', snap: 1, minor: 'day', major: 'week' };
    else if (ppd >= 9) t = { name: 'week', top: 'month', unit: 'week', snap: 1, minor: ppd >= 14 ? 'day' : null, major: 'week' };
    else if (ppd >= 3) t = { name: 'month', top: 'year', unit: 'month', snap: 7, minor: null, major: 'month' };
    else t = { name: 'quarter', top: 'year', unit: 'quarter', snap: 7, minor: 'month', major: 'quarter' };
    var i = UNITS.indexOf(t.unit);
    while (i < UNITS.length - 1 && UNIT_DAYS[UNITS[i]] * ppd < (SC.MIN_LABEL_PX[UNITS[i]] || 0)) i++;
    t.unit = UNITS[i];
    lastPpd = ppd;
    lastTier = t;
    return t;
  };

  function D() { return GT.dates; }
  function ymd(day) {
    var dt = new Date(day * 864e5);
    return { y: dt.getUTCFullYear(), m: dt.getUTCMonth() };
  }
  function dayOf(y, m) { return Math.round(Date.UTC(y, m, 1) / 864e5); }

  // The start of the unit holding `day` (week starts on ws, 0 = Sunday).
  SC.unitStart = function (unit, day, ws) {
    day = Math.floor(day);
    if (unit === 'day') return day;
    if (unit === 'week') return D().startOfWeek(day, ws);
    var p = ymd(day);
    if (unit === 'month') return dayOf(p.y, p.m);
    if (unit === 'quarter') return dayOf(p.y, p.m - (p.m % 3));
    return dayOf(p.y, 0);
  };
  // The start of the next unit after the one starting at `start`.
  SC.unitNext = function (unit, start) {
    if (unit === 'day') return start + 1;
    if (unit === 'week') return start + 7;
    var p = ymd(start);
    if (unit === 'month') return dayOf(p.y, p.m + 1);
    if (unit === 'quarter') return dayOf(p.y, p.m + 3);
    return dayOf(p.y + 1, 0);
  };

  /*
   * ticks(unit, from, to, ws, out) fills `out` (a Float64Array owned by the
   * caller, so a frame allocates nothing) with the unit starts whose unit
   * overlaps [from, to), starting with the unit that holds `from`. Returns
   * the count written; stops when `out` is full.
   */
  SC.ticks = function (unit, from, to, ws, out) {
    var n = 0, d = SC.unitStart(unit, from, ws);
    while (d < to && n < out.length) {
      out[n++] = d;
      d = SC.unitNext(unit, d);
    }
    return n;
  };

  SC.xOf = function (cam, day) { return (day - cam.epoch) * cam.ppd - cam.sx; };
  SC.dayAt = function (cam, x) { return (x + cam.sx) / cam.ppd + cam.epoch; };
  SC.contentX = function (cam, day) { return (day - cam.epoch) * cam.ppd; };

  // Whole-snap-unit day delta for a pixel delta; symmetric around zero.
  SC.snapDelta = function (dxPx, ppd, snapDays) {
    var s = snapDays > 0 ? snapDays : 1;
    var v = dxPx / ppd / s;
    var r = (v < 0 ? -Math.round(-v) : Math.round(v)) * s;
    return r === 0 ? 0 : r;
  };

  // Zoom by factor f keeping the day under viewport x `fx` in place. Pass
  // `out` (may be `cam` itself) to write the result there: a pinch frame
  // then allocates nothing (§14.3 rule 4).
  SC.zoomAt = function (cam, f, fx, out) {
    var dayF = (cam.sx + fx) / cam.ppd;
    var ppd = SC.clampPpd(cam.ppd * f);
    var o = out || {};
    o.sx = dayF * ppd - fx; o.sy = cam.sy; o.ppd = ppd; o.epoch = cam.epoch;
    return o;
  };

  // A new epoch for the same view: sx shifts so nothing moves on screen.
  SC.rebase = function (cam, epoch) {
    return { sx: cam.sx + (cam.epoch - epoch) * cam.ppd, sy: cam.sy, ppd: cam.ppd, epoch: epoch };
  };

  /*
   * fitRange(min, max, viewW, epoch) -> camera fields {ppd, sx} showing the
   * inclusive day range [min, max] with a margin of 4% of the view on each
   * side (at least 12 px).
   */
  SC.fitRange = function (min, max, viewW, epoch) {
    var span = Math.max(1, max - min + 1);
    var pad = Math.max(12, viewW * 0.04);
    var ppd = SC.clampPpd((viewW - 2 * pad) / span);
    var used = span * ppd;
    var left = (viewW - used) / 2;
    return { ppd: ppd, sx: (min - epoch) * ppd - left };
  };

  /*
   * clampCamera(cam, bounds, view): bounds {minX, maxX, totalH} in content
   * pixels, view {w, h}. Horizontally about one viewport past the content;
   * vertically 0 .. max(0, totalH - h + FAB_ROOM). Pass `out` (may be
   * `cam` itself) to write the result there instead of a new object.
   */
  SC.clampCamera = function (cam, bounds, view, out) {
    var lo = bounds.minX - view.w, hi = Math.max(lo, bounds.maxX);
    var maxY = Math.max(0, bounds.totalH - view.h + SC.FAB_ROOM);
    var sx = Math.max(lo, Math.min(hi, cam.sx));
    var sy = Math.max(0, Math.min(maxY, cam.sy));
    var o = out || {};
    o.sx = sx; o.sy = sy; o.ppd = cam.ppd; o.epoch = cam.epoch;
    return o;
  };

  /*
   * One fling step, exact for any frame length: velocity decays by
   * FLING_DECAY per 16.667 ms, and the distance is the integral over dt, so
   * 60 Hz and 120 Hz travel the same distance. -> {v, dx, done}, written
   * into `out` when given (the fling loop reuses one object per axis).
   */
  var K = -Math.log(SC.FLING_DECAY) / (1000 / 60);
  SC.fling = function (v, dtMs, out) {
    var dt = Math.max(0, dtMs);
    var e = Math.exp(-K * dt);
    var o = out || {};
    o.dx = v * (1 - e) / K;
    o.v = v * e;
    o.done = Math.abs(o.v) < SC.FLING_STOP_V;
    return o;
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
