/*
 * Formula Studio's Markdown math scanner and mutation primitives.
 *
 * This module deliberately has no DOM or Synapse dependency so it can be
 * exhaustively tested under Node. Offsets are UTF-16 string offsets, matching
 * JavaScript substring() and the content handed to User Apps.
 */
(function (root, factory) {
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.FormulaCore = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var ANCHOR_LENGTH = 48;

  function indexLines(source) {
    var lines = [];
    var start = 0;
    while (start < source.length) {
      var nl = source.indexOf('\n', start);
      var next = nl === -1 ? source.length : nl + 1;
      var end = nl === -1 ? source.length : (nl > start && source[nl - 1] === '\r' ? nl - 1 : nl);
      lines.push({ start: start, end: end, next: next, text: source.slice(start, end) });
      start = next;
    }
    if (!source.length) lines.push({ start: 0, end: 0, next: 0, text: '' });
    return lines;
  }

  function escapeRegex(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  function fencedCodeRanges(source) {
    var lines = indexLines(source);
    var ranges = [];
    var open = null;
    for (var k = 0; k < lines.length; k++) {
      var line = lines[k];
      if (!open) {
        var opener = /^( {0,3})(`{3,}|~{3,})(.*)$/.exec(line.text);
        if (!opener || (opener[2][0] === '`' && opener[3].indexOf('`') !== -1)) continue;
        open = {
          start: line.start,
          marker: opener[2][0],
          length: opener[2].length,
        };
        continue;
      }
      var close = new RegExp(
        '^ {0,3}' + escapeRegex(open.marker) + '{' + open.length + ',}[ \\t]*$'
      );
      if (close.test(line.text)) {
        ranges.push({ start: open.start, end: line.next });
        open = null;
      }
    }
    if (open) ranges.push({ start: open.start, end: source.length });
    return ranges;
  }

  function containsOffset(ranges, offset) {
    for (var i = 0; i < ranges.length; i++) {
      if (offset < ranges[i].start) return false;
      if (offset >= ranges[i].start && offset < ranges[i].end) return true;
    }
    return false;
  }

  function codeRanges(source) {
    var ranges = fencedCodeRanges(source);
    var i = 0;
    while (i < source.length) {
      if (containsOffset(ranges, i) || source[i] !== '`') {
        i++;
        continue;
      }
      var run = 1;
      while (source[i + run] === '`') run++;
      var marker = source.slice(i, i + run);
      var close = source.indexOf(marker, i + run);
      while (close !== -1 && containsOffset(ranges, close)) {
        close = source.indexOf(marker, close + run);
      }
      if (close === -1) {
        i += run;
        continue;
      }
      ranges.push({ start: i, end: close + run });
      ranges.sort(function (a, b) { return a.start - b.start; });
      i = close + run;
    }
    return ranges;
  }

  function isEscaped(source, offset) {
    var slashes = 0;
    for (var i = offset - 1; i >= 0 && source[i] === '\\'; i--) slashes++;
    return slashes % 2 === 1;
  }

  function findDelimiter(source, delimiter, from, protectedRanges, sameLine) {
    var offset = source.indexOf(delimiter, from);
    while (offset !== -1) {
      if (sameLine && source.slice(from, offset).indexOf('\n') !== -1) return -1;
      if (!containsOffset(protectedRanges, offset) && !isEscaped(source, offset)) return offset;
      offset = source.indexOf(delimiter, offset + delimiter.length);
    }
    return -1;
  }

  function contextAt(source, start, end) {
    var lineStart = source.lastIndexOf('\n', Math.max(0, start - 1)) + 1;
    var lineEnd = source.indexOf('\n', end);
    if (lineEnd === -1) lineEnd = source.length;
    var text = source.slice(lineStart, lineEnd).replace(/\s+/g, ' ').trim();
    if (text.length > 96) text = text.slice(0, 93) + '…';
    return text;
  }

  function makeUnit(source, start, end, bodyStart, bodyEnd, kind, delimiter, legacy) {
    var inside = source.slice(bodyStart, bodyEnd);
    var leading = (/^\s*/.exec(inside) || [''])[0];
    var trailing = (/\s*$/.exec(inside) || [''])[0];
    var bodyEndWithoutPadding = Math.max(leading.length, inside.length - trailing.length);
    var body = inside.slice(leading.length, bodyEndWithoutPadding);
    return {
      index: -1,
      start: start,
      end: end,
      bodyStart: bodyStart,
      bodyEnd: bodyEnd,
      raw: source.slice(start, end),
      body: body,
      kind: kind,
      delimiter: delimiter,
      leadingPadding: leading,
      trailingPadding: trailing,
      legacy: !!legacy,
      context: contextAt(source, start, end),
    };
  }

  /**
   * Scan editable note math.
   *
   * Canonical `\\(...\\)` and `\\[...\\]` are always recognized. Legacy
   * `$$...$$` is recognized globally. Single-dollar math is opt-in and should
   * only be enabled for an explicitly selected block or paragraph.
   */
  function scanFormulas(source, options) {
    source = String(source == null ? '' : source);
    options = options || {};
    var protectedRanges = codeRanges(source);
    var units = [];
    var i = 0;

    while (i < source.length) {
      if (containsOffset(protectedRanges, i)) {
        i++;
        continue;
      }

      var close;
      if (source.slice(i, i + 2) === '\\(' && !isEscaped(source, i)) {
        close = findDelimiter(source, '\\)', i + 2, protectedRanges, false);
        if (close !== -1) {
          units.push(makeUnit(source, i, close + 2, i + 2, close, 'inline', 'paren', false));
          i = close + 2;
          continue;
        }
      }

      if (source.slice(i, i + 2) === '\\[' && !isEscaped(source, i)) {
        close = findDelimiter(source, '\\]', i + 2, protectedRanges, false);
        if (close !== -1) {
          units.push(makeUnit(source, i, close + 2, i + 2, close, 'display', 'bracket', false));
          i = close + 2;
          continue;
        }
      }

      if (source.slice(i, i + 2) === '$$' && !isEscaped(source, i)) {
        close = findDelimiter(source, '$$', i + 2, protectedRanges, false);
        if (close !== -1 && source.slice(i + 2, close).trim()) {
          units.push(makeUnit(source, i, close + 2, i + 2, close, 'display', 'doubleDollar', true));
          i = close + 2;
          continue;
        }
      }

      if (options.legacySingleDollar &&
          source[i] === '$' &&
          source[i - 1] !== '$' &&
          source[i + 1] !== '$' &&
          !isEscaped(source, i)) {
        close = findDelimiter(source, '$', i + 1, protectedRanges, true);
        while (close !== -1 && (source[close - 1] === '$' || source[close + 1] === '$')) {
          close = findDelimiter(source, '$', close + 1, protectedRanges, true);
        }
        if (close !== -1) {
          var singleBody = source.slice(i + 1, close);
          if (singleBody &&
              singleBody.trim() === singleBody &&
              singleBody.indexOf('\n') === -1) {
            units.push(makeUnit(source, i, close + 1, i + 1, close, 'inline', 'dollar', true));
            i = close + 1;
            continue;
          }
        }
      }
      i++;
    }

    for (var u = 0; u < units.length; u++) units[u].index = u;
    return units;
  }

  function delimiterFor(kind) {
    return kind === 'inline'
      ? { open: '\\(', close: '\\)' }
      : { open: '\\[', close: '\\]' };
  }

  function serializeFormula(body, kind, original) {
    body = String(body == null ? '' : body).trim();
    if (!body) return '';
    kind = kind === 'inline' ? 'inline' : 'display';
    var delimiters = delimiterFor(kind);
    if (original &&
        !original.legacy &&
        original.kind === kind &&
        (original.delimiter === 'paren' || original.delimiter === 'bracket')) {
      return delimiters.open +
        (original.leadingPadding || '') +
        body +
        (original.trailingPadding || '') +
        delimiters.close;
    }
    if (kind === 'inline') return delimiters.open + body + delimiters.close;
    return delimiters.open + '\n' + body + '\n' + delimiters.close;
  }

  function replaceRange(source, start, end, replacement) {
    return source.slice(0, start) + replacement + source.slice(end);
  }

  function appendDisplayFormula(source, body) {
    var formula = serializeFormula(body, 'display', null);
    if (!formula) return source;
    if (!source) return formula;
    if (/\n\n$/.test(source)) return source + formula;
    if (/\n$/.test(source)) return source + '\n' + formula;
    return source + '\n\n' + formula;
  }

  /**
   * Replaces a formula and inserts a separate display statement below its
   * containing paragraph. For an inline formula this keeps the rest of the
   * paragraph together instead of splitting it at the formula offset.
   */
  function replaceWithDisplayBelow(source, unit, replacement, belowBody) {
    var below = serializeFormula(belowBody, 'display', null);
    var next = replaceRange(source, unit.start, unit.end, replacement);
    if (!below) return next;
    var originalInsertion = source.indexOf('\n\n', unit.end);
    if (unit.kind !== 'inline' || originalInsertion === -1) {
      originalInsertion = unit.kind === 'inline' ? source.length : unit.end;
    }
    var delta = replacement.length - (unit.end - unit.start);
    var insertion = originalInsertion + delta;
    return next.slice(0, insertion) + '\n\n' + below + next.slice(insertion);
  }

  function createTarget(source, unit) {
    return {
      mode: 'existing',
      originalOffset: unit.start,
      raw: unit.raw,
      delimiter: unit.delimiter,
      kind: unit.kind,
      legacySingleDollar: unit.delimiter === 'dollar',
      anchorBefore: source.slice(Math.max(0, unit.start - ANCHOR_LENGTH), unit.start),
      anchorAfter: source.slice(unit.end, unit.end + ANCHOR_LENGTH),
    };
  }

  function commonSuffix(a, b) {
    var count = 0;
    while (count < a.length && count < b.length &&
        a[a.length - 1 - count] === b[b.length - 1 - count]) count++;
    return count;
  }

  function commonPrefix(a, b) {
    var count = 0;
    while (count < a.length && count < b.length && a[count] === b[count]) count++;
    return count;
  }

  function relocateTarget(source, target) {
    var units = scanFormulas(source, {
      legacySingleDollar: !!target.legacySingleDollar,
    });
    var candidates = units.filter(function (unit) {
      return unit.raw === target.raw && unit.delimiter === target.delimiter;
    });
    if (!candidates.length) return { ok: false, reason: 'not-found' };

    for (var i = 0; i < candidates.length; i++) {
      if (candidates[i].start === target.originalOffset) {
        return { ok: true, unit: candidates[i], relocated: false };
      }
    }
    if (candidates.length === 1) {
      return { ok: true, unit: candidates[0], relocated: true };
    }

    var ranked = candidates.map(function (unit) {
      var before = source.slice(Math.max(0, unit.start - ANCHOR_LENGTH), unit.start);
      var after = source.slice(unit.end, unit.end + ANCHOR_LENGTH);
      return {
        unit: unit,
        anchorScore:
          commonSuffix(target.anchorBefore || '', before) +
          commonPrefix(target.anchorAfter || '', after),
        distance: Math.abs(unit.start - target.originalOffset),
      };
    }).sort(function (a, b) {
      return b.anchorScore - a.anchorScore || a.distance - b.distance;
    });

    if (!ranked[0].anchorScore) return { ok: false, reason: 'ambiguous' };
    if (ranked[1] &&
        ranked[0].anchorScore === ranked[1].anchorScore &&
        ranked[0].distance === ranked[1].distance) {
      return { ok: false, reason: 'ambiguous' };
    }
    return { ok: true, unit: ranked[0].unit, relocated: true };
  }

  function formulaPreview(unit) {
    var text = unit.body.replace(/\s+/g, ' ').trim();
    if (!text) return '(empty formula)';
    return text.length > 72 ? text.slice(0, 69) + '…' : text;
  }

  return {
    ANCHOR_LENGTH: ANCHOR_LENGTH,
    indexLines: indexLines,
    codeRanges: codeRanges,
    scanFormulas: scanFormulas,
    serializeFormula: serializeFormula,
    replaceRange: replaceRange,
    appendDisplayFormula: appendDisplayFormula,
    replaceWithDisplayBelow: replaceWithDisplayBelow,
    createTarget: createTarget,
    relocateTarget: relocateTarget,
    formulaPreview: formulaPreview,
  };
});
