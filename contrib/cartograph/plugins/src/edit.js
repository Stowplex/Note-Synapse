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

  /*
   * Add a line of body text under a node.
   *
   * A line placed directly beneath a bullet, with no blank line between, is a
   * paragraph continuation of that bullet - it folds into the LABEL rather than
   * becoming body. So an item with no body yet gets a blank line first,
   * otherwise every "attach" would quietly lengthen the node's own label.
   * Headings need no such care: a line after a heading is already body.
   */
  ED.appendBodyLines = function (doc, node, lines) {
    var list = (lines || []).filter(function (l) { return String(l).trim(); });
    if (!list.length) return doc.src;
    var at = node.self.end;
    for (var i = 0; i < node.body.length; i++) at = Math.max(at, node.body[i].end);
    var pad = node.kind === 'item' ? new Array(node.contentIndent + 1).join(' ') : '';
    var needsGap = node.kind === 'item' && !node.body.length;
    var block = list.map(function (l) { return pad + l; }).join('\n');
    return applySplices(doc.src, [insertLineAt(doc.src, at, (needsGap ? '\n' : '') + block)]);
  };

  ED.appendBodyLine = function (doc, node, text) {
    return ED.appendBodyLines(doc, node, [text]);
  };

  /* --------------------------------------------------------- note cards */

  ED.noteLink = function (id, title) {
    return '[' + String(title || 'Note').replace(/[\[\]]/g, '') +
      '](synapseresource://note/' + String(id).replace(/[^A-Za-z0-9_\-]/g, '') + ')';
  };

  /*
   * The body line an attached note lives on, if it has one of its own. A note
   * link sitting inside a node's LABEL has no line to move or hang links from.
   */
  ED.attachmentLine = function (doc, node, noteId) {
    var split = MD.splitLinks(node);
    for (var i = 0; i < split.cards.length; i++) {
      var c = split.cards[i];
      if (c.noteId !== noteId) continue;
      if (!c.link.inBody) return null;
      var nl = doc.src.indexOf('\n', c.lineStart);
      return { start: c.lineStart, end: nl === -1 ? doc.src.length : nl + 1, card: c };
    }
    return null;
  };

  ED.attachNotes = function (doc, node, notes) {
    var lines = (notes || []).map(function (n) { return ED.noteLink(n.id, n.title); });
    if (!lines.length) return { src: doc.src, error: 'nothing to attach' };
    return { src: ED.appendBodyLines(doc, node, lines), error: null, count: lines.length };
  };

  /*
   * Moving a card is moving one line, so removal and insertion go in a single
   * splice set against the original document - the whole line travels, which is
   * how the card keeps its own links.
   */
  /*
   * Move attached notes onto another node. Every removal and the one insertion
   * go in a single splice set against the original document, so N cards move as
   * one undo step and no offset is re-resolved against a shifted document.
   *
   * A card already on the target is skipped rather than refused, which also
   * keeps the insertion point clear of anything being removed.
   */
  ED.moveAttachments = function (doc, items, target) {
    if (!target) return { src: doc.src, error: 'nothing to move' };
    var lines = [], removals = [];
    for (var i = 0; i < (items || []).length; i++) {
      var it = items[i];
      if (!it || !it.node) continue;
      if (it.node === target) continue;
      var line = ED.attachmentLine(doc, it.node, it.noteId);
      if (!line) return { src: doc.src, error: 'that note is part of the label, so it has no line to move' };
      lines.push(doc.src.slice(line.start, line.end).replace(/\n$/, '').replace(/^[ \t]+/, ''));
      removals.push(ED.lineRemoval(doc.src, line.start, line.end));
    }
    if (!lines.length) return { src: doc.src, error: 'they are already there' };

    var at = target.self.end;
    for (var b = 0; b < target.body.length; b++) at = Math.max(at, target.body[b].end);
    var pad = target.kind === 'item' ? new Array(target.contentIndent + 1).join(' ') : '';
    var needsGap = target.kind === 'item' && !target.body.length;
    var prefix = (at > 0 && doc.src.charAt(at - 1) !== '\n') ? '\n' : '';
    var block = lines.map(function (l) { return pad + l; }).join('\n');

    return {
      src: applySplices(doc.src, removals.concat([
        { start: at, end: at, text: prefix + (needsGap ? '\n' : '') + block + '\n' }
      ])),
      error: null,
      moved: lines.length
    };
  };

  ED.moveAttachment = function (doc, source, noteId, target) {
    return ED.moveAttachments(doc, [{ node: source, noteId: noteId }], target);
  };

  ED.addCardLink = function (doc, source, noteId, linkMarkdown) {
    var line = ED.attachmentLine(doc, source, noteId);
    if (!line) return { src: doc.src, error: 'that note is part of the label, so it cannot carry links' };
    var end = line.end;
    if (doc.src.charAt(end - 1) === '\n') end--;
    while (end > line.start && /[ \t]/.test(doc.src.charAt(end - 1))) end--;
    return {
      src: applySplices(doc.src, [{ start: end, end: end, text: ' \u2192 ' + linkMarkdown }]),
      error: null
    };
  };

  ED.removeCardLink = function (doc, source, noteId, targetPattern) {
    var line = ED.attachmentLine(doc, source, noteId);
    if (!line) return { src: doc.src, error: 'no such attachment' };
    var text = doc.src.slice(line.start, line.end);
    var re = new RegExp('[ \\t]*(\\u2192[ \\t]*)?\\[[^\\]]*\\]\\([ \\t]*' + targetPattern + '[ \\t]*\\)', 'g');
    var splices = [], m;
    while ((m = re.exec(text)) !== null) {
      splices.push({ start: line.start + m.index, end: line.start + m.index + m[0].length, text: '' });
    }
    if (!splices.length) return { src: doc.src, error: 'that link is not on this note' };
    return { src: applySplices(doc.src, splices), error: null };
  };

  /*
   * Detaching takes the card's whole line, so any links the card carried go
   * with it. Stripping just the note link would strand them, and the line's
   * first link would then be an anchor - quietly turning the card's links into
   * the node's.
   */
  ED.detachNote = function (doc, node, noteId) {
    var line = ED.attachmentLine(doc, node, noteId);
    if (line) {
      return { src: applySplices(doc.src, [ED.lineRemoval(doc.src, line.start, line.end)]), error: null };
    }
    var re = new RegExp('[ \\t]*\\[[^\\]]*\\]\\([ \\t]*synapseresource://note/' +
      escapeRe(noteId) + '[^)]*\\)', 'gi');
    var r = ED.stripLinks(doc, node, re);
    if (!r.count) return { src: doc.src, error: 'could not find that link' };
    return { src: r.src, error: null };
  };

  ED.escapeRe = escapeRe;

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
    return null;
  };

  // True when the move would turn a section into bullets. Worth saying out loud
  // before it happens, since it rewrites how the note reads.
  ED.willChangeKind = function (node, newParent) {
    return !!(node && newParent && node.kind === 'heading' &&
      (newParent.kind === 'item' || newParent.level >= 6));
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

    /*
     * Same-kind moves are a pure shift - indent for bullets, heading level for
     * sections - which preserves markers and spacing exactly. That is the path
     * drag, indent and outdent take.
     *
     * When the kinds differ (a section moving under a bullet, or past ######)
     * the shift has no meaning, so the block is re-shaped instead, using the
     * same transform that import uses.
     */
    if (ED.willChangeKind(node, newParent)) {
      block = ED.reshape.apply(null, reshapeArgs(doc, node, newParent));
      if (block) block += '\n';
    } else if (node.kind === 'item') {
      var newIndent = (newParent.kind === 'item') ? newParent.contentIndent : 0;
      block = shiftIndent(block, newIndent - node.indent);
    } else {
      var newLevel = newParent.kind === 'root' ? 1 : Math.min(6, newParent.level + 1);
      block = shiftHeadings(block, newLevel - node.level);
    }
    if (!block.trim()) return { src: doc.src, error: 'there is nothing to move' };

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

  /*
   * A node's own subtree, lifted to the top level: an item dedented to column
   * zero, a section renumbered to start at `#`. This is the form `reshape`
   * expects, and it is how a move is expressed as an import of itself.
   */
  ED.subtreeMarkdown = function (doc, node) {
    var raw = doc.src.slice(node.outer.start, node.outer.end);
    if (node.kind === 'item') return shiftIndent(raw, -node.indent).replace(/\s+$/, '');
    return shiftHeadings(raw, 1 - node.level).replace(/\s+$/, '');
  };

  function reshapeArgs(doc, node, target) {
    var fdoc = MD.parse(ED.subtreeMarkdown(doc, node));
    return [fdoc, fdoc.root.children, target];
  }

  // Where a new last child of `target` goes, ignoring any child that is itself
  // on its way out - the only way an insertion could land inside a removal.
  function insertOffsetSkipping(doc, target, moving) {
    var end = target.kind === 'root'
      ? (doc.sidecar ? doc.sidecar.span.start : doc.src.length)
      : target.self.end;
    for (var i = 0; i < target.body.length; i++) end = Math.max(end, target.body[i].end);
    for (var c = 0; c < target.children.length; c++) {
      if (moving.indexOf(target.children[c]) >= 0) continue;
      end = Math.max(end, target.children[c].outer.end);
    }
    return end;
  }

  /*
   * Move several nodes under one destination as a SINGLE splice set.
   *
   * Every removal and the one insertion are computed against the original
   * document and applied together, so no offset is ever re-resolved against a
   * document that has already shifted underneath it. One undo step, too.
   */
  ED.moveMany = function (doc, nodes, target) {
    var list = (nodes || []).filter(Boolean);
    if (!list.length) return { src: doc.src, error: 'nothing to move' };

    // A node travelling inside its own selected ancestor must not also move on
    // its own account, or it would arrive twice.
    list = list.filter(function (n) {
      return !list.some(function (other) { return other !== n && isDescendant(n, other); });
    });

    for (var i = 0; i < list.length; i++) {
      var why = ED.canMove(list[i], target);
      if (why) return { src: doc.src, error: why };
    }

    list.sort(function (a, b) { return a.outer.start - b.outer.start; });
    if (list.every(function (n) { return n.parent === target; })) {
      return { src: doc.src, error: 'they are already there' };
    }

    var joined = list.map(function (n) { return ED.subtreeMarkdown(doc, n); }).join('\n');
    var fdoc = MD.parse(joined);
    var block = ED.reshape(fdoc, fdoc.root.children, target);
    if (!block.trim()) return { src: doc.src, error: 'there is nothing to move' };

    var at = insertOffsetSkipping(doc, target, list);
    var prefix = (at > 0 && doc.src.charAt(at - 1) !== '\n') ? '\n' : '';
    if (at > 0 && block.charAt(0) === '#' && doc.src.charAt(at - 2) !== '\n') prefix += '\n';

    var splices = list.map(function (n) {
      return { start: n.outer.start, end: n.outer.end, text: '' };
    });
    splices.push({ start: at, end: at, text: prefix + block + '\n' });

    var out = applySplices(doc.src, splices);
    return { src: out.replace(/\n{3,}/g, '\n\n'), error: null, moved: list.length };
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

  /* ---------------------------------------------------------------- links */

  function escapeRe(s) { return String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

  function lineBoundsAt(src, pos) {
    var start = src.lastIndexOf('\n', pos - 1) + 1;
    var nl = src.indexOf('\n', pos);
    return { start: start, end: nl === -1 ? src.length : nl + 1 };
  }

  /*
   * Remove every link in `node` matching `re`, and take the whole line with it
   * when nothing but whitespace would be left behind.
   *
   * Deliberately line-precise rather than a document-wide tidy of blank lines:
   * a whitespace-only line inside a fenced code block is content, and a global
   * sweep would eat it.
   */
  ED.stripLinks = function (doc, node, re) {
    var src = doc.src;
    var hits = [];
    function scan(start, end) {
      var text = src.slice(start, end);
      var m;
      re.lastIndex = 0;
      while ((m = re.exec(text)) !== null) {
        hits.push({ start: start + m.index, end: start + m.index + m[0].length });
      }
    }
    scan(node.textStart, node.textEnd);
    for (var i = 0; i < node.body.length; i++) scan(node.body[i].start, node.body[i].end);
    if (!hits.length) return { src: src, count: 0 };

    var splices = hits.map(function (h) {
      var line = lineBoundsAt(src, h.start);
      var rest = src.slice(line.start, h.start) + src.slice(h.end, line.end);
      if (rest.trim()) return { start: h.start, end: h.end, text: '' };
      return ED.lineRemoval(src, line.start, line.end);
    });
    return { src: applySplices(src, splices), count: hits.length };
  };

  /*
   * Remove a whole line. If it was separated from the node above only by the
   * blank line that made it body in the first place, that goes too - but not
   * when the next line is blank as well, where the gap is the reader's
   * paragraph break rather than ours.
   */
  ED.lineRemoval = function (src, start, end) {
    var from = start;
    if (from > 0) {
      var prev = lineBoundsAt(src, from - 1);
      if (!src.slice(prev.start, prev.end).trim()) {
        var nl = src.indexOf('\n', end);
        var nextLine = end >= src.length ? '' : src.slice(end, nl === -1 ? src.length : nl);
        var removedIndent = MD.indentWidth(src.slice(start, end));
        /*
         * That blank line is what makes everything under it BODY rather than a
         * continuation of the label. It may only go when nothing indented is
         * left below - otherwise the next line folds back into the label, which
         * is the same trap appendBodyLine has to avoid from the other side.
         */
        // A nested bullet or heading below is a CHILD, not body, so it never
        // needed that blank line. Only unstructured indented text does.
        var nextIsStructural = /^[ \t]*([-*+]|\d{1,9}[.)])[ \t]+/.test(nextLine) ||
          /^[ \t]{0,3}#{1,6}[ \t]+/.test(nextLine);
        if (end >= src.length || !nextLine.trim() ||
            MD.indentWidth(nextLine) < removedIndent || nextIsStructural) {
          from = prev.start;
        }
      }
    }
    return { start: from, end: end, text: '' };
  };

  ED.linkLabel = function (target) {
    return '\u2192 ' + MD.plainText(target.text).replace(/[\[\]]/g, '').slice(0, 60);
  };

  ED.linkLine = function (target) {
    return '[' + ED.linkLabel(target) + '](#' + MD.slug(target.text) + ')';
  };

  ED.linksFrom = function (node) {
    return (node.links || []).filter(function (l) { return l.type === 'anchor'; });
  };

  ED.hasLinkTo = function (node, slug) {
    return ED.linksFrom(node).some(function (l) {
      return l.target.replace(/^#/, '').toLowerCase() === slug;
    });
  };

  ED.addLink = function (doc, source, target) {
    if (!source || !target) return { src: doc.src, error: 'nothing to link' };
    if (source === target) return { src: doc.src, error: 'a node cannot link to itself' };
    var slug = MD.slug(target.text);
    if (!slug) return { src: doc.src, error: 'that node has no label to link to' };
    if (ED.hasLinkTo(source, slug)) return { src: doc.src, error: 'those two are already linked' };
    return { src: ED.appendBodyLine(doc, source, ED.linkLine(target)), error: null, slug: slug };
  };

  ED.removeLink = function (doc, source, slug) {
    var re = new RegExp('[ \\t]*\\[[^\\]]*\\]\\([ \\t]*#' + escapeRe(slug) + '[ \\t]*\\)', 'gi');
    var r = ED.stripLinks(doc, source, re);
    if (!r.count) return { src: doc.src, error: 'that link is not on this node' };
    return { src: r.src, error: null };
  };

  /*
   * Rename a node and carry any links that pointed at it.
   *
   * Anchors address a node by its text, so renaming would otherwise strand
   * every link to it. Both edits go in one splice set, hence one undo step.
   *
   * Only done when the old slug named exactly one node: if two nodes shared it,
   * the remaining twin still answers to it and rewriting would steal its links.
   */
  ED.renameCarryingLinks = function (doc, node, text, anchorIndex) {
    var clean = String(text == null ? '' : text).replace(/[\r\n]+/g, ' ');
    var splices = [{ start: node.textStart, end: node.textEnd, text: clean }];

    var oldSlug = MD.slug(node.text);
    var newSlug = MD.slug(clean);
    var unique = !anchorIndex || !oldSlug || (anchorIndex[oldSlug] || []).length === 1;

    if (oldSlug && newSlug && oldSlug !== newSlug && unique) {
      var oldLabel = ED.linkLabel(node);
      var newLabel = '\u2192 ' + MD.plainText(clean).replace(/[\[\]]/g, '').slice(0, 60);
      var re = new RegExp('\\[([^\\]]*)\\]\\([ \\t]*#' + escapeRe(oldSlug) + '[ \\t]*\\)', 'gi');
      var m;
      re.lastIndex = 0;
      while ((m = re.exec(doc.src)) !== null) {
        // Never touch a link inside the label being replaced.
        if (m.index >= node.textStart && m.index < node.textEnd) continue;
        // Keep a hand-written label; only refresh the one this app generates.
        var label = m[1] === oldLabel ? newLabel : m[1];
        splices.push({
          start: m.index, end: m.index + m[0].length,
          text: '[' + label + '](#' + newSlug + ')'
        });
      }
    }
    return applySplices(doc.src, splices);
  };

  /* ---------------------------------------------------------------- graft */

  function repeat(ch, n) { return n > 0 ? new Array(n + 1).join(ch) : ''; }

  // Strip a block's own common indent, then re-indent it to `indent`.
  function reindentBlock(raw, indent) {
    var lines = raw.replace(/\s+$/, '').split('\n');
    var min = null;
    lines.forEach(function (l) {
      if (!l.trim()) return;
      var w = MD.indentWidth(/^[ \t]*/.exec(l)[0]);
      if (min === null || w < min) min = w;
    });
    if (min === null) min = 0;
    return lines.map(function (l) {
      if (!l.trim()) return '';
      var ws = /^[ \t]*/.exec(l)[0];
      return repeat(' ', Math.max(0, MD.indentWidth(ws) - min) + indent) + l.slice(ws.length);
    }).join('\n');
  }

  /*
   * Re-shape a foreign outline so it can live under `target`.
   *
   * A heading can only stay a heading while there is heading depth left and the
   * target itself is a section. Once either runs out - the target is a bullet,
   * or the level would pass `######` - everything from there down becomes
   * bullets, nested by indent. Clamping at `######` instead would silently
   * flatten a deep import into a row of siblings.
   */
  ED.reshape = function (fdoc, roots, target) {
    var startLevel = null, baseIndent = 0;
    if (target.kind === 'root') startLevel = 1;
    else if (target.kind === 'heading') startLevel = Math.min(6, target.level + 1);
    else baseIndent = target.contentIndent;
    if (target.kind === 'heading' && target.level >= 6) startLevel = null;

    var out = [];

    function emit(n, ctx) {
      var asHeading = ctx.headingLevel !== null && n.kind === 'heading';
      var line, childCtx, bodyIndent;
      if (asHeading) {
        if (out.length) out.push('');   // a heading wants air above it
        line = repeat('#', ctx.headingLevel) + ' ' + n.text;
        bodyIndent = 0;
        childCtx = {
          headingLevel: ctx.headingLevel + 1 <= 6 ? ctx.headingLevel + 1 : null,
          indent: ctx.indent
        };
      } else {
        var box = n.checked === null ? '' : (n.checked ? '[x] ' : '[ ] ');
        var marker = (n.marker && /\d/.test(n.marker)) ? n.marker : '-';
        line = repeat(' ', ctx.indent) + marker + ' ' + box + n.text;
        bodyIndent = ctx.indent + 2;
        childCtx = { headingLevel: null, indent: ctx.indent + 2 };
      }
      out.push(line);
      for (var b = 0; b < n.body.length; b++) {
        var raw = fdoc.src.slice(n.body[b].start, n.body[b].end);
        out.push('');
        out.push(reindentBlock(raw, bodyIndent));
      }
      for (var c = 0; c < n.children.length; c++) emit(n.children[c], childCtx);
    }

    var ctx0 = { headingLevel: startLevel, indent: baseIndent };
    for (var i = 0; i < roots.length; i++) emit(roots[i], ctx0);
    return out.join('\n').replace(/\n{3,}/g, '\n\n').replace(/\s+$/, '');
  };

  // The part of a foreign note worth importing: its single `#` title branch if
  // it has one, otherwise everything at the top level.
  ED.graftRoots = function (fdoc) {
    var kids = fdoc.root.children;
    if (kids.length === 1 && kids[0].kind === 'heading') return [kids[0]];
    return kids;
  };

  ED.graft = function (doc, target, foreignMarkdown) {
    var fdoc = MD.parse(String(foreignMarkdown == null ? '' : foreignMarkdown));
    var roots = ED.graftRoots(fdoc);
    if (!roots.length) return { src: doc.src, error: 'that note has nothing to import' };
    var block = ED.reshape(fdoc, roots, target);
    if (!block.trim()) return { src: doc.src, error: 'that note has nothing to import' };
    var at = ED.childInsertOffset(doc, target, null);
    var prefix = '';
    if (at > 0) {
      if (doc.src.charAt(at - 1) !== '\n') prefix = '\n';
      // An imported section reads badly welded to the line above it.
      if (block.charAt(0) === '#' && doc.src.charAt(at - 2) !== '\n') prefix += '\n';
    }
    return {
      src: applySplices(doc.src, [{ start: at, end: at, text: prefix + block + '\n' }]),
      error: null
    };
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
