/*
 * Cartograph - balanced two-sided tidy-tree layout.
 *
 * Flowed nodes are packed by a variable-size Reingold-Tilford walk, so
 * siblings never overlap. Pinned nodes leave the flow entirely: their subtree
 * is laid out around the pin, and flowed branches are pushed clear of it.
 */
(function (global) {
  'use strict';
  var CG = (global.CG = global.CG || {});
  var LO = (CG.layout = {});

  function defaultSize() { return { w: 160, h: 36 }; }

  /*
   * Most notes open with a single `# Title` heading, which would otherwise make
   * the whole document one lopsided branch hanging off the note title. When the
   * synthetic root has exactly one heading child, that heading becomes the
   * visual centre instead. Only ever hoisted one level, so nothing is hidden.
   */
  LO.displayRoot = function (root) {
    if (root.kind === 'root' && root.children.length === 1 &&
        root.children[0].kind === 'heading' && root.children[0].children.length) {
      return root.children[0];
    }
    return root;
  };

  LO.compute = function (root, opts) {
    opts = opts || {};
    var sizeOf = opts.sizeOf || defaultSize;
    var isCollapsed = opts.isCollapsed || function () { return false; };
    var pinOf = opts.pinOf || function () { return null; };
    var vgap = opts.vgap == null ? 16 : opts.vgap;
    var hgap = opts.hgap == null ? 58 : opts.hgap;

    var boxes = new Map();
    var ext = new Map();
    var sizes = new Map();

    function size(n) {
      if (!sizes.has(n)) sizes.set(n, sizeOf(n));
      return sizes.get(n);
    }
    function kids(n) {
      if (isCollapsed(n)) return [];
      return n.children.filter(function (c) { return !pinOf(c); });
    }

    /* ---- vertical extents, bottom up ---- */
    function measure(n) {
      var k = kids(n);
      var s = size(n);
      if (!k.length) { ext.set(n, s.h); return s.h; }
      var sum = 0;
      for (var i = 0; i < k.length; i++) {
        sum += measure(k[i]);
        if (i) sum += vgap;
      }
      var e = Math.max(s.h, sum);
      ext.set(n, e);
      return e;
    }

    /* ---- per-depth column widths within one tree ---- */
    function columnWidths(n, depth, acc) {
      var s = size(n);
      acc[depth] = Math.max(acc[depth] || 0, s.w);
      var k = kids(n);
      for (var i = 0; i < k.length; i++) columnWidths(k[i], depth + 1, acc);
      return acc;
    }

    function columnX(widths, dir, startX) {
      var xs = [startX];
      for (var d = 1; d < widths.length; d++) {
        xs[d] = dir > 0
          ? xs[d - 1] + (widths[d - 1] || 0) + hgap
          : xs[d - 1] - hgap - (widths[d] || 0);
      }
      return xs;
    }

    function place(n, depth, top, dir, xs, branch) {
      var s = size(n);
      var k = kids(n);
      var e = ext.get(n);
      var x = xs[depth] == null ? xs[xs.length - 1] : xs[depth];

      if (!k.length) {
        boxes.set(n.id, { node: n, x: x, y: top + (e - s.h) / 2, w: s.w, h: s.h, depth: depth, dir: dir, branch: branch });
        return;
      }
      var total = 0;
      for (var i = 0; i < k.length; i++) { total += ext.get(k[i]); if (i) total += vgap; }
      var cy = top + (e - total) / 2;
      var firstMid = 0, lastMid = 0;
      for (var j = 0; j < k.length; j++) {
        place(k[j], depth + 1, cy, dir, xs, branch);
        var kb = boxes.get(k[j].id);
        var mid = kb.y + kb.h / 2;
        if (j === 0) firstMid = mid;
        lastMid = mid;
        cy += ext.get(k[j]) + vgap;
      }
      boxes.set(n.id, { node: n, x: x, y: (firstMid + lastMid) / 2 - s.h / 2, w: s.w, h: s.h, depth: depth, dir: dir, branch: branch });
    }

    /* ---- main tree: root centred, branches balanced left/right ---- */
    var rootSize = size(root);
    var topLevel = kids(root);
    topLevel.forEach(measure);

    var left = [], right = [], loadL = 0, loadR = 0;
    for (var t = 0; t < topLevel.length; t++) {
      var h = ext.get(topLevel[t]);
      if (loadR <= loadL) { right.push(topLevel[t]); loadR += h + vgap; }
      else { left.push(topLevel[t]); loadL += h + vgap; }
    }

    boxes.set(root.id, { node: root, x: -rootSize.w / 2, y: -rootSize.h / 2, w: rootSize.w, h: rootSize.h, depth: 0, dir: 0, branch: -1 });

    function layoutSide(list, dir) {
      if (!list.length) return;
      // widths[d] is the widest card at absolute depth d; xs[d] its left edge.
      var widths = [];
      list.forEach(function (n) { columnWidths(n, 1, widths); });
      var xs = [];
      xs[0] = -rootSize.w / 2;
      xs[1] = dir > 0
        ? rootSize.w / 2 + hgap
        : -rootSize.w / 2 - hgap - (widths[1] || 0);
      for (var dd = 2; dd < widths.length; dd++) {
        xs[dd] = dir > 0
          ? xs[dd - 1] + (widths[dd - 1] || 0) + hgap
          : xs[dd - 1] - hgap - (widths[dd] || 0);
      }
      var total = 0;
      list.forEach(function (n, i) { total += ext.get(n); if (i) total += vgap; });
      var cy = -total / 2;
      list.forEach(function (n) {
        var branch = topLevel.indexOf(n);
        place(n, 1, cy, dir, xs, branch);
        cy += ext.get(n) + vgap;
      });
    }
    layoutSide(right, 1);
    layoutSide(left, -1);

    /* ---- pinned subtrees float free ---- */
    var pinnedGroups = [];
    (function collectPinned(n, visible) {
      for (var i = 0; i < n.children.length; i++) {
        var c = n.children[i];
        var pin = visible ? pinOf(c) : null;
        if (pin) {
          measure(c);
          var widths = columnWidths(c, 0, []);
          var dir = 1;
          var xs = columnX(widths, dir, pin.x);
          var e = ext.get(c);
          place(c, 0, pin.y - e / 2, dir, xs, topLevelAncestorIndex(c));
          pinnedGroups.push(c);
          collectPinned(c, !isCollapsed(c));
        } else {
          collectPinned(c, visible && !isCollapsed(c));
        }
      }
    })(root, true);

    function topLevelAncestorIndex(n) {
      var cur = n;
      while (cur.parent && cur.parent !== root) cur = cur.parent;
      return topLevel.indexOf(cur);
    }

    /* ---- push flowed branches clear of pinned ones ---- */
    function groupBounds(n) {
      var b = null;
      (function walk(x) {
        var bx = boxes.get(x.id);
        if (bx) {
          if (!b) b = { x0: bx.x, y0: bx.y, x1: bx.x + bx.w, y1: bx.y + bx.h };
          else {
            b.x0 = Math.min(b.x0, bx.x); b.y0 = Math.min(b.y0, bx.y);
            b.x1 = Math.max(b.x1, bx.x + bx.w); b.y1 = Math.max(b.y1, bx.y + bx.h);
          }
        }
        var k = kids(x);
        for (var i = 0; i < k.length; i++) walk(k[i]);
      })(n);
      return b;
    }
    function shift(n, dy) {
      (function walk(x) {
        var bx = boxes.get(x.id);
        if (bx) bx.y += dy;
        var k = kids(x);
        for (var i = 0; i < k.length; i++) walk(k[i]);
      })(n);
    }
    if (pinnedGroups.length) {
      var pinBounds = pinnedGroups.map(groupBounds).filter(Boolean);
      for (var pass = 0; pass < 6; pass++) {
        var moved = false;
        for (var g = 0; g < topLevel.length; g++) {
          var gb = groupBounds(topLevel[g]);
          if (!gb) continue;
          for (var p = 0; p < pinBounds.length; p++) {
            var pb = pinBounds[p];
            if (gb.x1 + 8 < pb.x0 || pb.x1 + 8 < gb.x0) continue;
            if (gb.y1 + vgap < pb.y0 || pb.y1 + vgap < gb.y0) continue;
            var up = pb.y0 - vgap - gb.y1;
            var down = pb.y1 + vgap - gb.y0;
            var dy = Math.abs(up) < Math.abs(down) ? up : down;
            shift(topLevel[g], dy);
            moved = true;
            break;
          }
        }
        if (!moved) break;
      }
    }

    /* ---- edges + bbox ---- */
    var edges = [];
    (function walkEdges(n, visible) {
      var k = visible && !isCollapsed(n) ? n.children : [];
      for (var i = 0; i < k.length; i++) {
        var c = k[i];
        var pb = boxes.get(n.id), cb = boxes.get(c.id);
        if (pb && cb) edges.push({ from: pb, to: cb, parent: n, child: c, pinned: !!pinOf(c), branch: cb.branch });
        walkEdges(c, true);
      }
    })(root, true);

    var bbox = null;
    boxes.forEach(function (b) {
      if (!bbox) bbox = { x0: b.x, y0: b.y, x1: b.x + b.w, y1: b.y + b.h };
      else {
        bbox.x0 = Math.min(bbox.x0, b.x); bbox.y0 = Math.min(bbox.y0, b.y);
        bbox.x1 = Math.max(bbox.x1, b.x + b.w); bbox.y1 = Math.max(bbox.y1, b.y + b.h);
      }
    });

    return { boxes: boxes, edges: edges, bbox: bbox || { x0: 0, y0: 0, x1: 0, y1: 0 }, sides: { left: left, right: right } };
  };

  // Test helper: any two flowed boxes that overlap is a layout bug.
  LO.overlaps = function (result) {
    var list = [];
    result.boxes.forEach(function (b) { list.push(b); });
    var bad = [];
    for (var i = 0; i < list.length; i++) {
      for (var j = i + 1; j < list.length; j++) {
        var a = list[i], b = list[j];
        if (a.x + a.w <= b.x || b.x + b.w <= a.x) continue;
        if (a.y + a.h <= b.y || b.y + b.h <= a.y) continue;
        bad.push([a.node.text || 'root', b.node.text || 'root']);
      }
    }
    return bad;
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = CG;
})(typeof window !== 'undefined' ? window : globalThis);
