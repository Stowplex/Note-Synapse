/*
 * Gantt gesture state machine (M5, plan §13.1, §13.2, §11.4): synthetic
 * pointer sequences against gestures.attach with a fake element, a fake
 * clock, hand-run frames and timers, and a camera that follows scale.js.
 * Runs under node (dev/run.js) and in the browser (dev/auto_smoke.html).
 */
(function (global) {
  'use strict';
  var GT = global.GT, SPEC = GT.spec;
  var A = SPEC.api, ok = A.ok, eq = A.eq;
  var G = GT.gestures, SC = GT.scale;

  var NAME_W = 100;              // the fake name column: body x = clientX - 100

  /*
   * rig(opts) -> a gestures handle over a fake element with helpers.
   * opts.bounds {lo, hi} clamps sx; opts.ppd starts the camera.
   */
  function rig(opts) {
    opts = opts || {};
    var L = {}, captured = [], released = [];
    var el = {
      addEventListener: function (n, f, o) { L[n] = { f: f, o: o }; },
      removeEventListener: function (n) { delete L[n]; },
      setPointerCapture: function (id) { captured.push(id); },
      releasePointerCapture: function (id) { released.push(id); }
    };
    // opts.held: pointer ids the element still reports as captured.
    if (opts.held) el.hasPointerCapture = function (id) { return opts.held.indexOf(id) >= 0; };
    var t = 1000, frames = [], timers = [];
    var env = {
      now: function () { return t; },
      frame: function (f) { frames.push(f); return frames.length; },
      cancelFrame: function (h) { frames[h - 1] = null; },
      setTimeout: function (f, ms) { timers.push({ f: f, at: t + ms, live: true }); return timers.length; },
      clearTimeout: function (h) { if (timers[h - 1]) timers[h - 1].live = false; }
    };
    var cam = { sx: 0, sy: 0, ppd: opts.ppd || 16, epoch: 0 };
    var log = { taps: [], longs: [], settles: 0, live: [], zooms: [], pans: 0, cancels: [] };
    var api = {
      hit: function (target, x, y, out) {
        if (!target || !target.kind) return null;
        out.kind = target.kind; out.id = target.id || null;
        if (target.edge) out.edge = target.edge;
        return out;
      },
      toX: function (x) { return x - NAME_W; },
      panBy: function (dx, dy) {
        var bx = cam.sx, by = cam.sy;
        cam.sx += dx; cam.sy += dy;
        if (opts.bounds) cam.sx = Math.max(opts.bounds.lo, Math.min(opts.bounds.hi, cam.sx));
        cam.sy = Math.max(0, cam.sy);
        log.pans++;
        return (cam.sx !== bx ? 1 : 0) | (cam.sy !== by ? 2 : 0);
      },
      zoomAt: function (f, x) { log.zooms.push([f, x]); SC.zoomAt(cam, f, x, cam); return true; },
      settle: function () { log.settles++; },
      live: function (on) { log.live.push(on); },
      tap: function (kind, id, x, y) { log.taps.push({ kind: kind, id: id, x: x, y: y }); }
    };
    if (opts.longPress !== false) api.longPress = function (kind, id) { log.longs.push(kind + ':' + id); };
    api.cancelDrag = function (state) { log.cancels.push(state); };
    // M6: opts.drag makes the rig a drag owner. opts.drag.lift (default
    // true) answers longPress, opts.drag.refuse lists states it refuses;
    // opts.drag.rect is the body rect for edge autoscroll.
    if (opts.drag) {
      var dopt = opts.drag;
      log.starts = []; log.moves = []; log.drops = [];
      api.longPress = function (kind, id) { log.longs.push(kind + ':' + id); return dopt.lift !== false; };
      api.dragStart = function (st, id, x0, y0) {
        if ((dopt.refuse || []).indexOf(st) >= 0) return false;
        log.starts.push(st + ':' + id + '@' + x0 + ',' + y0);
        return true;
      };
      api.dragMove = function (st, x, y) { log.moves.push([st, x, y, cam.sx, cam.sy]); };
      api.drop = function (st, x, y) { log.drops.push(st + '@' + x + ',' + y); };
      if (dopt.rect) api.edgeRect = function (out) { out.l = dopt.rect.l; out.t = dopt.rect.t; out.r = dopt.rect.r; out.b = dopt.rect.b; };
    }
    var h = G.attach(el, api, env);
    function ev(id, x, y, extra) {
      var e = { pointerId: id, clientX: x, clientY: y, pointerType: 'touch', button: 0, target: null, defaultPrevented: false };
      e.preventDefault = function () { e.defaultPrevented = true; };
      for (var k in extra) e[k] = extra[k];
      return e;
    }
    var r = {
      h: h, el: el, L: L, cam: cam, log: log, captured: captured, released: released, env: env,
      now: function () { return t; },
      down: function (id, x, y, kind, extra) { var e = ev(id, x, y, extra); e.target = kind ? (typeof kind === 'string' ? { kind: kind } : kind) : null; L.pointerdown.f(e); return e; },
      move: function (id, x, y, extra) { var e = ev(id, x, y, extra); L.pointermove.f(e); return e; },
      up: function (id, x, y, extra) { var e = ev(id, x, y, extra); L.pointerup.f(e); return e; },
      cancel: function (id) { L.pointercancel.f(ev(id, 0, 0)); },
      lost: function (id) { L.lostpointercapture.f(ev(id, 0, 0)); },
      wheel: function (o) { var e = ev(0, o.clientX || 0, o.clientY || 0, o); L.wheel.f(e); return e; },
      // Advance the clock, firing timers that come due.
      wait: function (ms) {
        var end = t + ms;
        for (;;) {
          var next = null;
          timers.forEach(function (x) { if (x.live && x.at <= end && (!next || x.at < next.at)) next = x; });
          if (!next) break;
          t = next.at; next.live = false; next.f();
        }
        t = end;
      },
      // Run queued frames, each dt ms apart, until none is queued (or n ran).
      frames: function (dt, n) {
        var ran = 0;
        while (ran < (n || 100000)) {
          var q = frames.filter(function (f) { return f; });
          frames.length = 0;
          if (!q.length) break;
          t += dt;
          q.forEach(function (f) { f(t); });
          ran++;
        }
        return ran;
      },
      pending: function () { return frames.filter(function (f) { return f; }).length; },
      // A straight drag of one pointer in `steps` moves, `dt` ms apart.
      drag: function (id, x0, y0, x1, y1, steps, dt) {
        for (var i = 1; i <= steps; i++) { t += dt; r.move(id, x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps); }
      }
    };
    return r;
  }
  function dayAt(cam, x) { return (cam.sx + x) / cam.ppd; }

  function constantsSpec() {
    eq('D9: LONG_MS 400', G.LONG_MS, 400);
    eq('D9: SLOP_TOUCH 8 and SLOP_MOUSE 3', [G.SLOP_TOUCH, G.SLOP_MOUSE].join(','), '8,3');
    eq('D9: DOUBLE_SLOP 32, DOUBLE_MS 300, TAP_MS 300', [G.DOUBLE_SLOP, G.DOUBLE_MS, G.TAP_MS].join(','), '32,300,300');
    eq('D9: MIN_PINCH 24', G.MIN_PINCH, 24);
    eq('§13.1: AXIS_LOCK_PX 10, EDGE_PX 36, EDGE_MAX_SPEED 14', [G.AXIS_LOCK_PX, G.EDGE_PX, G.EDGE_MAX_SPEED].join(','), '10,36,14');
    eq('§13.1: fling constants live in scale.js', [SC.FLING_MIN_V, SC.FLING_DECAY].join(','), '0.25,0.94');
    var r = rig();
    eq('attach listens to pointer events and wheel only', Object.keys(r.L).sort().join(','), 'lostpointercapture,pointercancel,pointerdown,pointermove,pointerup,wheel');
    ok('pointer listeners are passive', ['pointerdown', 'pointermove', 'pointerup', 'pointercancel', 'lostpointercapture'].every(function (n) { return r.L[n].o && r.L[n].o.passive === true; }));
    ok('the wheel listener is not passive', r.L.wheel.o && r.L.wheel.o.passive === false);
    var src = global.GT_SOURCES && global.GT_SOURCES['gestures.js'];
    if (src) src = src.replace(/\/\*[\s\S]*?\*\/|\/\/.*$/gm, '');   // code only
    if (src) {
      ok('gestures.js registers no touch or mouse listeners', !/'(touch|mouse)(start|move|end|down|up|cancel)'/.test(src));
      ok('gestures.js never calls elementFromPoint or reads layout', !/elementFromPoint|getBoundingClientRect|offset(Width|Height|Left|Top)|client(Width|Height)/.test(src));
      ok('gestures.js has no chart knowledge (no model, store or render)', !/GT\.(model|store|render|block|host)\b/.test(src));
      // §14.3 rule 4: the move path allocates nothing.
      ['onMove', 'panMove', 'pinchMove', 'flingStep', 'sample'].forEach(function (fn) {
        var m = new RegExp('function ' + fn + '\\([^)]*\\) \\{([\\s\\S]*?)\\n    \\}').exec(src);
        ok(fn + ' exists', !!m);
        if (m) ok(fn + ' allocates nothing (no new, closure, array or object literal)', !/\bnew\b|function\s*\(|\[\]|\{\s*[a-z]+:|\.slice\(|\.map\(|forEach|Array\.from/.test(m[1]), m[1]);
      });
    }
    var cam = { sx: 10, sy: 5, ppd: 16, epoch: 3 }, o1 = {};
    ok('scale.zoomAt can write into out (and into the camera itself)', SC.zoomAt(cam, 2, 50, o1) === o1 && SC.zoomAt(cam, 2, 50, cam) === cam && cam.ppd === 32);
    var fo = {};
    ok('scale.fling can write into out', SC.fling(1, 16, fo) === fo && fo.v < 1 && fo.dx > 0);
    eq('scale.fling without out still returns a fresh object', typeof SC.fling(1, 16).dx, 'number');
  }

  function panSpec() {
    var r = rig();
    var e0 = r.down(1, 300, 400, 'bg');
    eq('down on the grid: PRESS_BG', r.h.state(), 'PRESS_BG');
    eq('the pointer is captured on down', r.captured.join(','), '1');
    r.move(1, 295, 400);
    eq('5 px is inside the touch slop: still a press', r.h.state(), 'PRESS_BG');
    eq('... and the camera has not moved', r.cam.sx, 0);
    r.move(1, 292.1, 400);
    eq('7.9 px is still inside the slop', r.h.state(), 'PRESS_BG');
    r.move(1, 292, 400);
    eq('8 px starts a PAN', r.h.state(), 'PAN');
    eq('the pan includes the travel inside the slop', r.cam.sx, 8);
    r.move(1, 250, 380);
    eq('pan: the camera follows the finger across', r.cam.sx, 50);
    eq('pan: and down', r.cam.sy, 20);
    eq('live(true) once the pan starts', r.log.live.join(','), 'true');
    r.wait(300);
    r.up(1, 250, 380);
    eq('a finger that rested before lifting does not fling', r.h.state(), 'IDLE');
    eq('the pan settles once', r.log.settles, 1);
    eq('live(false) at the end', r.log.live.join(','), 'true,false');
    eq('no tap after a pan', r.log.taps.length, 0);
    eq('no pointer left', r.h.pointers(), 0);
    ok('the pointer capture is released', r.released.indexOf(1) >= 0);
    ok('the down event itself is not cancelled (passive)', !e0.defaultPrevented);

    // Mouse slop is 3 px.
    var m = rig();
    m.down(2, 300, 300, 'bg', { pointerType: 'mouse' });
    m.move(2, 297.5, 300, { pointerType: 'mouse' });
    eq('mouse: 2.5 px is a press', m.h.state(), 'PRESS_BG');
    m.move(2, 297, 300, { pointerType: 'mouse' });
    eq('mouse: 3 px pans', m.h.state(), 'PAN');
    m.up(2, 297, 300);
    var m2 = rig();
    m2.down(3, 300, 300, 'bg', { pointerType: 'mouse', button: 2 });
    eq('mouse: a right button press is ignored', m2.h.state() + ':' + m2.h.pointers() + ':' + m2.captured.length, 'IDLE:0:0');

    // Axes per target.
    var n = rig();
    n.down(4, 50, 300, { kind: 'name', id: 't1' });
    n.move(4, 10, 250);
    eq('a press on a name row pans rows only (vertical)', n.cam.sx + ',' + n.cam.sy, '0,50');
    n.up(4, 10, 250);
    var hd = rig();
    hd.down(5, 300, 20, 'header');
    hd.move(5, 250, 60);
    eq('a press on the header pans time only (horizontal)', hd.cam.sx + ',' + hd.cam.sy, '50,0');
    hd.up(5, 250, 60);
    var gr = rig();
    gr.down(6, 50, 300, { kind: 'group', id: 'g1' });
    gr.move(6, 30, 260);
    eq('a press on a group header pans rows only', gr.cam.sx + ',' + gr.cam.sy, '0,40');
    gr.up(6, 30, 260);
    eq('... and is not a tap', gr.log.taps.length, 0);

    // A swipe over a bar pans (§13.2), even with a long press due.
    var b = rig();
    b.down(7, 300, 300, { kind: 'bar', id: 't3' });
    eq('down on a bar: PRESS_BAR', b.h.state(), 'PRESS_BAR');
    b.move(7, 280, 300);
    eq('a swipe over a bar is a PAN', b.h.state(), 'PAN');
    b.wait(500);
    eq('the long press never fires after the swipe', b.log.longs.length, 0);
    b.up(7, 280, 300);
    eq('... and it is not a tap', b.log.taps.length, 0);
    // A selected bar and a handle pan too in M5 (M6 drags them).
    ['barSel', 'handle'].forEach(function (k) {
      var x = rig();
      x.down(8, 300, 300, { kind: k, id: 't1' });
      x.move(8, 270, 300);
      eq('M5: a moving press on ' + k + ' pans', x.h.state() + ':' + x.cam.sx, 'PAN:30');
      x.up(8, 270, 300);
    });

    // Nothing captured for a pointer the owner leaves alone (buttons).
    var z = rig();
    z.down(9, 10, 10, null);
    eq('a pointer on a button is left alone: no capture, no state', z.h.state() + ':' + z.captured.length + ':' + z.h.pointers(), 'IDLE:0:0');
  }

  function tapSpec() {
    var r = rig();
    r.down(1, 300, 400, 'bg');
    r.wait(80);
    r.up(1, 302, 401);
    eq('tap on the grid', JSON.stringify(r.log.taps), JSON.stringify([{ kind: 'bg', id: null, x: 202, y: 401 }]));
    r.wait(1000);
    r.down(2, 300, 400, { kind: 'bar', id: 't2' });
    r.wait(100);
    r.up(2, 300, 400);
    eq('tap on a bar before LONG_MS', r.log.taps[1].kind + ':' + r.log.taps[1].id, 'bar:t2');
    r.down(3, 60, 400, { kind: 'group', id: 'g1' });
    r.up(3, 60, 400);
    eq('tap on a group header', r.log.taps[2].kind + ':' + r.log.taps[2].id, 'group:g1');
    r.down(4, 60, 400, { kind: 'name', id: 't1' });
    r.up(4, 60, 400);
    eq('tap on a name row', r.log.taps[3].kind + ':' + r.log.taps[3].id, 'name:t1');

    // Long press on a bar.
    var l = rig();
    l.down(1, 300, 300, { kind: 'bar', id: 't1' });
    l.wait(399);
    eq('no long press at 399 ms', l.log.longs.length, 0);
    l.wait(1);
    eq('long press at 400 ms (D9)', l.log.longs.join(','), 'bar:t1');
    l.up(1, 300, 300);
    eq('the release after a long press is not a tap', l.log.taps.length, 0);
    var ln = rig();
    ln.down(1, 50, 300, { kind: 'name', id: 't4' });
    ln.wait(400);
    eq('long press on a name row', ln.log.longs.join(','), 'name:t4');
    ln.up(1, 50, 300);
    var lb = rig();
    lb.down(1, 300, 300, 'bg');
    lb.wait(1000);
    lb.up(1, 300, 300);
    eq('the grid has no long press', lb.log.longs.length, 0);
    var lm = rig();
    lm.down(1, 300, 300, { kind: 'bar', id: 't1' }, { pointerType: 'mouse' });
    lm.wait(1000);
    eq('mouse: no long press (§13.2)', lm.log.longs.length, 0);
    lm.up(1, 300, 300, { pointerType: 'mouse' });

    // Double tap on the grid zooms x1.6 at the point, keeping its day.
    var d = rig();
    d.down(1, 300, 400, 'bg'); d.wait(60); d.up(1, 300, 400);
    var before = dayAt(d.cam, 200);
    d.wait(150);
    d.down(2, 310, 405, 'bg'); d.wait(60); d.up(2, 310, 405);
    eq('double tap zooms x1.6 at the point', JSON.stringify(d.log.zooms), JSON.stringify([[1.6, 210]]));
    eq('the camera zoomed', d.cam.ppd, 16 * 1.6);
    ok('... keeping the day under the second tap', Math.abs(dayAt(d.cam, 210) - (d.cam.sx + 210) / d.cam.ppd) < 1e-9 && Math.abs((0 + 210) / 16 - dayAt(d.cam, 210)) < 1e-9, String(before));
    eq('only the first tap is reported as a tap', d.log.taps.length, 1);
    eq('the double tap settles', d.log.settles, 1);
    var d2 = rig();
    d2.down(1, 300, 400, 'bg'); d2.up(1, 300, 400);
    d2.wait(301);
    d2.down(2, 300, 400, 'bg'); d2.up(2, 300, 400);
    eq('two taps more than DOUBLE_MS apart are two taps', d2.log.zooms.length + ':' + d2.log.taps.length, '0:2');
    var d3 = rig();
    d3.down(1, 300, 400, 'bg'); d3.up(1, 300, 400);
    d3.wait(100);
    d3.down(2, 340, 400, 'bg'); d3.up(2, 340, 400);
    eq('two taps DOUBLE_SLOP or more apart are two taps', d3.log.zooms.length + ':' + d3.log.taps.length, '0:2');
    var d4 = rig();
    d4.down(1, 300, 400, 'bg'); d4.up(1, 300, 400);
    d4.wait(100);
    d4.down(2, 300, 400, 'bg'); d4.up(2, 300, 400);
    d4.wait(100);
    d4.down(3, 300, 400, 'bg'); d4.up(3, 300, 400);
    eq('a third quick tap starts over (no second zoom)', d4.log.zooms.length, 1);

    // Header: a tap jumps after DOUBLE_MS; a double tap zooms in instead.
    var h = rig();
    h.down(1, 260, 20, 'header'); h.wait(50); h.up(1, 260, 20);
    eq('a header tap waits for a possible second tap', h.log.taps.length, 0);
    h.wait(300);
    eq('... then arrives with its body x', JSON.stringify(h.log.taps), JSON.stringify([{ kind: 'header', id: null, x: 160, y: 20 }]));
    var hh = rig();
    hh.down(1, 260, 20, 'header'); hh.up(1, 260, 20);
    hh.wait(120);
    hh.down(2, 262, 22, 'header'); hh.up(2, 262, 22);
    hh.wait(1000);
    eq('a double tap on the header zooms in at the point', JSON.stringify(hh.log.zooms), JSON.stringify([[1.6, 162]]));
    eq('... and reports no tap', hh.log.taps.length, 0);
    var hf = rig();
    hf.down(1, 260, 20, 'header'); hf.up(1, 260, 20);
    hf.wait(50);
    hf.down(2, 400, 300, 'bg');
    eq('a press far away lets a pending header tap fire at once', hf.log.taps.length && hf.log.taps[0].kind, 'header');
    hf.up(2, 400, 300);
  }

  function flingSpec() {
    // Finger at -1 px/ms for 160 ms, then lift: the camera flings on.
    function flingAt(hz, v) {
      var r = rig({ ppd: 16 });
      r.down(1, 600, 300, 'bg');
      r.drag(1, 600, 300, 600 - 160 * v, 300, 10, 16);
      var afterPan = r.cam.sx;
      r.up(1, 600 - 160 * v, 300);
      var st = r.h.state();
      var n = r.frames(1000 / hz);
      return { r: r, afterPan: afterPan, state: st, frames: n, total: r.cam.sx - afterPan };
    }
    var a = flingAt(60, 1);
    eq('a fast release starts a FLING', a.state, 'FLING');
    ok('the fling carries the camera on in the same direction', a.total > 50, String(a.total));
    eq('the fling ends in IDLE', a.r.h.state(), 'IDLE');
    eq('the fling settles once at its end', a.r.log.settles, 1);
    eq('live stays on through the fling and goes off at its end', a.r.log.live.join(','), 'true,false');
    // The analytic distance of an exponential fling from 1 px/ms until 0.25 px/ms.
    var K = -Math.log(SC.FLING_DECAY) / (1000 / 60), want = (1 - SC.FLING_STOP_V) / K;
    ok('fling distance matches the decay integral within 5% (' + a.total.toFixed(1) + ' vs ' + want.toFixed(1) + ')', Math.abs(a.total - want) / want < 0.05);
    var b = flingAt(120, 1);
    ok('60 Hz and 120 Hz fling the same distance within 2% (' + a.total.toFixed(2) + ' / ' + b.total.toFixed(2) + ')', Math.abs(a.total - b.total) / a.total < 0.02);
    ok('120 Hz runs about twice the frames', b.frames > 1.7 * a.frames);
    var slow = flingAt(60, 0.2);
    eq('below FLING_MIN_V there is no fling', slow.state, 'IDLE');
    // Steps decay.
    var r = rig();
    r.down(1, 600, 300, 'bg');
    r.drag(1, 600, 300, 440, 300, 10, 16);
    r.up(1, 440, 300);
    var xs = [];
    for (var i = 0; i < 5; i++) { var s0 = r.cam.sx; r.frames(16, 1); xs.push(r.cam.sx - s0); }
    ok('fling steps decay frame by frame', xs.every(function (d, k) { return k === 0 || d < xs[k - 1]; }) && xs[0] > 0, xs.join(','));
    // A down stops the fling, and that press is not a tap.
    var sx = r.cam.sx;
    r.down(2, 300, 300, 'bg');
    eq('any down stops the fling', r.h.state(), 'PRESS_BG');
    r.frames(16);
    eq('... and the camera stays put', r.cam.sx, sx);
    r.up(2, 300, 300);
    eq('the press that stopped a fling is not a tap', r.log.taps.length, 0);
    // Vertical fling, and an axis that hits the edge stops.
    var e = rig({ bounds: { lo: 0, hi: 150 } });
    e.down(1, 600, 300, 'bg');
    e.drag(1, 600, 300, 480, 140, 10, 16);
    e.up(1, 480, 140);
    var n = e.frames(16);
    eq('the x axis stops at the edge while y flings on', e.cam.sx, 150);
    ok('the fling ran on in y', e.cam.sy > 170, String(e.cam.sy));
    ok('and ended', e.h.state() === 'IDLE' && n > 3);
    var e2 = rig({ bounds: { lo: 0, hi: 130 } });
    e2.down(1, 600, 300, 'bg');
    e2.drag(1, 600, 300, 480, 300, 10, 16);
    e2.up(1, 480, 300);
    var n2 = e2.frames(16);
    ok('a fling that reaches the edge ends at once (' + n2 + ' frames)', e2.cam.sx === 130 && n2 <= 3 && e2.h.state() === 'IDLE');
    // Only the last VEL_MS count: fast at first, then slow for 128 ms.
    var vw = rig();
    vw.down(1, 600, 300, 'bg');
    vw.drag(1, 600, 300, 450, 300, 5, 16);
    vw.drag(1, 450, 300, 442, 300, 8, 16);
    vw.up(1, 442, 300);
    eq('the release velocity comes from the last VEL_MS only (slow end: no fling)', vw.h.state(), 'IDLE');
    var hdr = rig();
    hdr.down(1, 600, 20, 'header');
    hdr.drag(1, 600, 20, 440, 200, 10, 16);
    hdr.up(1, 440, 200);
    hdr.frames(16);
    eq('a header fling moves time only', hdr.cam.sy, 0);
    ok('... and does move time', hdr.cam.sx > 200);
    // Hide stops it (§14.3 rule 9).
    var h = rig();
    h.down(1, 600, 300, 'bg');
    h.drag(1, 600, 300, 440, 300, 10, 16);
    h.up(1, 440, 300);
    h.frames(16, 2);
    h.h.stop();
    var hx = h.cam.sx;
    h.frames(16);
    eq('stop() ends a fling at once', h.cam.sx + ':' + h.h.state() + ':' + h.pending(), hx + ':IDLE:0');
    eq('... and settles', h.log.settles, 1);
    // The wheel stops a fling too.
    var w = rig();
    w.down(1, 600, 300, 'bg');
    w.drag(1, 600, 300, 440, 300, 10, 16);
    w.up(1, 440, 300);
    w.wheel({ deltaY: 10 });
    eq('a wheel event stops the fling', w.h.state(), 'IDLE');
  }

  function pinchSpec() {
    var r = rig({ ppd: 16 });
    r.cam.sx = 400;
    r.down(1, 300, 300, 'bg');
    r.move(1, 300, 300);
    r.down(2, 400, 300, 'bg');
    eq('a second finger makes a PINCH', r.h.state(), 'PINCH');
    eq('the pinch names its pair', JSON.stringify(r.h.pair()), '[1,2]');
    var dA = dayAt(r.cam, 200), dB = dayAt(r.cam, 300);
    // Fingers spread and drift right.
    r.move(2, 460, 310);
    r.move(1, 280, 310);
    r.move(2, 520, 320);
    ok('the pinch zoomed in', r.cam.ppd > 16 * 2.3, String(r.cam.ppd));
    ok('the day under finger 1 stays under it (focal anchoring)', Math.abs(dayAt(r.cam, 180) - dA) < 1e-9, (dayAt(r.cam, 180) - dA).toString());
    ok('the day under finger 2 stays under it', Math.abs(dayAt(r.cam, 420) - dB) < 1e-9, (dayAt(r.cam, 420) - dB).toString());
    eq('zooms use the named pair\'s midpoint (body x)', r.log.zooms[r.log.zooms.length - 1][1], 300);
    // Zoom stays horizontal: rows keep their height and the vertical pan follows the midpoint.
    eq('the midpoint moving down pans rows by the same amount', r.cam.sy, 0);
    // A third finger joins nothing.
    var z = r.log.zooms.length, cam = JSON.stringify(r.cam);
    r.down(3, 100, 500, 'bg');
    eq('a third finger keeps the pair', JSON.stringify(r.h.pair()), '[1,2]');
    r.move(3, 50, 600);
    eq('... and moving it changes nothing', JSON.stringify(r.cam) + r.log.zooms.length, cam + z);
    r.up(3, 50, 600);
    eq('... nor does lifting it', r.h.state() + JSON.stringify(r.cam), 'PINCH' + cam);
    // Lift one of the pair while another finger is down: re-baseline on the new pair.
    r.down(4, 600, 300, 'bg');
    r.up(1, 280, 310);
    eq('losing a named finger with two left re-baselines on them', JSON.stringify(r.h.pair()), '[2,4]');
    eq('... with no zoom at the switch', r.log.zooms.length, z);
    var d2 = dayAt(r.cam, 420), d4 = dayAt(r.cam, 500);
    r.move(4, 680, 300);
    ok('the new pair zooms from its own baseline, day under finger 2 kept', Math.abs(dayAt(r.cam, 420) - d2) < 1e-9);
    ok('... and under finger 4', Math.abs(dayAt(r.cam, 580) - d4) < 1e-9);
    // One lifts: PAN re-baselined with the other.
    r.up(2, 520, 320);
    eq('one finger left: PAN', r.h.state(), 'PAN');
    var sx = r.cam.sx;
    r.move(4, 670, 300);
    eq('... re-baselined: the pan follows that finger without a jump', r.cam.sx - sx, 10);
    r.wait(300);
    r.up(4, 670, 300);
    eq('... and its release is not a tap', r.log.taps.length, 0);
    eq('the camera settled once at the end of the whole gesture', r.log.settles, 1);
    eq('no pointer left', r.h.pointers(), 0);

    // Minimum separation: two fingers landing together pan but do not scale.
    var m = rig();
    m.down(1, 300, 300, 'bg');
    m.down(2, 310, 300, 'bg');
    m.move(2, 318, 300);
    eq('below MIN_PINCH nothing scales', m.log.zooms.length, 0);
    m.move(2, 330, 300);
    eq('the first separation over MIN_PINCH is a baseline, not a scale', m.log.zooms.length, 0);
    m.move(2, 360, 300);
    eq('then the pinch scales against that baseline (30 -> 60 px)', m.log.zooms.length && m.log.zooms[0][0], 2);
    m.move(2, 315, 300);
    var zc = m.log.zooms.length;
    ok('fingers pinched together below MIN_PINCH stop scaling', zc === 1, String(zc));
    // Separation measure: horizontal when |dx| >= 0.5 * dist, else full distance.
    var v = rig();
    v.down(1, 300, 300, 'bg');
    v.down(2, 300, 360, 'bg');
    v.move(2, 300, 420);
    eq('a vertical pinch uses the full distance (60 -> 120)', v.log.zooms[0] && v.log.zooms[0][0], 2);
    var hz = rig();
    hz.down(1, 300, 300, 'bg');
    hz.down(2, 360, 330, 'bg');
    hz.move(2, 420, 330);
    eq('a mostly horizontal pinch uses the horizontal separation (60 -> 120)', hz.log.zooms[0] && hz.log.zooms[0][0], 2);
    // Switching measure (horizontal 60 px to a 67 px diagonal) is a new
    // baseline, not a 1.12x jump.
    var sw = rig();
    sw.down(1, 300, 300, 'bg');
    sw.down(2, 360, 300, 'bg');
    sw.move(2, 330, 360);
    eq('a switch of separation measure scales nothing', sw.log.zooms.length, 0);
    sw.move(2, 330, 420);
    ok('... and the next move scales against the new measure', sw.log.zooms.length === 1 && Math.abs(sw.log.zooms[0][0] - Math.sqrt(30 * 30 + 120 * 120) / Math.sqrt(30 * 30 + 60 * 60)) < 1e-12);

    // Two-finger pan.
    var p = rig();
    p.cam.sx = 500;
    p.down(1, 300, 300, 'bg');
    p.down(2, 400, 300, 'bg');
    p.cam.sy = 200;
    var p1 = dayAt(p.cam, 200);
    // Events arrive one finger at a time, so the separation wobbles in
    // between; after both moved the scale is back where it was.
    p.move(1, 340, 330);
    p.move(2, 440, 330);
    ok('two fingers moving together pan time with the fingers', Math.abs(p.cam.sx - 460) < 1e-9, String(p.cam.sx));
    ok('... and scroll rows with them', Math.abs(p.cam.sy - 170) < 1e-9, String(p.cam.sy));
    ok('... with no net scale', Math.abs(p.cam.ppd - 16) < 1e-9, String(p.cam.ppd));
    ok('... the day under the first finger stays under it', Math.abs(dayAt(p.cam, 240) - p1) < 1e-9);
    p.move(1, 340, 280);
    p.move(2, 440, 280);
    ok('a two-finger drag up scrolls rows down', Math.abs(p.cam.sy - 220) < 1e-9, String(p.cam.sy));
    ok('... with no net scale', Math.abs(p.cam.ppd - 16) < 1e-9);

    // A second finger during a press cancels the long press and the tap.
    var c = rig();
    c.down(1, 300, 300, { kind: 'bar', id: 't1' });
    c.wait(200);
    c.down(2, 400, 300, 'bg');
    c.wait(400);
    eq('a second finger during a press cancels the long press', c.log.longs.length, 0);
    c.up(2, 400, 300);
    c.up(1, 300, 300);
    eq('... and neither release is a tap', c.log.taps.length, 0);
    eq('... the gesture ended', c.h.state() + ':' + c.h.pointers(), 'IDLE:0');
    // A second finger during a pan becomes a pinch too.
    var pp = rig();
    pp.down(1, 300, 300, 'bg');
    pp.move(1, 250, 300);
    pp.down(2, 400, 300, 'bg');
    eq('a second finger during a PAN is a PINCH', pp.h.state(), 'PINCH');
    eq('... named with the panning finger first', JSON.stringify(pp.h.pair()), '[1,2]');
  }

  function cancelSpec() {
    var r = rig();
    r.down(1, 600, 300, 'bg');
    r.drag(1, 600, 300, 440, 300, 10, 16);
    r.cancel(1);
    eq('pointercancel during a pan ends it without a fling', r.h.state() + ':' + r.pending(), 'IDLE:0');
    eq('... and settles', r.log.settles, 1);
    var l = rig();
    l.down(1, 600, 300, 'bg');
    l.drag(1, 600, 300, 440, 300, 10, 16);
    l.lost(1);
    eq('lostpointercapture is a cancel', l.h.state() + ':' + l.h.pointers(), 'IDLE:0');
    var lp = rig();
    lp.down(1, 300, 300, 'bg');
    lp.down(2, 400, 300, 'bg');
    lp.lost(2);
    eq('a lost capture in a pinch leaves a pan on the other finger', lp.h.state(), 'PAN');
    lp.cancel(1);
    eq('... and a cancel on that one ends it', lp.h.state() + ':' + lp.h.pointers(), 'IDLE:0');
    var p = rig();
    p.down(1, 300, 300, { kind: 'bar', id: 't1' });
    p.cancel(1);
    p.wait(1000);
    eq('a cancelled press is neither a tap nor a long press', p.log.taps.length + ':' + p.log.longs.length, '0:0');
    // Stale pointers are swept when a new one arrives (§13.1).
    var s = rig();
    s.down(1, 300, 300, 'bg');
    s.wait(G.STALE_MS + 1);
    s.down(2, 500, 300, 'bg');
    eq('a pointer silent for STALE_MS is swept: the new finger is a press, not a pinch', s.h.state() + ':' + s.h.pointers(), 'PRESS_BG:1');
    var s2 = rig();
    s2.down(1, 300, 300, 'bg');
    s2.wait(G.STALE_MS - 100);
    s2.down(2, 500, 300, 'bg');
    eq('a pointer heard from recently is kept: a pinch', s2.h.state(), 'PINCH');
    // A foreign finger's up does not end the gesture.
    var f = rig();
    f.down(1, 300, 300, 'bg');
    f.move(1, 250, 300);
    f.up(9, 0, 0);
    eq('an up for a pointer this layer never saw is ignored', f.h.state(), 'PAN');
    f.up(1, 250, 300);
  }

  function wheelSpec() {
    var r = rig({ ppd: 16 });
    r.cam.sx = 300;
    var d0 = dayAt(r.cam, 150);
    var e = r.wheel({ ctrlKey: true, deltaY: -50, clientX: 250 });
    ok('ctrl-wheel is prevented (no page zoom)', e.defaultPrevented);
    eq('ctrl-wheel zooms by exp(-deltaY * 0.01) at the cursor', JSON.stringify(r.log.zooms[0]), JSON.stringify([Math.exp(0.5), 150]));
    ok('... keeping the day under the cursor', Math.abs(dayAt(r.cam, 150) - d0) < 1e-9);
    r.wheel({ ctrlKey: true, deltaY: 3, deltaMode: 1, clientX: 250 });
    eq('line-mode deltas count 16 px', r.log.zooms[1][0], Math.exp(-0.48));
    var p = rig();
    var w1 = p.wheel({ deltaX: 0, deltaY: 30 });
    eq('a plain wheel scrolls rows', p.cam.sx + ',' + p.cam.sy, '0,30');
    ok('... and is prevented too (the page never scrolls)', w1.defaultPrevented);
    p.wheel({ deltaX: 40, deltaY: 10 });
    eq('a dominant deltaX pans time', p.cam.sx, 40);
    p.wheel({ deltaY: 25, shiftKey: true });
    eq('shift+wheel pans time', p.cam.sx, 65);
    p.wheel({ deltaY: 2, deltaMode: 1 });
    eq('line mode scrolls 16 px per line', p.cam.sy, 62);
    eq('every wheel event settles the camera', p.log.settles, 4);
  }

  function stopSpec() {
    var r = rig();
    r.down(1, 300, 300, 'bg');
    r.down(2, 400, 300, 'bg');
    r.h.stop();
    eq('stop() forgets every pointer', r.h.pointers() + ':' + r.h.state(), '0:IDLE');
    eq('... releases their capture', r.released.sort().join(','), '1,2');
    eq('... and ends live mode', r.log.live[r.log.live.length - 1], false);
    r.move(1, 200, 300);
    r.up(1, 200, 300);
    eq('events for the forgotten pointers do nothing', r.log.pans + ':' + r.log.taps.length, '0:0');
    var d = rig();
    d.h.detach();
    eq('detach removes every listener', Object.keys(d.L).length, 0);
  }

  // M5 review round 1: each block failed before its fix.
  // Each block runs on its own, so a throw in one (a missing function on
  // the unfixed code) cannot hide the others.
  function part(name, fn) {
    try { fn(); } catch (e) { ok('review 1: ' + name + ' ran to the end', false, String((e && e.stack) || e)); }
  }
  function review1Spec() {
    part('major', function () {
    // [major] A staggered two-finger release must not fling on pinch motion.
    var r = rig();
    r.cam.sx = 500;
    r.down(1, 300, 300, 'bg');
    r.down(2, 400, 300, 'bg');
    r.drag(2, 400, 300, 500, 300, 5, 16);
    r.up(1, 300, 300);
    eq('one finger of a pinch lifts: PAN', r.h.state(), 'PAN');
    r.drag(2, 500, 300, 460, 300, 3, 16);
    r.up(2, 460, 300);
    eq('the last finger lifting within VEL_MS of the pinch does not fling', r.h.state() + ':' + r.pending(), 'IDLE:0');
    eq('... and the gesture settles once', r.log.settles, 1);
    var r2 = rig();
    r2.cam.sx = 500;
    r2.down(1, 300, 300, 'bg');
    r2.down(2, 400, 300, 'bg');
    r2.up(1, 300, 300);
    r2.drag(2, 400, 300, 240, 300, 10, 16);
    r2.up(2, 240, 300);
    eq('after VEL_MS of its own motion the last finger may fling', r2.h.state(), 'FLING');

    });
    part('stopFling', function () {
    // [minor] stopFling for toolbar actions.
    var f = rig();
    f.down(1, 600, 300, 'bg');
    f.drag(1, 600, 300, 440, 300, 10, 16);
    f.up(1, 440, 300);
    ok('stopFling() stops a running fling', f.h.stopFling() === true && f.h.state() === 'IDLE' && f.pending() === 0);
    ok('stopFling() with nothing flinging does nothing', f.h.stopFling() === false);

    });
    part('header', function () {
    // [minor] A pending header tap never fires once a later press pans.
    var h = rig();
    h.down(1, 260, 20, 'header'); h.up(1, 260, 20);
    h.wait(100);
    h.down(2, 265, 22, 'header');
    h.move(2, 200, 22);
    h.wait(500);
    h.up(2, 200, 22);
    h.wait(500);
    eq('a header tap followed by a pan is dropped (no jump mid-pan)', h.log.taps.length + ':' + h.log.zooms.length, '0:0');
    var hc = rig();
    hc.down(1, 260, 20, 'header'); hc.up(1, 260, 20);
    hc.wait(100);
    hc.down(2, 262, 20, 'header');
    hc.cancel(2);
    hc.wait(500);
    eq('a pointercancel drops a pending header tap too', hc.log.taps.length + ':' + hc.log.zooms.length, '0:0');

    });
    part('sweep', function () {
    // [minor] A still, captured finger is not swept; a swept one is released.
    var s = rig({ held: [1] });
    s.down(1, 300, 300, 'bg');
    s.wait(G.STALE_MS + 1);
    s.down(2, 500, 300, 'bg');
    eq('a silent pointer still captured is kept: a pinch', s.h.state() + ':' + s.h.pointers(), 'PINCH:2');
    var s2 = rig({ held: [] });
    s2.down(1, 300, 300, 'bg');
    s2.wait(G.STALE_MS + 1);
    s2.down(2, 500, 300, 'bg');
    ok('a swept pointer has its capture released', s2.released.indexOf(1) >= 0 && s2.h.pointers() === 1);

    });
    part('stop velocity', function () {
    // [minor] The fling stops at FLING_STOP_V, not at the start threshold.
    ok('FLING_STOP_V is well below FLING_MIN_V', SC.FLING_STOP_V > 0 && SC.FLING_STOP_V < SC.FLING_MIN_V / 5);
    ok('a fling step at 0.2 px/ms is not done', SC.fling(0.2, 1).done === false);
    ok('a fling step below FLING_STOP_V is done', SC.fling(0.019, 1).done === true);

    });
    part('cancelDrag', function () {
    // [minor] cancelDrag on every path that ends a gesture without an up.
    var c = rig();
    c.down(1, 300, 300, { kind: 'bar', id: 't1' });
    c.cancel(1);
    c.down(2, 300, 300, 'bg'); c.move(2, 250, 300); c.lost(2);
    c.down(3, 300, 300, { kind: 'bar', id: 't1' }); c.down(4, 400, 300, 'bg');
    c.up(3, 300, 300); c.wait(300); c.up(4, 400, 300);
    c.down(5, 300, 300, 'bg'); c.move(5, 250, 300); c.h.stop();
    eq('cancelDrag runs on cancel, lost capture, second finger and stop', c.log.cancels.join(','), 'PRESS_BAR,PAN,PRESS_BAR,PAN');
    var c2 = rig({ held: [] });
    c2.down(1, 300, 300, { kind: 'name', id: 't1' });
    c2.wait(G.STALE_MS + 1);
    c2.down(2, 400, 300, 'bg');
    eq('... and on a stale sweep of the gesture pointer', c2.log.cancels.join(','), 'PRESS_NAME');
    var c3 = rig();
    c3.down(1, 300, 300, 'bg'); c3.up(1, 300, 300);
    c3.down(2, 600, 300, 'bg'); c3.drag(2, 600, 300, 440, 300, 10, 16); c3.up(2, 440, 300);
    c3.h.stop();
    eq('... never on a normal release or a fling', c3.log.cancels.length, 0);

    });
    part('crossing', function () {
    // [minor] Fingers crossing in a pinch.
    var x = rig();
    x.down(1, 300, 300, 'bg');
    x.down(2, 400, 300, 'bg');
    x.move(2, 360, 300); x.move(2, 310, 300); x.move(2, 290, 300); x.move(2, 240, 300); x.move(2, 200, 300);
    ok('crossing fingers keep a finite, positive scale', isFinite(x.cam.ppd) && x.cam.ppd > 0 && isFinite(x.cam.sx));
    var zc = x.log.zooms.length;
    x.move(2, 150, 300);
    ok('after crossing, spreading scales again against the crossed pair', x.log.zooms.length === zc + 1 && x.log.zooms[zc][0] > 1);

    });
    part('rows', function () {
    // [nit] The empty name column scrolls rows, with no long press and no id.
    var e = rig();
    e.down(1, 50, 700, 'rows');
    eq('rows: a press', e.h.state(), 'PRESS_ROWS');
    e.wait(1000);
    eq('rows: no long press', e.log.longs.length, 0);
    e.move(1, 20, 650);
    eq('rows: pans rows only', e.cam.sx + ',' + e.cam.sy, '0,50');
    e.up(1, 20, 650);

    });
    part('allocation', function () {
    // [minor, nit] Allocation-free move path outside gestures.js too.
    var src = global.GT_SOURCES;
    if (src) {
      var app = src['app.js'], rd = src['render.js'];
      var toX = /function toX\(clientX\) \{([^}]*)\}/.exec(app);
      ok('app.js toX reads the name column without allocating', !!toX && /view\.nameW\(\)/.test(toX[1]) && !/viewSize/.test(toX[1]));
      ok('render.js drawHeader reuses one pill object', !/pill = \{/.test(rd) && /pill = pillBuf/.test(rd));
      ok('render.js builds layer transforms only when the camera moved', /layerMemo\.bx !== cam\.sx/.test(rd) && !/var tb = 'translate3d/.test(rd));
    }
    });
  }

  /* ============================================ M6: the drag branches */
  function dragSpec() {
    // Long press on a bar: ARMED (live), then the axis decides.
    var a = rig({ drag: {} });
    a.down(1, 300, 300, { kind: 'bar', id: 't1' });
    a.wait(400);
    eq('M6: a long press the owner lifts is ARMED', a.h.state(), 'ARMED');
    eq('M6: ARMED holds the camera (live)', a.log.live.join(','), 'true');
    a.move(1, 305, 302);
    eq('M6: ARMED waits for AXIS_LOCK_PX', a.h.state(), 'ARMED');
    a.move(1, 312, 303);
    eq('M6: ARMED + horizontal past 10 px is MOVE', a.h.state(), 'MOVE');
    eq('M6: dragStart gets the press origin', a.log.starts.join(','), 'MOVE:t1@300,300');
    ok('M6: the preview starts at once', a.log.moves.length >= 1 && a.log.moves[0][0] === 'MOVE');
    var n0 = a.log.moves.length;
    a.move(1, 340, 330);
    eq('M6: a MOVE preview per move with the pointer', JSON.stringify(a.log.moves[n0].slice(0, 3)), JSON.stringify(['MOVE', 340, 330]));
    eq('M6: a drag never pans the camera by itself', a.cam.sx + ',' + a.cam.sy, '0,0');
    a.up(1, 340, 330);
    eq('M6: the up drops (commits) once', a.log.drops.join(','), 'MOVE@340,330');
    eq('M6: ... is not a tap', a.log.taps.length, 0);
    eq('M6: ... ends live and settles', a.h.state() + ':' + a.log.live.join(',') + ':' + a.log.settles, 'IDLE:true,false:1');
    eq('M6: ... and never cancels', a.log.cancels.length, 0);

    var b = rig({ drag: {} });
    b.down(1, 300, 300, { kind: 'bar', id: 't2' });
    b.wait(400);
    b.move(1, 303, 320);
    eq('M6: ARMED + vertical is REORDER', b.h.state(), 'REORDER');
    b.up(1, 303, 320);
    eq('M6: REORDER drops', b.log.drops.join(','), 'REORDER@303,320');

    var c = rig({ drag: {} });
    c.down(1, 300, 300, { kind: 'bar', id: 't2' });
    c.wait(400);
    c.up(1, 300, 300);
    eq('M6: an ARMED bar released in place is dropped as ARMED, not a tap', c.log.drops.join(',') + ':' + c.log.taps.length, 'ARMED@300,300:0');

    // A long press the owner does not lift behaves as M5 (read-only chart).
    var d = rig({ drag: { lift: false } });
    d.down(1, 300, 300, { kind: 'bar', id: 't1' });
    d.wait(400);
    eq('M6: an unlifted long press stays a press', d.h.state(), 'PRESS_BAR');
    d.move(1, 330, 300);
    eq('M6: ... and a move then pans', d.h.state() + ':' + d.cam.sx, 'PAN:-30');
    d.up(1, 330, 300);
    eq('M6: ... with no drag at all', d.log.starts.length + d.log.drops.length, 0);

    // A long press on a name lifts its row straight into REORDER.
    var e = rig({ drag: {} });
    e.down(1, 50, 300, { kind: 'name', id: 't3' });
    e.wait(400);
    eq('M6: a long press on a name is REORDER', e.h.state() + ':' + e.log.starts.join(','), 'REORDER:REORDER:t3@50,300');
    e.move(1, 50, 380);
    e.up(1, 50, 380);
    eq('M6: ... and drops', e.log.drops.join(','), 'REORDER@50,380');

    // A selected bar drags without a long press (AXIS_PENDING).
    var f = rig({ drag: {} });
    f.down(1, 300, 300, { kind: 'barSel', id: 't1' });
    f.move(1, 309, 300);
    eq('M6: a moving selected bar is AXIS_PENDING', f.h.state(), 'AXIS_PENDING');
    f.move(1, 316, 300);
    eq('M6: AXIS_PENDING + horizontal is MOVE', f.h.state(), 'MOVE');
    f.up(1, 316, 300);
    var f2 = rig({ drag: {} });
    f2.down(1, 300, 300, { kind: 'barSel', id: 't1' });
    f2.move(1, 300, 309);
    f2.up(1, 300, 309);
    eq('M6: AXIS_PENDING released early is nothing (no tap, no drop)', f2.log.taps.length + f2.log.drops.length + ':' + f2.h.state(), '0:IDLE');
    var f3 = rig({ drag: {} });
    f3.down(1, 300, 300, { kind: 'barSel', id: 't1' });
    f3.up(1, 300, 300);
    eq('M6: a tap on the selected bar is a barSel tap', f3.log.taps.map(function (x) { return x.kind + ':' + x.id; }).join(','), 'barSel:t1');
    // A refused drag pans instead.
    var f4 = rig({ drag: { refuse: ['MOVE'] } });
    f4.down(1, 300, 300, { kind: 'barSel', id: 't1' });
    f4.move(1, 320, 300);
    eq('M6: a refused MOVE pans', f4.h.state() + ':' + f4.cam.sx, 'PAN:-20');
    f4.up(1, 320, 300);

    // Mouse: any bar goes to AXIS_PENDING past 3 px, no long press.
    var m = rig({ drag: {} });
    m.down(1, 300, 300, { kind: 'bar', id: 't1' }, { pointerType: 'mouse' });
    m.move(1, 304, 300, { pointerType: 'mouse' });
    eq('M6: mouse on a bar past 3 px is AXIS_PENDING', m.h.state(), 'AXIS_PENDING');
    m.move(1, 300, 320, { pointerType: 'mouse' });
    eq('M6: ... then REORDER on a vertical move', m.h.state(), 'REORDER');
    m.up(1, 300, 320, { pointerType: 'mouse' });
    // Touch on an unselected bar still pans (a swipe over a bar scrolls).
    var sw = rig({ drag: {} });
    sw.down(1, 300, 300, { kind: 'bar', id: 't1' });
    sw.move(1, 280, 300);
    eq('M6: a touch swipe over an unselected bar still pans', sw.h.state(), 'PAN');
    sw.up(1, 280, 300);

    // Handles: RESIZE_S / RESIZE_E past 4 px; a still press is a no-op.
    var h = rig({ drag: {} });
    h.down(1, 300, 300, { kind: 'handle', id: 't1', edge: 'e' });
    h.move(1, 303, 300);
    eq('M6: a handle waits for HANDLE_SLOP', h.h.state(), 'PRESS_HANDLE');
    h.move(1, 305, 300);
    eq('M6: the end handle is RESIZE_E', h.h.state(), 'RESIZE_E');
    h.up(1, 305, 300);
    eq('M6: ... and drops', h.log.drops.join(','), 'RESIZE_E@305,300');
    var hs = rig({ drag: {} });
    hs.down(1, 300, 300, { kind: 'handle', id: 't1', edge: 's' });
    hs.move(1, 290, 300);
    eq('M6: the start handle is RESIZE_S', hs.h.state(), 'RESIZE_S');
    hs.up(1, 290, 300);
    var hn = rig({ drag: {} });
    hn.down(1, 300, 300, { kind: 'handle', id: 't1', edge: 'e' });
    hn.up(1, 300, 300);
    eq('M6: a handle press that never moved is a no-op, not a tap', hn.log.taps.length + hn.log.drops.length, 0);
    // Review round 1: a vertical move from a handle scrolls rows, not a resize.
    var hv = rig({ drag: {} });
    hv.down(1, 300, 300, { kind: 'handle', id: 't1', edge: 'e' });
    hv.move(1, 301, 320);
    eq('M6 r1: a vertical move from a handle pans (no resize)', hv.h.state() + ':' + hv.log.starts.length, 'PAN:0');
    hv.up(1, 301, 320);
    // Review round 1: the up's coordinates are the committed preview.
    var uc = rig({ drag: {} });
    uc.down(1, 300, 300, { kind: 'barSel', id: 't1' });
    uc.move(1, 320, 300);
    uc.up(1, 337, 300);
    var lastMove = uc.log.moves[uc.log.moves.length - 1];
    eq('M6 r1: the up position is previewed before the drop', lastMove[0] + '@' + lastMove[1], 'MOVE@337');
    var hr = rig({ drag: { refuse: ['RESIZE_E'] } });
    hr.down(1, 300, 300, { kind: 'handle', id: 'ms1', edge: 'e' });
    hr.move(1, 320, 300);
    eq('M6: a refused resize (a milestone) pans', hr.h.state(), 'PAN');
    hr.up(1, 320, 300);

    // Every end without an up reverts: cancel, lost capture, second finger, stop.
    ['cancel', 'lost', 'finger', 'stop'].forEach(function (how) {
      var x = rig({ drag: {} });
      x.down(1, 300, 300, { kind: 'barSel', id: 't1' });
      x.move(1, 330, 300);
      if (how === 'cancel') x.cancel(1);
      else if (how === 'lost') x.lost(1);
      else if (how === 'finger') x.down(2, 400, 300, 'bg');
      else x.h.stop();
      eq('M6: ' + how + ' during MOVE reverts (cancelDrag MOVE, no drop)', x.log.cancels.join(',') + ':' + x.log.drops.length, 'MOVE:0');
      if (how === 'finger') eq('M6: a second finger during MOVE becomes a PINCH', x.h.state(), 'PINCH');
      else eq('M6: ... and ends live (' + how + ')', x.h.state() + ':' + x.log.live[x.log.live.length - 1], 'IDLE:false');
    });
    var ar = rig({ drag: {} });
    ar.down(1, 300, 300, { kind: 'bar', id: 't1' });
    ar.wait(400);
    ar.down(2, 400, 300, 'bg');
    eq('M6: a second finger while ARMED cancels the lift', ar.log.cancels.join(',') + ':' + ar.h.state(), 'ARMED:PINCH');

    // Edge autoscroll: within EDGE_PX of the body edge, speed ~ depth^2.
    var rect = { l: 100, t: 100, r: 500, b: 800 };
    var s1 = rig({ drag: { rect: rect } });
    s1.down(1, 300, 300, { kind: 'barSel', id: 't1' });
    s1.move(1, 320, 300);
    eq('M6: no autoscroll away from the edges', s1.pending(), 0);
    s1.move(1, 500 - 18, 300);                 // half way into the band
    ok('M6: a pointer in the right band starts autoscroll', s1.pending() === 1);
    var sx0 = s1.cam.sx, mv = s1.log.moves.length;
    s1.frames(1000 / 60, 1);
    var v1 = s1.cam.sx - sx0;
    ok('M6: half depth scrolls EDGE_MAX_SPEED/4 per frame (' + v1 + ')', Math.abs(v1 - G.EDGE_MAX_SPEED / 4) < 1e-9);
    ok('M6: the scroll replays the preview (delta includes the scroll)', s1.log.moves.length === mv + 1 && s1.log.moves[mv][3] === s1.cam.sx);
    s1.move(1, 520, 300);                      // past the edge: full speed
    var sx1 = s1.cam.sx;
    s1.frames(1000 / 60, 1);
    ok('M6: past the edge scrolls EDGE_MAX_SPEED (' + (s1.cam.sx - sx1) + ')', Math.abs(s1.cam.sx - sx1 - G.EDGE_MAX_SPEED) < 1e-9);
    s1.move(1, 300, 300);
    s1.frames(1000 / 60, 3);
    eq('M6: leaving the band stops the autoscroll', s1.pending(), 0);
    s1.move(1, 110, 300);
    ok('M6: the left band scrolls back', s1.frames(1000 / 60, 1) === 1 && s1.cam.sx < sx1 + G.EDGE_MAX_SPEED);
    s1.up(1, 110, 300);
    eq('M6: the up stops the autoscroll', s1.pending(), 0);
    ok('M6: autoscroll frames are counted', s1.h.counts().edgeFrames >= 3);
    var s2 = rig({ drag: { rect: rect } });
    s2.down(1, 50, 300, { kind: 'name', id: 't3' });
    s2.wait(400);
    s2.move(1, 50, 790);
    var sy0 = s2.cam.sy;
    s2.frames(1000 / 60, 1);
    ok('M6: REORDER autoscrolls rows at the bottom edge', s2.cam.sy > sy0 && s2.cam.sx === 0);
    s2.cancel(1);
    eq('M6: a cancel stops the autoscroll too', s2.pending(), 0);
    var s3 = rig({ drag: { rect: rect }, bounds: { lo: 0, hi: 0 } });
    s3.down(1, 300, 300, { kind: 'barSel', id: 't1' });
    s3.move(1, 499, 300);
    s3.frames(1000 / 60, 5);
    eq('M6: autoscroll stops when the camera cannot move', s3.pending(), 0);
    s3.up(1, 499, 300);
    // 120 Hz frames scroll the same distance per second as 60 Hz.
    var r60 = rig({ drag: { rect: rect } }), r120 = rig({ drag: { rect: rect } });
    [r60, r120].forEach(function (r) { r.down(1, 300, 300, { kind: 'barSel', id: 't1' }); r.move(1, 490, 300); });
    r60.frames(1000 / 60, 60); r120.frames(1000 / 120, 120);
    ok('M6: autoscroll is frame-rate independent', Math.abs(r60.cam.sx - r120.cam.sx) < 1e-6, r60.cam.sx + ' vs ' + r120.cam.sx);

    var src = global.GT_SOURCES && global.GT_SOURCES['gestures.js'];
    if (src) {
      src = src.replace(/\/\*[\s\S]*?\*\/|\/\/.*$/gm, '');
      ['edgeStep', 'edgeVel', 'axisMove'].forEach(function (fn) {
        var mm = new RegExp('function ' + fn + '\\([^)]*\\) \\{([\\s\\S]*?)\\n    \\}').exec(src);
        ok(fn + ' exists', !!mm);
        if (mm) ok(fn + ' allocates nothing', !/\bnew\b|function\s*\(|\[\]|\{\s*[a-z]+:|\.slice\(|\.map\(|forEach/.test(mm[1]), mm[1]);
      });
    }
  }

  SPEC.suites.push({ name: 'the gesture drag spec (M6)', fn: dragSpec });
  SPEC.suites.push({ name: 'the gesture constants spec', fn: constantsSpec });
  SPEC.suites.push({ name: 'the gesture pan spec', fn: panSpec });
  SPEC.suites.push({ name: 'the gesture tap spec', fn: tapSpec });
  SPEC.suites.push({ name: 'the gesture fling spec', fn: flingSpec });
  SPEC.suites.push({ name: 'the gesture pinch spec', fn: pinchSpec });
  SPEC.suites.push({ name: 'the gesture cancel spec', fn: cancelSpec });
  SPEC.suites.push({ name: 'the gesture wheel spec', fn: wheelSpec });
  SPEC.suites.push({ name: 'the gesture stop spec', fn: stopSpec });
  SPEC.suites.push({ name: 'the gesture review round 1 spec', fn: review1Spec });

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
