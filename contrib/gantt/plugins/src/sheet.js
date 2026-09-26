/*
 * Gantt bottom sheet and side panel (plan §13.4, §14.1, §14.2): one #sheet
 * element with two detents, PEEK (content height up to 240 px, no scrim,
 * the chart stays interactive) and FULL (86% of the height, scrim). On a
 * landscape phone (wider than tall and at least 640 px) or a tablet it is a
 * right side panel instead, with no scrim at PEEK.
 *
 * Content kinds: the task sheet (dates, milestone, colour, completion with
 * its item list, Open note, the two-step Remove), menus and forms (rename,
 * confirmations, the conflict sheet, the create sheets of M7). The
 * sheet knows no model and no store: it reads a view model through
 * ctx.task(id) and reports edits through ctx.act(name, id, value).
 *
 * Keyboard avoidance for text inputs (§13.4): --kb follows visualViewport,
 * the sheet sits above it, and the focused field is scrolled into view with
 * scrollTop math. Note-derived text goes in through textContent only.
 */
(function (global) {
  'use strict';
  var GT = (global.GT = global.GT || {});
  var SH = (GT.sheet = {});

  SH.PEEK_MAX = 240;             // px (§13.4)
  SH.FULL = 0.86;                // of the viewport height
  SH.SIDE_MIN_W = 640;           // landscape side panel from this width
  SH.TABLET_W = 768;
  SH.SWIPE_PX = 40;              // a grab drag this far switches detent
  SH.ARM_MS = 3000;              // "Tap again to remove" stays armed this long (§13.4)

  /* ------------------------------------------------------ pure helpers */

  // A side panel instead of a bottom sheet (§13.4, §14.1).
  SH.sideOf = function (w, h) { return (w > h && w >= SH.SIDE_MIN_W) || w >= SH.TABLET_W; };
  // The keyboard's height: innerHeight minus the visual viewport's bottom.
  SH.kbOf = function (innerH, vv) {
    if (!vv || typeof vv.height !== 'number') return 0;
    return Math.max(0, Math.round(innerH - (vv.height + (vv.offsetTop || 0))));
  };
  // A grab-handle drag of dy px released at detent `cur`: up goes FULL,
  // down goes FULL to PEEK and PEEK to closed (null); a short drag stays.
  SH.nextDetent = function (cur, dy) {
    if (dy <= -SH.SWIPE_PX) return 'full';
    if (dy >= SH.SWIPE_PX) return cur === 'full' ? 'peek' : null;
    return cur;
  };
  // A scrim tap: FULL to PEEK (the scrim only shows at FULL), else closed.
  SH.scrimTap = function (cur) { return cur === 'full' ? 'peek' : null; };
  // The scrollTop that shows a field `top` px down a scroller of height h.
  /*
   * datesFor('start' | 'end', vm, day) -> {start, end} for a date input, or
   * null to ignore it (an empty value). A start past the end moves the end
   * with it (the duration is kept); an end before the start is clamped to
   * the start (a one-day task). Never a swap, so a typed Start stays Start.
   */
  SH.datesFor = function (which, vm, day) {
    if (typeof day !== 'number' || !isFinite(day)) return null;
    if (which === 'start') {
      if (vm.milestone) return { start: day, end: null };
      if (vm.start === null) return { start: day, end: null };
      var end = vm.end === null ? vm.start : vm.end;
      return { start: day, end: day > end ? day + (end - vm.start) : end };
    }
    var s = vm.start === null ? day : vm.start;
    return { start: s, end: Math.max(s, day) };
  };
  // Whether the sheet is a side panel after a resize to w x h: a
  // height-only change (the keyboard) never flips it.
  SH.sideAfter = function (side, prevW, w, h) { return w === prevW ? side : SH.sideOf(w, h); };
  SH.scrollFor = function (top, fieldH, scrollTop, h) {
    if (top < scrollTop + 8) return Math.max(0, top - 8);
    if (top + fieldH > scrollTop + h - 8) return Math.max(0, top + fieldH - h + 8);
    return scrollTop;
  };

  /* ------------------------------------------------------------ state */

  var st = {
    doc: null, win: null, el: null, scrim: null, ctx: null,
    kind: null, det: null, id: null, spec: null, side: false, w: 0, ro: false, back: null,
    head: null, title: null, dot: null, body: null, grab: null, parts: null
  };
  function T(s) { return st.ctx && st.ctx.text ? st.ctx.text(s) : s; }
  function el(tag, cls, text, parent) {
    var e = st.doc.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = text;
    if (parent) parent.appendChild(e);
    return e;
  }
  // Focus one row of a menu or list; list rows keep one tab stop (roving).
  function roveTo(rows, row) {
    if (row.classList.contains('sh-trow')) rows.forEach(function (x) { x.setAttribute('tabindex', x === row ? '0' : '-1'); });
    try { row.focus({ preventScroll: false }); } catch (e) { row.focus(); }
  }
  function button(cls, text, parent, run) {
    var b = el('button', cls, text, parent);
    b.type = 'button';
    if (run) b.addEventListener('click', run);
    return b;
  }

  /*
   * init(o): o {doc, win, el (#sheet), scrim (#scrim), ctx}. ctx:
   *   text(s), fmt(key, vars)       i18n
   *   day(v) -> YYYY-MM-DD or ''; parse(s) -> day or null   date inputs
   *   task(id) -> view model or null (see openTask)
   *   act(name, id, value)          'dates' {start, end}, 'milestone' bool,
   *                                 'color' name or null, 'open', 'remove',
   *                                 'item' key (a completion-list tap),
   *                                 'openItem' key (a child task's chevron)
   *   onClose(kind, id)             after the sheet closed
   *   colors                        the palette names (model.COLORS)
   */
  SH.init = function (o) {
    st.doc = o.doc || global.document;
    st.win = o.win || global;
    st.el = o.el;
    st.scrim = o.scrim;
    st.ctx = o.ctx || {};
    var e = st.el;
    while (e.firstChild) e.removeChild(e.firstChild);
    e.setAttribute('role', 'dialog');
    st.grab = el('div', 'sheet-grab', null, e);
    el('span', null, null, st.grab);
    st.head = el('div', 'sheet-head', null, e);
    st.dot = el('span', 'sh-dot', null, st.head);
    st.title = el('div', 'sh-title', null, st.head);
    st.title.setAttribute('tabindex', '-1');
    st.title.setAttribute('role', 'heading');
    st.title.setAttribute('aria-level', '2');
    // The dialog is named by its title (§15.2).
    st.title.id = 'sheet-title';
    e.setAttribute('aria-labelledby', 'sheet-title');
    var close = button('sh-close', null, st.head, function () { SH.close(); });
    close.setAttribute('aria-label', T('Close'));
    close.setAttribute('data-i18n-label', 'Close');
    close.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg>';
    st.body = el('div', 'sheet-body', null, e);
    wireGrab();
    if (st.scrim) st.scrim.addEventListener('click', function () { setDetent(SH.scrimTap(st.det)); });
    wireKeyboard();
    st.win.addEventListener('resize', function () {
      if (!st.kind) return;
      st.side = SH.sideAfter(st.side, st.w, st.win.innerWidth, st.win.innerHeight);
      st.w = st.win.innerWidth;
      paint();
    });
    // M9: arrow keys move between the rows of a menu or a list (roving).
    e.addEventListener('keydown', function (ev) {
      var k = ev.key, t = ev.target;
      if ((k !== 'ArrowDown' && k !== 'ArrowUp' && k !== 'Home' && k !== 'End') || !t || !t.classList) return;
      var cls = t.classList.contains('sh-item') ? 'sh-item' : (t.classList.contains('sh-trow') ? 'sh-trow' : null);
      if (!cls) return;
      var rows = Array.prototype.filter.call(st.body.querySelectorAll('.' + cls), function (x) { return !x.disabled; });
      var i = rows.indexOf(t);
      var n = k === 'Home' ? 0 : k === 'End' ? rows.length - 1 : Math.max(0, Math.min(rows.length - 1, i + (k === 'ArrowDown' ? 1 : -1)));
      ev.preventDefault();
      if (n < 0 || !rows[n]) return;
      roveTo(rows, rows[n]);
    });
    // FULL is modal: Tab and Shift+Tab stay inside the sheet.
    e.addEventListener('keydown', function (ev) {
      if (ev.key !== 'Tab' || st.det !== 'full' || st.side) return;
      var f = focusables();
      if (!f.length) return;
      var a = st.doc.activeElement, i = f.indexOf(a);
      var next = ev.shiftKey ? (i <= 0 ? f[f.length - 1] : null) : (i < 0 || i === f.length - 1 ? f[0] : null);
      if (next) { ev.preventDefault(); next.focus(); }
    });
    e.hidden = true;
    if (st.scrim) st.scrim.hidden = true;
  };

  /* ---------------------------------------------------------- detents */

  // Side panel or bottom sheet is decided on open and on a width change.
  function place() {
    st.w = st.win.innerWidth;
    st.side = SH.sideOf(st.w, st.win.innerHeight);
    paint();
  }
  function paint() {
    var e = st.el, body = st.doc.body;
    e.className = 'sheet ' + (st.side ? 'side ' : '') + (st.det || 'peek') + ' k-' + st.kind + (st.ro ? ' ro' : '');
    e.setAttribute('aria-modal', st.det === 'full' ? 'true' : 'false');
    if (st.scrim) st.scrim.hidden = st.det !== 'full';
    body.classList.toggle('sheet-open', !!st.kind);
    body.classList.toggle('sheet-side', !!st.kind && st.side);
  }
  function setDetent(d) {
    if (!st.kind) return;
    if (d === null) { SH.close(); return; }
    st.det = d;
    paint();
  }
  function focusables() {
    return Array.prototype.filter.call(st.el.querySelectorAll('button, input, select, textarea, [tabindex]:not([tabindex="-1"])'), function (x) {
      return !x.disabled && !x.hidden && x.offsetParent !== null;
    });
  }
  SH.setDetent = setDetent;

  function wireGrab() {
    var id = null, y0 = 0, dy = 0;
    st.grab.addEventListener('pointerdown', function (ev) {
      if (st.side) return;
      id = ev.pointerId; y0 = ev.clientY; dy = 0;
      try { st.grab.setPointerCapture(id); } catch (e) { /* synthetic */ }
    });
    st.grab.addEventListener('pointermove', function (ev) {
      if (ev.pointerId !== id) return;
      dy = ev.clientY - y0;
      // Follow the finger down; up is shown by the detent change on release.
      st.el.style.transform = dy > 0 ? 'translate3d(0,' + dy + 'px,0)' : '';
    });
    function end(ev, cancelled) {
      if (ev.pointerId !== id) return;
      id = null;
      st.el.style.transform = '';
      if (cancelled) return;
      // A tap on the grab toggles PEEK and FULL.
      if (Math.abs(dy) < 6) { setDetent(st.det === 'full' ? 'peek' : 'full'); return; }
      setDetent(SH.nextDetent(st.det, dy));
    }
    st.grab.addEventListener('pointerup', function (ev) { end(ev, false); });
    st.grab.addEventListener('pointercancel', function (ev) { end(ev, true); });
  }

  /* --------------------------------------------------- keyboard (§13.4) */

  function wireKeyboard() {
    var win = st.win, vv = win.visualViewport, root = st.doc.documentElement;
    function kb() {
      var k = SH.kbOf(win.innerHeight, vv);
      root.style.setProperty('--kb', k + 'px');
      reveal();
    }
    if (vv && vv.addEventListener) {
      vv.addEventListener('resize', kb);
      vv.addEventListener('scroll', kb);
    }
    // The WebView may scroll the page to show a focused field; the layout
    // is fixed, so undo it (Cartograph app.js:3555-3561).
    win.addEventListener('scroll', function () { if (win.scrollY || win.scrollX) win.scrollTo(0, 0); });
    st.el.addEventListener('focusin', function (ev) {
      var t = ev.target;
      if (isTextField(t)) { if (!st.side && st.det !== 'full') setDetent('full'); reveal(); }
    });
    SH.kbNow = kb;
  }
  function isTextField(t) { return !!t && ((t.tagName === 'INPUT' && t.type === 'text') || t.tagName === 'TEXTAREA'); }
  // Scroll the focused text field into the sheet's view (no scrollIntoView).
  function reveal() {
    var a = st.doc.activeElement;
    if (!a || !st.body.contains(a) || !isTextField(a)) return;
    var top = 0, n = a;
    while (n && n !== st.body) { top += n.offsetTop; n = n.offsetParent; }
    st.body.scrollTop = SH.scrollFor(top, a.offsetHeight, st.body.scrollTop, st.body.clientHeight);
  }

  /* ------------------------------------------------------------- open */

  function open(kind, id, spec, det, title, hue) {
    disarm();
    // Another sheet replacing a live form applies its typed text first.
    if (st.kind && st.parts && typeof st.parts.flush === 'function') { var fl = st.parts.flush; st.parts.flush = null; fl(); }
    // Focus goes back where it was when the sheet closes (§15.2).
    var a = st.doc.activeElement;
    if (!st.kind) st.back = a && a !== st.doc.body && !st.el.contains(a) ? a : null;
    st.ro = false;
    st.kind = kind; st.id = id; st.spec = spec;
    st.det = det || 'peek';
    while (st.body.firstChild) st.body.removeChild(st.body.firstChild);
    st.title.textContent = title || '';
    st.dot.className = 'sh-dot' + (hue ? ' c-' + hue : '');
    st.dot.hidden = !hue;
    st.el.hidden = false;
    place();
    st.body.scrollTop = 0;
  }
  function focusTitle() { try { st.title.focus({ preventScroll: true }); } catch (e) { /* old engines */ } }

  /*
   * openTask(id, detent) shows the task sheet. ctx.task(id) returns
   * {id, title, hue, start, end, milestone, color, note, readOnly,
   *  progress: {done, total, ratio, text},
   *  items: {state: 'loading'|'ok'|'failed'|'none', list: [{key, kind:
   *          'check'|'sub'|'child', text, done, busy}]}} with day numbers (or null).
   */
  SH.openTask = function (id, detent) {
    var vm = st.ctx.task ? st.ctx.task(id) : null;
    if (!vm) return false;
    open('task', id, null, detent, vm.title, vm.hue);
    buildTask();
    fillTask(vm);
    focusTitle();
    return true;
  };

  function buildTask() {
    var b = st.body, P = (st.parts = {});
    var dates = el('div', 'sh-dates', null, b);
    function field(cls, label) {
      var f = el('label', 'sh-field ' + cls, null, dates);
      var lab = el('span', 'sh-flab', T(label), f);
      var i = el('input', null, null, f);
      i.type = 'date';
      return { f: f, lab: lab, i: i };
    }
    P.start = field('sh-start', 'Start');
    P.end = field('sh-end', 'End');
    P.dur = el('div', 'sh-dur', '', b);
    function dateChange(which, input) {
      var vm = st.ctx.task(st.id);
      if (!vm) return;
      var d = SH.datesFor(which, vm, st.ctx.parse(input.value));
      // A cleared field (the native picker's Clear) changes nothing: it shows the dates again.
      if (!d) { fillTask(vm); return; }
      st.ctx.act('dates', st.id, d);
    }
    P.start.i.addEventListener('change', function () { dateChange('start', P.start.i); });
    P.end.i.addEventListener('change', function () { dateChange('end', P.end.i); });
    var ms = el('label', 'sh-row sh-switch', null, b);
    el('span', null, T('Milestone'), ms);
    P.ms = el('input', null, null, ms);
    P.ms.type = 'checkbox';
    P.ms.setAttribute('role', 'switch');
    P.ms.addEventListener('change', function () { st.ctx.act('milestone', st.id, P.ms.checked); });
    el('div', 'sh-lab', T('Colour'), b);
    var sw = el('div', 'sh-swatches', null, b);
    sw.setAttribute('role', 'radiogroup');
    sw.setAttribute('aria-label', T('Colour'));
    P.sw = [];
    // The palette names come from the owner (model.COLORS): one list.
    [''].concat(st.ctx.colors || []).forEach(function (c) {
      var btn = button('sw' + (c ? ' c-' + c : ' auto'), c ? null : T('Auto'), sw, function () { st.ctx.act('color', st.id, c || null); });
      btn.setAttribute('data-color', c);
      btn.setAttribute('role', 'radio');
      if (c) btn.setAttribute('aria-label', T(COLOR_NAMES[c]));
      if (c) el('span', null, null, btn);
      P.sw.push(btn);
    });
    el('div', 'sh-lab', T('Completion'), b);
    var pr = el('div', 'sh-prog', null, b);
    P.track = el('div', 'sh-track', null, pr);
    P.fill = el('div', 'sh-fill', null, P.track);
    P.ptext = el('div', 'sh-ptext', '', pr);
    // The completion list (§13.4): checkbox items, subnotes and child tasks.
    P.list = el('div', 'sh-items', null, b);
    P.list.setAttribute('role', 'list');
    P.itemsSig = null;
    var acts = el('div', 'sh-actions', null, b);
    P.open = button('sh-btn primary', T('Open note'), acts, function () { st.ctx.act('open', st.id); });
    // Two-step remove (confirm() is unusable in the WebView): the first tap
    // arms it for ARM_MS, the second removes.
    P.remove = button('sh-btn danger', T('Remove from chart'), acts, function () {
      if (P.armed) { disarm(); st.ctx.act('remove', st.id); return; }
      arm(P);
    });
    P.remove.setAttribute('data-action', 'remove');
  }
  function arm(P) {
    P.armed = true;
    P.remove.textContent = T('Tap again to remove');
    P.remove.classList.add('armed');
    // The timer disarms only the sheet that armed it.
    P.armTimer = st.win.setTimeout(function () { P.armTimer = null; disarm(P); }, SH.ARM_MS);
  }
  // Back to "Remove from chart" (timeout, close, another sheet).
  function disarm(P) {
    P = P || st.parts;
    if (!P || !P.remove) return;
    if (P.armTimer) { st.win.clearTimeout(P.armTimer); P.armTimer = null; }
    P.armed = false;
    P.remove.textContent = T('Remove from chart');
    P.remove.classList.remove('armed');
  }
  SH.disarm = function () { disarm(); };
  // Keyboard Delete (§13.2): the first press arms Remove, like a first tap.
  SH.armRemove = function () {
    var P = st.parts;
    if (st.kind !== 'task' || !P || !P.remove || P.remove.hidden) return false;
    if (!P.armed) arm(P);
    return true;
  };
  SH.removeArmed = function () { return st.kind === 'task' && !!st.parts && !!st.parts.armed; };

  // The list is rebuilt only when what it shows changed.
  function fillItems(its, ro) {
    var P = st.parts;
    its = its || { state: 'none', list: [] };
    var list = its.list || [];
    var sig = JSON.stringify([ro, its.state, list.map(function (x) { return [x.key, x.kind, x.text, !!x.done, !!x.busy]; })]);
    if (sig === P.itemsSig) return;
    P.itemsSig = sig;
    var box = P.list;
    while (box.firstChild) box.removeChild(box.firstChild);
    box.setAttribute('data-state', its.state);
    var NOTE = { loading: 'Loading…', failed: 'Couldn’t load the items.', 'too-large': 'This note is too large to list here. Open the note to tick its items.' };
    if (NOTE[its.state]) {
      el('div', 'sh-inote', T(NOTE[its.state]), box);
      return;
    }
    list.forEach(function (x) {
      var row = el('div', 'sh-it k-' + x.kind + (x.done ? ' done' : ''), null, box);
      row.setAttribute('role', 'listitem');
      row.setAttribute('data-key', x.key);
      var lab = el('label', 'sh-itl', null, row);
      var cb = el('input', null, null, lab);
      cb.type = 'checkbox';
      cb.checked = !!x.done;
      cb.disabled = ro || !!x.busy;
      // The owner redraws the list with the new state (optimistic).
      cb.addEventListener('change', function () { cb.checked = !!x.done; st.ctx.act('item', st.id, x.key); });
      el('span', 'sh-itx', x.text || T('Untitled'), lab);
      if (x.kind === 'child') {
        var ob = button('sh-itopen', '›', row, function () { st.ctx.act('openItem', st.id, x.key); });
        ob.setAttribute('aria-label', T('Open note'));
      }
    });
  }
  var COLOR_NAMES = {
    indigo: 'Indigo', blue: 'Blue', sky: 'Sky', teal: 'Teal', emerald: 'Emerald', amber: 'Amber',
    orange: 'Orange', rose: 'Rose', pink: 'Pink', violet: 'Violet', slate: 'Slate'
  };
  SH.COLOR_NAMES = COLOR_NAMES;

  function setVal(input, v) { if (st.doc.activeElement !== input && input.value !== v) input.value = v; }
  function fillTask(vm) {
    var P = st.parts, ro = !!vm.readOnly, d = st.ctx.day || function () { return ''; };
    st.title.textContent = vm.title;
    st.dot.className = 'sh-dot c-' + vm.hue;
    st.dot.hidden = false;
    P.start.lab.textContent = T(vm.milestone ? 'Date' : 'Start');
    setVal(P.start.i, vm.start === null ? '' : d(vm.start));
    setVal(P.end.i, vm.start === null ? '' : d(vm.end === null ? vm.start : vm.end));
    P.end.f.hidden = !!vm.milestone;
    P.start.i.disabled = ro;
    P.end.i.disabled = ro || vm.start === null;
    P.dur.textContent = vm.start === null ? T('Unscheduled') : (vm.milestone ? T('Milestone') :
      st.ctx.fmt('Duration: {n} day(s)', { n: (vm.end === null ? vm.start : vm.end) - vm.start + 1 }));
    P.ms.checked = !!vm.milestone;
    // A task with no note must stay a milestone (model.setTask).
    P.ms.disabled = ro || (!vm.note && vm.milestone);
    P.sw.forEach(function (b) {
      var c = b.getAttribute('data-color');
      b.setAttribute('aria-checked', (vm.color || '') === c ? 'true' : 'false');
      b.disabled = ro;
    });
    var pg = vm.progress || {};
    P.track.className = 'sh-track c-' + vm.hue;
    P.fill.style.transform = 'scaleX(' + (typeof pg.ratio === 'number' ? Math.max(0, Math.min(1, pg.ratio)) : 0) + ')';
    P.ptext.textContent = pg.text || '';
    fillItems(vm.items, ro);
    P.open.hidden = !vm.note;
    P.remove.hidden = ro;
    if (ro) disarm();
    st.ro = ro;
    st.el.classList.toggle('ro', ro);
  }

  /*
   * openMenu({title, items: [{label, run, danger, disabled, hint, keep}]}, detent)
   * A tap runs the item and closes the sheet (unless keep).
   */
  SH.openMenu = function (spec, detent) {
    open('menu', null, spec, detent, spec.title || '', null);
    var list = el('div', 'sh-menu', null, st.body);
    (spec.items || []).forEach(function (it) {
      var b = button('sh-item' + (it.danger ? ' danger' : ''), null, list, function () {
        if (b.disabled) return;
        if (!it.keep) SH.close();
        if (it.run) it.run();
      });
      el('span', 'sh-il', it.label, b);
      if (it.hint) el('span', 'sh-ih', it.hint, b);
      b.disabled = !!it.disabled;
      if (it.id) b.setAttribute('data-item', it.id);
    });
    focusTitle();
    return true;
  };

  /*
   * M9 Task list view (§13.5, §15.2): openList(spec, detent), spec {title,
   * kind, empty, sections: [{title, rows: [{id, title, hue, meta, status,
   * ratio, ptext, aria}]}], focusId, pick(id)}. Each row is one button in a
   * roving tabindex (arrows, Home and End move, Enter or a tap picks); the
   * dot and the progress bar are the task sheet's own parts (sh-dot,
   * sh-prog). Text goes in through textContent.
   */
  SH.openList = function (spec, detent) {
    open('list', null, spec, detent, spec.title || '', null);
    var rows = [], focusRow = null;
    (spec.sections || []).forEach(function (sec) {
      if (!sec.rows || !sec.rows.length) return;
      if (sec.title) {
        var h = el('div', 'sh-lab sh-lhead', sec.title, st.body);
        h.setAttribute('role', 'heading');
        h.setAttribute('aria-level', '3');
      }
      var box = el('div', 'sh-tlist', null, st.body);
      box.setAttribute('role', 'list');
      sec.rows.forEach(function (r) {
        var li = el('div', 'sh-tli', null, box);
        li.setAttribute('role', 'listitem');
        var b = button('sh-trow', null, li, function () { if (spec.pick) spec.pick(r.id); });
        b.setAttribute('data-id', r.id);
        b.setAttribute('tabindex', '-1');
        if (r.aria) b.setAttribute('aria-label', r.aria);
        var top = el('span', 'sh-tr1', null, b);
        el('span', 'sh-dot c-' + (r.hue || 'slate'), null, top).setAttribute('aria-hidden', 'true');
        el('span', 'sh-tt', r.title, top);
        if (r.status) el('span', 'sh-tst', r.status, top);
        if (r.meta) el('span', 'sh-tm', r.meta, b);
        var pr = el('span', 'sh-prog', null, b);
        var tr = el('span', 'sh-track c-' + (r.hue || 'slate'), null, pr);
        el('span', 'sh-fill', null, tr).style.transform = 'scaleX(' + Math.max(0, Math.min(1, r.ratio || 0)) + ')';
        el('span', 'sh-ptext', r.ptext || '', pr);
        rows.push(b);
        if (r.id === spec.focusId) focusRow = b;
      });
    });
    if (!rows.length) el('div', 'sh-inote', spec.empty || '', st.body);
    else (focusRow || rows[0]).setAttribute('tabindex', '0');
    if (focusRow) roveTo(rows, focusRow); else focusTitle();
    return true;
  };

  /*
   * M9 live locale switch (§15.1): relabel(reopen) redraws the open sheet in
   * the new language and keeps its detent, scroll position, focused control
   * and what was typed or chosen. The task sheet is rebuilt here; a menu,
   * form or list is rebuilt by reopen(detent), its owner's own opener.
   */
  SH.relabel = function (reopen) {
    if (!st.kind) return false;
    var det = st.det, top = st.body.scrollTop, f = focusables(), a = st.doc.activeElement;
    var fi = f.indexOf(a), onTitle = a === st.title;
    var rowId = a && a.classList && a.classList.contains('sh-trow') ? a.getAttribute('data-id') : null;
    if (st.kind === 'task') {
      var armed = !!(st.parts && st.parts.armed);
      disarm();
      while (st.body.firstChild) st.body.removeChild(st.body.firstChild);
      buildTask();
      var vm = st.ctx.task ? st.ctx.task(st.id) : null;
      if (!vm) { SH.close(); return false; }
      fillTask(vm);
      if (armed) arm(st.parts);
    } else {
      if (typeof reopen !== 'function') return false;
      var vals = st.parts && typeof st.parts.values === 'function' ? st.parts.values() : null;
      // Typed text is carried over, not applied: the relabel is not a close.
      if (st.parts) st.parts.flush = null;
      reopen(det);
      if (!st.kind) return false;
      if (vals && st.parts && typeof st.parts.set === 'function') Object.keys(vals).forEach(function (k) { st.parts.set(k, vals[k]); });
      if (st.det !== det) setDetent(det);
    }
    st.body.scrollTop = top;
    var g = focusables(), target = null;
    if (rowId) {
      var all = Array.prototype.slice.call(st.body.querySelectorAll('.sh-trow'));
      target = all.filter(function (x) { return x.getAttribute('data-id') === rowId; })[0] || null;
      if (target) { roveTo(all, target); return true; }
    } else if (onTitle) target = st.title;
    else if (fi >= 0) target = g[Math.min(fi, g.length - 1)] || null;
    if (target) { try { target.focus({ preventScroll: true }); } catch (e) { target.focus(); } }
    return true;
  };

  /*
   * openForm(spec, detent): spec {title, text, fields, actions, kind}.
   *   fields: {name, label, type: 'text' | 'code' | 'choice' | 'note' |
   *            'date' | 'textarea' | 'switch', value, options: [{value,
   *            label}], detail, placeholder, showIf: {name, value}}
   *   A date field's value is a day number (ctx.day / ctx.parse), a switch's
   *   a boolean. showIf shows the field only while that choice holds value.
   *   actions: {label, primary, danger, id, run(values) -> true keeps the
   *            sheet open}; with no run the action just closes.
   * spec.kind names the form for isOpen callers (for example 'conflict').
   * M8 (the settings and display sheets, §13.5):
   *   spec.onChange(name, value, values) applies a control at once: a
   *     choice or switch on tap, a text field on change (blur or Enter), a
   *     day or date list on every edit.
   *   spec.readOnly (or field.disabled) disables the controls.
   *   type 'days': seven toggles, value an array of weekday numbers (0 is
   *     Sunday), options [{value, label}] in display order.
   *   type 'dates': a list of date inputs with Remove, plus Add; value an
   *     array of day numbers.
   *   choice options may carry preview: 'fill' | 'segments' | 'dots'.
   */
  SH.openForm = function (spec, detent) {
    open('form', null, spec, detent, spec.title || '', null);
    var b = st.body, vals = {}, inputs = {};
    st.parts = { vals: vals, inputs: inputs };
    if (spec.text) el('p', 'sh-text', spec.text, b);
    var conds = [];
    function syncShow() { conds.forEach(function (c) { c.wrap.hidden = vals[c.name] !== c.value; }); }
    function changed(name) { if (spec.onChange && st.spec === spec) spec.onChange(name, values()[name], values()); }
    var applied = {};
    (spec.fields || []).forEach(function (f) {
      var wrap = el('div', 'sh-ff sh-ff-' + (f.type || 'text'), null, b);
      var off = !!(spec.readOnly || f.disabled);
      if (f.name) wrap.setAttribute('data-field', f.name);
      if (f.showIf) conds.push({ wrap: wrap, name: f.showIf.name, value: f.showIf.value });
      if (f.type === 'switch') {
        var sw = el('label', 'sh-row sh-switch', null, wrap);
        el('span', null, f.label || '', sw);
        var cb = el('input', null, null, sw);
        cb.type = 'checkbox';
        cb.setAttribute('role', 'switch');
        cb.checked = f.value !== false;
        cb.disabled = off;
        cb.addEventListener('change', function () { changed(f.name); });
        inputs[f.name] = cb;
        return;
      }
      if (f.label) el('div', 'sh-flab', f.label, wrap);
      if (f.type === 'code') { el('pre', 'sh-code', f.value || '', wrap); return; }
      if (f.type === 'note') { el('div', 'sh-note', f.value || '', wrap); return; }
      if (f.detail) el('div', 'sh-detail', f.detail, wrap);
      if (f.type === 'choice') {
        var seg = el('div', 'seg sh-seg', null, wrap);
        seg.setAttribute('role', 'group');
        if (f.label) seg.setAttribute('aria-label', f.label);
        vals[f.name] = f.value;
        var btns = (f.options || []).map(function (op) {
          var ob = button(null, op.preview ? null : op.label, seg, function () {
            if (ob.disabled) return;
            var was = vals[f.name];
            vals[f.name] = op.value;
            btns.forEach(function (x) { x.setAttribute('aria-pressed', x === ob ? 'true' : 'false'); });
            syncShow();
            if (was !== op.value) changed(f.name);
          });
          // A preview of a completion style above its name (constant markup).
          if (op.preview) { el('span', 'pv pv-' + op.preview, null, ob).setAttribute('aria-hidden', 'true'); el('span', null, op.label, ob); }
          ob.setAttribute('data-value', op.value);
          ob.setAttribute('aria-pressed', op.value === f.value ? 'true' : 'false');
          ob.disabled = off;
          return ob;
        });
        inputs[f.name] = btns;
        return;
      }
      if (f.type === 'days') {
        var row = el('div', 'sh-days', null, wrap);
        row.setAttribute('role', 'group');
        if (f.label) row.setAttribute('aria-label', f.label);
        var on = (f.value || []).slice();
        vals[f.name] = on.slice().sort();
        (f.options || []).forEach(function (op) {
          var db = button(null, op.label, row, function () {
            if (db.disabled) return;
            var i = on.indexOf(op.value);
            if (i >= 0) on.splice(i, 1); else on.push(op.value);
            vals[f.name] = on.slice().sort();
            db.setAttribute('aria-pressed', i >= 0 ? 'false' : 'true');
            changed(f.name);
          });
          db.setAttribute('data-value', String(op.value));
          db.setAttribute('aria-pressed', on.indexOf(op.value) >= 0 ? 'true' : 'false');
          if (op.title) db.setAttribute('aria-label', op.title);
          db.disabled = off;
        });
        return;
      }
      if (f.type === 'dates') {
        var list = el('div', 'sh-dlist', null, wrap);
        var days = (f.value || []).slice();
        vals[f.name] = days.slice();
        var sync = function () { vals[f.name] = days.filter(function (x) { return typeof x === 'number'; }); };
        var addRow = function (day, focus) {
          var r = el('div', 'sh-drow', null, list);
          var di = el('input', 'sh-input', null, r);
          di.type = 'date';
          di.value = typeof day === 'number' && st.ctx.day ? st.ctx.day(day) : '';
          if (f.label) di.setAttribute('aria-label', f.label);
          di.disabled = off;
          var idx = days.length;
          days.push(typeof day === 'number' ? day : null);
          di.addEventListener('change', function () {
            var v = st.ctx.parse ? st.ctx.parse(di.value) : null;
            if (typeof v !== 'number') return;
            days[idx] = v;
            sync();
            changed(f.name);
          });
          var rm = button(null, '×', r, function () {
            if (rm.disabled) return;
            days[idx] = undefined;
            list.removeChild(r);
            sync();
            changed(f.name);
          });
          rm.setAttribute('aria-label', T('Remove'));
          rm.disabled = off;
          if (focus) { try { di.focus(); } catch (e) { /* no focus */ } }
        };
        days = [];
        (f.value || []).forEach(function (d) { addRow(d, false); });
        var add = button('sh-dadd', f.addLabel || T('Add'), wrap, function () { if (!add.disabled) addRow(null, true); });
        add.setAttribute('data-action', 'add-' + f.name);
        add.disabled = off;
        return;
      }
      if (f.type === 'textarea') {
        var ta = el('textarea', 'sh-input sh-ta', null, wrap);
        ta.rows = 4;
        ta.value = f.value || '';
        if (f.placeholder) ta.placeholder = f.placeholder;
        if (f.label) ta.setAttribute('aria-label', f.label);
        inputs[f.name] = ta;
        return;
      }
      var i = el('input', 'sh-input', null, wrap);
      if (f.type === 'date') {
        i.type = 'date';
        i.value = typeof f.value === 'number' && st.ctx.day ? st.ctx.day(f.value) : '';
        if (f.label) i.setAttribute('aria-label', f.label);
        inputs[f.name] = i;
        return;
      }
      i.type = 'text';
      i.value = f.value || '';
      i.disabled = off;
      applied[f.name] = i.value;
      i.addEventListener('change', function () { if (applied[f.name] !== i.value) { applied[f.name] = i.value; changed(f.name); } });
      i.setAttribute('autocomplete', 'off');
      if (f.placeholder) i.placeholder = f.placeholder;
      if (f.label) i.setAttribute('aria-label', f.label);
      inputs[f.name] = i;
      i.addEventListener('keydown', function (ev) {
        if (ev.key !== 'Enter') return;
        // A live sheet applies the typed text first (M8 review: Enter dropped it).
        flushText();
        var first = (spec.actions || []).filter(function (a) { return a.primary; })[0];
        if (first) { ev.preventDefault(); runAction(first); }
      });
    });
    // Text typed into a live sheet (onChange) and not yet applied: applied
    // on Enter and on every close (X, scrim, swipe, Done), M8 review.
    function flushText() {
      if (!spec.onChange) return;
      Object.keys(applied).forEach(function (k) {
        var x = inputs[k];
        if (x && applied[k] !== x.value) { applied[k] = x.value; changed(k); }
      });
    }
    st.parts.flush = flushText;
    // M9: a relabel puts back what was typed or chosen (sheet.relabel).
    st.parts.values = function () { return values(); };
    st.parts.set = function (name, v) {
      var x = inputs[name];
      if (!x) return;
      if (Array.isArray(x)) {
        if (!x.some(function (b) { return b.getAttribute('data-value') === String(v); })) return;
        vals[name] = v;
        x.forEach(function (b) { b.setAttribute('aria-pressed', b.getAttribute('data-value') === String(v) ? 'true' : 'false'); });
        syncShow();
      } else if (x.type === 'checkbox') x.checked = !!v;
      else if (x.type === 'date') x.value = typeof v === 'number' && st.ctx.day ? st.ctx.day(v) : '';
      else x.value = v == null ? '' : String(v);
    };
    syncShow();
    function values() {
      var out = {};
      Object.keys(vals).forEach(function (k) { out[k] = vals[k]; });
      Object.keys(inputs).forEach(function (k) {
        var x = inputs[k];
        if (x.tagName === 'TEXTAREA') out[k] = x.value;
        else if (x.tagName !== 'INPUT') return;
        else if (x.type === 'checkbox') out[k] = !!x.checked;
        else if (x.type === 'date') out[k] = st.ctx.parse ? st.ctx.parse(x.value) : null;
        else out[k] = x.value;
      });
      return out;
    }
    function runAction(a) {
      var keep = a.run ? a.run(values()) : false;
      if (keep !== true && st.spec === spec) SH.close();
    }
    var acts = el('div', 'sh-actions', null, b);
    (spec.actions || []).forEach(function (a) {
      var ab = button('sh-btn' + (a.primary ? ' primary' : '') + (a.danger ? ' danger' : ''), a.label, acts, function () { runAction(a); });
      if (a.id) ab.setAttribute('data-action', a.id);
    });
    var firstText = null;
    Object.keys(inputs).forEach(function (k) { if (!firstText && inputs[k].tagName === 'INPUT' && inputs[k].type === 'text') firstText = inputs[k]; });
    // spec.noFocus: a sheet of live controls (settings) keeps focus on its title.
    if (firstText && !spec.noFocus) { try { firstText.focus(); firstText.select(); } catch (e) { /* no focus */ } } else focusTitle();
    return true;
  };

  // Re-read the open task sheet (after a commit, a merge, a locale change).
  SH.update = function () {
    if (st.kind !== 'task') return;
    var vm = st.ctx.task ? st.ctx.task(st.id) : null;
    if (!vm) { SH.close(); return; }
    fillTask(vm);
  };

  SH.close = function () {
    if (!st.kind) return;
    disarm();
    // A live form applies its typed text before it goes (M8 review).
    if (st.parts && typeof st.parts.flush === 'function') st.parts.flush();
    var kind = st.kind, id = st.id;
    st.kind = null; st.id = null; st.spec = null; st.det = null; st.parts = null;
    st.el.hidden = true;
    st.el.style.transform = '';
    if (st.scrim) st.scrim.hidden = true;
    st.doc.body.classList.remove('sheet-open', 'sheet-side');
    var a = st.doc.activeElement, back = st.back;
    st.back = null;
    if (a && st.el.contains(a) && a.blur) a.blur();
    if (back && back.isConnected && st.doc.contains(back) && typeof back.focus === 'function') {
      try { back.focus({ preventScroll: true }); } catch (e) { /* not focusable any more */ }
    }
    if (st.ctx.onClose) st.ctx.onClose(kind, id);
  };

  SH.isOpen = function () { return !!st.kind; };
  SH.kind = function () { return (st.kind === 'form' || st.kind === 'list') && st.spec && st.spec.kind ? st.spec.kind : st.kind; };
  SH.taskId = function () { return st.kind === 'task' ? st.id : null; };
  // The spec of the open menu, form or list (its owner's relabel check).
  SH.spec = function () { return st.kind ? st.spec : null; };
  SH.detent = function () { return st.kind ? st.det : null; };
  SH.side = function () { return !!st.kind && st.side; };

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
