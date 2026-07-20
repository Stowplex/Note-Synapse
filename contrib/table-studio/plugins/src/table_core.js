/*
 * Table Studio core — pure data logic shared by the plugin UI and the
 * offline test suite (dev/run_core_tests.mjs). No DOM, no Synapse calls.
 *
 * Covers:
 *   - scanning GitHub-flavored-markdown pipe tables out of note content
 *     (fence-aware, so tables inside ``` code blocks are never touched)
 *   - serializing a grid back to a pretty-printed GFM table
 *   - RFC 4180 CSV/TSV parsing and serialization that preserves the
 *     original delimiter, line endings, BOM and trailing newline
 *   - small grid utilities (rectangular normalization, column labels)
 */
(function (root, factory) {
  var core = factory();
  if (typeof module === 'object' && module.exports) {
    module.exports = core;
  }
  if (root) {
    root.TableCore = core;
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // ---------------------------------------------------------------------
  // Markdown pipe tables
  // ---------------------------------------------------------------------

  /** True when the line contains at least one pipe that is not backslash-escaped. */
  function hasUnescapedPipe(line) {
    for (var i = 0; i < line.length; i++) {
      var ch = line[i];
      if (ch === '\\') {
        i++; // skip the escaped character
      } else if (ch === '|') {
        return true;
      }
    }
    return false;
  }

  /**
   * Splits one markdown table row into trimmed cell strings, honoring
   * backslash-escaped pipes and dropping the optional outer pipes.
   */
  function splitPipeRow(line) {
    var s = line.trim();
    if (s.startsWith('|')) {
      s = s.slice(1);
    }
    var cells = [];
    var cur = '';
    for (var i = 0; i < s.length; i++) {
      var ch = s[i];
      if (ch === '\\' && i + 1 < s.length) {
        cur += ch + s[i + 1];
        i++;
      } else if (ch === '|') {
        cells.push(cur.trim());
        cur = '';
      } else {
        cur += ch;
      }
    }
    var last = cur.trim();
    // A trailing outer pipe leaves one empty final segment; drop it.
    if (last !== '' || cells.length === 0) {
      cells.push(last);
    }
    return cells;
  }

  var DELIMITER_CELL = /^:?-+:?$/;

  /** True when the line is a GFM header/body delimiter row (| --- | :-: |). */
  function isDelimiterRow(line) {
    var s = line.trim();
    if (s === '' || s.indexOf('-') === -1 || s.indexOf('|') === -1) {
      return false;
    }
    if (!/^[|:\s-]+$/.test(s)) {
      return false;
    }
    var cells = splitPipeRow(line);
    if (cells.length === 0) {
      return false;
    }
    for (var i = 0; i < cells.length; i++) {
      if (!DELIMITER_CELL.test(cells[i])) {
        return false;
      }
    }
    return true;
  }

  /** 'left' | 'center' | 'right' | null (default) from one delimiter cell. */
  function parseAlign(cell) {
    var left = cell.startsWith(':');
    var right = cell.endsWith(':');
    if (left && right) return 'center';
    if (right) return 'right';
    if (left) return 'left';
    return null;
  }

  /** Converts a stored markdown cell into editable plain text. */
  function decodeMdCell(cell) {
    return cell
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/\\\|/g, '|');
  }

  /** Converts editable plain text back into a markdown-safe cell. */
  function encodeMdCell(text) {
    return String(text == null ? '' : text)
      .replace(/\|/g, '\\|')
      .replace(/\r\n?/g, '\n')
      .replace(/\n/g, '<br>');
  }

  var FENCE_RE = /^ {0,3}(`{3,}|~{3,})(.*)$/;

  /**
   * Scans markdown content for GFM pipe tables, skipping fenced code blocks.
   *
   * Returns an array of:
   *   {
   *     startLine, endLine,   // [startLine, endLine) into content.split('\n')
   *     raw,                  // the exact source text of the table block
   *     indent,               // leading whitespace of the header line
   *     aligns,               // per-column alignment (null|'left'|'center'|'right')
   *     grid                  // rectangular string[][] — row 0 is the header
   *   }
   *
   * Cells in `grid` are decoded for editing (\| -> |, <br> -> newline).
   * Body rows wider than the header extend the grid instead of being cut,
   * so no source data is silently dropped.
   */
  function scanTables(content) {
    var lines = String(content == null ? '' : content).split('\n');
    var tables = [];
    var inFence = false;
    var fenceChar = '';
    var fenceLen = 0;

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      var fm = FENCE_RE.exec(line);
      if (inFence) {
        if (
          fm &&
          fm[1][0] === fenceChar &&
          fm[1].length >= fenceLen &&
          fm[2].trim() === ''
        ) {
          inFence = false;
        }
        continue;
      }
      if (fm) {
        // The info string of a backtick fence cannot contain backticks.
        if (fm[1][0] === '~' || fm[2].indexOf('`') === -1) {
          inFence = true;
          fenceChar = fm[1][0];
          fenceLen = fm[1].length;
          continue;
        }
      }

      if (!hasUnescapedPipe(line) || i + 1 >= lines.length) {
        continue;
      }
      if (!isDelimiterRow(lines[i + 1])) {
        continue;
      }
      var header = splitPipeRow(line);
      var delim = splitPipeRow(lines[i + 1]);
      if (header.length !== delim.length) {
        continue;
      }

      var aligns = delim.map(parseAlign);
      var rows = [header];
      var j = i + 2;
      for (; j < lines.length; j++) {
        var body = lines[j];
        if (body.trim() === '' || !hasUnescapedPipe(body)) {
          break;
        }
        if (FENCE_RE.test(body)) {
          break;
        }
        rows.push(splitPipeRow(body));
      }

      var indentMatch = /^\s*/.exec(line);
      var grid = rows.map(function (r) {
        return r.map(decodeMdCell);
      });
      normalizeGrid(grid);
      while (aligns.length < grid[0].length) {
        aligns.push(null);
      }

      tables.push({
        startLine: i,
        endLine: j,
        raw: lines.slice(i, j).join('\n'),
        indent: indentMatch ? indentMatch[0] : '',
        aligns: aligns,
        grid: grid,
      });
      i = j - 1;
    }
    return tables;
  }

  /** Visual width used for column padding (wide CJK glyphs count double). */
  function displayWidth(s) {
    var w = 0;
    for (var i = 0; i < s.length; i++) {
      var code = s.codePointAt(i);
      if (code > 0xffff) {
        i++;
      }
      w += code >= 0x1100 &&
        (code <= 0x115f ||
          (code >= 0x2e80 && code <= 0xa4cf) ||
          (code >= 0xac00 && code <= 0xd7a3) ||
          (code >= 0xf900 && code <= 0xfaff) ||
          (code >= 0xfe30 && code <= 0xfe4f) ||
          (code >= 0xff00 && code <= 0xff60) ||
          (code >= 0xffe0 && code <= 0xffe6) ||
          (code >= 0x20000 && code <= 0x3fffd))
        ? 2
        : 1;
    }
    return w;
  }

  function padCell(text, width, align) {
    var pad = width - displayWidth(text);
    if (pad <= 0) {
      return text;
    }
    if (align === 'right') {
      return ' '.repeat(pad) + text;
    }
    if (align === 'center') {
      var leftPad = Math.floor(pad / 2);
      return ' '.repeat(leftPad) + text + ' '.repeat(pad - leftPad);
    }
    return text + ' '.repeat(pad);
  }

  function delimiterCell(align, width) {
    var w = Math.max(3, width);
    if (align === 'center') {
      return ':' + '-'.repeat(w - 2) + ':';
    }
    if (align === 'right') {
      return '-'.repeat(w - 1) + ':';
    }
    if (align === 'left') {
      return ':' + '-'.repeat(w - 1);
    }
    return '-'.repeat(w);
  }

  /**
   * Serializes a grid (row 0 = header) into a pretty-printed GFM table.
   * Returns the table text without a trailing newline.
   */
  function serializeTable(grid, aligns, indent) {
    var rect = grid.map(function (r) {
      return r.slice();
    });
    normalizeGrid(rect);
    var cols = rect[0].length;
    var encoded = rect.map(function (row) {
      return row.map(encodeMdCell);
    });

    var widths = [];
    for (var c = 0; c < cols; c++) {
      var w = 3;
      for (var r = 0; r < encoded.length; r++) {
        w = Math.max(w, displayWidth(encoded[r][c]));
      }
      widths.push(w);
    }

    var prefix = indent || '';
    var out = [];
    for (var r2 = 0; r2 < encoded.length; r2++) {
      var cells = [];
      for (var c2 = 0; c2 < cols; c2++) {
        cells.push(padCell(encoded[r2][c2], widths[c2], aligns[c2] || null));
      }
      out.push(prefix + '| ' + cells.join(' | ') + ' |');
      if (r2 === 0) {
        var delims = [];
        for (var c3 = 0; c3 < cols; c3++) {
          delims.push(delimiterCell(aligns[c3] || null, widths[c3]));
        }
        out.push(prefix + '| ' + delims.join(' | ') + ' |');
      }
    }
    return out.join('\n');
  }

  // ---------------------------------------------------------------------
  // Delimited text (CSV / TSV)
  // ---------------------------------------------------------------------

  /**
   * Picks the delimiter for a text file: extension wins for .tsv/.tab,
   * otherwise the most frequent of , ; \t outside quoted regions in the
   * first ~10 lines (comma on a tie / when nothing is found).
   */
  function sniffDelimiter(text, ext) {
    var e = String(ext || '').toLowerCase();
    if (e === 'tsv' || e === 'tab') {
      return '\t';
    }
    var counts = { ',': 0, ';': 0, '\t': 0 };
    var inQuotes = false;
    var newlines = 0;
    for (var i = 0; i < text.length && newlines < 10; i++) {
      var ch = text[i];
      if (inQuotes) {
        if (ch === '"') {
          if (text[i + 1] === '"') {
            i++;
          } else {
            inQuotes = false;
          }
        }
      } else if (ch === '"') {
        inQuotes = true;
      } else if (ch === '\n') {
        newlines++;
      } else if (Object.prototype.hasOwnProperty.call(counts, ch)) {
        counts[ch]++;
      }
    }
    var best = ',';
    if (counts[';'] > counts[best]) best = ';';
    if (counts['\t'] > counts[best]) best = '\t';
    return best;
  }

  /**
   * RFC 4180 parser.
   * Returns { rows, delim, lineEnding, hadBom, trailingNewline }.
   */
  function parseDelimited(text, delim) {
    var s = String(text == null ? '' : text);
    var hadBom = s.charCodeAt(0) === 0xfeff;
    if (hadBom) {
      s = s.slice(1);
    }

    var rows = [];
    var row = [];
    var cur = '';
    var inQuotes = false;
    var lineEnding = null;
    var endedWithNewline = false;

    function endCell() {
      row.push(cur);
      cur = '';
    }
    function endRow() {
      endCell();
      rows.push(row);
      row = [];
    }

    for (var i = 0; i < s.length; i++) {
      var ch = s[i];
      if (inQuotes) {
        if (ch === '"') {
          if (s[i + 1] === '"') {
            cur += '"';
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          cur += ch;
        }
        continue;
      }
      if (ch === '"' && cur === '') {
        inQuotes = true;
      } else if (ch === delim) {
        endCell();
      } else if (ch === '\r' || ch === '\n') {
        var ending = ch === '\r' && s[i + 1] === '\n' ? '\r\n' : ch;
        if (ending === '\r\n') {
          i++;
        }
        if (lineEnding === null) {
          lineEnding = ending;
        }
        endRow();
        endedWithNewline = i === s.length - 1;
      } else {
        cur += ch;
      }
    }
    if (!endedWithNewline && s.length > 0) {
      endRow();
    }
    if (rows.length === 0) {
      rows.push(['']);
    }
    normalizeGrid(rows);
    return {
      rows: rows,
      delim: delim,
      lineEnding: lineEnding || '\n',
      hadBom: hadBom,
      trailingNewline: endedWithNewline,
    };
  }

  /** Serializes rows with RFC 4180 quoting, honoring the parse metadata. */
  function serializeDelimited(rows, meta) {
    var delim = meta.delim || ',';
    var eol = meta.lineEnding || '\n';
    var needsQuote = new RegExp('["\r\n' + (delim === '\t' ? '\\t' : delim) + ']');
    var lines = rows.map(function (row) {
      return row
        .map(function (cell) {
          var v = String(cell == null ? '' : cell);
          if (needsQuote.test(v)) {
            return '"' + v.replace(/"/g, '""') + '"';
          }
          return v;
        })
        .join(delim);
    });
    var body = lines.join(eol);
    if (meta.trailingNewline) {
      body += eol;
    }
    return (meta.hadBom ? '﻿' : '') + body;
  }

  // ---------------------------------------------------------------------
  // Grid utilities
  // ---------------------------------------------------------------------

  /**
   * Makes the grid rectangular in place (pads short rows with '') and
   * coerces every cell to a string. Guarantees at least a 1x1 grid.
   */
  function normalizeGrid(grid) {
    if (grid.length === 0) {
      grid.push(['']);
    }
    var cols = 1;
    for (var r = 0; r < grid.length; r++) {
      cols = Math.max(cols, grid[r].length);
    }
    for (var r2 = 0; r2 < grid.length; r2++) {
      var row = grid[r2];
      for (var c = 0; c < cols; c++) {
        row[c] = row[c] == null ? '' : String(row[c]);
      }
      row.length = cols;
    }
    return grid;
  }

  /** 0 -> A, 25 -> Z, 26 -> AA ... */
  function colLabel(index) {
    var n = index;
    var label = '';
    do {
      label = String.fromCharCode(65 + (n % 26)) + label;
      n = Math.floor(n / 26) - 1;
    } while (n >= 0);
    return label;
  }

  /** True when a string can be safely stored as a spreadsheet number. */
  function looksNumeric(s) {
    return /^-?(\d+\.?\d*|\.\d+)(e[+-]?\d+)?$/i.test(s.trim()) &&
      s.trim().length <= 15;
  }

  return {
    hasUnescapedPipe: hasUnescapedPipe,
    splitPipeRow: splitPipeRow,
    isDelimiterRow: isDelimiterRow,
    parseAlign: parseAlign,
    decodeMdCell: decodeMdCell,
    encodeMdCell: encodeMdCell,
    scanTables: scanTables,
    serializeTable: serializeTable,
    sniffDelimiter: sniffDelimiter,
    parseDelimited: parseDelimited,
    serializeDelimited: serializeDelimited,
    normalizeGrid: normalizeGrid,
    colLabel: colLabel,
    looksNumeric: looksNumeric,
    displayWidth: displayWidth,
  };
});
