/*
 * Gantt - the chart model.
 *
 * chart = { v, settings:{...,_x}, groups:[{id,title,color,_x}],
 *           tasks:[{id,note,title,start,end,group,color,milestone,after,progress,_x}], _x }
 *
 * start and end are day numbers (GT.dates) in memory, YYYY-MM-DD in JSON.
 * Charts are immutable: every transform returns {chart, inverse} where
 * inverse is a patch list that applyPatch turns back into the old chart.
 * Unknown keys at every level live in `_x` and are written back verbatim.
 * A known key whose stored value is unusable is kept in `_x` too (a
 * "shadow"), so it is re-emitted unchanged until the user sets that field.
 *
 * Ids are the prefix ('t' or 'g') plus six random base-36 characters, so an
 * id is never issued twice and two devices adding at once never collide.
 */
(function (global) {
  'use strict';
  var GT = (global.GT = global.GT || {});
  var M = (GT.model = {});
  var D = GT.dates;

  M.V = 1;
  M.COLORS = ['indigo', 'blue', 'sky', 'teal', 'emerald', 'amber', 'orange', 'rose', 'pink', 'violet', 'slate'];
  M.AUTO_HUES = M.COLORS.filter(function (c) { return c !== 'slate'; });
  M.SOURCES = ['subnotes', 'checklist', 'status', 'none'];
  // Replaceable for deterministic tests.
  M.random = function () { return Math.random(); };

  var ID = /^[A-Za-z0-9_-]+$/;
  var ALPHABET = '0123456789abcdefghijklmnopqrstuvwxyz';

  // Settings in key order (the order written to JSON), with defaults.
  var SETTINGS = [
    ['progressSource', 'subnotes'], ['progressSection', 'Checklist'], ['childTasks', true],
    ['progressStyle', 'fill'], ['colorBy', 'status'], ['scale', 'week'], ['weekStart', null],
    ['workdays', [1, 2, 3, 4, 5]], ['holidays', []], ['mirror', true], ['embed', false],
    ['syncDates', false]
  ];
  var SETTING_KEYS = SETTINGS.map(function (p) { return p[0]; });
  var TASK_KEYS = ['id', 'note', 'title', 'start', 'end', 'group', 'color', 'milestone', 'after', 'progress'];
  var GROUP_KEYS = ['id', 'title', 'color'];
  var TOP_KEYS = ['v', 'settings', 'groups', 'tasks'];
  M.SETTING_KEYS = SETTING_KEYS.slice();
  M.TASK_KEYS = TASK_KEYS.slice();

  function has(o, k) { return !!o && Object.prototype.hasOwnProperty.call(o, k); }
  function own(o, k) { return has(o, k) ? o[k] : undefined; }
  // Plain assignment of '__proto__' would change the prototype, so unknown
  // keys are always defined as own data properties.
  function put(o, k, v) { Object.defineProperty(o, k, { value: v, enumerable: true, writable: true, configurable: true }); }
  // Key-order independent identity of JSON-like values.
  function stable(x) {
    if (x === undefined) return 'undefined';
    if (Array.isArray(x)) return '[' + x.map(stable).join(',') + ']';
    if (x && typeof x === 'object') {
      return '{' + Object.keys(x).sort().map(function (k) { return JSON.stringify(k) + ':' + stable(x[k]); }).join(',') + '}';
    }
    return JSON.stringify(x);
  }
  function same(a, b) { return stable(a) === stable(b); }
  function clone(x) { return x === undefined ? undefined : JSON.parse(JSON.stringify(x)); }
  function isObj(x) { return !!x && typeof x === 'object' && !Array.isArray(x); }
  function copyX(x, drop) {
    var o = {};
    if (x) Object.keys(x).forEach(function (k) { if (k !== drop) put(o, k, x[k]); });
    return o;
  }
  M.same = same;
  M.stable = stable;

  function defaults() {
    var s = {};
    SETTINGS.forEach(function (p) { s[p[0]] = clone(p[1]); });
    s._x = {};
    return s;
  }

  M.empty = function () { return { v: M.V, settings: defaults(), groups: [], tasks: [], _x: {} }; };

  /* ------------------------------------------------------------------- ids */

  function takenIds(chart) {
    var t = Object.create(null);
    chart.tasks.forEach(function (x) { t[x.id] = true; });
    chart.groups.forEach(function (x) { t[x.id] = true; });
    return t;
  }

  function freshId(prefix, taken) {
    for (;;) {
      var s = prefix;
      for (var i = 0; i < 6; i++) s += ALPHABET.charAt(Math.min(35, Math.floor(M.random() * 36)));
      if (!taken[s]) { taken[s] = true; return s; }
    }
  }

  // Deterministic ids for records a hand-written block left without one, so
  // two reads of the same note give the same chart.
  function derivedId(prefix, seed, taken) {
    for (var salt = 0; ; salt++) {
      var h = 0x811c9dc5, s = seed + '#' + salt;
      for (var i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
      var id = prefix + ('000000' + (h % 2176782336).toString(36)).slice(-6);
      if (!taken[id]) { taken[id] = true; return id; }
    }
  }

  M.nextId = function (chart, prefix) { return freshId(prefix || 't', takenIds(chart)); };

  /* ---------------------------------------------------------------- coerce */

  function isDay(x) { return D.parse(x) !== null; }

  function coerceSettings(raw, bad) {
    var s = defaults();
    if (!isObj(raw)) return s;
    Object.keys(raw).forEach(function (k) {
      var v = raw[k], okv = false;
      if (SETTING_KEYS.indexOf(k) < 0) { put(s._x, k, clone(v)); return; }
      switch (k) {
        case 'progressSource': case 'progressSection': case 'progressStyle': case 'colorBy': case 'scale':
          okv = typeof v === 'string';
          if (okv) s[k] = v;
          break;
        case 'childTasks': case 'mirror': case 'embed': case 'syncDates':
          okv = typeof v === 'boolean';
          if (okv) s[k] = v;
          break;
        case 'weekStart':
          okv = v === null || (typeof v === 'number' && v >= 0 && v <= 6 && v === Math.floor(v));
          if (okv) s[k] = v;
          break;
        case 'workdays':
          if (Array.isArray(v)) {
            okv = true;
            var w = [];
            v.forEach(function (d) {
              if (typeof d === 'number' && d >= 0 && d <= 6 && d === Math.floor(d)) { if (w.indexOf(d) < 0) w.push(d); }
              else bad.n++;
            });
            s[k] = w.sort();
          }
          break;
        case 'holidays':
          if (Array.isArray(v)) {
            okv = true;
            var h = [];
            v.forEach(function (d) { if (isDay(d)) { if (h.indexOf(d) < 0) h.push(d); } else bad.n++; });
            s[k] = h;
          }
          break;
      }
      if (!okv) { put(s._x, k, clone(v)); bad.n++; }
    });
    return s;
  }

  function coerceGroup(raw, bad) {
    if (!isObj(raw)) return null;
    var g = { id: typeof raw.id === 'string' && ID.test(raw.id) ? raw.id : null, title: '', color: null, _x: {} };
    Object.keys(raw).forEach(function (k) {
      var v = raw[k];
      if (k === 'id') return;
      if (k === 'title' && typeof v === 'string') { g.title = v; return; }
      if (k === 'color' && typeof v === 'string') { g.color = v; return; }
      put(g._x, k, clone(v));
      if (GROUP_KEYS.indexOf(k) >= 0) bad.n++;
    });
    return g;
  }

  function coerceTask(raw, bad) {
    if (!isObj(raw)) return null;
    var t = { id: typeof raw.id === 'string' && ID.test(raw.id) ? raw.id : null, note: null, title: '', start: null,
      end: null, group: null, color: null, milestone: false, after: [], progress: null, _x: {} };
    Object.keys(raw).forEach(function (k) {
      var v = raw[k], okv = true;
      switch (k) {
        case 'id': return;
        case 'note': okv = typeof v === 'string' && ID.test(v); if (okv) t.note = v; break;
        case 'title': okv = typeof v === 'string'; if (okv) t.title = v; break;
        case 'start': case 'end': okv = isDay(v); if (okv) t[k] = D.clamp(D.parse(v)); break;
        case 'group': okv = typeof v === 'string'; if (okv) t.group = v; break;
        case 'color': okv = typeof v === 'string'; if (okv) t.color = v; break;
        case 'progress': okv = typeof v === 'string'; if (okv) t.progress = v; break;
        case 'milestone': okv = typeof v === 'boolean'; if (okv) t.milestone = v; break;
        case 'after':
          okv = Array.isArray(v);
          if (okv) v.forEach(function (a) { if (typeof a === 'string' && t.after.indexOf(a) < 0) t.after.push(a); else if (typeof a !== 'string') bad.n++; });
          break;
        default: put(t._x, k, clone(v)); return;
      }
      if (!okv) { put(t._x, k, clone(v)); bad.n++; }
    });
    if (t.start === null && t.end !== null) { t.start = t.end; t.end = null; }
    if (t.milestone && t.end !== null) { t.end = null; bad.n++; }
    if (t.start !== null && t.end !== null && t.end < t.start) { var x = t.start; t.start = t.end; t.end = x; }
    if (t.end === t.start) t.end = null;   // one-day task: canonical form has no end
    // A shadow is kept only while its field reads as its default; a field
    // that ended up with a real value (an end moved into the start) has none.
    if (t.start !== null && has(t._x, 'start')) t._x = copyX(t._x, 'start');
    return t;
  }

  // Drop `after` edges to missing tasks, to self and those closing a cycle.
  // Edges are admitted in document order, so the result is deterministic.
  function cleanDeps(tasks) {
    var ids = Object.create(null), dropped = 0;
    tasks.forEach(function (t) { ids[t.id] = true; });
    var edges = Object.create(null);
    function reaches(from, to) {
      var stack = [from], seen = Object.create(null);
      while (stack.length) {
        var c = stack.pop();
        if (c === to) return true;
        if (seen[c]) continue;
        seen[c] = true;
        (edges[c] || []).forEach(function (n) { stack.push(n); });
      }
      return false;
    }
    var out = tasks.map(function (t) {
      var keep = [];
      t.after.forEach(function (a) {
        if (!ids[a] || a === t.id || keep.indexOf(a) >= 0 || reaches(a, t.id)) { dropped++; return; }
        keep.push(a);
        (edges[t.id] = edges[t.id] || []).push(a);
      });
      if (keep.length === t.after.length) return t;
      var c = copyTask(t);
      c.after = keep;
      return c;
    });
    return { tasks: out, dropped: dropped };
  }

  // JSON data (as parsed from the block) to a chart. Never throws. `dropped`
  // counts records and values that were discarded or set aside as shadows.
  M.coerce = function (data) {
    var chart = M.empty(), bad = { n: 0 };
    if (!isObj(data)) return { chart: chart, dropped: 0 };
    if (typeof data.v === 'number' && data.v >= 1 && data.v === Math.floor(data.v)) chart.v = data.v;
    chart.settings = coerceSettings(own(data, 'settings'), bad);

    // Derived ids must not depend on position, so an edit elsewhere in a
    // hand-written block never renames a record: a task with a note seeds
    // on the note (unique, D20); anything else on its content plus how many
    // records with the same content came before it.
    var seen = Object.create(null);
    function seedOf(kind, raw, note) {
      if (note) return kind + ':n:' + note;
      var body = {};
      Object.keys(raw).forEach(function (k) { if (k !== 'id') put(body, k, raw[k]); });
      var s = kind + ':' + stable(body);
      seen[s] = (seen[s] || 0) + 1;
      return s + '#' + seen[s];
    }

    var taken = Object.create(null), groups = [], rawGroups = Array.isArray(own(data, 'groups')) ? data.groups : [];
    var explicit = Object.create(null);
    var gs = rawGroups.map(function (raw) {
      var g = coerceGroup(raw, bad);
      if (!g) { bad.n++; return null; }
      // A repeated id keeps the record under a derived id (counted).
      if (g.id !== null && explicit[g.id]) { g.id = null; bad.n++; }
      if (g.id !== null) { explicit[g.id] = true; taken[g.id] = true; }
      return g;
    });
    var rawTasks = Array.isArray(own(data, 'tasks')) ? data.tasks : [];
    rawTasks.forEach(function (raw) { if (isObj(raw) && typeof raw.id === 'string' && ID.test(raw.id)) taken[raw.id] = true; });
    gs.forEach(function (g, k) {
      if (!g) return;
      if (g.id === null) g.id = derivedId('g', seedOf('g', rawGroups[k], null), taken);
      groups.push(g);
    });
    chart.groups = groups;
    var gids = Object.create(null);
    groups.forEach(function (g) { gids[g.id] = true; });

    var tids = Object.create(null), notes = Object.create(null), tasks = [];
    rawTasks.forEach(function (raw) {
      var t = coerceTask(raw, bad);
      if (!t) { bad.n++; return; }
      if (t.note === null && !t.milestone) { bad.n++; return; }
      if (t.note !== null && notes[t.note]) { bad.n++; return; }
      if (t.id !== null && tids[t.id]) { t.id = null; bad.n++; }
      if (t.group !== null && !gids[t.group]) { put(t._x, 'group', t.group); t.group = null; bad.n++; }
      if (t.note !== null) notes[t.note] = true;
      if (t.id === null) t.id = derivedId('t', seedOf('t', raw, t.note), taken);
      tids[t.id] = true;
      tasks.push(t);
    });
    var deps = cleanDeps(tasks);
    chart.tasks = deps.tasks;

    Object.keys(data).forEach(function (k) { if (TOP_KEYS.indexOf(k) < 0) put(chart._x, k, clone(data[k])); });
    return { chart: chart, dropped: bad.n + deps.dropped };
  };

  /* ---------------------------------------------------------------- toData */

  function putX(o, x) { if (x) Object.keys(x).forEach(function (k) { if (!has(o, k)) put(o, k, clone(x[k])); }); }

  M.settingsData = function (s) {
    var o = {};
    SETTINGS.forEach(function (p) {
      var k = p[0];
      if (s[k] === undefined || same(s[k], p[1])) return;
      o[k] = clone(s[k]);
    });
    putX(o, s._x);
    return o;
  };

  M.groupData = function (g) {
    var o = { id: g.id };
    if (g.title) o.title = g.title;
    if (g.color !== null && g.color !== undefined) o.color = g.color;
    putX(o, g._x);
    return o;
  };

  M.taskData = function (t) {
    var o = { id: t.id };
    if (t.note !== null && t.note !== undefined) o.note = t.note;
    if (t.title) o.title = t.title;
    if (t.start !== null && t.start !== undefined) o.start = D.format(t.start);
    if (t.end !== null && t.end !== undefined && !t.milestone) o.end = D.format(t.end);
    if (t.group !== null && t.group !== undefined) o.group = t.group;
    if (t.color !== null && t.color !== undefined) o.color = t.color;
    if (t.milestone) o.milestone = true;
    if (t.after && t.after.length) o.after = t.after.slice();
    if (t.progress !== null && t.progress !== undefined) o.progress = t.progress;
    putX(o, t._x);
    return o;
  };

  // A chart to JSON data in canonical key order, defaults omitted.
  M.toData = function (chart) {
    var o = { v: chart.v || M.V };
    var s = M.settingsData(chart.settings || defaults());
    if (Object.keys(s).length) o.settings = s;
    if (chart.groups.length) o.groups = chart.groups.map(M.groupData);
    if (chart.tasks.length) o.tasks = chart.tasks.map(M.taskData);
    putX(o, chart._x);
    return o;
  };

  /* ------------------------------------------------------------ transforms */

  function copyTask(t) {
    var c = {};
    TASK_KEYS.forEach(function (k) { c[k] = t[k] === undefined ? (k === 'milestone' ? false : null) : t[k]; });
    c.after = (t.after || []).slice();
    c._x = t._x || {};
    return c;
  }
  function copyGroup(g) {
    return { id: g.id, title: typeof g.title === 'string' ? g.title : '', color: g.color === undefined ? null : g.color, _x: g._x || {} };
  }
  function withTasks(chart, tasks) {
    return { v: chart.v, settings: chart.settings, groups: chart.groups, tasks: tasks, _x: chart._x };
  }
  function withGroups(chart, groups, tasks) {
    return { v: chart.v, settings: chart.settings, groups: groups, tasks: tasks || chart.tasks, _x: chart._x };
  }
  function indexOf(list, id) {
    for (var i = 0; i < list.length; i++) if (list[i].id === id) return i;
    return -1;
  }
  M.task = function (chart, id) { var i = indexOf(chart.tasks, id); return i < 0 ? null : chart.tasks[i]; };
  M.group = function (chart, id) { var i = indexOf(chart.groups, id); return i < 0 ? null : chart.groups[i]; };

  function noop(chart) { return { chart: chart, inverse: [] }; }
  function day(x) { return typeof x === 'number' && isFinite(x) ? D.clamp(Math.round(x)) : null; }

  /*
   * Set task fields; the inverse holds the old values of fields that changed.
   * Setting a known field drops its shadow from `_x`; `_x` itself may be set
   * whole (inverses use that to put a shadow back).
   */
  function setFields(chart, id, fields) {
    var i = indexOf(chart.tasks, id);
    if (i < 0) return noop(chart);
    var old = chart.tasks[i], t = copyTask(old), prev = {}, changed = false;
    Object.keys(fields).forEach(function (k) {
      if (k === '_x') {
        if (!same(t._x, fields._x)) { if (!has(prev, '_x')) prev._x = t._x; t._x = fields._x || {}; changed = true; }
        return;
      }
      if (TASK_KEYS.indexOf(k) < 0 || k === 'id') return;
      var v = k === 'after' ? (fields[k] || []).slice() : fields[k];
      if (!same(old[k], v)) {
        prev[k] = k === 'after' ? old[k].slice() : old[k];
        t[k] = v;
        changed = true;
      }
      if (has(t._x, k)) {
        if (!has(prev, '_x')) prev._x = t._x;
        t._x = copyX(t._x, k);
        changed = true;
      }
    });
    if (!changed) return noop(chart);
    var tasks = chart.tasks.slice();
    tasks[i] = t;
    return { chart: withTasks(chart, tasks), inverse: [{ op: 'set', id: id, fields: prev }] };
  }

  // Normalised dates for a task: clamped, swapped, one-day and milestone rules.
  function dates(start, end, milestone) {
    var s = day(start), e = day(end);
    if (s === null && e !== null) { s = e; e = null; }
    if (s !== null && e !== null && e < s) { var x = s; s = e; e = x; }
    if (milestone || e === s) e = null;
    return { start: s, end: e };
  }

  // Add tasks from partial specs. Notes already on the chart are skipped (D20).
  M.addTasks = function (chart, specs, opts) {
    opts = opts || {};
    var tasks = chart.tasks.slice(), notes = Object.create(null), added = [], skipped = 0, taken = takenIds(chart);
    tasks.forEach(function (t) { if (t.note) notes[t.note] = true; });
    var at = typeof opts.index === 'number' ? Math.max(0, Math.min(tasks.length, opts.index)) : tasks.length;
    (specs || []).forEach(function (sp) {
      var note = typeof sp.note === 'string' && ID.test(sp.note) ? sp.note : null;
      var ms = sp.milestone === true;
      if ((note === null && !ms) || (note !== null && notes[note])) { skipped++; return; }
      var d = dates(sp.start, sp.end, ms);
      var t = {
        id: freshId('t', taken), note: note, title: typeof sp.title === 'string' ? sp.title : '',
        start: d.start, end: d.end,
        group: sp.group !== undefined ? sp.group : (opts.group !== undefined ? opts.group : null),
        color: typeof sp.color === 'string' ? sp.color : null,
        milestone: ms, after: [], progress: typeof sp.progress === 'string' ? sp.progress : null, _x: {}
      };
      if (t.group !== null && !M.group(chart, t.group)) t.group = null;
      if (note) notes[note] = true;
      tasks.splice(at++, 0, t);
      added.push(t.id);
    });
    if (!added.length) return { chart: chart, inverse: [], added: [], skipped: skipped };
    var inverse = added.slice().reverse().map(function (id) { return { op: 'remove', id: id }; });
    return { chart: withTasks(chart, tasks), inverse: inverse, added: added, skipped: skipped };
  };

  // Shift a task in time, keeping its calendar length. Unscheduled: no-op.
  M.moveTask = function (chart, id, delta) {
    var t = M.task(chart, id);
    if (!t || t.start === null || !delta) return noop(chart);
    var d = dates(t.start + delta, t.end === null ? null : t.end + delta, t.milestone);
    if (d.start === t.start && d.end === t.end) return noop(chart);
    return setFields(chart, id, d);
  };

  // Move one edge to `day`, clamped so end >= start. Milestones never resize.
  M.resizeTask = function (chart, id, edge, at) {
    var t = M.task(chart, id);
    at = day(at);
    if (!t || t.milestone || at === null) return noop(chart);
    if (t.start === null) return setFields(chart, id, { start: at, end: null });
    var end = t.end === null ? t.start : t.end;
    if (edge === 'start') return setFields(chart, id, dates(Math.min(at, end), end, false));
    return setFields(chart, id, dates(t.start, Math.max(at, t.start), false));
  };

  // Set both dates; an end before the start is swapped. null start unschedules.
  M.setDates = function (chart, id, start, end) {
    var t = M.task(chart, id);
    if (!t) return noop(chart);
    return setFields(chart, id, dates(start, end, t.milestone));
  };

  // Move a task to index `toIndex` of the task list; optionally regroup it
  // (groupId null means ungrouped, undefined leaves the group alone).
  M.reorder = function (chart, id, toIndex, groupId) {
    var i = indexOf(chart.tasks, id);
    if (i < 0) return noop(chart);
    var oldIds = chart.tasks.map(function (t) { return t.id; });
    var tasks = chart.tasks.slice();
    var t = tasks.splice(i, 1)[0];
    var to = Math.max(0, Math.min(tasks.length, toIndex | 0));
    var inverse = [];
    if (groupId !== undefined && groupId !== t.group && (groupId === null || M.group(chart, groupId))) {
      var r = setFields(withTasks(chart, [t]), id, { group: groupId });
      inverse = r.inverse;
      t = r.chart.tasks[0];
    }
    tasks.splice(to, 0, t);
    if (to !== i) inverse.unshift({ op: 'order', ids: oldIds });
    if (!inverse.length) return noop(chart);
    return { chart: withTasks(chart, tasks), inverse: inverse };
  };

  // Remove a task and every `after` reference to it. The note is untouched.
  M.removeTask = function (chart, id) {
    var i = indexOf(chart.tasks, id);
    if (i < 0) return noop(chart);
    var inverse = [{ op: 'insert', task: chart.tasks[i], index: i, prev: i > 0 ? chart.tasks[i - 1].id : null }];
    var tasks = [];
    chart.tasks.forEach(function (t, k) {
      if (k === i) return;
      if (t.after.indexOf(id) >= 0) {
        inverse.push({ op: 'set', id: t.id, fields: { after: t.after.slice() } });
        var c = copyTask(t);
        c.after = t.after.filter(function (a) { return a !== id; });
        tasks.push(c);
      } else tasks.push(t);
    });
    return { chart: withTasks(chart, tasks), inverse: inverse };
  };

  // Set any task fields. A note already on another task (D20), an unknown
  // group or a dependency cycle is refused; dates go through the setDates rules.
  M.setTask = function (chart, id, fields) {
    var t = M.task(chart, id);
    if (!t) return noop(chart);
    var f = {};
    Object.keys(fields || {}).forEach(function (k) { if (k !== '_x') f[k] = fields[k]; });
    var ms = has(f, 'milestone') ? f.milestone === true : t.milestone;
    if (has(f, 'milestone')) f.milestone = ms;
    if (has(f, 'note')) {
      var n = f.note;
      var clash = chart.tasks.some(function (x) { return x.id !== id && x.note === n; });
      if (!((n === null && ms) || (typeof n === 'string' && ID.test(n) && !clash))) delete f.note;
    }
    if (!has(f, 'note') && t.note === null && !ms) delete f.milestone;   // a note-less task must stay a milestone
    if (has(f, 'start') || has(f, 'end') || has(f, 'milestone')) {
      var d = dates(has(f, 'start') ? f.start : t.start, has(f, 'end') ? f.end : t.end, has(f, 'milestone') ? f.milestone : t.milestone);
      if (has(f, 'start') || d.start !== t.start) f.start = d.start;
      if (has(f, 'end') || d.end !== t.end) f.end = d.end;
    }
    if (has(f, 'group') && f.group !== null && !M.group(chart, f.group)) delete f.group;
    if (has(f, 'title') && typeof f.title !== 'string') delete f.title;
    if (has(f, 'after')) f.after = acyclicAfter(chart, id, f.after);
    return setFields(chart, id, f);
  };

  // The entries of `after` that task `id` may hold in `chart`: existing
  // tasks, no repeats, not itself, and none closing a cycle through the
  // other tasks' edges, which are always kept.
  function acyclicAfter(chart, id, after) {
    var edges = Object.create(null);
    chart.tasks.forEach(function (x) { if (x.id !== id) edges[x.id] = x.after; });
    function reaches(from) {
      var stack = [from], seen = Object.create(null);
      while (stack.length) {
        var cur = stack.pop();
        if (cur === id) return true;
        if (seen[cur]) continue;
        seen[cur] = true;
        (edges[cur] || []).forEach(function (x) { stack.push(x); });
      }
      return false;
    }
    return (after || []).filter(function (a, k, arr) {
      return typeof a === 'string' && a !== id && edges[a] !== undefined && arr.indexOf(a) === k && !reaches(a);
    });
  }

  M.setDeps = function (chart, id, after) { return M.setTask(chart, id, { after: after || [] }); };

  M.addGroup = function (chart, spec, index) {
    spec = spec || {};
    var g = { id: freshId('g', takenIds(chart)), title: typeof spec.title === 'string' ? spec.title : '',
      color: typeof spec.color === 'string' ? spec.color : null, _x: {} };
    var groups = chart.groups.slice();
    var at = typeof index === 'number' ? Math.max(0, Math.min(groups.length, index)) : groups.length;
    groups.splice(at, 0, g);
    return { chart: withGroups(chart, groups), inverse: [{ op: 'group', group: null, id: g.id }], id: g.id };
  };

  M.renameGroup = function (chart, id, title, color) {
    var i = indexOf(chart.groups, id);
    if (i < 0) return noop(chart);
    var old = chart.groups[i];
    var g = copyGroup(old);
    if (typeof title === 'string') { g.title = title; if (has(g._x, 'title')) g._x = copyX(g._x, 'title'); }
    if (color !== undefined) { g.color = color; if (has(g._x, 'color')) g._x = copyX(g._x, 'color'); }
    if (same(g, old)) return noop(chart);
    var groups = chart.groups.slice();
    groups[i] = g;
    return { chart: withGroups(chart, groups), inverse: [{ op: 'group', group: old, id: id, index: i }] };
  };

  // Remove a group; its tasks become ungrouped.
  M.removeGroup = function (chart, id) {
    var i = indexOf(chart.groups, id);
    if (i < 0) return noop(chart);
    var inverse = [{ op: 'group', group: chart.groups[i], id: id, index: i }];
    var tasks = chart.tasks.map(function (t) {
      if (t.group !== id) return t;
      inverse.push({ op: 'set', id: t.id, fields: { group: id } });
      var c = copyTask(t);
      c.group = null;
      return c;
    });
    var groups = chart.groups.slice();
    groups.splice(i, 1);
    return { chart: withGroups(chart, groups, tasks), inverse: inverse };
  };

  M.setSettings = function (chart, fields) {
    var s = {}, prev = {}, changed = false;
    SETTING_KEYS.forEach(function (k) { s[k] = chart.settings[k]; });
    s._x = chart.settings._x;
    Object.keys(fields || {}).forEach(function (k) {
      if (k === '_x') {
        if (!same(s._x, fields._x)) { if (!has(prev, '_x')) prev._x = s._x; s._x = fields._x || {}; changed = true; }
        return;
      }
      if (SETTING_KEYS.indexOf(k) < 0) return;
      if (!same(s[k], fields[k])) { prev[k] = clone(s[k]); s[k] = clone(fields[k]); changed = true; }
      if (has(s._x, k)) { if (!has(prev, '_x')) prev._x = s._x; s._x = copyX(s._x, k); changed = true; }
    });
    if (!changed) return noop(chart);
    return { chart: { v: chart.v, settings: s, groups: chart.groups, tasks: chart.tasks, _x: chart._x },
      inverse: [{ op: 'settings', fields: prev }] };
  };

  /* ------------------------------------------------------------ applyPatch */

  // The inverse of a note effect. `prev` carries the value before the effect
  // for kinds whose opposite is not implied (status, title).
  function flipBox(line) {
    return String(line).replace(/\[( |x|X)\]/, function (m, c) { return c === ' ' ? '[x]' : '[ ]'; });
  }
  function invertHost(p) {
    var a = p.args || {}, b = {};
    Object.keys(a).forEach(function (k) { b[k] = a[k]; });
    switch (p.kind) {
      case 'toggleItem': b.checked = !a.checked; b.line = flipBox(a.line); break;
      case 'toggleSubnote': b.done = !a.done; break;
      case 'setChildStatus': b.status = a.prev; b.prev = a.status; break;
      case 'renameChart': b.title = a.prev; b.prev = a.title; break;
    }
    return { op: 'host', kind: p.kind, args: b };
  }
  M.invertHost = invertHost;

  // Apply patches in order. Returns the new chart, the inverse (already in
  // undo order) and the host effects, which leave the chart untouched.
  // A patch naming a task or group that is gone does nothing.
  M.applyPatch = function (chart, patches) {
    var inverse = [], effects = [];
    (patches || []).forEach(function (p) {
      var r = applyOne(chart, p);
      chart = r.chart;
      if (r.effect) effects.push(r.effect);
      if (r.inverse) inverse.unshift(r.inverse);
    });
    // validFields already leaves out restored edges that close a cycle; this
    // is a safety net so the chart always reads back unchanged.
    var deps = cleanDeps(chart.tasks);
    if (deps.dropped) chart = withTasks(chart, deps.tasks);
    return { chart: chart, inverse: inverse, effects: effects };
  };

  // Patch values checked against the chart as it is now (a merge may have
  // removed a group or task, or given a note to another task): a value that
  // would make the chart invalid is left out.
  function validFields(chart, id, fields) {
    var f = {};
    Object.keys(fields).forEach(function (k) {
      var v = fields[k];
      if (k === 'group' && v !== null && !M.group(chart, v)) return;
      if (k === 'note' && v !== null && chart.tasks.some(function (x) { return x.id !== id && x.note === v; })) return;
      // Only the restored entries that would close a cycle are left out;
      // the other tasks' edges (possibly theirs, after a merge) stay.
      if (k === 'after') v = acyclicAfter(chart, id, v);
      f[k] = v;
    });
    return f;
  }

  function applyOne(chart, p) {
    if (!p || typeof p !== 'object') return { chart: chart };
    var i, tasks;
    switch (p.op) {
      case 'set': {
        var r = setFields(chart, p.id, validFields(chart, p.id, p.fields || {}));
        return { chart: r.chart, inverse: r.inverse[0] || null };
      }
      case 'insert': {
        if (!p.task || indexOf(chart.tasks, p.task.id) >= 0) return { chart: chart };
        // Their copy of the same note wins (D20): the insert does nothing.
        if (p.task.note && chart.tasks.some(function (x) { return x.note === p.task.note; })) return { chart: chart };
        var ins = p.task, vf = validFields(chart, ins.id, { group: ins.group, after: ins.after });
        if (!has(vf, 'group') || vf.after.length !== ins.after.length) {
          ins = copyTask(ins);
          if (!has(vf, 'group')) ins.group = null;
          ins.after = vf.after;
        }
        tasks = chart.tasks.slice();
        // After the task it followed when that one is still there, else at
        // the recorded index, so an insert elsewhere meanwhile does not shift it.
        var anchor = p.prev === null ? 0 : (typeof p.prev === 'string' ? indexOf(tasks, p.prev) : -1);
        i = p.prev === null ? 0 : (anchor >= 0 ? anchor + 1 : Math.max(0, Math.min(tasks.length, p.index | 0)));
        tasks.splice(i, 0, ins);
        return { chart: withTasks(chart, tasks), inverse: { op: 'remove', id: p.task.id } };
      }
      case 'remove': {
        i = indexOf(chart.tasks, p.id);
        if (i < 0) return { chart: chart };
        tasks = chart.tasks.slice();
        var gone = tasks.splice(i, 1)[0];
        return { chart: withTasks(chart, tasks), inverse: { op: 'insert', task: gone, index: i, prev: i > 0 ? tasks[i - 1].id : null } };
      }
      case 'order': {
        // The listed tasks take the slots they occupy now, in the listed
        // order. Unlisted tasks (added since) keep their slots.
        var want = (p.ids || []).filter(function (id, k, arr) { return indexOf(chart.tasks, id) >= 0 && arr.indexOf(id) === k; });
        var slots = [], cur = [];
        chart.tasks.forEach(function (t, k) { if (want.indexOf(t.id) >= 0) { slots.push(k); cur.push(t.id); } });
        if (same(cur, want)) return { chart: chart };
        tasks = chart.tasks.slice();
        want.forEach(function (id, k) { tasks[slots[k]] = chart.tasks[indexOf(chart.tasks, id)]; });
        return { chart: withTasks(chart, tasks), inverse: { op: 'order', ids: cur } };
      }
      case 'settings': {
        var rs = M.setSettings(chart, p.fields || {});
        return { chart: rs.chart, inverse: rs.inverse[0] || null };
      }
      case 'group': {
        i = indexOf(chart.groups, p.id);
        var groups = chart.groups.slice();
        if (!p.group) {
          if (i < 0) return { chart: chart };
          var old = groups.splice(i, 1)[0];
          return { chart: withGroups(chart, groups), inverse: { op: 'group', group: old, id: p.id, index: i } };
        }
        if (i >= 0) {
          var prev = groups[i];
          groups[i] = p.group;
          return { chart: withGroups(chart, groups), inverse: { op: 'group', group: prev, id: p.id, index: i } };
        }
        var at = typeof p.index === 'number' ? Math.max(0, Math.min(groups.length, p.index)) : groups.length;
        groups.splice(at, 0, p.group);
        return { chart: withGroups(chart, groups), inverse: { op: 'group', group: null, id: p.id } };
      }
      case 'host':
        return { chart: chart, effect: p, inverse: invertHost(p) };
    }
    return { chart: chart };
  }

  /* -------------------------------------------------------------- queries */

  // {min, max} day over every dated task, or null.
  M.range = function (chart) {
    var min = null, max = null;
    chart.tasks.forEach(function (t) {
      if (t.start === null) return;
      var e = t.end === null ? t.start : t.end;
      if (min === null || t.start < min) min = t.start;
      if (max === null || e > max) max = e;
    });
    return min === null ? null : { min: min, max: max };
  };

  // Refresh task titles from note facts ({noteId: {title}}). Not an undo step.
  M.titlesFrom = function (chart, facts) {
    var changed = false;
    var tasks = chart.tasks.map(function (t) {
      var f = t.note && facts && has(facts, t.note) ? facts[t.note] : null;
      if (!f || typeof f.title !== 'string' || f.missing || f.title === t.title) return t;
      changed = true;
      var c = copyTask(t);
      c.title = f.title;
      return c;
    });
    return changed ? withTasks(chart, tasks) : chart;
  };

  /* ------------------------------------------------ progress and status */

  // Note statuses stored by the host (plan §2.1).
  M.STATUSES = ['todo', 'in_progress', 'complete', 'abandoned'];
  M.CLASSES = ['none', 'todo', 'doing', 'done', 'late', 'dropped'];
  M.BITS_MAX = 64;

  // The progress source for a task: its own override, else the chart's,
  // else the default. Unknown values fall back for rendering (§5.5).
  M.sourceOf = function (task, settings) {
    var s = task && task.progress;
    if (M.SOURCES.indexOf(s) >= 0) return s;
    s = settings && settings.progressSource;
    return M.SOURCES.indexOf(s) >= 0 ? s : 'subnotes';
  };

  function count(x) { return Number.isSafeInteger(x) && x > 0 ? x : 0; }
  function statusOf(fact) { return fact && !fact.missing && M.STATUSES.indexOf(fact.status) >= 0 ? fact.status : null; }
  // One {done, total, bits} part with done clamped to total; bits is kept
  // only when it has one 0/1 per item.
  function counts(p) {
    var total = count(p && p.total), done = Math.min(total, count(p && p.done));
    var bits = p && typeof p.bits === 'string' && p.bits.length === total && /^[01]*$/.test(p.bits) ? p.bits : '';
    return { done: done, total: total, bits: bits, whole: bits.length === total };
  }

  /*
   * classify(fact, task, summary, today) -> one of M.CLASSES (§6.2), in
   * precedence order: dropped, done, late, doing, todo, none. `today` is a
   * day number. A task's last day is `end`, or `start` for a one-day task or
   * a milestone (D16 stores no end for those). Only a task with a resolved
   * note can be late: a note-less milestone has no status to finish. A
   * missing note classifies as 'none'; `missing` is a render flag. While
   * `summary.loading` is set, counts and dates give no class (they may be
   * stale or absent); only the note's status does.
   */
  M.classify = function (fact, task, summary, today) {
    summary = summary || {};
    if (fact && fact.missing) return 'none';
    var st = statusOf(fact);
    var total = count(summary.total), done = Math.min(total, count(summary.done));
    if (st === 'abandoned') return 'dropped';
    if (summary.loading) { total = 0; done = 0; }
    if (st === 'complete' || (total > 0 && done === total)) return 'done';
    var last = task ? (typeof task.end === 'number' ? task.end : task.start) : null;
    if (fact && !summary.loading && typeof last === 'number' && typeof today === 'number' && last < today) return 'late';
    if ((done > 0 && done < total) || (st === 'in_progress' && (total === 0 || summary.src === 'status'))) return 'doing';
    if (total > 0 && done === 0) return 'todo';
    return 'none';
  };

  /*
   * summarize(fact, task, settings, today) -> the §6.3 summary:
   *   {src, done, total, ratio, bits, found, partial, cls, overdue, chip,
   *    missing, loading}
   *
   * fact.prog is {src, done, total, bits, found?, partial?, child?}. For the
   * subnotes source done/total/bits are the subnotes table (§7.2) and
   * `child` the linked child tasks (§7.3), added when settings.childTasks is
   * not false (D4); bits are the subnote bits then the child bits. A prog
   * for another source (a changed setting or task override) is stale and
   * shows as loading, never as old counts (§7.5).
   */
  M.summarize = function (fact, task, settings, today) {
    settings = settings || {};
    var src = M.sourceOf(task, settings);
    var s = { src: src, done: 0, total: 0, ratio: null, bits: '', found: true, partial: false,
      cls: 'none', overdue: false, chip: '', missing: !!(fact && fact.missing), loading: false };
    var st = statusOf(fact), noted = !!(task && task.note);
    if (s.missing || !noted) {
      // nothing to count
    } else if (!fact) {
      s.loading = true;                    // every source needs the note
    } else if (src === 'status') {
      if (st) {
        s.total = 1;
        s.done = st === 'complete' ? 1 : 0;
        s.ratio = st === 'complete' ? 1 : (st === 'in_progress' ? 0.5 : 0);
      }
    } else if (src === 'subnotes' || src === 'checklist') {
      var p = fact && fact.prog;
      if (!p || p.src !== src) s.loading = true;
      else {
        var a = counts(p);
        if (src === 'subnotes' && settings.childTasks !== false && p.child) {
          var c = counts(p.child);
          a = { done: a.done + c.done, total: a.total + c.total, bits: a.whole && c.whole ? a.bits + c.bits : '' };
        }
        if (src === 'checklist') {
          s.found = p.found !== false;
          s.partial = !!p.partial;
          if (!s.found) a = { done: 0, total: 0, bits: '' };
        }
        s.done = a.done;
        s.total = a.total;
        s.bits = a.bits.length <= M.BITS_MAX ? a.bits : '';
        s.ratio = s.total > 0 ? s.done / s.total : null;
      }
    }
    s.cls = M.classify(fact, task, s, today);
    s.overdue = s.cls === 'late';
    s.chip = s.cls === 'done' ? '✓' : (s.total > 0 && src !== 'status' ? s.done + '/' + s.total : '');
    return s;
  };

  M.sameIgnoringTitles = function (a, b) {
    function strip(c) {
      var d = M.toData(c);
      (d.tasks || []).forEach(function (t) { delete t.title; });
      return stable(d);
    }
    return strip(a) === strip(b);
  };

  /* ---------------------------------------------------------------- merge3 */

  function byId(list) { var o = Object.create(null); list.forEach(function (x) { o[x.id] = x; }); return o; }
  function idOf(x) { return x.id; }

  // Field-wise three-way merge of one record. `keys` are the known fields;
  // unknown keys merge one by one as '_x.<key>'.
  function mergeRecord(prefix, keys, b, m, t, res, conflicts, soft) {
    var out = {};
    function pick(name, bv, mv, tv) {
      var mc = !same(bv, mv), tc = !same(bv, tv);
      if (!mc) return tv;
      if (!tc || same(mv, tv)) return mv;
      if (soft && soft.indexOf(name) >= 0) return tv;
      var key = prefix + name, r = own(res, key);
      if (r === 'mine') return mv;
      if (r === 'theirs') return tv;
      conflicts.push({ key: key, base: bv === undefined ? null : bv, mine: mv === undefined ? null : mv, theirs: tv === undefined ? null : tv });
      return tv;
    }
    keys.forEach(function (k) { out[k] = clone(pick(k, b ? b[k] : undefined, m[k], t[k])); });
    var x = {}, names = [];
    [t._x, m._x, b && b._x].forEach(function (src) {
      if (src) Object.keys(src).forEach(function (k) { if (names.indexOf(k) < 0) names.push(k); });
    });
    names.forEach(function (k) {
      var v = pick('_x.' + k, own(b && b._x, k), own(m._x, k), own(t._x, k));
      if (v !== undefined) put(x, k, clone(v));
    });
    out._x = x;
    return out;
  }

  // Order: theirs, then the ids I moved or added re-applied after their
  // predecessor in my order.
  function mergeOrder(baseIds, mineIds, theirIds, keep) {
    var inBase = Object.create(null);
    baseIds.forEach(function (id) { inBase[id] = true; });
    var common = mineIds.filter(function (id) { return inBase[id]; });
    var baseCommon = baseIds.filter(function (id) { return mineIds.indexOf(id) >= 0; });
    var stay = lcs(baseCommon, common);
    var moved = Object.create(null);
    // Moved by me, added by me, or kept by me after theirs removed it.
    mineIds.forEach(function (id) {
      if (!inBase[id] || stay.indexOf(id) < 0 || theirIds.indexOf(id) < 0) moved[id] = true;
    });
    var out = theirIds.filter(function (id) { return keep[id] && !moved[id]; });
    mineIds.forEach(function (id, k) {
      if (!moved[id] || !keep[id] || out.indexOf(id) >= 0) return;
      var at = 0;
      for (var j = k - 1; j >= 0; j--) {
        var p = out.indexOf(mineIds[j]);
        if (p >= 0) { at = p + 1; break; }
      }
      out.splice(at, 0, id);
    });
    Object.keys(keep).forEach(function (id) { if (keep[id] && out.indexOf(id) < 0) out.push(id); });
    return out;
  }

  function lcs(a, b) {
    var n = a.length, m = b.length, L = [], i, j;
    for (i = 0; i <= n; i++) L.push(new Array(m + 1).fill(0));
    for (i = n - 1; i >= 0; i--) for (j = m - 1; j >= 0; j--) {
      L[i][j] = a[i] === b[j] ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1]);
    }
    var out = [];
    i = 0; j = 0;
    while (i < n && j < m) {
      if (a[i] === b[j]) { out.push(a[i]); i++; j++; }
      else if (L[i + 1][j] >= L[i][j + 1]) i++;
      else j++;
    }
    return out;
  }

  // A record's identity for "was it edited": its JSON data, key order and
  // in-memory shape ignored; for tasks the title is ignored too.
  function editKey(kind, x) {
    var d = kind === 'task' ? M.taskData(copyTask(x)) : M.groupData(copyGroup(x));
    if (kind === 'task') delete d.title;
    return stable(d);
  }

  // Merge a list of records (tasks or groups) by id.
  function mergeList(kind, keys, bl, ml, tl, res, conflicts, soft) {
    var B = byId(bl), Mi = byId(ml), T = byId(tl);
    var ids = [];
    [tl, ml, bl].forEach(function (l) { l.forEach(function (x) { if (ids.indexOf(x.id) < 0) ids.push(x.id); }); });
    var out = Object.create(null), keep = Object.create(null);
    var shape = kind === 'task' ? copyTask : copyGroup;
    ids.forEach(function (id) {
      var b = B[id], m = Mi[id], t = T[id];
      var key = id + '.removed';
      if (b && !m && !t) return;
      if (b && (!m || !t)) {
        // Removed on one side: fine when the other side left it alone.
        if (editKey(kind, b) === editKey(kind, m || t)) return;
        var r = own(res, key);
        if (!r) { conflicts.push({ key: key, base: b, mine: m || null, theirs: t || null }); r = 'theirs'; }
        if ((r === 'mine' && !m) || (r === 'theirs' && !t)) return;
        out[id] = shape(r === 'mine' ? m : t);
      } else if (!b && m && !t) out[id] = shape(m);
      else if (!b && !m && t) out[id] = shape(t);
      else {
        var rec = mergeRecord(id + '.', keys, b || null, m, t, res, conflicts, soft);
        rec.id = id;
        out[id] = shape(rec);
      }
      keep[id] = true;
    });
    var order = mergeOrder(bl.map(idOf), ml.map(idOf), tl.map(idOf), keep);
    return order.map(function (id) { return out[id]; });
  }

  /*
   * merge3(base, mine, theirs, {resolutions}) -> {chart, conflicts, remap}
   *
   * Per task, group and setting, per field. One-sided changes win; the same
   * field changed to different values on both sides is a conflict, reported as
   * {key, base, mine, theirs} unless `resolutions[key]` is 'mine' or 'theirs'.
   * Keys: '<id>.<field>', '<id>._x.<key>', '<id>.removed' (removed on one side,
   * edited on the other), 'settings.<key>', 'settings._x.<key>', '_x.<key>'.
   * Unresolved conflicts take theirs in the returned chart. Titles never
   * conflict (theirs wins): they are last-seen copies, never authoritative.
   * No id is ever changed: ids are random, so both sides adding at once do
   * not collide. The one exception is D20: a note both sides added under
   * different ids keeps theirs, and `remap` maps my dropped id to theirs.
   */
  M.merge3 = function (base, mine, theirs, opts) {
    var res = (opts && opts.resolutions) || {};
    var conflicts = [];
    base = base || M.empty();

    var baseIds = byId(base.tasks), theirNotes = Object.create(null), remap = {};
    theirs.tasks.forEach(function (t) { if (t.note) theirNotes[t.note] = t.id; });
    var mineTasks = mine.tasks.filter(function (t) {
      if (baseIds[t.id] || !t.note || !theirNotes[t.note] || theirNotes[t.note] === t.id) return true;
      remap[t.id] = theirNotes[t.note];
      return false;
    }).map(function (t) {
      if (!t.after.some(function (a) { return has(remap, a); })) return t;
      var c = copyTask(t);
      c.after = t.after.map(function (a) { return has(remap, a) ? remap[a] : a; });
      return c;
    });

    var settings = mergeRecord('settings.', SETTING_KEYS, base.settings, mine.settings, theirs.settings, res, conflicts);
    var groups = mergeList('group', ['title', 'color'], base.groups, mine.groups, theirs.groups, res, conflicts);
    var tasks = mergeList('task', TASK_KEYS.filter(function (k) { return k !== 'id'; }),
      base.tasks, mineTasks, theirs.tasks, res, conflicts, ['title']);
    var top = mergeRecord('', [], { _x: base._x }, { _x: mine._x }, { _x: theirs._x }, res, conflicts);
    var out = { v: Math.max(mine.v || 1, theirs.v || 1), settings: settings, groups: groups, tasks: tasks, _x: top._x };
    return { chart: M.normalize(out), conflicts: conflicts, remap: remap };
  };

  // Repair invariants a merge can break: dangling groups and deps, notes
  // appearing twice, milestones with an end, an end before the start.
  M.normalize = function (chart) {
    var gids = Object.create(null), groups = [];
    chart.groups.forEach(function (g) { if (!gids[g.id]) { gids[g.id] = true; groups.push(copyGroup(g)); } });
    var notes = Object.create(null), tids = Object.create(null), tasks = [];
    chart.tasks.forEach(function (t) {
      if (tids[t.id] || (t.note && notes[t.note]) || (!t.note && !t.milestone)) return;
      tids[t.id] = true;
      if (t.note) notes[t.note] = true;
      var c = copyTask(t);
      if (c.group !== null && !gids[c.group]) c.group = null;
      var d = dates(c.start, c.end, c.milestone);
      c.start = d.start;
      c.end = d.end;
      tasks.push(c);
    });
    return { v: chart.v, settings: chart.settings, groups: groups, tasks: cleanDeps(tasks).tasks, _x: chart._x };
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
