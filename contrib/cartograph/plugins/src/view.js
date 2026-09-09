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
      matched: false, keep: true, tags: [], links: [], outLinks: [], lineStart: -1,
      collapsed: false, hiddenCount: 0
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
    var cardsByNote = {};
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
      var split = MD.splitLinks(docNode);
      // Only the links this node actually owns; the rest belong to its cards.
      v.links = split.own;
      var r = rollup(docNode);
      v.taskDone = r.done; v.taskTotal = r.total;
      v.collapsed = !!collapsed[docNode.id];
      if (v.collapsed) v.hiddenCount = countDescendants(docNode);
      byId[v.id] = v;
      all.push(v);
      if (docNode.kind !== 'root') {
        // A slug can name several nodes, so this is a list. Which one a link
        // means is decided per source, by distance - see below.
        var sl = MD.slug(docNode.text);
        if (sl) (anchors[sl] = anchors[sl] || []).push(v.id);
      }

      // Attached notes become cards hanging off the node.
      var seen = {};
      for (var L = 0; L < split.cards.length; L++) {
        var card = split.cards[L];
        if (seen[card.noteId]) continue;
        seen[card.noteId] = true;
        var nv = mkView('note', 'note:' + docNode.id + ':' + card.noteId);
        nv.noteId = card.noteId;
        nv.ref = docNode;
        nv.outLinks = card.out;
        nv.lineStart = card.lineStart;
        var cached = noteCache[card.noteId];
        nv.noteTitle = (cached && cached.title) || card.link.label || 'Note';
        nv.notePreview = cached ? VIEW.preview(cached.content) : '';
        nv.text = nv.noteTitle;
        nv.parent = v;
        byId[nv.id] = nv;
        all.push(nv);
        (cardsByNote[card.noteId] = cardsByNote[card.noteId] || []).push(nv);
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

    /*
     * Anchor links become dashed edges once every node id is known.
     *
     * `#colors` cannot tell two nodes called "Colors" apart, so the nearest one
     * to the link's source wins - counted in edges through their lowest common
     * ancestor. Document order breaks a tie. The link is still reported as
     * ambiguous so the app can say so.
     */
    // Nearest of the candidates, measured from the source's own node. A card
    // measures from the node it hangs off, which is where it lives.
    function nearest(fromView, candidates) {
      var best = null, bestDist = Infinity;
      for (var i = 0; i < candidates.length; i++) {
        var cand = candidates[i];
        if (!cand || cand.id === fromView.id || !cand.ref || !fromView.ref) continue;
        var d = VIEW.distance(fromView.ref, cand.ref);
        if (d < bestDist) { bestDist = d; best = cand; }
      }
      return best;
    }

    // Both nodes and cards can be the source of a link; a card's live on the
    // body line it shares with its attachment.
    all.forEach(function (v) {
      if (!v.ref) return;
      var outgoing = v.kind === 'note' ? v.outLinks : v.links;
      (outgoing || []).forEach(function (link) {
        var candidates = null, slug = null, ambiguous = false;
        if (link.type === 'anchor') {
          slug = link.target.replace(/^#/, '').toLowerCase();
          var ids = anchors[slug] || [];
          candidates = ids.map(function (id) { return byId[id]; });
          ambiguous = ids.length > 1;
        } else if (link.type === 'note' && link.noteId) {
          candidates = cardsByNote[link.noteId] || [];
          ambiguous = candidates.length > 1;
        } else {
          return;
        }
        var best = nearest(v, candidates);
        if (!best) return;
        crossLinks.push({
          from: v.id, to: best.id, label: link.label,
          slug: slug, noteId: link.noteId || null,
          ambiguous: ambiguous, fromCard: v.kind === 'note'
        });
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

  // Edges between two nodes, through their lowest common ancestor.
  VIEW.distance = function (a, b) {
    if (a === b) return 0;
    var up = new Map(), d = 0;
    for (var x = a; x; x = x.parent, d++) up.set(x, d);
    var e = 0;
    for (var y = b; y; y = y.parent, e++) {
      if (up.has(y)) return up.get(y) + e;
    }
    return Infinity;
  };

  /*
   * Every slug in the document and the nodes that answer to it. Used when
   * creating a link, to warn that a label is not unique.
   */
  VIEW.anchorIndex = function (doc) {
    var map = {};
    doc.nodes.forEach(function (n) {
      if (n.kind === 'root') return;
      var s = MD.slug(n.text);
      if (!s) return;
      (map[s] = map[s] || []).push(n);
    });
    return map;
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
