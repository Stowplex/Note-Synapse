/*
 * Cartograph - markdown outline parser with byte-exact spans.
 *
 * The note is the source of truth. Every node remembers the exact byte range
 * it came from, so an edit is a splice into the original string and never a
 * re-serialization of the document. Bytes we did not touch survive untouched.
 */
(function (global) {
  'use strict';
  var CG = (global.CG = global.CG || {});
  var MD = (CG.md = {});

  var RE_ATX = /^(#{1,6})([ \t]+)(.*)$/;
  var RE_SETEXT = /^[ \t]{0,3}(=+|-{2,})[ \t]*$/;
  var RE_ITEM = /^([ \t]*)([-*+]|\d{1,9}[.)])([ \t]+)(.*)$/;
  var RE_ITEM_EMPTY = /^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]*$/;
  var RE_FENCE = /^([ \t]{0,3})(`{3,}|~{3,})[ \t]*(\S*)[^\n]*$/;
  var RE_TASK = /^\[([ xX])\](?:[ \t]+|$)/;
  var RE_THEMATIC = /^[ \t]{0,3}((\*[ \t]*){3,}|(-[ \t]*){3,}|(_[ \t]*){3,})$/;

  MD.SIDECAR_INFO = 'synapse-cartograph';

  var uidCounter = 0;
  function nextId() {
    uidCounter += 1;
    return 'n' + uidCounter.toString(36);
  }
  MD.resetIds = function () { uidCounter = 0; };

  /* ---------------------------------------------------------------- lines */

  function splitLines(src) {
    var lines = [];
    var i = 0;
    while (i < src.length) {
      var nl = src.indexOf('\n', i);
      if (nl === -1) {
        lines.push({ start: i, textEnd: src.length, end: src.length, text: src.slice(i) });
        i = src.length;
      } else {
        lines.push({ start: i, textEnd: nl, end: nl + 1, text: src.slice(i, nl) });
        i = nl + 1;
      }
    }
    return lines;
  }
  MD.splitLines = splitLines;

  function indentWidth(s) {
    var n = 0;
    for (var i = 0; i < s.length; i++) {
      var c = s.charAt(i);
      if (c === ' ') n += 1;
      else if (c === '\t') n += 4;
      else break;
    }
    return n;
  }
  MD.indentWidth = indentWidth;

  function isBlank(text) { return /^[ \t]*$/.test(text); }

  /* ------------------------------------------------------------ inline md */

  // Strip inline markdown down to plain text, for slugs, fingerprints and
  // search. Deliberately simple: it never has to round-trip.
  function plainText(md) {
    var s = String(md == null ? '' : md);
    s = s.replace(/`([^`]*)`/g, '$1');
    s = s.replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1');
    s = s.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1');
    s = s.replace(/(\*\*|__)(.*?)\1/g, '$2');
    s = s.replace(/(\*|_)(.*?)\1/g, '$2');
    s = s.replace(/~~(.*?)~~/g, '$1');
    s = s.replace(/<[^>]+>/g, '');
    return s.replace(/\s+/g, ' ').trim();
  }
  MD.plainText = plainText;

  function slug(md) {
    return plainText(md)
      .toLowerCase()
      .replace(/[^\w一-鿿 \-]/g, '')
      .trim()
      .replace(/\s+/g, '-');
  }
  MD.slug = slug;

  var RE_LINK = /(!?)\[((?:[^\[\]\\]|\\.)*)\]\(\s*<?([^)\s>]*)>?(?:\s+"[^"]*")?\s*\)/g;

  function extractLinks(text) {
    var out = [];
    var m;
    RE_LINK.lastIndex = 0;
    while ((m = RE_LINK.exec(text)) !== null) {
      if (m[1] === '!') continue;
      var target = m[3] || '';
      var type = 'external';
      var noteId = null;
      if (/^synapseresource:\/\/note\//i.test(target)) {
        type = 'note';
        noteId = target.replace(/^synapseresource:\/\/note\//i, '').split(/[?#]/)[0];
      } else if (target.charAt(0) === '#') {
        type = 'anchor';
      }
      out.push({ type: type, label: m[2], target: target, noteId: noteId, index: m.index, length: m[0].length });
    }
    return out;
  }
  MD.extractLinks = extractLinks;

  /*
   * Split a node's links into the ones the NODE owns and the ones belonging to
   * attached-note cards hanging off it.
   *
   * A body line whose first link is a note link is that card's line: the note
   * link makes the card, and every other link on the line is the card's own.
   * Any other line's links are the node's, as they always were.
   */
  MD.splitLinks = function (node) {
    var byLine = {};
    var order = [];
    (node.links || []).forEach(function (l) {
      var key = String(l.lineStart);
      if (!byLine[key]) { byLine[key] = []; order.push(key); }
      byLine[key].push(l);
    });
    var own = [], cards = [];
    order.forEach(function (key) {
      var line = byLine[key].slice().sort(function (a, b) { return a.index - b.index; });
      var first = line[0];
      if (first.inBody && first.type === 'note' && first.noteId) {
        cards.push({ link: first, noteId: first.noteId, lineStart: first.lineStart, out: line.slice(1) });
        return;
      }
      // A note link anywhere else - in the label, or after other text - still
      // makes a card, it just has no links of its own to carry.
      line.forEach(function (l) {
        if (l.type === 'note' && l.noteId) {
          cards.push({ link: l, noteId: l.noteId, lineStart: l.lineStart, out: [] });
        } else {
          own.push(l);
        }
      });
    });
    return { own: own, cards: cards };
  };

  /* ---------------------------------------------------------------- nodes */

  function makeNode(kind) {
    return {
      id: nextId(),
      kind: kind,               // 'root' | 'heading' | 'item'
      level: 0,                 // heading level 1-6, or list depth 0-n
      marker: '',               // '-', '*', '+', '1.', '1)'
      text: '',                 // inline markdown of the label
      checked: null,            // null | false | true
      self: { start: 0, end: 0 },   // own line(s), including trailing newline
      textStart: 0,             // absolute offset of the label
      textEnd: 0,
      checkSpan: null,          // absolute span of '[ ]' when present
      indent: 0,                // visual indent of the marker
      contentIndent: 0,         // visual indent of the label
      markerSpan: null,         // absolute span of the list marker
      leadLength: 0,            // literal leading-whitespace length
      body: [],                 // [{start,end,type}]
      children: [],
      parent: null,
      outer: { start: 0, end: 0 },
      links: []
    };
  }

  function blockType(text) {
    var t = text.replace(/^[ \t]+/, '');
    if (/^(`{3,}|~{3,})/.test(t)) return 'code';
    if (/^\|/.test(t)) return 'table';
    if (/^>/.test(t)) return 'quote';
    if (/^!\[/.test(t)) return 'image';
    if (/^</.test(t)) return 'html';
    if (RE_THEMATIC.test(text)) return 'rule';
    return 'para';
  }

  /* ---------------------------------------------------------------- parse */

  MD.parse = function (src, options) {
    src = String(src == null ? '' : src);
    var opts = options || {};
    var lines = splitLines(src);

    var root = makeNode('root');
    root.text = opts.title || '';
    root.level = 0;
    root.self = { start: 0, end: 0 };

    var nodes = [root];
    var headStack = [root];       // innermost heading last
    var listStack = [];           // [{indent, contentIndent, node}]
    var sidecar = null;

    var openBody = null;          // {owner, block}
    var fence = null;             // {char, len, indent, owner, block, sidecar}
    var lastItem = null;          // node eligible for lazy continuation
    var prevBlank = true;

    function closeBody() { openBody = null; }

    function currentHeading() { return headStack[headStack.length - 1]; }

    // Which node a loose block of text belongs to, given the current line.
    function ownerForBlock(vIndent) {
      if (listStack.length) {
        var top = listStack[listStack.length - 1];
        if (vIndent >= top.contentIndent) return top.node;
        // Dedented back out of the list: the list is over.
        for (var i = listStack.length - 1; i >= 0; i--) {
          if (vIndent >= listStack[i].contentIndent) {
            listStack.length = i + 1;
            return listStack[i].node;
          }
        }
        listStack.length = 0;
      }
      return currentHeading();
    }

    function addBody(owner, line, type) {
      if (openBody && openBody.owner === owner && openBody.block.type === type) {
        openBody.block.end = line.end;
        return openBody.block;
      }
      var block = { start: line.start, end: line.end, type: type };
      owner.body.push(block);
      openBody = { owner: owner, block: block };
      return block;
    }

    function attach(node, parent) {
      node.parent = parent;
      parent.children.push(node);
      nodes.push(node);
    }

    for (var li = 0; li < lines.length; li++) {
      var line = lines[li];
      var text = line.text;

      /* ---- inside a fenced block: consume verbatim ---- */
      if (fence) {
        fence.block.end = line.end;
        var closeRe = new RegExp('^[ \\t]{0,3}' + fence.char + '{' + fence.len + ',}[ \\t]*$');
        if (closeRe.test(text)) {
          if (fence.isSidecar) sidecar.span.end = line.end;
          fence = null;
          openBody = null;
        }
        prevBlank = false;
        continue;
      }

      /* ---- blank ---- */
      if (isBlank(text)) {
        closeBody();
        lastItem = null;
        prevBlank = true;
        continue;
      }

      var vIndent = indentWidth(text);

      /* ---- fenced block start ---- */
      var fm = RE_FENCE.exec(text);
      if (fm) {
        var info = (fm[3] || '').trim().toLowerCase();
        // The sidecar is only ever written at column 0, as a top-level block.
        // Requiring that keeps a fence of the same name nested inside a list
        // from being mistaken for it.
        if (info === MD.SIDECAR_INFO && vIndent === 0) {
          listStack.length = 0;
          sidecar = { span: { start: line.start, end: line.end }, body: '' , bodyStart: line.end };
          fence = { char: fm[2].charAt(0), len: fm[2].length, isSidecar: true, block: sidecar.span };
          closeBody();
          prevBlank = false;
          continue;
        }
        var fOwner = ownerForBlock(vIndent);
        closeBody();
        var fBlock = { start: line.start, end: line.end, type: 'code' };
        fOwner.body.push(fBlock);
        fence = { char: fm[2].charAt(0), len: fm[2].length, isSidecar: false, block: fBlock };
        lastItem = null;
        prevBlank = false;
        continue;
      }

      /* ---- ATX heading ---- */
      var hm = RE_ATX.exec(text);
      if (hm && vIndent <= 3) {
        closeBody();
        listStack.length = 0;
        lastItem = null;
        var level = hm[1].length;
        while (headStack.length > 1 && headStack[headStack.length - 1].level >= level) headStack.pop();

        var hnode = makeNode('heading');
        hnode.level = level;
        hnode.marker = hm[1];
        var rawLabel = hm[3];
        // Trailing closing hashes are decoration, not text.
        var trimmed = rawLabel.replace(/[ \t]+#+[ \t]*$/, '');
        hnode.text = trimmed.trim();
        hnode.textStart = line.start + hm[1].length + hm[2].length;
        hnode.textEnd = hnode.textStart + trimmed.replace(/[ \t]+$/, '').length;
        hnode.self = { start: line.start, end: line.end };
        attach(hnode, headStack[headStack.length - 1]);
        headStack.push(hnode);
        prevBlank = false;
        continue;
      }

      /* ---- list item ---- */
      var im = RE_ITEM.exec(text);
      var imEmpty = im ? null : RE_ITEM_EMPTY.exec(text);
      if (im || imEmpty) {
        closeBody();
        var lead = im ? im[1] : imEmpty[1];
        var marker = im ? im[2] : imEmpty[2];
        var gap = im ? im[3] : ' ';
        var label = im ? im[4] : '';
        var mIndent = indentWidth(lead);
        var cIndent = mIndent + marker.length + indentWidth(gap === '' ? ' ' : gap);

        while (listStack.length && listStack[listStack.length - 1].indent >= mIndent) listStack.pop();

        var parent = listStack.length ? listStack[listStack.length - 1].node : currentHeading();
        var inode = makeNode('item');
        inode.level = listStack.length;
        inode.marker = marker;
        inode.indent = mIndent;
        inode.contentIndent = cIndent;
        inode.self = { start: line.start, end: line.end };
        inode.markerSpan = { start: line.start + lead.length, end: line.start + lead.length + marker.length };
        inode.leadLength = lead.length;
        var labelStart = line.start + lead.length + marker.length + gap.length;

        var tm = RE_TASK.exec(label);
        if (tm) {
          inode.checked = tm[1].toLowerCase() === 'x';
          inode.checkSpan = { start: labelStart, end: labelStart + 3 };
          labelStart += tm[0].length;
          label = label.slice(tm[0].length);
        }
        inode.text = label.replace(/[ \t]+$/, '');
        inode.textStart = labelStart;
        inode.textEnd = labelStart + inode.text.length;

        attach(inode, parent);
        listStack.push({ indent: mIndent, contentIndent: cIndent, node: inode });
        lastItem = inode;
        prevBlank = false;
        continue;
      }

      /* ---- paragraph continuation of the previous list item's label ---- */
      // With no blank line between, this line is part of the item's paragraph
      // whatever its indent - lazy (under-indented) or aligned to the content.
      if (lastItem && !prevBlank) {
        lastItem.self.end = line.end;
        lastItem.text += ' ' + text.trim();
        lastItem.textEnd = line.start + text.replace(/[ \t]+$/, '').length;
        prevBlank = false;
        continue;
      }

      /* ---- ordinary block content ---- */
      var owner = ownerForBlock(vIndent);
      addBody(owner, line, blockType(text));
      lastItem = null;
      prevBlank = false;
    }

    // Outer spans + link extraction, bottom-up.
    (function finish(node) {
      var end = node.self.end;
      for (var i = 0; i < node.body.length; i++) end = Math.max(end, node.body[i].end);
      for (var j = 0; j < node.children.length; j++) {
        finish(node.children[j]);
        end = Math.max(end, node.children[j].outer.end);
      }
      node.outer = { start: node.self.start, end: end };
      /*
       * Links carry absolute offsets and the start of the line they sit on.
       * The line matters: a body line whose first link is a note link belongs
       * to that attached-note card, and so does everything else on it - which
       * is how a card gets links of its own without becoming a node.
       */
      function lineStartAt(pos) { return src.lastIndexOf('\n', pos - 1) + 1; }

      node.links = extractLinks(node.text);
      for (var t = 0; t < node.links.length; t++) {
        node.links[t].index += node.textStart;
        node.links[t].inBody = false;
        node.links[t].lineStart = lineStartAt(node.links[t].index);
      }
      for (var k = 0; k < node.body.length; k++) {
        var blockText = src.slice(node.body[k].start, node.body[k].end);
        var found = extractLinks(blockText);
        for (var f = 0; f < found.length; f++) {
          found[f].index += node.body[k].start;
          found[f].inBody = true;
          found[f].lineStart = lineStartAt(found[f].index);
          node.links.push(found[f]);
        }
      }
    })(root);

    root.outer = { start: 0, end: src.length };

    var byId = {};
    for (var n = 0; n < nodes.length; n++) byId[nodes[n].id] = nodes[n];

    return {
      src: src,
      root: root,
      nodes: nodes,
      byId: byId,
      sidecar: sidecar,
      lines: lines
    };
  };

  /* ------------------------------------------------------------- coverage */

  // Proves the parse is lossless: every byte of the document is claimed by
  // exactly one node line, body block, sidecar block, or blank gap.
  MD.coverage = function (doc) {
    var spans = [];
    function walk(n) {
      if (n.kind !== 'root') spans.push([n.self.start, n.self.end, 'self:' + n.id]);
      for (var i = 0; i < n.body.length; i++) spans.push([n.body[i].start, n.body[i].end, 'body:' + n.id]);
      for (var j = 0; j < n.children.length; j++) walk(n.children[j]);
    }
    walk(doc.root);
    if (doc.sidecar) spans.push([doc.sidecar.span.start, doc.sidecar.span.end, 'sidecar']);
    spans.sort(function (a, b) { return a[0] - b[0]; });

    var problems = [];
    var cursor = 0;
    for (var s = 0; s < spans.length; s++) {
      var sp = spans[s];
      if (sp[0] < cursor) { problems.push('overlap at ' + sp[0] + ' (' + sp[2] + ')'); continue; }
      if (sp[0] > cursor) {
        var gap = doc.src.slice(cursor, sp[0]);
        if (!/^[ \t\r\n]*$/.test(gap)) problems.push('unclaimed text at ' + cursor + ': ' + JSON.stringify(gap.slice(0, 60)));
      }
      cursor = Math.max(cursor, sp[1]);
    }
    if (cursor < doc.src.length) {
      var tail = doc.src.slice(cursor);
      if (!/^[ \t\r\n]*$/.test(tail)) problems.push('unclaimed tail at ' + cursor + ': ' + JSON.stringify(tail.slice(0, 60)));
    }
    return problems;
  };

  // Convenience for tests: parse and check in one call.
  MD.coverageOf = function (src) { return MD.coverage(MD.parse(src)); };

  if (typeof module !== 'undefined' && module.exports) module.exports = CG;
})(typeof window !== 'undefined' ? window : globalThis);
