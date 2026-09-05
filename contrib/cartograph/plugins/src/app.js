/*
 * Cartograph - application shell.
 *
 * State flows one way: markdown -> document tree -> view tree -> layout -> DOM.
 * Every user action produces a new markdown string and re-enters at the top,
 * so what is drawn can never drift from what will be written to the note.
 */
(function () {
  'use strict';
  var CG = window.CG;
  var md = CG.md, edit = CG.edit, sidecar = CG.sidecar, layout = CG.layout, view = CG.view, host = CG.host;

  function $(sel) { return document.querySelector(sel); }
  var elStage, elEdges, elViewport, elBottom, elSheet, elScrim, elToast, elCrumbs, elOutline, elOlList, elOlSrc, elTrash, elEmpty;

  var PALETTE = ['--b0', '--b1', '--b2', '--b3', '--b4', '--b5', '--b6', '--b7'];

  var S = {
    noteId: null, title: '', src: '', doc: null, vt: null,
    pins: {}, collapsed: {}, selectedId: null, focusId: null,
    mode: 'map', query: '', filters: {}, matches: [], matchIx: -1,
    undo: [], redo: [], noteCache: {}, embedded: false, isBlockScope: false,
    baseline: '', saveTimer: null, saveState: '', pendingNoteFetch: {},
    tx: 0, ty: 0, k: 1, boxes: null, els: {}, edgeEls: [], fresh: {},
    editingId: null, booted: false,
    selectMode: false, multi: {}, ghost: null, home: null, standalone: false, recents: [],
    linkEls: []
  };
  CG.state = S;

  /* ===================================================================== */
  /* markdown pipeline                                                      */
  /* ===================================================================== */

  function fingerprintsFor(ids) {
    var seen = {}, out = [];
    ids.forEach(function (id) {
      if (!id || seen[id]) return;
      var n = S.doc && S.doc.byId[id];
      if (!n || n.kind === 'root') return;
      seen[id] = true;
      var f = sidecar.fingerprint(n);
      out.push({ id: id, key: f.key, text: f.text, depth: f.depth, parentKey: f.parentKey });
    });
    return out;
  }

  // Re-parse, carrying pins / collapse / selection / focus onto the new tree.
  function reparse(newSrc) {
    var carried = null;
    if (S.doc) {
      var ids = Object.keys(S.pins).concat(Object.keys(S.collapsed));
      if (S.selectedId) ids.push(S.selectedId);
      if (S.focusId) ids.push(S.focusId);
      carried = fingerprintsFor(ids);
    }
    var doc = md.parse(newSrc, { title: S.title });
    if (carried && carried.length) {
      var m = sidecar.match(carried, doc.nodes);
      var pins = {}, collapsed = {};
      Object.keys(S.pins).forEach(function (id) { var n = m[id]; if (n) pins[n.id] = S.pins[id]; });
      Object.keys(S.collapsed).forEach(function (id) { var n = m[id]; if (n) collapsed[n.id] = true; });
      S.pins = pins;
      S.collapsed = collapsed;
      S.selectedId = S.selectedId && m[S.selectedId] ? m[S.selectedId].id : null;
      S.focusId = S.focusId && m[S.focusId] ? m[S.focusId].id : null;
    }
    S.doc = doc;
    S.src = newSrc;
  }

  function snapshot() {
    return { src: S.src, pins: JSON.parse(JSON.stringify(S.pins)), collapsed: JSON.parse(JSON.stringify(S.collapsed)), selectedId: S.selectedId, focusId: S.focusId };
  }

  function restore(snap) {
    S.pins = snap.pins; S.collapsed = snap.collapsed;
    S.selectedId = snap.selectedId; S.focusId = snap.focusId;
    S.doc = md.parse(snap.src, { title: S.title });
    S.src = snap.src;
  }

  // The single entry point for anything that changes the note.
  function apply(newSrc, opts) {
    opts = opts || {};
    if (newSrc === S.src) { render(); return; }
    S.undo.push(snapshot());
    if (S.undo.length > 50) S.undo.shift();
    S.redo.length = 0;
    reparse(newSrc);
    var renumbered = edit.renumber(S.doc);
    if (renumbered !== S.src) reparse(renumbered);
    syncSidecar();
    fetchLinkedNotes();
    scheduleSave();
    render();
  }

  // Keep the sidecar block inside S.src at all times, so spans stay truthful.
  function syncSidecar() {
    var block = sidecar.build(S.doc, S);
    var next = edit.writeSidecar(S.doc, block);
    if (next !== S.src) reparse(next);
  }

  function undo() {
    if (!S.undo.length) return;
    S.redo.push(snapshot());
    restore(S.undo.pop());
    fetchLinkedNotes();
    scheduleSave();
    render();
    toast('Undone');
  }

  /* ===================================================================== */
  /* saving                                                                 */
  /* ===================================================================== */

  function scheduleSave() {
    clearTimeout(S.saveTimer);
    setStatus('unsaved');
    S.saveTimer = setTimeout(save, 600);
  }

  function setStatus(state) {
    S.saveState = state;
    var t = $('#status');
    if (!t) return;
    t.textContent = state === 'saving' ? 'saving…' : state === 'saved' ? 'saved' : state === 'unsaved' ? 'unsaved changes' : state === 'error' ? 'not saved' : '';
  }

  function save() {
    if (host.isMock && !window.Synapse) return;
    setStatus('saving');
    var payload = S.src;
    var go = S.isBlockScope
      ? Promise.resolve(null)
      : host.readContent(S.noteId).catch(function () { return null; });
    return go.then(function (current) {
      if (current !== null && current !== S.baseline && current !== payload) {
        setStatus('unsaved');
        return conflictSheet(current, payload);
      }
      return host.writeContent(S.noteId, payload).then(function () {
        S.baseline = payload;
        setStatus('saved');
      });
    }).catch(function (e) {
      setStatus('error');
      toast(String((e && e.message) || e).slice(0, 120));
    });
  }

  function conflictSheet(current, mine) {
    openSheet('This note changed elsewhere', function (body) {
      var p = document.createElement('p');
      p.textContent = 'The note was edited outside Cartograph while this map was open. Choose which version to keep — the other one is discarded.';
      body.appendChild(p);
      var row = document.createElement('div');
      row.className = 'btn-row';
      var reload = document.createElement('button');
      reload.className = 'btn';
      reload.textContent = 'Use the other version';
      reload.onclick = function () {
        closeSheet();
        S.undo.push(snapshot());
        reparse(current);
        S.baseline = current;
        sidecar.apply(S.doc, S);
        fetchLinkedNotes();
        setStatus('saved');
        render();
        toast('Reloaded from the note');
      };
      var keep = document.createElement('button');
      keep.className = 'btn danger';
      keep.textContent = 'Keep my map';
      keep.onclick = function () {
        closeSheet();
        host.writeContent(S.noteId, mine).then(function () {
          S.baseline = mine; setStatus('saved'); toast('Overwrote the note');
        });
      };
      row.appendChild(reload); row.appendChild(keep);
      body.appendChild(row);
    });
  }

  /* ===================================================================== */
  /* attached notes                                                         */
  /* ===================================================================== */

  function fetchLinkedNotes() {
    var want = {};
    S.doc.nodes.forEach(function (n) {
      n.links.forEach(function (l) {
        if (l.type === 'note' && l.noteId && !S.noteCache[l.noteId] && !S.pendingNoteFetch[l.noteId]) want[l.noteId] = true;
      });
    });
    var ids = Object.keys(want);
    if (!ids.length) return;
    ids.forEach(function (i) { S.pendingNoteFetch[i] = true; });
    host.readNotes(ids).then(function (rows) {
      var got = false;
      rows.forEach(function (r) { S.noteCache[r.id] = { title: r.title, content: r.content }; got = true; });
      ids.forEach(function (i) {
        delete S.pendingNoteFetch[i];
        if (!S.noteCache[i]) S.noteCache[i] = { title: 'Missing note', content: '', missing: true };
      });
      if (got || ids.length) render();
    }).catch(function () { ids.forEach(function (i) { delete S.pendingNoteFetch[i]; }); });
  }

  /* ===================================================================== */
  /* inline markdown                                                        */
  /* ===================================================================== */

  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }

  function stripNoteLinks(text) {
    return text.replace(/\[([^\]]*)\]\(\s*synapseresource:\/\/note\/[^)]*\)/gi, '').replace(/\s{2,}/g, ' ').trim();
  }

  function inlineMd(text) {
    var out = esc(stripNoteLinks(text));
    out = out.replace(/`([^`]+)`/g, '<code>$1</code>');
    out = out.replace(/!\[([^\]]*)\]\(([^)]*)\)/g, '<span class="imgref">🖼 $1</span>');
    out = out.replace(/\[([^\]]*)\]\(([^)]*)\)/g, function (m, label, url) {
      var cls = url.charAt(0) === '#' ? 'anchorref' : 'extref';
      return '<a class="' + cls + '" data-href="' + esc(url) + '">' + label + '</a>';
    });
    out = out.replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>');
    out = out.replace(/(^|[^*])\*([^*]+)\*/g, '$1<i>$2</i>');
    out = out.replace(/~~([^~]+)~~/g, '<s>$1</s>');
    out = out.replace(/(^|\s)#([\w一-鿿][\w一-鿿\-\/]*)/g, '$1<span class="tagref">#$2</span>');
    return out || '<span style="opacity:.4">empty</span>';
  }

  /* ===================================================================== */
  /* map rendering                                                          */
  /* ===================================================================== */

  function nodeClasses(v, depth) {
    var c = ['cg-node', 'k-' + (v.isRoot ? 'root' : v.kind), 'd' + Math.min(depth, 6)];
    if (depth >= 3) c.push('deep');
    if (S.ghost) {
      var g = v.kind === 'ghost' ? { state: v.ghostState } : (S.ghost.cls.byNew[v.id] || null);
      if (g && g.state && g.state !== 'kept') c.push('g-' + g.state);
      else if (g) c.push('g-kept');
    }
    if (S.multi[v.id]) c.push('multi');
    if (v.id === S.selectedId) c.push('sel');
    if (S.vt.filtering && v.matched) c.push('match');
    if (S.vt.filtering && !v.keep) c.push('dim');
    if (v.checked === true) c.push('done');
    if (v.id === S.editingId) c.push('editing');
    return c.join(' ');
  }

  function buildNodeEl(v, depth) {
    var d = document.createElement('div');
    d.dataset.id = v.id;
    fillNodeEl(d, v, depth);
    return d;
  }

  function fillNodeEl(d, v, depth) {
    d.className = nodeClasses(v, depth);
    if (S.editingId === v.id) return;   // never blow away the caret mid-edit
    var html = '';
    if (v.checked !== null && v.kind !== 'note') {
      html += '<span class="cg-check' + (v.checked ? ' on' : '') + '"></span>';
    }
    if (v.kind === 'note') {
      html += '<span class="label"><span class="note-title">' + esc(v.noteTitle) + '</span>' +
        (v.notePreview ? '<span class="note-prev">' + esc(v.notePreview) + '</span>' : '') + '</span>';
    } else {
      html += '<span class="label">' + inlineMd(v.text) + '</span>';
    }
    var meta = '';
    if (v.taskTotal) meta += '<span class="cg-pill tasks">' + v.taskDone + '/' + v.taskTotal + '</span>';
    if (v.hasBody) meta += '<span class="cg-pill body">' + bodyGlyph(v.bodyTypes) + '</span>';
    if (S.pins[v.id]) meta += '<span class="cg-pill pinned">📌</span>';
    if (meta) html += '<span class="cg-meta">' + meta + '</span>';
    d.innerHTML = html;
  }

  function bodyGlyph(types) {
    if (types.indexOf('code') >= 0) return '⟨⟩';
    if (types.indexOf('table') >= 0) return '▦';
    if (types.indexOf('image') >= 0) return '🖼';
    if (types.indexOf('quote') >= 0) return '❝';
    return '¶';
  }

  function branchColor(branch) {
    if (branch == null || branch < 0) return getComputedStyle(document.documentElement).getPropertyValue('--accent').trim();
    return getComputedStyle(document.documentElement).getPropertyValue(PALETTE[branch % PALETTE.length]).trim();
  }

  function renderMap() {
    var vt = S.vt;
    var live = {};

    // 1. sync elements
    (function walk(v, depth) {
      live[v.id] = true;
      var d = S.els[v.id];
      if (!d) {
        d = buildNodeEl(v, depth);
        d.style.opacity = '0';
        S.els[v.id] = d;
        S.fresh[v.id] = true;
        elStage.appendChild(d);
      } else {
        fillNodeEl(d, v, depth);
      }
      d._view = v;
      d._depth = depth;
      for (var i = 0; i < v.children.length; i++) walk(v.children[i], depth + 1);
    })(vt.root, 0);

    Object.keys(S.els).forEach(function (id) {
      if (live[id]) return;
      var d = S.els[id];
      d.style.opacity = '0';
      d.style.pointerEvents = 'none';
      setTimeout(function () { if (d.parentNode) d.parentNode.removeChild(d); }, 200);
      delete S.els[id];
      delete S.fresh[id];
    });

    // 2. measure, then lay out
    var sizes = {};
    Object.keys(S.els).forEach(function (id) {
      var d = S.els[id];
      sizes[id] = { w: d.offsetWidth, h: d.offsetHeight };
    });

    var res = layout.compute(vt.root, {
      sizeOf: function (v) { return sizes[v.id] || { w: 150, h: 34 }; },
      isCollapsed: function () { return false; },
      pinOf: function (v) { return S.pins[v.id] || null; },
      vgap: 16, hgap: 56
    });
    S.boxes = res.boxes;

    // 3. position
    res.boxes.forEach(function (b) {
      var d = S.els[b.node.id];
      if (!d) return;
      if (S.fresh[b.node.id]) {
        var p = b.node.parent && res.boxes.get(b.node.parent.id);
        var sx = p ? p.x : b.x, sy = p ? p.y : b.y;
        d.style.transition = 'none';
        d.style.transform = 'translate(' + sx + 'px,' + sy + 'px)';
        d.offsetHeight;
        d.style.transition = '';
        delete S.fresh[b.node.id];
      }
      d.style.transform = 'translate(' + b.x + 'px,' + b.y + 'px)';
      d.style.opacity = '1';
      d.style.borderLeftColor = b.node.kind === 'note' ? branchColor(b.branch) : '';
    });

    drawEdges(res, vt);
    drawToggles(res, vt);
    drawLinkHandles(res, vt);
    S.lastResult = res;
  }

  function edgeEnds(from, to) {
    var rightward = (to.x + to.w / 2) >= (from.x + from.w / 2);
    return {
      x1: rightward ? from.x + from.w : from.x,
      y1: from.y + from.h / 2,
      x2: rightward ? to.x : to.x + to.w,
      y2: to.y + to.h / 2
    };
  }

  function edgePath(from, to) {
    var e = edgeEnds(from, to);
    var mx = e.x1 + (e.x2 - e.x1) * 0.5;
    return 'M' + e.x1 + ',' + e.y1 + 'C' + mx + ',' + e.y1 + ' ' + mx + ',' + e.y2 + ' ' + e.x2 + ',' + e.y2;
  }

  function drawEdges(res, vt) {
    var frag = document.createDocumentFragment();
    res.edges.forEach(function (e) {
      var p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      p.setAttribute('d', edgePath(e.from, e.to));
      p.setAttribute('stroke', branchColor(e.to.branch));
      p.setAttribute('stroke-width', String(Math.max(1.4, 4 - e.to.depth * 0.7)));
      if (e.pinned) p.setAttribute('stroke-dasharray', '2 5');
      var dim = vt.filtering && !(e.child.keep);
      p.setAttribute('opacity', dim ? '0.1' : (e.child.kind === 'note' ? '0.55' : '0.8'));
      frag.appendChild(p);
    });
    vt.crossLinks.forEach(function (cl) {
      var a = res.boxes.get(cl.from), b = res.boxes.get(cl.to);
      if (!a || !b) return;
      var p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      p.setAttribute('d', edgePath(a, b));
      p.setAttribute('stroke', 'currentColor');
      p.setAttribute('stroke-width', '1.5');
      p.setAttribute('stroke-dasharray', '5 5');
      var lit = !vt.filtering ||
        ((vt.byId[cl.from] && vt.byId[cl.from].keep) || (vt.byId[cl.to] && vt.byId[cl.to].keep));
      p.setAttribute('opacity', lit ? '0.4' : '0.08');
      frag.appendChild(p);
    });
    elEdges.textContent = '';
    elEdges.appendChild(frag);
  }

  function drawToggles(res, vt) {
    S.edgeEls.forEach(function (t) { if (t.parentNode) t.parentNode.removeChild(t); });
    S.edgeEls = [];
    res.boxes.forEach(function (b) {
      var v = b.node;
      var doc = v.ref;
      if (!doc || v.kind === 'note') return;
      var hasKids = doc.children.length > 0;
      if (!hasKids) return;
      var t = document.createElement('button');
      t.className = 'cg-toggle';
      t.dataset.toggle = v.id;
      t.textContent = v.collapsed ? String(v.hiddenCount) : '−';
      var rightward = b.dir >= 0;
      var x = rightward ? b.x + b.w - 4 : b.x - 16;
      t.style.transform = 'translate(' + x + 'px,' + (b.y + b.h / 2 - 10) + 'px) scale(var(--inv, 1))';
      if (vt.filtering && !v.keep) t.style.opacity = '0.15';
      elStage.appendChild(t);
      S.edgeEls.push(t);
    });
  }

  /*
   * A dashed 1.5px curve is not a touch target, so every link gets a handle at
   * its midpoint. For the cubic used here the curve's midpoint is exactly the
   * average of its endpoints, which makes this cheap and exact.
   *
   * The handle is an ordinary element in the stage rather than something inside
   * the SVG: #edges is a 1x1 box relying on overflow, and hit-testing content
   * outside an SVG viewport is not dependable across engines.
   */
  function drawLinkHandles(res, vt) {
    S.linkEls.forEach(function (h) { if (h.parentNode) h.parentNode.removeChild(h); });
    S.linkEls = [];
    if (S.ghost) return;
    vt.crossLinks.forEach(function (cl) {
      var a = res.boxes.get(cl.from), b = res.boxes.get(cl.to);
      if (!a || !b) return;
      var e = edgeEnds(a, b);
      var h = document.createElement('button');
      var lit = !vt.filtering ||
        ((vt.byId[cl.from] && vt.byId[cl.from].keep) || (vt.byId[cl.to] && vt.byId[cl.to].keep));
      h.className = 'cg-link' + (lit ? '' : ' dim') +
        (S.multi[cl.from] && S.multi[cl.to] ? ' on' : '');
      h.dataset.linkFrom = cl.from;
      h.dataset.linkTo = cl.to;
      h.innerHTML = '<svg viewBox="0 0 24 24"><path d="M9.5 14.5l5-5"/>' +
        '<path d="M12.5 7.5l1.8-1.8a3.5 3.5 0 014.9 4.9L17.4 12.4"/>' +
        '<path d="M11.5 16.5l-1.8 1.8a3.5 3.5 0 01-4.9-4.9L6.6 11.6"/></svg>';
      h.style.transform = 'translate(' + ((e.x1 + e.x2) / 2 - 13) + 'px,' +
        ((e.y1 + e.y2) / 2 - 13) + 'px) scale(var(--inv, 1))';
      elStage.appendChild(h);
      S.linkEls.push(h);
    });
  }

  /* ===================================================================== */
  /* camera                                                                 */
  /* ===================================================================== */

  function applyTransform() {
    elStage.style.transform = 'translate(' + S.tx + 'px,' + S.ty + 'px) scale(' + S.k + ')';
    /*
     * Handles and collapse chips are affordances, not diagram content, so they
     * counter-scale to hold a constant size on screen. At a readable zoom of
     * 0.62 a 26px handle would otherwise render 16px, which is not a touch
     * target. Clamped so they do not balloon when zoomed far out.
     */
    elStage.style.setProperty('--inv', String(Math.min(2.2, 1 / S.k)));
  }

  /*
   * The band of #viewport the reader can actually see.
   *
   * `interactive-widget=resizes-content` shrinks the layout viewport on Android
   * Chrome, but iOS WKWebView ignores it entirely - there the layout viewport
   * keeps its full height and the keyboard simply covers the bottom of it.
   * visualViewport is the one signal both platforms agree on, so all framing
   * goes through here rather than through clientHeight.
   */
  function visibleRect() {
    var r = elViewport.getBoundingClientRect();
    var top = r.top, bottom = r.bottom, left = r.left, right = r.right;
    var vv = window.visualViewport;
    if (vv) {
      top = Math.max(top, vv.offsetTop);
      bottom = Math.min(bottom, vv.offsetTop + vv.height);
      left = Math.max(left, vv.offsetLeft);
      right = Math.min(right, vv.offsetLeft + vv.width);
    }
    // The action bar floats over the canvas, so it hides what is behind it.
    if (elBottom && elBottom.classList.contains('open')) {
      bottom -= Math.min(elBottom.offsetHeight, (bottom - top) * 0.4);
    }
    return {
      top: top, bottom: bottom, left: left, right: right,
      height: Math.max(48, bottom - top), width: Math.max(48, right - left),
      originTop: r.top, originLeft: r.left
    };
  }


  /*
   * Nudge the node being edited back into view by the smallest amount that
   * works. Measured from the live element rather than the layout box, because
   * the card grows as the text wraps and the layout has not re-run yet.
   */
  /*
   * Where a node will BE on screen once the transitions land - not where it is
   * painting right now.
   *
   * Reading getBoundingClientRect() mid-transition would make each follow-up
   * call re-apply a correction that is already in flight, and the map would
   * overshoot and oscillate while the keyboard animates. Layout position comes
   * from the laid-out box and the stage transform; only the SIZE is read from
   * the element, because the card grows as the text wraps.
   */
  function nodeScreenRect(viewId) {
    var el = S.els[viewId];
    var box = S.boxes && S.boxes.get(viewId);
    if (!el || !box) return null;
    var r = elViewport.getBoundingClientRect();
    var top = r.top + S.ty + box.y * S.k;
    var left = r.left + S.tx + box.x * S.k;
    var h = el.offsetHeight * S.k;
    var w = el.offsetWidth * S.k;
    return { top: top, left: left, width: w, height: h, bottom: top + h, right: left + w };
  }

  function keepEditingVisible() {
    var id = S.editingId;
    if (!id) return false;
    var margin = 14;
    var vis = visibleRect();

    if (S.mode === 'outline') {
      var row = elOlList.querySelector('[data-id="' + id + '"]');
      if (!row) return false;
      var rb = row.getBoundingClientRect();
      if (rb.bottom > vis.bottom - margin || rb.top < vis.top + margin) {
        var delta = (rb.top + rb.height / 2) - (vis.top + vis.height / 2);
        if (Math.abs(delta) >= 1) { elOutline.scrollTop += delta; return true; }
      }
      return false;
    }

    var r = nodeScreenRect(id);
    if (!r) return false;
    var top = r.top, left = r.left, h = r.height, w = r.width, bottom = r.bottom, right = r.right;

    var dx = 0, dy = 0;
    if (h + margin * 2 >= vis.height) dy = (vis.top + margin) - top;
    else if (bottom > vis.bottom - margin) dy = (vis.bottom - margin) - bottom;
    else if (top < vis.top + margin) dy = (vis.top + margin) - top;
    if (w + margin * 2 >= vis.width) dx = (vis.left + margin) - left;
    else if (right > vis.right - margin) dx = (vis.right - margin) - right;
    else if (left < vis.left + margin) dx = (vis.left + margin) - left;
    if (Math.abs(dx) < 1 && Math.abs(dy) < 1) return false;
    S.tx += dx;
    S.ty += dy;
    elStage.style.transition = 'transform .18s cubic-bezier(.22,.61,.36,1)';
    applyTransform();
    clearTimeout(S._keepT);
    S._keepT = setTimeout(function () { elStage.style.transition = 'none'; }, 200);
    return true;
  }

  var READABLE = 0.62;

  /*
   * Two behaviours. Opening a map, or reacting to a resize, must land at a
   * readable zoom - shrinking a wide map until the labels vanish is worse than
   * asking the reader to pan, so below READABLE we centre on the root instead.
   * The Fit button asks for the whole map and gets it, however small.
   */
  function fit(animate, opts) {
    if (!S.lastResult) return;
    var all = !!(opts && opts.all);
    var b = S.lastResult.bbox;
    var pad = 34;
    var vis = visibleRect();
    var vw = vis.width, vh = vis.height;
    var w = Math.max(1, b.x1 - b.x0), h = Math.max(1, b.y1 - b.y0);
    var k = Math.min((vw - pad * 2) / w, (vh - pad * 2) / h, 1.35);
    if (!all) k = Math.max(k, READABLE);
    S.k = clamp(k, 0.15, 3);

    // Centre of the visible band, in #viewport-local coordinates.
    var cx = (vis.left + vis.right) / 2 - vis.originLeft;
    var cy = (vis.top + vis.bottom) / 2 - vis.originTop;
    var fitsWide = w * S.k <= vw - pad;
    var fitsTall = h * S.k <= vh - pad;
    if (all || (fitsWide && fitsTall)) {
      S.tx = cx - (b.x0 + w / 2) * S.k;
      S.ty = cy - (b.y0 + h / 2) * S.k;
    } else {
      var anchor = S.boxes && S.boxes.get(S.vt.root.id);
      var ax = anchor ? anchor.x + anchor.w / 2 : b.x0 + w / 2;
      var ay = anchor ? anchor.y + anchor.h / 2 : b.y0 + h / 2;
      S.tx = cx - ax * S.k;
      S.ty = cy - (fitsTall ? (b.y0 + h / 2) : ay) * S.k;
    }
    elStage.style.transition = animate ? 'transform .3s cubic-bezier(.22,.61,.36,1)' : 'none';
    applyTransform();
    if (animate) setTimeout(function () { elStage.style.transition = 'none'; }, 320);
  }

  function centerOn(viewId, animate) {
    var b = S.boxes && S.boxes.get(viewId);
    if (!b) return;
    var vis = visibleRect();
    S.tx = (vis.left + vis.right) / 2 - vis.originLeft - (b.x + b.w / 2) * S.k;
    S.ty = (vis.top + vis.bottom) / 2 - vis.originTop - (b.y + b.h / 2) * S.k;
    elStage.style.transition = animate ? 'transform .3s cubic-bezier(.22,.61,.36,1)' : 'none';
    applyTransform();
    if (animate) setTimeout(function () { elStage.style.transition = 'none'; }, 320);
  }

  /*
   * Frame one branch rather than the whole map. After a proposal or an import,
   * the thing worth looking at is the part that changed - centring the root
   * instead can leave it off the side of the screen entirely.
   */
  function fitBranch(viewId, animate) {
    if (!S.boxes) return fit(animate);
    var v = S.vt.byId[viewId];
    if (!v) return fit(animate);
    var b = null;
    (function walk(x) {
      var bx = S.boxes.get(x.id);
      if (bx) {
        if (!b) b = { x0: bx.x, y0: bx.y, x1: bx.x + bx.w, y1: bx.y + bx.h };
        else {
          b.x0 = Math.min(b.x0, bx.x); b.y0 = Math.min(b.y0, bx.y);
          b.x1 = Math.max(b.x1, bx.x + bx.w); b.y1 = Math.max(b.y1, bx.y + bx.h);
        }
      }
      for (var i = 0; i < x.children.length; i++) walk(x.children[i]);
    })(v);
    if (!b) return fit(animate);

    var pad = 30;
    var vis = visibleRect();
    var w = Math.max(1, b.x1 - b.x0), h = Math.max(1, b.y1 - b.y0);
    S.k = clamp(Math.min((vis.width - pad * 2) / w, (vis.height - pad * 2) / h, 1.2), 0.15, 3);
    S.tx = (vis.left + vis.right) / 2 - vis.originLeft - (b.x0 + w / 2) * S.k;
    S.ty = (vis.top + vis.bottom) / 2 - vis.originTop - (b.y0 + h / 2) * S.k;
    S.userMoved = true;
    elStage.style.transition = animate ? 'transform .3s cubic-bezier(.22,.61,.36,1)' : 'none';
    applyTransform();
    if (animate) setTimeout(function () { elStage.style.transition = 'none'; }, 320);
  }

  function screenToStage(px, py) {
    var r = elViewport.getBoundingClientRect();
    return { x: (px - r.left - S.tx) / S.k, y: (py - r.top - S.ty) / S.k };
  }

  /* ===================================================================== */
  /* outline                                                                */
  /* ===================================================================== */

  function renderOutline() {
    var frag = document.createDocumentFragment();
    (function walk(v, depth) {
      if (v.kind !== 'root') {
        var row = document.createElement('div');
        row.className = 'ol-row' + (v.kind === 'heading' ? ' h' : '') +
          (v.id === S.selectedId ? ' sel' : '') +
          (S.vt.filtering && !v.keep ? ' dim' : '') +
          (v.checked === true ? ' done' : '');
        row.dataset.id = v.id;

        var guide = document.createElement('span');
        guide.className = 'ol-guide';
        guide.style.marginLeft = (Math.max(0, depth - 1) * 15) + 'px';
        guide.style.borderLeftColor = depth > 1 ? '' : 'transparent';
        row.appendChild(guide);

        if (v.checked !== null && v.kind !== 'note') {
          var chk = document.createElement('span');
          chk.className = 'cg-check' + (v.checked ? ' on' : '');
          chk.dataset.check = v.id;
          row.appendChild(chk);
        }
        var txt = document.createElement('span');
        txt.className = 'ol-txt';
        if (v.kind === 'note') {
          txt.innerHTML = '<span class="ol-note">▸ ' + esc(v.noteTitle) + '</span>';
        } else {
          txt.innerHTML = inlineMd(v.text);
        }
        row.appendChild(txt);
        frag.appendChild(row);
      }
      for (var i = 0; i < v.children.length; i++) walk(v.children[i], depth + 1);
    })(S.vt.root, 0);
    elOlList.textContent = '';
    elOlList.appendChild(frag);
    if (elOlSrc.classList.contains('on')) elOlSrc.textContent = S.src;
  }

  /* ===================================================================== */
  /* chrome                                                                 */
  /* ===================================================================== */

  function render() {
    var homeEl = $('#home');
    document.body.classList.toggle('ghosting', !!S.ghost);
    document.body.classList.toggle('mapping', !S.home);
    if (S.home) { renderHome(); return; }
    if (homeEl) homeEl.classList.remove('on');
    // While filtering, collapse is ignored so every path to a match is open.
    var filtering = !!(S.query || '').trim() || !!S.filters.status || !!S.filters.hasNote || !!S.filters.tag;
    // A ghost preview draws the PROPOSED tree, never the current one.
    var doc = S.ghost ? S.ghost.doc : S.doc;
    S.vt = view.build(doc, {
      title: S.title,
      collapsed: S.ghost ? {} : (filtering ? {} : S.collapsed),
      focusId: S.ghost ? null : S.focusId,
      query: S.ghost ? '' : S.query,
      filters: S.ghost ? {} : S.filters,
      noteCache: S.noteCache
    });
    if (S.ghost) injectGhostNodes();
    if (S.mode === 'map') renderMap(); else renderOutline();
    renderCrumbs();
    renderBottomBar();
    renderMatches();
    $('#btnUndo').disabled = !S.undo.length;
    elEmpty.classList.toggle('on', S.doc.nodes.length <= 1);
    if (S.doc.nodes.length <= 1) {
      elEmpty.innerHTML = '<div style="font-size:38px">🗺️</div><div><b>Nothing to map yet</b><br>' +
        'This note has no headings or bullets. Add one to start the map, or let AI build one from the whole note.</div>';
      var row = document.createElement('div');
      row.className = 'btn-row';
      var add = document.createElement('button');
      add.className = 'btn primary';
      add.textContent = 'Add the first node';
      add.onclick = function () { addChild(S.doc.root); };
      row.appendChild(add);
      if (!S.embedded) {
        var gen = document.createElement('button');
        gen.className = 'btn';
        gen.textContent = 'Generate with AI';
        gen.onclick = function () { generateForCurrentNote(); };
        row.appendChild(gen);
      }
      elEmpty.appendChild(row);
    }
  }

  function renderCrumbs() {
    elCrumbs.textContent = '';
    var chain = [];
    if (S.focusId && S.doc.byId[S.focusId]) {
      for (var n = S.doc.byId[S.focusId]; n; n = n.parent) chain.unshift(n);
    } else {
      chain = [S.doc.root];
    }
    chain.forEach(function (n, i) {
      if (i) {
        var sep = document.createElement('span');
        sep.className = 'sep'; sep.textContent = '›';
        elCrumbs.appendChild(sep);
      }
      var c = document.createElement('span');
      c.className = 'crumb' + (i === chain.length - 1 ? ' last' : '');
      c.textContent = n.kind === 'root' ? (S.title || 'Note') : md.plainText(n.text);
      c.onclick = function () { setFocus(n.kind === 'root' ? null : n.id); };
      elCrumbs.appendChild(c);
    });
    $('#btnFocusOut').hidden = !S.focusId;
  }

  var ICONS = {
    child: '<svg viewBox="0 0 24 24"><path d="M5 6h4M7 4v4"/><path d="M11 6h8M11 12h8M11 18h8"/><path d="M5 12h4M5 18h4"/></svg>',
    sibling: '<svg viewBox="0 0 24 24"><path d="M4 7h16M4 17h16"/><path d="M12 9v6M9 12h6"/></svg>',
    edit: '<svg viewBox="0 0 24 24"><path d="M4 20h4L19 9a2.1 2.1 0 00-3-3L5 17v3z"/></svg>',
    note: '<svg viewBox="0 0 24 24"><path d="M6 3h9l5 5v13H6z"/><path d="M15 3v5h5"/><path d="M9 13h7M9 17h5"/></svg>',
    focus: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M12 3v3M12 18v3M3 12h3M18 12h3"/></svg>',
    more: '<svg viewBox="0 0 24 24"><circle cx="5" cy="12" r="1.4"/><circle cx="12" cy="12" r="1.4"/><circle cx="19" cy="12" r="1.4"/></svg>',
    open: '<svg viewBox="0 0 24 24"><path d="M14 4h6v6M20 4l-9 9"/><path d="M18 14v5a1 1 0 01-1 1H5a1 1 0 01-1-1V7a1 1 0 011-1h5"/></svg>',
    indent: '<svg viewBox="0 0 24 24"><path d="M9 6h11M9 12h11M9 18h11"/><path d="M3 9l3 3-3 3"/></svg>',
    outdent: '<svg viewBox="0 0 24 24"><path d="M9 6h11M9 12h11M9 18h11"/><path d="M6 9l-3 3 3 3"/></svg>',
    up: '<svg viewBox="0 0 24 24"><path d="M12 19V5M6 11l6-6 6 6"/></svg>',
    down: '<svg viewBox="0 0 24 24"><path d="M12 5v14M6 13l6 6 6-6"/></svg>',
    task: '<svg viewBox="0 0 24 24"><path d="M4 7h4v4H4zM4 15h4v4H4z"/><path d="M11 9h9M11 17h9"/></svg>',
    unpin: '<svg viewBox="0 0 24 24"><path d="M9 4h6l-1 6 4 4H6l4-4z"/><path d="M12 14v6"/></svg>',
    trash: '<svg viewBox="0 0 24 24"><path d="M4 7h16M9 7V5h6v2M6 7l1 13h10l1-13"/></svg>',
    select: '<svg viewBox="0 0 24 24"><path d="M4 8V5a1 1 0 011-1h3M20 8V5a1 1 0 00-1-1h-3M4 16v3a1 1 0 001 1h3M20 16v3a1 1 0 01-1 1h-3"/><path d="M9 12l2 2 4-4"/></svg>',
    ai: '<svg viewBox="0 0 24 24"><path d="M12 3l1.9 4.6L18.5 9.5 13.9 11.4 12 16l-1.9-4.6L5.5 9.5l4.6-1.9z"/><path d="M18 15l.9 2.1 2.1.9-2.1.9-.9 2.1-.9-2.1-2.1-.9 2.1-.9z"/></svg>',
    merge: '<svg viewBox="0 0 24 24"><path d="M7 4v5a4 4 0 004 4h6M17 4v5a4 4 0 01-4 4"/><path d="M14 10l3 3-3 3"/></svg>',
    group: '<svg viewBox="0 0 24 24"><rect x="3" y="4" width="7" height="7" rx="1.5"/><rect x="14" y="4" width="7" height="7" rx="1.5"/><path d="M12 14v3a1 1 0 01-1 1H4M12 14v3a1 1 0 001 1h7"/></svg>',
    apply: '<svg viewBox="0 0 24 24"><path d="M4 12l5 5L20 6"/></svg>',
    close: '<svg viewBox="0 0 24 24"><path d="M18 6L6 18M6 6l12 12"/></svg>',
    home: '<svg viewBox="0 0 24 24"><path d="M4 11l8-7 8 7"/><path d="M6 10v9a1 1 0 001 1h10a1 1 0 001-1v-9"/></svg>',
    map: '<svg viewBox="0 0 24 24"><path d="M9 4L3 6v14l6-2 6 2 6-2V4l-6 2z"/><path d="M9 4v14M15 6v14"/></svg>',
    move: '<svg viewBox="0 0 24 24"><path d="M5 4h5M5 4v5"/><path d="M5 4l7 7"/><path d="M14 20h5v-5"/><path d="M19 20l-7-7"/></svg>',
    link: '<svg viewBox="0 0 24 24"><path d="M9.5 14.5l5-5"/><path d="M12.5 7.5l1.8-1.8a3.5 3.5 0 014.9 4.9L17.4 12.4"/><path d="M11.5 16.5l-1.8 1.8a3.5 3.5 0 01-4.9-4.9L6.6 11.6"/></svg>',
    unlink: '<svg viewBox="0 0 24 24"><path d="M12.5 7.5l1.8-1.8a3.5 3.5 0 014.9 4.9L17.4 12.4"/><path d="M11.5 16.5l-1.8 1.8a3.5 3.5 0 01-4.9-4.9L6.6 11.6"/><path d="M4 4l16 16"/></svg>'
  };

  function bb(label, icon, cls, fn) {
    var b = document.createElement('button');
    b.className = 'bb' + (cls ? ' ' + cls : '');
    b.innerHTML = icon + '<span>' + label + '</span>';
    b.onclick = fn;
    return b;
  }

  function selectedView() { return S.selectedId && S.vt.byId[S.selectedId]; }
  function selectedDoc() {
    var v = selectedView();
    return v && v.kind !== 'note' ? v.ref : null;
  }

  function renderBottomBar() {
    elBottom.textContent = '';

    elBottom.classList.toggle('ghost', !!S.ghost);
    if (S.ghost) {
      elBottom.classList.add('open');
      var note = document.createElement('div');
      note.className = 'bb-note';
      note.textContent = S.ghost.headline;
      elBottom.appendChild(note);
      elBottom.appendChild(bb('Apply', ICONS.apply, 'accent', applyGhost));
      elBottom.appendChild(bb('Discard', ICONS.close, 'danger', discardGhost));
      return;
    }

    if (S.selectMode) {
      elBottom.classList.add('open');
      var n = Object.keys(S.multi).length;
      var nodes = multiDocNodes();
      var cards = multiCardViews();
      var mixed = nodes.length > 0 && cards.length > 0;

      var count = document.createElement('div');
      count.className = 'bb-note';
      count.textContent = n
        ? n + ' selected' + (cards.length ? ' · ' + cards.length + ' attached' : '')
        : 'Tap nodes to select';
      elBottom.appendChild(count);

      /*
       * Merge, Group and Split rewrite markdown labels. A card is a reference to
       * another note, not text this note owns, so they are withheld whenever one
       * is in the selection rather than offered and then failing.
       */
      if (!cards.length) {
        elBottom.appendChild(bb('Merge', ICONS.merge, n >= 2 ? 'accent' : 'off', function () { runOp('merge'); }));
        elBottom.appendChild(bb('Group', ICONS.group, n >= 2 ? 'accent' : 'off', function () { runOp('group'); }));
      }

      elBottom.appendChild(bb('Move', ICONS.move, n >= 1 && !mixed ? '' : 'off', function () {
        if (!n) return toast('Select something first');
        // Nodes move as subtrees among children; cards move as lines into a
        // body. Doing both at once is possible but would fail silently.
        if (mixed) return toast('Move nodes and attached notes separately');
        if (cards.length) return moveCardsPicker(cards);
        movePicker(nodes);
      }));
      var ids = Object.keys(S.multi);
      var pair = ids.length === 2 ? linkedPair(ids[0], ids[1]) : null;
      if (pair) {
        elBottom.appendChild(bb('Unlink', ICONS.unlink, 'danger', unlinkSelected));
      } else {
        elBottom.appendChild(bb('Link', ICONS.link, n === 2 ? '' : 'off', function () {
          if (n !== 2) return toast('Select exactly two nodes to link them');
          linkSelected();
        }));
      }
      if (!cards.length) {
        elBottom.appendChild(bb('Split', ICONS.ai, n >= 1 ? '' : 'off', function () { runOp('split'); }));
      }
      elBottom.appendChild(bb('Done', ICONS.close, '', exitSelect));
      return;
    }

    var v = selectedView();
    if (!v || S.embedded) { elBottom.classList.remove('open'); return; }
    elBottom.classList.add('open');

    if (v.kind === 'note') {
      elBottom.appendChild(bb('Open', ICONS.open, 'accent', function () { host.openNote(v.noteId); }));
      elBottom.appendChild(bb('Edit', ICONS.edit, '', function () { editNoteSheet(v.noteId); }));
      elBottom.appendChild(bb('Move', ICONS.move, '', function () { moveCardsPicker([v]); }));
      elBottom.appendChild(bb('Link', ICONS.link, '', function () { cardLinkPicker(v); }));
      elBottom.appendChild(bb('Select', ICONS.select, '', function () { enterSelect(v.id); }));
      elBottom.appendChild(bb('Detach', ICONS.trash, 'danger', function () { detachNote(v); }));
      return;
    }

    if (S.mode === 'outline') {
      elBottom.appendChild(bb('Child', ICONS.child, 'accent', function () { addChild(v.ref); }));
      elBottom.appendChild(bb('Sibling', ICONS.sibling, '', function () { addSibling(v.ref); }));
      elBottom.appendChild(bb('Out', ICONS.outdent, '', function () { outdentNode(v.ref); }));
      elBottom.appendChild(bb('In', ICONS.indent, '', function () { indentNode(v.ref); }));
      elBottom.appendChild(bb('Up', ICONS.up, '', function () { nudge(v.ref, -1); }));
      elBottom.appendChild(bb('Down', ICONS.down, '', function () { nudge(v.ref, 1); }));
      elBottom.appendChild(bb('More', ICONS.more, '', moreMenu));
      return;
    }

    elBottom.appendChild(bb('Child', ICONS.child, 'accent', function () { addChild(v.ref); }));
    if (v.ref.kind !== 'root') elBottom.appendChild(bb('Sibling', ICONS.sibling, '', function () { addSibling(v.ref); }));
    elBottom.appendChild(bb('Edit', ICONS.edit, '', function () { beginEdit(v.id); }));
    elBottom.appendChild(bb('Note', ICONS.note, '', noteMenu));
    elBottom.appendChild(bb('Focus', ICONS.focus, '', function () { setFocus(v.ref.id); }));
    elBottom.appendChild(bb('More', ICONS.more, '', moreMenu));
  }

  function renderMatches() {
    var hits = $('#hits');
    if (!S.vt.filtering) { S.matches = []; hits.textContent = ''; return; }
    S.matches = S.vt.all.filter(function (v) { return v.matched; }).map(function (v) { return v.id; });
    hits.textContent = S.matches.length ? (Math.max(0, S.matchIx) + 1) + '/' + S.matches.length : '0';
  }

  /* ===================================================================== */
  /* sheets, toasts                                                         */
  /* ===================================================================== */

  function toast(msg) {
    elToast.textContent = msg;
    elToast.classList.add('on');
    clearTimeout(elToast._t);
    elToast._t = setTimeout(function () { elToast.classList.remove('on'); }, 2200);
  }

  function openSheet(title, fill) {
    elSheet.querySelector('.sheet-title').textContent = title;
    var body = elSheet.querySelector('.sheet-body');
    body.textContent = '';
    fill(body);
    elSheet.classList.add('open');
    elScrim.classList.add('open');
  }
  function closeSheet() {
    elSheet.classList.remove('open');
    elScrim.classList.remove('open');
  }

  function menuItem(body, label, sub, icon, cls, fn) {
    var b = document.createElement('button');
    b.className = 'menu-item' + (cls ? ' ' + cls : '');
    b.innerHTML = icon + '<span>' + esc(label) + (sub ? '<span class="sub">' + esc(sub) + '</span>' : '') + '</span>';
    b.onclick = function () { closeSheet(); fn(); };
    body.appendChild(b);
    return b;
  }

  function noteMenu() {
    var doc = selectedDoc();
    if (!doc) return;
    openSheet('Notes', function (body) {
      menuItem(body, 'Import a map here', 'Bring another note\u2019s outline in under this node', ICONS.indent, '', function () { importHere(doc); });
      menuItem(body, 'Attach an existing note', 'Pick a note and hang it off this node', ICONS.note, '', function () { attachExisting(doc); });
      menuItem(body, 'Create a note here', 'A new note titled “' + md.plainText(doc.text).slice(0, 28) + '”', ICONS.child, '', function () { createNoteHere(doc); });
      if (doc.children.length) {
        menuItem(body, 'Promote branch to a note', 'Move this whole branch into its own note', ICONS.open, '', function () { promoteBranch(doc); });
      }
    });
  }

  function moreMenu() {
    var v = selectedView();
    var doc = v && v.ref;
    if (!doc) return;
    openSheet(md.plainText(doc.text).slice(0, 40) || 'Node', function (body) {
      if (doc.kind !== 'root') {
        menuItem(body, 'Move to…', 'Put this branch under a different parent', ICONS.move, '', function () {
          movePicker([doc]);
        });
        menuItem(body, 'Link to…', 'A dashed line to any other node', ICONS.link, '', function () {
          linkPicker(doc);
        });
      }
      menuItem(body, 'Select several nodes', 'Then merge or group them', ICONS.select, '', function () { enterSelect(v.id); });
      if (doc.children.length) {
        menuItem(body, 'Reshape this branch with AI', 'Regroup, or tidy the wording', ICONS.ai, '', function () { aiMenu(doc, null); });
      }
      if (doc.children.length) {
        menuItem(body, v.collapsed ? 'Expand branch' : 'Collapse branch', null, ICONS.more, '', function () {
          if (v.collapsed) delete S.collapsed[doc.id]; else S.collapsed[doc.id] = true;
          syncSidecar(); scheduleSave(); render();
        });
      }
      if (v.hasBody) {
        menuItem(body, 'Show body', 'The paragraphs, code and tables under this node', ICONS.note, '', function () { bodySheet(doc); });
      }
      if (doc.kind === 'item') {
        menuItem(body, doc.checked === null ? 'Make it a task' : 'Remove the checkbox', null, ICONS.task, '', function () {
          apply(doc.checked === null ? edit.setChecked(S.doc, doc, false) : edit.clearChecked(S.doc, doc));
        });
      }
      if (S.pins[doc.id]) {
        menuItem(body, 'Unpin', 'Let it rejoin the automatic layout', ICONS.unpin, '', function () {
          delete S.pins[doc.id]; syncSidecar(); scheduleSave(); render();
        });
      }
      if (doc.kind !== 'root') {
        menuItem(body, 'Delete', doc.children.length ? 'Removes ' + doc.children.length + ' nested item(s) too' : null, ICONS.trash, 'danger', function () {
          removeNode(doc);
        });
      }
    });
  }

  function bodySheet(doc) {
    openSheet(md.plainText(doc.text).slice(0, 40) || 'Body', function (body) {
      var raw = doc.body.map(function (b) { return S.doc.src.slice(b.start, b.end); }).join('\n');
      body.innerHTML = renderBlocks(raw);
    });
  }

  function editNoteSheet(noteId) {
    var cached = S.noteCache[noteId];
    openSheet((cached && cached.title) || 'Note', function (body) {
      var ta = document.createElement('textarea');
      ta.id = 'editor';
      ta.value = (cached && cached.content) || '';
      body.appendChild(ta);
      var row = document.createElement('div');
      row.className = 'btn-row';
      var open = document.createElement('button');
      open.className = 'btn';
      open.textContent = 'Open note';
      open.onclick = function () { closeSheet(); host.openNote(noteId); };
      var savebtn = document.createElement('button');
      savebtn.className = 'btn primary';
      savebtn.textContent = 'Save';
      savebtn.onclick = function () {
        var text = ta.value;
        host.writeContent(noteId, text).then(function () {
          S.noteCache[noteId] = { title: (cached && cached.title) || '', content: text };
          closeSheet(); render(); toast('Note saved');
        }).catch(function (e) { toast(String(e.message || e).slice(0, 120)); });
      };
      row.appendChild(open); row.appendChild(savebtn);
      body.appendChild(row);
    });
  }

  // Small block renderer, only ever used for read-only body previews.
  function renderBlocks(src) {
    var lines = String(src).split('\n');
    var out = [], i = 0;
    function flushPara(buf) { if (buf.length) out.push('<p>' + inlineMd(buf.join(' ')) + '</p>'); }
    var para = [];
    while (i < lines.length) {
      var l = lines[i];
      var fm = /^[ \t]*(`{3,}|~{3,})(.*)$/.exec(l);
      if (fm) {
        flushPara(para); para = [];
        var code = [];
        i++;
        while (i < lines.length && !new RegExp('^[ \\t]*' + fm[1].charAt(0) + '{3,}[ \\t]*$').test(lines[i])) { code.push(lines[i]); i++; }
        i++;
        out.push('<pre>' + esc(code.join('\n')) + '</pre>');
        continue;
      }
      if (/^[ \t]*\|/.test(l)) {
        flushPara(para); para = [];
        var rows = [];
        while (i < lines.length && /^[ \t]*\|/.test(lines[i])) { rows.push(lines[i]); i++; }
        out.push('<table>' + rows.filter(function (r) { return !/^[ \t]*\|[\s:|-]+\|?[\s]*$/.test(r); }).map(function (r, ix) {
          var cells = r.trim().replace(/^\||\|$/g, '').split('|');
          var tag = ix === 0 ? 'th' : 'td';
          return '<tr>' + cells.map(function (c) { return '<' + tag + '>' + inlineMd(c.trim()) + '</' + tag + '>'; }).join('') + '</tr>';
        }).join('') + '</table>');
        continue;
      }
      if (/^[ \t]*>/.test(l)) {
        flushPara(para); para = [];
        var q = [];
        while (i < lines.length && /^[ \t]*>/.test(lines[i])) { q.push(lines[i].replace(/^[ \t]*>[ \t]?/, '')); i++; }
        out.push('<blockquote>' + inlineMd(q.join(' ')) + '</blockquote>');
        continue;
      }
      if (/^[ \t]*$/.test(l)) { flushPara(para); para = []; i++; continue; }
      para.push(l.trim());
      i++;
    }
    flushPara(para);
    return out.join('') || '<p style="opacity:.5">Empty.</p>';
  }

  /* ===================================================================== */
  /* node operations                                                        */
  /* ===================================================================== */

  function indexPath(node) {
    var p = [];
    for (var n = node; n && n.parent; n = n.parent) p.unshift(n.parent.children.indexOf(n));
    return p;
  }
  function nodeAtPath(doc, path) {
    var n = doc.root;
    for (var i = 0; i < path.length; i++) { n = n.children[path[i]]; if (!n) return null; }
    return n;
  }

  // Structural position survives an edit even when the text changed beyond
  // recognition, so selection is carried by path rather than by fingerprint.
  function applyAt(newSrc, path) {
    apply(newSrc);
    var n = path ? nodeAtPath(S.doc, path) : null;
    if (n) { S.selectedId = n.id; render(); }
    return n;
  }

  function addChild(docNode) {
    if (S.collapsed[docNode.id]) delete S.collapsed[docNode.id];
    var path = indexPath(docNode).concat(docNode.children.length);
    var n = applyAt(edit.insertChild(S.doc, docNode, { text: '' }), path);
    if (n) beginEdit(n.id);
  }

  function addSibling(docNode) {
    if (docNode.kind === 'root') return addChild(docNode);
    var path = indexPath(docNode);
    path[path.length - 1] += 1;
    var n = applyAt(edit.insertSibling(S.doc, docNode, { text: '' }), path);
    if (n) beginEdit(n.id);
  }

  function removeNode(docNode) {
    if (docNode.kind === 'root') return;
    var label = md.plainText(docNode.text).slice(0, 24) || 'node';
    S.selectedId = null;
    apply(edit.remove(S.doc, docNode));
    toast('Deleted “' + label + '” — undo in the top bar');
  }

  function doMove(node, newParent, anchor) {
    var why = edit.canMove(node, newParent);
    if (why) return toast(why);
    S.selectedId = node.id;
    var r = edit.move(S.doc, node, newParent, anchor);
    if (r.error) return toast(r.error);
    apply(r.src);
  }

  function indentNode(d) {
    if (!d.parent) return;
    var ix = d.parent.children.indexOf(d);
    if (ix <= 0) return toast('Nothing above to nest under');
    var prev = d.parent.children[ix - 1];
    if (S.collapsed[prev.id]) delete S.collapsed[prev.id];
    doMove(d, prev, null);
  }

  function outdentNode(d) {
    var p = d.parent;
    if (!p || p.kind === 'root') return toast('Already at the top level');
    doMove(d, p.parent, { after: p });
  }

  function nudge(d, dir) {
    if (!d.parent) return;
    var sibs = d.parent.children, ix = sibs.indexOf(d);
    var t = ix + dir;
    if (t < 0) return toast('Already first');
    if (t >= sibs.length) return toast('Already last');
    doMove(d, d.parent, dir > 0 ? { after: sibs[t] } : { before: sibs[t] });
  }

  function toggleCheck(docNode) {
    if (docNode.checked === null) return;
    apply(edit.setChecked(S.doc, docNode, !docNode.checked));
  }

  function setFocus(id) {
    S.focusId = id || null;
    render();
    requestAnimationFrame(function () { fit(true); });
  }

  /* ---- attached notes ---- */

  function noteLinkFor(id, title) {
    return '[' + String(title || 'Note').replace(/[\[\]]/g, '') + '](synapseresource://note/' + id + ')';
  }

  /*
   * The host picker's option is `multiSelect`, not `multiple` - passing the
   * wrong name meant it always opened multi-select and the extra choices were
   * silently dropped. Attaching now takes everything that comes back, in one
   * splice, so N notes are one undo step.
   */
  function attachExisting(docNode) {
    var path = indexPath(docNode);
    host.pickNotes({ title: 'Attach notes' }).then(function (notes) {
      if (!notes.length) return;
      var n = nodeAtPath(S.doc, path) || docNode;
      var r = edit.attachNotes(S.doc, n, notes);
      if (r.error) return toast(r.error);
      applyAt(r.src, path);
      toast(notes.length === 1
        ? 'Attached “' + (notes[0].title || 'note') + '”'
        : 'Attached ' + notes.length + ' notes');
    });
  }

  function createNoteHere(docNode) {
    var title = md.plainText(stripNoteLinks(docNode.text)).slice(0, 80) || 'Untitled';
    var path = indexPath(docNode);
    toast('Creating note…');
    host.createNote({ title: title, content: '', tags: (host.note() || {}).tags || [] })
      .then(function (created) {
        S.noteCache[created.id] = { title: title, content: '' };
        var n = nodeAtPath(S.doc, path);
        if (!n) return toast('Created “' + title + '”');
        applyAt(edit.appendBodyLine(S.doc, n, noteLinkFor(created.id, title)), path);
        toast('Created “' + title + '”');
      })
      .catch(function (e) { toast(String((e && e.message) || e).slice(0, 120)); });
  }

  // Move a whole branch into its own note, leaving a link where it stood.
  function promoteBranch(docNode) {
    var title = md.plainText(stripNoteLinks(docNode.text)).slice(0, 80) || 'Untitled';
    var raw = S.doc.src.slice(docNode.self.end, docNode.outer.end);
    var content = dedentBranch(raw, docNode);
    if (!content.trim()) return toast('This branch has nothing to move');
    var path = indexPath(docNode);
    toast('Creating note…');
    host.createNote({ title: title, content: content, tags: (host.note() || {}).tags || [] })
      .then(function (created) {
        S.noteCache[created.id] = { title: title, content: content };
        var n = nodeAtPath(S.doc, path);
        if (!n) return;
        // Drop the branch, then hang the link off the node it came from.
        var trimmed = edit.applySplices(S.doc.src, [{ start: n.self.end, end: n.outer.end, text: '' }]);
        reparse(trimmed);
        var again = nodeAtPath(S.doc, path);
        if (!again) { apply(trimmed); return; }
        S.undo.push(snapshot());
        applyAt(edit.appendBodyLine(S.doc, again, noteLinkFor(created.id, title)), path);
        toast('Moved the branch into “' + title + '”');
      })
      .catch(function (e) { toast(String((e && e.message) || e).slice(0, 120)); });
  }

  function dedentBranch(raw, docNode) {
    var lines = raw.replace(/\s+$/, '').split('\n');
    if (docNode.kind === 'item') {
      var base = docNode.contentIndent;
      return lines.map(function (l) {
        var ws = /^[ \t]*/.exec(l)[0];
        if (ws.length === l.length) return '';
        var w = Math.max(0, md.indentWidth(ws) - base);
        return new Array(w + 1).join(' ') + l.slice(ws.length);
      }).join('\n');
    }
    var delta = 1 - (docNode.level + 1);
    var fence = null;
    return lines.map(function (l) {
      var fm = /^[ \t]{0,3}(`{3,}|~{3,})/.exec(l);
      if (fm) { fence = fence && fm[1].charAt(0) === fence ? null : (fence || fm[1].charAt(0)); return l; }
      if (fence) return l;
      var m = /^(#{1,6})([ \t]+.*)$/.exec(l);
      if (!m) return l;
      var lvl = Math.max(1, Math.min(6, m[1].length + delta));
      return new Array(lvl + 1).join('#') + m[2];
    }).join('\n');
  }

  function detachNote(v) {
    var docNode = v.ref;
    var r = edit.detachNote(S.doc, docNode, host.sqlId(v.noteId));
    if (r.error) return toast(r.error);
    S.selectedId = docNode.id;
    apply(r.src);
    toast('Detached');
  }

  /* ---- inline text editing ---- */

  function beginEdit(viewId) {
    if (S.embedded) return;
    var v = S.vt.byId[viewId];
    if (!v || v.kind === 'note' || !v.ref) return;
    if (S.mode === 'outline') return beginEditOutline(viewId);
    var el = S.els[viewId];
    if (!el) return;
    S.editingId = viewId;
    S.selectedId = viewId;
    el.className = nodeClasses(v, el._depth || 1);
    var label = el.querySelector('.label');
    label.textContent = v.ref.text;
    label.contentEditable = 'true';
    label.spellcheck = false;
    wireEditor(label, viewId);
    focusAll(label);
    armKeyboardFollow();
  }

  /*
   * The keyboard animates in after focus, and not every WebView fires a
   * visualViewport event when it does. Keyboard animations also vary wildly
   * between Android OEMs, so rather than guess a schedule, re-check until the
   * node has needed no correction for a few ticks running, then stop.
   */
  function armKeyboardFollow() {
    stopKeyboardFollow();
    var ticks = 0, stable = 0;
    keepEditingVisible();
    S._kbTimer = setInterval(function () {
      ticks++;
      if (!S.editingId || ticks > 22) return stopKeyboardFollow();
      stable = keepEditingVisible() ? 0 : stable + 1;
      if (ticks >= 6 && stable >= 3) stopKeyboardFollow();
    }, 90);
  }

  function stopKeyboardFollow() {
    if (S._kbTimer) { clearInterval(S._kbTimer); S._kbTimer = null; }
  }

  function beginEditOutline(viewId) {
    var row = elOlList.querySelector('[data-id="' + viewId + '"]');
    if (!row) return;
    var v = S.vt.byId[viewId];
    S.editingId = viewId;
    var txt = row.querySelector('.ol-txt');
    txt.textContent = v.ref.text;
    txt.contentEditable = 'true';
    txt.spellcheck = false;
    wireEditor(txt, viewId);
    focusAll(txt);
    armKeyboardFollow();
  }

  function wireEditor(node, viewId) {
    node.onkeydown = function (e) {
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); commitEdit(true); }
      else if (e.key === 'Escape') { e.preventDefault(); cancelEdit(); }
      else if (e.key === 'Tab') {
        e.preventDefault();
        var v = S.vt.byId[viewId];
        commitEdit(false);
        var d = S.doc.byId[S.selectedId];
        if (d) (e.shiftKey ? outdentNode : indentNode)(d);
      }
    };
    node.oninput = function () { keepEditingVisible(); };
    node.onblur = function () { if (S.editingId === viewId) commitEdit(false); };
  }

  function focusAll(node) {
    node.focus();
    try {
      var r = document.createRange();
      r.selectNodeContents(node);
      var sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(r);
    } catch (e) { /* older webviews */ }
  }

  // A node that was never given a label is not a node. Abandoning a fresh one
  // (Escape, or tapping away) must not leave an empty bullet in the note.
  function dropIfEmpty(docNode) {
    if (!docNode || docNode.kind === 'root') return false;
    if (docNode.text.trim() || docNode.children.length || docNode.body.length) return false;
    S.selectedId = null;
    apply(edit.remove(S.doc, docNode));
    return true;
  }

  function cancelEdit() {
    var id = S.editingId;
    S.editingId = null;
    stopKeyboardFollow();
    var v = id && S.vt.byId[id];
    if (v && v.ref && dropIfEmpty(v.ref)) return;
    render();
  }

  function commitEdit(thenSibling) {
    var id = S.editingId;
    if (!id) return;
    S.editingId = null;
    stopKeyboardFollow();
    var host_ = S.mode === 'map' ? S.els[id] : elOlList.querySelector('[data-id="' + id + '"]');
    var field = host_ && host_.querySelector(S.mode === 'map' ? '.label' : '.ol-txt');
    var v = S.vt.byId[id];
    if (!field || !v || !v.ref) { render(); return; }
    var text = (field.innerText || '').replace(/[\r\n]+/g, ' ').trim();
    field.contentEditable = 'false';
    field.onkeydown = null;
    field.oninput = null;
    field.onblur = null;
    var d = v.ref;
    var path = indexPath(d);
    if (!text && dropIfEmpty(d)) return;
    if (text !== d.text) {
      var n = applyAt(edit.renameCarryingLinks(S.doc, d, text, CG.view.anchorIndex(S.doc)), path);
      if (thenSibling && n) addSibling(n);
      return;
    }
    render();
    if (thenSibling) {
      var again = nodeAtPath(S.doc, path);
      if (again) addSibling(again);
    }
  }

  /* ===================================================================== */
  /* gestures                                                               */
  /* ===================================================================== */

  var ptrs = new Map();
  var g = null;

  function clamp(v, a, b) { return Math.max(a, Math.min(b, v)); }

  function onDown(e) {
    if (S.mode !== 'map') return;
    ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (ptrs.size === 2) { startPinch(); return; }
    if (ptrs.size > 2) return;

    var linkEl = e.target.closest && e.target.closest('.cg-link');
    if (linkEl) {
      g = { type: 'link', from: linkEl.dataset.linkFrom, to: linkEl.dataset.linkTo };
      return;
    }

    var toggle = e.target.closest && e.target.closest('.cg-toggle');
    if (toggle) { g = { type: 'toggle', id: toggle.dataset.toggle }; return; }

    var link = e.target.closest && e.target.closest('a.anchorref');
    if (link) { g = { type: 'anchor', href: link.dataset.href }; return; }

    var nodeEl = e.target.closest && e.target.closest('.cg-node');
    if (nodeEl && S.editingId === nodeEl.dataset.id) { g = null; return; }
    if (nodeEl) {
      g = {
        type: 'node', id: nodeEl.dataset.id, el: nodeEl,
        x0: e.clientX, y0: e.clientY, moved: false,
        check: !!(e.target.closest && e.target.closest('.cg-check'))
      };
      try { elViewport.setPointerCapture(e.pointerId); } catch (err) {}
      return;
    }
    if (S.editingId) commitEdit(false);
    g = { type: 'pan', x0: e.clientX, y0: e.clientY, tx0: S.tx, ty0: S.ty, t: Date.now() };
  }

  function startPinch() {
    var pts = Array.from(ptrs.values());
    var cx = (pts[0].x + pts[1].x) / 2, cy = (pts[0].y + pts[1].y) / 2;
    var s = screenToStage(cx, cy);
    g = { type: 'pinch', d0: Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y), k0: S.k, sx: s.x, sy: s.y };
  }

  function onMove(e) {
    if (!ptrs.has(e.pointerId)) return;
    ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (!g) return;

    if (g.type === 'pinch') {
      if (ptrs.size < 2) return;
      var pts = Array.from(ptrs.values());
      var d = Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
      var cx = (pts[0].x + pts[1].x) / 2, cy = (pts[0].y + pts[1].y) / 2;
      var r = elViewport.getBoundingClientRect();
      S.userMoved = true;
      S.k = clamp(g.k0 * (d / (g.d0 || 1)), 0.15, 3);
      S.tx = cx - r.left - g.sx * S.k;
      S.ty = cy - r.top - g.sy * S.k;
      elStage.style.transition = 'none';
      applyTransform();
      return;
    }

    if (g.type === 'pan') {
      S.userMoved = true;
      S.tx = g.tx0 + (e.clientX - g.x0);
      S.ty = g.ty0 + (e.clientY - g.y0);
      elStage.style.transition = 'none';
      applyTransform();
      return;
    }

    if (g.type === 'node') {
      if (Math.hypot(e.clientX - g.x0, e.clientY - g.y0) < 9) return;
      var v = S.vt.byId[g.id];
      if (!v || v.kind === 'note' || v.kind === 'ghost' || v.isRoot ||
          (v.ref && v.ref.kind === 'root') || S.embedded || S.selectMode || S.ghost) { g.moved = true; return; }
      var box = S.boxes.get(g.id);
      g.type = 'drag';
      g.moved = true;
      g.box = { x: box.x, y: box.y, w: box.w, h: box.h };
      g.el.classList.add('dragging');
      elTrash.classList.add('open');
      return;
    }

    if (g.type === 'drag') {
      var dx = (e.clientX - g.x0) / S.k, dy = (e.clientY - g.y0) / S.k;
      g.nx = g.box.x + dx; g.ny = g.box.y + dy;
      g.el.style.transform = 'translate(' + g.nx + 'px,' + g.ny + 'px)';
      var tr = elTrash.getBoundingClientRect();
      var overTrash = e.clientX > tr.left && e.clientX < tr.right && e.clientY > tr.top && e.clientY < tr.bottom;
      elTrash.classList.toggle('hot', overTrash);
      var target = overTrash ? null : hitTest(e.clientX, e.clientY, g.id);
      if (g.target && g.target !== target) g.target.classList.remove('droptarget');
      if (target) target.classList.add('droptarget');
      g.target = target;
    }
  }

  function hitTest(x, y, selfId) {
    var prev = g.el.style.pointerEvents;
    g.el.style.pointerEvents = 'none';
    var hit = document.elementFromPoint(x, y);
    g.el.style.pointerEvents = prev;
    var nodeEl = hit && hit.closest && hit.closest('.cg-node');
    if (!nodeEl) return null;
    var v = S.vt.byId[nodeEl.dataset.id];
    if (!v || v.kind === 'note') return null;
    var self = S.doc.byId[selfId];
    var tgt = v.ref;
    if (!self || !tgt || tgt === self || edit.isDescendant(tgt, self)) return null;
    return nodeEl;
  }

  function onUp(e) {
    ptrs.delete(e.pointerId);
    try { elViewport.releasePointerCapture(e.pointerId); } catch (err) {}
    if (!g) return;
    var gg = g;
    if (ptrs.size >= 1 && gg.type === 'pinch') return;
    g = null;

    if (gg.type === 'toggle') {
      var v = S.vt.byId[gg.id];
      if (v && v.ref) {
        if (S.collapsed[v.ref.id]) delete S.collapsed[v.ref.id]; else S.collapsed[v.ref.id] = true;
        syncSidecar(); scheduleSave(); render();
      }
      return;
    }
    if (gg.type === 'link') {
      if (!S.ghost) selectLinkEnds(gg.from, gg.to);
      return;
    }
    if (gg.type === 'anchor') {
      var target = S.vt.anchors[String(gg.href || '').replace(/^#/, '').toLowerCase()];
      if (target) { S.selectedId = target; render(); centerOn(target, true); }
      return;
    }
    if (gg.type === 'pan') {
      if (!gg.moved && Date.now() - gg.t < 250 && Math.hypot(e.clientX - gg.x0, e.clientY - gg.y0) < 6) {
        if (S.lastTap && Date.now() - S.lastTap < 320) { fit(true); S.lastTap = 0; }
        else { S.lastTap = Date.now(); S.selectedId = null; render(); }
      }
      return;
    }
    if (gg.type === 'node') {
      var vv = S.vt.byId[gg.id];
      if (!vv) return;
      if (S.ghost) return;
      if (S.selectMode) {
        if (vv.kind === 'ghost' || !vv.ref || (vv.kind !== 'note' && vv.ref.kind === 'root')) return;
        if (S.multi[gg.id]) delete S.multi[gg.id]; else S.multi[gg.id] = true;
        render();
        return;
      }
      if (gg.check && vv.ref) { toggleCheck(vv.ref); return; }
      if (S.selectedId === gg.id && !S.embedded) { beginEdit(gg.id); return; }
      S.selectedId = gg.id;
      render();
      return;
    }
    if (gg.type === 'drag') {
      gg.el.classList.remove('dragging');
      elTrash.classList.remove('open', 'hot');
      if (gg.target) gg.target.classList.remove('droptarget');
      var node = S.doc.byId[gg.id];
      if (!node) { render(); return; }
      var tr = elTrash.getBoundingClientRect();
      if (e.clientX > tr.left && e.clientX < tr.right && e.clientY > tr.top && e.clientY < tr.bottom) {
        removeNode(node); return;
      }
      if (gg.target) {
        var tv = S.vt.byId[gg.target.dataset.id];
        doMove(node, tv.ref, null);
        return;
      }
      S.pins[node.id] = { x: gg.nx, y: gg.ny + gg.box.h / 2 };
      syncSidecar(); scheduleSave(); render();
      toast('Pinned — drag it onto a node to re-nest, or unpin from More');
    }
  }

  /* ===================================================================== */
  /* multi-select                                                           */
  /* ===================================================================== */

  function enterSelect(seedId) {
    S.selectMode = true;
    S.multi = {};
    if (seedId) S.multi[seedId] = true;
    S.editingId = null;
    render();
    toast('Tap nodes to select. Drag is off while selecting.');
  }

  function exitSelect() {
    S.selectMode = false;
    S.multi = {};
    render();
  }

  function multiDocNodes() {
    var out = [];
    Object.keys(S.multi).forEach(function (id) {
      var v = S.vt.byId[id];
      if (v && v.ref && v.kind !== 'note' && v.kind !== 'ghost') out.push(v.ref);
    });
    return out;
  }

  function multiCardViews() {
    var out = [];
    Object.keys(S.multi).forEach(function (id) {
      var v = S.vt.byId[id];
      if (v && v.kind === 'note' && v.ref) out.push(v);
    });
    return out;
  }

  function cardItems(views) {
    return views.map(function (v) { return { node: v.ref, noteId: v.noteId }; });
  }

  // Lowest common ancestor - the smallest branch that contains every target,
  // and therefore the only part of the note an operation may rewrite.
  function lcaOf(nodes) {
    if (!nodes.length) return null;
    var chains = nodes.map(function (n) {
      var c = [];
      for (var x = n; x; x = x.parent) c.unshift(x);
      return c;
    });
    var lca = chains[0][0];
    for (var i = 0; ; i++) {
      var cand = chains[0][i];
      if (!cand) break;
      var all = chains.every(function (c) { return c[i] === cand; });
      if (!all) break;
      lca = cand;
    }
    // A target cannot also be the scope, or it would be asked to rewrite itself.
    while (lca && nodes.indexOf(lca) >= 0 && lca.parent) lca = lca.parent;
    return lca;
  }

  /* ===================================================================== */
  /* move to a different parent                                             */
  /* ===================================================================== */

  /*
   * Destinations that cannot work are not listed at all, rather than offered
   * and then refused: the node itself, anything inside it, and the parent it is
   * already under. Reordering within a parent is what the up/down buttons are
   * for, so the picker does not try to be that as well.
   */
  function moveTargets(list) {
    var out = [];
    var sharedParent = list.every(function (n) { return n.parent === list[0].parent; })
      ? list[0].parent : null;

    if (sharedParent !== S.doc.root) out.push({ node: S.doc.root, depth: 0, top: true });

    (function walk(n, depth) {
      for (var i = 0; i < n.children.length; i++) {
        var c = n.children[i];
        // Inside something that is moving? Then so is everything below it.
        if (list.some(function (m) { return m === c || edit.isDescendant(c, m); })) continue;
        if (c !== sharedParent) out.push({ node: c, depth: depth });
        walk(c, depth + 1);
      }
    })(S.doc.root, 0);

    return out;
  }

  function movePicker(nodes) {
    var list = (nodes || []).filter(Boolean);
    list = list.filter(function (n) {
      return !list.some(function (o) { return o !== n && edit.isDescendant(n, o); });
    });
    if (!list.length) return toast('Nothing to move');

    var paths = list.map(indexPath);
    var targets = moveTargets(list);
    if (!targets.length) return toast('There is nowhere else for it to go');

    var what = list.length === 1
      ? '“' + (md.plainText(list[0].text).slice(0, 32) || 'this node') + '”'
      : list.length + ' nodes';

    /*
     * When a lone `#` heading is hoisted to be the map's centre, "Top level"
     * means OUTSIDE it - a second centre, which changes the shape of the whole
     * map. Say so, rather than letting it look like the obvious choice sitting
     * above the real one.
     */
    var hoisted = layout.displayRoot(S.doc.root);
    var topLabel = hoisted === S.doc.root
      ? 'Top level'
      : 'Top level — outside “' + (md.plainText(hoisted.text).slice(0, 24) || 'the centre') + '”';

    var rows = targets.map(function (t) {
      return {
        label: t.top ? topLabel : (md.plainText(t.node.text) || 'Untitled'),
        depth: t.depth,
        top: !!t.top,
        hint: list.some(function (m) { return edit.willChangeKind(m, t.node); }) ? 'becomes a bullet' : null,
        pick: function (label) { performMove(paths, t.top ? null : indexPath(t.node), label); }
      };
    });

    nodePickerSheet('Move ' + what + ' to…', 'Find a destination', rows, 'No destination matches that.');
  }

  // Shared by Move to… and Link to…: a searchable, indented list of nodes.
  function nodePickerSheet(title, placeholder, rows, emptyText) {
    openSheet(title, function (body) {
      var q = document.createElement('input');
      q.type = 'search';
      q.id = 'moveq';
      q.placeholder = placeholder;
      q.autocomplete = 'off';
      q.spellcheck = false;
      body.appendChild(q);

      var listEl = document.createElement('div');
      listEl.className = 'move-list';
      body.appendChild(listEl);

      function draw() {
        var needle = q.value.trim().toLowerCase();
        listEl.textContent = '';
        var shown = 0;
        rows.forEach(function (r) {
          if (needle && r.label.toLowerCase().indexOf(needle) < 0) return;
          shown++;
          var row = document.createElement('button');
          row.className = 'move-row' + (r.top ? ' top' : '');
          row.style.paddingLeft = (12 + Math.min(r.depth, 6) * 13) + 'px';
          row.innerHTML = '<span class="mv-label"></span>' +
            (r.hint ? '<span class="mv-hint"></span>' : '');
          row.querySelector('.mv-label').textContent = r.label;
          if (r.hint) row.querySelector('.mv-hint').textContent = r.hint;
          row.onclick = function () { closeSheet(); r.pick(r.label); };
          listEl.appendChild(row);
        });
        if (!shown) {
          var none = document.createElement('div');
          none.className = 'home-empty';
          none.textContent = emptyText;
          listEl.appendChild(none);
        }
      }
      q.addEventListener('input', draw);
      draw();
    });
  }

  /* ===================================================================== */
  /* links between unrelated nodes                                          */
  /* ===================================================================== */

  function linkedPair(idA, idB) {
    var links = (S.vt && S.vt.crossLinks) || [];
    for (var i = 0; i < links.length; i++) {
      var l = links[i];
      if ((l.from === idA && l.to === idB) || (l.from === idB && l.to === idA)) return l;
    }
    return null;
  }

  /*
   * Unlike Move to…, a node's own children and its parent ARE offered: linking
   * to your own child says something, even though moving there cannot.
   */
  function linkPicker(source) {
    var rows = [];
    (function walk(n, depth) {
      for (var i = 0; i < n.children.length; i++) {
        var c = n.children[i];
        var slug = md.slug(c.text);
        if (c !== source && slug && !edit.hasLinkTo(source, slug)) {
          rows.push({
            label: md.plainText(c.text) || 'Untitled',
            depth: depth,
            hint: (CG.view.anchorIndex(S.doc)[slug] || []).length > 1 ? 'name repeats' : null,
            node: c
          });
        }
        walk(c, depth + 1);
      }
    })(S.doc.root, 0);

    if (!rows.length) return toast('There is nothing left to link to');

    var sourcePath = indexPath(source);
    rows.forEach(function (r) {
      var targetPath = indexPath(r.node);
      r.pick = function () { performLink(sourcePath, targetPath); };
    });

    nodePickerSheet('Link “' + (md.plainText(source.text).slice(0, 30) || 'this node') + '” to…',
      'Find a node', rows, 'No node matches that.');
  }

  function performLink(sourcePath, targetPath) {
    var source = nodeAtPath(S.doc, sourcePath);
    var target = nodeAtPath(S.doc, targetPath);
    if (!source || !target) return toast('One of those nodes moved on before this could run');

    var r = edit.addLink(S.doc, source, target);
    if (r.error) return toast(r.error);

    S.selectedId = source.id;
    S.selectMode = false;
    S.multi = {};
    apply(r.src);

    var twins = (CG.view.anchorIndex(S.doc)[r.slug] || []).length;
    toast(twins > 1
      ? 'Linked — but “' + md.plainText(target.text).slice(0, 24) + '” is not a unique name, so the line points at the nearest one'
      : 'Linked to “' + md.plainText(target.text).slice(0, 24) + '”');
  }

  /*
   * When a card is in the pair it is the source, because a card's links live on
   * its own line. Two cards use the earlier one; two nodes take the node path.
   */
  function linkSelected() {
    var views = Object.keys(S.multi).map(function (id) { return S.vt.byId[id]; }).filter(Boolean);
    if (views.length !== 2) return toast('Select exactly two things to link them');
    views.sort(function (a, b) { return docPos(a) - docPos(b); });

    var cards = views.filter(function (v) { return v.kind === 'note'; });
    if (!cards.length) {
      performLink(indexPath(views[0].ref), indexPath(views[1].ref));
      return;
    }
    var source = cards[0];
    var other = views[0] === source ? views[1] : views[0];
    if (other.kind === 'note') {
      performCardLink(source, { kind: 'card', noteId: other.noteId, title: other.noteTitle });
    } else {
      performCardLink(source, { kind: 'node', path: indexPath(other.ref) });
    }
  }

  function unlinkSelected() {
    var ids = Object.keys(S.multi);
    var pair = ids.length === 2 && linkedPair(ids[0], ids[1]);
    if (!pair) return toast('Those two are not linked');

    var r;
    if (pair.fromCard) {
      var fv = S.vt.byId[pair.from];
      if (!fv || !fv.ref) return toast('That link has gone');
      var pattern = pair.noteId
        ? 'synapseresource://note/' + edit.escapeRe(pair.noteId) + '[^)]*'
        : '#' + edit.escapeRe(pair.slug);
      r = edit.removeCardLink(S.doc, fv.ref, fv.noteId, pattern);
    } else {
      var source = S.doc.byId[pair.from];
      if (!source) return toast('That link has gone');
      r = edit.removeLink(S.doc, source, pair.slug);
    }
    if (r.error) return toast(r.error);
    S.selectMode = false;
    S.multi = {};
    S.selectedId = null;
    apply(r.src);
    toast('Unlinked — undo in the top bar');
  }

  // Tapping a link is how you act on it: both ends selected means merge, group
  // and move are immediately available.
  function selectLinkEnds(fromId, toId) {
    if (!S.vt.byId[fromId] || !S.vt.byId[toId]) return;
    S.selectMode = true;
    S.multi = {};
    S.multi[fromId] = true;
    S.multi[toId] = true;
    S.selectedId = null;
    render();
    requestAnimationFrame(function () { frameIds([fromId, toId], true); });
    toast('Both ends selected');
  }

  function frameIds(ids, animate) {
    if (!S.boxes) return;
    var b = null;
    ids.forEach(function (id) {
      var bx = S.boxes.get(id);
      if (!bx) return;
      if (!b) b = { x0: bx.x, y0: bx.y, x1: bx.x + bx.w, y1: bx.y + bx.h };
      else {
        b.x0 = Math.min(b.x0, bx.x); b.y0 = Math.min(b.y0, bx.y);
        b.x1 = Math.max(b.x1, bx.x + bx.w); b.y1 = Math.max(b.y1, bx.y + bx.h);
      }
    });
    if (!b) return;
    var pad = 40;
    var vis = visibleRect();
    var w = Math.max(1, b.x1 - b.x0), h = Math.max(1, b.y1 - b.y0);
    S.k = clamp(Math.min((vis.width - pad * 2) / w, (vis.height - pad * 2) / h, 1.2), 0.15, 3);
    S.tx = (vis.left + vis.right) / 2 - vis.originLeft - (b.x0 + w / 2) * S.k;
    S.ty = (vis.top + vis.bottom) / 2 - vis.originTop - (b.y0 + h / 2) * S.k;
    S.userMoved = true;
    elStage.style.transition = animate ? 'transform .3s cubic-bezier(.22,.61,.36,1)' : 'none';
    applyTransform();
    if (animate) setTimeout(function () { elStage.style.transition = 'none'; }, 320);
  }

  function performMove(paths, targetPath, label) {
    var nodes = paths.map(function (p) { return nodeAtPath(S.doc, p); }).filter(Boolean);
    var target = targetPath ? nodeAtPath(S.doc, targetPath) : S.doc.root;
    if (!nodes.length || !target) return toast('That node moved on before this could run');

    var r = edit.moveMany(S.doc, nodes, target);
    if (r.error) return toast(r.error);

    // Carry the destination across the re-parse, so the moved nodes can be
    // found again as its last children.
    S.selectedId = target.kind === 'root' ? null : target.id;
    S.selectMode = false;
    S.multi = {};
    apply(r.src);

    var landed = target.kind === 'root'
      ? S.doc.root
      : (S.selectedId ? S.doc.byId[S.selectedId] : null);
    var first = landed && landed.children.length
      ? landed.children[landed.children.length - r.moved]
      : null;
    if (first) {
      S.selectedId = first.id;
      if (S.collapsed[first.id]) delete S.collapsed[first.id];
      render();
      requestAnimationFrame(function () { fitBranch(first.id, true); });
    }
    toast('Moved to “' + label + '” — undo in the top bar');
  }

  /* ===================================================================== */
  /* attached notes: moving and linking                                     */
  /* ===================================================================== */

  function cardLabel(views) {
    return views.length === 1
      ? '“' + (views[0].noteTitle || 'note').slice(0, 28) + '”'
      : views.length + ' notes';
  }

  // Where a view sits in the document, for putting a pair in order.
  function docPos(v) {
    if (!v) return 0;
    if (v.kind === 'note') return v.lineStart >= 0 ? v.lineStart : (v.ref ? v.ref.outer.start : 0);
    return v.ref ? v.ref.outer.start : 0;
  }

  function nodeRows(skip) {
    var rows = [];
    (function walk(n, depth) {
      for (var i = 0; i < n.children.length; i++) {
        var c = n.children[i];
        if (!skip || !skip(c)) {
          rows.push({ label: md.plainText(c.text) || 'Untitled', depth: depth, node: c });
        }
        walk(c, depth + 1);
      }
    })(S.doc.root, 0);
    return rows;
  }

  /*
   * A card attaches to a node, so the root is not offered: a link line at the
   * very end of the note belongs to nothing.
   */
  function moveCardsPicker(cards) {
    var owners = cards.map(function (v) { return v.ref; });
    var shared = owners.every(function (o) { return o === owners[0]; }) ? owners[0] : null;
    var items = cards.map(function (v) { return { path: indexPath(v.ref), noteId: v.noteId }; });

    var rows = nodeRows(function (c) { return c === shared; });
    if (!rows.length) return toast('There is nowhere else to put it');
    rows.forEach(function (r) {
      var targetPath = indexPath(r.node);
      r.pick = function (label) { performCardMove(items, targetPath, label); };
    });
    nodePickerSheet('Move ' + cardLabel(cards) + ' to…', 'Find a node', rows,
      'No node matches that.');
  }

  function performCardMove(items, targetPath, label) {
    var target = nodeAtPath(S.doc, targetPath);
    var resolved = items.map(function (it) {
      return { node: nodeAtPath(S.doc, it.path), noteId: it.noteId };
    }).filter(function (x) { return x.node; });
    if (!target || !resolved.length) return toast('That note moved on before this could run');

    var r = edit.moveAttachments(S.doc, resolved, target);
    if (r.error) return toast(r.error);

    S.selectedId = target.id;
    S.selectMode = false;
    S.multi = {};
    apply(r.src);

    var landed = S.selectedId ? S.doc.byId[S.selectedId] : null;
    if (landed) {
      var cardId = 'note:' + landed.id + ':' + resolved[0].noteId;
      if (S.vt.byId[cardId]) {
        S.selectedId = cardId;
        render();
        requestAnimationFrame(function () { fitBranch(cardId, true); });
      }
    }
    toast('Moved to “' + label + '”');
  }

  function cardLinkPicker(card) {
    var already = {};
    (card.outLinks || []).forEach(function (l) {
      already[l.type === 'note' ? 'note:' + l.noteId : 'slug:' + l.target.replace(/^#/, '').toLowerCase()] = true;
    });

    var rows = nodeRows(function (c) {
      var slug = md.slug(c.text);
      return !slug || already['slug:' + slug];
    });
    rows.forEach(function (r) {
      var targetPath = indexPath(r.node);
      r.pick = function () { performCardLink(card, { kind: 'node', path: targetPath }); };
    });

    // Other attached notes are targets too - that is a card-to-card link.
    S.vt.all.forEach(function (v) {
      if (v.kind !== 'note' || v.noteId === card.noteId || already['note:' + v.noteId]) return;
      rows.push({
        label: v.noteTitle || 'Note', depth: 0, hint: 'attached note',
        pick: function () {
          performCardLink(card, { kind: 'card', noteId: v.noteId, title: v.noteTitle });
        }
      });
    });

    if (!rows.length) return toast('There is nothing left to link to');
    nodePickerSheet('Link “' + (card.noteTitle || 'note').slice(0, 26) + '” to…',
      'Find a node or note', rows, 'Nothing matches that.');
  }

  function performCardLink(card, target) {
    var sourcePath = indexPath(card.ref);
    var noteId = card.noteId;
    var linkMd;
    if (target.kind === 'node') {
      var t = nodeAtPath(S.doc, target.path);
      if (!t) return toast('That node moved on before this could run');
      linkMd = '[' + edit.linkLabel(t) + '](#' + md.slug(t.text) + ')';
    } else {
      linkMd = '[\u2192 ' + String(target.title || 'Note').replace(/[\[\]]/g, '') +
        '](synapseresource://note/' + host.sqlId(target.noteId) + ')';
    }
    var source = nodeAtPath(S.doc, sourcePath);
    if (!source) return toast('That note moved on before this could run');

    var r = edit.addCardLink(S.doc, source, noteId, linkMd);
    if (r.error) return toast(r.error);
    S.selectedId = source.id;
    S.selectMode = false;
    S.multi = {};
    apply(r.src);
    toast('Linked');
  }

  /* ===================================================================== */
  /* AI refactor                                                            */
  /* ===================================================================== */

  function aiMenu(scopeDoc, targets) {
    openSheet('Reshape with AI', function (body) {
      menuItem(body, 'Regroup this branch', 'Let related items find each other', ICONS.group, '', function () {
        runRefactor('regroup', scopeDoc, []);
      });
      menuItem(body, 'Tidy the labels', 'Consistent wording, same structure', ICONS.ai, '', function () {
        runRefactor('tidy', scopeDoc, []);
      });
      if (targets && targets.length) {
        menuItem(body, 'Merge the selected nodes', null, ICONS.merge, '', function () {
          runRefactor('merge', scopeDoc, targets);
        });
      }
    });
  }

  function runOp(op) {
    var targets = multiDocNodes();
    var need = op === 'split' ? 1 : 2;
    if (targets.length < need) return toast('Select at least ' + need + ' node' + (need > 1 ? 's' : '') + ' first');
    var scope = lcaOf(targets);
    if (!scope) return toast('Those nodes have nothing in common to work within');
    runRefactor(op, scope, targets);
  }

  function countBodies(node) {
    var n = 0;
    (function walk(x) { n += x.body.length; for (var i = 0; i < x.children.length; i++) walk(x.children[i]); })(node);
    return n;
  }

  function runRefactor(op, scope, targets) {
    if (!scope.children.length) return toast('There is nothing inside this branch to reshape');
    var branch = S.doc.src.slice(scope.self.end, scope.outer.end);
    var prompt = CG.ai.refactorPrompt(
      op,
      md.plainText(scope.text) || S.title,
      dedentBranch(branch, scope),
      (targets || []).map(function (n) { return md.plainText(n.text); })
    );
    if (!prompt) return toast('Unknown operation');

    var scopePath = indexPath(scope);
    busy(CG.ai.OPS[op].label + '…');
    host.ai(prompt).then(function (text) {
      var body = CG.ai.strip(text);
      if (!body) throw new Error('the AI did not return an outline');
      var fdoc = md.parse(body);
      if (!fdoc.root.children.length) throw new Error('the AI did not return an outline');
      var block = edit.reshape(fdoc, fdoc.root.children, scope);
      if (!block.trim()) throw new Error('the AI returned nothing usable');
      var proposed = edit.applySplices(S.doc.src, [
        { start: scope.self.end, end: scope.outer.end, text: block + '\n' }
      ]);
      buildGhost(proposed, scopePath, scope, op);
      busy(null);
      render();
      var shown = nodeAtPath(S.ghost.doc, scopePath);
      requestAnimationFrame(function () { fitBranch(shown ? shown.id : S.vt.root.id, true); });
    }).catch(function (e) {
      busy(null);
      toast(String((e && e.message) || e).slice(0, 140));
    });
  }

  function buildGhost(proposedSrc, scopePath, scopeNode, op) {
    var doc = md.parse(proposedSrc, { title: S.title });
    var newScope = nodeAtPath(doc, scopePath) || doc.root;
    var cls = CG.diff.classify(scopeNode, newScope);
    var lost = countBodies(scopeNode) - countBodies(newScope);
    var headline = CG.diff.describe(cls.summary);
    if (lost > 0) headline += ' · ' + lost + ' block' + (lost > 1 ? 's' : '') + ' of text dropped';
    S.ghost = {
      doc: doc, src: proposedSrc, cls: cls, op: op,
      scopePath: scopePath, headline: headline, lost: lost,
      nothing: cls.summary.touched === 0 && lost === 0
    };
  }

  /*
   * Nodes the proposal drops do not exist in the proposed tree, so they are
   * grafted onto the VIEW as ghosts - hung off whichever node absorbed them, or
   * off their old parent's replacement - purely so you can see what would go.
   */
  function injectGhostNodes() {
    var cls = S.ghost.cls;
    Object.keys(cls.byOld).forEach(function (oldId) {
      var e = cls.byOld[oldId];
      if (e.state !== 'removed' && e.state !== 'merged') return;
      var anchorId = null;
      if (e.state === 'merged' && e.into) anchorId = e.into.id;
      if (!anchorId) {
        var op = e.from.parent;
        var pe = op && cls.byOld[op.id];
        if (pe && pe.to) anchorId = pe.to.id;
      }
      var anchor = S.vt.byId[anchorId] || S.vt.root;
      if (!anchor) return;
      var g = {
        id: 'ghost:' + oldId, kind: 'ghost', ghostState: e.state, text: e.from.text,
        ref: null, noteId: null, noteTitle: '', notePreview: '', level: 0, checked: null,
        children: [], parent: anchor, hasBody: false, bodyTypes: [], taskDone: 0, taskTotal: 0,
        matched: false, keep: true, tags: [], links: [], collapsed: false, hiddenCount: 0
      };
      anchor.children.push(g);
      S.vt.byId[g.id] = g;
      S.vt.all.push(g);
    });
  }

  function applyGhost() {
    var g = S.ghost;
    if (!g) return;
    S.ghost = null;
    S.selectMode = false;
    S.multi = {};
    S.selectedId = null;
    apply(g.src);
    toast(CG.ai.OPS[g.op].label + ' applied — undo in the top bar');
  }

  function discardGhost() {
    S.ghost = null;
    render();
    requestAnimationFrame(function () { fit(true); });
  }

  /* ===================================================================== */
  /* import                                                                 */
  /* ===================================================================== */

  function importHere(target) {
    var path = indexPath(target);
    host.pickNotes({ multiSelect: false }).then(function (notes) {
      if (!notes.length) return;
      var picked = notes[0];
      return host.readNotes([picked.id]).then(function (rows) {
        if (!rows.length) return toast('Could not read that note');
        var source = rows[0];
        openSheet('Import “' + (source.title || 'note') + '”', function (body) {
          var p = document.createElement('p');
          p.textContent = 'Bring its outline in under “' +
            (md.plainText(target.text).slice(0, 40) || 'this node') + '”.';
          body.appendChild(p);
          menuItem(body, 'Copy it in', 'Its headings and bullets become part of this note', ICONS.indent, '', function () {
            var node = nodeAtPath(S.doc, path) || target;
            var r = edit.graft(S.doc, node, stripSidecar(source.content));
            if (r.error) return toast(r.error);
            var landed = applyAt(r.src, path);
            if (landed) requestAnimationFrame(function () { fitBranch(landed.id, true); });
            toast('Imported “' + (source.title || 'note') + '”');
          });
          menuItem(body, 'Link to it instead', 'A card that opens the note, kept in sync', ICONS.note, '', function () {
            var node = nodeAtPath(S.doc, path) || target;
            applyAt(edit.appendBodyLine(S.doc, node, noteLinkFor(source.id, source.title)), path);
            toast('Linked “' + (source.title || 'note') + '”');
          });
        });
      });
    });
  }

  function stripSidecar(content) {
    var d = md.parse(String(content == null ? '' : content));
    return edit.writeSidecar(d, null);
  }

  /* ===================================================================== */
  /* AI generation                                                          */
  /* ===================================================================== */

  function busy(label) {
    var t = $('#status');
    if (!t) return;
    if (label) { t.textContent = label; t.classList.add('busy'); }
    else { t.classList.remove('busy'); setStatus(S.saveState); }
  }

  /*
   * Map the WHOLE note: its markdown and every file attached to it. A note that
   * is only a PDF has nothing in `content`, and is still very much a note. The
   * attachments are looked up here (the caller may pre-supply them) so every
   * entry point - the ✦ button, the launch chooser, the standalone home - gets
   * the same treatment.
   */
  function generateFor(source, onDone) {
    var content = stripSidecar(source.content || '');
    busy('Reading the note…');
    var lookup = Array.isArray(source.attachments)
      ? Promise.resolve(source.attachments)
      : host.attachmentsOf(source.id).catch(function () { return []; });

    lookup.then(function (atts) {
      atts = atts || [];
      if (!content.trim() && !atts.length) {
        busy(null);
        toast('That note is empty: no text and no attachments');
        return;
      }
      var calls = CG.ai.planCalls(content, atts);
      var truncated = calls.some(function (c) { return c.truncated; });
      var label = function (i) { return calls.length > 1 ? 'Mapping ' + (i + 1) + '/' + calls.length + '…' : 'Mapping…'; };
      busy(label(0));

      var parts = [];
      var chain = Promise.resolve();
      calls.forEach(function (call, i) {
        chain = chain.then(function () {
          busy(label(i));
          var prompt = CG.ai.generatePrompt(source.title, call.text, {
            section: calls.length > 1,
            attachments: call.attachments.map(function (a) { return a.fileName; })
          });
          var opts = call.attachments.length
            ? { attachments: call.attachments.map(function (a) { return a.path; }) }
            : undefined;
          return host.ai(prompt, opts).then(function (t) { parts.push(t); });
        });
      });

      return chain.then(function () {
        var outline = calls.length > 1
          ? CG.ai.joinSections(parts, source.title)
          : CG.ai.sanitizeOutline(parts[0], source.title);
        busy(null);
        if (!outline.trim()) throw new Error('the AI did not return an outline');
        previewGenerated(source, outline, { calls: calls.length, truncated: truncated, attachments: atts.length }, onDone);
      });
    }).catch(function (e) {
      busy(null);
      toast(String((e && e.message) || e).slice(0, 140));
    });
  }

  function outlineHtml(markdown) {
    var d = md.parse(markdown);
    var out = [];
    (function walk(n, depth) {
      for (var i = 0; i < n.children.length; i++) {
        var c = n.children[i];
        out.push('<div class="pv-row d' + Math.min(depth, 5) + (c.kind === 'heading' ? ' h' : '') + '">' +
          inlineMd(c.text) + '</div>');
        walk(c, depth + 1);
      }
    })(d.root, 0);
    return out.join('') || '<p style="opacity:.6">Nothing came back.</p>';
  }

  function previewGenerated(source, outline, info, onDone) {
    info = info || {};
    openSheet('Map of “' + (source.title || 'note') + '”', function (body) {
      var meta = document.createElement('p');
      var count = md.parse(outline).nodes.length - 1;
      meta.style.color = 'var(--muted)';
      meta.style.fontSize = '12.5px';
      meta.textContent = count + ' nodes' +
        (info.calls > 1 ? ' · built from ' + info.calls + ' parts' : '') +
        (info.attachments ? ' · read ' + info.attachments + ' attached file' + (info.attachments === 1 ? '' : 's') : '') +
        (info.truncated ? ' · the note was long and was trimmed' : '');
      body.appendChild(meta);

      var pv = document.createElement('div');
      pv.className = 'preview';
      pv.innerHTML = outlineHtml(outline);
      body.appendChild(pv);

      var row = document.createElement('div');
      row.className = 'btn-row';
      var again = document.createElement('button');
      again.className = 'btn';
      again.textContent = 'Try again';
      again.onclick = function () { closeSheet(); generateFor(source, onDone); };
      var save = document.createElement('button');
      save.className = 'btn primary';
      save.textContent = 'Save map';
      save.onclick = function () { closeSheet(); saveGenerated(source, outline, onDone); };
      row.appendChild(again);
      row.appendChild(save);
      body.appendChild(row);
    });
  }

  function saveGenerated(source, outline, onDone) {
    var existing = host.mapIdIn(source.content || '');
    busy('Saving…');
    var done = function (mapId, replaced) {
      busy(null);
      rememberMap(mapId, (source.title || 'Note') + ' — map');
      toast(replaced ? 'Map updated' : 'Map saved');
      if (onDone) onDone(mapId);
    };

    if (existing) {
      host.writeContent(existing, outline)
        .then(function () { done(existing, true); })
        .catch(function (e) { busy(null); toast(String(e.message || e).slice(0, 140)); });
      return;
    }

    host.createNote({ title: (source.title || 'Note') + ' — map', content: outline, tags: source.tags || [] })
      .then(function (created) {
        S.noteCache[created.id] = { title: created.title, content: outline };
        var link = host.mapLink(created.id, created.title);
        // The source note is the one being mapped; when it is also the note on
        // screen the link goes through the undo stack like any other edit.
        if (S.doc && source.id === S.noteId) {
          apply(edit.appendBodyLine(S.doc, S.doc.root, link));
          done(created.id, false);
        } else {
          var next = String(source.content || '').replace(/\s+$/, '');
          host.writeContent(source.id, next + (next ? '\n\n' : '') + link)
            .then(function () { done(created.id, false); })
            .catch(function () { done(created.id, false); });
        }
      })
      .catch(function (e) { busy(null); toast(String((e && e.message) || e).slice(0, 140)); });
  }

  function currentSource() {
    return { id: S.noteId, title: S.title, content: S.src, tags: (host.note() || {}).tags || [] };
  }

  /*
   * A note_action launch used to open the note as a map without asking, which
   * is only ever useful for a note with headings or bullets in it. Now the
   * reader is asked what they came for: read the note as it is written, open
   * the map it already has, or have AI build one from the whole note -
   * attachments included, so a note that is nothing but a PDF still works.
   * Dismissing the sheet is the same as choosing the first option: the map
   * behind it is already drawn, and nothing has been written.
   */
  function launchChooser() {
    var existing = host.mapIdIn(S.src);
    var what = S.isBlockScope ? 'block' : 'note';
    openSheet(S.title || 'Cartograph', function (body) {
      menuItem(body, 'Map this ' + what + ' as written',
        'Headings and bullets become branches. Nothing is written until you change something.',
        ICONS.map, '', function () {});
      if (existing) {
        menuItem(body, 'Open the existing map', 'This ' + what + ' already links to a map note',
          ICONS.open, '', function () { openMap(existing); });
      }
      menuItem(body, existing ? 'Regenerate the map with AI' : 'Generate a map with AI',
        existing
          ? 'Reads the whole ' + what + ', attachments included, and replaces the existing map note'
          : 'Reads the whole ' + what + ', attachments included, into a new companion note',
        ICONS.ai, '', function () { generateFor(currentSource(), offerOpen); });
    });
  }

  function generateForCurrentNote() {
    var existing = host.mapIdIn(S.src);
    var source = currentSource();
    if (!existing) return generateFor(source, offerOpen);
    openSheet('This note already has a map', function (body) {
      var p = document.createElement('p');
      p.textContent = 'Regenerating replaces the contents of the existing map note. No second map is created.';
      body.appendChild(p);
      menuItem(body, 'Open the existing map', null, ICONS.map, '', function () { openMap(existing); });
      menuItem(body, 'Regenerate it', 'Replaces what is in the map note now', ICONS.ai, '', function () {
        generateFor(source, offerOpen);
      });
    });
  }

  function offerOpen(mapId) {
    openSheet('Map saved', function (body) {
      var p = document.createElement('p');
      p.textContent = 'The map is a note of its own. This note now links to it.';
      body.appendChild(p);
      menuItem(body, 'Open the map', null, ICONS.map, '', function () { openMap(mapId); });
    });
  }

  function openMap(id) {
    if (S.standalone) return openMapNote(id);
    host.openNote(id);
  }

  /* ===================================================================== */
  /* standalone home                                                        */
  /* ===================================================================== */

  function rememberMap(id, title) {
    if (!S.standalone) return;
    S.recents = [{ id: id, title: title }].concat(
      (S.recents || []).filter(function (r) { return r.id !== id; })
    ).slice(0, 12);
    host.storeState({ recents: S.recents });
  }

  function goHome() {
    S.home = { loading: true, maps: [] };
    S.ghost = null;
    S.selectMode = false;
    S.multi = {};
    S.editingId = null;
    render();
    host.findMaps().then(function (maps) {
      S.home = { loading: false, maps: maps };
      render();
    }).catch(function () {
      S.home = { loading: false, maps: [] };
      render();
    });
  }

  function loadNote(id) {
    return host.readNotes([id]).then(function (rows) {
      if (!rows.length) throw new Error('that note could not be read');
      var row = rows[0];
      S.noteId = row.id;
      S.title = row.title || 'Note';
      S.isBlockScope = false;
      S.baseline = row.content || '';
      S.pins = {};
      S.collapsed = {};
      S.selectedId = null;
      S.focusId = null;
      S.undo = [];
      S.redo = [];
      S.doc = null;
      reparse(S.baseline);
      sidecar.apply(S.doc, S);
      fetchLinkedNotes();
      return row;
    });
  }

  function openMapNote(id) {
    busy('Opening…');
    loadNote(id).then(function (row) {
      busy(null);
      S.home = null;
      rememberMap(row.id, row.title);
      S.userMoved = false;
      render();
      requestAnimationFrame(function () { fit(false); setStatus(''); });
    }).catch(function (e) {
      busy(null);
      toast(String((e && e.message) || e).slice(0, 140));
    });
  }

  function homeRow(icon, title, sub, onTap) {
    var b = document.createElement('button');
    b.className = 'home-row';
    b.innerHTML = icon + '<span class="hr-text"><span class="hr-title"></span>' +
      (sub ? '<span class="hr-sub"></span>' : '') + '</span>';
    b.querySelector('.hr-title').textContent = title;
    if (sub) b.querySelector('.hr-sub').textContent = sub;
    b.onclick = onTap;
    return b;
  }

  function section(parent, label) {
    var h = document.createElement('div');
    h.className = 'home-head';
    h.textContent = label;
    parent.appendChild(h);
  }

  function renderHome() {
    elBottom.classList.remove('open');
    elCrumbs.textContent = '';
    var c = document.createElement('span');
    c.className = 'crumb last';
    c.textContent = 'Cartograph';
    elCrumbs.appendChild(c);
    $('#btnFocusOut').hidden = true;
    $('#btnUndo').disabled = true;

    var el = $('#home');
    el.classList.add('on');
    el.textContent = '';

    var lead = document.createElement('button');
    lead.className = 'home-cta';
    lead.innerHTML = ICONS.ai + '<span>Generate a map from a note…</span>';
    lead.onclick = function () {
      host.pickNotes({ multiSelect: false }).then(function (notes) {
        if (!notes.length) return;
        host.readNotes([notes[0].id]).then(function (rows) {
          if (!rows.length) return toast('Could not read that note');
          generateFor(rows[0], function (mapId) { openMapNote(mapId); });
        });
      });
    };
    el.appendChild(lead);

    if (S.recents && S.recents.length) {
      section(el, 'Recent');
      S.recents.forEach(function (r) {
        el.appendChild(homeRow(ICONS.map, r.title || 'Map', null, function () { openMapNote(r.id); }));
      });
    }

    section(el, S.home.loading ? 'Maps — looking…' : 'Maps');
    if (!S.home.loading && !S.home.maps.length) {
      var empty = document.createElement('div');
      empty.className = 'home-empty';
      empty.textContent = 'No maps yet. Generate one above, or open any note as a map.';
      el.appendChild(empty);
    }
    S.home.maps.forEach(function (m) {
      el.appendChild(homeRow(ICONS.map, m.title || 'Map', 'from ' + (m.sourceTitle || 'a note'), function () {
        openMapNote(m.id);
      }));
    });

    section(el, 'Any note');
    el.appendChild(homeRow(ICONS.note, 'Open a note as a map…', 'Nothing is written until you change something', function () {
      host.pickNotes({ multiSelect: false }).then(function (notes) {
        if (notes.length) openMapNote(notes[0].id);
      });
    }));
  }

  /* ===================================================================== */
  /* search                                                                 */
  /* ===================================================================== */

  function renderFilterChips() {
    var wrap = $('#filterChips');
    wrap.textContent = '';
    var tags = {};
    S.doc.nodes.forEach(function (n) { view.tagsIn(n.text).forEach(function (t) { tags[t] = true; }); });

    function chip(label, on, fn) {
      var b = document.createElement('button');
      b.className = 'chip' + (on ? ' on' : '');
      b.textContent = label;
      b.onclick = fn;
      wrap.appendChild(b);
    }
    chip('To do', S.filters.status === 'todo', function () {
      S.filters.status = S.filters.status === 'todo' ? null : 'todo'; S.matchIx = -1; render();
    });
    chip('Done', S.filters.status === 'done', function () {
      S.filters.status = S.filters.status === 'done' ? null : 'done'; S.matchIx = -1; render();
    });
    chip('Has note', !!S.filters.hasNote, function () {
      S.filters.hasNote = !S.filters.hasNote; S.matchIx = -1; render();
    });
    Object.keys(tags).sort().forEach(function (t) {
      chip('#' + t, S.filters.tag === t, function () {
        S.filters.tag = S.filters.tag === t ? null : t; S.matchIx = -1; render();
      });
    });
  }

  function stepMatch(dir) {
    if (!S.matches.length) return;
    S.matchIx = (S.matchIx + dir + S.matches.length) % S.matches.length;
    var id = S.matches[S.matchIx];
    S.selectedId = id;
    render();
    if (S.mode === 'map') centerOn(id, true);
    else {
      var row = elOlList.querySelector('[data-id="' + id + '"]');
      if (row) row.scrollIntoView({ block: 'center', behavior: 'smooth' });
    }
  }

  /* ===================================================================== */
  /* wiring                                                                 */
  /* ===================================================================== */

  function wire() {
    elViewport.addEventListener('pointerdown', onDown);
    elViewport.addEventListener('pointermove', onMove);
    elViewport.addEventListener('pointerup', onUp);
    elViewport.addEventListener('pointercancel', onUp);
    elViewport.addEventListener('wheel', function (e) {
      if (S.mode !== 'map') return;
      e.preventDefault();
      var r = elViewport.getBoundingClientRect();
      var s = screenToStage(e.clientX, e.clientY);
      S.userMoved = true;
      S.k = clamp(S.k * (e.deltaY < 0 ? 1.12 : 0.89), 0.15, 3);
      S.tx = e.clientX - r.left - s.x * S.k;
      S.ty = e.clientY - r.top - s.y * S.k;
      elStage.style.transition = 'none';
      applyTransform();
    }, { passive: false });

    elOlList.addEventListener('click', function (e) {
      var chk = e.target.closest('.cg-check');
      if (chk) {
        var cv = S.vt.byId[chk.dataset.check];
        if (cv && cv.ref) toggleCheck(cv.ref);
        return;
      }
      var row = e.target.closest('.ol-row');
      if (!row) return;
      var id = row.dataset.id;
      var v = S.vt.byId[id];
      if (v && v.kind === 'note') { host.openNote(v.noteId); return; }
      if (S.editingId === id) return;
      if (S.selectedId === id) { beginEditOutline(id); return; }
      S.selectedId = id;
      render();
    });

    document.querySelectorAll('#viewToggle button').forEach(function (b) {
      b.onclick = function () {
        if (S.editingId) commitEdit(false);
        S.mode = b.dataset.mode;
        document.querySelectorAll('#viewToggle button').forEach(function (x) { x.classList.toggle('on', x === b); });
        elOutline.classList.toggle('on', S.mode === 'outline');
        elStage.style.visibility = S.mode === 'map' ? '' : 'hidden';
        render();
        if (S.mode === 'map') requestAnimationFrame(function () { fit(false); });
      };
    });

    $('#btnSearch').onclick = function () {
      var bar = $('#searchbar');
      var open = bar.classList.toggle('open');
      $('#btnSearch').classList.toggle('on', open);
      if (open) { renderFilterChips(); $('#q').focus(); }
      else { S.query = ''; S.filters = {}; $('#q').value = ''; S.matchIx = -1; render(); }
    };
    $('#btnCloseSearch').onclick = function () { $('#btnSearch').onclick(); };
    $('#q').addEventListener('input', function () {
      S.query = this.value;
      S.matchIx = -1;
      render();
      if (S.matches.length) stepMatch(1);
    });
    $('#btnNext').onclick = function () { stepMatch(1); };
    $('#btnPrev').onclick = function () { stepMatch(-1); };
    $('#btnUndo').onclick = undo;
    $('#btnFit').onclick = function () {
      if (S.mode !== 'map') { elOutline.scrollTo({ top: 0, behavior: 'smooth' }); return; }
      // Tap once to see everything; tap again to come back to a readable zoom.
      fit(true, { all: S.k <= READABLE + 0.001 });
    };
    $('#btnFocusOut').onclick = function () {
      var n = S.focusId && S.doc.byId[S.focusId];
      var up = n && n.parent && n.parent.kind !== 'root' ? n.parent.id : null;
      setFocus(up);
    };
    $('#btnExpand').onclick = function () {
      S.embedded = !S.embedded;
      document.body.classList.toggle('embed', S.embedded);
      $('#btnExpand').classList.toggle('on', !S.embedded);
      toast(S.embedded ? 'Read-only' : 'Editing enabled');
      render();
    };
    $('#btnHome').onclick = function () {
      if (S.editingId) commitEdit(false);
      goHome();
    };
    $('#btnAI').onclick = function () {
      if (S.home) return;
      if (S.ghost) return toast('Apply or discard the proposal first');
      generateForCurrentNote();
    };
    $('#btnSheetClose').onclick = closeSheet;
    elScrim.onclick = closeSheet;

    elStage.addEventListener('click', function (e) {
      var a = e.target.closest && e.target.closest('a.extref');
      if (a) { e.preventDefault(); toast(a.dataset.href); }
    });

    /*
     * A keyboard opening is a resize too - on Android it shrinks the layout
     * viewport, so height alone cannot tell the two apart (both innerHeight and
     * visualViewport.height move together). A keyboard never changes the WIDTH,
     * so that is what a genuine resize is judged by. Re-fitting on a keyboard
     * would throw away the frame the reader is typing into; and once they have
     * framed the map themselves, nothing re-fits it behind their back.
     */
    var lastWidth = elViewport.clientWidth;
    window.addEventListener('resize', function () {
      var w = elViewport.clientWidth;
      var widthChanged = Math.abs(w - lastWidth) > 2;
      lastWidth = w;
      if (S.editingId) { keepEditingVisible(); return; }
      if (S.mode === 'map' && widthChanged && !S.userMoved) fit(false, { all: S.embedded });
    });

    var vv = window.visualViewport;
    if (vv) {
      var onVV = function () {
        if (S.editingId) keepEditingVisible();
      };
      vv.addEventListener('resize', onVV);
      vv.addEventListener('scroll', onVV);
    }

    // iOS scrolls the document to reveal a focused field even when there is
    // nothing to scroll, which drags the whole fixed layout off screen.
    window.addEventListener('scroll', function () {
      if (window.scrollY !== 0 || window.scrollX !== 0) {
        window.scrollTo(0, 0);
        if (S.editingId) keepEditingVisible();
      }
    }, true);
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'hidden' && S.saveState === 'unsaved') { clearTimeout(S.saveTimer); save(); }
    });
  }

  /* ===================================================================== */
  /* boot                                                                   */
  /* ===================================================================== */

  function boot() {
    elStage = $('#stage'); elEdges = $('#edges'); elViewport = $('#viewport');
    elBottom = $('#bottombar'); elSheet = $('#sheet'); elScrim = $('#scrim');
    elToast = $('#toast'); elCrumbs = $('#crumbs'); elOutline = $('#outline');
    elOlList = $('#ol-list'); elOlSrc = $('#ol-src'); elTrash = $('#trash'); elEmpty = $('#empty');

    /*
     * The same HTML ships twice: as a `normal` app and as a `note_action` one.
     * No build flag is needed to tell them apart - a normal launch simply
     * arrives with no note, which is the standalone home.
     */
    var note = host.note();
    if (!note) {
      S.standalone = true;
      document.body.classList.add('standalone');
      $('#btnHome').hidden = false;
      wire();
      S.booted = true;
      host.loadState().then(function (st) {
        S.recents = (st && st.recents) || [];
        goHome();
      });
      return;
    }

    S.noteId = note.id;
    S.title = note.title || 'Note';
    S.isBlockScope = note.isBlockScope;
    S.baseline = note.content || '';

    var params = host.params() || {};
    S.embedded = String(params.mode || '') === 'embed';
    if (String(params.view || '') === 'outline') {
      S.mode = 'outline';
      elOutline.classList.add('on');
      elStage.style.visibility = 'hidden';
      document.querySelectorAll('#viewToggle button').forEach(function (x) {
        x.classList.toggle('on', x.dataset.mode === 'outline');
      });
    }
    document.body.classList.toggle('embed', S.embedded);
    $('#btnExpand').hidden = !S.embedded;

    reparse(S.baseline);
    sidecar.apply(S.doc, S);

    // A large map opens legible rather than exhaustive.
    if (!Object.keys(S.collapsed).length && S.doc.nodes.length > 60) {
      S.doc.nodes.forEach(function (n) {
        var depth = 0;
        for (var p = n.parent; p; p = p.parent) depth++;
        if (depth >= 3 && n.children.length) S.collapsed[n.id] = true;
      });
    }

    wire();
    fetchLinkedNotes();
    render();
    // An inline embed is a preview: show the whole map rather than a readable
    // slice of it, since the reader is not there to explore.
    requestAnimationFrame(function () { fit(false, { all: S.embedded }); setStatus(''); });
    // A full-screen note_action launch asks what the reader wants first. An
    // embed is a preview with nobody to ask, and ?launch=map skips the question.
    if (!S.embedded && String(params.launch || '') !== 'map') launchChooser();
    S.booted = true;
  }

  CG.app = {
    S: S, apply: apply, reparse: reparse, render: render, fit: fit, undo: undo,
    screenToStage: screenToStage, boot: boot, fitBranch: fitBranch,
    visibleRect: visibleRect, keepEditingVisible: keepEditingVisible,
    applyTransform: applyTransform, nodeScreenRect: nodeScreenRect,
    _ops: { beginEdit: beginEdit, addChild: addChild, addSibling: addSibling, removeNode: removeNode, doMove: doMove,
            enterSelect: enterSelect, exitSelect: exitSelect, runOp: runOp, runRefactor: runRefactor,
            applyGhost: applyGhost, discardGhost: discardGhost, importHere: importHere,
            generateFor: generateFor, generateForCurrentNote: generateForCurrentNote,
            saveGenerated: saveGenerated, goHome: goHome, openMapNote: openMapNote, loadNote: loadNote,
            lcaOf: lcaOf, stripSidecar: stripSidecar,
            movePicker: movePicker, performMove: performMove, moveTargets: moveTargets,
            linkPicker: linkPicker, performLink: performLink, linkSelected: linkSelected,
            unlinkSelected: unlinkSelected, selectLinkEnds: selectLinkEnds, linkedPair: linkedPair,
            attachExisting: attachExisting, moveCardsPicker: moveCardsPicker, performCardMove: performCardMove,
            cardLinkPicker: cardLinkPicker, performCardLink: performCardLink,
            multiCardViews: multiCardViews, detachNote: detachNote,
            indentNode: indentNode, outdentNode: outdentNode, nudge: nudge, toggleCheck: toggleCheck,
            setFocus: setFocus, promoteBranch: promoteBranch, dedentBranch: dedentBranch }
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
