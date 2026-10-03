/*
 * Gantt pointer gestures (plan §13.1, §13.2, D9). One pointer-event state
 * machine on #gantt. It knows pointers, distances and timers and nothing
 * about charts: the owner says what a pointer landed on (api.hit), the
 * camera moves through api.panBy / api.zoomAt, and taps are reported.
 *
 * M5 built the navigation states: IDLE, the PRESS_* states, PAN, FLING and
 * PINCH. M6 adds ARMED, AXIS_PENDING, MOVE, RESIZE_S/E and REORDER:
 *   onLong      a long press on a bar the owner accepts (api.longPress
 *               returns true) is ARMED; on a name it starts a REORDER;
 *   pressMoved  a moving PRESS_BAR_SEL or mouse PRESS_BAR goes to
 *               AXIS_PENDING, a moving PRESS_HANDLE to RESIZE_S/E;
 *   axisMove    ARMED and AXIS_PENDING split into MOVE (|dx| >= |dy|) or
 *               REORDER once the pointer passed AXIS_LOCK_PX;
 *   onMove, onUp  a branch per drag state: api.dragMove (preview), api.drop
 *               (commit); edge autoscroll pans while the pointer is within
 *               EDGE_PX of the body and replays the preview;
 *   abandon     every path that ends a gesture without an up (pointercancel,
 *               lost capture, a second finger, stop() on hide, a stale
 *               sweep) calls api.cancelDrag(state) first, so a drag preview
 *               is always reverted (§13.2 "cancel → revert").
 * With no api.dragStart (or when it refuses) the drag states are never
 * entered and those presses pan, as in M5.
 *
 * Rules kept here (§13.1, §14.3):
 *   Pointer events only. api.hit runs first, only to leave buttons alone
 *   (a captured pointer would lose its click); every pointer the gesture
 *   takes is captured before its gesture is decided. lostpointercapture is
 *   a cancel; a pointer silent for STALE_MS and no longer captured is swept
 *   when a new one arrives.
 *   A pinch names its pointer pair (pa, pb) and re-baselines when the pair
 *   changes; below MIN_PINCH it pans but does not scale.
 *   No elementFromPoint and no layout reads: api.hit gets the event target.
 *   No allocation per move: pointer records, the gesture state, the velocity
 *   ring and the fling steps are allocated once.
 *   Pointer listeners are passive; the wheel listener is not.
 */
