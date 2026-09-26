/*
 * Gantt - the chart region of a chart note.
 *
 *   region := [embedLine NL NL] [mirror NL NL] fence      (never ends with NL)
 *
 * The fence holds the chart JSON, one group or task per line. The mirror is
 * a generated, readable list of note links above it; state never comes from
 * it. The embed line shows the chart inline in the note. Plan §5.6 is the
 * single definition of the grammar: region() writes exactly it and read()
 * detects exactly it. Every byte outside the region belongs to the user.
 *
 * Lines split on \n; a trailing \r is ignored for matching and kept in the
 * text. A synapse-gantt fence nested inside a wider fence is documentation.
 */
(function (global) {
  'use strict';
  var GT = (global.GT = global.GT || {});
  var B = (GT.block = {});

  B.INFO = 'synapse-gantt';
  B.V = 1;
  B.EMBED_H = 420;

  function M() { return GT.model; }
  // GT.APP_UUID is defined by host.js. Without it no embed line is written
  // or recognised.
  function uuid() { return typeof GT.APP_UUID === 'string' && /^[0-9a-f-]+$/.test(GT.APP_UUID) ? GT.APP_UUID : null; }

  /* ----------------------------------------------------------------- lines */

  function lines(src) {
    var out = [], i = 0, n = src.length;
    for (;;) {
      var j = src.indexOf('\n', i);
      var stop = j < 0 ? n : j;
      var end = (stop > i && src.charAt(stop - 1) === '\r') ? stop - 1 : stop;
      out.push({ start: i, end: end, next: j < 0 ? n : j + 1 });
      if (j < 0) break;
      i = j + 1;
    }
    return out;
  }
  function blank(s) { return !/\S/.test(s); }

  // CommonMark opening fence: up to 3 spaces, 3+ backticks or tildes, then an
  // info string (no backtick in it for a backtick fence). The first word of
  // the info string names the language.
  var OPEN = /^ {0,3}(`{3,}|~{3,})(.*)$/;
  function opening(line) {
    var m = OPEN.exec(line);
    if (!m) return null;
    if (m[1].charAt(0) === '`' && m[2].indexOf('`') >= 0) return null;
    var info = m[2].trim().split(/[ \t]+/)[0] || '';
    return { ch: m[1].charAt(0), len: m[1].length, info: info };
  }
  B.opening = opening;

  function closes(line, open) {
    var k = 0;
    while (k < 3 && line.charAt(k) === ' ') k++;
    var c = 0;
    while (line.charAt(k + c) === open.ch) c++;
    if (c < open.len) return false;
    return /^[ \t]*$/.test(line.slice(k + c));
  }
  B.closes = closes;

  // A line that could belong to hand-edited JSON: structure, a string, a
  // number or a literal at its start, a key (quoted or not) followed by a
  // value, or a // comment. A numbered list item, a markdown link, a bare
  // checkbox (`[ ] task`) and digits followed by words (`2026 goals`, `3rd`)
  // are prose.
  var JSONISH = /^\s*([{}[\],":]|-?\d|true\b|false\b|null\b|\/\/|'[^']*'\s*:|[A-Za-z_$][\w$]*\s*:\s*([{[\]"'\d-]|true\b|false\b|null\b))/;
  var PROSE = /^\s*(\d+[.)](\s|$)|\[[^\]]*\]\(|\[[ xX]\][ \t]+\S|\d+[ \t]+[^\d\s,\]}.]|\d+[^\d\s,\]}.:eE+-])/;
  function jsonish(line) { return JSONISH.test(line) && !PROSE.test(line); }
  B.jsonish = jsonish;

  /*
   * Where a chart fence that is not properly closed ends: at the last blank
   * line before the first line that follows a blank line and is plainly not
   * JSON, so a blank line inside the JSON does not cut it short. With no such
   * line it ends before the first blank line (Big Bang's rule). Looks at
   * lines i+1..stop; returns {last, stray}: the span's last line, and
   * whether a prose line was found.
   */
  function boundAt(src, ls, i, stop) {
    var firstBlank = -1, lastBlank = -1;
    for (var j = i + 1; j <= stop; j++) {
      var s = src.slice(ls[j].start, ls[j].end);
      if (blank(s)) { if (firstBlank < 0) firstBlank = j; lastBlank = j; continue; }
      if (lastBlank >= 0 && !jsonish(s)) return { last: lastBlank - 1, stray: true };
    }
    return { last: firstBlank >= 0 ? firstBlank - 1 : stop, stray: false };
  }
  function boundUnclosed(src, ls, i) { return boundAt(src, ls, i, ls.length - 1).last; }

  function makeSpan(src, ls, i, j, closed) {
    var bodyStart = Math.min(src.length, ls[i].next);
    var bodyEnd = closed ? ls[j].start : ls[j].end;
    if (bodyEnd < bodyStart) bodyEnd = bodyStart;
    return { line: i, lastLine: j, start: ls[i].start, end: ls[j].end, closed: closed,
      body: src.slice(bodyStart, bodyEnd) };
  }

  // Every top-level synapse-gantt fence, in order, plus nested ones counted.
  B.scan = function (text) {
    var src = String(text == null ? '' : text);
    var ls = lines(src), out = [], open = null, shadowed = 0;
    for (var i = 0; i < ls.length; i++) {
      var line = src.slice(ls[i].start, ls[i].end);
      if (open) {
        if (closes(line, open)) {
          if (open.chart) out.push(makeSpan(src, ls, open.i, i, true));
          open = null;
        } else {
          var mm = opening(line);
          if (mm && mm.info === B.INFO) shadowed++;
        }
        continue;
      }
      var m = opening(line);
      if (!m) continue;
      open = { ch: m.ch, len: m.len, i: i, chart: m.info === B.INFO };
    }
    if (open && open.chart) out.push(makeSpan(src, ls, open.i, boundUnclosed(src, ls, open.i), false));
    return { spans: out, shadowed: shadowed, openAtEnd: !!open && !open.chart, lines: ls, src: src };
  };

  /* ------------------------------------------------------------ key, hash */

  // Whitespace outside JSON strings is insignificant (Big Bang bodyKey).
  B.key = function (body) {
    var s = String(body == null ? '' : body);
    var out = [], i = 0, n = s.length, inStr = false;
    while (i < n) {
      var c = s.charAt(i);
      if (inStr) {
        out.push(c);
        if (c === '\\') { if (i + 1 < n) out.push(s.charAt(i + 1)); i += 2; continue; }
        if (c === '"') inStr = false;
        i++;
        continue;
      }
      if (c === ' ' || c === '\t' || c === '\n' || c === '\r' || c === '\f' || c === '\v') { i++; continue; }
      if (c === '"') inStr = true;
      out.push(c);
      i++;
    }
    return out.join('');
  };

  // FNV-1a over UTF-16 code units, 8 hex digits.
  B.hash = function (str) {
    var s = String(str == null ? '' : str), h = 0x811c9dc5;
    for (var i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 0x01000193) >>> 0;
    }
    return ('0000000' + h.toString(16)).slice(-8);
  };

  /* ------------------------------------------------------------- serialise */

  // The fence body: canonical JSON, one group or task per line.
  B.serialize = function (chart) {
    var d = M().toData(chart);
    var out = '{"v":' + JSON.stringify(d.v);
    if (d.settings) out += ',\n"settings":' + JSON.stringify(d.settings);
    ['groups', 'tasks'].forEach(function (k) {
      if (!d[k]) return;
      out += ',\n"' + k + '":[\n' + d[k].map(function (x) { return ' ' + JSON.stringify(x); }).join(',\n') + '\n]';
    });
    Object.keys(d).forEach(function (k) {
      if (k === 'v' || k === 'settings' || k === 'groups' || k === 'tasks') return;
      out += ',\n' + JSON.stringify(k) + ':' + JSON.stringify(d[k]);
    });
    return out + '}';
  };

  B.fence = function (chart) { return '```' + B.INFO + '\n' + B.serialize(chart) + '\n```'; };

  /* ---------------------------------------------------------------- mirror */

  // Only what breaks the parse changes: CR/LF become spaces, unbalanced
  // brackets become fullwidth. No backslashes (the renderer shows them).
  B.etext = function (title) {
    var s = String(title == null ? '' : title).replace(/\r\n|\r|\n/g, ' ');
    var chars = s.split(''), open = [];
    for (var i = 0; i < chars.length; i++) {
      if (chars[i] === '[') open.push(i);
      else if (chars[i] === ']') { if (open.length) open.pop(); else chars[i] = '］'; }
    }
    open.forEach(function (k) { chars[k] = '［'; });
    return chars.join('');
  };

  function summaryOf(summaries, task) {
    if (!summaries) return null;
    var s = typeof summaries === 'function' ? summaries(task) : summaries[task.id];
    return s || null;
  }

  function rest(task, sum) {
    var D = GT.dates, out = '';
    if (task.start !== null) {
      out += ' · ' + D.format(task.start);
      if (!task.milestone && task.end !== null && task.end !== task.start) out += ' → ' + D.format(task.end);
    }
    if (sum && Number.isSafeInteger(sum.total) && sum.total > 0) {
      var done = Number.isSafeInteger(sum.done) ? Math.max(0, Math.min(sum.total, sum.done)) : 0;
      out += ' · ' + done + '/' + sum.total;
    }
    return out;
  }

  function taskLine(task, sum, grouped) {
    return (grouped ? '  - ' : '- ') + (task.milestone ? '◆ ' : '') + '[' + B.etext(task.title) +
      '](synapseresource://note/' + task.note + '?via=gantt)' + rest(task, sum);
  }

  // The mirror text, or '' when no task has a note.
  B.mirror = function (chart, summaries) {
    var gids = Object.create(null), out = [];
    chart.groups.forEach(function (g) { gids[g.id] = true; });
    var noted = chart.tasks.filter(function (t) { return !!t.note; });
    noted.forEach(function (t) {
      if (t.group === null || !gids[t.group]) out.push(taskLine(t, summaryOf(summaries, t), false));
    });
    chart.groups.forEach(function (g) {
      var mine = noted.filter(function (t) { return t.group === g.id; });
      if (!mine.length) return;
      out.push('- **' + B.etext(g.title) + '**');
      mine.forEach(function (t) { out.push(taskLine(t, summaryOf(summaries, t), true)); });
    });
    return out.join('\n');
  };

  B.embedLine = function () {
    var u = uuid();
    return u ? '@[100% x ' + B.EMBED_H + '](synapseresource://app/' + u + '?note=current&mode=embed)' : '';
  };

  // The whole region for `chart`. opts.embedOutside suppresses the embed line.
  B.region = function (chart, summaries, opts) {
    opts = opts || {};
    var s = chart.settings || {}, parts = [];
    if (s.embed === true && !opts.embedOutside && uuid()) parts.push(B.embedLine());
    if (s.mirror !== false) {
      var m = B.mirror(chart, summaries);
      if (m) parts.push(m);
    }
    parts.push(B.fence(chart));
    return parts.join('\n\n');
  };

  /* --------------------------------------------------------- line grammar */

  var TASK_RE = new RegExp('^(  )?- (◆ )?\\[([\\s\\S]*)\\]\\(synapseresource://note/([A-Za-z0-9_-]+)\\?via=gantt\\)' +
    '(?:| · (\\d+)/(\\d+)| · (\\d{4}-\\d{2}-\\d{2})(?: → (\\d{4}-\\d{2}-\\d{2}))?(?: · (\\d+)/(\\d+))?)$');
  var GROUP_RE = /^- \*\*([\s\S]*)\*\*$/;

  // {kind:'top'|'sub'|'group', id?, title} or null.
  B.parseLine = function (line) {
    var m = TASK_RE.exec(line);
    if (m) return { kind: m[1] ? 'sub' : 'top', id: m[4], title: m[3], milestone: !!m[2] };
    m = GROUP_RE.exec(line);
    if (m) return { kind: 'group', title: m[1] };
    return null;
  };

  function escRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
  function isEmbedLine(line) {
    var u = uuid();
    if (!u) return false;
    return new RegExp('^@\\[100% x \\d+\\]\\(synapseresource://app/' + escRe(u) + '\\?note=current&mode=embed\\)$').test(line);
  }
  // Any line that embeds this app, for embedOutside.
  function embedsApp(line) {
    var u = uuid();
    return !!u && line.indexOf('synapseresource://app/' + u) >= 0 && /[?&]mode=embed\b/.test(line);
  }
  B.isEmbedLine = isEmbedLine;

  /* ------------------------------------------------------------------ read */

  function detect(src, ls, F, chart) {
    function text(k) { return src.slice(ls[k].start, ls[k].end); }
    var i = F - 1;
    if (i < 0 || !blank(text(i))) return F;
    i -= 1;
    if (i < 0) return F;
    var ids = Object.create(null), anyNote = false, anyId = false;
    if (chart && chart.settings.mirror !== false) {
      chart.tasks.forEach(function (t) { if (t.note) { ids[t.note] = true; anyNote = true; } });
    } else if (!chart) {
      // Malformed block: its note ids are unknown, so any mirror-grammar
      // line joins; a forced Repair then replaces the old mirror too.
      anyNote = anyId = true;
    }
    var T = -1, below = null;
    if (anyNote) {
      for (var k = i; k >= 0; k--) {
        var p = B.parseLine(text(k));
        var join = false;
        if (p && (p.kind === 'top' || p.kind === 'sub') && (anyId || ids[p.id])) join = true;
        else if (p && p.kind === 'group' && below && below.kind === 'sub') join = true;
        if (!join) break;
        T = k;
        below = p;
      }
    }
    if (T >= 0) {
      if (T - 2 >= 0 && blank(text(T - 1)) && isEmbedLine(text(T - 2))) return T - 2;
      return T;
    }
    return isEmbedLine(text(i)) ? i : F;
  }

  /*
   * read(text) -> {status, chart, key, region:{start,end,text}|null,
   *   embedOutside, extra, shadowed, openAtEnd, dropped, reason, span}
   * Never throws.
   */
  B.read = function (text) {
    var found = B.scan(text), src = found.src, ls = found.lines;
    var span = found.spans[0] || null;
    var out = {
      status: 'none', chart: null, key: null, region: null, embedOutside: false,
      extra: found.spans.length > 1 ? found.spans.length - 1 : 0, shadowed: found.shadowed,
      openAtEnd: found.openAtEnd, dropped: 0, reason: '', span: span
    };
    var skipFrom = -1, skipTo = -1;
    if (span) {
      var data;
      if (span.closed) { try { data = JSON.parse(span.body); } catch (e) { data = undefined; } }
      // A chart fence whose closing line was deleted can be "closed" by a
      // later bare fence, swallowing the prose between. A body that does not
      // parse is bounded like an unclosed fence (boundAt), but only when a
      // line after a blank line is plainly not JSON (prose, a heading, a
      // fence opener); a real block with a JSON typo keeps its whole closed
      // span.
      if (span.closed && data === undefined) {
        var cut = boundAt(src, ls, span.line, span.lastLine - 1);
        if (cut.stray) {
          span = makeSpan(src, ls, span.line, cut.last, false);
          out.span = span;
        }
      }
      out.key = B.key(span.body);
      if (!span.closed) { out.status = 'malformed'; out.reason = 'unclosed'; }
      else {
        if (data === undefined) { out.status = 'malformed'; out.reason = 'json'; }
        else if (!data || typeof data !== 'object' || Array.isArray(data)) { out.status = 'malformed'; out.reason = 'not-object'; }
        else if (typeof data.v !== 'number' || data.v < 1 || data.v !== Math.floor(data.v)) { out.status = 'malformed'; out.reason = 'version'; }
        else {
          var c = M().coerce(data);
          out.chart = c.chart;
          out.dropped = c.dropped;
          out.status = data.v > B.V ? 'future' : 'ok';
          if (out.status === 'future') out.reason = 'v' + data.v;
        }
      }
      var first = detect(src, ls, span.line, out.chart);
      out.region = { start: ls[first].start, end: span.end, text: src.slice(ls[first].start, span.end) };
      skipFrom = first;
      skipTo = span.lastLine;
    }
    for (var k = 0; k < ls.length; k++) {
      if (k >= skipFrom && k <= skipTo) continue;
      if (embedsApp(src.slice(ls[k].start, ls[k].end))) { out.embedOutside = true; break; }
    }
    return out;
  };

  /*
   * mirrorGap(text) -> null or {key, deleted: [taskId], edited: [taskId]}
   * (M9 reconciliation banner). With the mirror on, the tasks that have a
   * note but no line in the detected region. `edited`: the task's
   * ?via=gantt link is still in the note outside the region (a line edited
   * out of the grammar, kept as user text, §5.6); `deleted`: it is gone.
   * The mirror is output only: this never changes the chart.
   */
  B.mirrorGap = function (text) {
    var src = String(text == null ? '' : text), r = B.read(src);
    if (r.status !== 'ok' || !r.chart || !r.region || r.chart.settings.mirror === false) return null;
    var have = Object.create(null);
    r.region.text.split('\n').forEach(function (l) {
      var p = B.parseLine(l.replace(/\r$/, ''));
      if (p && p.id) have[p.id] = true;
    });
    var outside = src.slice(0, r.region.start) + '\n' + src.slice(r.region.end);
    var out = { key: r.key, deleted: [], edited: [] };
    r.chart.tasks.forEach(function (t) {
      if (!t.note || have[t.note]) return;
      var link = 'synapseresource://note/' + t.note + '?via=gantt)';
      (outside.indexOf(link) >= 0 ? out.edited : out.deleted).push(t.id);
    });
    return out;
  };

  /* ---------------------------------------------------------------- splice */

  // Replace the detected region with `region`, or append it after a blank
  // line when the note has none. Bytes outside the region are untouched.
  B.splice = function (text, region) {
    var src = String(text == null ? '' : text);
    var r = B.read(src);
    if (r.region) return src.slice(0, r.region.start) + region + src.slice(r.region.end);
    if (!src.length) return region;
    var pad = /\r?\n\r?\n$/.test(src) ? '' : (/\r?\n$/.test(src) ? '\n' : '\n\n');
    return src + pad + region;
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
