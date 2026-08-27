/*
 * Cartograph - the sidecar block, and re-finding nodes after an outside edit.
 *
 * The sidecar holds only what markdown cannot express: pinned positions and
 * collapse state. It is optional by construction - with it missing, stale or
 * mangled, every node simply auto-lays-out.
 */
(function (global) {
  'use strict';
  var CG = (global.CG = global.CG || {});
  var MD = CG.md;
  var SC = (CG.sidecar = {});

  function norm(text) { return MD.plainText(text).toLowerCase(); }

  function pathKey(node) {
    var parts = [];
    for (var n = node; n && n.kind !== 'root'; n = n.parent) parts.unshift(MD.slug(n.text));
    return (node.kind === 'heading' ? 'h' : 'i') + node.level + ':' + parts.join('/');
  }
  SC.pathKey = pathKey;

  function depthOf(node) {
    var d = 0;
    for (var n = node.parent; n; n = n.parent) d++;
    return d;
  }

  function parentKeyOf(node) {
    return node.parent && node.parent.kind !== 'root' ? pathKey(node.parent) : '';
  }

  SC.fingerprint = function (node) {
    return { key: pathKey(node), text: norm(node.text), depth: depthOf(node), parentKey: parentKeyOf(node) };
  };

  /* ------------------------------------------------------------ similarity */

  function similarity(a, b) {
    if (a === b) return 1;
    if (!a.length || !b.length) return 0;
    // Editing a label usually means appending to or trimming it, which edit
    // distance scores harshly. Treat prefix and containment as near-identity.
    if (a.indexOf(b) === 0 || b.indexOf(a) === 0) return 0.95;
    if (a.indexOf(b) >= 0 || b.indexOf(a) >= 0) return 0.88;
    var m = a.length, n = b.length;
    if (Math.abs(m - n) / Math.max(m, n) > 0.7) return 0;
    var prev = new Array(n + 1), cur = new Array(n + 1);
    for (var j = 0; j <= n; j++) prev[j] = j;
    for (var i = 1; i <= m; i++) {
      cur[0] = i;
      for (var k = 1; k <= n; k++) {
        cur[k] = Math.min(prev[k] + 1, cur[k - 1] + 1, prev[k - 1] + (a.charAt(i - 1) === b.charAt(k - 1) ? 0 : 1));
      }
      var t = prev; prev = cur; cur = t;
    }
    return 1 - prev[n] / Math.max(m, n);
  }
  SC.similarity = similarity;

  /* ----------------------------------------------------------------- match */

  /*
   * Claim nodes for entries, in descending order of confidence:
   *   1. exact path key            (nothing moved)
   *   2. exact text, same depth    (reordered)
   *   3. exact text, anywhere      (reparented)
   *   4. fuzzy text, same parent   (renamed)
   * Anything unclaimed is dropped; those nodes just auto-lay-out.
   */
  SC.match = function (entries, nodes) {
    var result = {};
    var free = nodes.filter(function (n) { return n.kind !== 'root'; });
    var taken = new Set();
    var pending = entries.slice();

    function sweep(pick) {
      var rest = [];
      for (var i = 0; i < pending.length; i++) {
        var e = pending[i];
        var hit = null;
        for (var j = 0; j < free.length; j++) {
          var n = free[j];
          if (taken.has(n)) continue;
          if (pick(e, n)) { hit = n; break; }
        }
        if (hit) { result[e.id] = hit; taken.add(hit); }
        else rest.push(e);
      }
      pending = rest;
    }

    var fp = new Map();
    function f(n) { if (!fp.has(n)) fp.set(n, SC.fingerprint(n)); return fp.get(n); }

    sweep(function (e, n) { return e.key === f(n).key; });
    sweep(function (e, n) { return e.text && e.text === f(n).text && e.depth === f(n).depth; });
    sweep(function (e, n) { return e.text && e.text === f(n).text; });

    // Fuzzy passes take the best candidate rather than the first. Same-parent
    // is the confident case (a plain rename); same-depth is a wider net for a
    // rename that also moved, so it demands a closer match.
    function fuzzy(threshold, sameParent) {
      var rest = [];
      for (var i = 0; i < pending.length; i++) {
        var e = pending[i];
        var best = null, bestScore = threshold;
        for (var j = 0; j < free.length; j++) {
          var n = free[j];
          if (taken.has(n)) continue;
          if (sameParent ? f(n).parentKey !== e.parentKey : f(n).depth !== e.depth) continue;
          var s = similarity(e.text, f(n).text);
          if (s > bestScore) { bestScore = s; best = n; }
        }
        if (best) { result[e.id] = best; taken.add(best); }
        else rest.push(e);
      }
      pending = rest;
    }

    fuzzy(0.62, true);
    fuzzy(0.85, false);

    SC.lastUnmatched = pending.length;
    return result;
  };

  /* --------------------------------------------------------- read / write */

  SC.read = function (doc) {
    if (!doc.sidecar) return {};
    var raw = doc.src.slice(doc.sidecar.span.start, doc.sidecar.span.end);
    var body = raw.replace(/^[^\n]*\n?/, '').replace(/[ \t]*(`{3,}|~{3,})[ \t]*\n?$/, '');
    var data;
    try { data = JSON.parse(body); } catch (e) { return {}; }
    if (!data || typeof data !== 'object' || !data.n) return {};
    var entries = [];
    Object.keys(data.n).forEach(function (id) {
      var v = data.n[id] || {};
      entries.push({
        id: id,
        key: v.k || '',
        text: (v.t || '').toLowerCase(),
        depth: typeof v.d === 'number' ? v.d : -1,
        parentKey: v.pk || '',
        pin: Array.isArray(v.p) && v.p.length === 2 ? { x: v.p[0], y: v.p[1] } : null,
        collapsed: v.c === 1 || v.c === true
      });
    });
    return { v: data.v || 1, entries: entries };
  };

  // Apply a stored sidecar onto a freshly parsed tree.
  SC.apply = function (doc, state) {
    var read = SC.read(doc);
    if (!read.entries || !read.entries.length) return 0;
    var matched = SC.match(read.entries, doc.nodes);
    var applied = 0;
    read.entries.forEach(function (e) {
      var node = matched[e.id];
      if (!node) return;
      if (e.pin) state.pins[node.id] = { x: e.pin.x, y: e.pin.y };
      if (e.collapsed) state.collapsed[node.id] = true;
      applied++;
    });
    return applied;
  };

  // Serialize current pins/collapse. Returns null when there is nothing to say,
  // so a map with no manual state leaves the note completely clean.
  SC.build = function (doc, state) {
    var n = {};
    var count = 0;
    doc.nodes.forEach(function (node) {
      if (node.kind === 'root') return;
      var pin = state.pins[node.id];
      var collapsed = state.collapsed[node.id];
      if (!pin && !collapsed) return;
      var fpr = SC.fingerprint(node);
      var entry = { k: fpr.key, t: fpr.text };
      if (fpr.parentKey) entry.pk = fpr.parentKey;
      entry.d = fpr.depth;
      if (pin) entry.p = [Math.round(pin.x), Math.round(pin.y)];
      if (collapsed) entry.c = 1;
      n[node.id] = entry;
      count++;
    });
    if (!count) return null;
    return '```' + MD.SIDECAR_INFO + '\n' + JSON.stringify({ v: 1, n: n }) + '\n```';
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = CG;
})(typeof window !== 'undefined' ? window : globalThis);
