/*
 * Cartograph - exporting the map.
 *
 * Three layers, so a new format is one function and a new destination is
 * another:
 *
 *   doc + state --scene()--> Scene --writer--> { base64 | text } --sink--> attached to the note
 *
 * The scene is a plain description of the WHOLE map - every branch expanded,
 * focus lifted, filters ignored - laid out afresh with the same layout engine
 * the screen uses, sized by the same text wrapping the writer will draw. It
 * never depends on what is on screen, so exporting a filtered or focused map
 * still exports all of it.
 *
 * The PNG writer draws the scene as SVG made of <rect>, <path> and <text> only
 * - no <foreignObject>, no CSS classes, no external references - because that
 * is the subset an <img>-loaded SVG renders reliably in WebKit, which is the
 * only way to rasterise inside a WebView with no network and no library.
 */
(function (global) {
  'use strict';
  var CG = (global.CG = global.CG || {});
  var EX = (CG.export = {});
  var MD = CG.md;

  /* ------------------------------------------------------------- palette */

  // The light theme's variables, fixed: an export must read the same in a
  // chat, a document or on paper whatever the phone's theme was.
  EX.PALETTE = {
    branches: ['#4f6ef7', '#e0559a', '#0d9488', '#d97706', '#7c3aed', '#2563eb', '#059669', '#db2777'],
    bg: '#ffffff', surface: '#ffffff', surface2: '#eef0f4', surface3: '#e4e7ee',
    text: '#191c22', muted: '#6b7280', faint: '#9aa1ae', border: '#e2e5ea',
    accent: '#4f6ef7', accentSoft: '#e4e9fe', accentInk: '#ffffff',
    good: '#059669', goodSoft: '#dcf3ea',
    comment: '#fff6d5', commentBorder: '#e8cf86', commentInk: '#4a3a10', commentLine: '#c9a227'
  };

  EX.FONT = '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif';

  function colorOf(branch) {
    var P = EX.PALETTE;
    if (branch == null || branch < 0) return P.accent;
    return P.branches[branch % P.branches.length];
  }

  /* ---------------------------------------------------------- typography */

  // Mirrors the .cg-node rules in cartograph.html.
  function styleFor(v, depth) {
    if (v.isRoot) return { size: 17, weight: 700, padX: 18, padY: 12, maxW: 260, radius: 999, lineH: 1.35 };
    if (v.kind === 'note') return { size: 13.5, weight: 640, padX: 12, padY: 8, maxW: 220, minW: 130, radius: 10, lineH: 1.35, card: true };
    var deep = depth >= 3;
    return {
      size: deep ? 13 : (v.kind === 'heading' && depth === 1 ? 15.5 : 14),
      weight: v.kind === 'heading' ? 640 : 450,
      padX: deep ? 10 : 12, padY: deep ? 6 : 8, maxW: deep ? 180 : 210, radius: 10, lineH: 1.35
    };
  }

  function fontString(size, weight) { return weight + ' ' + size + 'px ' + EX.FONT; }
  EX.fontString = fontString;

  /*
   * measure(text, font) -> width in px. In the browser a canvas measures with
   * the real font; in node an estimate stands in, so the scene is testable
   * without a DOM. Wide scripts count as a full em.
   */
  EX.canvasMeasure = function () {
    var ctx = global.document ? global.document.createElement('canvas').getContext('2d') : null;
    if (!ctx) return EX.estimateMeasure;
    return function (text, font) { ctx.font = font; return ctx.measureText(text).width; };
  };
  EX.estimateMeasure = function (text, font) {
    var px = parseFloat(String(font).replace(/^\d+\s+/, '')) || 14;
    var w = 0;
    for (var i = 0; i < text.length; i++) {
      var c = text.charCodeAt(i);
      w += (c > 0x2e80 ? 1 : (c === 32 ? 0.28 : 0.55)) * px;
    }
    return w;
  };

  // Word wrap to maxW; a word wider than the line (or a run of CJK) is broken
  // by character, so nothing can overflow its box.
  EX.wrap = function (text, font, maxW, measure) {
    var words = String(text == null ? '' : text).split(/\s+/).filter(Boolean);
    if (!words.length) return [''];
    var lines = [], cur = '';
    words.forEach(function (w) {
      if (cur && measure(cur + ' ' + w, font) > maxW) { lines.push(cur); cur = ''; }
      if (measure(w, font) > maxW) {
        var piece = cur ? cur + ' ' : '';
        for (var i = 0; i < w.length; i++) {
          var ch = w.charAt(i);
          if (piece && measure(piece + ch, font) > maxW) { lines.push(piece); piece = ch; }
          else piece += ch;
        }
        cur = piece;
      } else {
        cur = cur ? cur + ' ' + w : w;
      }
    });
    if (cur) lines.push(cur);
    return lines.length ? lines : [''];
  };

  function textOf(v) {
    if (v.kind === 'note') return v.noteTitle || 'Note';
    return MD.plainText(v.text) || 'Untitled';
  }

  /* --------------------------------------------------------------- scene */

  function edgeEnds(from, to) {
    var rightward = (to.x + to.w / 2) >= (from.x + from.w / 2);
    return {
      x1: rightward ? from.x + from.w : from.x, y1: from.y + from.h / 2,
      x2: rightward ? to.x : to.x + to.w, y2: to.y + to.h / 2
    };
  }
  function edgePath(from, to) {
    var e = edgeEnds(from, to);
    var mx = e.x1 + (e.x2 - e.x1) * 0.5;
    return 'M' + r1(e.x1) + ',' + r1(e.y1) + 'C' + r1(mx) + ',' + r1(e.y1) + ' ' + r1(mx) + ',' + r1(e.y2) + ' ' + r1(e.x2) + ',' + r1(e.y2);
  }
  function r1(n) { return Math.round(n * 10) / 10; }

  EX.PAD = 40;

  /*
   * state: { title, pins, comments, noteCache }. Only pins are honoured from
   * the on-screen state - they are the reader's own layout choices. Collapse,
   * focus and filters are deliberately not.
   */
  EX.scene = function (doc, state, measure) {
    state = state || {};
    measure = measure || EX.estimateMeasure;
    var pins = state.pins || {};
    var vt = CG.view.build(doc, {
      title: state.title, collapsed: {}, focusId: null, query: '', filters: {}, noteCache: state.noteCache || {}
    });

    var info = {};
    function sizeOf(v) {
      if (info[v.id]) return info[v.id];
      var depth = 0;
      for (var p = v.parent; p; p = p.parent) depth++;
      var st = styleFor(v, depth);
      var font = fontString(st.size, st.weight);
      var innerMax = st.maxW - st.padX * 2;
      var lines = EX.wrap(textOf(v), font, innerMax, measure);
      var textW = 0;
      lines.forEach(function (l) { textW = Math.max(textW, measure(l, font)); });
      var lineH = st.size * st.lineH;
      var h = lines.length * lineH + st.padY * 2;
      var w = textW + st.padX * 2;
      var check = v.checked !== null && v.kind !== 'note';
      if (check) w += 16 + 7;
      var pills = [];
      if (v.taskTotal) pills.push({ kind: 'tasks', text: v.taskDone + '/' + v.taskTotal });
      if (v.hasBody) pills.push({ kind: 'body', text: '¶' });
      if (pins[v.id]) pills.push({ kind: 'pinned', text: '📌' });
      var pillW = 0;
      pills.forEach(function (pl) { pl.w = Math.ceil(measure(pl.text, fontString(10.5, 700)) + 12); pillW += pl.w + 5; });
      if (pillW) w += pillW + 4;
      var preview = [];
      if (st.card && v.notePreview) {
        var pf = fontString(11.5, 400);
        preview = EX.wrap(v.notePreview, pf, innerMax, measure).slice(0, 2);
        var pw = 0;
        preview.forEach(function (l) { pw = Math.max(pw, measure(l, pf)); });
        w = Math.max(w, pw + st.padX * 2);
        h += preview.length * 11.5 * 1.35 + 3;
      }
      if (st.minW) w = Math.max(w, st.minW);
      info[v.id] = {
        w: Math.ceil(w), h: Math.ceil(h), st: st, font: font, lines: lines, lineH: lineH,
        check: check, pills: pills, preview: preview, depth: depth
      };
      return info[v.id];
    }

    var res = CG.layout.compute(vt.root, {
      sizeOf: sizeOf,
      isCollapsed: function () { return false; },
      pinOf: function (v) { return pins[v.id] || null; },
      vgap: 16, hgap: 56
    });

    /* ---- comments ---- */
    function endId(end) { return end.c ? 'note:' + end.n + ':' + end.c : end.n; }
    function crossLink(a, b) {
      for (var i = 0; i < vt.crossLinks.length; i++) {
        var l = vt.crossLinks[i];
        if ((l.from === a && l.to === b) || (l.from === b && l.to === a)) return l;
      }
      return null;
    }
    function anchorPoint(a) {
      if (!a) return null;
      if (a.kind === 'link') {
        var l = crossLink(endId(a.a), endId(a.b));
        if (!l) return null;
        var ba = res.boxes.get(l.from), bb = res.boxes.get(l.to);
        if (!ba || !bb) return null;
        var e = edgeEnds(ba, bb);
        return { x: (e.x1 + e.x2) / 2, y: (e.y1 + e.y2) / 2 };
      }
      var b = res.boxes.get(a.kind === 'card' ? endId({ n: a.n, c: a.c }) : a.n);
      return b ? { x: b.x + b.w / 2, y: b.y + b.h / 2 } : null;
    }
    var comments = [];
    var cm = state.comments || {};
    var cfont = fontString(12.5, 400);
    Object.keys(cm).forEach(function (cid) {
      var c = cm[cid];
      if (!c || !c.text || !c.text.trim()) return;
      var origin, pts = [];
      if (c.anchors && c.anchors.length && !c.reanchor) {
        var p0 = anchorPoint(c.anchors[0]);
        if (!p0) return;
        origin = { x: p0.x + c.pos.x, y: p0.y + c.pos.y };
      } else {
        origin = { x: c.pos.x, y: c.pos.y };
      }
      (c.anchors || []).forEach(function (a) { var q = anchorPoint(a); if (q) pts.push(q); });
      var lines = [];
      c.text.split('\n').forEach(function (para) { lines = lines.concat(EX.wrap(para, cfont, 200 - 20, measure)); });
      var tw = 0;
      lines.forEach(function (l) { tw = Math.max(tw, measure(l, cfont)); });
      comments.push({
        id: cid, x: origin.x, y: origin.y, w: Math.ceil(Math.max(44, tw + 20)), h: Math.ceil(lines.length * 12.5 * 1.35 + 14),
        lines: lines, font: cfont, lineH: 12.5 * 1.35, anchors: pts
      });
    });

    /* ---- bounds, shifted to a top-left origin ---- */
    var b = { x0: res.bbox.x0, y0: res.bbox.y0, x1: res.bbox.x1, y1: res.bbox.y1 };
    comments.forEach(function (c) {
      b.x0 = Math.min(b.x0, c.x); b.y0 = Math.min(b.y0, c.y);
      b.x1 = Math.max(b.x1, c.x + c.w); b.y1 = Math.max(b.y1, c.y + c.h);
    });
    var ox = -b.x0 + EX.PAD, oy = -b.y0 + EX.PAD;
    function shifted(bx) { return { x: bx.x + ox, y: bx.y + oy, w: bx.w, h: bx.h }; }

    var nodes = [], cards = [];
    res.boxes.forEach(function (bx) {
      var v = bx.node, i = info[v.id];
      var entry = {
        id: v.id, kind: v.isRoot ? 'root' : v.kind, isRoot: !!v.isRoot,
        x: bx.x + ox, y: bx.y + oy, w: bx.w, h: bx.h, depth: bx.depth, branch: bx.branch, color: colorOf(bx.branch),
        text: textOf(v), lines: i.lines, font: i.font, lineH: i.lineH, st: i.st,
        checked: v.checked, check: i.check, pills: i.pills, preview: i.preview
      };
      (v.kind === 'note' ? cards : nodes).push(entry);
    });
    var edges = res.edges.map(function (e) {
      return {
        from: shifted(e.from), to: shifted(e.to), color: colorOf(e.to.branch),
        width: Math.max(1.4, 4 - e.to.depth * 0.7), pinned: !!e.pinned, card: e.child.kind === 'note'
      };
    });
    var links = [];
    vt.crossLinks.forEach(function (cl) {
      var a = res.boxes.get(cl.from), c2 = res.boxes.get(cl.to);
      if (a && c2) links.push({ from: shifted(a), to: shifted(c2) });
    });
    comments.forEach(function (c) {
      c.x += ox; c.y += oy;
      c.anchors = c.anchors.map(function (p) { return { x: p.x + ox, y: p.y + oy }; });
    });

    return {
      w: Math.ceil(b.x1 - b.x0 + EX.PAD * 2), h: Math.ceil(b.y1 - b.y0 + EX.PAD * 2),
      nodes: nodes, cards: cards, edges: edges, links: links, comments: comments,
      count: vt.all.length
    };
  };

  /* ----------------------------------------------------------------- svg */

  function esc(s) {
    return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  function textBlock(x, y, lines, size, weight, fill, lineH, extra) {
    var out = '<text x="' + r1(x) + '" y="' + r1(y) + '" font-size="' + size + '" font-weight="' + weight + '" fill="' + fill + '"' + (extra || '') + '>';
    lines.forEach(function (l, i) {
      out += '<tspan x="' + r1(x) + '" dy="' + (i ? r1(lineH) : 0) + '">' + esc(l) + '</tspan>';
    });
    return out + '</text>';
  }

  function commentLine(c, p) {
    var cx = c.x + c.w / 2, cy = c.y + c.h / 2;
    var dx = p.x - cx, dy = p.y - cy;
    var sx = cx, sy = cy;
    if (dx || dy) {
      var t = Math.min(Math.abs((c.w / 2) / (dx || 1e-9)), Math.abs((c.h / 2) / (dy || 1e-9)));
      sx = cx + dx * t; sy = cy + dy * t;
    }
    return 'M' + r1(sx) + ',' + r1(sy) + 'L' + r1(p.x) + ',' + r1(p.y);
  }

  function drawBox(n) {
    var P = EX.PALETTE, st = n.st;
    var out = '';
    var fill = n.isRoot ? P.accent : (st.card ? P.surface2 : P.surface);
    var stroke = n.isRoot ? 'none' : (st.card ? P.accent : P.border);
    out += '<rect x="' + r1(n.x) + '" y="' + r1(n.y) + '" width="' + n.w + '" height="' + n.h + '" rx="' + Math.min(st.radius, n.h / 2) +
      '" fill="' + fill + '" stroke="' + stroke + '" stroke-width="1.5"/>';
    if (st.card) {
      out += '<rect x="' + r1(n.x) + '" y="' + r1(n.y + 1) + '" width="4" height="' + (n.h - 2) + '" rx="2" fill="' + P.accent + '"/>';
    }
    var tx = n.x + st.padX;
    var ty = n.y + st.padY;
    if (n.check) {
      var cy = ty + 2;
      out += '<rect x="' + r1(tx) + '" y="' + r1(cy) + '" width="16" height="16" rx="5" fill="' + (n.checked ? P.good : 'none') +
        '" stroke="' + (n.checked ? P.good : P.faint) + '" stroke-width="1.8"/>';
      if (n.checked) out += '<path d="M' + r1(tx + 4) + ',' + r1(cy + 8.5) + 'l3,3l5.5,-6" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>';
      tx += 16 + 7;
    }
    var ink = n.isRoot ? P.accentInk : (n.checked === true ? P.muted : (st.card ? P.text : P.text));
    var baseline = ty + n.st.size * 0.95;
    out += textBlock(tx, baseline, n.lines, st.size, st.weight, ink, n.lineH,
      n.checked === true ? ' text-decoration="line-through"' : '');
    if (n.preview && n.preview.length) {
      out += textBlock(n.x + st.padX, ty + n.lines.length * n.lineH + 3 + 11.5 * 0.95, n.preview, 11.5, 400, P.muted, 11.5 * 1.35);
    }
    if (n.pills && n.pills.length) {
      var total = 0;
      n.pills.forEach(function (pl) { total += pl.w + 5; });
      var px = n.x + n.w - st.padX - total + 5;
      var py = ty + (n.lineH - 16) / 2;
      n.pills.forEach(function (pl) {
        var bg = pl.kind === 'tasks' ? P.goodSoft : pl.kind === 'pinned' ? P.accentSoft : P.surface3;
        var fg = pl.kind === 'tasks' ? P.good : pl.kind === 'pinned' ? P.accent : P.muted;
        if (n.isRoot) { bg = 'rgba(255,255,255,0.24)'; fg = '#fff'; }
        out += '<rect x="' + r1(px) + '" y="' + r1(py) + '" width="' + pl.w + '" height="16" rx="8" fill="' + bg + '"/>';
        out += '<text x="' + r1(px + pl.w / 2) + '" y="' + r1(py + 11.5) + '" font-size="10.5" font-weight="700" fill="' + fg + '" text-anchor="middle">' + esc(pl.text) + '</text>';
        px += pl.w + 5;
      });
    }
    return out;
  }

  EX.svg = function (scene) {
    var P = EX.PALETTE;
    var out = '<svg xmlns="http://www.w3.org/2000/svg" width="' + scene.w + '" height="' + scene.h +
      '" viewBox="0 0 ' + scene.w + ' ' + scene.h + '" font-family="' + esc(EX.FONT) + '">';
    out += '<rect x="0" y="0" width="' + scene.w + '" height="' + scene.h + '" fill="' + P.bg + '"/>';
    out += '<g fill="none" stroke-linecap="round">';
    scene.edges.forEach(function (e) {
      out += '<path d="' + edgePath(e.from, e.to) + '" stroke="' + e.color + '" stroke-width="' + r1(e.width) + '"' +
        (e.pinned ? ' stroke-dasharray="2 5"' : '') + ' opacity="' + (e.card ? '0.55' : '0.8') + '"/>';
    });
    scene.links.forEach(function (l) {
      out += '<path d="' + edgePath(l.from, l.to) + '" stroke="' + P.muted + '" stroke-width="1.5" stroke-dasharray="5 5" opacity="0.5"/>';
    });
    scene.comments.forEach(function (c) {
      c.anchors.forEach(function (p) {
        out += '<path d="' + commentLine(c, p) + '" stroke="' + P.commentLine + '" stroke-width="1.3" stroke-dasharray="0.1 4.2" opacity="0.7"/>';
      });
    });
    out += '</g>';
    scene.nodes.forEach(function (n) { out += drawBox(n); });
    scene.cards.forEach(function (n) { out += drawBox(n); });
    scene.comments.forEach(function (c) {
      out += '<rect x="' + r1(c.x) + '" y="' + r1(c.y) + '" width="' + c.w + '" height="' + c.h + '" rx="7" fill="' + P.comment +
        '" stroke="' + P.commentBorder + '" stroke-width="1"/>';
      out += textBlock(c.x + 10, c.y + 7 + 12.5 * 0.95, c.lines, 12.5, 400, P.commentInk, c.lineH);
    });
    return out + '</svg>';
  };

  /* ----------------------------------------------------------------- png */

  // iOS caps a canvas around 16M pixels; beyond that drawImage silently fails.
  EX.MAX_PIXELS = 16 * 1000 * 1000;

  EX.pngScale = function (w, h, wanted) {
    var want = wanted || 2;
    var fit = Math.sqrt(EX.MAX_PIXELS / Math.max(1, w * h));
    return Math.max(0.25, Math.min(want, Math.floor(fit * 100) / 100));
  };

  EX.svgDataUri = function (svg) { return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg); };

  EX.png = function (svg, opts) {
    opts = opts || {};
    return new Promise(function (resolve, reject) {
      var m = /width="(\d+)" height="(\d+)"/.exec(svg);
      var w = m ? parseInt(m[1], 10) : 0, h = m ? parseInt(m[2], 10) : 0;
      if (!w || !h) return reject(new Error('the drawing has no size'));
      var scale = EX.pngScale(w, h, opts.scale);
      if (scale < 0.25) return reject(new Error('the map is too large to rasterise'));
      var img = new global.Image();
      img.onload = function () {
        try {
          var canvas = global.document.createElement('canvas');
          canvas.width = Math.round(w * scale);
          canvas.height = Math.round(h * scale);
          var ctx = canvas.getContext('2d');
          ctx.fillStyle = EX.PALETTE.bg;
          ctx.fillRect(0, 0, canvas.width, canvas.height);
          ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
          var url = canvas.toDataURL('image/png');
          var base64 = url.slice(url.indexOf(',') + 1);
          if (!base64) throw new Error('the canvas produced no image');
          resolve({ base64: base64, width: canvas.width, height: canvas.height, scale: scale, scaled: scale < (opts.scale || 2) });
        } catch (e) { reject(e); }
      };
      img.onerror = function () { reject(new Error('the drawing could not be rasterised')); };
      img.src = EX.svgDataUri(svg);
    });
  };

  EX.toBase64 = function (text) {
    var s = String(text == null ? '' : text);
    if (typeof global.btoa === 'function') return global.btoa(unescape(encodeURIComponent(s)));
    return Buffer.from(s, 'utf8').toString('base64');
  };

  /* ------------------------------------------------------------- formats */

  /*
   * The registry the export sheet lists. A writer takes the scene and the
   * document and resolves to { base64 } (binary) or { text } (textual), plus
   * whatever the toast might mention (width, height, scaled).
   */
  EX.formats = [];
  EX.register = function (f) {
    for (var i = 0; i < EX.formats.length; i++) {
      if (EX.formats[i].id === f.id) { EX.formats[i] = f; return f; }
    }
    EX.formats.push(f);
    return f;
  };
  EX.format = function (id) {
    for (var i = 0; i < EX.formats.length; i++) if (EX.formats[i].id === id) return EX.formats[i];
    return null;
  };

  EX.register({
    id: 'png', label: 'PNG image', sub: 'A picture of the whole map, expanded', ext: '.png', mime: 'image/png',
    write: function (scene, doc, opts) { return EX.png(EX.svg(scene), opts); }
  });

  /* ----------------------------------------------------------- filenames */

  EX.fileStem = function (title) {
    var t = String(title == null ? '' : title).replace(/[\/\\:*?"<>|\r\n\t]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 60);
    return (t || 'Map') + ' — map';
  };
  EX.fileName = function (title, ext) { return EX.fileStem(title) + ext; };

  function escapeRe(s) { return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

  // The host renames every saved file to <stem>_<uuid><ext>, so a previous
  // export is recognised by its human name or by that pattern - never by a
  // loose prefix, which would sweep up a user's own file.
  EX.isPreviousExport = function (att, stem, ext) {
    if (!att) return false;
    var name = String(att.fileName || '');
    if (name === stem + ext) return true;
    var base = String(att.path || '').split('/').pop();
    var re = new RegExp('^' + escapeRe(stem) + '_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' + escapeRe(ext) + '$');
    return re.test(base) || re.test(name);
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = CG;
})(typeof window !== 'undefined' ? window : globalThis);
