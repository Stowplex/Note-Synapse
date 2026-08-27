/*
 * Cartograph - the view tree.
 *
 * The document tree is what gets written back to markdown. The view tree is
 * what gets drawn: it adds attached-note cards, applies focus and collapse,
 * and carries the derived bits (task rollup, search state) that the renderer
 * needs. Keeping the two apart means drawing can never corrupt the document.
 */
(function (global) {
  'use strict';
  var CG = (global.CG = global.CG || {});
  var MD = CG.md;
  var VIEW = (CG.view = {});

  var RE_TAG = /(^|\s)#([\w一-鿿][\w一-鿿\-\/]*)/g;

  function tagsIn(text) {
    var out = [];
    var m;
    RE_TAG.lastIndex = 0;
    while ((m = RE_TAG.exec(text)) !== null) out.push(m[2].toLowerCase());
    return out;
  }
  VIEW.tagsIn = tagsIn;

  function mkView(kind, id) {
    return {
      id: id, kind: kind, text: '', ref: null, noteId: null, noteTitle: '', notePreview: '',
      level: 0, checked: null, children: [], parent: null,
      hasBody: false, bodyTypes: [], taskDone: 0, taskTotal: 0,
      matched: false, keep: true, tags: [], links: [], collapsed: false, hiddenCount: 0
    };
  }

  // Descendant task counts, computed over the document tree so a collapsed
  // branch still reports the totals underneath it.
  function rollup(docNode) {
    var done = 0, total = 0;
    (function walk(n) {
      for (var i = 0; i < n.children.length; i++) {
        var c = n.children[i];
        if (c.checked !== null) { total++; if (c.checked) done++; }
        walk(c);
      }
    })(docNode);
    return { done: done, total: total };
  }

  function countDescendants(docNode) {
    var n = 0;
    (function walk(x) { for (var i = 0; i < x.children.length; i++) { n++; walk(x.children[i]); } })(docNode);
    return n;
  }

  VIEW.build = function (doc, state) {
    state = state || {};
    var collapsed = state.collapsed || {};
    var noteCache = state.noteCache || {};
    var query = (state.query || '').trim().toLowerCase();
    var filters = state.filters || {};

    var rootDoc = doc.root;
    if (state.focusId && doc.byId[state.focusId]) rootDoc = doc.byId[state.focusId];
    else rootDoc = CG.layout.displayRoot(doc.root);

    var byId = {};
    var anchors = {};
    var crossLinks = [];
    var all = [];

    function build(docNode, parentView) {
      var v = mkView(docNode.kind, docNode.id);
      v.ref = docNode;
      v.text = docNode.kind === 'root' ? (state.title || 'Note') : docNode.text;
      v.level = docNode.level;
      v.checked = docNode.checked;
      v.parent = parentView;
      v.hasBody = docNode.body.length > 0;
      v.bodyTypes = docNode.body.map(function (b) { return b.type; });
      v.tags = tagsIn(v.text);
      v.links = docNode.links;
      var r = rollup(docNode);
      v.taskDone = r.done; v.taskTotal = r.total;
      v.collapsed = !!collapsed[docNode.id];
      if (v.collapsed) v.hiddenCount = countDescendants(docNode);
      byId[v.id] = v;
      all.push(v);
      if (docNode.kind !== 'root') anchors[MD.slug(docNode.text)] = v.id;

      // Attached notes become cards hanging off the node.
      var seen = {};
      for (var L = 0; L < docNode.links.length; L++) {
        var link = docNode.links[L];
        if (link.type !== 'note' || !link.noteId || seen[link.noteId]) continue;
        seen[link.noteId] = true;
        var nv = mkView('note', 'note:' + docNode.id + ':' + link.noteId);
        nv.noteId = link.noteId;
        nv.ref = docNode;
        var cached = noteCache[link.noteId];
        nv.noteTitle = (cached && cached.title) || link.label || 'Note';
        nv.notePreview = cached ? VIEW.preview(cached.content) : '';
        nv.text = nv.noteTitle;
        nv.parent = v;
        byId[nv.id] = nv;
        all.push(nv);
        v.children.push(nv);
      }

      if (!v.collapsed) {
        for (var i = 0; i < docNode.children.length; i++) {
          v.children.push(build(docNode.children[i], v));
        }
      }
      return v;
    }

    var rootView = build(rootDoc, null);
    // A hoisted `# Title` heading is still the visual centre of the map, even
    // though the document tree knows it as an ordinary heading.
    rootView.isRoot = true;

    // Anchor links become dashed edges once every node id is known.
    all.forEach(function (v) {
      if (!v.ref || v.kind === 'note') return;
      v.links.forEach(function (link) {
        if (link.type !== 'anchor') return;
        var target = anchors[link.target.replace(/^#/, '').toLowerCase()];
        if (target && target !== v.id) crossLinks.push({ from: v.id, to: target, label: link.label });
      });
    });

    /* ---- search and filters ---- */
    var filtering = !!query || filters.status || filters.hasNote || (filters.tag && filters.tag.length);
    if (filtering) {
      all.forEach(function (v) {
        var hay = (v.kind === 'note' ? v.noteTitle + ' ' + v.notePreview : v.text).toLowerCase();
        var ok = !query || hay.indexOf(query) >= 0;
        if (ok && filters.status === 'todo') ok = v.checked === false;
        if (ok && filters.status === 'done') ok = v.checked === true;
        if (ok && filters.hasNote) ok = v.children.some(function (c) { return c.kind === 'note'; }) || v.kind === 'note';
        if (ok && filters.tag) ok = v.tags.indexOf(filters.tag) >= 0;
        v.matched = ok;
      });
      // Keep a node when it matches, or is on the path to something that does.
      (function mark(v) {
        var any = v.matched;
        for (var i = 0; i < v.children.length; i++) if (mark(v.children[i])) any = true;
        v.keep = any;
        return any;
      })(rootView);
      rootView.keep = true;
    } else {
      all.forEach(function (v) { v.matched = false; v.keep = true; });
    }

    return { root: rootView, byId: byId, all: all, anchors: anchors, crossLinks: crossLinks, filtering: filtering };
  };

  VIEW.preview = function (content) {
    if (!content) return '';
    var lines = String(content).split('\n');
    var out = [];
    for (var i = 0; i < lines.length && out.length < 3; i++) {
      var l = lines[i].trim();
      if (!l) continue;
      if (/^```/.test(l)) continue;
      if (/^#{1,6}\s/.test(l)) l = l.replace(/^#{1,6}\s+/, '');
      if (/^<!--/.test(l)) continue;
      l = l.replace(/^([-*+]|\d{1,9}[.)])\s+/, '').replace(/^\[[ xX]\]\s+/, '');
      if (/^```synapse-cartograph/.test(l) || !l) continue;
      out.push(MD.plainText(l));
    }
    return out.join(' · ').slice(0, 160);
  };

  // Every path that needs expanding for a node to be visible.
  VIEW.pathTo = function (doc, nodeId) {
    var node = doc.byId[nodeId];
    var ids = [];
    for (var p = node && node.parent; p; p = p.parent) ids.push(p.id);
    return ids;
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = CG;
})(typeof window !== 'undefined' ? window : globalThis);
