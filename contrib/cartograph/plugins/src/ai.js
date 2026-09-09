/*
 * Cartograph - the AI contract.
 *
 * Synapse.chatAI returns plain text; there is no JSON or schema mode. That is
 * a good fit here: the answer's format is simply a markdown outline, which the
 * ordinary parser already consumes. Nothing the model can say is unparseable -
 * at worst it becomes a node with a long label, which is visible and fixable.
 *
 * Everything below is pure string work, so all of it is testable without a
 * model.
 */
(function (global) {
  'use strict';
  var CG = (global.CG = global.CG || {});
  var AI = (CG.ai = {});

  AI.MAX_SECTION = 12000;

  var RULES = [
    'Rules:',
    '- Reply with the outline ONLY. No preamble, no explanation, no code fences.',
    '- Use markdown headings (#, ##, ###) and "-" bullets, nested by indent.',
    '- Restructure only. Group, order and surface what the text already says.',
    '- Invent nothing. Add no fact, name, number or conclusion that is not in the text.',
    '- Prefer the source\'s own wording for labels, so each branch is traceable.',
    '- Keep "- [ ]" and "- [x]" checkboxes exactly as they appear.',
    '- Keep labels short. A label is a phrase, not a sentence.'
  ].join('\n');

  /*
   * A note is more than its markdown: a PDF, an image or a document attached
   * to it is as much "the note" as the text is. Attached files travel with the
   * request itself (Synapse.chatAI's `attachments`); the prompt only has to
   * name them and say that they count. `opts.attachments` is that list of
   * names. The text may legitimately be empty when the note is attachments
   * only, and the prompt says so rather than sending a bare, puzzling block.
   */
  AI.generatePrompt = function (title, text, opts) {
    opts = opts || {};
    var atts = (opts.attachments || []).map(function (a) {
      return String(a == null ? '' : (a.fileName || a.name || a)).replace(/[\r\n]+/g, ' ').trim();
    }).filter(Boolean);
    var body = String(text == null ? '' : text);
    var hasText = !!body.trim();
    var head = opts.section
      ? 'Turn this section of a note into one branch of a mind map.\n\n' +
        'Return a single "##" heading for the section, with nested bullets beneath it.'
      : 'Turn this note into a mind map outline.\n\n' +
        'Return one "#" heading - the centre of the map, naming the whole note - ' +
        'then "##" headings for its main themes, with nested bullets beneath them.';
    if (atts.length && opts.section && !hasText) {
      head = 'Turn the files attached to a note into branches of a mind map.\n\n' +
        'Return one "##" heading per main theme found in the files, with nested bullets beneath it.';
    }
    var files = '';
    if (atts.length) {
      files = '\n\nAttached files (' + atts.length + ', included with this message): ' + atts.join(', ') + '.\n' +
        'Their contents are part of the note. Read them and map what they say' +
        (hasText ? ' alongside the text below.' : '.');
      if (!hasText) files += '\nThe note has no text of its own; the attached files are the whole note.';
    }
    return head + '\n\n' + RULES + '\n\nNote title: ' + (title || 'Untitled') + files +
      '\n\n--- BEGIN TEXT ---\n' + (hasText ? body : '(no text)') + '\n--- END TEXT ---';
  };

  /*
   * Which model calls a generation takes. Text is split on its own headings as
   * before; attachments ride on the single call when there is one, and get a
   * call of their own when the text was long enough to split, so a section
   * prompt is never asked to fold a PDF into one heading of the text.
   */
  AI.planCalls = function (content, attachments, maxChars) {
    var text = String(content == null ? '' : content);
    var atts = attachments || [];
    var calls = text.trim()
      ? AI.splitSections(text, maxChars).map(function (s) { return { text: s.text, truncated: s.truncated, attachments: [] }; })
      : [];
    if (!atts.length) return calls;
    if (calls.length <= 1) {
      if (!calls.length) calls.push({ text: '', truncated: false, attachments: [] });
      calls[0].attachments = atts;
    } else {
      calls.push({ text: '', truncated: false, attachments: atts });
    }
    return calls;
  };

  var OPS = {
    merge: {
      label: 'Merge',
      say: function (names) {
        return 'Combine these nodes into a single node: ' + names +
          '. Keep every child of the originals, re-parented under the combined node.';
      }
    },
    group: {
      label: 'Group',
      say: function (names) {
        return 'Gather these nodes under one new parent node: ' + names +
          '. Choose a parent label drawn from what they have in common. Keep all of them and their children.';
      }
    },
    regroup: {
      label: 'Regroup',
      say: function () {
        return 'Reorganise this branch so related items sit together under sensible parents. ' +
          'Keep every leaf; you may introduce grouping nodes and re-order freely.';
      }
    },
    split: {
      label: 'Split',
      say: function (names) {
        return 'Split these overloaded nodes into several sibling nodes, one idea each: ' + names + '.';
      }
    },
    tidy: {
      label: 'Tidy labels',
      say: function () {
        return 'Rewrite the labels in this branch so they are consistent in style, ' +
          'length and grammatical form. Change no structure and drop nothing.';
      }
    }
  };
  AI.OPS = OPS;

  /*
   * Only the branch being worked on is ever sent, and only its replacement is
   * expected back, so the rest of the note is not in the request and cannot be
   * rewritten by accident.
   */
  AI.refactorPrompt = function (op, parentLabel, branchMarkdown, targetLabels) {
    var spec = OPS[op];
    if (!spec) return null;
    var names = (targetLabels || []).map(function (t) { return '"' + t + '"'; }).join(', ');
    return [
      spec.say(names),
      '',
      'You are given the contents of the branch "' + parentLabel + '".',
      'Reply with the replacement contents of that branch ONLY - not the "' + parentLabel + '" line itself.',
      '',
      'Rules:',
      '- Reply with markdown ONLY. No preamble, no explanation, no code fences.',
      '- Use "-" bullets nested by indent, mirroring the shape you were given.',
      '- Invent nothing. Every surviving label must come from the text below.',
      '- Drop nothing except what this instruction explicitly folds together.',
      '- Keep "- [ ]" and "- [x]" checkboxes exactly as they appear.',
      '',
      '--- BEGIN BRANCH ---',
      branchMarkdown,
      '--- END BRANCH ---'
    ].join('\n');
  };

  /* ------------------------------------------------------------ sanitizing */

  function isStructural(l) {
    return /^[ \t]{0,3}#{1,6}[ \t]+\S/.test(l) || /^[ \t]*([-*+]|\d{1,9}[.)])[ \t]+\S/.test(l);
  }

  /*
   * Models wrap answers in fences and bookend them with chat ("Here's the mind
   * map:" / "Let me know if..."). Strip the wrapper and any prose outside the
   * outline itself.
   *
   * Prose BETWEEN structural lines is left alone, since that is legitimate node
   * body. Only the head and tail are trimmed, which is where chat lives.
   */
  AI.strip = function (text) {
    var s = String(text == null ? '' : text).replace(/\r\n/g, '\n').trim();
    var fence = /^```[\w-]*[ \t]*\n([\s\S]*?)\n?[ \t]*```$/.exec(s);
    if (fence) s = fence[1].trim();
    // A model that fenced only part of the answer still leaves stray fences.
    s = s.replace(/^```[\w-]*[ \t]*$/gm, '');
    var lines = s.split('\n');
    var first = 0;
    while (first < lines.length && !isStructural(lines[first])) first++;
    var last = lines.length - 1;
    while (last >= first && !isStructural(lines[last])) last--;
    if (first > last) return '';
    return lines.slice(first, last + 1).join('\n').replace(/\s+$/, '');
  };

  function shiftHeadings(text, delta) {
    return text.split('\n').map(function (l) {
      var m = /^([ \t]{0,3})(#{1,6})([ \t]+.*)$/.exec(l);
      if (!m) return l;
      var lvl = Math.max(1, Math.min(6, m[2].length + delta));
      return m[1] + new Array(lvl + 1).join('#') + m[3];
    }).join('\n');
  }

  /*
   * Guarantee the outline has exactly one `#` heading, so the map has a single
   * centre (Cartograph hoists a lone H1 to the middle).
   */
  AI.sanitizeOutline = function (text, title) {
    var body = AI.strip(text);
    if (!body) return '';
    var h1s = (body.match(/^[ \t]{0,3}#[ \t]+\S/gm) || []).length;
    var name = String(title || 'Map').replace(/[\r\n]+/g, ' ').trim() || 'Map';
    if (h1s === 1 && /^[ \t]{0,3}#[ \t]+\S/.test(body)) return body;
    if (h1s === 0) return '# ' + name + '\n\n' + body;
    return '# ' + name + '\n\n' + shiftHeadings(body, 1);
  };

  /* -------------------------------------------------------------- chunking */

  /*
   * A note's content can be very large. Split it on its own top-level headings
   * so each piece is mapped in its own call and the results simply concatenate
   * - a join, never a merge.
   */
  AI.splitSections = function (content, maxChars) {
    var max = maxChars || AI.MAX_SECTION;
    var text = String(content == null ? '' : content);
    if (text.length <= max) return [{ text: text, truncated: false }];

    var lines = text.split('\n');
    var cuts = [];
    var fence = null;
    for (var i = 0; i < lines.length; i++) {
      var fm = /^[ \t]{0,3}(`{3,}|~{3,})/.exec(lines[i]);
      if (fm) { fence = fence && fm[1].charAt(0) === fence ? null : (fence || fm[1].charAt(0)); continue; }
      if (fence) continue;
      if (/^#{1,2}[ \t]+\S/.test(lines[i]) && i > 0) cuts.push(i);
    }
    if (!cuts.length) return [{ text: text.slice(0, max), truncated: text.length > max }];

    var blocks = [];
    var start = 0;
    cuts.concat([lines.length]).forEach(function (c) {
      blocks.push(lines.slice(start, c).join('\n'));
      start = c;
    });

    var out = [], cur = '';
    blocks.forEach(function (b) {
      if (cur && (cur.length + b.length + 1) > max) { out.push({ text: cur, truncated: false }); cur = ''; }
      if (b.length > max) {
        if (cur) { out.push({ text: cur, truncated: false }); cur = ''; }
        out.push({ text: b.slice(0, max), truncated: true });
        return;
      }
      cur = cur ? cur + '\n' + b : b;
    });
    if (cur) out.push({ text: cur, truncated: false });
    return out;
  };

  // Stitch per-section branches under one centre.
  AI.joinSections = function (parts, title) {
    var name = String(title || 'Map').replace(/[\r\n]+/g, ' ').trim() || 'Map';
    var body = parts.map(function (p) {
      var t = AI.strip(p);
      if (!t) return '';
      // Every section must sit at "##" so they become siblings under the centre.
      var h1 = (t.match(/^[ \t]{0,3}#[ \t]+\S/gm) || []).length;
      return h1 ? shiftHeadings(t, 1) : t;
    }).filter(Boolean).join('\n\n');
    if (!body) return '';
    return '# ' + name + '\n\n' + body;
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = CG;
})(typeof window !== 'undefined' ? window : globalThis);
