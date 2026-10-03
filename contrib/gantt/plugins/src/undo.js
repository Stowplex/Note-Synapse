/*
 * Gantt - undo and redo stacks of inverse patches (D6).
 *
 * An entry is {label, patches, coalesceKey?, at}. `patches` is the inverse a
 * model transform returned. Undo applies it to the CURRENT chart, so changes
 * merged in from elsewhere survive. applyPatch returns the redo patches.
 *
 * Host effects ({op:'host'}) are carried, never executed: undo() and redo()
 * return them in `effects` and the caller (store) performs them. When an
 * effect fails the caller calls revert(result), which puts the entry back
 * unchanged; skip() drops a stuck top entry.
 */
(function (global) {
  'use strict';
  var GT = (global.GT = global.GT || {});
  var U = (GT.undo = {});

  U.COALESCE_MS = 800;

  U.createStack = function (opts) {
    opts = opts || {};
    var cap = opts.cap > 0 ? opts.cap : 100;
    var now = typeof opts.now === 'function' ? opts.now : function () { return Date.now(); };
    var undos = [], redos = [];

    function push(entry) {
      if (!entry || !entry.patches || !entry.patches.length) return false;
      var e = { label: entry.label || '', patches: entry.patches.slice(), coalesceKey: entry.coalesceKey || null, at: now() };
      var top = undos[undos.length - 1];
      redos.length = 0;
      if (top && e.coalesceKey && top.coalesceKey === e.coalesceKey && e.at - top.at <= U.COALESCE_MS) {
        // Undoing the pair undoes the newer change first.
        top.patches = e.patches.concat(top.patches);
        top.at = e.at;
        return true;
      }
      undos.push(e);
      while (undos.length > cap) undos.shift();
      return true;
    }

    function step(from, to, chart) {
      var e = from.pop();
      if (!e) return null;
      var r = GT.model.applyPatch(chart, e.patches);
      // A step the chart guarded into a no-op (its targets are gone) has
      // nothing to redo, so nothing goes onto the other stack.
      var back = null;
      if (r.inverse.length || r.effects.length) {
        back = { label: e.label, patches: r.inverse, coalesceKey: null, at: e.at };
        to.push(back);
      }
      return { chart: r.chart, effects: r.effects, label: e.label, entry: e, back: back, from: from, to: to };
    }

    return {
      push: push,
      undo: function (chart) { return step(undos, redos, chart); },
      redo: function (chart) { return step(redos, undos, chart); },
      // An effect of `result` failed: put its entry back where it was.
      revert: function (result) {
        if (!result) return;
        var i = result.back ? result.to.lastIndexOf(result.back) : -1;
        if (i >= 0) result.to.splice(i, 1);
        result.from.push(result.entry);
      },
      // Drop the top entry of one side (a stuck host effect the user skips).
      skip: function (which) { return (which === 'redo' ? redos : undos).pop() || null; },
      canUndo: function () { return undos.length > 0; },
      canRedo: function () { return redos.length > 0; },
      label: function (which) {
        var s = which === 'redo' ? redos : undos;
        return s.length ? s[s.length - 1].label : null;
      },
      clear: function () { undos.length = 0; redos.length = 0; },
      size: function () { return { undo: undos.length, redo: redos.length }; }
    };
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
