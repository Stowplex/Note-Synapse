/*
 * Gantt theme (plan §12.1 to §12.3, D10, D25): theme resolution, the token
 * and palette tables, the canvas token snapshot and the WCAG contrast
 * function. Never reads the host: app.js passes the host's theme in with
 * setHostTheme. The tables are pure data; gantt.html spells the same values
 * in CSS and a test holds the two together.
 *
 * Resolution order: in-app override (appState prefs.theme) > host theme
 * (only after the optional M10) > prefers-color-scheme.
 */
(function (global) {
  'use strict';
  var GT = (global.GT = global.GT || {});
  var T = (GT.theme = {});

  /* ---------------------------------------------------------------- tables */

  // §12.2, the colour tokens (layout and motion tokens live only in CSS).
  T.TOKENS = {
    light: {
      '--bg': '#f5f6f8', '--surface': '#ffffff', '--surface-2': '#eef0f4', '--surface-3': '#e4e7ee',
      '--text': '#191c22', '--muted': '#6b7280', '--faint': '#9aa1ae', '--border': '#e2e5ea',
      '--g-bg': '#ffffff', '--g-stripe': 'rgba(16,24,40,.025)', '--g-weekend': 'rgba(16,24,40,.045)',
      '--g-line': 'rgba(16,24,40,.07)', '--g-line-strong': 'rgba(16,24,40,.14)',
      '--g-header-bg': 'rgba(255,255,255,.92)', '--g-drag-band': 'rgba(79,110,247,.10)',
      '--accent': '#4f6ef7', '--accent-soft': 'rgba(79,110,247,.12)', '--accent-ink': '#ffffff',
      '--today': '#e5484d', '--today-ink': '#ffffff',
      '--good': '#059669', '--warn': '#b45309', '--danger': '#dc2626',
      // M8: late open segments, the label backing, the loading shimmer.
      '--warn-soft': 'rgba(180,83,9,.35)', '--seg-lab': 'rgba(255,255,255,.88)', '--g-shimmer': 'rgba(255,255,255,.55)'
    },
    dark: {
      '--bg': '#0e1013', '--surface': '#171a20', '--surface-2': '#1f232c', '--surface-3': '#2a2f3a',
      '--text': '#e8eaf0', '--muted': '#8b93a5', '--faint': '#6b7280', '--border': '#262b36',
      '--g-bg': '#12151a', '--g-stripe': 'rgba(255,255,255,.025)', '--g-weekend': 'rgba(255,255,255,.035)',
      '--g-line': 'rgba(255,255,255,.06)', '--g-line-strong': 'rgba(255,255,255,.12)',
      '--g-header-bg': 'rgba(23,26,32,.92)', '--g-drag-band': 'rgba(125,144,255,.14)',
      '--accent': '#7d90ff', '--accent-soft': 'rgba(125,144,255,.22)', '--accent-ink': '#0e1013',
      '--today': '#ff6b70', '--today-ink': '#1a0a0b',
      '--good': '#34d399', '--warn': '#fbbf24', '--danger': '#f87171',
      '--warn-soft': 'rgba(251,191,36,.35)', '--seg-lab': 'rgba(18,21,26,.84)', '--g-shimmer': 'rgba(255,255,255,.08)'
    }
  };

  // §12.3: light fill, light tint (the 100 shade), dark fill (a 400 shade).
  var HUES = {
    indigo: ['#4f46e5', '#e0e7ff', '#818cf8'],
    blue: ['#2563eb', '#dbeafe', '#60a5fa'],
    sky: ['#0369a1', '#e0f2fe', '#38bdf8'],
    teal: ['#0f766e', '#ccfbf1', '#2dd4bf'],
    emerald: ['#047857', '#d1fae5', '#34d399'],
    amber: ['#b45309', '#fef3c7', '#fbbf24'],
    orange: ['#c2410c', '#ffedd5', '#fb923c'],
    rose: ['#e11d48', '#ffe4e6', '#fb7185'],
    pink: ['#be185d', '#fce7f3', '#f472b6'],
    violet: ['#7c3aed', '#ede9fe', '#a78bfa'],
    slate: ['#475569', '#e2e8f0', '#94a3b8']
  };
  T.INK = { light: '#ffffff', dark: '#0b0d12' };
  T.DARK_TINT_ALPHA = 0.22;       // hue over --g-bg (§12.3)
  T.STROKE_ALPHA = { light: 0.32, dark: 0.45 };

  /* ----------------------------------------------------------- colour math */

  function hex2(n) { var s = Math.round(Math.max(0, Math.min(255, n))).toString(16); return s.length < 2 ? '0' + s : s; }
  // '#rgb', '#rrggbb' or 'rgb(a)(r,g,b[,a])' -> {r, g, b, a}; null otherwise.
  T.parse = function (c) {
    var s = String(c || '').trim(), m;
    if ((m = /^#([0-9a-f]{3})$/i.exec(s))) {
      return { r: parseInt(m[1][0] + m[1][0], 16), g: parseInt(m[1][1] + m[1][1], 16), b: parseInt(m[1][2] + m[1][2], 16), a: 1 };
    }
    if ((m = /^#([0-9a-f]{6})$/i.exec(s))) {
      return { r: parseInt(m[1].slice(0, 2), 16), g: parseInt(m[1].slice(2, 4), 16), b: parseInt(m[1].slice(4, 6), 16), a: 1 };
    }
    if ((m = /^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)$/i.exec(s))) {
      return { r: +m[1], g: +m[2], b: +m[3], a: m[4] === undefined ? 1 : +m[4] };
    }
    return null;
  };
  T.hex = function (o) { return '#' + hex2(o.r) + hex2(o.g) + hex2(o.b); };
  // `fg` at `alpha` over the opaque `bg`, as an opaque hex colour.
  T.blend = function (fg, alpha, bg) {
    var f = T.parse(fg), b = T.parse(bg);
    return T.hex({ r: f.r * alpha + b.r * (1 - alpha), g: f.g * alpha + b.g * (1 - alpha), b: f.b * alpha + b.b * (1 - alpha) });
  };
  function lin(c) { c /= 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); }
  T.luminance = function (c) {
    var o = T.parse(c);
    return 0.2126 * lin(o.r) + 0.7152 * lin(o.g) + 0.0722 * lin(o.b);
  };
  // WCAG 2 contrast ratio of two opaque colours.
  T.contrast = function (a, b) {
    var la = T.luminance(a), lb = T.luminance(b);
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
  };

  /*
   * PALETTE[name][theme] = {fill, tint, stroke, ink}. Light ink is white on
   * the 600/700 fill, dark ink near-black on the 400 fill; the dark tint is
   * the hue at 22% over --g-bg; the stroke is the fill over the tint.
   */
  T.PALETTE = {};
  Object.keys(HUES).forEach(function (name) {
    var h = HUES[name];
    var darkTint = T.blend(h[2], T.DARK_TINT_ALPHA, T.TOKENS.dark['--g-bg']);
    T.PALETTE[name] = {
      light: { fill: h[0], tint: h[1], stroke: T.blend(h[0], T.STROKE_ALPHA.light, h[1]), ink: T.INK.light },
      dark: { fill: h[2], tint: darkTint, stroke: T.blend(h[2], T.STROKE_ALPHA.dark, darkTint), ink: T.INK.dark }
    };
  });

  // The tokens the canvases paint with (read once per theme change).
  T.CANVAS = ['--g-bg', '--g-stripe', '--g-weekend', '--g-line', '--g-line-strong', '--g-header-bg',
    '--g-drag-band', '--today', '--today-ink', '--text', '--muted', '--faint', '--border', '--accent', '--surface'];

  /* ------------------------------------------------------------ resolution */

  function isTheme(v) { return v === 'light' || v === 'dark'; }
  // Pure: override > host > media.
  T.resolve = function (override, hostTheme, mediaDark) {
    if (isTheme(override)) return override;
    if (isTheme(hostTheme)) return hostTheme;
    return mediaDark ? 'dark' : 'light';
  };

  var env = { doc: null, win: null, mq: null };
  var state = { override: 'auto', host: null, media: false, resolved: 'light', snap: null };
  var listeners = [];

  function mediaDark() { return !!(env.mq && env.mq.matches); }
  function apply() {
    var next = T.resolve(state.override, state.host, state.media);
    var changed = next !== state.resolved;
    state.resolved = next;
    state.snap = null;
    var d = env.doc;
    if (d && d.documentElement) {
      var root = d.documentElement;
      if (root.getAttribute('data-theme') !== next) {
        // One frame without transitions so the swap does not animate.
        root.classList.add('no-anim');
        root.setAttribute('data-theme', next);
        root.style.colorScheme = next;
        var raf = env.win && env.win.requestAnimationFrame;
        if (raf) raf.call(env.win, function () { root.classList.remove('no-anim'); });
        else root.classList.remove('no-anim');
      }
    }
    if (changed) listeners.slice().forEach(function (cb) { try { cb(next); } catch (e) { /* listener bug */ } });
    return next;
  }

  /*
   * init({doc, win, override, hostTheme}) wires prefers-color-scheme and
   * applies the theme. Returns the resolved theme.
   */
  T.init = function (o) {
    o = o || {};
    env.doc = o.doc || null;
    env.win = o.win || null;
    if (env.win && typeof env.win.matchMedia === 'function') {
      env.mq = env.win.matchMedia('(prefers-color-scheme: dark)');
      var onMq = function () { state.media = mediaDark(); apply(); };
      if (env.mq.addEventListener) env.mq.addEventListener('change', onMq);
      else if (env.mq.addListener) env.mq.addListener(onMq);
    }
    state.media = mediaDark();
    state.override = isTheme(o.override) ? o.override : 'auto';
    state.host = isTheme(o.hostTheme) ? o.hostTheme : null;
    state.resolved = d0();
    return apply();
  };
  // What the no-flash script already put on <html>, so init counts a change.
  function d0() {
    var r = env.doc && env.doc.documentElement ? env.doc.documentElement.getAttribute('data-theme') : null;
    return isTheme(r) ? r : 'light';
  }
  T.resolved = function () { return state.resolved; };
  T.override = function () { return state.override; };
  T.setOverride = function (v) { state.override = isTheme(v) ? v : 'auto'; return apply(); };
  T.setHostTheme = function (v) { state.host = isTheme(v) ? v : null; return apply(); };
  T.onChange = function (cb) {
    listeners.push(cb);
    return function () { var i = listeners.indexOf(cb); if (i >= 0) listeners.splice(i, 1); };
  };

  /*
   * The canvas tokens as a plain object, read with ONE getComputedStyle per
   * theme change and cached; falls back to the table when there is no
   * document (node) or a value is empty.
   */
  T.tokens = function () {
    if (state.snap) return state.snap;
    var table = T.TOKENS[state.resolved], out = {};
    var cs = null;
    try { if (env.win && env.doc) cs = env.win.getComputedStyle(env.doc.documentElement); } catch (e) { cs = null; }
    T.CANVAS.forEach(function (k) {
      var v = cs ? String(cs.getPropertyValue(k) || '').trim() : '';
      out[k] = v || table[k];
    });
    state.snap = out;
    return out;
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