(function (global) {
  'use strict';
  var GT = (global.GT = global.GT || {});
  var G = (GT.gestures = {});

  G.SLOP_TOUCH = 8;          // px (§13.1)
  G.SLOP_MOUSE = 3;
  G.LONG_MS = 400;           // D9
  G.TAP_MS = 300;            // a press longer than this is not half of a double tap
  G.DOUBLE_MS = 300;
  G.DOUBLE_SLOP = 32;
  G.MIN_PINCH = 24;
  G.AXIS_LOCK_PX = 10;       // M6 (ARMED, AXIS_PENDING)
  G.HANDLE_SLOP = 4;         // M6 (PRESS_HANDLE)
  G.EDGE_PX = 36;            // M6 (edge autoscroll)
  G.EDGE_MAX_SPEED = 14;
  G.STALE_MS = 4000;
  G.VEL_MS = 100;            // the velocity window at release
  G.DOUBLE_ZOOM = 1.6;       // double tap and +/- (§11.4)
  G.WHEEL_ZOOM = 0.01;       // ctrl-wheel: exp(-deltaY * 0.01) (§11.4)
  G.WHEEL_LINE = 16;         // line-mode deltas (§13.2)
  G.WHEEL_PAGE = 400;

  // What a press on each kind of target becomes, and which axes it may pan
  // (1 = x, 2 = y). Names, group headers and the empty name column scroll
  // the rows only; the header scrolls time only. `rows` (the name column
  // below the last row) has no long press and no id.
  G.PRESS = {
    bg: 'PRESS_BG', bar: 'PRESS_BAR', barSel: 'PRESS_BAR_SEL', handle: 'PRESS_HANDLE',
    name: 'PRESS_NAME', group: 'PRESS_GROUP', header: 'PRESS_HDR', rows: 'PRESS_ROWS'
  };
  G.AXES = { bg: 3, bar: 3, barSel: 3, handle: 3, name: 2, group: 2, header: 1, rows: 2 };
  // Presses that arm the long-press timer (touch and pen only; §13.2). A
  // group header's long press opens its group sheet (task-groups plan §8.3).
  var LONG = { PRESS_BAR: true, PRESS_NAME: true, PRESS_GROUP: true };
  // The drag states (M6): a preview on every move, a commit on the up.
  var DRAGS = { MOVE: true, RESIZE_S: true, RESIZE_E: true, REORDER: true };
  G.DRAGS = DRAGS;

  function SC() { return GT.scale; }

  /*
   * attach(el, api, env) -> handle
   *
   * api (all optional except hit, toX, panBy, zoomAt):
   *   hit(target, clientX, clientY, out) -> out {kind, id} or null to leave
   *     the pointer alone (buttons keep their clicks). kind is one of the
   *     G.PRESS keys.
   *   toX(clientX) -> x in the timeline body (the zoom anchor).
   *   panBy(dx, dy) -> bitmask of the axes that moved (1 x, 2 y).
   *   zoomAt(f, x)          multiply ppd by f keeping the day under x.
   *   settle()              the camera came to rest (store view state).
   *   live(on)              a gesture holds the camera (no transitions).
   *   tap(kind, id, x, y)   a tap; header taps arrive after DOUBLE_MS.
   *   longPress(kind, id)   a press on a bar or name held for LONG_MS; its
   *                         release is not a tap. Returning true lifts it:
   *                         a bar becomes ARMED, a name starts a REORDER.
   *                         On a group header ('group', id) true means the
   *                         owner opened its group sheet (GROUP_SHEET: no
   *                         pan, no tap); false leaves an ordinary press.
   *   dragStart(state, id, x0, y0) -> true to take a drag (MOVE, RESIZE_S,
   *                         RESIZE_E, REORDER) of task `id` pressed at client
   *                         x0, y0; false refuses it and the pointer pans.
   *   dragMove(state, x, y) the pointer (client px) of a drag moved, or an
   *                         edge autoscroll moved the camera under it.
   *   drop(state, x, y)     the up of a drag, or of an ARMED bar (commit).
   *   edgeRect(out)         fills out {l, t, r, b}, the timeline body in
   *                         client px (from cached sizes), for autoscroll.
   *   cancelDrag(state)     the gesture in `state` ended without an up
   *                         (cancel, lost capture, second finger, stop,
   *                         sweep): revert any preview.
   * handle: state(), pointers(), pair(), flinging(), counts(), stopFling()
   *   (a toolbar action takes the camera), stop() (hide), detach().
   * env: {frame, cancelFrame, now, setTimeout, clearTimeout}; defaults are
   *   the page's (requestAnimationFrame, performance.now).
   */
  G.attach = function (el, api, env) {
    env = env || {};
    var now = env.now || function () { return global.performance && global.performance.now ? global.performance.now() : Date.now(); };
    var raf = env.frame || function (f) { return global.requestAnimationFrame(f); };
    var caf = env.cancelFrame || function (h) { global.cancelAnimationFrame(h); };
    var setT = env.setTimeout || function (f, ms) { return global.setTimeout(f, ms); };
    var clearT = env.clearTimeout || function (h) { global.clearTimeout(h); };

    var ptrs = new Map();
    var hitBuf = { kind: null, id: null, edge: null };
    // The one gesture in flight. Fields are reset, never reallocated.
    var g = {
      state: 'IDLE', ptr: null, kind: null, id: null, edge: null, mouse: false, slop: G.SLOP_TOUCH, axes: 3,
      x0: 0, y0: 0, t0: 0, lx: 0, ly: 0, moved: false, longFired: false, afterFling: false,
      pa: null, pb: null, primed: false, horiz: false, sep: 0, mx: 0, my: 0,
      fromPinch: false, panT0: 0, ex: 0, ey: 0,
      rect: { l: 0, t: 0, r: 0, b: 0 }
    };
    // Edge autoscroll (M6): the frame handle, its clock and the speed per axis.
    var edgeH = null, edgeT = 0, evx = 0, evy = 0;
    var liveOn = false;
    var longTimer = null;
    var lastTapT = -1e9, lastTapX = 0, lastTapY = 0, lastTapKind = null;
    var hdrTimer = null, hdrX = 0, hdrY = 0, hdrT = -1e9;
    // Velocity ring: t, x, y per sample.
    var RING = 16, ring = new Float64Array(RING * 3), ringN = 0, ringI = 0;
    // Fling: camera velocity in px/ms per axis, and one step object per axis.
    var fvx = 0, fvy = 0, flingT = 0, flingH = null;
    var fsx = { v: 0, dx: 0, done: true }, fsy = { v: 0, dx: 0, done: true };
    var counts = { pans: 0, zooms: 0, flingFrames: 0, taps: 0, edgeFrames: 0 };

    function live(on) {
      if (liveOn === on) return;
      liveOn = on;
      if (api.live) api.live(on);
    }
    function settle() { if (api.settle) api.settle(); }
    function clearLong() { if (longTimer !== null) { clearT(longTimer); longTimer = null; } }
    function clearHdr() { if (hdrTimer !== null) { clearT(hdrTimer); hdrTimer = null; } }

    function capture(id) { try { el.setPointerCapture(id); } catch (e) { /* synthetic or refused */ } }
    function forget(id) {
      ptrs.delete(id);
      try { el.releasePointerCapture(id); } catch (e) { /* never captured */ }
    }
    function reset() {
      g.state = 'IDLE'; g.ptr = null; g.pa = null; g.pb = null; g.kind = null; g.id = null; g.edge = null;
      g.moved = false; g.longFired = false; g.afterFling = false; g.primed = false; g.fromPinch = false;
      clearLong();
      stopEdge();
    }
    // A gesture ends without an up: the owner reverts any preview first (M6).
    function abandon(st) {
      stopEdge();
      if (api.cancelDrag && st !== 'IDLE' && st !== 'FLING') api.cancelDrag(st);
    }

    /* ---- drags (M6) ---- */
    // Enter a drag state if the owner takes it; the preview starts at once.
    function beginDrag(st) {
      if (!api.dragStart || api.dragStart(st, g.id, g.x0, g.y0) !== true) return false;
      clearLong();
      clearHdr();
      g.state = st;
      g.moved = true;
      g.ex = g.ptr ? g.ptr.x : g.x0;
      g.ey = g.ptr ? g.ptr.y : g.y0;
      g.rect.l = 0; g.rect.t = 0; g.rect.r = 0; g.rect.b = 0;
      if (api.edgeRect) api.edgeRect(g.rect);
      live(true);
      if (api.dragMove) api.dragMove(st, g.ex, g.ey);
      edgeCheck();
      return true;
    }
    // ARMED and AXIS_PENDING: past AXIS_LOCK_PX the dominant axis decides.
    function axisMove(rec) {
      var dx = rec.x - g.x0, dy = rec.y - g.y0;
      if (dx * dx + dy * dy < G.AXIS_LOCK_PX * G.AXIS_LOCK_PX) return;
      var from = g.state;
      if (beginDrag(Math.abs(dx) >= Math.abs(dy) ? 'MOVE' : 'REORDER')) return;
      // Refused: an ARMED lift is dropped and the pointer pans instead.
      if (from === 'ARMED' && api.cancelDrag) api.cancelDrag('ARMED');
      toPan(rec, g.axes);
      panMove(rec);
    }
    // Edge autoscroll: speed grows with the depth into the EDGE_PX band,
    // squared, up to EDGE_MAX_SPEED px per 60 Hz frame. MOVE and RESIZE
    // scroll time, REORDER scrolls rows.
    function edgeSpeed(p, lo, hi) {
      var d;
      if (p < lo + G.EDGE_PX) d = p - (lo + G.EDGE_PX);
      else if (p > hi - G.EDGE_PX) d = p - (hi - G.EDGE_PX);
      else return 0;
      var k = Math.min(1, Math.abs(d) / G.EDGE_PX);
      return (d < 0 ? -1 : 1) * G.EDGE_MAX_SPEED * k * k;
    }
    function edgeVel() {
      var r = g.rect;
      evx = 0; evy = 0;
      if (!(r.r > r.l) || !(r.b > r.t)) return;
      if (g.state === 'REORDER') evy = edgeSpeed(g.ey, r.t, r.b);
      else evx = edgeSpeed(g.ex, r.l, r.r);
    }
    function edgeCheck() {
      edgeVel();
      if ((evx || evy) && edgeH === null) { edgeT = now(); edgeH = raf(edgeStep); }
    }
    function edgeStep() {
      edgeH = null;
      if (DRAGS[g.state] !== true) return;
      var t = now(), dt = Math.max(1, Math.min(64, t - edgeT));
      edgeT = t;
      edgeVel();
      if (!evx && !evy) return;
      var f = dt / (1000 / 60);
      var moved = api.panBy(evx * f, evy * f) | 0;
      counts.edgeFrames++;
      // The drag delta includes the scrolled amount: replay the pointer.
      if (api.dragMove) api.dragMove(g.state, g.ex, g.ey);
      if (moved) edgeH = raf(edgeStep);
    }
    function stopEdge() { if (edgeH !== null) { caf(edgeH); edgeH = null; } }

    /* ---- velocity ---- */
    function sample(t, x, y) {
      ring[ringI * 3] = t; ring[ringI * 3 + 1] = x; ring[ringI * 3 + 2] = y;
      ringI = (ringI + 1) % RING;
      if (ringN < RING) ringN++;
    }
    var vel = { x: 0, y: 0 };
    // Finger velocity (px/ms) over the last VEL_MS of samples; zero when the
    // finger rested before lifting.
    function velocity() {
      vel.x = 0; vel.y = 0;
      if (ringN < 2) return vel;
      var last = (ringI - 1 + RING) % RING;
      var tl = ring[last * 3], xl = ring[last * 3 + 1], yl = ring[last * 3 + 2];
      var oi = last;
      for (var k = 1; k < ringN; k++) {
        var j = (last - k + RING) % RING;
        if (tl - ring[j * 3] > G.VEL_MS) break;
        oi = j;
      }
      var dt = tl - ring[oi * 3];
      if (dt < 1) return vel;
      vel.x = (xl - ring[oi * 3 + 1]) / dt;
      vel.y = (yl - ring[oi * 3 + 2]) / dt;
      return vel;
    }

    /* ---- fling ---- */
    function stopFling() {
      if (flingH !== null) { caf(flingH); flingH = null; }
      fvx = 0; fvy = 0;
      if (g.state === 'FLING') { reset(); live(false); settle(); return true; }
      return false;
    }
    function startFling(vx, vy, axes) {
      var min = SC().FLING_MIN_V;
      // The camera moves against the finger.
      fvx = axes & 1 ? -vx : 0;
      fvy = axes & 2 ? -vy : 0;
      if (Math.abs(fvx) < min) fvx = 0;
      if (Math.abs(fvy) < min) fvy = 0;
      if (!fvx && !fvy) return false;
      g.state = 'FLING';
      flingT = now();
      flingH = raf(flingStep);
      return true;
    }
    function flingStep() {
      flingH = null;
      if (g.state !== 'FLING') return;
      var t = now(), dt = t - flingT;
      flingT = t;
      counts.flingFrames++;
      SC().fling(fvx, dt, fsx);
      SC().fling(fvy, dt, fsy);
      var moved = api.panBy(fvx ? fsx.dx : 0, fvy ? fsy.dx : 0) | 0;
      // An axis that hit the edge stops; an axis below the minimum stops.
      fvx = fvx && !fsx.done && (moved & 1 || fsx.dx === 0) ? fsx.v : 0;
      fvy = fvy && !fsy.done && (moved & 2 || fsy.dx === 0) ? fsy.v : 0;
      if (!fvx && !fvy) { reset(); live(false); settle(); return; }
      flingH = raf(flingStep);
    }

    /* ---- pinch ---- */
    function baseline() {
      var a = g.pa, b = g.pb, dx = b.x - a.x, dy = b.y - a.y, d = Math.sqrt(dx * dx + dy * dy);
      g.mx = (a.x + b.x) / 2; g.my = (a.y + b.y) / 2;
      g.primed = d >= G.MIN_PINCH;
      g.horiz = Math.abs(dx) >= 0.5 * d;
      g.sep = g.horiz ? Math.abs(dx) : d;
    }
    // Name the first two pointers in the map as the pair.
    function firstTwo() {
      var a = null, b = null;
      ptrs.forEach(function (p) { if (!a) a = p; else if (!b) b = p; });
      g.pa = a; g.pb = b;
    }
    function toPinch(pa, pb) {
      abandon(g.state);
      clearLong();
      clearHdr();
      g.state = 'PINCH';
      g.ptr = null;
      g.moved = true;
      if (pa && pb) { g.pa = pa; g.pb = pb; } else firstTwo();
      baseline();
      live(true);
    }
    function pinchMove() {
      var a = g.pa, b = g.pb;
      var mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
      // Midpoint movement pans both axes (two-finger pan), primed or not.
      if (mx !== g.mx || my !== g.my) { api.panBy(g.mx - mx, g.my - my); counts.pans++; }
      g.mx = mx; g.my = my;
      var dx = b.x - a.x, dy = b.y - a.y, d = Math.sqrt(dx * dx + dy * dy);
      if (d < G.MIN_PINCH) { g.primed = false; return; }
      var horiz = Math.abs(dx) >= 0.5 * d, sep = horiz ? Math.abs(dx) : d;
      // The first honest separation, or a switch of measure, is a new
      // baseline and scales nothing.
      if (!g.primed || horiz !== g.horiz) { g.primed = true; g.horiz = horiz; g.sep = sep; return; }
      var f = sep / g.sep;
      g.sep = sep;
      if (!(f > 0) || !isFinite(f) || f === 1) return;
      api.zoomAt(f, api.toX(mx));
      counts.zooms++;
    }
    // One of the named pair went away.
    function pinchLost() {
      if (ptrs.size >= 2) { firstTwo(); baseline(); return; }
      if (ptrs.size === 1) {
        var rest = null;
        ptrs.forEach(function (p) { rest = p; });
        g.lx = rest.x; g.ly = rest.y;
        toPan(rest, 3);
        // Its samples so far are pinch motion: no fling until it has VEL_MS of its own.
        g.fromPinch = true;
        return;
      }
      reset();
      live(false);
      settle();
    }

    /* ---- pan ---- */
    function toPan(rec, axes) {
      clearLong();
      // A press that pans is not the second half of a header double tap,
      // and a pending header tap must not jump the view mid-pan: drop it.
      clearHdr();
      g.state = 'PAN';
      g.ptr = rec;
      g.axes = axes;
      g.moved = true;
      g.fromPinch = false;
      ringN = 0; ringI = 0;
      g.panT0 = now();
      sample(g.panT0, rec.x, rec.y);
      live(true);
    }
    function panMove(rec) {
      var dx = g.lx - rec.x, dy = g.ly - rec.y;
      g.lx = rec.x; g.ly = rec.y;
      sample(rec.t, rec.x, rec.y);
      if (!(g.axes & 1)) dx = 0;
      if (!(g.axes & 2)) dy = 0;
      if (dx || dy) { api.panBy(dx, dy); counts.pans++; }
    }

    /* ---- press ---- */
    function onLong() {
      longTimer = null;
      var st = g.state;
      // PRESS_GROUP (task-groups plan §8.3): LONG -> GROUP_SHEET when the
      // owner takes it; the gesture then ignores moves and its up is not a
      // tap. Refused, the press stays a press: move > slop pans, up folds.
      if (st === 'PRESS_GROUP') {
        if (!api.longPress || api.longPress('group', g.id) !== true) return;
        g.longFired = true;
        g.state = 'GROUP_SHEET';
        return;
      }
      if (st !== 'PRESS_BAR' && st !== 'PRESS_NAME') return;
      g.longFired = true;
      var lifted = api.longPress ? api.longPress(g.kind, g.id) === true : false;
      if (!lifted) return;
      // A bar waits for the axis (ARMED); a name row lifts into REORDER.
      if (st === 'PRESS_BAR') { g.state = 'ARMED'; g.moved = true; live(true); return; }
      beginDrag('REORDER');
    }
    function startPress(rec, e) {
      var kind = hitBuf.kind;
      g.state = G.PRESS[kind];
      g.ptr = rec; g.kind = kind; g.id = hitBuf.id; g.edge = hitBuf.edge || null;
      g.mouse = e.pointerType === 'mouse';
      g.slop = g.mouse ? G.SLOP_MOUSE : G.SLOP_TOUCH;
      g.axes = G.AXES[kind] || 3;
      g.x0 = g.lx = rec.x; g.y0 = g.ly = rec.y; g.t0 = rec.t;
      g.moved = false; g.longFired = false;
      clearLong();
      if (!g.mouse && LONG[g.state]) longTimer = setT(onLong, G.LONG_MS);
    }
    // A press moved past its slop. A swipe over a bar scrolls (§13.2); a
    // selected bar and a mouse press on any bar wait for the axis
    // (AXIS_PENDING); a handle resizes. Without a drag owner, every press pans.
    function pressMoved(rec) {
      var st = g.state;
      if (api.dragStart) {
        // A handle resizes on a horizontal move; a vertical one scrolls rows.
        if (st === 'PRESS_HANDLE' && Math.abs(rec.x - g.x0) >= Math.abs(rec.y - g.y0)) {
          if (beginDrag(g.edge === 's' ? 'RESIZE_S' : 'RESIZE_E')) return;
        } else if (st === 'PRESS_BAR_SEL' || (st === 'PRESS_BAR' && g.mouse)) {
          clearLong();
          g.state = 'AXIS_PENDING';
          g.moved = true;
          live(true);
          axisMove(rec);
          return;
        }
      }
      toPan(rec, g.axes);
      panMove(rec);
    }

    /* ---- taps ---- */
    function tapUp(rec) {
      counts.taps++;
      var x = api.toX(rec.x), kind = g.kind;
      var near = Math.abs(rec.x - lastTapX) + Math.abs(rec.y - lastTapY) < G.DOUBLE_SLOP;
      var quick = rec.t - g.t0 < G.TAP_MS;
      if (kind === 'header') {
        if (hdrTimer !== null && g.t0 - hdrT < G.DOUBLE_MS && Math.abs(rec.x - hdrX) + Math.abs(rec.y - hdrY) < G.DOUBLE_SLOP) {
          clearHdr();
          api.zoomAt(G.DOUBLE_ZOOM, x);
          counts.zooms++;
          settle();
          return;
        }
        clearHdr();
        if (!quick) { if (api.tap) api.tap('header', null, x, rec.y); return; }
        hdrX = rec.x; hdrY = rec.y; hdrT = rec.t;
        hdrTimer = setT(hdrFire, G.DOUBLE_MS);
        return;
      }
      if (kind === 'bg' && lastTapKind === 'bg' && near && g.t0 - lastTapT < G.DOUBLE_MS) {
        lastTapKind = null;
        api.zoomAt(G.DOUBLE_ZOOM, x);
        counts.zooms++;
        settle();
        return;
      }
      lastTapKind = quick ? kind : null;
      lastTapT = rec.t; lastTapX = rec.x; lastTapY = rec.y;
      if (api.tap) api.tap(kind, g.id, x, rec.y);
    }
    function hdrFire() {
      hdrTimer = null;
      if (api.tap) api.tap('header', null, api.toX(hdrX), hdrY);
    }

    /* ---- events ---- */
    // A finger resting still sends no moves (iOS), so silence alone is not
    // gone: a pointer we still hold captured is kept.
    function held(id) {
      try { return !!(el.hasPointerCapture && el.hasPointerCapture(id)); } catch (e) { return false; }
    }
    function prune(t) {
      var stale = null;
      ptrs.forEach(function (p, id) { if (t - p.t > G.STALE_MS && !held(id)) (stale = stale || []).push(id); });
      if (!stale) return;
      for (var i = 0; i < stale.length; i++) {
        var p = ptrs.get(stale[i]);
        forget(stale[i]);
        if (p === g.ptr || p === g.pa || p === g.pb) { var st = g.state; abandon(st); reset(); live(false); if (st !== 'IDLE' && st.indexOf('PRESS') !== 0) settle(); }
      }
    }

    function onDown(e) {
      if (e.pointerType === 'mouse' && e.button !== 0) return;
      hitBuf.kind = null; hitBuf.id = null; hitBuf.edge = null;
      var h = api.hit(e.target, e.clientX, e.clientY, hitBuf);
      if (!h || !G.PRESS[hitBuf.kind]) return;
      var t = now();
      prune(t);
      // Capture first, before anything decides what the gesture is (§13.1).
      capture(e.pointerId);
      var rec = ptrs.get(e.pointerId);
      if (!rec) { rec = { id: e.pointerId, x: 0, y: 0, t: 0 }; ptrs.set(e.pointerId, rec); }
      rec.x = e.clientX; rec.y = e.clientY; rec.t = t;
      // Any down stops a fling, and that press is not a tap.
      var stopped = stopFling();
      clearHdrIfFar(rec);
      if (ptrs.size === 2) {
        var other = g.ptr && g.ptr !== rec ? g.ptr : null;
        if (!other) ptrs.forEach(function (p) { if (p !== rec) other = p; });
        toPinch(other, rec);
        return;
      }
      if (ptrs.size > 2) return;              // a third finger joins nothing
      startPress(rec, e);
      g.afterFling = stopped;
    }
    // A second press far from a pending header tap lets that tap fire now.
    function clearHdrIfFar(rec) {
      if (hdrTimer === null) return;
      if (Math.abs(rec.x - hdrX) + Math.abs(rec.y - hdrY) >= G.DOUBLE_SLOP) { clearHdr(); hdrFire(); }
    }

    function onMove(e) {
      var rec = ptrs.get(e.pointerId);
      if (!rec) return;
      rec.x = e.clientX; rec.y = e.clientY; rec.t = now();
      var st = g.state;
      if (st === 'PINCH') { if (rec === g.pa || rec === g.pb) pinchMove(); return; }
      if (rec !== g.ptr) return;
      if (st === 'PAN') { panMove(rec); return; }
      if (DRAGS[st] === true) {
        g.ex = rec.x; g.ey = rec.y;
        if (api.dragMove) api.dragMove(st, rec.x, rec.y);
        edgeCheck();
        return;
      }
      if (st === 'ARMED' || st === 'AXIS_PENDING') { axisMove(rec); return; }
      if (st.indexOf('PRESS') === 0) {
        var slop = st === 'PRESS_HANDLE' ? G.HANDLE_SLOP : g.slop;
        var dx = rec.x - g.x0, dy = rec.y - g.y0;
        if (dx * dx + dy * dy < slop * slop) return;
        pressMoved(rec);
      }
    }

    function onUp(e) {
      var rec = ptrs.get(e.pointerId);
      if (!rec) return;
      rec.x = e.clientX; rec.y = e.clientY; rec.t = now();
      forget(e.pointerId);
      var st = g.state;
      if (st === 'PINCH') { if (rec === g.pa || rec === g.pb) pinchLost(); return; }
      if (rec !== g.ptr) return;
      // A drag commits on its up; an ARMED bar that never moved is dropped
      // in place (it stays selected). Neither is a tap.
      if (DRAGS[st] === true || st === 'ARMED') {
        stopEdge();
        // The up's own position is the last preview, so the commit matches it.
        if (DRAGS[st] === true) { g.ex = rec.x; g.ey = rec.y; if (api.dragMove) api.dragMove(st, rec.x, rec.y); }
        if (api.drop) api.drop(st, rec.x, rec.y);
        reset();
        live(false);
        settle();
        return;
      }
      if (st === 'AXIS_PENDING') { reset(); live(false); return; }
      if (st === 'PAN') {
        sample(rec.t, rec.x, rec.y);
        var v = velocity(), axes = g.axes;
        var own = !g.fromPinch || rec.t - g.panT0 >= G.VEL_MS;
        reset();
        if (!own || !startFling(v.x, v.y, axes)) { live(false); settle(); }
        return;
      }
      // A handle press that never moved is a no-op (§13.2), not a tap.
      var tap = st.indexOf('PRESS') === 0 && st !== 'PRESS_HANDLE' && !g.longFired && !g.afterFling;
      if (tap) tapUp(rec);
      reset();
    }

    function onCancel(e) {
      var rec = ptrs.get(e.pointerId);
      if (!rec) return;
      forget(e.pointerId);
      var st = g.state;
      if (st === 'PINCH') { if (rec === g.pa || rec === g.pb) pinchLost(); return; }
      if (rec !== g.ptr) return;
      // The system took the pointer: no pending header tap fires either.
      clearHdr();
      abandon(st);
      reset();
      if (st === 'PAN' || DRAGS[st] === true || st === 'ARMED' || st === 'AXIS_PENDING') { live(false); settle(); }
    }

    function onWheel(e) {
      e.preventDefault();
      stopFling();
      var k = e.deltaMode === 1 ? G.WHEEL_LINE : (e.deltaMode === 2 ? G.WHEEL_PAGE : 1);
      var dx = e.deltaX * k, dy = e.deltaY * k;
      if (e.ctrlKey) { api.zoomAt(Math.exp(-dy * G.WHEEL_ZOOM), api.toX(e.clientX)); counts.zooms++; }
      else if (e.shiftKey || Math.abs(dx) > Math.abs(dy)) api.panBy(dx || dy, 0);
      else api.panBy(0, dy);
      settle();
    }

    var PASSIVE = { passive: true }, ACTIVE = { passive: false };
    el.addEventListener('pointerdown', onDown, PASSIVE);
    el.addEventListener('pointermove', onMove, PASSIVE);
    el.addEventListener('pointerup', onUp, PASSIVE);
    el.addEventListener('pointercancel', onCancel, PASSIVE);
    el.addEventListener('lostpointercapture', onCancel, PASSIVE);
    el.addEventListener('wheel', onWheel, ACTIVE);

    return {
      state: function () { return g.state; },
      pointers: function () { return ptrs.size; },
      pair: function () { return g.pa && g.pb ? [g.pa.id, g.pb.id] : null; },
      flinging: function () { return g.state === 'FLING'; },
      counts: function () { return { pans: counts.pans, zooms: counts.zooms, flingFrames: counts.flingFrames, taps: counts.taps, edgeFrames: counts.edgeFrames }; },
      // Hidden or torn down: stop the fling and timers, forget every pointer
      // (§14.3 rule 9). The camera the user sees is settled.
      stop: function () {
        var was = g.state;
        if (flingH !== null) { caf(flingH); flingH = null; }
        fvx = 0; fvy = 0;
        clearHdr();
        abandon(was);
        ptrs.forEach(function (p, id) { try { el.releasePointerCapture(id); } catch (err) { /* ignore */ } });
        ptrs.clear();
        reset();
        live(false);
        if (was !== 'IDLE') settle();
      },
      // A toolbar action (Today, Fit all, D/W/M, +/-, going home) takes the
      // camera: a running fling stops; fingers on the glass are left alone.
      stopFling: function () { return stopFling(); },
      detach: function () {
        el.removeEventListener('pointerdown', onDown, PASSIVE);
        el.removeEventListener('pointermove', onMove, PASSIVE);
        el.removeEventListener('pointerup', onUp, PASSIVE);
        el.removeEventListener('pointercancel', onCancel, PASSIVE);
        el.removeEventListener('lostpointercapture', onCancel, PASSIVE);
        el.removeEventListener('wheel', onWheel, ACTIVE);
      }
    };
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
