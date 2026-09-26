/*
 * Gantt - calendar arithmetic on integer day numbers.
 *
 * A day number is Date.UTC(y, m - 1, d) / 864e5, so 1970-01-01 is 0. Days are
 * UTC-based and DST can never move one. Only today() and fromHost() look at
 * the local clock, because "today" and a zoned host value are local ideas.
 *
 * Workday functions take `s`, the chart settings (or any object with
 * `workdays` and `holidays`). Missing values fall back to Monday to Friday and
 * no holidays. A settings object with no working days at all is treated as
 * "every day works" so no loop can run forever.
 */
(function (global) {
  'use strict';
  var GT = (global.GT = global.GT || {});
  var D = (GT.dates = {});

  var MS = 864e5;
  var YMD = /^(\d{4})-(\d{2})-(\d{2})$/;
  var DEFAULT_WORK = [1, 2, 3, 4, 5];

  function pad(n, w) { var s = String(n); while (s.length < w) s = '0' + s; return s; }

  // 'YYYY-MM-DD' to a day number, or null for anything else (including 2026-02-30).
  D.parse = function (iso) {
    if (typeof iso !== 'string') return null;
    var m = YMD.exec(iso);
    if (!m) return null;
    var y = +m[1], mo = +m[2], d = +m[3];
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    var t = Date.UTC(y, mo - 1, d);
    var back = new Date(t);
    if (back.getUTCFullYear() !== y || back.getUTCMonth() !== mo - 1 || back.getUTCDate() !== d) return null;
    // Date.UTC maps years 0..99 to 1900..1999.
    if (y < 100) return null;
    return Math.round(t / MS);
  };

  // The representable range: four-digit years 0100 to 9999.
  D.MIN = D.parse('0100-01-01');
  D.MAX = D.parse('9999-12-31');
  D.clamp = function (day) { return Math.max(D.MIN, Math.min(D.MAX, day)); };

  D.format = function (day) {
    if (typeof day !== 'number' || !isFinite(day)) return '';
    var dt = new Date(Math.round(day) * MS);
    return pad(dt.getUTCFullYear(), 4) + '-' + pad(dt.getUTCMonth() + 1, 2) + '-' + pad(dt.getUTCDate(), 2);
  };

  function toDate(now) {
    if (now instanceof Date) return now;
    return new Date(typeof now === 'number' ? now : Date.now());
  }

  // The local calendar date of `now` (a Date or ms; default the current time).
  D.today = function (now) {
    var dt = toDate(now);
    return Math.round(Date.UTC(dt.getFullYear(), dt.getMonth(), dt.getDate()) / MS);
  };

  // How far through the local day `now` is, in [0, 1).
  D.dayFraction = function (now) {
    var dt = toDate(now);
    var s = dt.getHours() * 3600 + dt.getMinutes() * 60 + dt.getSeconds() + dt.getMilliseconds() / 1000;
    return Math.min(0.999999, Math.max(0, s / 86400));
  };

  // 0 = Sunday. Day 0 (1970-01-01) was a Thursday.
  D.dow = function (day) { return (((day + 4) % 7) + 7) % 7; };

  D.startOfWeek = function (day, ws) {
    var w = (typeof ws === 'number' && ws >= 0 && ws <= 6) ? ws : 0;
    return day - ((D.dow(day) - w + 7) % 7);
  };

  function ymd(day) {
    var dt = new Date(day * MS);
    return { y: dt.getUTCFullYear(), m: dt.getUTCMonth(), d: dt.getUTCDate() };
  }
  function fromYmd(y, m, d) { return Math.round(Date.UTC(y, m, d) / MS); }

  // ISO 8601 week number (weeks start Monday; week 1 holds the first Thursday).
  D.isoWeek = function (day) {
    var thu = day - ((D.dow(day) + 6) % 7) + 3;          // the Thursday of day's ISO week
    var y = new Date(thu * MS).getUTCFullYear();
    return Math.floor((thu - Math.round(Date.UTC(y, 0, 1) / MS)) / 7) + 1;
  };
  // The number of the week that starts on `start` (a week-start day `ws`):
  // the ISO week of the Monday inside it, so Sunday and Monday weeks agree.
  D.weekNumber = function (start, ws) {
    return D.isoWeek(start + ((1 - (ws || 0) + 7) % 7));
  };

  D.startOfMonth = function (day) { var p = ymd(day); return fromYmd(p.y, p.m, 1); };

  // Same day of month n months later, clamped to the month's last day.
  D.addMonths = function (day, n) {
    var p = ymd(day);
    var total = p.y * 12 + p.m + (n | 0);
    var y = Math.floor(total / 12), m = total - y * 12;
    var last = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
    return fromYmd(y, m, Math.min(p.d, last));
  };

  D.startOfQuarter = function (day) { var p = ymd(day); return fromYmd(p.y, p.m - (p.m % 3), 1); };

  /* -------------------------------------------------------------- workdays */

  // One cached lookup per settings object identity and content.
  var cacheKey = null, cacheVal = null;
  function workInfo(s) {
    var wd = (s && Array.isArray(s.workdays)) ? s.workdays : DEFAULT_WORK;
    var hol = (s && Array.isArray(s.holidays)) ? s.holidays : [];
    var key = wd.join(',') + '|' + hol.join(',');
    if (key === cacheKey) return cacheVal;
    var days = [false, false, false, false, false, false, false], any = false;
    wd.forEach(function (w) { if (w >= 0 && w <= 6 && w === Math.floor(w)) { days[w] = true; any = true; } });
    if (!any) days = [true, true, true, true, true, true, true];
    var h = Object.create(null);
    hol.forEach(function (x) {
      var n = typeof x === 'number' ? x : D.parse(x);
      if (n !== null && isFinite(n)) h[n] = true;
    });
    // Holidays can remove every working day only in theory; addWork caps its walk.
    cacheKey = key;
    cacheVal = { days: days, hol: h };
    return cacheVal;
  }

  D.isWork = function (day, s) {
    var w = workInfo(s);
    return w.days[D.dow(day)] && !w.hol[day];
  };

  // The nearest working day at or after (dir >= 0) or at or before (dir < 0) `day`.
  D.snap = function (day, s, dir) {
    var step = dir < 0 ? -1 : 1;
    for (var i = 0; i < 3660; i++) {
      if (D.isWork(day + i * step, s)) return day + i * step;
    }
    return day;
  };

  // Move n working days. n = 0 snaps forward to a working day.
  D.addWork = function (day, n, s) {
    n = n | 0;
    if (n === 0) return D.snap(day, s, 1);
    var step = n > 0 ? 1 : -1, left = Math.abs(n), d = day, guard = 0;
    while (left > 0 && guard++ < 366000) {
      d += step;
      if (D.isWork(d, s)) left--;
    }
    return d;
  };

  // Working days in the inclusive range [a, b]; negative when b < a.
  D.workBetween = function (a, b, s) {
    if (b < a) return -D.workBetween(b, a, s);
    var n = 0;
    for (var d = a; d <= b; d++) if (D.isWork(d, s)) n++;
    return n;
  };

  /* ------------------------------------------------------------ host dates */

  var ZONED = /(Z|[+-]\d{2}:?\d{2})$/i;

  // A host date string to a day number. A bare date or a zone-less timestamp
  // is taken as written; a value with Z or an offset becomes the local date.
  D.fromHost = function (str) {
    if (typeof str !== 'string') return null;
    var t = str.trim();
    if (!t) return null;
    if (ZONED.test(t) && /T|\s\d/.test(t)) {
      var ms = Date.parse(t);
      if (!isFinite(ms)) return null;
      return D.today(ms);
    }
    var m = /^(\d{4}-\d{2}-\d{2})(?:$|[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?$)/.exec(t);
    if (!m) return null;
    return D.parse(m[1]);
  };

  D.toHost = function (day) { return D.format(day); };

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
