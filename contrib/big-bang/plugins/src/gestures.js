/*
 * Big Bang - pointer gestures.
 *
 * Everything the finger does happens here, and nothing else does. This layer
 * knows about pointers, distances and timers; it knows nothing about boards,
 * undo or saving. It reports what happened through the callbacks in `api`, and
 * the app decides what that means. Keeping the two apart is what makes a drag
 * of nine cards ONE undo step: the gesture moves elements, the app writes the
 * model once, when the gesture says it is over.
 *
 * The rules it enforces:
 *
 *   Pointer events only, and touch-action:none on the viewport. No touch/mouse
 *   pairs, no synthesised clicks, no scroll to fight with.
 *
 *   A gesture commits to being one thing. A press on a card is not a drag until
 *   the finger has moved past the slop, and once it is a drag it will not turn
 *   into a tap. This is what stops a card jumping when a thumb rolls.
 *
 *   A second finger cancels an item drag rather than fighting it. Pinching
 *   while dragging is nobody's intent, and half-committing that drag would move
 *   a card to wherever the fingers happened to be.
 *
 *   Zoom is clamped and checked. A pinch that divides by a distance of zero
 *   yields Infinity, and a zoom of 0 or NaN is refused by the model's setters -
 *   which the user would experience as a board that froze, not as an error. It
 *   never gets that far.
 *
 * And three rules about the pointers themselves, each of which was a board
 * that stopped responding:
 *
 *   EVERY pointer is captured, first thing, before anything decides what the
 *   gesture is. The stage sits between two bars; a finger that drifts onto one
 *   of them sends its `pointerup` to a sibling that does not bubble here, and
 *   an id left in the map is a pinch that never ends - after which one finger
 *   zooms. Capture retargets that up to the stage, which is why it now happens
 *   BEFORE the two-finger branch that used to return in front of it. Capture
 *   taken back is announced by `lostpointercapture` and ends the gesture; a
 *   pointer we were never allowed to capture has no signal at all, so the next
 *   `pointerdown` drops it once it has been silent long enough to be gone.
 *
 *   A pinch KNOWS WHICH TWO POINTERS it is. Taking "the first two in the map"
 *   means a third finger landing, or one of the original two lifting, quietly
 *   swaps the pair while the baseline distance still describes the old one -
 *   the board jumps. The pair is named at the start and re-baselined, on
 *   purpose, whenever it changes.
 *
 *   A pinch has a MINIMUM SEPARATION. Two fingers that land together measure
 *   0px apart, and substituting 1px for that baseline makes the first real
 *   movement a division by one: forty pixels of spread became the maximum zoom
 *   in a single frame. Below the minimum the pinch holds the board but does not
 *   scale it, and the first movement that clears the minimum becomes the
 *   baseline.
 */
