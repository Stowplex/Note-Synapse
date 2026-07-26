/*
 * Diagram Studio core — pure markdown logic shared by the plugin UI and the
 * offline test suite (dev/run_core_tests.mjs). No DOM, no Synapse calls.
 *
 * Covers:
 *   - a CommonMark-ish fence scanner (``` and ~~~, indented, long fences,
 *     unterminated-at-EOF) so diagram blocks can be located by character range
 *   - classifying a block into a studio tab (mermaid / draw / ascii / ai)
 *   - a best-effort "is this ASCII art?" heuristic, because ASCII diagrams
 *     arrive inside ordinary fences and paragraphs and never announce
 *     themselves
 *   - locating THIS app's own previously inserted render image next to a
 *     block, so re-rendering replaces it instead of stacking another
 *   - composing and splicing a unit back into note content
 *
 * The strip/compose half is where a bug silently destroys the user's writing,
 * so the rules are deliberately narrow: only a full-line image, only one blank
 * line away from the source, and only with an alt text this app writes.
 */
(function (root, factory) {
  var core = factory();
  if (typeof module === 'object' && module.exports) {
    module.exports = core;
  }
  if (root) {
    root.DiagramBlocks = core;
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // The alt texts this app owns. `mermaid` is the legacy form written by
  // Mermaid Block Renderer, the app Diagram Studio replaces — recognising it
  // is what stops an upgraded note from growing a second image on first
  // re-render. Never widen this to match arbitrary alt text: a block selection
  // can be expanded upwards to swallow a preceding image, and the write
  // replaces the whole span.
  var RENDER_ALT = /^(?:diagram(?::[a-z-]+)?|mermaid)$/;

  /** A full line that is nothing but one of our render images. */
  var RENDER_LINE = /^[ \t]*!\[([^\]]*)\]\(([^)]*)\)[ \t]*$/;

  var TAB_KINDS = ['mermaid', 'draw', 'ascii', 'ai'];

  // Fence info strings we route to a tab. Everything else falls through to the
  // content-based checks.
  var INFO_MERMAID = /^mermaid\b/i;
  var INFO_AI = /^(?:ai-diagram|ai-image|aidiagram)\b/i;
  var INFO_DRAW = /^(?:jsdraw|js-draw|excalidraw|drawing|sketch)\b/i;

  // First non-empty line of a bare fence that gives away a Mermaid diagram.
  var MERMAID_KEYWORD = new RegExp(
    '^(?:graph|flowchart|sequenceDiagram|classDiagram|stateDiagram(?:-v2)?|' +
      'erDiagram|journey|gantt|pie|mindmap|timeline|gitGraph|quadrantChart|' +
      'requirementDiagram|sankey(?:-beta)?|xychart(?:-beta)?|block(?:-beta)?|' +
      'packet(?:-beta)?|architecture(?:-beta)?|C4Context|C4Container|' +
      'C4Component|C4Dynamic|C4Deployment)\\b',
    'i'
  );

  // ---------------------------------------------------------------------
  // Line indexing
  // ---------------------------------------------------------------------

  /**
   * Splits content into lines while remembering each line's character range,
   * so a block located by line index can be converted back to the [start, end)
   * offsets the write paths need.
   *
   * `end` excludes the line terminator; `next` is where the following line
   * begins. Both \n and \r\n are handled, and a file with no trailing newline
   * still yields its last line.
   */
  function indexLines(content) {
    var src = String(content == null ? '' : content);
    var lines = [];
    var i = 0;
    var start = 0;
    while (i < src.length) {
      var ch = src.charAt(i);
      if (ch === '\n') {
        lines.push({ text: src.slice(start, i), start: start, end: i, next: i + 1 });
        i += 1;
        start = i;
      } else if (ch === '\r') {
        var stop = i;
        i += src.charAt(i + 1) === '\n' ? 2 : 1;
        lines.push({ text: src.slice(start, stop), start: start, end: stop, next: i });
        start = i;
      } else {
        i += 1;
      }
    }
    // A trailing line with no terminator, or the single empty line of empty
    // content. Content ending in "\n" must NOT gain a phantom extra line.
    if (start < src.length || lines.length === 0) {
      lines.push({ text: src.slice(start), start: start, end: src.length, next: src.length });
    }
    return lines;
  }

  // ---------------------------------------------------------------------
  // Fence scanning
  // ---------------------------------------------------------------------

  /**
   * Parses a fence opener. Returns null when the line is not one.
   *
   * Follows CommonMark closely enough for real notes: at most 3 leading
   * spaces, at least 3 of ` or ~, and for backtick fences the info string may
   * not itself contain a backtick (```` ```a`b ```` is a paragraph, not a
   * fence).
   */
  function parseFenceOpen(line) {
    var m = /^([ ]{0,3})(`{3,}|~{3,})(.*)$/.exec(line);
    if (!m) return null;
    var info = m[3].trim();
    if (m[2].charAt(0) === '`' && info.indexOf('`') !== -1) return null;
    return { indent: m[1].length, char: m[2].charAt(0), len: m[2].length, info: info };
  }

  /** True when `line` closes a fence opened by `open`. */
  function isFenceClose(line, open) {
    var m = /^([ ]{0,3})(`{3,}|~{3,})[ \t]*$/.exec(line);
    if (!m) return false;
    return m[2].charAt(0) === open.char && m[2].length >= open.len;
  }

  /**
   * Finds every fenced code block, as line ranges.
   *
   * `openLine` / `closeLine` are inclusive line indices; `closeLine` is null
   * for a fence left unterminated at end of content (which the studio still
   * treats as a block, since that is what the user sees rendered).
   */
  function scanFences(lines) {
    var out = [];
    for (var i = 0; i < lines.length; i++) {
      var open = parseFenceOpen(lines[i].text);
      if (!open) continue;

      var closeLine = null;
      for (var j = i + 1; j < lines.length; j++) {
        if (isFenceClose(lines[j].text, open)) {
          closeLine = j;
          break;
        }
      }

      var lastLine = closeLine === null ? lines.length - 1 : closeLine;
      out.push({
        openLine: i,
        closeLine: closeLine,
        lastLine: lastLine,
        fence: open,
        bodyStartLine: i + 1,
        bodyEndLine: closeLine === null ? lines.length - 1 : closeLine - 1,
      });
      i = lastLine;
    }
    return out;
  }

  /** Joins the body lines of a fence back into text. */
  function fenceBody(lines, fence) {
    var out = [];
    for (var i = fence.bodyStartLine; i <= fence.bodyEndLine && i < lines.length; i++) {
      // Fence content is indented by the opener's indent; strip only that much.
      out.push(stripIndent(lines[i].text, fence.fence.indent));
    }
    return out.join('\n');
  }

  function stripIndent(text, amount) {
    var i = 0;
    while (i < amount && (text.charAt(i) === ' ' || text.charAt(i) === '\t')) i++;
    return text.slice(i);
  }

  // ---------------------------------------------------------------------
  // ASCII art detection
  // ---------------------------------------------------------------------

  // Box drawing, block elements and arrows. Any of these is near-conclusive:
  // nothing but a diagram puts them in a note.
  var BOX_GLYPH = /[─-╿▀-▟←-⇿]/;

  // The plain-ASCII vocabulary diagrams are drawn from.
  var ART_GLYPH = /[|+\-\/\\<>*=_#.:^v~()[\]]/;

  // A GFM pipe-table delimiter row. Tables are Table Studio's job, not ours,
  // and they would otherwise score very highly on pipes and dashes.
  var TABLE_DELIM = /^[ \t]*\|?[ \t]*:?-{2,}:?[ \t]*(?:\|[ \t]*:?-{2,}:?[ \t]*)+\|?[ \t]*$/;

  /**
   * Scores how much `text` looks like an ASCII/Unicode diagram, 0..1.
   *
   * Best-effort by design: the studio uses it to pre-select a tab and to decide
   * what to list, and the user can always override. It is tuned to accept the
   * common case (a box-and-arrow diagram pasted or AI-generated into an
   * ordinary fence) while rejecting prose, tables and source code.
   */
  function asciiArtScore(text) {
    var raw = String(text == null ? '' : text).replace(/\r\n?/g, '\n');
    var all = raw.split('\n');

    // Trim blank lines at both ends; they carry no signal.
    var from = 0;
    var to = all.length - 1;
    while (from <= to && all[from].trim() === '') from++;
    while (to >= from && all[to].trim() === '') to--;
    if (to < from) return 0;
    var lines = all.slice(from, to + 1);

    if (lines.length < 2) return 0;

    // A pipe table is not a diagram.
    for (var t = 0; t < lines.length; t++) {
      if (TABLE_DELIM.test(lines[t])) return 0;
    }

    var artChars = 0;
    var nonSpace = 0;
    var boxChars = 0;
    var drawingLines = 0;

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      var lineArt = 0;
      for (var c = 0; c < line.length; c++) {
        var ch = line.charAt(c);
        if (ch === ' ' || ch === '\t') continue;
        nonSpace++;
        if (BOX_GLYPH.test(ch)) {
          boxChars++;
          artChars++;
          lineArt++;
        } else if (ART_GLYPH.test(ch)) {
          artChars++;
          lineArt++;
        }
      }
      // "Drawing-ish" line: enough structural characters to be a border, a
      // connector or a box wall rather than incidental punctuation.
      if (lineArt >= 3) drawingLines++;
    }

    if (nonSpace === 0) return 0;

    // Box-drawing glyphs are decisive on their own — but still require two
    // drawing-ish lines so a single "→" in a sentence does not qualify.
    if (boxChars > 0 && drawingLines >= 2) return 1;

    if (drawingLines < 2) return 0;

    var artRatio = artChars / nonSpace;

    // Prose guard: long alphabetic runs are words, and diagrams are mostly
    // labels rather than sentences.
    var words = raw.match(/[A-Za-z]{4,}/g) || [];
    var wordChars = 0;
    for (var w = 0; w < words.length; w++) wordChars += words[w].length;
    var wordRatio = wordChars / nonSpace;

    // Diagrams tend to be rectangular: several lines of comparable width.
    var widths = [];
    for (var k = 0; k < lines.length; k++) {
      if (lines[k].trim() !== '') widths.push(lines[k].replace(/\s+$/, '').length);
    }
    var mean = 0;
    for (var m = 0; m < widths.length; m++) mean += widths[m];
    mean = mean / (widths.length || 1);
    var variance = 0;
    for (var v = 0; v < widths.length; v++) {
      variance += (widths[v] - mean) * (widths[v] - mean);
    }
    var spread = mean > 0 ? Math.sqrt(variance / (widths.length || 1)) / mean : 1;

    var score = artRatio;
    if (wordRatio > 0.5) score -= wordRatio - 0.5;
    if (spread < 0.5) score += 0.1;
    if (score < 0) score = 0;
    if (score > 1) score = 1;
    return score;
  }

  var ASCII_THRESHOLD = 0.35;

  function looksLikeAsciiArt(text) {
    return asciiArtScore(text) >= ASCII_THRESHOLD;
  }

  // ---------------------------------------------------------------------
  // Classification
  // ---------------------------------------------------------------------

  /**
   * Routes a block to a studio tab. Order matters: an explicit info string
   * always wins, then a Mermaid keyword in a bare fence, then the ASCII
   * heuristic. `other` means "not a diagram" — still offered as an insertion
   * point, but not opened as one.
   */
  function classify(info, body) {
    var tag = String(info || '').trim();
    if (INFO_MERMAID.test(tag)) return 'mermaid';
    if (INFO_AI.test(tag)) return 'ai';
    if (INFO_DRAW.test(tag)) return 'draw';

    var text = String(body == null ? '' : body);
    var firstLine = '';
    var candidates = text.replace(/\r\n?/g, '\n').split('\n');
    for (var i = 0; i < candidates.length; i++) {
      if (candidates[i].trim() !== '') {
        firstLine = candidates[i].trim();
        break;
      }
    }
    // Only guess Mermaid for a fence with no language tag. A fence explicitly
    // marked ```python that happens to start with "graph" is Python.
    if (tag === '' && MERMAID_KEYWORD.test(firstLine)) return 'mermaid';

    if (looksLikeAsciiArt(text)) return 'ascii';
    return 'other';
  }

  // ---------------------------------------------------------------------
  // Render marker
  // ---------------------------------------------------------------------

  /**
   * Parses a line that is exactly one of this app's render images.
   * Returns {alt, ref, kind} or null. A user-authored image, or an image with
   * text around it, never matches.
   */
  function parseRenderLine(text) {
    var m = RENDER_LINE.exec(String(text == null ? '' : text));
    if (!m) return null;
    var alt = m[1];
    if (!RENDER_ALT.test(alt)) return null;
    var kind = alt === 'mermaid' ? 'mermaid' : alt.indexOf(':') === -1 ? null : alt.split(':')[1];
    return { alt: alt, ref: m[2].trim(), kind: kind };
  }

  /**
   * Looks for one of our render images adjacent to the line range
   * [firstLine, lastLine], skipping at most one blank line.
   *
   * Above is preferred because that is where both this app and its predecessor
   * write by default. Returns null when the neighbouring line is anything else
   * — including a user's own image, which must never be touched.
   *
   * `opts.consumed` is the set of lines already owned by an earlier unit, so
   * two units can never both claim the same image. `opts.acceptKinds`, when
   * given, restricts which typed renders may be claimed: an untyped
   * `![diagram]` always matches, but a `![diagram:draw]` sitting next to an
   * ASCII paragraph belongs to a drawing, not to the paragraph.
   */
  function findAdjacentRender(lines, firstLine, lastLine, opts) {
    var above = probeRender(lines, firstLine, -1, opts);
    if (above) return above;
    return probeRender(lines, lastLine, 1, opts);
  }

  function probeRender(lines, from, step, opts) {
    var options = opts || {};
    var consumed = options.consumed || {};
    var acceptKinds = options.acceptKinds || null;

    var i = from + step;
    if (i < 0 || i >= lines.length) return null;

    var blank = 0;
    if (lines[i].text.trim() === '') {
      blank = 1;
      i += step;
      if (i < 0 || i >= lines.length) return null;
    }

    if (consumed[i]) return null;

    var parsed = parseRenderLine(lines[i].text);
    if (!parsed) return null;
    if (acceptKinds && parsed.kind && acceptKinds.indexOf(parsed.kind) === -1) return null;

    return {
      ref: parsed.ref,
      alt: parsed.alt,
      kind: parsed.kind,
      line: i,
      blankLines: blank,
      position: step < 0 ? 'above' : 'below',
    };
  }

  // ---------------------------------------------------------------------
  // Unit scanning
  // ---------------------------------------------------------------------

  /**
   * Scans note content into "units": a diagram source plus the render image
   * this app previously wrote next to it, if any.
   *
   * Returned ranges are character offsets into `content`:
   *   sourceStart/sourceEnd  the fence (or paragraph) itself
   *   unitStart/unitEnd      source plus the adjacent render, i.e. exactly what
   *                          a write should replace
   *
   * Units are returned in document order and never overlap.
   */
  function scanBlocks(content) {
    var text = String(content == null ? '' : content);
    var lines = indexLines(text);
    var fences = scanFences(lines);

    var units = [];
    var consumed = {}; // line index -> true, so paragraph scanning skips fences

    for (var f = 0; f < fences.length; f++) {
      var fence = fences[f];
      for (var l = fence.openLine; l <= fence.lastLine; l++) consumed[l] = true;

      var body = fenceBody(lines, fence);
      var kind = classify(fence.fence.info, body);
      // A fence is a diagram *source*, so any of our renders beside it is its
      // output — no kind restriction needed.
      var render = findAdjacentRender(lines, fence.openLine, fence.lastLine, { consumed: consumed });
      if (render) consumed[render.line] = true;

      // A render image tells us what produced it, which beats guessing —
      // an `ai-diagram` prompt fence renders as `![diagram:ai]`, and a fence
      // whose content no longer parses still belongs to its original tab.
      if (render && render.kind && TAB_KINDS.indexOf(render.kind) !== -1) {
        kind = render.kind;
      }

      units.push(
        makeUnit({
          lines: lines,
          kind: kind,
          info: fence.fence.info,
          body: body,
          fence: fence.fence,
          firstLine: fence.openLine,
          lastLine: fence.lastLine,
          render: render,
          unterminated: fence.closeLine === null,
        })
      );
    }

    // Plain paragraphs that look like ASCII art. Runs BEFORE the standalone
    // pass so a paragraph gets first claim on its own render; only genuinely
    // orphaned images fall through.
    var p = 0;
    while (p < lines.length) {
      if (consumed[p] || lines[p].text.trim() === '' || parseRenderLine(lines[p].text)) {
        p++;
        continue;
      }
      var startLine = p;
      while (
        p < lines.length &&
        !consumed[p] &&
        lines[p].text.trim() !== '' &&
        !parseRenderLine(lines[p].text)
      ) {
        p++;
      }
      var endLine = p - 1;

      var paraLines = [];
      for (var q = startLine; q <= endLine; q++) paraLines.push(lines[q].text);
      var paraText = paraLines.join('\n');

      if (looksLikeAsciiArt(paraText)) {
        // Only an untyped or `ascii` render can belong to a paragraph of
        // ASCII art — a neighbouring `![diagram:draw]` is a drawing's output.
        var paraRender = findAdjacentRender(lines, startLine, endLine, {
          consumed: consumed,
          acceptKinds: ['ascii'],
        });
        for (var c2 = startLine; c2 <= endLine; c2++) consumed[c2] = true;
        if (paraRender) consumed[paraRender.line] = true;
        units.push(
          makeUnit({
            lines: lines,
            kind: 'ascii',
            info: '',
            body: paraText,
            fence: null,
            firstLine: startLine,
            lastLine: endLine,
            render: paraRender,
          })
        );
      }
    }

    // Standalone render images with no source beside them: a Draw unit, whose
    // SVG attachment *is* its source, looks exactly like this. So does a
    // render whose source block the user has since deleted.
    for (var r = 0; r < lines.length; r++) {
      if (consumed[r]) continue;
      var solo = parseRenderLine(lines[r].text);
      if (!solo) continue;
      consumed[r] = true;
      units.push(
        makeUnit({
          lines: lines,
          kind: solo.kind && TAB_KINDS.indexOf(solo.kind) !== -1 ? solo.kind : 'draw',
          info: '',
          body: '',
          fence: null,
          firstLine: r,
          lastLine: r,
          render: { ref: solo.ref, alt: solo.alt, kind: solo.kind, line: r, blankLines: 0, position: 'above' },
          soloRender: true,
        })
      );
    }

    units.sort(function (a, b) {
      return a.unitStart - b.unitStart || a.unitEnd - b.unitEnd;
    });
    for (var u = 0; u < units.length; u++) units[u].index = u;
    return units;
  }

  function makeUnit(opts) {
    var lines = opts.lines;
    var sourceStart = lines[opts.firstLine].start;
    var sourceEnd = lines[opts.lastLine].end;

    var unitStart = sourceStart;
    var unitEnd = sourceEnd;
    if (opts.render && !opts.soloRender) {
      if (opts.render.position === 'above') {
        unitStart = lines[opts.render.line].start;
      } else {
        unitEnd = lines[opts.render.line].end;
      }
    }

    return {
      kind: opts.kind,
      info: opts.info || '',
      body: opts.body || '',
      fence: opts.fence || null,
      sourceStart: sourceStart,
      sourceEnd: sourceEnd,
      unitStart: unitStart,
      unitEnd: unitEnd,
      firstLine: opts.firstLine,
      lastLine: opts.lastLine,
      renderRef: opts.render ? opts.render.ref : null,
      renderPosition: opts.render ? opts.render.position : null,
      soloRender: !!opts.soloRender,
      unterminated: !!opts.unterminated,
      index: 0,
    };
  }

  // ---------------------------------------------------------------------
  // Composing and splicing
  // ---------------------------------------------------------------------

  /** The fence a given tab writes its source into. */
  function fenceInfoFor(kind) {
    if (kind === 'mermaid') return 'mermaid';
    if (kind === 'ai') return 'ai-diagram';
    if (kind === 'draw') return 'jsdraw';
    return '';
  }

  /**
   * Picks a fence delimiter long enough to contain `body`.
   *
   * A prompt or a label can legitimately contain a ``` run; opening with a
   * longer fence is the CommonMark-sanctioned way to nest it, and skipping
   * this check would truncate the block at the user's own backticks.
   */
  function fenceFor(body) {
    var longest = 0;
    var runs = String(body || '').match(/`+/g) || [];
    for (var i = 0; i < runs.length; i++) {
      if (runs[i].length > longest) longest = runs[i].length;
    }
    return new Array(Math.max(3, longest + 1) + 1).join('`');
  }

  /**
   * Builds the markdown for a unit: the source block and the render image,
   * in the requested order.
   *
   * `ref` may be null (source only, e.g. a diagram that has not rendered yet),
   * and `body` may be empty for a Draw unit whose SVG carries everything.
   */
  function composeUnit(opts) {
    var kind = opts.kind;
    var ref = opts.ref || null;
    var body = String(opts.body == null ? '' : opts.body).replace(/\s+$/, '');
    var position = opts.position === 'below' ? 'below' : 'above';
    var keepFence = opts.fenced !== false;

    var image = ref ? '![diagram:' + kind + '](' + ref + ')' : '';

    var source = '';
    if (body !== '') {
      if (keepFence) {
        var info = opts.info != null ? opts.info : fenceInfoFor(kind);
        var delim = fenceFor(body);
        source = delim + info + '\n' + body + '\n' + delim;
      } else {
        source = body;
      }
    }

    if (!image) return source;
    if (!source) return image;
    return position === 'above' ? image + '\n\n' + source : source + '\n\n' + image;
  }

  /**
   * Replaces [start, end) of `content` with `text`.
   *
   * Unit boundaries are always line-aligned (unitStart is the first character
   * of a line, unitEnd the last character before its terminator), so a
   * replacement needs no seam fixing at all — the surrounding blank lines are
   * exactly what the user wrote and are preserved byte for byte. Only the two
   * degenerate cases need work: an insertion, which has to supply its own
   * paragraph break, and a deletion, which would otherwise leave a run of
   * blank lines behind.
   */
  function spliceRange(content, start, end, text) {
    var src = String(content == null ? '' : content);
    var before = src.slice(0, start);
    var after = src.slice(end);
    var body = String(text == null ? '' : text);

    if (body === '') {
      var head = before.replace(/\n+$/, '');
      var tail = after.replace(/^\n+/, '');
      if (head === '' || tail === '') return head + tail;
      return head + '\n\n' + tail;
    }

    if (start === end) {
      var padBefore = '';
      if (before !== '' && !/\n\n$/.test(before)) {
        padBefore = /\n$/.test(before) ? '\n' : '\n\n';
      }
      var padAfter = '';
      if (after !== '' && !/^\n\n/.test(after)) {
        padAfter = /^\n/.test(after) ? '\n' : '\n\n';
      }
      return before + padBefore + body + padAfter + after;
    }

    return before + body + after;
  }

  /** Replaces a scanned unit (source + its render) with new markdown. */
  function replaceUnit(content, unit, text) {
    return spliceRange(content, unit.unitStart, unit.unitEnd, text);
  }

  /**
   * Inserts new markdown relative to an existing unit, for "add a diagram
   * here". `where` is 'before' or 'after'; pass unit=null to append at the end
   * of the note.
   */
  function insertRelative(content, unit, where, text) {
    var src = String(content == null ? '' : content);
    if (!unit) {
      var tail = src.replace(/\s+$/, '');
      return tail === '' ? text : tail + '\n\n' + text;
    }
    var at = where === 'before' ? unit.unitStart : unit.unitEnd;
    return spliceRange(src, at, at, text);
  }

  return {
    RENDER_ALT: RENDER_ALT,
    RENDER_LINE: RENDER_LINE,
    TAB_KINDS: TAB_KINDS,
    ASCII_THRESHOLD: ASCII_THRESHOLD,

    indexLines: indexLines,
    parseFenceOpen: parseFenceOpen,
    isFenceClose: isFenceClose,
    scanFences: scanFences,

    asciiArtScore: asciiArtScore,
    looksLikeAsciiArt: looksLikeAsciiArt,
    classify: classify,

    parseRenderLine: parseRenderLine,
    findAdjacentRender: findAdjacentRender,

    scanBlocks: scanBlocks,
    fenceInfoFor: fenceInfoFor,
    fenceFor: fenceFor,
    composeUnit: composeUnit,
    spliceRange: spliceRange,
    replaceUnit: replaceUnit,
    insertRelative: insertRelative,
  };
});
