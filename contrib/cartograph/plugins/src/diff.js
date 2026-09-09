/*
 * Cartograph - what an AI proposal actually changed.
 *
 * Reuses sidecar.match, the same matcher that re-finds nodes after somebody
 * edits the note in another app. Given the tree before and the tree after, it
 * says which nodes survived, which were renamed or reparented, which were
 * folded into another, and which are new - which is exactly what the ghost
 * preview needs to draw.
 */
(function (global) {
  'use strict';
  var CG = (global.CG = global.CG || {});
  var MD = CG.md, SC = CG.sidecar;
  var DIFF = (CG.diff = {});

  function subtree(node) {
    var out = [];
    (function walk(n) {
      for (var i = 0; i < n.children.length; i++) { out.push(n.children[i]); walk(n.children[i]); }
    })(node);
    return out;
  }
  DIFF.subtree = subtree;

  var STOP = { a: 1, an: 1, the: 1, and: 1, or: 1, of: 1, to: 1, for: 1, in: 1, on: 1, with: 1 };

  function tokens(text) {
    return MD.plainText(text).toLowerCase().split(/[^\w\u4e00-\u9fff]+/)
      .filter(function (w) { return w && !STOP[w]; });
  }

  function parentText(n) {
    return n.parent && n.parent.kind !== 'root' ? MD.plainText(n.parent.text).toLowerCase() : '';
  }

  /*
   * `oldRoot` / `newRoot` bound the comparison - only what is under them is
   * considered, so a refactor of one branch can never be reported as having
   * touched the rest of the note.
   */
  DIFF.classify = function (oldRoot, newRoot) {
    var before = subtree(oldRoot);
    var after = subtree(newRoot);

    var entries = before.map(function (n) {
      var f = SC.fingerprint(n);
      return { id: n.id, key: f.key, text: f.text, depth: f.depth, parentKey: f.parentKey };
    });
    var matched = SC.match(entries, after);

    var byOld = {}, byNew = {};
    var claimed = {};

    before.forEach(function (n) {
      var hit = matched[n.id];
      if (!hit) return;
      claimed[hit.id] = true;
      var renamed = MD.plainText(n.text) !== MD.plainText(hit.text);
      var moved = parentText(n) !== parentText(hit);
      var state = renamed && moved ? 'movedrenamed' : renamed ? 'renamed' : moved ? 'moved' : 'kept';
      byOld[n.id] = { state: state, to: hit, from: n };
      byNew[hit.id] = { state: state, from: n, to: hit };
    });

    /*
     * An unmatched old node was either folded into a survivor or dropped.
     * Word overlap is the test, not substring containment: merging "API docs"
     * into "API design and docs" keeps every word but breaks the substring.
     */
    before.forEach(function (n) {
      if (byOld[n.id]) return;
      var mine = tokens(n.text);
      var best = null, bestScore = 0.6;
      if (mine.length) {
        for (var i = 0; i < after.length; i++) {
          var cand = tokens(after[i].text);
          if (cand.length <= mine.length) continue;
          var hit = 0;
          for (var t = 0; t < mine.length; t++) if (cand.indexOf(mine[t]) >= 0) hit++;
          var score = hit / mine.length;
          if (score > bestScore) { bestScore = score; best = after[i]; }
        }
      }
      byOld[n.id] = best ? { state: 'merged', into: best, from: n } : { state: 'removed', from: n };
    });

    after.forEach(function (n) {
      if (!claimed[n.id]) byNew[n.id] = { state: 'new', to: n };
    });

    var summary = { kept: 0, renamed: 0, moved: 0, merged: 0, removed: 0, added: 0 };
    Object.keys(byOld).forEach(function (id) {
      var s = byOld[id].state;
      if (s === 'kept') summary.kept++;
      else if (s === 'renamed') summary.renamed++;
      else if (s === 'moved') summary.moved++;
      else if (s === 'movedrenamed') { summary.moved++; summary.renamed++; }
      else if (s === 'merged') summary.merged++;
      else if (s === 'removed') summary.removed++;
    });
    Object.keys(byNew).forEach(function (id) { if (byNew[id].state === 'new') summary.added++; });

    summary.touched = summary.renamed + summary.moved + summary.merged + summary.removed + summary.added;
    return { byOld: byOld, byNew: byNew, summary: summary, before: before, after: after };
  };

  // One line a person can actually judge the change by.
  DIFF.describe = function (summary) {
    var bits = [];
    if (summary.merged) bits.push(summary.merged + ' merged');
    if (summary.added) bits.push(summary.added + ' added');
    if (summary.renamed) bits.push(summary.renamed + ' renamed');
    if (summary.moved) bits.push(summary.moved + ' moved');
    if (summary.removed) bits.push(summary.removed + ' removed');
    if (!bits.length) return 'Nothing would change.';
    return bits.join(' · ') + ' · ' + summary.kept + ' untouched';
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = CG;
})(typeof window !== 'undefined' ? window : globalThis);
