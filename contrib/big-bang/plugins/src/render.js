/*
 * Big Bang - drawing the scene.
 *
 * The board is DOM over SVG: one absolutely-positioned card per item inside a
 * single transformed scene, an <svg> under them holding every line, a frame
 * layer under that for groups, and a layer over everything for the affordances
 * that must stay a thumb's width whatever the zoom. Cards are DOM because they
 * hold real text that has to wrap, select and stay legible at any zoom; edges
 * are SVG because they are geometry.
 *
 * Six things here are load-bearing:
 *
 *   One transform moves everything. Pan and zoom are a single transform on the
 *   scene, so a drag of the background touches one style on one element rather
 *   than repositioning every card. Cards carry only their own board position.
 *
 *   Affordances counter-scale. The scene sets --inv to 1/zoom, and every handle
 *   and chip multiplies itself by it, so a grip stays a grip at 0.4x. They are
 *   affordances, not diagram content: a 44px target that shrinks to 17px when
 *   the board is zoomed out is not a target at all. Lines counter-scale too,
 *   but in JS rather than CSS: `vector-effect:non-scaling-stroke` compensates
 *   only for transforms INSIDE an SVG, and this SVG is scaled by a CSS
 *   transform on an HTML ancestor, which it cannot see. Every stroke width,
 *   dash length and arrowhead below is therefore multiplied by `inv` at draw
 *   time, and `deco()` is re-run whenever the zoom changes.
 *
 *   Elements are reused, never rebuilt. sync() patches the cards that changed
 *   and leaves the rest alone; a render in the middle of a drag must not swap
 *   the element out from under the finger holding it, and it must never blow
 *   away a contentEditable that has the caret in it. The SVG is the exception:
 *   nothing in it is ever typed into or held, so it is rebuilt wholesale.
 *
 *   Note content never becomes markup. Every string from a note - or from a
 *   sticky, a link label or a group name - goes in with textContent. There is
 *   no innerHTML path a title or an excerpt can reach, which is why a note
 *   called <img onerror=...> is simply a card with a funny name.
 *
 *   An anchored annotation has no position of its own. Its `p` is an offset
 *   from whatever it points at, so where it IS can only be answered by the
 *   thing that knows where everything else is - this file. `absOf` is that
 *   answer, and `settle` is the small amount of writing back that follows from
 *   it: converting an offset measured from an anchor that has since died, and
 *   keeping `q` - the last spot it was really drawn at - honest.
 *
 *   A line is not a touch target. A 1.7px curve and a dotted leader both carry
 *   a second, invisible, much fatter stroke for the finger, and a link also
 *   gets a counter-scaling handle at the point the curve actually passes
 *   through - which for the quadratic used here is NOT the average of the
 *   endpoints, so it is computed rather than assumed.
 */
