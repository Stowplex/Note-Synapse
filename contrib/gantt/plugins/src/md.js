/*
 * Gantt - markdown in task notes: headings, checklists, checkbox toggles,
 * task-note templates and note links.
 *
 * Checkbox items are GFM task list items (`-`, `*`, `+`, `1.`, `1)`) plus
 * the host's bare `[ ] text` line (applyCheckboxToggle in
 * lib/widgets/interactive_checkbox_markdown.dart). Every checkbox counts on
 * its own, nested ones too. Lines inside fenced code (at any indent), HTML
 * comments and blockquotes are not content. Headings are ATX or setext.
 *
 * toggleEdit builds the replace_text edit that flips exactly one item (plan
 * D17, §8). It checks the edit against the host's own rules, restated here
 * from lib/services/note_modification_service.dart: replace_text needs
 * old_text to occur once in its scope (lines 555-641), and `section` scopes
 * to the lines after the FIRST line whose trim() equals it, up to the next
 * line starting with `#`s of the same or a higher level (_sliceSection,
 * lines 660-683; _headingLevel, lines 721-724). That rule is not fence
 * aware, so the edit is only used when the host's scope holds the item.
 */
(function (global) {
  'use strict';
  var GT = (global.GT = global.GT || {});
  var MD = (GT.md = {});

  function B() { return GT.block; }

  var ID = /^[A-Za-z0-9_-]+$/;
  var ATX = /^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$/;
  var ITEM = /^([ \t]*)(?:([-*+]|\d{1,9}[.)])[ \t]+)?\[([ xX])\][ \t]+(\S.*)$/;
  var LIST = /^[ \t]*([-*+]|\d{1,9}[.)])([ \t]|$)/;
  var HR = /^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$/;
  var UNDER = /^ {0,3}(=+|-+)[ \t]*$/;
  var QUOTE = /^[ \t]*>/;
  var BLANK = /^[ \t]*$/;
  // Dart's String.trim() set (it differs from JS trim only by U+0085).
  var DART_WS = '[\\t\\n\\v\\f\\r \\u0085\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff]';
  var DART_TRIM = new RegExp('^' + DART_WS + '+|' + DART_WS + '+$', 'g');
  function dartTrim(s) { return String(s).replace(DART_TRIM, ''); }

  /* -------------------------------------------------------------- headings */

  // Heading text for matching: marks, a trailing colon, case and runs of
  // whitespace do not matter, so `Checklist`, `## Checklist` and
  // `### checklist:` are one heading. NFKC folds fullwidth forms.
  MD.normHeading = function (s) {
    var t = String(s == null ? '' : s).replace(/[\r\n]+/g, ' ');
    if (t.normalize) t = t.normalize('NFKC');
    t = t.trim().replace(/^#+[ \t]*/, '').replace(/[ \t]+#+[ \t]*$/, '').trim();
    t = t.replace(/:+$/, '').trim();
    return t.replace(/\s+/g, ' ').toLowerCase();
  };

  /* ------------------------------------------------------------------ scan */

  // Classifies every line once: code, comment, quote, blank, heading,
  // heading-cont (a later line of a setext heading), underline, item,
  // list, hr or para.
  function scan(content) {
    var raw = String(content == null ? '' : content).split('\n');
    var text = raw.map(function (l) { return l.replace(/\r$/, ''); });
    var n = text.length, kind = new Array(n), heads = [];
    var fence = null, comment = false, i, s;
    for (i = 0; i < n; i++) {
      s = text[i];
      var lead = s.replace(/^[ \t]+/, '');
      if (fence) { kind[i] = 'code'; if (B().closes(lead, fence)) fence = null; continue; }
      if (comment) { kind[i] = 'comment'; if (s.indexOf('-->') >= 0) comment = false; continue; }
      var o = B().opening(lead);
      if (o) { fence = o; kind[i] = 'code'; continue; }
      // Only a comment that starts a line hides lines (CommonMark HTML block
      // type 2), up to the line holding `-->`. A mid-line `<!--` is inline
      // HTML (or sits in a code span) and hides nothing: a known limit.
      var h;
      if (/^<!--/.test(lead)) {
        kind[i] = 'comment';
        if (lead.indexOf('-->', 4) < 0) comment = true;
      }
      else if (QUOTE.test(s)) kind[i] = 'quote';
      else if (BLANK.test(s)) kind[i] = 'blank';
      else if ((h = ATX.exec(s))) { kind[i] = 'heading'; heads.push({ line: i, end: i, level: h[1].length, text: h[2] || '', setext: false }); }
      else if (ITEM.test(s)) kind[i] = 'item';
      else if (HR.test(s)) kind[i] = 'hr';
      else if (LIST.test(s)) kind[i] = 'list';
      else kind[i] = 'para';
    }
    // Setext: an underline directly under a paragraph makes the paragraph a
    // heading (level 1 for `=`, 2 for `-`).
    for (i = 1; i < n; i++) {
      if ((kind[i] !== 'para' && kind[i] !== 'hr') || kind[i - 1] !== 'para') continue;
      var u = UNDER.exec(text[i]);
      if (!u) continue;
      var p = i - 1;
      while (p > 0 && kind[p - 1] === 'para') p--;
      // A paragraph straight under a list item or a quote is its lazy
      // continuation, and the underline is then a thematic break (CommonMark).
      if (p > 0 && (kind[p - 1] === 'item' || kind[p - 1] === 'list' || kind[p - 1] === 'quote')) continue;
      var words = [];
      for (var k = p; k < i; k++) { words.push(text[k].trim()); kind[k] = k === p ? 'heading' : 'heading-cont'; }
      kind[i] = 'underline';
      heads.push({ line: p, end: i, level: u[1].charAt(0) === '=' ? 1 : 2, text: words.join(' '), setext: true });
    }
    heads.sort(function (a, b) { return a.line - b.line; });
    return { raw: raw, text: text, kind: kind, heads: heads };
  }

  function whole(sc) {
    return { found: true, whole: true, heading: null, text: '', level: 0, setext: false, line: -1, bodyStart: 0, bodyEnd: sc.text.length };
  }

  function find(sc, section) {
    var want = MD.normHeading(section);
    if (!want) return whole(sc);
    for (var k = 0; k < sc.heads.length; k++) {
      var h = sc.heads[k];
      if (MD.normHeading(h.text) !== want) continue;
      var end = sc.text.length;
      for (var j = k + 1; j < sc.heads.length; j++) if (sc.heads[j].level <= h.level) { end = sc.heads[j].line; break; }
      return { found: true, whole: false, heading: h.setext ? null : dartTrim(sc.text[h.line]), text: h.text, level: h.level,
        setext: h.setext, line: h.line, bodyStart: h.end + 1, bodyEnd: end };
    }
    return { found: false, whole: false, heading: null, text: '', level: 0, setext: false, line: -1, bodyStart: 0, bodyEnd: 0 };
  }

  /*
   * findSection(content, section) -> {found, whole, heading, text, level,
   *   setext, line, bodyStart, bodyEnd}
   * `section` '' is the whole note. Otherwise the first heading outside code
   * whose normHeading matches; its body runs to the next heading of the same
   * or a higher level. `heading` is the full trimmed ATX heading line (the
   * `section` string replace_text needs), null for setext headings.
   */
  MD.findSection = function (content, section) { return find(scan(content), section); };

  /* ------------------------------------------------------------- checklist */

  function itemsIn(sc, sec) {
    var out = [];
    for (var i = sec.bodyStart; i < sec.bodyEnd; i++) {
      if (sc.kind[i] !== 'item') continue;
      var s = sc.text[i], m = ITEM.exec(s);
      var box = s.indexOf('[', m[1].length + (m[2] ? m[2].length : 0));
      out.push({ index: i, line: s, prevLine: i > 0 ? sc.text[i - 1] : null, checked: m[3] !== ' ',
        text: m[4].replace(/[ \t]+$/, ''), indent: m[1].replace(/\t/g, '    ').length, box: box });
    }
    return out;
  }

  /*
   * checklist(content, section) -> {found, heading, items, done, total, bits}
   * items: [{index, line, prevLine, checked, text, indent, box}] in note
   * order. bits is one '1'/'0' per item, '' above 64 items.
   */
  MD.checklist = function (content, section) {
    var sc = scan(content), sec = find(sc, section);
    var out = { found: sec.found, heading: sec.heading, setext: sec.setext, items: [], done: 0, total: 0, bits: '' };
    if (!sec.found) return out;
    out.items = itemsIn(sc, sec);
    out.total = out.items.length;
    out.done = out.items.filter(function (it) { return it.checked; }).length;
    if (out.total <= 64) out.bits = out.items.map(function (it) { return it.checked ? '1' : '0'; }).join('');
    return out;
  };

  /* ---------------------------------------------------------------- toggle */

  // The host's _sliceSection scope as a line range, or null when the host
  // would throw "Section not found".
  function hostLevel(s) { var m = /^(#+)\s+/.exec(s); return m ? m[1].length : null; }
  function hostScope(raw, section) {
    var h = -1, i;
    for (i = 0; i < raw.length; i++) if (dartTrim(raw[i]) === section) { h = i; break; }
    if (h < 0) return null;
    var lvl = hostLevel(section), end = raw.length;
    for (i = h + 1; i < raw.length; i++) {
      var l = hostLevel(dartTrim(raw[i]));
      if (l !== null && lvl !== null && l <= lvl) { end = i; break; }
    }
    return { from: h + 1, to: end };
  }
  // hostScope(content, section) -> {from, to} line range of the host's
  // _sliceSection scope, or null. Used by store to verify a toggle.
  MD.hostScope = function (content, section) {
    return hostScope(String(content == null ? '' : content).split('\n'), String(section == null ? '' : section));
  };

  // Occurrences of `needle` in `hay`, overlapping ones included, stopping at 2.
  // Stricter than the host's count, so "once" here is once there too.
  function occurs(hay, needle) {
    var n = 0, i = hay.indexOf(needle);
    while (i >= 0 && n < 2) { n++; i = hay.indexOf(needle, i + 1); }
    return n;
  }

  function flip(it) {
    return it.line.slice(0, it.box + 1) + (it.checked ? ' ' : 'x') + it.line.slice(it.box + 2);
  }

  function pick(items, target) {
    if (typeof target.index === 'number') {
      // With a line too (the task sheet's list, M7), the item at that index
      // must still read that line; a note edited since never toggles another item.
      var want0 = typeof target.line === 'string' ? target.line.replace(/\r$/, '') : null;
      for (var i = 0; i < items.length; i++) {
        if (items[i].index !== target.index) continue;
        return want0 === null || items[i].line === want0 ? { item: items[i] } : { reason: 'gone' };
      }
      return { reason: 'gone' };
    }
    if (typeof target.line !== 'string') return { reason: 'gone' };
    var want = target.line.replace(/\r$/, '');
    var c = items.filter(function (it) { return it.line === want; });
    if (c.length > 1 && typeof target.prevLine === 'string') {
      var p = target.prevLine.replace(/\r$/, '');
      var c2 = c.filter(function (it) { return it.prevLine === p; });
      if (c2.length) c = c2;
    }
    if (!c.length) return { reason: 'gone' };
    if (c.length > 1) return { reason: 'ambiguous' };
    return { item: c[0] };
  }

  /*
   * toggleEdit(content, section, target) -> {ok, old_text, new_text,
   *   section?, line, newLine, prevLine, checked, index} | {ok:false, reason}
   *
   * target: {index} (a line index from checklist, optionally with the
   * `line` it must still hold) or {line, prevLine} (the identity a host
   * patch keeps, §6.1). The edit always targets the real
   * note: the host has no replace_text for a block-scoped launch, whose
   * writes go to parentNoteId (§10.1).
   *
   * old_text is the item line when that is unique in the scope, else the
   * line above plus the line, else more context, until it is unique; and
   * after the edit old_text must be gone and new_text unique in the scope,
   * so a retry of an applied edit is the host's idempotent no-op
   * (verification b).
   * The scope is the section (with `section` set to the full heading line)
   * for an ATX heading, else the whole note. `checked` is the new state.
   * reason: 'no-section', 'gone', 'ambiguous' or 'not-unique'.
   */
  MD.toggleEdit = function (content, section, target) {
    var sc = scan(content), sec = find(sc, section);
    if (!sec.found) return { ok: false, reason: 'no-section' };
    var got = pick(itemsIn(sc, sec), target || {});
    if (!got.item) return { ok: false, reason: got.reason };
    var it = got.item, raw = sc.raw, newLine = flip(it);
    var scopes = [];
    if (!sec.whole && !sec.setext) {
      var hs = hostScope(raw, sec.heading);
      if (hs) scopes.push({ section: sec.heading, from: hs.from, to: hs.to });
    }
    scopes.push({ section: null, from: 0, to: raw.length });
    var edited = raw.slice();
    edited[it.index] = newLine + raw[it.index].slice(it.line.length);
    for (var s = 0; s < scopes.length; s++) {
      var sp = scopes[s];
      if (it.index < sp.from || it.index >= sp.to) continue;
      var hay = { before: raw.slice(sp.from, sp.to).join('\n'), after: edited.slice(sp.from, sp.to).join('\n') }, k, j, r;
      // k lines of context above the item (the D17 rule is k <= 1), then j
      // lines below, then everything above plus j lines below. The whole
      // scope occurs once in itself (before and after the edit), so the
      // last step always ends.
      var maxUp = it.index - sp.from, maxDown = sp.to - 1 - it.index;
      for (k = 0; k <= maxUp; k++) if ((r = attempt(hay, raw, it, newLine, k, 0, sp.section))) return r;
      for (j = 1; j <= maxDown; j++) if ((r = attempt(hay, raw, it, newLine, 0, j, sp.section))) return r;
      for (j = 1; j <= maxDown; j++) if ((r = attempt(hay, raw, it, newLine, maxUp, j, sp.section))) return r;
    }
    return { ok: false, reason: 'not-unique' };
  };

  // The edit with k lines above and j lines below the item, or null when its
  // old_text is not unique in the scope, or a retry of it would not be the
  // host's no-op (old_text still there, or new_text not unique, after it).
  function attempt(hay, raw, it, newLine, k, j, section) {
    var above = k ? raw.slice(it.index - k, it.index).join('\n') + '\n' : '';
    // The item's own \r stays outside old_text when nothing follows it.
    var below = j ? raw[it.index].slice(it.line.length) + '\n' + raw.slice(it.index + 1, it.index + 1 + j).join('\n') : '';
    var oldT = above + it.line + below;
    var newT = above + newLine + below;
    // The host treats a retry as done only when old_text is gone and new_text
    // occurs once (note_modification_service.dart:580-592).
    if (occurs(hay.before, oldT) !== 1 || occurs(hay.after, oldT) !== 0 || occurs(hay.after, newT) !== 1) return null;
    var r = { ok: true, old_text: oldT, new_text: newT, line: it.line, newLine: newLine,
      prevLine: it.prevLine, checked: !it.checked, index: it.index };
    if (section) r.section = section;
    return r;
  }

  /* -------------------------------------------------------------- template */

  // The heading line a new task note gets for a section setting: the setting
  // itself when it is already an ATX heading, else `## <section>`.
  MD.headingLine = function (section) {
    var s = String(section == null ? '' : section).replace(/[\r\n]+/g, ' ').trim();
    if (!s) return '';
    if (/^#{1,6}[ \t]+\S/.test(s)) return s;
    var t = s.replace(/^#+[ \t]*/, '');
    return t ? '## ' + t : '';
  };

  // The checklist section a NEW chart stores for a UI language (§15.1).
  // A chart without the setting reads as "Checklist" whatever the language.
  MD.defaultSection = function (lang) {
    var I = GT.i18n;
    return I && I.normTag(lang) === 'zh-CN' ? I.ZH.Checklist : 'Checklist';
  };

  function oneLine(s) { return String(s == null ? '' : s).replace(/[\r\n]+/g, ' ').trim(); }

  /*
   * template({source, section, steps, intro, backlink:{chartId, title}})
   *   -> {content, subNotes}
   * Content for a task note created from the chart (§8). Source 'subnotes'
   * turns steps into subNotes; any other source writes the section heading
   * plus `- [ ] <step>` lines (the heading alone for 'checklist' with no
   * steps, so the section exists). The backlink line goes last. The content
   * has no leading or trailing whitespace (saveNotes trims it anyway).
   */
  MD.template = function (spec) {
    spec = spec || {};
    var source = spec.source || 'checklist';
    var steps = (Array.isArray(spec.steps) ? spec.steps : []).map(oneLine).filter(Boolean);
    var parts = [], subNotes = [];
    var intro = String(spec.intro == null ? '' : spec.intro).replace(/\r\n?/g, '\n').trim();
    if (intro) parts.push(intro);
    if (source === 'subnotes') {
      subNotes = steps.map(function (s) { return { name: s, content: '' }; });
    } else if (source === 'checklist' || steps.length) {
      var head = MD.headingLine(spec.section);
      var list = steps.map(function (s) { return '- [ ] ' + s; }).join('\n');
      if (head) parts.push(list ? head + '\n' + list : head);
      else if (list) parts.push(list);
    }
    var bl = spec.backlink;
    if (bl && typeof bl.chartId === 'string' && ID.test(bl.chartId)) {
      parts.push('[↩ ' + B().etext(oneLine(bl.title)) + '](synapseresource://note/' + bl.chartId + '?via=gantt-chart)');
    }
    return { content: parts.join('\n\n'), subNotes: subNotes };
  };

  /* ----------------------------------------------------------------- links */

  /*
   * noteLinkIds(content, opts) -> [noteId] in first-seen order, no repeats.
   * Links in code and comments do not count, nor chart backlinks
   * (`?via=gantt-chart`), nor opts.exclude (the note's own id).
   */
  MD.noteLinkIds = function (content, opts) {
    opts = opts || {};
    var sc = scan(content), out = [], seen = Object.create(null);
    var re = /synapseresource:\/\/note\/([A-Za-z0-9_-]+)(\?[^\s)]*)?/g;
    for (var i = 0; i < sc.text.length; i++) {
      if (sc.kind[i] === 'code' || sc.kind[i] === 'comment') continue;
      re.lastIndex = 0;
      var m;
      while ((m = re.exec(sc.text[i]))) {
        var id = m[1];
        if (m[2] && /[?&]via=gantt-chart(&|$)/.test(m[2])) continue;
        if (id === opts.exclude || seen[id]) continue;
        seen[id] = true;
        out.push(id);
      }
    }
    return out;
  };

  /*
   * sqlNeedle(section) -> the bare heading text for instr() in the §7.4
   * window query, with `'` doubled. No `#` marks, no closing `#`s, no
   * trailing colon; case is kept (instr is case-sensitive). '' for the
   * whole note.
   */
  MD.sqlNeedle = function (section) {
    var s = oneLine(section).replace(/^#+[ \t]*/, '').replace(/[ \t]+#+[ \t]*$/, '').replace(/[:：]+$/, '').trim();
    return s.replace(/\u0000/g, '').replace(/'/g, "''");
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
