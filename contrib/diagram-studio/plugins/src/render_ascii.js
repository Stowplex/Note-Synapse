/*
 * ASCII art -> SVG for Diagram Studio.
 *
 * The point of rendering ASCII to an image at all is that the art only holds
 * together in a monospace font: a note rendered in a proportional face turns a
 * carefully aligned box diagram into noise. The SVG pins the grid.
 *
 * Alignment is the whole job, so each line is emitted as one <text> with
 * `xml:space="preserve"` and an explicit `textLength`, which forces character
 * *i* of every line to land at exactly the same x regardless of what monospace
 * face the viewer actually resolves. Without textLength the columns drift as
 * soon as the font's advance width differs from our assumption.
 *
 * Pure string work — no DOM — so it is testable offline.
 */
(function (root, factory) {
  var core = factory();
  if (typeof module === 'object' && module.exports) {
    module.exports = core;
  }
  if (root) {
    root.DiagramAscii = core;
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // Advance width as a fraction of font size. 0.6 is the de-facto monospace
  // ratio (Menlo, DejaVu Sans Mono, Roboto Mono, Consolas all sit at or very
  // near it); textLength corrects any residual difference anyway.
  var ADVANCE_RATIO = 0.6;
  var LINE_RATIO = 1.25;

  var FONT_STACK =
    'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, ' +
    '"Liberation Mono", "Courier New", monospace';

  function escapeXml(text) {
    return String(text == null ? '' : text)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  /** Splits into lines, normalising line endings and expanding tabs. */
  function toLines(text, tabWidth) {
    var width = tabWidth || 4;
    return String(text == null ? '' : text)
      .replace(/\r\n?/g, '\n')
      .split('\n')
      .map(function (line) {
        // Tabs would break the character grid entirely.
        var out = '';
        for (var i = 0; i < line.length; i++) {
          if (line.charAt(i) === '\t') {
            var pad = width - (out.length % width);
            out += new Array(pad + 1).join(' ');
          } else {
            out += line.charAt(i);
          }
        }
        return out;
      });
  }

  /** Trims blank lines from both ends without touching interior blanks. */
  function trimBlankEdges(lines) {
    var from = 0;
    var to = lines.length - 1;
    while (from <= to && lines[from].trim() === '') from++;
    while (to >= from && lines[to].trim() === '') to--;
    return to < from ? [] : lines.slice(from, to + 1);
  }

  /** Grid dimensions of the art: widest line and number of rows. */
  function measure(text, tabWidth) {
    var lines = trimBlankEdges(toLines(text, tabWidth));
    var cols = 0;
    for (var i = 0; i < lines.length; i++) {
      var len = lines[i].replace(/\s+$/, '').length;
      if (len > cols) cols = len;
    }
    return { rows: lines.length, cols: cols, lines: lines };
  }

  /**
   * Right-pads every line to the same width. Offered to the editor as a
   * "normalise" action — trailing-space differences are invisible while
   * editing but shift how the art reads once it is fenced.
   */
  function padLines(text, tabWidth) {
    var m = measure(text, tabWidth);
    return m.lines
      .map(function (line) {
        var trimmed = line.replace(/\s+$/, '');
        return trimmed + new Array(m.cols - trimmed.length + 1).join(' ');
      })
      .join('\n');
  }

  /**
   * Renders ASCII art to an SVG string.
   *
   * opts: {fontSize, color, background, padding, tabWidth}
   */
  function asciiToSvg(text, opts) {
    var options = opts || {};
    var fontSize = options.fontSize || 14;
    var color = options.color || '#e0e0e0';
    var background = options.background || '#282c34';
    var padding = options.padding == null ? 12 : options.padding;

    var m = measure(text, options.tabWidth);
    var advance = fontSize * ADVANCE_RATIO;
    var lineHeight = fontSize * LINE_RATIO;

    var width = Math.max(1, Math.round(m.cols * advance + padding * 2));
    var height = Math.max(1, Math.round(m.rows * lineHeight + padding * 2));

    var parts = [];
    parts.push(
      '<svg xmlns="http://www.w3.org/2000/svg" width="' + width + '" height="' + height +
        '" viewBox="0 0 ' + width + ' ' + height + '" preserveAspectRatio="xMidYMid meet">'
    );
    parts.push('<rect x="0" y="0" width="100%" height="100%" fill="' + escapeXml(background) + '"/>');
    parts.push(
      '<g font-family="' + escapeXml(FONT_STACK) + '" font-size="' + fontSize +
        '" fill="' + escapeXml(color) + '" xml:space="preserve">'
    );

    for (var i = 0; i < m.lines.length; i++) {
      var line = m.lines[i].replace(/\s+$/, '');
      if (line === '') continue;
      // Baseline sits a little below the line box top; 0.8em is the usual
      // cap-height offset for a monospace face.
      var y = padding + i * lineHeight + fontSize * 0.8;
      // textLength pins the run to an exact multiple of the advance width, so
      // columns line up no matter which monospace face resolves.
      var textLength = (line.length * advance).toFixed(3);
      parts.push(
        '<text x="' + padding + '" y="' + y.toFixed(3) + '" textLength="' + textLength +
          '" lengthAdjust="spacing">' + escapeXml(line) + '</text>'
      );
    }

    parts.push('</g>');
    parts.push('</svg>');
    return parts.join('');
  }

  return {
    ADVANCE_RATIO: ADVANCE_RATIO,
    LINE_RATIO: LINE_RATIO,
    FONT_STACK: FONT_STACK,
    escapeXml: escapeXml,
    toLines: toLines,
    trimBlankEdges: trimBlankEdges,
    measure: measure,
    padLines: padLines,
    asciiToSvg: asciiToSvg,
  };
});