(function (global) {
  'use strict';
  var BB = (global.BB = global.BB || {});
  var BOARD = BB.board, M = BB.model, I18n = BB.i18n;
  var R = (BB.render = {});
  function tr(text) { return I18n ? I18n.text(text) : text; }

  var SVGNS = 'http://www.w3.org/2000/svg';

  R.W = { note: 220, sticky: 180, annot: 170 };
  R.MIN_W = 120;
  R.MAX_W = 460;

  /*
   * How far an affordance may grow when the board is zoomed out, and why it is
   * this number and not a rounder one.
   *
   * --inv is 1/zoom, so a 44px grip holds 44px on screen for as long as the
   * multiplier is allowed to keep up. Cap it below 1/zoom and the grip starts
   * shrinking again: at the old cap of 2.6 it stopped counter-scaling at
   * k = 0.385 and measured 17px at the zoom floor - the exact failure the
   * mechanism exists to prevent, on the one platform this ships to.
   *
   * The floor is the gesture layer's MIN_Z, which is the smallest zoom a finger
   * can reach, so the cap is its reciprocal. It is written here rather than
   * read from BB.gestures because render.js loads first; the two are asserted
   * against each other in the suite so they cannot drift apart.
   */
  R.MIN_K = 0.15;                 // must equal gestures.js G.MIN_Z
  R.MAX_INV = 1 / R.MIN_K;        // 6.667 - 44px stays 44px all the way down
  R.TAGS = 4;                     // chips on a card before the rest are a count

  /* ------------------------------------------------------------ line sizes */

  // Screen pixels, every one of them: each is multiplied by `inv` on the way
  // into the SVG, so these are what the user actually sees at any zoom.
  R.EDGE_W = 1.7;                 // a drawn link
  R.PROP_W = 2;                   // ... and one the AI has only suggested
  R.LEAD_W = 1.4;                 // an annotation's leader
  R.HIT_W = 26;                   // and what the finger gets instead
  R.HEAD = 11;                    // arrowhead length
  R.DASH = { solid: null, dashed: [7, 5], dotted: [0.6, 4.4] };
  R.LEAD_DASH = [0.6, 5];         // deliberately unlike any link dash
  R.BOW = 0.16;                   // how far a link bows out, as a fraction
  R.MAX_BOW = 46;
  /*
   * How far a link's label sits above its handle, as a multiple of its own
   * height. It is exported because app.js has to answer where that label is on
   * screen for the keyboard-follow, and the only way to know is to apply the
   * same number the transform below applies. Written twice, it drifted.
   */
  R.LABEL_LIFT = 1.76;
  R.GROUP_PAD = 22;               // board units of air inside a group frame
  R.GROUP_TOP = 14;               // ... and extra at the top, under the tab
  // How deep an annotation anchored to an annotation may go before the chain
  // is declared circular. Nothing forbids such a chain, and nothing should
  // hang because somebody made one.
  R.DEPTH = 5;

  R.widthOf = function (it) {
    var w = it && typeof it.w === 'number' && isFinite(it.w) && it.w > 0 ? it.w : R.W[it && it.k] || R.W.note;
    return Math.max(R.MIN_W, Math.min(R.MAX_W, Math.round(w)));
  };

  function el(tag, cls) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    return e;
  }
  function svg(tag, cls) {
    var e = document.createElementNS(SVGNS, tag);
    if (cls) e.setAttribute('class', cls);
    return e;
  }
  function r2(n) { return Math.round(n * 100) / 100; }

  /*
   * A colour name on its way into a class name. The `c` field is free text in
   * the format - board.js keeps any non-empty string - so it is the one value
   * from a board that reaches CSS rather than textContent, and everything that
   * is not a plain word is dropped rather than escaped. `red;background:url(x)`
   * becomes `c-redbackgroundurlx`, which names no rule and does nothing.
   *
   * TWO classes come back: `col` says "this thing wears a colour" and `c-<name>`
   * says which. The stylesheet turns the name into a --c custom property once
   * and every rule that wears a colour reads --c, so the eight-way block that
   * used to be repeated for cards, lines, handles, frames and tabs is one line
   * per colour instead of five.
   */
  R.colourClass = function (c) {
    var s = String(c == null ? '' : c).replace(/[^a-z]/gi, '');
    return s ? 'col c-' + s : '';
  };

  function dashOf(d, inv) {
    var a = R.DASH[d];
    return a ? r2(a[0] * inv) + ' ' + r2(a[1] * inv) : '';
  }

  /* ================================================================ */
  /* the geometry, once                                               */
  /* ================================================================ */

  /*
   * Where a line goes, given the boxes at its ends. Three functions, at module
   * scope and outside R.make()'s closure, because they are the whole of what
   * the SCREEN and the PICTURE have to agree about.
   *
   * They used to be written twice - here inside the renderer, and again inside
   * BB.export's scene - with a comment in the copy saying the two could not
   * drift apart because they shared the constants. Only the constants were
   * shared. The `mid` formula is the one that matters and is the one that is
   * easiest to get wrong in a copy: for a quadratic the point the curve passes
   * through at t = 0.5 is (A + 2C + B) / 4, NOT the average of the endpoints,
   * and a copy that used the average put every link's handle, every label and
   * every anchored annotation somewhere the line does not go.
   *
   * Nothing here knows what a board is. They take boxes and return numbers, so
   * both callers can hand them whatever they already know about sizes: the
   * renderer measures elements, the export lays text out from scratch.
   */

  // Where a ray from the centre of a box towards a point leaves that box.
  R.edgePoint = function (box, tx, ty) {
    var cx = box.x + box.w / 2, cy = box.y + box.h / 2;
    var dx = tx - cx, dy = ty - cy;
    if (!dx && !dy) return [cx, cy];
    var sx = dx ? (box.w / 2) / Math.abs(dx) : Infinity;
    var sy = dy ? (box.h / 2) / Math.abs(dy) : Infinity;
    var t = Math.min(sx, sy);
    return [cx + dx * t, cy + dy * t];
  };

  /*
   * The link between two boxes: one quadratic bowed out to the side, so two
   * cards with a link each way do not draw the same line twice and so a link
   * is never mistaken for an annotation's straight leader.
   *
   * `round` is how the path string is rounded, which is the one thing the two
   * callers genuinely differ about - the screen rounds to 1/100 of a board
   * unit, the picture to 1/10 of a pixel - and it changes nothing about where
   * the line is.
   */
  R.curveBetween = function (ba, bb, round) {
    var rn = round || function (n) { return n; };
    var A = R.edgePoint(ba, bb.x + bb.w / 2, bb.y + bb.h / 2);
    var B = R.edgePoint(bb, ba.x + ba.w / 2, ba.y + ba.h / 2);
    var dx = B[0] - A[0], dy = B[1] - A[1];
    var len = Math.hypot(dx, dy) || 1;
    var bow = Math.min(R.MAX_BOW, len * R.BOW);
    var C = [(A[0] + B[0]) / 2 - (dy / len) * bow, (A[1] + B[1]) / 2 + (dx / len) * bow];
    return {
      a: A, b: B, c: C,
      mid: [(A[0] + 2 * C[0] + B[0]) / 4, (A[1] + 2 * C[1] + B[1]) / 4],
      d: 'M' + rn(A[0]) + ',' + rn(A[1]) + ' Q' + rn(C[0]) + ',' + rn(C[1]) + ' ' + rn(B[0]) + ',' + rn(B[1])
    };
  };

  /*
   * The frame a group draws, from the boxes of whatever its members are. A
   * group has no stored geometry at all: move a member and the frame follows,
   * which is the whole of what a frame means. Boxes that could not be resolved
   * are the caller's to leave out; a group with none of them has no frame.
   */
  R.frameOf = function (boxes) {
    var out = null;
    (boxes || []).forEach(function (b) {
      if (!b) return;
      if (!out) { out = { x0: b.x, y0: b.y, x1: b.x + b.w, y1: b.y + b.h }; return; }
      out.x0 = Math.min(out.x0, b.x); out.y0 = Math.min(out.y0, b.y);
      out.x1 = Math.max(out.x1, b.x + b.w); out.y1 = Math.max(out.y1, b.y + b.h);
    });
    if (!out) return null;
    return {
      x: out.x0 - R.GROUP_PAD,
      y: out.y0 - R.GROUP_PAD - R.GROUP_TOP,
      w: (out.x1 - out.x0) + R.GROUP_PAD * 2,
      h: (out.y1 - out.y0) + R.GROUP_PAD * 2 + R.GROUP_TOP
    };
  };

  R.make = function (opts) {
    var elScene = opts.scene, elCards = opts.cards, elEdges = opts.edges;
    var elGroups = opts.groups, elHandles = opts.handles;
    var els = Object.create(null);
    var gels = Object.create(null);        // groupId -> frame element
    var hels = Object.create(null);        // linkId/groupId -> handle element
    var lels = Object.create(null);        // linkId -> label element
    var phels = Object.create(null);       // proposalId -> its dismiss handle
    var plels = Object.create(null);       // proposalId -> its label
    var ghost = Object.create(null);       // id -> [x, y] while a drag is in flight
    var wghost = Object.create(null);      // id -> width while a resize is in flight
    var geoms = Object.create(null);       // linkId -> geometry, one draw pass only
    var sizes = Object.create(null);       // id -> laid-out size, one draw pass only
    var cam = { tx: 0, ty: 0, k: 1 };
    var rubber = null;                     // the line a link-drag is trailing

    function inv() { return Math.min(R.MAX_INV, 1 / (cam.k || 1)); }

    /* ------------------------------------------------------------ geometry */

    /*
     * Size of an item, from the element that is laying it out. offsetWidth is
     * a laid-out value, not a painted one, so it is honest mid-transition -
     * which getBoundingClientRect is not.
     *
     * Cached for the length of one draw pass, alongside `geoms` and cleared
     * with it. Nothing inside a pass changes a card's size - drawGroups,
     * drawEdges and drawHandles only write to frames, lines and handles - and
     * without the cache a card referenced by a link and two frames was measured
     * five or six times, each read forced after a write to a sibling and so
     * each one a fresh layout. dragMove runs the whole of deco() at pointer-move
     * rate; this is where that cost was.
     */
    function sizeOf(id, it) {
      if (BOARD.has(sizes, id)) return sizes[id];
      var e = els[id];
      var w = e ? (wghost[id] != null ? wghost[id] : e.offsetWidth) : 0;
      var s = {
        w: w || (wghost[id] != null ? wghost[id] : R.widthOf(it)),
        h: (e && e.offsetHeight) || 60
      };
      sizes[id] = s;
      return s;
    }

    /*
     * Where an item actually is on the plane.
     *
     *   a drag in flight wins over everything - it is what the finger says
     *   an unanchored item is simply its own `p`
     *   an anchored annotation is its first anchor's centre, plus `p`
     *   one flagged `reanchor` has an ABSOLUTE `p` measured against an anchor
     *     that has gone; it stays there until settle() re-measures it
     *   one whose first anchor cannot be resolved at all falls back to `q`,
     *     the last spot it was really drawn at
     */
    function absAt(board, id, depth) {
      var it = BOARD.hasItem(board, id) ? board.items[id] : null;
      if (!it) return null;
      if (ghost[id]) return ghost[id];
      if (it.k !== 'annot' || it.reanchor || !it.at || !it.at.length) return it.p;
      if (depth >= R.DEPTH) return it.q || it.p;
      var a = anchorAt(board, it.at[0], depth + 1);
      if (!a) return it.q || it.p;
      return [a[0] + it.p[0], a[1] + it.p[1]];
    }

    function boxAt(board, id, depth) {
      var it = BOARD.hasItem(board, id) ? board.items[id] : null;
      if (!it) return null;
      var p = absAt(board, id, depth);
      if (!p) return null;
      var s = sizeOf(id, it);
      return { x: p[0], y: p[1], w: s.w, h: s.h };
    }

    // What an anchor points at, as a single point: the centre of an item, or
    // the point a link's curve passes through.
    function anchorAt(board, a, depth) {
      if (!a) return null;
      if (a.i) {
        var b = boxAt(board, a.i, depth);
        return b ? [b.x + b.w / 2, b.y + b.h / 2] : null;
      }
      var g = geomOf(board, a.l, depth);
      return g ? g.mid : null;
    }

    // The shared one. Named here because this file's own drawing code calls it
    // by the short name in a dozen places.
    var edgePoint = R.edgePoint;

    /*
     * A link, as geometry: R.curveBetween, memoised for one draw pass. The
     * shape itself lives at module scope, where the export reads it too.
     */
    function geomOf(board, linkId, depth) {
      if (BOARD.has(geoms, linkId)) return geoms[linkId];
      var l = M.link(board, linkId);
      if (!l) { geoms[linkId] = null; return null; }
      return curveOf(board, linkId, l.a, l.b, depth || 0);
    }

    /*
     * The same curve, between two items named directly rather than by a link.
     *
     * A suggested link is not on the board and has no link row to look up, but
     * it is drawn exactly where a real one between those two cards would be -
     * which is the whole of what a preview promises. `key` is its own id, and
     * a proposal's id can never collide with a link's (see ai.js).
     */
    function curveOf(board, key, aId, bId, depth) {
      if (BOARD.has(geoms, key)) return geoms[key];
      geoms[key] = null;                          // in case of a cycle
      var ba = boxAt(board, aId, depth || 0), bb = boxAt(board, bId, depth || 0);
      if (!ba || !bb) return null;
      geoms[key] = R.curveBetween(ba, bb, r2);
      return geoms[key];
    }

    // The frame a group draws, from wherever its members are right now.
    function rectOf(board, groupId) {
      var g = M.group(board, groupId);
      if (!g) return null;
      return R.frameOf(g.m.map(function (id) { return boxAt(board, id, 0); }));
    }

    var api = {
      els: els,
      cam: cam,
      edges: elEdges,

      el: function (id) { return els[id] || null; },
      handle: function (id) { return hels[id] || null; },
      label: function (id) { return lels[id] || null; },
      frame: function (id) { return gels[id] || null; },

      /* ---------------------------------------------------------- camera */

      setCamera: function (tx, ty, k) {
        // A zoom that is not a positive finite number would be rejected by the
        // model's setters and would leave the board looking frozen rather than
        // broken, so it never gets this far.
        if (!isFinite(tx) || !isFinite(ty) || !isFinite(k) || k <= 0) return false;
        cam.tx = tx; cam.ty = ty; cam.k = k;
        elScene.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + k + ')';
        elScene.style.setProperty('--inv', String(inv()));
        return true;
      },

      /* ------------------------------------------------------ live drags */

      // Move a card without touching the model. The model is written once, at
      // the end of the gesture, so one drag of nine cards is one undo step.
      ghost: function (id, x, y) {
        var e = els[id];
        if (!e) return;
        ghost[id] = [x, y];
        e.style.transform = 'translate(' + x + 'px,' + y + 'px)';
      },
      ghostWidth: function (id, w) {
        var e = els[id];
        if (!e) return;
        wghost[id] = w;
        e.style.width = w + 'px';
        delete sizes[id];               // it is a different size now
      },
      ghostOf: function (id) { return ghost[id] || null; },
      clearGhosts: function () {
        ghost = Object.create(null);
        wghost = Object.create(null);
        sizes = Object.create(null);
      },

      /*
       * The line a link-drag trails behind the finger. It is drawn straight and
       * accented rather than as the curve it will become: what matters while
       * the finger is moving is which two things it joins, not what the final
       * line looks like.
       */
      rubber: function (from, x, y) {
        if (!rubber) {
          rubber = svg('path', 'bb-rubber');
          rubber.setAttribute('fill', 'none');
          elEdges.appendChild(rubber);
        }
        rubber.setAttribute('stroke-width', r2(2 * inv()));
        rubber.setAttribute('stroke-dasharray', dashOf('dashed', inv()));
        rubber.setAttribute('d', 'M' + r2(from[0]) + ',' + r2(from[1]) + 'L' + r2(x) + ',' + r2(y));
        rubber.removeAttribute('hidden');
      },
      clearRubber: function () {
        if (rubber && rubber.parentNode) rubber.parentNode.removeChild(rubber);
        rubber = null;
      },

      /* ------------------------------------------------------------ boxes */

      // An item's box in BOARD coordinates, anchors resolved.
      box: function (board, id) { return boxAt(board, id, 0); },
      absOf: function (board, id) { return absAt(board, id, 0); },
      geomOf: function (board, linkId) { return geomOf(board, linkId, 0); },
      rectOf: function (board, groupId) { return rectOf(board, groupId); },

      // Where an annotation's first anchor is - the origin its `p` is measured
      // from. Null when it has none, or when nothing resolves.
      anchorOrigin: function (board, id) {
        var it = BOARD.hasItem(board, id) ? board.items[id] : null;
        if (!it || it.k !== 'annot' || !it.at || !it.at.length) return null;
        return anchorAt(board, it.at[0], 1);
      },

      /*
       * Which item is under a board point, topmost first. Used by the link
       * drag to decide what the finger is over. It is the app's own geometry
       * rather than document.elementFromPoint for the reason every other
       * measurement here avoids the DOM: a rect read mid-transition is a lie,
       * and this has to be right on the frame the finger lifts.
       */
      hitItem: function (board, x, y, skip) {
        var out = null;
        drawOrder(board).forEach(function (id) {
          if (id === skip) return;
          var b = boxAt(board, id, 0);
          if (!b) return;
          if (x < b.x || x > b.x + b.w || y < b.y || y > b.y + b.h) return;
          out = id;                       // later in DRAW order wins: it is on top
        });
        return out;
      },

      // Everything on the board, as one box. Null when the board is empty.
      // Group frames count: a frame drawn round the edge of the board is part
      // of what "fit the board" has to show.
      bounds: function (board) {
        var out = null;
        function add(x0, y0, x1, y1) {
          if (!out) { out = { x0: x0, y0: y0, x1: x1, y1: y1 }; return; }
          out.x0 = Math.min(out.x0, x0); out.y0 = Math.min(out.y0, y0);
          out.x1 = Math.max(out.x1, x1); out.y1 = Math.max(out.y1, y1);
        }
        Object.keys(board.items).forEach(function (id) {
          var b = boxAt(board, id, 0);
          if (b) add(b.x, b.y, b.x + b.w, b.y + b.h);
        });
        board.groups.forEach(function (g) {
          var r = rectOf(board, g.i);
          if (r) add(r.x, r.y, r.x + r.w, r.y + r.h);
        });
        return out;
      },

      /* ------------------------------------------------------------- sync */

      /*
       * Draw the board. ctx carries everything that is not the board itself:
       *   ctx.cache       the note cache (titles, excerpts, tombstones)
       *   ctx.sel         { itemId: true }
       *   ctx.selectMode  multi-selection is on
       *   ctx.dragging    ids being dragged right now, left where they are
       *   ctx.linkSel     the link whose bar is open
       *   ctx.groupSel    the group whose bar is open
       *   ctx.editing     the id whose text is being typed into RIGHT NOW; its
       *                   element is left completely alone
       *   ctx.readOnly    no ports, no grips: a board that cannot be edited
       *   ctx.lit         search or focus is on, and these are the ids that
       *                   stay bright; everything else on the board is dimmed.
       *                   Absent (or null) means the whole board is lit, which
       *                   is not the same as an empty set - that one dims
       *                   everything, and is what a search matching nothing
       *                   looks like.
       *   ctx.proposals   links the AI has suggested and nobody has accepted:
       *                   [{ i, a, b, t }]. They are drawn over the board and
       *                   are not in it - no link row, no undo step, nothing
       *                   the note is ever written with.
       */
      sync: function (board, ctx) {
        ctx = ctx || {};
        geoms = Object.create(null); sizes = Object.create(null);
        paintCards(board, ctx);
        settle(board);
        // paintCards wrote widths and text, so both caches are stale.
        geoms = Object.create(null); sizes = Object.create(null);
        api.deco(board, ctx);
        return els;
      },

      /*
       * Everything that is derived from where the cards are: frames, lines,
       * handles. Re-run on its own during a drag (the cards are being ghosted,
       * not re-synced) and whenever the ZOOM changes, since every stroke width
       * and arrowhead below is in board units scaled by 1/zoom.
       */
      deco: function (board, ctx) {
        ctx = ctx || {};
        geoms = Object.create(null); sizes = Object.create(null);
        drawGroups(board, ctx);
        drawEdges(board, ctx);
        drawHandles(board, ctx);
      }
    };

    /* ------------------------------------------------------------- cards */

    /*
     * Items, annotations last.
     *
     * paintCards wants that order because an annotation may be anchored to a
     * card whose element does not exist yet, and its position is that card's
     * centre. hitItem wants it because an annotation is drawn ABOVE what it is
     * about (`.bb-card.k-annot` carries the z-index that makes that true
     * whatever order the elements were created in), so it is what the finger
     * lands on. Object key order is INSERTION order and answers neither: it
     * finds the card underneath the annotation the user can plainly see, and a
     * link dropped on one lands on the other.
     */
    function drawOrder(board) {
      return Object.keys(board.items).sort(function (a, b) {
        var ka = board.items[a].k === 'annot' ? 1 : 0;
        var kb = board.items[b].k === 'annot' ? 1 : 0;
        return ka - kb;
      });
    }

    function paintCards(board, ctx) {
      var live = Object.create(null);
      var order = drawOrder(board);

      order.forEach(function (id) {
        live[id] = 1;
        var it = board.items[id];
        var e = els[id];
        if (!e) {
          e = el('div', 'bb-card');
          e.dataset.id = id;
          // The task box is a sibling of the title, never a child of it: the
          // title element holds the note's title and nothing else, so that
          // reading it back gives the note's name and not a glyph plus it.
          // It carries its own id because it is a TARGET as well as a marker -
          // ticking it writes to the note - and the gesture layer decides what
          // was pressed from the element under the finger alone.
          var tk = el('div', 'tk');
          tk.dataset.tick = id;
          e.appendChild(tk);
          e.appendChild(el('div', 'ct'));
          e.appendChild(el('div', 'cx'));
          e.appendChild(el('div', 'cc'));
          var grip = el('div', 'grip');
          grip.dataset.grip = id;
          e.appendChild(grip);
          // Where a link is dragged from. Bottom-centre, clear of the
          // right-edge width grip, so the two 44px targets never overlap.
          var port = el('div', 'port');
          port.dataset.port = id;
          e.appendChild(port);
          // The other card-on-card gesture. Dragging the card itself onto a
          // note means merge; dragging this distinct handle onto any card
          // means group. Keeping the choice in the thing under the finger is
          // usable on touch screens where there is no modifier key to hold.
          var groupPort = el('div', 'group-port');
          groupPort.dataset.groupPort = id;
          groupPort.title = tr('Drag onto another card to group');
          groupPort.setAttribute('aria-label', groupPort.title);
          e.appendChild(groupPort);
          els[id] = e;
          elCards.appendChild(e);
        }
        var groupPortNow = e.querySelector('.group-port');
        if (groupPortNow) {
          groupPortNow.title = tr('Drag onto another card to group');
          groupPortNow.setAttribute('aria-label', groupPortNow.title);
        }
        paint(e, board, id, it, ctx);
      });

      Object.keys(els).forEach(function (id) {
        if (live[id]) return;
        var e = els[id];
        if (e.parentNode) e.parentNode.removeChild(e);
        delete els[id];
        delete ghost[id];
        delete wghost[id];
      });
    }

    /*
     * Dimmed, meaning "not part of what you are looking for". One answer for
     * cards, lines, frames, tabs and labels, so a search can never leave a
     * bright line hanging off a dim card.
     */
    function dimmed(ctx, id) {
      return !!(ctx && ctx.lit && !BOARD.has(ctx.lit, id));
    }

    function paint(e, board, id, it, ctx) {
      var face = BB.notes.face(board, id, ctx.cache);
      var tomb = !!(face && face.tomb);
      var kind = it.k;

      var cls = ['bb-card', 'k-' + kind];
      if (tomb) cls.push('tomb');
      if (face.task) cls.push('task');
      if (face.task && face.done) cls.push('done');
      if (ctx.sel && ctx.sel[id]) cls.push('sel');
      if (ctx.selectMode) cls.push('multi');
      if (ctx.dragging && ctx.dragging[id]) cls.push('dragging');
      if (ctx.editing === id) cls.push('editing');
      if (ctx.linkFrom === id) cls.push('linking');
      if (ctx.linkOver === id) cls.push('target');
      if (it.k !== 'note' && !it.t) cls.push('blank');
      if (dimmed(ctx, id)) cls.push('dim');
      var col = R.colourClass(it.c);
      if (col) cls.push(col);
      var next = cls.join(' ');
      if (e.className !== next) e.className = next;

      var w = wghost[id] != null ? wghost[id] : R.widthOf(it);
      var wpx = w + 'px';
      if (e.style.width !== wpx) e.style.width = wpx;

      var p = absAt(board, id, 0) || it.p;
      var tr = 'translate(' + r2(p[0]) + 'px,' + r2(p[1]) + 'px)';
      if (e.style.transform !== tr) e.style.transform = tr;

      var tick = e.firstChild, title = tick.nextSibling, body = title.nextSibling, chips = body.nextSibling;

      // A task card carries an unticked or ticked box, drawn in CSS. The
      // gesture layer treats it as part of the card until a tap commits; the
      // app then asks before writing the task status to the real note.
      tick.hidden = !face.task;

      /*
       * The one element the caret can be in. While a sticky, an annotation or
       * a link label is being typed into, nothing writes to it - not its text,
       * not a placeholder, not the face's idea of what an empty sticky is
       * called. Rewriting textContent under a live contentEditable moves the
       * caret to the front and eats the character being typed.
       */
      if (ctx.editing !== id) {
        // textContent, everywhere, always. A note's title and body are text,
        // and the fallback for a card that has none is the face's - the
        // renderer does not invent a second answer to what an empty sticky is
        // called.
        var t = face.title || '';
        if (title.textContent !== t) title.textContent = t;
      }

      // Only note cards carry an excerpt.
      var x = kind === 'note' ? (face.excerpt || '') : '';
      if (body.textContent !== x) body.textContent = x;
      body.hidden = !x;

      paintChips(chips, face, kind, tomb);
    }

    /*
     * The chip row: the note's tags, and the one word that says a card's note
     * is gone.
     *
     * Chips are rebuilt only when they actually differ - a signature string
     * decides, so a render in the middle of a drag leaves the row alone. Every
     * chip's text is textContent and its colour reaches CSS as a custom
     * property that is only set when it parses as a hex colour, so a tag named
     * or coloured to look like markup is a chip with a funny name.
     *
     * A sticky and an annotation have no row at all any more. They used to
     * carry a chip saying what they were, which was the only way to tell them
     * from a note card while they were drawn as placeholders; now they look
     * like themselves and the label would be a caption on a photograph of a
     * thing you are holding.
     */
    function paintChips(chips, face, kind, tomb) {
      if (kind !== 'note') {
        if (chips.dataset.sig !== '-') { chips.dataset.sig = '-'; chips.textContent = ''; }
        chips.hidden = true;
        return;
      }
      var tags = (face.tags || []).slice(0, R.TAGS);
      var over = (face.tags || []).length - tags.length;
      var state = tomb ? 'missing' : '';
      var sig = state + ' ' + over + ' ' + tags.map(function (t) {
        return t.name + '' + (t.color || '');
      }).join('');

      if (chips.dataset.sig !== sig) {
        chips.dataset.sig = sig;
        chips.textContent = '';
        if (state) {
          var s = el('span', 'chip state');
          s.textContent = tr(state);
          chips.appendChild(s);
        }
        tags.forEach(function (t) {
          var c = el('span', 'chip tag');
          c.textContent = t.name;
          var hex = hexOf(t.color);
          if (hex) c.style.setProperty('--chip', hex);
          chips.appendChild(c);
        });
        if (over > 0) {
          var more = el('span', 'chip tag more');
          more.textContent = '+' + over;
          chips.appendChild(more);
        }
      }
      chips.hidden = !state && !tags.length && over <= 0;
      var cls = 'cc' + (tomb ? ' bad' : '');
      if (chips.className !== cls) chips.className = cls;
    }

    // A tag colour, if it is one. Anything that is not a plain hex is dropped
    // rather than passed through: this is the one string on a card that reaches
    // CSS instead of textContent, and it is the only place it could matter.
    function hexOf(c) {
      var s = String(c == null ? '' : c).trim();
      var m = /^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.exec(s);
      return m ? '#' + m[1] : null;
    }

    /* --------------------------------------------------------- annotations */

    /*
     * The two pieces of writing-back the renderer owns, because it is the only
     * thing that knows where an anchor IS.
     *
     *   `reanchor` means `p` is an absolute spot, put there by whoever dropped
     *   the anchor it used to be measured from (model.js `detach`, board.js
     *   `sanitise`; both promote `q`). Now that there is a live first anchor
     *   again, `p` becomes an offset from it - and the annotation does not move
     *   on screen, which is the entire point of the flag. The flag never
     *   outlives a draw, which is why the block format has no field for it.
     *
     *   `q` is where the annotation was last really drawn. removeItem promotes
     *   it to `p` when the LAST anchor disappears, so that an annotation whose
     *   subject was deleted stays where the user saw it. It is a cache of this
     *   file's own geometry, refreshed on every draw, and it marks NOTHING
     *   dirty: a board that was only looked at does not rewrite its note.
     */
    function settle(board) {
      Object.keys(board.items).forEach(function (id) {
        var it = board.items[id];
        if (it.k !== 'annot') return;
        if (it.reanchor && it.at && it.at.length) {
          var base = anchorAt(board, it.at[0], 1);
          if (base) M.setAnnotOffset(board, id, [it.p[0] - base[0], it.p[1] - base[1]]);
        }
        if (!it.at || !it.at.length) return;
        var abs = absAt(board, id, 0);
        if (abs) M.stampSpot(board, id, abs);
      });
    }

    /* -------------------------------------------------------------- groups */

    function drawGroups(board, ctx) {
      if (!elGroups) return;
      var live = Object.create(null);
      board.groups.forEach(function (g) {
        var r = rectOf(board, g.i);
        if (!r) return;
        live[g.i] = 1;
        var e = gels[g.i];
        if (!e) {
          e = el('div', 'bb-group');
          e.dataset.id = g.i;
          gels[g.i] = e;
          elGroups.appendChild(e);
        }
        var cls = 'bb-group' + (ctx.groupSel === g.i ? ' sel' : '') + (dimmed(ctx, g.i) ? ' dim' : '');
        var col = R.colourClass(g.c);
        if (col) cls += ' ' + col;
        if (e.className !== cls) e.className = cls;
        e.style.transform = 'translate(' + r2(r.x) + 'px,' + r2(r.y) + 'px)';
        e.style.width = r2(r.w) + 'px';
        e.style.height = r2(r.h) + 'px';
      });
      Object.keys(gels).forEach(function (id) {
        if (live[id]) return;
        if (gels[id].parentNode) gels[id].parentNode.removeChild(gels[id]);
        delete gels[id];
      });
    }

    /* --------------------------------------------------------------- edges */

    function path(d, cls, attrs) {
      var p = svg('path', cls);
      p.setAttribute('d', d);
      p.setAttribute('fill', 'none');
      Object.keys(attrs || {}).forEach(function (k) { if (attrs[k] !== '') p.setAttribute(k, attrs[k]); });
      return p;
    }

    // The invisible stroke the finger actually hits. Far fatter than the line
    // it shadows, and carrying the id, because a 1.7px curve and a dotted
    // leader are not touch targets on any phone.
    function hitPath(d, id, k, v) {
      var p = path(d, 'bb-hit', { 'stroke-width': r2(R.HIT_W * v) });
      p.dataset.id = id;
      p.dataset.hit = k;
      return p;
    }

    // An arrowhead, as two strokes rather than a filled triangle, so it wears
    // the link's own colour and dash-free weight with no second fill rule.
    function headPath(tip, from, v) {
      var dx = tip[0] - from[0], dy = tip[1] - from[1];
      var len = Math.hypot(dx, dy) || 1;
      var ux = dx / len, uy = dy / len;
      var s = R.HEAD * v, w = s * 0.52;
      var bx = tip[0] - ux * s, by = tip[1] - uy * s;
      return 'M' + r2(bx - uy * w) + ',' + r2(by + ux * w) +
        'L' + r2(tip[0]) + ',' + r2(tip[1]) +
        'L' + r2(bx + uy * w) + ',' + r2(by - ux * w);
    }

    // Where a straight leader leaves the annotation's own box, so the dotted
    // line starts at the edge of the label rather than under it.
    function leaderStart(box, to) {
      return edgePoint(box, to[0], to[1]);
    }

    function drawEdges(board, ctx) {
      var v = inv();
      var frag = document.createDocumentFragment();

      board.links.forEach(function (l) {
        var g = geomOf(board, l.i, 0);
        if (!g) return;
        var cls = 'bb-edge' + (ctx.linkSel === l.i ? ' on' : '') + (dimmed(ctx, l.i) ? ' dim' : '');
        var col = R.colourClass(l.c);
        if (col) cls += ' ' + col;
        var attrs = { 'stroke-width': r2(R.EDGE_W * v), 'stroke-dasharray': dashOf(l.d, v) };
        frag.appendChild(path(g.d, cls, attrs));
        // A head is drawn solid whatever the line's dash: a dotted arrowhead
        // is three dots pointing vaguely somewhere.
        if (l.h === 'arrow' || l.h === 'double') {
          frag.appendChild(path(headPath(g.b, g.c, v), cls, { 'stroke-width': r2(R.EDGE_W * v) }));
        }
        if (l.h === 'double') {
          frag.appendChild(path(headPath(g.a, g.c, v), cls, { 'stroke-width': r2(R.EDGE_W * v) }));
        }
        frag.appendChild(hitPath(g.d, l.i, 'link', v));
      });

      Object.keys(board.items).forEach(function (id) {
        var it = board.items[id];
        if (it.k !== 'annot' || !it.at || !it.at.length) return;
        var box = boxAt(board, id, 0);
        if (!box) return;
        var sel = !!(ctx.sel && ctx.sel[id]);
        it.at.forEach(function (a) {
          var p = anchorAt(board, a, 1);
          if (!p) return;
          var s = leaderStart(box, p);
          var d = 'M' + r2(s[0]) + ',' + r2(s[1]) + 'L' + r2(p[0]) + ',' + r2(p[1]);
          var cls = 'bb-lead' + (sel ? ' on' : '') + (dimmed(ctx, id) ? ' dim' : '');
          var col = R.colourClass(it.c);
          if (col) cls += ' ' + col;
          frag.appendChild(path(d, cls, {
            'stroke-width': r2(R.LEAD_W * v),
            'stroke-dasharray': r2(R.LEAD_DASH[0] * v) + ' ' + r2(R.LEAD_DASH[1] * v)
          }));
          frag.appendChild(hitPath(d, id, 'annot', v));
        });
      });

      /*
       * Links the AI has proposed, drawn LAST so they lie over the board they
       * are about. Dashed and accented, whatever style axes a real link
       * happens to wear, because the one thing this line has to say is that it
       * is not there yet. They are never dimmed: a search is about the board,
       * and a preview waiting to be answered is not part of it.
       */
      (ctx.proposals || []).forEach(function (p) {
        var pg = curveOf(board, p.i, p.a, p.b, 0);
        if (!pg) return;
        frag.appendChild(path(pg.d, 'bb-edge prop', {
          'stroke-width': r2(R.PROP_W * v),
          'stroke-dasharray': dashOf('dashed', v)
        }));
        frag.appendChild(hitPath(pg.d, p.i, 'prop', v));
      });

      elEdges.textContent = '';
      elEdges.appendChild(frag);
      // The rubber band belongs to a gesture in flight and outlives a redraw.
      if (rubber) elEdges.appendChild(rubber);
    }

    /* ------------------------------------------------------------- handles */

    /*
     * Counter-scaled things that sit over the scene: a link's handle, its
     * label, and a group's tab.
     *
     * They are ordinary elements rather than SVG content because #edges is a
     * 1x1 box relying on overflow, and hit-testing content outside an SVG
     * viewport is not dependable across engines - and because a label has to
     * be typed into, which means it has to be a contentEditable div.
     */
    function place(e, x, y, extra) {
      var tr = 'translate(' + r2(x) + 'px,' + r2(y) + 'px) scale(var(--inv, 1)) ' + extra;
      if (e.style.transform !== tr) e.style.transform = tr;
    }

    function drawHandles(board, ctx) {
      if (!elHandles) return;
      var live = Object.create(null);

      board.links.forEach(function (l) {
        var g = geomOf(board, l.i, 0);
        if (!g) return;
        live[l.i] = 1;
        var h = hels[l.i];
        if (!h) {
          h = el('div', 'bb-link');
          h.dataset.id = l.i;
          // The one place this file builds markup, and it is a constant: a
          // static icon with nothing from the board anywhere in it. Nothing a
          // note or a board says ever reaches innerHTML - not a title, not an
          // excerpt, not a </script> somebody typed into a sticky. (That one
          // is written out in full deliberately: build.sh escapes every
          // literal </script> on its way into the single-file app, and until
          // this line existed no source held one, so the escaping shipped
          // untested and the balance check in dev/build_check.js could not
          // fail.)
          h.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true">' +
            '<path d="M9.5 14.5l5-5"/>' +
            '<path d="M12.5 7.5l1.8-1.8a3.5 3.5 0 014.9 4.9L17.4 12.4"/>' +
            '<path d="M11.5 16.5l-1.8 1.8a3.5 3.5 0 01-4.9-4.9L6.6 11.6"/></svg>';
          hels[l.i] = h;
          elHandles.appendChild(h);
        }
        var cls = 'bb-link' + (ctx.linkSel === l.i ? ' on' : '') + (l.real ? ' real' : '') +
          (dimmed(ctx, l.i) ? ' dim' : '');
        var col = R.colourClass(l.c);
        if (col) cls += ' ' + col;
        if (h.className !== cls) h.className = cls;
        place(h, g.mid[0], g.mid[1], 'translate(-50%,-50%)');

        var lab = lels[l.i];
        var text = l.t || '';
        var wanted = !!text || ctx.editing === l.i;
        if (wanted && !lab) {
          lab = el('div', 'bb-label');
          lab.dataset.id = l.i;
          lels[l.i] = lab;
          elHandles.appendChild(lab);
        }
        if (lab) {
          if (!wanted) {
            if (lab.parentNode) lab.parentNode.removeChild(lab);
            delete lels[l.i];
          } else {
            if (ctx.editing !== l.i && lab.textContent !== text) lab.textContent = text;
            var lcls = 'bb-label' + (ctx.linkSel === l.i ? ' on' : '') + (ctx.editing === l.i ? ' editing' : '') +
              (dimmed(ctx, l.i) ? ' dim' : '');
            if (lab.className !== lcls) lab.className = lcls;
            place(lab, g.mid[0], g.mid[1], 'translate(-50%,' + (-100 * R.LABEL_LIFT) + '%)');
          }
        }
      });

      board.groups.forEach(function (g) {
        var r = rectOf(board, g.i);
        if (!r) return;
        live[g.i] = 1;
        var t = hels[g.i];
        if (!t) {
          t = el('div', 'bb-gtab');
          t.dataset.id = g.i;
          t.appendChild(el('span', 'gt'));
          hels[g.i] = t;
          elHandles.appendChild(t);
        }
        var cls = 'bb-gtab' + (ctx.groupSel === g.i ? ' on' : '') + (dimmed(ctx, g.i) ? ' dim' : '');
        var col = R.colourClass(g.c);
        if (col) cls += ' ' + col;
        if (t.className !== cls) t.className = cls;
        var name = g.t || 'Group';
        var span = t.firstChild;
        if (ctx.editing !== g.i && span.textContent !== name) span.textContent = name;
        place(t, r.x + 10, r.y + 6, '');
      });

      /*
       * A suggested link's own two affordances: the label it came with, and a
       * 44px target that drops it.
       *
       * They are separate element maps rather than more entries in hels/lels
       * because a proposal is not a link: it has no style axes, no bar of its
       * own, and one tap on it means "not that one" rather than "tell me about
       * this". Keeping them apart is also what lets the cleanup pass below
       * remove every proposal element the moment the preview is answered,
       * without a live/dead test that would have to know about both kinds.
       */
      var plive = Object.create(null);
      (ctx.proposals || []).forEach(function (p) {
        var pg = curveOf(board, p.i, p.a, p.b, 0);
        if (!pg) return;
        plive[p.i] = 1;
        var h = phels[p.i];
        if (!h) {
          h = el('div', 'bb-link prop');
          h.dataset.id = p.i;
          h.title = tr('Drop this suggestion');
          h.setAttribute('aria-label', h.title);
          // A constant, like the link handle's: nothing from the board or from
          // a model ever reaches innerHTML.
          h.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true">' +
            '<path d="M7 7l10 10"/><path d="M17 7L7 17"/></svg>';
          phels[p.i] = h;
          elHandles.appendChild(h);
        }
        h.title = tr('Drop this suggestion');
        h.setAttribute('aria-label', h.title);
        place(h, pg.mid[0], pg.mid[1], 'translate(-50%,-50%)');

        var lab = plels[p.i];
        var text = p.t || '';
        if (text && !lab) {
          lab = el('div', 'bb-label prop');
          lab.dataset.id = p.i;
          plels[p.i] = lab;
          elHandles.appendChild(lab);
        }
        if (lab) {
          if (!text) {
            if (lab.parentNode) lab.parentNode.removeChild(lab);
            delete plels[p.i];
          } else {
            // textContent, always: this string came out of a language model.
            if (lab.textContent !== text) lab.textContent = text;
            place(lab, pg.mid[0], pg.mid[1], 'translate(-50%,' + (-100 * R.LABEL_LIFT) + '%)');
          }
        }
      });
      Object.keys(phels).forEach(function (id) {
        if (plive[id]) return;
        if (phels[id].parentNode) phels[id].parentNode.removeChild(phels[id]);
        delete phels[id];
        if (plels[id]) {
          if (plels[id].parentNode) plels[id].parentNode.removeChild(plels[id]);
          delete plels[id];
        }
      });

      Object.keys(hels).forEach(function (id) {
        if (live[id]) return;
        if (hels[id].parentNode) hels[id].parentNode.removeChild(hels[id]);
        delete hels[id];
        if (lels[id]) {
          if (lels[id].parentNode) lels[id].parentNode.removeChild(lels[id]);
          delete lels[id];
        }
      });
    }

    return api;
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = BB;
})(typeof window !== 'undefined' ? window : globalThis);
