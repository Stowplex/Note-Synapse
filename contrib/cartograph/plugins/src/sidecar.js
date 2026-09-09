/*
 * Cartograph - the sidecar block, and re-finding nodes after an outside edit.
 *
 * The sidecar holds only what markdown cannot express: pinned positions,
 * collapse state, and comments. It is optional by construction - with it
 * missing, stale or mangled, every node simply auto-lays-out and the map has
 * no comments.
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

  /* -------------------------------------------------------------- comments */

  /*
   * A comment is a free-floating text box laid over the map. It is not a node:
   * it writes no markdown line, creates no note, and nothing in the outline
   * depends on it. It lives only here.
   *
   * In state:   { id, text, anchors: [anchor], pos: { x, y } }
   *   anchor  = { kind: 'node', n: nodeId }
   *           | { kind: 'card', n: nodeId, c: noteId }         an attached-note card
   *           | { kind: 'link', a: end, b: end }              a dashed node link
   *   end     = { n: nodeId, c?: noteId }
   *   pos     = an offset from the FIRST anchor's reference point while anchored,
   *             so the comment rides along when that node moves; an absolute
   *             stage position when it floats free.
   *
   * Anchors name nodes through the same fingerprinted entries pins use, so a
   * comment re-finds what it points at after an outside edit by the same rules,
   * and quietly lets go of what it cannot. Losing the first anchor loses the
   * frame of reference for `pos`, which is why the absolute position is written
   * alongside it (`q`): the comment then stays where it was last seen.
   */
  function anchorNodeIds(a) {
    if (!a) return [];
    if (a.kind === 'link') return [a.a && a.a.n, a.b && a.b.n];
    return [a.n];
  }
  SC.anchorNodeIds = anchorNodeIds;

  // Re-express anchors through `lookup(oldNodeId) -> newNodeId | null`,
  // dropping any whose node is gone. Order is preserved.
  SC.remapAnchors = function (anchors, lookup) {
    var out = [];
    (anchors || []).forEach(function (a) {
      if (!a) return;
      if (a.kind === 'node') {
        var n = lookup(a.n);
        if (n) out.push({ kind: 'node', n: n });
      } else if (a.kind === 'card') {
        var n2 = lookup(a.n);
        if (n2) out.push({ kind: 'card', n: n2, c: a.c });
      } else if (a.kind === 'link' && a.a && a.b) {
        var x = lookup(a.a.n), y = lookup(a.b.n);
        if (x && y) {
          var ea = { n: x }, eb = { n: y };
          if (a.a.c) ea.c = a.a.c;
          if (a.b.c) eb.c = a.b.c;
          out.push({ kind: 'link', a: ea, b: eb });
        }
      }
    });
    return out;
  };

  SC.sameAnchor = function (p, q) {
    if (!p || !q || p.kind !== q.kind) return false;
    if (p.kind === 'link') {
      var same = function (e, f) { return e.n === f.n && (e.c || '') === (f.c || ''); };
      return (same(p.a, q.a) && same(p.b, q.b)) || (same(p.a, q.b) && same(p.b, q.a));
    }
    return p.n === q.n && (p.c || '') === (q.c || '');
  };

  function encodeEnd(e) { var o = { n: e.n }; if (e.c) o.c = e.c; return o; }
  function encodeAnchor(a) {
    if (a.kind === 'link') return { l: [encodeEnd(a.a), encodeEnd(a.b)] };
    return encodeEnd(a);
  }
  function decodeEnd(e) {
    if (!e || typeof e.n !== 'string') return null;
    var o = { n: e.n };
    if (typeof e.c === 'string' && e.c) o.c = e.c;
    return o;
  }
  function decodeAnchor(raw) {
    if (!raw || typeof raw !== 'object') return null;
    if (Array.isArray(raw.l)) {
      var a = decodeEnd(raw.l[0]), b = decodeEnd(raw.l[1]);
      return a && b ? { kind: 'link', a: a, b: b } : null;
    }
    var e = decodeEnd(raw);
    if (!e) return null;
    return e.c ? { kind: 'card', n: e.n, c: e.c } : { kind: 'node', n: e.n };
  }
  function pt(arr) {
    return Array.isArray(arr) && arr.length === 2 && typeof arr[0] === 'number' && typeof arr[1] === 'number'
      ? { x: arr[0], y: arr[1] } : null;
  }

  /* --------------------------------------------------------- read / write */

  SC.read = function (doc) {
    if (!doc.sidecar) return {};
    var raw = doc.src.slice(doc.sidecar.span.start, doc.sidecar.span.end);
    var body = raw.replace(/^[^\n]*\n?/, '').replace(/[ \t]*(`{3,}|~{3,})[ \t]*\n?$/, '');
    var data;
    try { data = JSON.parse(body); } catch (e) { return {}; }
    if (!data || typeof data !== 'object' || (!data.n && !Array.isArray(data.c))) return {};
    var entries = [];
    Object.keys(data.n || {}).forEach(function (id) {
      var v = data.n[id] || {};
      entries.push({
        id: id,
        key: v.k || '',
        text: (v.t || '').toLowerCase(),
        depth: typeof v.d === 'number' ? v.d : -1,
        parentKey: v.pk || '',
        pin: pt(v.p),
        collapsed: v.c === 1 || v.c === true
      });
    });
    var comments = [];
    (Array.isArray(data.c) ? data.c : []).forEach(function (raw) {
      if (!raw || typeof raw !== 'object' || typeof raw.i !== 'string' || !raw.i) return;
      var text = typeof raw.t === 'string' ? raw.t : '';
      if (!text.trim()) return;
      var pos = pt(raw.p);
      if (!pos) return;
      comments.push({
        id: raw.i,
        text: text,
        pos: pos,
        abs: pt(raw.q),
        anchors: (Array.isArray(raw.a) ? raw.a : []).map(decodeAnchor).filter(Boolean)
      });
    });
    return { v: data.v || 1, entries: entries, comments: comments };
  };

  // Apply a stored sidecar onto a freshly parsed tree.
  SC.apply = function (doc, state) {
    var read = SC.read(doc);
    var entries = read.entries || [];
    var matched = entries.length ? SC.match(entries, doc.nodes) : {};
    var applied = 0;
    entries.forEach(function (e) {
      var node = matched[e.id];
      if (!node) return;
      if (e.pin) state.pins[node.id] = { x: e.pin.x, y: e.pin.y };
      if (e.collapsed) state.collapsed[node.id] = true;
      applied++;
    });
    if (state.comments && typeof state.comments === 'object') {
      var lookup = function (id) { return matched[id] ? matched[id].id : null; };
      (read.comments || []).forEach(function (c) {
        var anchors = SC.remapAnchors(c.anchors, lookup);
        var first = c.anchors.length ? SC.remapAnchors([c.anchors[0]], lookup) : [];
        var out = { id: c.id, text: c.text, anchors: anchors, pos: { x: c.pos.x, y: c.pos.y } };
        if (c.anchors.length && !first.length) {
          // The node the offset was measured from is gone. Stay where last seen;
          // the app re-measures against whatever anchor comes first now.
          var abs = c.abs || c.pos;
          out.pos = { x: abs.x, y: abs.y };
          if (anchors.length) out.reanchor = true;
        }
        state.comments[c.id] = out;
        applied++;
      });
    }
    return applied;
  };

  // Serialize current pins/collapse/comments. Returns null when there is
  // nothing to say, so a map with no manual state leaves the note completely
  // clean.
  SC.build = function (doc, state) {
    var n = {};
    var count = 0;
    function ensure(node) {
      if (n[node.id]) return;
      var fpr = SC.fingerprint(node);
      var entry = { k: fpr.key, t: fpr.text };
      if (fpr.parentKey) entry.pk = fpr.parentKey;
      entry.d = fpr.depth;
      n[node.id] = entry;
    }
    doc.nodes.forEach(function (node) {
      if (node.kind === 'root') return;
      var pin = state.pins[node.id];
      var collapsed = state.collapsed[node.id];
      if (!pin && !collapsed) return;
      ensure(node);
      if (pin) n[node.id].p = [Math.round(pin.x), Math.round(pin.y)];
      if (collapsed) n[node.id].c = 1;
      count++;
    });

    var comments = [];
    var cm = state.comments || {};
    Object.keys(cm).forEach(function (id) {
      var c = cm[id];
      // A comment nobody has written anything into is nothing to say.
      if (!c || !c.text || !c.text.trim()) return;
      var live = function (nid) { var d = doc.byId[nid]; return d && d.kind !== 'root' ? d : null; };
      var kept = SC.remapAnchors(c.anchors, function (nid) { return live(nid) ? nid : null; });
      kept.forEach(function (a) { anchorNodeIds(a).forEach(function (nid) { ensure(live(nid)); }); });
      var entry = { i: c.id, t: c.text };
      if (kept.length) {
        entry.p = [Math.round(c.pos.x), Math.round(c.pos.y)];
        entry.a = kept.map(encodeAnchor);
        if (c.abs) entry.q = [Math.round(c.abs.x), Math.round(c.abs.y)];
      } else {
        // Every anchor is gone (or there never was one): it floats where last seen.
        var abs = (c.anchors && c.anchors.length && c.abs) ? c.abs : c.pos;
        entry.p = [Math.round(abs.x), Math.round(abs.y)];
      }
      comments.push(entry);
    });

    if (!count && !comments.length) return null;
    var data = { v: 1, n: n };
    if (comments.length) data.c = comments;
    return '```' + MD.SIDECAR_INFO + '\n' + JSON.stringify(data) + '\n```';
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = CG;
})(typeof window !== 'undefined' ? window : globalThis);
