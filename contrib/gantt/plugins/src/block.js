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
 *
 * Charts whose JSON has settings.listHeading use the delimited task list of
 * the task-groups plan §5.2 instead (read: findHeading/parseList, write:
 * regionParts):
 *
 *   region := listHead [NL NL embedLine] [NL NL block(h)] [NL NL utasks]
 *             {NL NL group} NL NL fence
 *
 * Charts without it are read by the grammar above and migrate on their next
 * save (plan §5.6). All of this is behind opts.list on read/region/splice;
 * without it the module behaves as an older build.
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
  // With opts.list, a chart with a list heading gets the delimited region
  // (regionParts); without it, always main spec §5.6's.
  B.region = function (chart, summaries, opts) {
    return B.regionParts(chart, summaries, opts).text;
  };

  // Main spec §5.6 region: [embed NL NL] [mirror NL NL] fence.
  function legacyRegion(chart, summaries, opts) {
    opts = opts || {};
    var s = chart.settings || {}, parts = [];
    if (s.embed === true && !opts.embedOutside && uuid()) parts.push(B.embedLine());
    if (s.mirror !== false) {
      var m = B.mirror(chart, summaries);
      if (m) parts.push(m);
    }
    parts.push(B.fence(chart));
    return parts.join('\n\n');
  }

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

  /* ------------------------------------------ task list (task-groups §5.2) */

  function own(o, k) { return o && Object.prototype.hasOwnProperty.call(o, k) ? o[k] : undefined; }
  function putKey(o, k, v) { Object.defineProperty(o, k, { value: v, enumerable: true, writable: true, configurable: true }); }
  function hashes(n) { var s = ''; while (s.length < n) s += '#'; return s; }

  // ATX heading with at most one leading space (the host renders two or more
  // as indented text). `stripped` drops a CommonMark closing sequence.
  var HEAD_RE = /^ ?(#{1,6})[ \t]+(\S[\s\S]*?)[ \t]*$/;
  var CLOSE_RE = /[ \t]+#+[ \t]*$/;
  var BOLD_RE = /^- \*\*([\s\S]+)\*\*$/;
  var ITEM_RE = /^([-*+] |\d+[.)] )/;
  var REST = '(?:| · \\d+/\\d+| · \\d{4}-\\d{2}-\\d{2}(?: → \\d{4}-\\d{2}-\\d{2})?(?: · \\d+/\\d+)?)';
  // Link text excludes "](", so a line holding two links is not a LINK.
  var LINK_RE = new RegExp('^( {0,3})(?:[-*+] |\\d{1,9}[.)] )?(◆ )?\\[((?:(?!\\]\\()[\\s\\S])*)\\]' +
    '\\(synapseresource://note/([A-Za-z0-9_-]+)(\\?via=gantt)?\\)' + REST + '[ \\t]*$');

  function heading(line) {
    var m = HEAD_RE.exec(line);
    if (!m) return null;
    return { level: m[1].length, text: m[2], stripped: m[2].replace(CLOSE_RE, '') };
  }
  B.heading = heading;

  function parseLink(line) {
    var m = LINK_RE.exec(line);
    return m ? { indent: m[1].length, ms: !!m[2], text: m[3], note: m[4], marked: !!m[5] } : null;
  }
  B.parseLink = parseLink;

  function norm(s) { return B.etext(s).replace(/\s+/g, ' ').trim(); }
  function htext(s) { return norm(s) || 'Untitled'; }
  // A group titled "" has the norm Untitled (plan §5.7; see the G1 build log).
  function gnorm(g) { return norm(g.title) || 'Untitled'; }
  function ltext(s) { return B.etext(s).split('](').join('］('); }
  B.norm = norm;
  B.htext = htext;
  B.ltext = ltext;

  function strH(v) { return typeof v === 'string' && norm(v) !== '' ? v : null; }
  function lvl(v) { return typeof v === 'number' && v === Math.floor(v) && v >= 1 && v <= 5 ? v : null; }

  // {on, h, L}: settings.listHeading / listLevel, or the same keys kept in
  // settings._x while model.coerce does not know them. h is null on a chart
  // without a list heading (main spec §5.6 applies).
  B.listConf = function (chart) {
    var s = (chart && chart.settings) || {}, x = s._x || {};
    var h = strH(s.listHeading);
    if (h === null) h = strH(own(x, 'listHeading'));
    var L = lvl(s.listLevel);
    if (L === null) L = lvl(own(x, 'listLevel'));
    return { on: s.mirror !== false, h: h, L: L === null ? 2 : L };
  };

  // The chart with settings.listHeading = h (in _x until coerce knows it).
  B.withHeading = function (chart, h) {
    var s = {};
    Object.keys(chart.settings).forEach(function (k) { if (k !== '_x') s[k] = chart.settings[k]; });
    var x = {};
    Object.keys(chart.settings._x || {}).forEach(function (k) { putKey(x, k, chart.settings._x[k]); });
    if (M().SETTING_KEYS.indexOf('listHeading') >= 0) s.listHeading = h;
    else putKey(x, 'listHeading', h);
    s._x = x;
    return { v: chart.v, settings: s, groups: chart.groups, tasks: chart.tasks, _x: chart._x };
  };

  // Same derivation as model.js derivedId, so new-marker ids are a pure
  // function of the note text.
  function derivedId(prefix, seed, taken) {
    for (var salt = 0; ; salt++) {
      var h = 0x811c9dc5, s = seed + '#' + salt;
      for (var i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
      var id = prefix + ('000000' + (h % 2176782336).toString(36)).slice(-6);
      if (!taken[id]) { taken[id] = true; return id; }
    }
  }
  B.derivedId = derivedId;

  // Per line: inside a fenced code block, or a fence line. Tracked from the
  // top of the note like scan().
  function codeMask(src, ls) {
    var m = new Array(ls.length), open = null;
    for (var i = 0; i < ls.length; i++) {
      var line = src.slice(ls[i].start, ls[i].end);
      if (open) { m[i] = true; if (closes(line, open)) open = null; continue; }
      var o = opening(line);
      m[i] = !!o;
      if (o) open = o;
    }
    return m;
  }

  function noteMap(chart) {
    var o = Object.create(null);
    chart.tasks.forEach(function (t) { if (t.note) o[t.note] = t; });
    return o;
  }

  function matchesH(hd, conf) {
    var want = norm(conf.h);
    return hd.level === conf.L && (norm(hd.stripped) === want || norm(hd.text) === want);
  }

  // 5.2.2: the nearest level-L heading with text h above the fence, outside
  // code blocks. -1 when there is none.
  function findHeading(src, ls, code, F, conf) {
    for (var k = F - 1; k >= 0; k--) {
      if (code[k]) continue;
      var hd = heading(src.slice(ls[k].start, ls[k].end));
      if (hd && matchesH(hd, conf)) return k;
    }
    return -1;
  }

  /*
   * §6.1 step 1 (pure): markers [{text, stripped, tasks:[taskId]}] in note
   * order to JSON groups. Returns {markers:[{title, gid, kind, dupOf}],
   * gone:[gid]}; kind is same | overlap | position | duplicate | new.
   * `listed` (optional): every task id the list shows in any section. Rename
   * by position (c) pairs only a group none of whose tasks is listed (G2:
   * a deleted marker whose tasks now sit in another section is a gone group
   * behind the removal banner, never a silent rename).
   */
  function mapMarkers(chart, markers, listed) {
    var groups = chart.groups, gn = groups.map(gnorm), titles = Object.create(null);
    gn.forEach(function (t) { titles[t] = true; });
    var gOf = Object.create(null);
    chart.tasks.forEach(function (t) { gOf[t.id] = t.group; });
    var used = groups.map(function () { return false; });
    // A title is matched with the closing sequence stripped, then as
    // written (§5.7); a title that matches no group is taken stripped, so a
    // CommonMark closing `##` never becomes part of a new or renamed title.
    var res = markers.map(function (m) {
      var a = norm(m.stripped), w = norm(m.text);
      return { title: titles[a] ? a : (titles[w] ? w : (a || w || 'Untitled')), gid: null, kind: null, dupOf: null };
    });
    function overlap(i, j) {
      var gid = groups[j].id, n = 0;
      markers[i].tasks.forEach(function (tid) { if (gOf[tid] === gid) n++; });
      return n;
    }
    function pair(i, j, kind) { res[i].gid = groups[j].id; res[i].kind = kind; used[j] = true; }
    // (a) same title: largest overlap first, ties by marker then group order.
    var byTitle = Object.create(null);
    res.forEach(function (r, i) { (byTitle[r.title] = byTitle[r.title] || { m: [], g: [] }).m.push(i); });
    gn.forEach(function (t, j) { if (byTitle[t]) byTitle[t].g.push(j); });
    Object.keys(byTitle).forEach(function (t) {
      var ms = byTitle[t].m.slice(), gs = byTitle[t].g.slice();
      while (ms.length && gs.length) {
        var best = null;
        for (var a = 0; a < ms.length; a++) {
          for (var b = 0; b < gs.length; b++) {
            var o = overlap(ms[a], gs[b]);
            if (!best || o > best.o) best = { o: o, a: a, b: b };
          }
        }
        pair(ms[best.a], gs[best.b], 'same');
        ms.splice(best.a, 1);
        gs.splice(best.b, 1);
      }
    });
    // (b) rename by overlap, for markers titled like no JSON group.
    res.forEach(function (r, i) {
      if (r.gid !== null || titles[r.title]) return;
      var best = -1, bo = 0;
      groups.forEach(function (g, j) {
        if (used[j]) return;
        var o = overlap(i, j);
        if (o > bo) { bo = o; best = j; }
      });
      if (best >= 0) pair(i, best, 'overlap');
    });
    // (c) rename by position.
    var left = [], leftG = [];
    res.forEach(function (r, i) { if (r.gid === null && !titles[r.title]) left.push(i); });
    used.forEach(function (u, j) { if (!u) leftG.push(j); });
    function unlisted(j) {
      var gid = groups[j].id;
      return !listed || !chart.tasks.some(function (t) { return t.group === gid && !!listed[t.id]; });
    }
    if (left.length === 1 && leftG.length === 1 && unlisted(leftG[0])) pair(left[0], leftG[0], 'position');
    // (d) duplicate, (e) new.
    // taken: every task and group id, and every shadow group value, so a
    // derived id never revives a group a task still names (review of G2
    // phase 1: the fold would then not survive serialise and coerce).
    var taken = Object.create(null), seen = Object.create(null);
    chart.tasks.forEach(function (t) {
      taken[t.id] = true;
      var sh = t._x && Object.prototype.hasOwnProperty.call(t._x, 'group') ? t._x.group : null;
      if (typeof sh === 'string') taken[sh] = true;
    });
    groups.forEach(function (g) { taken[g.id] = true; });
    res.forEach(function (r) {
      if (r.gid !== null) return;
      if (titles[r.title]) { r.kind = 'duplicate'; r.dupOf = groups[gn.indexOf(r.title)].id; return; }
      var k = seen[r.title] || 0;
      seen[r.title] = k + 1;
      r.gid = derivedId('g', 'list:' + r.title + '#' + k, taken);
      r.kind = 'new';
    });
    var gone = [];
    used.forEach(function (u, j) { if (!u) gone.push(groups[j].id); });
    return { markers: res, gone: gone };
  }
  B.mapMarkers = mapMarkers;

  /*
   * 5.2.3 to 5.2.5: the region's lines from the list heading `hl` to the
   * fence `F` (exclusive) as fr.list. Pure; linear apart from mapMarkers.
   */
  // The norms of the chart's group titles: a LEGACY bold line must name one
  // (older builds only write existing titles; review round 2).
  function groupTitles(chart) {
    var o = Object.create(null);
    chart.groups.forEach(function (g) { o[gnorm(g)] = true; });
    return o;
  }

  function parseList(src, ls, code, hl, F, chart, conf) {
    var L = conf.L, JT = noteMap(chart), links = [], gTitles = groupTitles(chart);
    function text(k) { return src.slice(ls[k].start, ls[k].end); }
    function link(k) {
      var i = k - hl;
      if (links[i] === undefined) {
        var p = code[k] ? null : parseLink(text(k));
        if (p) p.task = JT[p.note] ? JT[p.note].id : null;
        links[i] = p;
      }
      return links[i];
    }
    var rows = [];
    for (var k = hl + 1; k < F; k++) {
      var t = text(k), row = { k: k, cls: 'TEXT', content: t, hd: null, ln: null, owned: null, sec: 0 };
      if (code[k]) row.cls = 'CODE';
      else if (blank(t)) row.cls = 'BLANK';
      else if (isEmbedLine(t)) row.cls = 'EMBED';
      else {
        var hd = heading(t);
        if (hd && hd.level === L + 1) { row.cls = 'MARKER'; row.hd = hd; }
        else {
          var b = BOLD_RE.exec(t), nx = b && k + 1 < F && gTitles[norm(b[1]) || 'Untitled'] ? link(k + 1) : null;
          if (nx && nx.indent === 2 && nx.marked && nx.task) { row.cls = 'LEGACY'; row.bold = b[1]; }
          else {
            var ln = link(k);
            if (ln) { row.cls = 'LINK'; row.ln = ln; } else row.hd = hd;
          }
        }
      }
      rows.push(row);
    }

    // 5.2.4 copies (CODE lines are never LINK rows).
    var cnt = Object.create(null);
    rows.forEach(function (r) {
      if (r.cls !== 'LINK' || !r.ln.task) return;
      var c = cnt[r.ln.task] || (cnt[r.ln.task] = { v: [], p: [] });
      (r.ln.marked ? c.v : c.p).push(r);
    });
    var amb = Object.create(null), ambiguous = [];
    chart.tasks.forEach(function (t) {
      var c = cnt[t.id];
      if (!c) return;
      if (c.v.length >= 2 || (c.v.length === 0 && c.p.length >= 2)) { amb[t.id] = true; ambiguous.push(t.id); return; }
      (c.v.length ? c.v[0] : c.p[0]).owned = t.id;
    });

    // Sections.
    var sections = [{ marker: null, gid: null, key: 'h', tasks: [], line: hl, indent: 0 }];
    rows.forEach(function (r) {
      if (r.cls === 'MARKER' || r.cls === 'LEGACY') {
        var legacy = r.cls === 'LEGACY';
        sections.push({
          marker: { text: legacy ? r.bold : r.hd.text, stripped: legacy ? r.bold : r.hd.stripped, level: legacy ? 0 : L + 1,
            legacy: legacy, line: r.k, title: '', gid: null, kind: null, dupOf: null },
          gid: null, key: '', tasks: [], line: r.k, indent: legacy ? 2 : 0 });
      } else if (r.owned) sections[sections.length - 1].tasks.push(r.owned);
      r.sec = sections.length - 1;
    });
    var listedAll = Object.create(null);
    sections.forEach(function (s) { s.tasks.forEach(function (id) { listedAll[id] = true; }); });
    var map = mapMarkers(chart, sections.slice(1).map(function (s) {
      return { text: s.marker.text, stripped: s.marker.stripped, tasks: s.tasks };
    }), listedAll);
    sections.forEach(function (s, i) {
      if (!i) return;
      var m = map.markers[i - 1];
      s.marker.title = m.title;
      s.marker.gid = m.gid;
      s.marker.kind = m.kind;
      s.marker.dupOf = m.dupOf;
      s.gid = m.gid;
      s.key = m.kind === 'duplicate' ? 'x:' + i : 'g:' + m.gid;
    });

    // Blocks, offers, promote candidates.
    var gByNorm = Object.create(null);
    chart.groups.forEach(function (g) { var n = gnorm(g); if (!gByNorm[n]) gByNorm[n] = g.id; });
    var attach = { h: [] }, key = 'h', buf = [], offers = [], promote = [], seenHead = false, offered = Object.create(null);
    var last = sections.map(function () { return null; });
    function flush() {
      var a = 0, b = buf.length;
      while (a < b && buf[a].cls === 'BLANK') a++;
      while (b > a && buf[b - 1].cls === 'BLANK') b--;
      var arr = attach[key];
      // Two joined parts (heading and embed blocks) keep a blank line
      // between them, so no line pair across the join can read as LEGACY.
      if (arr.length && b > a) arr.push('');
      for (var i = a; i < b; i++) {
        var r = buf[i];
        if (r.cls === 'TEXT' && r.hd && r.hd.level === L) {
          var sec = sections[r.sec];
          promote.push({ text: r.hd.stripped, line: r.k, owner: key, index: arr.length,
            section: sec.marker && sec.marker.kind === 'duplicate' ? sec.marker.dupOf : sec.gid,
            group: gByNorm[norm(r.hd.stripped)] || null, tasks: [] });
        }
        // G2: where an offer's line sits in its block (Add removes it there).
        if (r.offer) { r.offer.owner = key; r.offer.index = arr.length; }
        arr.push(r.content);
      }
      buf = [];
    }
    function open(k) {
      flush();
      key = k;
      if (!own(attach, k)) attach[k] = [];
      seenHead = false;
    }
    rows.forEach(function (r) {
      var sec = sections[r.sec];
      if (r.cls === 'EMBED') { open('h'); return; }
      if (r.cls === 'MARKER' || r.cls === 'LEGACY') { open(sec.key); return; }
      if (r.cls === 'LINK' && r.owned) { open('t:' + r.owned); last[r.sec] = r.owned; return; }
      if (r.cls === 'LINK' && !r.ln.task && r.ln.indent === sec.indent && !seenHead && !offered[r.ln.note]) {
        offered[r.ln.note] = true;
        r.offer = { note: r.ln.note, text: r.ln.text, line: r.k, after: last[r.sec],
          group: sec.marker && sec.marker.kind === 'duplicate' ? sec.marker.dupOf : sec.gid, owner: null, index: -1 };
        offers.push(r.offer);
      }
      if (r.cls === 'TEXT' && r.hd) seenHead = true;
      buf.push(r);
    });
    flush();
    // G2: a promote candidate's tasks are the owned lines after it up to the
    // next heading of any level (a marker, a TEXT heading) or the fence.
    promote.forEach(function (p) {
      for (var q = 0; q < rows.length; q++) {
        var r = rows[q];
        if (r.k <= p.line) continue;
        if (r.cls === 'MARKER' || r.cls === 'LEGACY' || r.cls === 'EMBED' || (r.cls === 'TEXT' && r.hd)) break;
        if (r.cls === 'LINK' && r.owned) p.tasks.push(r.owned);
      }
    });

    var plainElsewhere = [];
    chart.tasks.forEach(function (t) {
      var c = cnt[t.id];
      if (!c || amb[t.id] || c.v.length !== 1) return;
      var s0 = c.v[0].sec;
      if (c.p.some(function (r) { return r.sec !== s0; })) plainElsewhere.push(t.id);
    });
    var duplicates = [];
    sections.forEach(function (s) {
      if (s.marker && s.marker.kind === 'duplicate') duplicates.push({ title: s.marker.title, line: s.marker.line, gid: s.marker.dupOf });
    });
    var sig = norm(conf.h) + '\n' + sections.map(function (s) {
      return (s.marker ? (s.marker.kind === 'duplicate' ? '=' + s.marker.dupOf : s.gid) + '|' + s.marker.title : '|') + '|' + s.tasks.join(',');
    }).join('\n');
    var hdr = heading(text(hl));
    return {
      heading: { text: hdr.stripped, level: hdr.level, line: hl },
      sections: sections.map(function (s) { return { marker: s.marker, gid: s.gid, key: s.key, tasks: s.tasks, line: s.line }; }),
      attach: attach, ambiguous: ambiguous, offers: offers, promote: promote, plainElsewhere: plainElsewhere,
      duplicates: duplicates, gone: map.gone,
      rows: rows.map(function (r) { return { line: r.k, cls: r.cls, task: r.ln ? r.ln.task : null, owned: !!r.owned }; }),
      sig: sig
    };
  }

  // The list of a region that has no list heading and no headless list (the
  // list was deleted): only the embed line can be in it.
  function emptyList(chart) {
    return { heading: null, sections: [{ marker: null, gid: null, key: 'h', tasks: [], line: -1 }], attach: { h: [] },
      ambiguous: [], offers: [], promote: [], plainElsewhere: [], duplicates: [], gone: chart.groups.map(function (g) { return g.id; }),
      rows: [], sig: '' };
  }

  /*
   * §5.6 missing heading: the climb rule. Segments between headings of level
   * L or shallower join (nearest first) while they hold a MARKED task line
   * or a MARKER; the fallback starts at the last joined segment's heading or
   * the note start. P0 is its head down to the first MARKER, LEGACY, EMBED or
   * MARKED task line, trailing blank lines trimmed. Segments below the
   * nearest joining one are crossed only under the threshold below; else
   * null (the list is gone).
   */
  function findFallback(src, ls, code, F, spanEnd, chart, conf) {
    var L = conf.L, JT = noteMap(chart), gTitles = groupTitles(chart);
    function text(k) { return src.slice(ls[k].start, ls[k].end); }
    function markedTask(k) {
      var p = code[k] ? null : parseLink(text(k));
      return p && p.marked && JT[p.note] ? JT[p.note].id : null;
    }
    function marked(k) { return markedTask(k) !== null; }
    function marker(k) {
      if (code[k]) return false;
      var hd = heading(text(k));
      return !!hd && hd.level === L + 1;
    }
    function term(k) {
      if (code[k]) return false;
      var t = text(k);
      if (isEmbedLine(t) || marker(k) || marked(k)) return true;
      var bm = BOLD_RE.exec(t);
      if (bm && gTitles[norm(bm[1]) || 'Untitled'] && k + 1 < F && !code[k + 1]) {
        var p = parseLink(text(k + 1));
        return !!(p && p.indent === 2 && p.marked && JT[p.note]);
      }
      return false;
    }
    // Non-joining segments (level-L TEXT headings with no task line or
    // marker below them) are crossed until the chain holds every task that
    // has a MARKED line above the fence; then a non-joining segment ends the
    // climb. A climb that crossed one stands only when the chain holds MARKED
    // lines for at least half of the chart's noted tasks, minimum one; else
    // the list is gone (§5.6, G1 review round 1).
    // Review round 2: a run reached by crossing must hold a MARKER or at
    // least two tasks new to the chain, so one stray task line (a stale copy
    // of a task deleted from the list) never pulls user sections in.
    var noted = 0, need = Object.create(null), needN = 0;
    chart.tasks.forEach(function (t) { if (t.note) noted++; });
    for (var q = 0; q < F; q++) {
      var qid = markedTask(q);
      if (qid !== null && !need[qid]) { need[qid] = true; needN++; }
    }
    // Segments from the fence up: {top, joins, tasks, marker}.
    var segs = [], hi = F;
    for (var k = F - 1; k >= -1; k--) {
      var hd = k >= 0 && !code[k] ? heading(text(k)) : null;
      if (k >= 0 && !(hd && hd.level <= L)) continue;
      var sg = { top: k < 0 ? 0 : k, joins: false, tasks: [], marker: false };
      for (var j = k + 1; j < hi; j++) {
        var id = markedTask(j);
        if (id !== null) { sg.joins = true; sg.tasks.push(id); } else if (marker(j)) { sg.joins = true; sg.marker = true; }
      }
      segs.push(sg);
      hi = k;
    }
    var chain = Object.create(null), inChain = 0, start = null, crossed = false, i = 0;
    // The run of joining segments starting at segs[a]: [a, b).
    function runEnd(a) { var b = a; while (b < segs.length && segs[b].joins) b++; return b; }
    function fresh(a, b) {
      var o = Object.create(null), n = 0, mk = false;
      for (var x = a; x < b; x++) {
        if (segs[x].marker) mk = true;
        segs[x].tasks.forEach(function (id) { if (!chain[id] && !o[id]) { o[id] = true; n++; } });
      }
      return mk || n >= 2;
    }
    function take(a, b) {
      for (var x = a; x < b; x++) {
        start = segs[x].top;
        segs[x].tasks.forEach(function (id) { if (!chain[id]) { chain[id] = true; inChain++; } });
      }
    }
    while (i < segs.length && !segs[i].joins) { i++; crossed = true; }
    if (i === segs.length) return null;
    var e0 = runEnd(i);
    if (crossed && !fresh(i, e0)) return null;
    take(i, e0);
    i = e0;
    while (i < segs.length && inChain < needN) {
      var g0 = i;
      while (i < segs.length && !segs[i].joins) i++;
      if (i === segs.length) break;
      var e1 = runEnd(i);
      if (!fresh(i, e1)) break;
      crossed = crossed || i > g0;
      take(i, e1);
      i = e1;
    }
    if (crossed && !(inChain >= 1 && 2 * inChain >= noted)) return null;
    var tl = start;
    while (tl < F && !term(tl)) tl++;
    var e = tl - 1;
    while (e >= start && blank(text(e))) e--;
    var p0 = e >= start ? src.slice(ls[start].start, ls[e].end) : '';
    var rest = src.slice(ls[tl].start, spanEnd);
    var listHead = hashes(L) + ' ' + htext(conf.h);
    // The note's own line break, so a CRLF note keeps P0's last \r.
    var nl = src.charAt(ls[tl].end) === '\r' ? '\r\n' : '\n';
    var useAs = null;
    if (e === start) {
      var h0 = heading(text(start));
      if (h0 && h0.level === L && !code[start]) useAs = h0.stripped.trim();
    }
    return {
      line: start, start: ls[start].start, end: spanEnd, text: src.slice(ls[start].start, spanEnd),
      p0: p0, headLine: tl, useAs: useAs,
      restore: (p0 ? p0 + nl + nl : '') + listHead + nl + nl + rest
    };
  }

  // A malformed block: the list heading from a raw "listHeading" match.
  function rawConf(body) {
    var m = /"listHeading"\s*:\s*("(?:[^"\\\r\n]|\\.)*")/.exec(body), h = null;
    if (m) { try { h = strH(JSON.parse(m[1])); } catch (e) { h = null; } }
    var l = /"listLevel"\s*:\s*(\d+)/.exec(body);
    return { on: !/"mirror"\s*:\s*false/.test(body), h: h, L: (l && lvl(Number(l[1]))) || 2 };
  }

  /*
   * §5.5 seed: above the region's top line, after one run of blank lines,
   * the run of level 2-6 headings, LINK lines and blank lines next to a
   * heading, holding a heading followed by a LINK at task indent. Only read
   * to make an offer.
   */
  function parseSeed(src, ls, code, top, chart, conf) {
    var JT = noteMap(chart);
    function text(k) { return src.slice(ls[k].start, ls[k].end); }
    function kind(k) {
      if (k < 0 || k >= top || code[k]) return null;
      var t = text(k);
      if (blank(t)) return 'B';
      var hd = heading(t);
      // A level-L heading titled like the list heading: a stale list above
      // a second list heading (§5.4 row 22), never a seed.
      if (hd && conf.h !== null && matchesH(hd, conf)) return 'X';
      if (hd && hd.level >= 2) return 'H';
      return parseLink(t) ? 'L' : null;
    }
    var i = top - 1;
    while (i >= 0 && kind(i) === 'B') i--;
    var end = i, j = i;
    while (j >= 0) {
      var kd = kind(j);
      if (kd === 'X') return null;
      if (kd === 'H' || kd === 'L' || (kd === 'B' && (kind(j - 1) === 'H' || kind(j - 1) === 'X' || kind(j + 1) === 'H'))) j--;
      else break;
    }
    var s = j + 1;
    while (s <= end && kind(s) === 'B') s++;
    if (s > end) return null;
    var groups = [], ungrouped = [], cur = null, valid = false, notes = Object.create(null), n = 0, lines = [];
    for (var k = s; k <= end; k++) {
      var t = text(k);
      lines.push(t);
      var kk = kind(k);
      if (kk === 'H') { var hd = heading(t); cur = { title: hd.stripped, level: hd.level, line: k, links: [] }; groups.push(cur); }
      else if (kk === 'L') {
        var p = parseLink(t);
        p.task = JT[p.note] ? JT[p.note].id : null;
        p.line = k;
        (cur ? cur.links : ungrouped).push(p);
        if (cur && p.indent === 0) valid = true;
        if (!notes[p.note]) { notes[p.note] = true; n++; }
      }
    }
    if (!valid) return null;
    // Only MARKED chart-task links under L+1 headings: a written list (a
    // stale part above a second list heading, with or without attached
    // lines cutting the run), not a seed (review round 2).
    var links = ungrouped.concat.apply(ungrouped, groups.map(function (gr) { return gr.links; }));
    if (links.every(function (p) { return p.marked && p.task; }) && groups.every(function (gr) { return gr.level === conf.L + 1; })) return null;
    var st = chart.settings || {}, hash = B.hash(lines.join('\n'));
    var skip = typeof st.seedSkip === 'string' ? st.seedSkip : own(st._x || {}, 'seedSkip');
    return { line: s, lastLine: end, start: ls[s].start, end: ls[end].end, text: src.slice(ls[s].start, ls[end].end),
      hash: hash, groups: groups, ungrouped: ungrouped, tasks: n, skipped: skip === hash };
  }

  // Blocks as user text: each block's lines, blocks one blank line apart.
  function spillOf(attach) {
    var sp = [];
    Object.keys(attach || {}).forEach(function (k) { var b = attach[k]; if (b && b.length) sp.push(b.join('\n')); });
    return sp.join('\n\n');
  }

  /*
   * regionParts(chart, summaries, {list, embedOutside, attach, ambiguous}) ->
   * {text, attach, spill}. Plan §5.2.6. Blocks whose owner is not written
   * move to the nearest preceding written owner in `attach` key order (the
   * read order), else to 'h'. With the list off, or on a chart without a
   * list heading, every block is `spill` (user text for above the region).
   * The returned attach lists every written owner in write order.
   */
  B.regionParts = function (chart, summaries, opts) {
    opts = opts || {};
    var conf = B.listConf(chart), attachIn = opts.attach || {}, keys = Object.keys(attachIn);
    // opts.list gates the delimited writer, like read (the phase-2 store).
    if (!opts.list || !conf.on || conf.h === null) {
      return { text: legacyRegion(chart, summaries, opts), attach: {}, spill: spillOf(attachIn) };
    }
    var amb = Object.create(null), gids = Object.create(null), byGroup = Object.create(null), ungrouped = [];
    (opts.ambiguous || []).forEach(function (id) { amb[id] = true; });
    chart.groups.forEach(function (g) { gids[g.id] = true; byGroup[g.id] = []; });
    chart.tasks.forEach(function (t) {
      if (!t.note || amb[t.id]) return;
      if (t.group !== null && gids[t.group]) byGroup[t.group].push(t); else ungrouped.push(t);
    });
    var out = { h: [] };
    ungrouped.forEach(function (t) { out['t:' + t.id] = []; });
    chart.groups.forEach(function (g) {
      out['g:' + g.id] = [];
      byGroup[g.id].forEach(function (t) { out['t:' + t.id] = []; });
    });
    // A block joined onto a non-empty one gets one blank line between them
    // (§5.3 W6), so a bold line and an indented copy never meet as LEGACY.
    function join(k, b) {
      if (!b.length) return;
      out[k] = out[k].length ? out[k].concat([''], b) : b.slice();
    }
    var lastKey = 'h';
    keys.forEach(function (k) {
      var b = attachIn[k] || [];
      if (own(out, k)) { lastKey = k; join(k, b); } else join(lastKey, b);
    });
    function sep(first) { return /^[^ \t]/.test(first) && !ITEM_RE.test(first) && !LINK_RE.test(first); }
    function blockText(k) {
      var b = out[k];
      return b.length ? '\n' + (sep(b[0]) ? '\n' : '') + b.join('\n') : '';
    }
    function owned(t) {
      return '- ' + (t.milestone ? '◆ ' : '') + '[' + ltext(t.title) + '](synapseresource://note/' + t.note + '?via=gantt)' +
        rest(t, summaryOf(summaries, t)) + blockText('t:' + t.id);
    }
    var parts = [hashes(conf.L) + ' ' + htext(conf.h)];
    if (chart.settings.embed === true && !opts.embedOutside && uuid()) parts.push(B.embedLine());
    if (out.h.length) parts.push(out.h.join('\n'));
    if (ungrouped.length) parts.push(ungrouped.map(owned).join('\n'));
    var mk = hashes(conf.L + 1) + ' ';
    chart.groups.forEach(function (g) {
      parts.push(mk + htext(g.title) + blockText('g:' + g.id) + byGroup[g.id].map(function (t) { return '\n' + owned(t); }).join(''));
    });
    parts.push(B.fence(chart));
    return { text: parts.join('\n\n'), attach: out, spill: '' };
  };

  /* ------------------------------------------------------------------ read */

  function detect(src, ls, F, chart, fenceOnly) {
    function text(k) { return src.slice(ls[k].start, ls[k].end); }
    var i = F - 1;
    if (i < 0 || !blank(text(i))) return F;
    i -= 1;
    if (i < 0) return F;
    var ids = Object.create(null), anyNote = false, anyId = false;
    if (fenceOnly) anyNote = false;
    else if (chart && chart.settings.mirror !== false) {
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
   * read(text, {list, listDefault}) -> {status, chart, key, bodyKey,
   *   region:{start,end,text}|null, embedOutside, extra, shadowed, openAtEnd,
   *   dropped, reason, span, list, legacy, defaulted, missing, fallback, seed,
   *   spill, json, fold}
   * Never throws. Without opts.list: main spec §5.6 only (everything below
   * is off, list fields stay empty).
   *
   * A chart with settings.listHeading and the list on: the region starts at
   * the list heading and `list` is its parse (task-groups plan §5.2). With no
   * list heading, `missing` and `fallback` (§5.6) are set when a headless
   * list is found, and `region` stays main spec §5.6's (embed and fence), so
   * a save that ignores `missing` adds a list and never overwrites one.
   * A chart without listHeading (`legacy`) is read by main spec §5.6; with
   * opts.listDefault its chart gets that heading and a composite key.
   */
  B.read = function (text, opts) {
    opts = opts || {};
    var found = B.scan(text), src = found.src, ls = found.lines;
    var span = found.spans[0] || null;
    var out = {
      status: 'none', chart: null, key: null, bodyKey: null, region: null, embedOutside: false,
      extra: found.spans.length > 1 ? found.spans.length - 1 : 0, shadowed: found.shadowed,
      openAtEnd: found.openAtEnd, dropped: 0, reason: '', span: span,
      list: null, legacy: false, defaulted: false, missing: false, fallback: null, seed: null, spill: '',
      json: null, fold: null
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
      out.bodyKey = out.key;
      // The list is read only when the caller asks (opts.list, the phase-2
      // store); without it every chart is read by main spec §5.6, as an
      // older build does.
      var conf = !opts.list ? null : out.chart ? B.listConf(out.chart) : (out.status === 'malformed' ? rawConf(span.body) : null);
      var first = -1, code = null;
      if (conf && conf.on && conf.h !== null) {
        code = codeMask(src, ls);
        var hl = findHeading(src, ls, code, span.line, conf);
        if (hl >= 0) {
          first = hl;
          if (out.chart) out.list = parseList(src, ls, code, hl, span.line, out.chart, conf);
          else {
            // Malformed: every link is FOREIGN; the blocks come back as
            // `spill` for a forced Repair to write above the new region.
            var bare = { settings: {}, groups: [], tasks: [] };
            out.spill = spillOf(parseList(src, ls, code, hl, span.line, bare, conf).attach);
          }
        } else if (out.chart) {
          out.fallback = findFallback(src, ls, code, span.line, span.end, out.chart, conf);
          out.missing = !!out.fallback;
          if (!out.missing) out.list = emptyList(out.chart);
        }
      } else if (out.chart && conf && conf.on) {
        out.legacy = true;
        var def = strH(opts.listDefault);
        if (def !== null) {
          out.chart = B.withHeading(out.chart, def);
          out.defaulted = true;
          out.key = out.bodyKey + '#' + B.hash('default\n' + norm(def));
        }
      }
      // In the missing state the region is the fence (and an embed line on
      // it): the headless list's task lines are never part of it.
      if (first < 0) first = detect(src, ls, span.line, out.missing ? null : out.chart, out.missing);
      if (out.chart && conf && conf.on && !out.missing) out.seed = parseSeed(src, ls, code || codeMask(src, ls), first, out.chart, conf);
      // G2 (§6.1, §6.2): the list decides membership, order and group
      // titles; fr.chart is the chart the note describes. `json` keeps the
      // block's own chart, `fold` the report and inverse. The key becomes
      // composite only when the fold changed the chart. Never on a future,
      // malformed, missing, legacy or list-off read.
      if (out.status === 'ok' && out.list && out.list.heading && !out.missing && !out.legacy) {
        var f = M().applyList(out.chart, out.list);
        out.json = out.chart;
        out.fold = f;
        if (f.changed) {
          out.chart = f.chart;
          out.key = out.bodyKey + '#' + B.hash(out.list.sig);
        }
      }
      out.region = { start: ls[first].start, end: span.end, text: src.slice(ls[first].start, span.end) };
      skipFrom = out.missing ? Math.min(first, out.fallback.line) : first;
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
  B.mirrorGap = function (text, opts) {
    // With opts.list, a list chart is answered from listReport (review
    // round 2): main spec §5.6 detection would call every task edited.
    if (opts && opts.list) {
      var lr = B.listReport(text, opts);
      return lr && !lr.missing ? { key: lr.key, deleted: lr.deleted, edited: lr.edited } : null;
    }
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

  /*
   * listReport(text, opts) -> null or the §6.3 report inputs of a read with
   * the list on (pure; the fold itself is model.applyList, G2):
   *   {key, bodyKey, missing, deleted:[taskId], edited:[taskId],
   *    goneGroups:[gid], moved:[{id, from, to}], renamed:[{id, from, to}],
   *    newGroups:[{id, title, line}], held:[taskId], ambiguous:[taskId],
   *    duplicates, plainElsewhere:[taskId], foreign:[offer], promote}
   * A noted task with no line in the region is `edited` when its note link
   * is still in the note (outside the region or in an attached line), else
   * `deleted`. A gone group is always deleted. Held: tasks under a duplicate
   * marker or whose JSON group is gone; `placement` is the fold's (Remove).
   * moved/renamed/newGroups are relative to the block's own chart (`json`).
   * Also `seed` and the fold's report. Legacy charts report deleted and
   * edited only.
   */
  B.listReport = function (text, opts) {
    var src = String(text == null ? '' : text), r = B.read(src, Object.assign({}, opts, { list: true }));
    if (r.status !== 'ok' || !r.chart || !r.region || r.chart.settings.mirror === false) return null;
    var out = { key: r.key, bodyKey: r.bodyKey, missing: r.missing, deleted: [], edited: [], goneGroups: [], moved: [],
      renamed: [], newGroups: [], held: [], ambiguous: [], duplicates: [], plainElsewhere: [], foreign: [], promote: [],
      placement: {}, seed: r.seed, fold: r.fold ? r.fold.report : null };
    if (r.missing) return out;
    // The block's own chart: moves and renames are relative to it (G2: the
    // read's chart is the folded one).
    var c = r.json || r.chart, list = r.list, have = Object.create(null), tid = Object.create(null);
    c.tasks.forEach(function (t) { if (t.note) tid[t.note] = t.id; });
    if (list) list.rows.forEach(function (row) { if (row.task) have[row.task] = true; });
    else {
      r.region.text.split('\n').forEach(function (l) {
        var p = B.parseLine(l.replace(/\r$/, ''));
        if (p && p.id && tid[p.id]) have[tid[p.id]] = true;
      });
    }
    // §6.3 "Gone or edited" (G2): edited while its note link is still in the
    // note, outside the region or in an attached line of it; else deleted.
    // A task with no LINK row has no link in the region except in attached
    // TEXT or CODE lines, so the whole note is searched.
    c.tasks.forEach(function (t) {
      if (!t.note || have[t.id]) return;
      var base = 'synapseresource://note/' + t.note;
      (src.indexOf(base + '?via=gantt)') >= 0 || src.indexOf(base + ')') >= 0 ? out.edited : out.deleted).push(t.id);
    });
    if (!list) return out;
    if (r.fold) out.placement = r.fold.report.placement;
    var gone = Object.create(null), byId = Object.create(null), gById = Object.create(null);
    list.gone.forEach(function (g) { gone[g] = true; out.goneGroups.push(g); });
    c.tasks.forEach(function (t) { byId[t.id] = t; });
    c.groups.forEach(function (g) { gById[g.id] = g; });
    list.sections.forEach(function (s) {
      var m = s.marker, dup = !!m && m.kind === 'duplicate';
      if (m && (m.kind === 'overlap' || m.kind === 'position')) out.renamed.push({ id: m.gid, from: gById[m.gid].title, to: m.title });
      if (m && m.kind === 'new') out.newGroups.push({ id: m.gid, title: m.title, line: m.line });
      s.tasks.forEach(function (id) {
        var t = byId[id];
        if (dup || (t.group !== null && gone[t.group])) { out.held.push(id); return; }
        if (t.group !== s.gid) out.moved.push({ id: id, from: t.group, to: s.gid });
      });
    });
    out.ambiguous = list.ambiguous.slice();
    out.duplicates = list.duplicates.slice();
    out.plainElsewhere = list.plainElsewhere.slice();
    out.foreign = list.offers.slice();
    out.promote = list.promote.slice();
    return out;
  };

  // Restore heading (§5.6): the note with the list heading inserted after
  // P0, or null when the note is not in the missing heading state.
  B.restoreHeading = function (text, opts) {
    var src = String(text == null ? '' : text), r = B.read(src, Object.assign({}, opts, { list: true }));
    if (!r.missing) return null;
    return src.slice(0, r.fallback.start) + r.fallback.restore + src.slice(r.fallback.end);
  };

  /* ---------------------------------------------------------------- splice */

  // Replace the detected region with `region`, or append it after a blank
  // line when the note has none. Bytes outside the region are untouched.
  // opts are read's; a malformed list region's attached lines (`spill`)
  // are kept above the new region.
  B.splice = function (text, region, opts) {
    var src = String(text == null ? '' : text);
    var r = B.read(src, opts);
    if (r.region) return src.slice(0, r.region.start) + (r.spill ? r.spill + '\n\n' : '') + region + src.slice(r.region.end);
    if (!src.length) return region;
    var pad = /\r?\n\r?\n$/.test(src) ? '' : (/\r?\n$/.test(src) ? '\n' : '\n\n');
    return src + pad + region;
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
