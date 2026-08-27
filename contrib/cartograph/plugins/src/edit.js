/*
 * Cartograph - structural edits.
 *
 * Every operation returns a NEW markdown string built by splicing the original.
 * Nothing is re-serialized, so an edit to one bullet cannot reformat a code
 * fence three sections away.
 */
(function (global) {
  'use strict';
  var CG = (global.CG = global.CG || {});
  var MD = CG.md;
  var ED = (CG.edit = {});

  function applySplices(src, splices) {
    var list = splices.slice().sort(function (a, b) { return b.start - a.start || b.end - a.end; });
    var out = src;
    for (var i = 0; i < list.length; i++) {
      var s = list[i];
      out = out.slice(0, s.start) + (s.text || '') + out.slice(s.end);
    }
    return out;
  }
  ED.applySplices = applySplices;

  // Collapse a run of 3+ newlines created by a removal down to a paragraph break.
  function tidySeam(src, at) {
    var start = at, end = at;
    while (start > 0 && /[ \t\r\n]/.test(src.charAt(start - 1))) start--;
    while (end < src.length && /[ \t\r\n]/.test(src.charAt(end))) end++;
    var run = src.slice(start, end);
    var nl = (run.match(/\n/g) || []).length;
    if (nl <= 2) return src;
    var replacement = start === 0 ? '' : '\n\n';
    if (end >= src.length) replacement = start === 0 ? '' : '\n';
    return src.slice(0, start) + replacement + src.slice(end);
  }

  function lineText(spec) {
    if (spec.kind === 'heading') {
      var lvl = Math.max(1, Math.min(6, spec.level || 1));
      return new Array(lvl + 1).join('#') + ' ' + spec.text;
    }
    var pad = new Array(Math.max(0, spec.indent || 0) + 1).join(' ');
    var box = spec.checked === true ? '[x] ' : (spec.checked === false ? '[ ] ' : '');
    return pad + (spec.marker || '-') + ' ' + box + spec.text;
  }
  ED.lineText = lineText;

  // The shape a new child of `parent` should take.
  ED.childSpecFor = function (parent) {
    if (parent.children.length) {
      var last = parent.children[parent.children.length - 1];
      if (last.kind === 'heading') return { kind: 'heading', level: last.level };
      return { kind: 'item', indent: last.indent, marker: last.marker, checked: last.checked === null ? null : false };
    }
    if (parent.kind === 'root') return { kind: 'heading', level: 1 };
    if (parent.kind === 'heading') return { kind: 'item', indent: 0, marker: '-' };
    return {
      kind: 'item',
      indent: parent.contentIndent,
      marker: /\d/.test(parent.marker) ? '1.' : parent.marker
    };
  };

  ED.siblingSpecFor = function (node) {
    if (node.kind === 'heading') return { kind: 'heading', level: node.level };
    return { kind: 'item', indent: node.indent, marker: node.marker, checked: node.checked === null ? null : false };
  };

  function insertLineAt(src, offset, text) {
    var prefix = (offset > 0 && src.charAt(offset - 1) !== '\n') ? '\n' : '';
    var body = text + '\n';
    return { start: offset, end: offset, text: prefix + body };
  }

  // Where a new last child of `parent` goes.
  ED.childInsertOffset = function (doc, parent, afterNode) {
    if (afterNode) return afterNode.outer.end;
    if (parent.children.length) return parent.children[parent.children.length - 1].outer.end;
    var end = parent.kind === 'root' ? 0 : parent.self.end;
    for (var i = 0; i < parent.body.length; i++) end = Math.max(end, parent.body[i].end);
    if (parent.kind === 'root') end = doc.sidecar ? doc.sidecar.span.start : doc.src.length;
    return end;
  };

  /* ------------------------------------------------------------- mutations */

  ED.setText = function (doc, node, text) {
    var clean = String(text == null ? '' : text).replace(/[\r\n]+/g, ' ');
    return applySplices(doc.src, [{ start: node.textStart, end: node.textEnd, text: clean }]);
  };

  ED.setChecked = function (doc, node, checked) {
    if (node.checkSpan) {
      return applySplices(doc.src, [{ start: node.checkSpan.start, end: node.checkSpan.end, text: checked ? '[x]' : '[ ]' }]);
    }
    if (node.kind !== 'item') return doc.src;
    return applySplices(doc.src, [{ start: node.textStart, end: node.textStart, text: (checked ? '[x] ' : '[ ] ') }]);
  };

  ED.clearChecked = function (doc, node) {
    if (!node.checkSpan) return doc.src;
    return applySplices(doc.src, [{ start: node.checkSpan.start, end: node.textStart, text: '' }]);
  };

  ED.remove = function (doc, node) {
    if (node.kind === 'root') return doc.src;
    var out = applySplices(doc.src, [{ start: node.outer.start, end: node.outer.end, text: '' }]);
    return tidySeam(out, node.outer.start);
  };

  ED.insertChild = function (doc, parent, spec, afterNode) {
    var s = Object.assign({}, ED.childSpecFor(parent), spec || {});
    if (!('text' in s)) s.text = '';
    var at = ED.childInsertOffset(doc, parent, afterNode);
    return applySplices(doc.src, [insertLineAt(doc.src, at, lineText(s))]);
  };

  ED.insertSibling = function (doc, node, spec) {
    var s = Object.assign({}, ED.siblingSpecFor(node), spec || {});
    if (!('text' in s)) s.text = '';
    return applySplices(doc.src, [insertLineAt(doc.src, node.outer.end, lineText(s))]);
  };

  ED.appendBodyLine = function (doc, node, text) {
    var at = node.self.end;
    for (var i = 0; i < node.body.length; i++) at = Math.max(at, node.body[i].end);
    var pad = node.kind === 'item' ? new Array(node.contentIndent + 1).join(' ') : '';
    return applySplices(doc.src, [insertLineAt(doc.src, at, pad + text)]);
  };

  /* ------------------------------------------------------------------ move */

  function isDescendant(node, maybeAncestor) {
    for (var p = node.parent; p; p = p.parent) if (p === maybeAncestor) return true;
    return false;
  }
  ED.isDescendant = isDescendant;

  ED.canMove = function (node, newParent) {
    if (!node || !newParent) return 'nothing to move';
    if (node === newParent) return 'a node cannot hold itself';
    if (isDescendant(newParent, node)) return 'a node cannot move inside its own branch';
    if (node.kind === 'heading' && newParent.kind === 'item') return 'a section cannot nest inside a bullet';
    return null;
  };

  function shiftIndent(block, delta) {
    if (!delta) return block;
    return block.split('\n').map(function (l) {
      if (!l.length) return l;
      var ws = /^[ \t]*/.exec(l)[0];
      if (ws.length === l.length) return l;
      var width = MD.indentWidth(ws) + delta;
      if (width < 0) width = 0;
      return new Array(width + 1).join(' ') + l.slice(ws.length);
    }).join('\n');
  }

  function shiftHeadings(block, delta) {
    if (!delta) return block;
    var fence = null;
    return block.split('\n').map(function (l) {
      var fm = /^[ \t]{0,3}(`{3,}|~{3,})/.exec(l);
      if (fm) {
        if (fence && fm[1].charAt(0) === fence) fence = null;
        else if (!fence) fence = fm[1].charAt(0);
        return l;
      }
      if (fence) return l;
      var m = /^(#{1,6})([ \t]+.*)$/.exec(l);
      if (!m) return l;
      var lvl = Math.max(1, Math.min(6, m[1].length + delta));
      return new Array(lvl + 1).join('#') + m[2];
    }).join('\n');
  }

  /*
   * `anchor` is {before: node} | {after: node} | a node (meaning "after it") |
   * null (append as the last child).
   */
  ED.move = function (doc, node, newParent, anchor) {
    var why = ED.canMove(node, newParent);
    if (why) return { src: doc.src, error: why };

    var original = doc.src.slice(node.outer.start, node.outer.end);
    var block = original;
    if (block.charAt(block.length - 1) !== '\n') block += '\n';

    if (node.kind === 'item') {
      var newIndent = (newParent.kind === 'item') ? newParent.contentIndent : 0;
      block = shiftIndent(block, newIndent - node.indent);
    } else {
      var newLevel = newParent.kind === 'root' ? 1 : Math.min(6, newParent.level + 1);
      block = shiftHeadings(block, newLevel - node.level);
    }

    var at;
    if (anchor && anchor.before) at = anchor.before.outer.start;
    else if (anchor && anchor.after) at = anchor.after.outer.end;
    else if (anchor && anchor.outer) at = anchor.outer.end;
    else at = ED.childInsertOffset(doc, newParent, null);
    // Landing inside its own span would splice the block into itself. Landing
    // exactly at either edge is fine as long as the block itself changed -
    // that is how "nest under the bullet above me" re-indents in place.
    if (at > node.outer.start && at < node.outer.end) return { src: doc.src, error: 'that would nest it inside itself' };
    if ((at === node.outer.start || at === node.outer.end) && block === (original.charAt(original.length - 1) === '\n' ? original : original + '\n')) {
      return { src: doc.src, error: 'that is already its home' };
    }

    var prefix = (at > 0 && doc.src.charAt(at - 1) !== '\n') ? '\n' : '';
    var splices = [
      { start: node.outer.start, end: node.outer.end, text: '' },
      { start: at, end: at, text: prefix + block }
    ];
    var out = applySplices(doc.src, splices);
    var seam = at < node.outer.start ? node.outer.start + (prefix + block).length : node.outer.start;
    return { src: tidySeam(out, seam), error: null };
  };

  /* ------------------------------------------------------------- renumber */

  // Renumber every run of ordered siblings. Run after any structural change.
  ED.renumber = function (doc) {
    var splices = [];
    function visit(parent) {
      var run = [];
      function flush() {
        for (var i = 0; i < run.length; i++) {
          var n = run[i];
          var delim = n.marker.charAt(n.marker.length - 1);
          var want = (i + 1) + delim;
          if (n.marker !== want && n.markerSpan) {
            splices.push({ start: n.markerSpan.start, end: n.markerSpan.end, text: want });
          }
        }
        run = [];
      }
      for (var c = 0; c < parent.children.length; c++) {
        var child = parent.children[c];
        if (child.kind === 'item' && /\d/.test(child.marker)) run.push(child);
        else flush();
        visit(child);
      }
      flush();
    }
    visit(doc.root);
    return splices.length ? applySplices(doc.src, splices) : doc.src;
  };

  /* -------------------------------------------------------------- sidecar */

  ED.writeSidecar = function (doc, text) {
    var src = doc.src;
    if (doc.sidecar) {
      var start = doc.sidecar.span.start, end = doc.sidecar.span.end;
      if (!text) {
        var out = applySplices(src, [{ start: start, end: end, text: '' }]);
        return tidySeam(out, start);
      }
      return applySplices(src, [{ start: start, end: end, text: text + '\n' }]);
    }
    if (!text) return src;
    var pad = src.length === 0 ? '' : (src.charAt(src.length - 1) === '\n' ? '\n' : '\n\n');
    return src + pad + text + '\n';
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = CG;
})(typeof window !== 'undefined' ? window : globalThis);