(function (global) {
  'use strict';
  var BB = (global.BB = global.BB || {});
  var G = (BB.gestures = {});

  G.SLOP = 8;              // px before a press becomes a drag - or a resize
  G.LONG_MS = 480;         // press-and-hold to start a multi-selection
  G.DOUBLE_MS = 330;
  G.DOUBLE_SLOP = 32;
  G.MIN_Z = 0.15;
  G.MAX_Z = 4;
  // Below this the two fingers are one blob, and their separation is noise
  // rather than a scale. It is roughly the width of a fingertip.
  G.MIN_PINCH = 24;
  /*
   * How long a pointer may go without a single event before a NEW touch is
   * allowed to conclude it has gone. It is the last-resort recovery, not the
   * mechanism: capture is what stops a pointer going missing, and
   * lostpointercapture is what says so when it does. This exists for the case
   * neither covers - a pointer capture refused - where there is no signal at
   * all, and it is long because a finger resting on the glass still emits
   * moves, so silence for four seconds means gone rather than still.
   */
  G.STALE_MS = 4000;

  function dist(a, b) { return Math.hypot(a.x - b.x, a.y - b.y); }
  function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }
  G.clamp = clamp;

  /*
   * The one place a zoom is judged. Every caller wanted the same three things -
   * finite, positive, inside the range a finger can reach - and each had
   * written its own two of them.
   * -> the usable zoom, or null.
   */
  G.zoom = function (k) {
    return (typeof k === 'number' && isFinite(k) && k > 0) ? clamp(k, G.MIN_Z, G.MAX_Z) : null;
  };

  /*
   * A point on the glass, in board coordinates: the inverse of the scene's one
   * transform. `r` is the viewport's rectangle and `c` the camera.
   *
   * It lives out here rather than inside attach() because the app needs the
   * same answer from its own camera - hit-testing what a link was dropped on,
   * placing a sticky where a long press landed - and two copies of one formula
   * is two places for a sign to be wrong.
   */
  G.toBoard = function (r, c, x, y) {
    return { x: (x - r.left - c.tx) / c.k, y: (y - r.top - c.ty) / c.k };
  };

  /*
   * attach({ viewport, api }) -> { active }
   *
   * api (every entry optional):
   *   camera()                        -> { tx, ty, k }
   *   setCamera(tx, ty, k, live)      live:true means "still moving"
   *   tapItem(id, event)
   *   tapTick(id, event)              a tap on a task card's checkbox
   *   tapBackground(event)
   *   doubleTap(event)
   *   longPressItem(id, event)
   *   longPressBackground(x, y, event)
   *   dragStart(id)                   -> [ids] to move, or null to refuse
   *   dragMove(ids, dx, dy, event)    dx/dy are BOARD units
   *   dragEnd(ids, commit, event)
   *   resizeStart(id)                 -> starting width, or null to refuse
   *   resizeMove(id, width)
   *   resizeEnd(id, width, commit)
   *   linkStart(id)                   -> true to start drawing a link
   *   linkMove(id, clientX, clientY)
   *   linkEnd(id, clientX, clientY, commit)
   *
   * The ids handed to tapItem, longPressItem and dragStart are BOARD ids, and
   * a board id names an item, a link OR a group - the three share one id space
   * (model.js `idTaken`). This layer neither knows nor cares which: it reports
   * what was under the finger and the app decides what that means. Which is
   * why a link handle, a group tab and a card are all tapped and dragged
   * through the same three callbacks rather than three parallel sets of them.
   */
  G.attach = function (opts) {
    var vp = opts.viewport, api = opts.api || {};
    var ptrs = new Map();
    var g = null;
    var longTimer = null;
    var lastTap = 0, lastTapX = 0, lastTapY = 0;

    function cam() { return (api.camera && api.camera()) || { tx: 0, ty: 0, k: 1 }; }
    function rect() { return vp.getBoundingClientRect(); }

    // Screen point -> board point, under the current camera.
    function toBoard(x, y) { return G.toBoard(rect(), cam(), x, y); }

    function clearLong() { if (longTimer) { clearTimeout(longTimer); longTimer = null; } }

    /*
     * What the finger landed on, as a board id.
     *
     * A card, a link's handle, a link's label, a group's tab and the invisible
     * fat stroke laid over a line or a leader are all board objects with ids,
     * and every one of them is tapped and dragged the same way. `.bb-hit` is
     * the fattened stroke: hit-testing a 1.7px curve is not possible with a
     * thumb, so the line the finger can reach is a second, transparent copy of
     * it, and it carries the id its visible twin draws.
     */
    var TARGETS = '.bb-card,.bb-link,.bb-label,.bb-gtab,.bb-hit';
    function itemOf(target) {
      var e = target && target.closest ? target.closest(TARGETS) : null;
      return e ? e.dataset.id : null;
    }
    function gripOf(target) {
      var e = target && target.closest ? target.closest('.grip') : null;
      return e ? e.dataset.grip : null;
    }
    function portOf(target) {
      var e = target && target.closest ? target.closest('.port') : null;
      return e ? e.dataset.port : null;
    }
    function groupPortOf(target) {
      var e = target && target.closest ? target.closest('.group-port') : null;
      return e ? e.dataset.groupPort : null;
    }
    /*
     * A task card's checkbox. It is inside the card, so it is looked for
     * BEFORE the card - but AFTER the grip and the port, because those two are
     * shown only while a card is selected and the three targets can overlap on
     * a short card. A press that lands on both goes to the affordance that has
     * to be draggable; the tick has a whole card's worth of glass to itself.
     */
    function tickOf(target) {
      var e = target && target.closest ? target.closest('.tk') : null;
      return e ? e.dataset.tick : null;
    }
    /*
     * A field with the caret in it is the browser's, not ours. Capturing the
     * pointer would take the tap away from the text - no caret placement, no
     * selection, no way to put the cursor in the middle of a sticky - and
     * `touch-action:none` on the stage means nothing else would give it back.
     */
    function editable(target) {
      var e = target && target.closest ? target.closest('[contenteditable]') : null;
      if (!e) return false;
      // Not `[contenteditable="true"]`: a field the app opened as
      // `plaintext-only` - which is how it keeps pasted markup out of a card -
      // is every bit as live, and a selector that missed it would take the tap
      // away from the text again.
      var v = String(e.getAttribute('contenteditable') || '').toLowerCase();
      return v === '' || v === 'true' || v === 'plaintext-only';
    }

    // Where the camera actually is, written down. Every gesture that moves it
    // ends here - including one that was cancelled, because applyCamera(live)
    // deliberately does not touch the board and the user is looking at the
    // result either way.
    function settle() {
      if (!api.setCamera) return;
      var c = cam();
      api.setCamera(c.tx, c.ty, c.k, false);
    }

    /* ---------------------------------------------------------- pointers */

    function forget(id) {
      ptrs.delete(id);
      try { vp.releasePointerCapture(id); } catch (err) { /* never captured */ }
    }

    /*
     * Pointers that have said nothing for a very long time, dropped at the one
     * moment it matters: a new finger arriving, which is when a stale id would
     * otherwise become the second half of a pinch nobody is holding.
     *
     * hasPointerCapture is deliberately NOT consulted. It is the obvious test
     * and it is not a reliable one - a pointer this layer captured successfully
     * can report itself uncaptured a moment later, and pruning on that answer
     * dissolves a live two-finger gesture into a one-finger pan.
     *
     * pointerleave is not a signal either: with capture in force it does not
     * arrive, and without it a finger that strays onto a bar and comes back
     * would have its pan cancelled underneath it.
     */
    function prune(now) {
      var dead = [];
      ptrs.forEach(function (p, id) {
        if (now - p.t > G.STALE_MS) dead.push(id);
      });
      dead.forEach(function (id) { ptrs.delete(id); });
      return dead.length;
    }

    /* ------------------------------------------------------------- down */

    function onDown(e) {
      // Before anything else, including the capture: a tap inside live text is
      // the text's. Taking it would put the caret nowhere and leave the user
      // with a box they cannot get into the middle of.
      if (editable(e.target)) return;

      var now = Date.now();
      // A stuck id must never be able to make a fresh touch the second finger
      // of a pinch that nobody is holding.
      prune(now);

      // First, before any branch returns: the capture is what guarantees this
      // pointer's up or cancel comes back here rather than to a bar the stage
      // sits between. Reaching it only for the FIRST pointer - after the
      // two-finger branch had already returned - is what left a pinch stuck.
      try { vp.setPointerCapture(e.pointerId); }
      catch (err) { /* a pointer the browser will not let us capture */ }

      ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY, t: now });
      if (ptrs.size === 2) { startPinch(); return; }
      // A third finger joins nothing. The pinch keeps the two it named.
      if (ptrs.size > 2) { clearLong(); return; }

      var grip = gripOf(e.target);
      if (grip) {
        var w0 = api.resizeStart ? api.resizeStart(grip) : null;
        if (w0 != null) {
          g = { type: 'resize', ptr: e.pointerId, id: grip, x0: e.clientX, w0: w0, w: w0, moved: false };
          return;
        }
      }

      /*
       * The link port. Unlike every other press this one commits immediately,
       * with no slop: the port is a 44px target that exists for exactly one
       * purpose, and making the user drag 8px before the line appears reads as
       * the gesture not having been noticed. A port press that never moves is
       * a link to nothing, which the app refuses out loud.
       */
      var port = portOf(e.target);
      if (port && api.linkStart && api.linkStart(port)) {
        g = { type: 'linkdraw', ptr: e.pointerId, id: port, x0: e.clientX, y0: e.clientY };
        if (api.linkMove) api.linkMove(port, e.clientX, e.clientY);
        return;
      }

      /*
       * A press on the tick is an ordinary press on its card, remembered as
       * one that landed on the box. It is not committed on the way down the
       * way the port is: a tick is a write to a note, and a thumb that rolled
       * off it has changed its mind. Moving past the slop turns it into a drag
       * of the card, and holding it starts a multi-selection, both exactly as
       * a press anywhere else on the card does.
       */
      var groupPort = groupPortOf(e.target);
      var tick = tickOf(e.target);
      var id = groupPort || tick || itemOf(e.target);
      if (id) {
        g = {
          type: 'press', ptr: e.pointerId, id: id,
          tick: !!tick, grouping: !!groupPort,
          x0: e.clientX, y0: e.clientY, t: Date.now(), moved: false, consumed: false
        };
        clearLong();
        // Holding the group handle is already a fully specified gesture. It
        // must not turn into the card's long-press multi-selection while a
        // careful thumb is still aiming at the destination.
        if (!groupPort) {
          longTimer = setTimeout(function () {
            longTimer = null;
            if (!g || g.type !== 'press' || g.moved) return;
            g.consumed = true;
            if (api.longPressItem) api.longPressItem(g.id, e);
          }, G.LONG_MS);
        }
        return;
      }

      var c = cam();
      g = { type: 'pan', ptr: e.pointerId, x0: e.clientX, y0: e.clientY, tx0: c.tx, ty0: c.ty, t: Date.now(), moved: false, consumed: false };
      clearLong();
      longTimer = setTimeout(function () {
        longTimer = null;
        if (!g || g.type !== 'pan' || g.moved) return;
        g.consumed = true;
        var b = toBoard(e.clientX, e.clientY);
        if (api.longPressBackground) api.longPressBackground(b.x, b.y, e);
      }, G.LONG_MS);
    }

    /* ------------------------------------------------------------ pinch */

    // The two pointers a pinch is made of, in the order it named them, or null
    // if either has gone.
    function pairOf(gg) {
      if (!gg || !gg.ids) return null;
      var a = ptrs.get(gg.ids[0]), b = ptrs.get(gg.ids[1]);
      return (a && b) ? [a, b] : null;
    }

    /*
     * Start - or re-baseline - a pinch on the two live pointers.
     *
     * `primed` is the whole of the zero-distance rule: an unprimed pinch holds
     * the board (two fingers are down, this is not a pan) and scales nothing,
     * and the first movement that separates the fingers properly becomes the
     * baseline. `k0` is therefore always the zoom the pinch actually starts
     * scaling from, never one measured against a distance nobody made.
     */
    function startPinch(quiet) {
      clearLong();
      if (!quiet) {
        // A drag caught mid-pinch is abandoned, not committed: the card would
        // land wherever two fingers happened to be.
        if (g && g.type === 'drag' && api.dragEnd) api.dragEnd(g.ids, false, null);
        if (g && g.type === 'resize' && api.resizeEnd) api.resizeEnd(g.id, g.w0, false);
        if (g && g.type === 'linkdraw' && api.linkEnd) api.linkEnd(g.id, g.x0, g.y0, false);
      }
      var ids = Array.from(ptrs.keys()).slice(0, 2);
      if (ids.length < 2) { g = null; return; }
      var a = ptrs.get(ids[0]), b = ptrs.get(ids[1]);
      var d0 = dist(a, b);
      var mid = toBoard((a.x + b.x) / 2, (a.y + b.y) / 2);
      var c = cam();
      g = {
        type: 'pinch', ids: ids,
        primed: d0 >= G.MIN_PINCH,
        d0: d0, k0: c.k, bx: mid.x, by: mid.y, moved: false
      };
    }

    /* ------------------------------------------------------------- move */

    function onMove(e) {
      if (!ptrs.has(e.pointerId)) return;
      var p = ptrs.get(e.pointerId);
      p.x = e.clientX; p.y = e.clientY; p.t = Date.now();
      if (!g) return;

      if (g.type === 'pinch') {
        var pair = pairOf(g);
        // The pair this pinch named is not the pair on the glass any more.
        // Re-baseline on whatever is actually down rather than scaling against
        // a distance that describes fingers that have gone.
        if (!pair) {
          if (ptrs.size >= 2) { startPinch(true); return; }
          return;
        }
        var d = dist(pair[0], pair[1]);
        if (!isFinite(d)) return;
        var cx = (pair[0].x + pair[1].x) / 2, cy = (pair[0].y + pair[1].y) / 2;
        if (!g.primed) {
          // Still one blob. Take the first honest separation as the baseline;
          // that move itself scales nothing, which is the point.
          if (d < G.MIN_PINCH) return;
          var mid = toBoard(cx, cy);
          var c0 = cam();
          g.primed = true; g.d0 = d; g.k0 = c0.k; g.bx = mid.x; g.by = mid.y;
          return;
        }
        if (d <= 0) return;
        var k = G.zoom(g.k0 * (d / g.d0));
        if (k === null) return;
        var r = rect();
        g.moved = true;
        if (api.setCamera) api.setCamera(cx - r.left - g.bx * k, cy - r.top - g.by * k, k, true);
        return;
      }

      if (g.type === 'pan') {
        if (!g.moved && Math.hypot(e.clientX - g.x0, e.clientY - g.y0) < G.SLOP) return;
        g.moved = true;
        clearLong();
        var c = cam();
        if (api.setCamera) api.setCamera(g.tx0 + (e.clientX - g.x0), g.ty0 + (e.clientY - g.y0), c.k, true);
        return;
      }

      if (g.type === 'press') {
        if (Math.hypot(e.clientX - g.x0, e.clientY - g.y0) < G.SLOP) return;
        clearLong();
        g.moved = true;
        var ids = api.dragStart ? api.dragStart(g.id, { grouping: g.grouping }) : null;
        if (ids && ids.length) {
          g = { type: 'drag', ptr: g.ptr, id: g.id, ids: ids, x0: g.x0, y0: g.y0 };
          return;
        }
        // Nothing to drag - a read-only board, say. The finger is already down
        // and moving, so the board pans instead of nothing happening at all.
        var cc = cam();
        g = { type: 'pan', ptr: g.ptr, x0: g.x0, y0: g.y0, tx0: cc.tx, ty0: cc.ty, t: g.t, moved: true, consumed: true };
        if (api.setCamera) api.setCamera(cc.tx + (e.clientX - g.x0), cc.ty + (e.clientY - g.y0), cc.k, true);
        return;
      }

      if (g.type === 'drag') {
        var k2 = cam().k || 1;
        if (api.dragMove) api.dragMove(g.ids, (e.clientX - g.x0) / k2, (e.clientY - g.y0) / k2, e);
        return;
      }

      if (g.type === 'linkdraw') {
        // Screen coordinates, not board ones: the app has to hit-test what is
        // under the finger, and it does that with its own camera.
        if (api.linkMove) api.linkMove(g.id, e.clientX, e.clientY);
        return;
      }

      if (g.type === 'resize') {
        // A grip is a drag target too: a finger that pressed it and never moved
        // has not resized anything, and committing that width writes the board
        // and pushes an undo step for a card nobody touched.
        if (!g.moved && Math.abs(e.clientX - g.x0) < G.SLOP) return;
        g.moved = true;
        var k3 = cam().k || 1;
        g.w = g.w0 + (e.clientX - g.x0) / k3;
        if (api.resizeMove) api.resizeMove(g.id, g.w);
      }
    }

    /* --------------------------------------------------------------- up */

    /*
     * Whose finger was that?
     *
     * Not every pointer on the glass belongs to the gesture in flight. A tap
     * inside live text returns from onDown before the map, on purpose, and
     * leaks nothing - but that finger is still DOWN, and when it lifts its up
     * arrives here like any other. Finishing `g` on it ended the drag the other
     * hand was making, using the wrong finger's coordinates, and dragEnd tested
     * overBin() with them: a thumb resting on an open sticky deleted the card
     * the index finger was moving. A pinch is exempt because it is the one
     * gesture made of two named pointers and knows which; everything else is
     * one finger's, and says so.
     */
    function mine(gg, e) { return gg.ptr == null || gg.ptr === e.pointerId; }

    function onUp(e) {
      forget(e.pointerId);
      if (!g) { clearLong(); return; }
      var gg = g;

      if (gg.type === 'pinch') { clearLong(); endPinch(gg); return; }
      if (!mine(gg, e)) return;
      clearLong();
      g = null;

      if (gg.type === 'drag') {
        if (api.dragEnd) api.dragEnd(gg.ids, true, e);
        return;
      }
      if (gg.type === 'resize') {
        // Never moved: this was a tap on the grip. It commits nothing.
        if (api.resizeEnd) api.resizeEnd(gg.id, gg.moved ? gg.w : gg.w0, gg.moved);
        return;
      }
      if (gg.type === 'linkdraw') {
        if (api.linkEnd) api.linkEnd(gg.id, e.clientX, e.clientY, true);
        return;
      }
      if (gg.type === 'press') {
        if (gg.consumed) return;
        if (gg.grouping && api.groupHint) { api.groupHint(gg.id, e); return; }
        if (gg.tick && api.tapTick) { api.tapTick(gg.id, e); return; }
        if (api.tapItem) api.tapItem(gg.id, e);
        return;
      }
      if (gg.type === 'pan') {
        if (gg.moved) { settle(); return; }
        if (gg.consumed) return;
        var now = Date.now();
        if (now - lastTap < G.DOUBLE_MS && Math.hypot(e.clientX - lastTapX, e.clientY - lastTapY) < G.DOUBLE_SLOP) {
          lastTap = 0;
          if (api.doubleTap) api.doubleTap(e);
          return;
        }
        lastTap = now; lastTapX = e.clientX; lastTapY = e.clientY;
        if (api.tapBackground) api.tapBackground(e);
      }
    }

    /*
     * A pinch losing a finger, however it lost it.
     *
     *   two or more left  - re-baseline on them; the pinch continues honestly.
     *   exactly one left  - the other finger is still holding the board. It
     *                       must not become a pan of whatever it is over, so
     *                       the pinch stays until it lifts too.
     *   none left         - the gesture is over, and the camera the user is
     *                       looking at is written down.
     */
    function endPinch(gg) {
      if (ptrs.size >= 2) { startPinch(true); return; }
      if (ptrs.size >= 1) {
        // Keep holding, but stop scaling against a pointer that has gone.
        gg.ids = Array.from(ptrs.keys()).slice(0, 2);
        gg.primed = false;
        return;
      }
      g = null;
      settle();
    }

    /*
     * pointercancel. Android raises it readily - a system edge gesture, a
     * notification shade, the app losing focus mid-drag - so this is an
     * ordinary ending and not an exceptional one.
     *
     * An item drag or a resize is ABANDONED: the finger stopped saying where
     * the card should go, and putting it wherever the last event was is worse
     * than putting it back. The CAMERA is not abandoned, because there is
     * nowhere to put it back to - applyCamera(live) never wrote it down, so the
     * board the user is looking at only becomes the board they saved if the
     * cancel commits it, exactly as an up would.
     */
    function onCancel(e) {
      forget(e.pointerId);
      if (!g) { clearLong(); return; }
      var gg = g;
      if (gg.type === 'pinch') { clearLong(); endPinch(gg); return; }
      // Somebody else's finger, exactly as in onUp. A cancel on a pointer this
      // gesture is not made of abandons a drag the user is still making.
      if (!mine(gg, e)) return;
      clearLong();
      g = null;
      if (gg.type === 'drag' && api.dragEnd) api.dragEnd(gg.ids, false, e);
      else if (gg.type === 'resize' && api.resizeEnd) api.resizeEnd(gg.id, gg.w0, false);
      else if (gg.type === 'linkdraw' && api.linkEnd) api.linkEnd(gg.id, gg.x0, gg.y0, false);
      else if (gg.type === 'pan' && gg.moved) settle();
    }

    /*
     * Capture taken away from under us - a browser or OS decision, not a
     * finger's. Without this the pointer stays in the map for ever, and the
     * gesture it belongs to never ends.
     */
    function onLostCapture(e) {
      if (!ptrs.has(e.pointerId)) return;
      onCancel(e);
    }

    /*
     * A trackpad or a wheel zooms about the pointer, which is the desktop
     * spelling of a pinch rather than an affordance of its own - the harness
     * runs on a laptop and the phone still has the gesture.
     */
    function onWheel(e) {
      if (!api.setCamera) return;
      e.preventDefault();
      var c = cam(), r = rect();
      var factor = Math.exp(-e.deltaY * (e.deltaMode === 1 ? 0.05 : 0.0025));
      var k = G.zoom(c.k * factor);
      if (k === null) return;
      var bx = (e.clientX - r.left - c.tx) / c.k, by = (e.clientY - r.top - c.ty) / c.k;
      api.setCamera(e.clientX - r.left - bx * k, e.clientY - r.top - by * k, k, false);
    }

    vp.addEventListener('pointerdown', onDown);
    vp.addEventListener('pointermove', onMove);
    vp.addEventListener('pointerup', onUp);
    vp.addEventListener('pointercancel', onCancel);
    vp.addEventListener('lostpointercapture', onLostCapture);
    vp.addEventListener('wheel', onWheel, { passive: false });

    return {
      active: function () { return g ? g.type : null; },
      // How many fingers this layer believes are down. The board has one
      // gesture handler for its whole life, so there is no detach; this is
      // here because a stuck pointer is the one state worth being able to ask
      // about from outside.
      pointers: function () { return ptrs.size; }
    };
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = BB;
})(typeof window !== 'undefined' ? window : globalThis);
