/*
 * Big Bang - exporting the board as a picture.
 *
 * Three layers, so a new format is one function and a new destination is
 * another - the same three Cartograph has, and for the same reasons:
 *
 *   board --scene()--> Scene --writer--> { base64 | text } --sink--> attached
 *
 * The SCENE is a plain description of the WHOLE board: every card, every link,
 * every annotation and every group frame, laid out from the board's own
 * coordinates. Focus is lifted, search is ignored, nothing is dimmed and the
 * camera is not consulted at all - a board that is zoomed into one corner
 * still exports all of it. It never reads the DOM, so it can be built and
 * asserted on in node.
 *
 * The WRITER turns a scene into bytes. The PNG writer draws it as SVG made of
 * <rect>, <path> and <text> only - no <foreignObject>, no CSS, no external
 * font file - because that is the subset an <img>-loaded SVG renders reliably
 * in a WebView with no network, which is the only way to rasterise on a phone
 * with no library. It is then drawn onto a canvas at 2x, and CAPPED: past
 * about sixteen million pixels drawImage quietly does nothing and the export
 * comes out blank, so a very large board is scaled down to fit and the toast
 * says so.
 *
 * The SINK attaches the result to the board note, replacing the previous one.
 * It lives in app.js, because it is the only part that asks the host anything.
 *
 * The palette is the LIGHT theme's, fixed, whatever the phone is set to. A
 * picture goes into a chat, a document or onto paper, and none of those has a
 * theme; a dark board exported dark is a black rectangle on a white page.
 */
(function (global) {
  'use strict';
  var BB = (global.BB = global.BB || {});
  var BOARD = BB.board;
  var M = BB.model;
  var EX = (BB.export = {});

  /* --------------------------------------------------------------- palette */

  // The :root block of big-bang.html, written out. Not read from the document:
  // the export must not depend on there being one, and must not change with
  // the theme.
  EX.PALETTE = {
    bg: '#f5f6f8', surface: '#ffffff', surface2: '#eef0f4', surface3: '#e4e7ee',
    text: '#191c22', muted: '#6b7280', faint: '#9aa1ae', border: '#e2e5ea',
    accent: '#4f6ef7', accentInk: '#ffffff', good: '#059669',
    sticky: '#fff6d5', stickyBorder: '#e8cf86', stickyInk: '#4a3a10',
    annotLine: '#c9a227',
    frame: '#7f899b',
    colours: {
      blue: '#4f6ef7', pink: '#e0559a', teal: '#0d9488', amber: '#d97706',
      violet: '#7c3aed', sky: '#2563eb', green: '#059669', rose: '#db2777'
    }
  };

  EX.FONT = '-apple-system, BlinkMacSystemFont, system-ui, "Segoe UI", Roboto, "Helvetica Neue", sans-serif';

  /*
   * A board's colour NAME to a colour. The `c` field is free text - board.js
   * keeps any non-empty string - so the same stripping the renderer does on
   * its way to a class name happens here on its way to a fill: anything that
   * is not one of the eight names is no colour at all, never a raw string
   * pasted into an attribute.
   */
  EX.colourOf = function (c) {
    var name = String(c == null ? '' : c).replace(/[^a-z]/gi, '').toLowerCase();
    return BOARD.has(EX.PALETTE.colours, name) ? EX.PALETTE.colours[name] : null;
  };

  /* ------------------------------------------------------------ typography */

  // Mirrors the .bb-card rules in big-bang.html: one entry per card kind, and
  // the numbers are the stylesheet's own.
  EX.STYLE = {
    note: {
      padX: 12, padY: 10, radius: 14, minH: 44,
      title: { size: 14, weight: 640, lh: 1.3, clamp: 2 },
      body: { size: 12, weight: 400, lh: 1.4, clamp: 3, gap: 5 },
      chip: { size: 11, h: 18, gap: 4, top: 7, padX: 6 }
    },
    sticky: {
      padX: 12, padY: 10, radius: 14, minH: 44,
      title: { size: 14, weight: 500, lh: 1.3, clamp: 8, pre: true }
    },
    annot: {
      padX: 10, padY: 8, radius: 14, minH: 36,
      title: { size: 13, weight: 500, lh: 1.3, clamp: 6, pre: true, italic: true }
    }
  };

  // The tick box on a task card: 17px, inset 10 from the card's top right, and
  // 26px of the title's width given up to it.
  EX.TICK = { size: 17, inset: 10, gutter: 26 };
  EX.LABEL = { size: 12, weight: 600, padX: 8, padY: 3, maxW: 190, lh: 1.35 };
  EX.TAB = { size: 12.5, weight: 650, padX: 14, minW: 44, minH: 30, maxW: 240 };

  EX.PAD = 48;

  function fontString(size, weight, italic) {
    return (italic ? 'italic ' : '') + weight + ' ' + size + 'px ' + EX.FONT;
  }
  EX.fontString = fontString;

  /*
   * measure(text, font) -> width in px.
   *
   * In a browser a canvas measures with the real font. In node an estimate
   * stands in, so the scene is testable with no DOM at all - it is only ever
   * wrong about where a line wraps, never about whether the picture exists.
   */
  EX.estimateMeasure = function (text, font) {
    var px = parseFloat(String(font).replace(/^(?:italic\s+)?\d+\s+/, '')) || 14;
    var w = 0;
    for (var i = 0; i < text.length; i++) {
      var c = text.charCodeAt(i);
      w += (c > 0x2e80 ? 1 : (c === 32 ? 0.28 : 0.55)) * px;
    }
    return w;
  };
  EX.canvasMeasure = function () {
    var ctx = null;
    try { ctx = global.document ? global.document.createElement('canvas').getContext('2d') : null; }
    catch (e) { ctx = null; }
    if (!ctx) return EX.estimateMeasure;
    return function (text, font) { ctx.font = font; return ctx.measureText(text).width; };
  };

  /*
   * Word wrap to maxW. A word wider than the line - a URL, a run of CJK with
   * no spaces in it - is broken by character, so nothing can overflow its box
   * and run across the card beside it.
   */
  EX.wrap = function (text, font, maxW, measure) {
    var words = String(text == null ? '' : text).split(/\s+/).filter(Boolean);
    if (!words.length) return [''];
    var lines = [], cur = '';
    words.forEach(function (w) {
      if (cur && measure(cur + ' ' + w, font) > maxW) { lines.push(cur); cur = ''; }
      if (measure(w, font) > maxW) {
        var piece = cur ? cur + ' ' : '';
        /*
         * By CHARACTER, not by code unit. `w.charAt(i)` cuts an emoji or a
         * CJK extension B ideograph in half, and half of a surrogate pair is
         * not a character: it draws as a box, and `encodeURIComponent` -
         * which is how the SVG becomes an image - throws `URIError` on it.
         * A long unbroken run of CJK is the realistic carrier, because it has
         * no spaces for the line above to break at.
         */
        var chars = BOARD.chars(w);
        for (var i = 0; i < chars.length; i++) {
          var ch = chars[i];
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

  /*
   * A block of text, wrapped and CLAMPED the way -webkit-line-clamp clamps it
   * on the card: the lines past the limit are dropped and the last one that
   * survives ends in an ellipsis, so the picture does not silently claim a
   * card said less than it does.
   *
   * `pre` keeps the user's own line breaks, which is what a sticky and an
   * annotation are drawn with (white-space: pre-wrap).
   */
  EX.block = function (text, style, maxW, measure) {
    var font = fontString(style.size, style.weight, style.italic);
    var src = String(text == null ? '' : text);
    var paras = style.pre ? src.split(/\r?\n/) : [src.replace(/\s+/g, ' ')];
    var lines = [];
    paras.forEach(function (p) {
      if (!p.replace(/\s+/g, '')) { lines.push(''); return; }
      lines = lines.concat(EX.wrap(p, font, maxW, measure));
    });
    while (lines.length && lines[lines.length - 1] === '') lines.pop();
    var clipped = false;
    if (style.clamp && lines.length > style.clamp) {
      lines = lines.slice(0, style.clamp);
      clipped = true;
      var last = lines[lines.length - 1];
      lines[lines.length - 1] = (last.replace(/\s+\S*$/, '') || last) + '…';
    }
    return { lines: lines, font: font, lineH: style.size * style.lh, clipped: clipped, size: style.size, weight: style.weight, italic: !!style.italic };
  };

  /* ----------------------------------------------------------------- scene */

  function r1(n) { return Math.round(n * 10) / 10; }
  EX.r1 = r1;

  /*
   * The shape of a line is BB.render's, CALLED rather than copied.
   *
   * These were the renderer's own functions written out again here, under a
   * comment claiming the picture and the screen could not drift apart because
   * the constants were shared. Only the constants were: the copy's `mid` - the
   * point a quadratic passes through at t = 0.5, which is (A + 2C + B) / 4 and
   * not the average of the endpoints - could be changed to the average with
   * the whole suite green, moving every label and every annotation anchored to
   * a link off the line in the picture and nowhere else.
   *
   * Now there is one implementation, and the only thing this file still says
   * about a curve is how it rounds the numbers.
   */
  function edgePoint(box, tx, ty) { return BB.render.edgePoint(box, tx, ty); }
  function curveOf(ba, bb) { return BB.render.curveBetween(ba, bb, r1); }

  // An arrowhead, as two strokes: it wears the link's own colour and weight
  // with no second fill rule, exactly as the renderer draws it.
  function headPath(tip, from) {
    var R = BB.render;
    var dx = tip[0] - from[0], dy = tip[1] - from[1];
    var len = Math.hypot(dx, dy) || 1;
    var ux = dx / len, uy = dy / len;
    var s = R.HEAD, w = s * 0.52;
    var bx = tip[0] - ux * s, by = tip[1] - uy * s;
    return 'M' + r1(bx - uy * w) + ',' + r1(by + ux * w) +
      'L' + r1(tip[0]) + ',' + r1(tip[1]) +
      'L' + r1(bx + uy * w) + ',' + r1(by - ux * w);
  }

  /*
   * scene(board, opts) -> everything the writers draw, in one flat object.
   *
   *   opts.faceOf   fn(itemId) -> the face the card shows (notes.js). Without
   *                 one the cards fall back to their stored labels, which is
   *                 what a board exported with no note cache would show.
   *   opts.measure  fn(text, font) -> width. Defaults to the estimate.
   *
   * Nothing else is read. There is deliberately no `focus`, no `query` and no
   * `lit`: the picture is of the board, not of the screen.
   */
  EX.scene = function (board, opts) {
    opts = opts || {};
    var P = EX.PALETTE;
    var R = BB.render;
    var measure = opts.measure || EX.estimateMeasure;
    var faceOf = opts.faceOf || null;
    if (!board) throw new Error('there is no board to draw');

    var ids = Object.keys(board.items);

    /* ---- sizes: what a card would lay out to, from its text alone ---- */

    var sizes = Object.create(null);
    var faces = Object.create(null);

    ids.forEach(function (id) {
      var it = board.items[id];
      var face = faceOf ? faceOf(id) : null;
      if (!face) {
        face = {
          kind: it.k, title: it.t || '', excerpt: '', tags: [],
          task: false, done: false, tomb: false, pending: false
        };
      }
      faces[id] = face;
      var st = EX.STYLE[it.k] || EX.STYLE.note;
      var w = R.widthOf(it);
      var inner = w - st.padX * 2;
      var titleW = inner - (face.task ? EX.TICK.gutter : 0);
      var title = EX.block(face.title || '', st.title, Math.max(20, titleW), measure);
      var h = st.padY * 2 + title.lines.length * title.lineH;
      var body = null, chips = null;
      if (it.k === 'note') {
        if (face.excerpt) {
          body = EX.block(face.excerpt, st.body, Math.max(20, inner), measure);
          h += st.body.gap + body.lines.length * body.lineH;
        }
        var names = [];
        if (face.tomb) names.push({ text: 'MISSING', state: true });
        (face.tags || []).slice(0, R.TAGS).forEach(function (t) {
          names.push({ text: String((t && t.name) || ''), state: false });
        });
        var over = (face.tags || []).length - Math.min((face.tags || []).length, R.TAGS);
        if (over > 0) names.push({ text: '+' + over, state: false });
        if (names.length) {
          chips = EX.chipRows(names, st.chip, inner, measure);
          h += st.chip.top + chips.rows.length * (st.chip.h + st.chip.gap) - st.chip.gap;
        }
      }
      sizes[id] = {
        w: w, h: Math.max(st.minH, Math.ceil(h)),
        st: st, title: title, body: body, chips: chips, face: face
      };
    });

    /* ---- where everything is: annotations resolve through their anchors ---- */

    var abs = Object.create(null);
    var geoms = Object.create(null);

    function boxAt(id, depth) {
      var p = absAt(id, depth);
      var s = sizes[id];
      if (!p || !s) return null;
      return { x: p[0], y: p[1], w: s.w, h: s.h };
    }

    function absAt(id, depth) {
      if (BOARD.has(abs, id)) return abs[id];
      abs[id] = null;                                    // in case of a cycle
      var it = BOARD.hasItem(board, id) ? board.items[id] : null;
      if (!it) return null;
      var out;
      /*
       * `reanchor` means `p` is an ABSOLUTE spot, not an offset - put there by
       * whoever dropped the anchor it used to be measured from. render.js
       * short-circuits on the flag for exactly this reason, and a copy that
       * did not would add the anchor's centre to a position that already is
       * one, moving the annotation and stretching the picture's bounds with it.
       */
      if (it.k !== 'annot' || it.reanchor || !it.at || !it.at.length || depth >= R.DEPTH) {
        out = (it.k === 'annot' && !it.reanchor && it.at && it.at.length && depth >= R.DEPTH) ? (it.q || it.p) : it.p;
      } else {
        var a = anchorAt(it.at[0], depth + 1);
        out = a ? [a[0] + it.p[0], a[1] + it.p[1]] : (it.q || it.p);
      }
      abs[id] = out;
      return out;
    }

    function anchorAt(a, depth) {
      if (!a) return null;
      if (a.i) {
        var b = boxAt(a.i, depth);
        return b ? [b.x + b.w / 2, b.y + b.h / 2] : null;
      }
      var g = geomOf(a.l, depth);
      return g ? g.mid : null;
    }

    function geomOf(linkId, depth) {
      if (BOARD.has(geoms, linkId)) return geoms[linkId];
      geoms[linkId] = null;
      var l = M.link(board, linkId);
      if (!l) return null;
      var ba = boxAt(l.a, depth || 0), bb = boxAt(l.b, depth || 0);
      if (!ba || !bb) return null;
      geoms[linkId] = curveOf(ba, bb);
      return geoms[linkId];
    }

    ids.forEach(function (id) { absAt(id, 0); });

    /* ---- group frames, from wherever their members are ---- */

    // R.frameOf, so a frame in the picture has the same air round it that the
    // frame on the screen has.
    function rectOf(g) {
      return R.frameOf(g.m.map(function (id) { return boxAt(id, 0); }));
    }

    /* ---- gather, in board coordinates; the shift to a top-left origin is
            applied once, at the end ---- */

    var bounds = null;
    function add(x0, y0, x1, y1) {
      if (!bounds) { bounds = { x0: x0, y0: y0, x1: x1, y1: y1 }; return; }
      bounds.x0 = Math.min(bounds.x0, x0); bounds.y0 = Math.min(bounds.y0, y0);
      bounds.x1 = Math.max(bounds.x1, x1); bounds.y1 = Math.max(bounds.y1, y1);
    }

    var groups = [], tabs = [];
    board.groups.forEach(function (g) {
      var r = rectOf(g);
      if (!r) return;
      var colour = EX.colourOf(g.c);
      groups.push({ x: r.x, y: r.y, w: r.w, h: r.h, colour: colour || P.faint });
      var name = g.t || 'Group';
      var tabFont = fontString(EX.TAB.size, EX.TAB.weight);
      var tw = Math.min(EX.TAB.maxW, Math.ceil(measure(name, tabFont) + EX.TAB.padX * 2));
      tabs.push({
        x: r.x + 10, y: r.y + 6, w: Math.max(EX.TAB.minW, tw), h: EX.TAB.minH,
        text: name, font: tabFont, colour: colour
      });
      add(r.x, r.y, r.x + r.w, r.y + r.h);
    });

    var links = [], labels = [];
    board.links.forEach(function (l) {
      var g = geomOf(l.i, 0);
      if (!g) return;
      var colour = EX.colourOf(l.c) || P.faint;
      // The POINTS, not a path: the whole scene is shifted to a top-left
      // origin once everything is gathered, and translating numbers is
      // straightforward while translating a path string is a regex over
      // somebody's coordinates.
      links.push({
        a: g.a.slice(), b: g.b.slice(), c: g.c.slice(), mid: g.mid.slice(),
        colour: colour, width: R.EDGE_W, dash: R.DASH[l.d] || null,
        heads: l.h === 'double' ? 2 : (l.h === 'arrow' ? 1 : 0),
        real: l.real === true
      });
      add(Math.min(g.a[0], g.b[0], g.c[0]), Math.min(g.a[1], g.b[1], g.c[1]),
        Math.max(g.a[0], g.b[0], g.c[0]), Math.max(g.a[1], g.b[1], g.c[1]));
      if (l.t) {
        var lb = EX.block(l.t, { size: EX.LABEL.size, weight: EX.LABEL.weight, lh: EX.LABEL.lh },
          EX.LABEL.maxW - EX.LABEL.padX * 2, measure);
        var lw = 0;
        lb.lines.forEach(function (line) { lw = Math.max(lw, measure(line, lb.font)); });
        var bw = Math.ceil(lw + EX.LABEL.padX * 2);
        var bh = Math.ceil(lb.lines.length * lb.lineH + EX.LABEL.padY * 2);
        // translate(-50%, -176%) on the handle's own point: centred on the
        // curve, lifted clear of it by R.LABEL_LIFT of its own height.
        var lx = g.mid[0] - bw / 2, ly = g.mid[1] - R.LABEL_LIFT * bh;
        labels.push({ x: lx, y: ly, w: bw, h: bh, block: lb, colour: EX.colourOf(l.c) });
        add(lx, ly, lx + bw, ly + bh);
      }
    });

    var leads = [];
    ids.forEach(function (id) {
      var it = board.items[id];
      if (it.k !== 'annot' || !it.at || !it.at.length) return;
      var box = boxAt(id, 0);
      if (!box) return;
      it.at.forEach(function (a) {
        var p = anchorAt(a, 1);
        if (!p) return;
        var s = edgePoint(box, p[0], p[1]);
        leads.push({ a: [s[0], s[1]], b: [p[0], p[1]], colour: EX.colourOf(it.c) || P.annotLine });
      });
    });

    var cards = [];
    // Annotations last, so they sit over what they point at - the z-index the
    // stylesheet gives them, expressed as paint order.
    ids.slice().sort(function (a, b) {
      return (board.items[a].k === 'annot' ? 1 : 0) - (board.items[b].k === 'annot' ? 1 : 0);
    }).forEach(function (id) {
      var it = board.items[id];
      var s = sizes[id];
      var p = absAt(id, 0);
      if (!s || !p) return;
      cards.push({
        id: id, kind: it.k, x: p[0], y: p[1], w: s.w, h: s.h,
        st: s.st, title: s.title, body: s.body, chips: s.chips,
        colour: EX.colourOf(it.c),
        tomb: !!s.face.tomb, task: !!s.face.task, done: !!s.face.done,
        blank: it.k !== 'note' && !it.t
      });
      add(p[0], p[1], p[0] + s.w, p[1] + s.h);
    });

    if (!bounds) throw new Error('there is nothing on this board to draw');

    var ox = -bounds.x0 + EX.PAD, oy = -bounds.y0 + EX.PAD;
    function shift(o) { o.x += ox; o.y += oy; }
    function move(p) { return [p[0] + ox, p[1] + oy]; }
    groups.forEach(shift);
    tabs.forEach(shift);
    labels.forEach(shift);
    cards.forEach(shift);
    links.forEach(function (l) {
      l.a = move(l.a); l.b = move(l.b); l.c = move(l.c); l.mid = move(l.mid);
      l.d = 'M' + r1(l.a[0]) + ',' + r1(l.a[1]) + ' Q' + r1(l.c[0]) + ',' + r1(l.c[1]) +
        ' ' + r1(l.b[0]) + ',' + r1(l.b[1]);
      var heads = [];
      if (l.heads >= 1) heads.push(headPath(l.b, l.c));
      if (l.heads >= 2) heads.push(headPath(l.a, l.c));
      l.heads = heads;
    });
    leads.forEach(function (l) {
      l.a = move(l.a); l.b = move(l.b);
      l.d = 'M' + r1(l.a[0]) + ',' + r1(l.a[1]) + 'L' + r1(l.b[0]) + ',' + r1(l.b[1]);
    });

    return {
      w: Math.ceil(bounds.x1 - bounds.x0 + EX.PAD * 2),
      h: Math.ceil(bounds.y1 - bounds.y0 + EX.PAD * 2),
      groups: groups, tabs: tabs, links: links, labels: labels, leads: leads, cards: cards
    };
  };

  /*
   * The chip row, wrapped. It is the one part of a card whose height depends
   * on how many things fit on a line, so it is laid out here rather than
   * guessed at.
   */
  EX.chipRows = function (names, chip, maxW, measure) {
    var font = fontString(chip.size, 700);
    var rows = [], cur = [], used = 0;
    names.forEach(function (n) {
      var w = Math.ceil(measure(n.text, font) + chip.padX * 2);
      if (w > maxW) w = maxW;
      if (cur.length && used + chip.gap + w > maxW) { rows.push(cur); cur = []; used = 0; }
      cur.push({ text: n.text, state: n.state, w: w });
      used += (used ? chip.gap : 0) + w;
    });
    if (cur.length) rows.push(cur);
    return { rows: rows, font: font };
  };

  /* ------------------------------------------------------------------- svg */

  /*
   * A string on its way into the SVG.
   *
   * Two jobs, and the second one is the one a note can fail the whole export
   * with. Markup characters become entities, so a title that looks like a tag
   * is text. And characters that are not legal XML at all are DROPPED first -
   * a C0 control (U+0001 arrives through a paste or an import) makes a
   * document that does not parse, and an <img> handed it fires `error` with
   * nothing to say; a lone surrogate makes `encodeURIComponent` throw outright
   * on its way to a data: URI. Either one, in one card's title, used to be
   * "The board could not be exported (URI malformed)" for the whole board.
   *
   * Every piece of text that reaches the picture goes through here - card
   * titles and bodies, chip names, link labels, group tabs - so this is the
   * one place the rule has to hold.
   */
  function esc(s) {
    return BOARD.xmlText(s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
  EX.esc = esc;

  function textBlock(x, y, block, fill, extra) {
    var out = '<text x="' + r1(x) + '" y="' + r1(y) + '" font-size="' + block.size +
      '" font-weight="' + block.weight + '" fill="' + fill + '"' +
      (block.italic ? ' font-style="italic"' : '') + (extra || '') + '>';
    block.lines.forEach(function (l, i) {
      out += '<tspan x="' + r1(x) + '" dy="' + (i ? r1(block.lineH) : 0) + '">' + esc(l) + '</tspan>';
    });
    return out + '</text>';
  }

  function dashAttr(dash) {
    return dash ? ' stroke-dasharray="' + r1(dash[0]) + ' ' + r1(dash[1]) + '"' : '';
  }

  function drawCard(c) {
    var P = EX.PALETTE, st = c.st;
    var fill = c.kind === 'sticky' ? P.sticky : (c.kind === 'annot' ? P.surface2 : (c.tomb ? P.surface2 : P.surface));
    var stroke = c.kind === 'sticky' ? P.stickyBorder : (c.tomb ? P.faint : P.border);
    var dashed = c.tomb || c.kind === 'annot';
    var out = '<rect x="' + r1(c.x) + '" y="' + r1(c.y) + '" width="' + c.w + '" height="' + c.h +
      '" rx="' + st.radius + '" fill="' + fill + '" stroke="' + stroke + '" stroke-width="1"' +
      (dashed ? ' stroke-dasharray="5 4"' : '') + '/>';
    // The `c` colour is a stripe down the left edge, never a fill: a tinted
    // card body cannot promise a legible excerpt, on screen or on paper.
    if (c.colour) {
      out += '<rect x="' + r1(c.x) + '" y="' + r1(c.y + 1) + '" width="3" height="' + r1(c.h - 2) +
        '" fill="' + c.colour + '"/>';
    }
    var ink = c.kind === 'sticky' ? P.stickyInk : (c.kind === 'annot' ? P.muted : (c.tomb || c.done ? P.muted : P.text));
    if (c.blank) ink = P.faint;
    var tx = c.x + st.padX;
    var ty = c.y + st.padY;
    out += textBlock(tx, ty + c.title.size * 0.95, c.title, ink,
      c.tomb ? ' text-decoration="line-through"' : '');
    var y = ty + c.title.lines.length * c.title.lineH;
    if (c.body) {
      out += textBlock(tx, y + st.body.gap + c.body.size * 0.95, c.body, P.muted);
      y += st.body.gap + c.body.lines.length * c.body.lineH;
    }
    if (c.chips) {
      var cy = y + st.chip.top;
      c.chips.rows.forEach(function (row) {
        var cx = tx;
        row.forEach(function (ch) {
          var bg = ch.state ? '#fdeaea' : P.surface2;
          var fg = ch.state ? '#b42318' : P.muted;
          out += '<rect x="' + r1(cx) + '" y="' + r1(cy) + '" width="' + ch.w + '" height="' + st.chip.h +
            '" rx="' + (st.chip.h / 2) + '" fill="' + bg + '" stroke="' + P.border + '" stroke-width="1"/>';
          out += '<text x="' + r1(cx + ch.w / 2) + '" y="' + r1(cy + st.chip.h / 2 + st.chip.size * 0.36) +
            '" font-size="' + st.chip.size + '" font-weight="700" fill="' + fg +
            '" text-anchor="middle">' + esc(ch.text) + '</text>';
          cx += ch.w + st.chip.gap;
        });
        cy += st.chip.h + st.chip.gap;
      });
    }
    if (c.task) {
      var bx = c.x + c.w - EX.TICK.inset - EX.TICK.size, by = c.y + EX.TICK.inset;
      out += '<rect x="' + r1(bx) + '" y="' + r1(by) + '" width="' + EX.TICK.size + '" height="' + EX.TICK.size +
        '" rx="4" fill="' + (c.done ? P.good : P.surface) + '" stroke="' + (c.done ? P.good : P.faint) +
        '" stroke-width="1.5"/>';
      if (c.done) {
        out += '<path d="M' + r1(bx + 4) + ',' + r1(by + 9) + 'l3,3l6,-6" fill="none" stroke="' + P.accentInk +
          '" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>';
      }
    }
    return out;
  }

  EX.svg = function (scene) {
    var P = EX.PALETTE;
    var out = '<svg xmlns="http://www.w3.org/2000/svg" width="' + scene.w + '" height="' + scene.h +
      '" viewBox="0 0 ' + scene.w + ' ' + scene.h + '" font-family="' + esc(EX.FONT) + '">';
    // Opaque, always, and light: the ground the whole picture stands on.
    out += '<rect x="0" y="0" width="' + scene.w + '" height="' + scene.h + '" fill="' + P.bg + '"/>';

    scene.groups.forEach(function (g) {
      out += '<rect x="' + r1(g.x) + '" y="' + r1(g.y) + '" width="' + r1(g.w) + '" height="' + r1(g.h) +
        '" rx="20" fill="' + P.frame + '" fill-opacity="0.06" stroke="' + g.colour +
        '" stroke-width="1.5" stroke-dasharray="6 5"/>';
    });

    out += '<g fill="none" stroke-linecap="round">';
    scene.links.forEach(function (l) {
      out += '<path d="' + l.d + '" stroke="' + l.colour + '" stroke-width="' + r1(l.width) + '"' +
        dashAttr(l.dash) + '/>';
      // A head is drawn solid whatever the line's dash: a dotted arrowhead is
      // three dots pointing vaguely somewhere.
      l.heads.forEach(function (d) {
        out += '<path d="' + d + '" stroke="' + l.colour + '" stroke-width="' + r1(l.width) + '"/>';
      });
    });
    scene.leads.forEach(function (l) {
      var R = BB.render;
      out += '<path d="' + l.d + '" stroke="' + l.colour + '" stroke-width="' + r1(R.LEAD_W) +
        '" stroke-dasharray="' + r1(R.LEAD_DASH[0]) + ' ' + r1(R.LEAD_DASH[1]) + '" opacity="0.85"/>';
    });
    out += '</g>';

    scene.cards.forEach(function (c) { out += drawCard(c); });

    // A link a real note relationship stands behind wears a solid dot, as it
    // does on its handle.
    scene.links.forEach(function (l) {
      if (!l.real) return;
      out += '<circle cx="' + r1(l.mid[0]) + '" cy="' + r1(l.mid[1]) + '" r="4.5" fill="' + P.good +
        '" stroke="' + P.bg + '" stroke-width="2"/>';
    });

    scene.labels.forEach(function (b) {
      out += '<rect x="' + r1(b.x) + '" y="' + r1(b.y) + '" width="' + b.w + '" height="' + b.h +
        '" rx="' + r1(Math.min(999, b.h / 2)) + '" fill="' + P.surface + '" stroke="' + (b.colour || P.border) +
        '" stroke-width="1"/>';
      out += textBlock(b.x + EX.LABEL.padX, b.y + EX.LABEL.padY + b.block.size * 0.95, b.block, P.muted);
    });

    scene.tabs.forEach(function (t) {
      out += '<rect x="' + r1(t.x) + '" y="' + r1(t.y) + '" width="' + t.w + '" height="' + t.h +
        '" rx="' + r1(t.h / 2) + '" fill="' + P.surface + '" stroke="' + (t.colour || P.border) +
        '" stroke-width="1"/>';
      out += '<text x="' + r1(t.x + t.w / 2) + '" y="' + r1(t.y + t.h / 2 + EX.TAB.size * 0.36) +
        '" font-size="' + EX.TAB.size + '" font-weight="' + EX.TAB.weight + '" fill="' +
        (t.colour || P.muted) + '" text-anchor="middle">' + esc(t.text) + '</text>';
    });

    return out + '</svg>';
  };

  /* ------------------------------------------------------------------- png */

  /*
   * The canvas ceiling. iOS caps a canvas at roughly sixteen million pixels
   * and, past it, drawImage does nothing AND THROWS NOTHING: the export comes
   * back as a blank rectangle of the right size. So the scale is chosen to fit
   * under the cap rather than trusted to 2x, and a scene that had to be scaled
   * says so, because a picture quietly rendered at half the resolution asked
   * for is a thing the user should be told about.
   */
  EX.MAX_PIXELS = 16 * 1000 * 1000;
  EX.SCALE = 2;
  EX.TIMEOUT = 30000;
  EX.MIN_SCALE = 0.25;

  EX.pngScale = function (w, h, wanted) {
    var want = wanted || EX.SCALE;
    var fit = Math.sqrt(EX.MAX_PIXELS / Math.max(1, w * h));
    return Math.max(0.05, Math.min(want, Math.floor(fit * 100) / 100));
  };

  /*
   * The drawing as something an <img> can be pointed at.
   *
   * `xmlText` again, and not because `esc` missed anything: this call is the
   * one that THROWS. Every string in the document already came through `esc`,
   * but this is the last gate before `encodeURIComponent`, and a `URIError`
   * here is an export that fails for the whole board with a message naming
   * neither the card nor the character. One scan of an already-clean string
   * costs a regex test.
   */
  EX.svgDataUri = function (svg) {
    return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(BOARD.xmlText(svg));
  };

  EX.png = function (svg, opts) {
    opts = opts || {};
    return new Promise(function (resolve, reject) {
      var m = /width="(\d+)" height="(\d+)"/.exec(svg);
      var w = m ? parseInt(m[1], 10) : 0, h = m ? parseInt(m[2], 10) : 0;
      if (!w || !h) return reject(new Error('the drawing has no size'));
      var want = opts.scale || EX.SCALE;
      var scale = EX.pngScale(w, h, want);
      if (scale < EX.MIN_SCALE) return reject(new Error('this board is too large to draw as one picture'));
      if (!global.Image || !global.document) return reject(new Error('there is nothing here to draw on'));
      /*
       * A bounded wait, for the same reason the AI call has one: an <img>
       * given a data: URI normally fires load or error, and an engine that
       * fires NEITHER would leave this promise outstanding for ever - and with
       * it the flag that says an export is in flight, so every later export
       * would be refused for the life of the board.
       */
      var settled = false;
      var timer = setTimeout(function () {
        if (settled) return;
        settled = true;
        reject(new Error('the drawing took too long to rasterise'));
      }, opts.timeout || EX.TIMEOUT);
      function fail(e) { if (settled) return; settled = true; clearTimeout(timer); reject(e); }
      function done(v) { if (settled) return; settled = true; clearTimeout(timer); resolve(v); }
      var img = new global.Image();
      img.onload = function () {
        try {
          var canvas = global.document.createElement('canvas');
          canvas.width = Math.round(w * scale);
          canvas.height = Math.round(h * scale);
          var ctx = canvas.getContext('2d');
          // Opaque, whatever the SVG did: a PNG with an alpha channel reads as
          // a hole in a chat that draws it on a dark ground.
          ctx.fillStyle = EX.PALETTE.bg;
          ctx.fillRect(0, 0, canvas.width, canvas.height);
          ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
          var url = canvas.toDataURL('image/png');
          var base64 = url.slice(url.indexOf(',') + 1);
          if (!base64) throw new Error('the canvas produced no image');
          done({
            base64: base64, width: canvas.width, height: canvas.height,
            scale: scale, scaled: scale < want
          });
        } catch (e) { fail(e); }
      };
      img.onerror = function () { fail(new Error('the drawing could not be rasterised')); };
      img.src = EX.svgDataUri(svg);
    });
  };

  /* --------------------------------------------------------------- formats */

  /*
   * The registry the export bar lists. A writer takes the scene and resolves
   * to `{ base64 }` plus whatever the toast might mention; a format whose
   * bytes are text - an SVG file, say - encodes them in its own `write`, which
   * is one line there rather than a second shape for every caller of every
   * writer to handle. PNG is the only one in v1: another format is one more
   * entry here and nothing else anywhere.
   */
  EX.formats = [];
  EX.register = function (f) { EX.formats.push(f); return f; };
  EX.format = function (id) {
    for (var i = 0; i < EX.formats.length; i++) if (EX.formats[i].id === id) return EX.formats[i];
    return null;
  };

  EX.register({
    id: 'png', label: 'PNG image', sub: 'A picture of the whole board',
    ext: '.png', mime: 'image/png',
    write: function (scene, opts) { return EX.png(EX.svg(scene), opts); }
  });

  /* ------------------------------------------------------------- filenames */

  /*
   * `<Title> — board.png`, and the stem is what a previous export is
   * recognised by. Characters a file system will not take are dropped rather
   * than escaped: this is a name, not a path, and nothing downstream is going
   * to un-escape it.
   */
  // The half of the name that is not the title, and the half that identifies
  // an export as one. Every picture this app has ever written ends in it.
  EX.SUFFIX = ' — board';

  EX.fileStem = function (title) {
    var t = String(title == null ? '' : title)
      .replace(/[\/\\:*?"<>|\r\n\t]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 60);
    return (t || 'Board') + EX.SUFFIX;
  };
  EX.fileName = function (title, ext) { return EX.fileStem(title) + (ext || '.png'); };

  function escapeRe(s) { return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

  /*
   * Was this file a previous export of THIS BOARD's note?
   *
   * The host renames everything it saves to `<stem>_<uuid><ext>`, so the
   * stored name is never the name that was sent; matching the uuid form is
   * what finds the last export on a real phone. The plain form is kept for a
   * host that does not rename.
   *
   * What is deliberately NOT in the test is the note's TITLE. The stem is
   * built from it, and a note can be renamed - after which a match on this
   * board's current stem finds nothing, the old picture stays, a second one
   * lands beside it, and every later rename adds another. The same window
   * opens for a moment on a `?board=<id>` launch, where the title is not known
   * until a query comes back. So an export is recognised by the SUFFIX every
   * one of them carries, whatever the note was called when it was written.
   *
   * That is still not a prefix match, which is the thing this must never
   * become: `<anything>` here has to be followed by ` — board` and then by
   * the extension or by a uuid and the extension. A user's own file is swept
   * up only if they named it, exactly, the way this app names its pictures.
   */
  var UUID = '_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';

  EX.isPreviousExport = function (att, ext) {
    if (!att) return false;
    var e = ext || '.png';
    var name = String(att.fileName || '');
    var base = String(att.path || '').split('/').pop();
    var re = new RegExp('^.+' + escapeRe(EX.SUFFIX) + '(?:' + UUID + ')?' + escapeRe(e) + '$');
    return re.test(base) || re.test(name);
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = BB;
})(typeof window !== 'undefined' ? window : globalThis);
