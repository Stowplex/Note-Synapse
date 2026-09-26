/*
 * Gantt layout (plan §11.5, §12.4, §6.2): rows, bar geometry, handles,
 * content bounds and the colour of a bar. Pure: no DOM, no host.
 *
 * Rows are flattened in D15 order: ungrouped scheduled tasks with no
 * header, then per group a header row and its scheduled tasks (skipped when
 * collapsed), then the synthetic Unscheduled group holding every task with
 * no start. Each row is {kind, id, task, group, gi, y, h, n, collapsed}
 * with a prefix-sum y.
 */
(function (global) {
  'use strict';
  var GT = (global.GT = global.GT || {});
  var L = (GT.layout = {});

  L.UNSCHED = '~unscheduled';     // never a valid group id ([A-Za-z0-9_-]+)
  L.DENSITY = {
    comfortable: { row: 44, bar: 26, grp: 32 },
    compact: { row: 36, bar: 22, grp: 28 }
  };
  L.MS_SIZE = 16;                 // milestone diamond (§11.5)
  L.HIT_MIN = 44;                 // minimum hit width (§14.2)
  L.HANDLE = 44;
  L.HANDLE_INSIDE_MIN = 3 * 44;   // two inside handles plus 44 px to press
  L.LABEL_INSIDE_MIN = 56;        // label inside the bar from this width (§11.5)
  L.CHIP_MIN = 90;                // chip hidden below this width (§12.4)

  function isSet(c, id) {
    if (!c) return false;
    if (typeof c.has === 'function') return c.has(id);
    if (Array.isArray(c)) return c.indexOf(id) >= 0;
    return !!c[id];
  }

  L.dens = function (density, rowH) {
    var d = L.DENSITY[density] || L.DENSITY.comfortable;
    if (typeof rowH === 'number' && rowH > 0) return { row: rowH, bar: Math.min(d.bar, rowH - 12), grp: d.grp };
    return d;
  };

  /*
   * buildRows(chart, collapsed, density, opts) -> {rows, totalH, index, groups}
   *   collapsed  Set, array or map of group ids (L.UNSCHED collapses the
   *              Unscheduled group)
   *   opts.rowH  row height override (tablet, §14.1)
   *   index      taskId -> row index (absent when its group is collapsed)
   *   groups     groupId -> row index of the header
   */
  L.buildRows = function (chart, collapsed, density, opts) {
    opts = opts || {};
    var d = L.dens(density, opts.rowH);
    var rows = [], index = {}, groups = {}, y = 0;
    var known = {};
    chart.groups.forEach(function (g, i) { known[g.id] = i; });
    function push(r) { r.y = y; y += r.h; rows.push(r); return r; }
    function taskRow(t, g, gi) {
      index[t.id] = rows.length;
      push({ kind: 'task', id: t.id, task: t, group: g, gi: gi, h: d.row });
    }
    var scheduled = function (t) { return typeof t.start === 'number'; };
    chart.tasks.forEach(function (t) {
      if (scheduled(t) && !(t.group && Object.prototype.hasOwnProperty.call(known, t.group))) taskRow(t, null, -1);
    });
    chart.groups.forEach(function (g, gi) {
      var list = chart.tasks.filter(function (t) { return t.group === g.id && scheduled(t); });
      var shut = isSet(collapsed, g.id);
      groups[g.id] = rows.length;
      push({ kind: 'group', id: g.id, task: null, group: g, gi: gi, h: d.grp, n: list.length, collapsed: shut });
      if (!shut) list.forEach(function (t) { taskRow(t, g, gi); });
    });
    var un = chart.tasks.filter(function (t) { return !scheduled(t); });
    if (un.length) {
      var shutU = isSet(collapsed, L.UNSCHED);
      groups[L.UNSCHED] = rows.length;
      push({ kind: 'group', id: L.UNSCHED, task: null, group: null, gi: -1, h: d.grp, n: un.length, collapsed: shutU, unscheduled: true });
      if (!shutU) {
        un.forEach(function (t) {
          var gi = t.group && Object.prototype.hasOwnProperty.call(known, t.group) ? known[t.group] : -1;
          taskRow(t, gi >= 0 ? chart.groups[gi] : null, gi);
        });
      }
    }
    return { rows: rows, totalH: y, index: index, groups: groups, dens: d };
  };

  /*
   * visibleRange(rows, y0, y1) -> {first, last}: the rows that intersect
   * [y0, y1), by binary search. first > last when none do. `out` is reused
   * when given (the frame loop allocates nothing).
   */
  L.visibleRange = function (rows, y0, y1, out) {
    var lo = 0, hi = rows.length;
    while (lo < hi) {                        // first row whose bottom is below y0
      var mid = (lo + hi) >> 1;
      if (rows[mid].y + rows[mid].h > y0) hi = mid; else lo = mid + 1;
    }
    var first = lo;
    lo = first; hi = rows.length;
    while (lo < hi) {                        // first row starting at or after y1
      var m2 = (lo + hi) >> 1;
      if (rows[m2].y >= y1) hi = m2; else lo = m2 + 1;
    }
    var o = out || {};
    o.first = first;
    o.last = lo - 1;
    return o;
  };

  // The row holding content y, or -1.
  L.rowAt = function (rows, y) {
    if (!rows.length || y < 0) return -1;
    var r = L.visibleRange(rows, y, y + 0.0001);
    return r.first <= r.last ? r.first : -1;
  };

  /*
   * barGeom(task, row, cam, dens, out) -> {x, w, y, h, ms} in CONTENT
   * pixels (the bars layer is translated by the camera). The end is
   * inclusive (D16). A milestone is a MS_SIZE diamond centred on its day.
   * Pass `out` to reuse an object. Null for an unscheduled task.
   */
  L.barGeom = function (task, row, cam, dens, out) {
    if (!task || typeof task.start !== 'number') return null;
    var g = out || {};
    var ppd = cam.ppd, x0 = (task.start - cam.epoch) * ppd;
    if (task.milestone) {
      var s = L.MS_SIZE;
      g.x = Math.round(x0 + ppd / 2 - s / 2);
      g.w = s;
      g.y = Math.round(row.y + (row.h - s) / 2);
      g.h = s;
      g.ms = true;
      return g;
    }
    var end = typeof task.end === 'number' ? task.end : task.start;
    var x1 = (end + 1 - cam.epoch) * ppd;
    g.x = Math.round(x0);
    g.w = Math.max(2, Math.round(x1) - g.x);
    g.y = Math.round(row.y + (row.h - dens.bar) / 2);
    g.h = dens.bar;
    g.ms = false;
    return g;
  };

  // The hit box of a bar: row height by max(width, 44), centred on the bar.
  L.hitBox = function (geom, row) {
    var w = Math.max(geom.w, L.HIT_MIN);
    return { x: geom.x + geom.w / 2 - w / 2, y: row.y, w: w, h: row.h };
  };

  /*
   * handleRects(geom) -> {s, e} 44 x 44 boxes centred on the bar's middle:
   * inside the bar ends from 132 px wide, outside them below (§14.2). Null
   * for a milestone (milestones never resize).
   */
  L.handleRects = function (geom) {
    if (!geom || geom.ms) return null;
    var H = L.HANDLE, y = geom.y + geom.h / 2 - H / 2;
    // Inside only when 44 px of bar stay between them for a MOVE press (M6 review).
    var inside = geom.w >= L.HANDLE_INSIDE_MIN;
    return {
      s: { x: inside ? geom.x : geom.x - H, y: y, w: H, h: H },
      e: { x: inside ? geom.x + geom.w - H : geom.x + geom.w, y: y, w: H, h: H },
      outside: !inside
    };
  };

  /*
   * reorderTarget(rows, chart, id, y) -> where task `id` lands when the
   * centre of its dragged row is at content y (§13.2 REORDER), or null.
   *   index   the model.reorder toIndex (in chart.tasks without the task)
   *   group   the group it joins: a group id, null (ungrouped), or
   *           undefined (unchanged: an unscheduled task stays in its group)
   *   from    the dragged row's index in rows
   *   lo, hi, dir  rows lo..hi shift by dir * the dragged row's height
   *           (dir -1 up, +1 down; lo > hi when none shift)
   *   y       the content y of the dropped row's top in the current rows
   *   changed whether a drop here changes the chart
   * A scheduled task stays among the scheduled rows; an unscheduled one
   * stays inside the Unscheduled group (it has no dates to show elsewhere).
   * Collapsed group headers are targets like any header.
   */
  L.reorderTarget = function (rows, chart, id, y) {
    var from = -1, uIdx = rows.length;
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].kind === 'task' && rows[i].id === id) from = i;
      if (rows[i].kind === 'group' && rows[i].id === L.UNSCHED) uIdx = i;
    }
    if (from < 0) return null;
    var task = rows[from].task, hd = rows[from].h;
    var sched = typeof task.start === 'number';
    // The candidate rows of the dragged row's region, in order, without it.
    var lo0 = sched ? 0 : uIdx, hi0 = sched ? uIdx - 1 : rows.length - 1;
    var cand = [];
    for (var k = lo0; k <= hi0; k++) if (k !== from) cand.push(k);
    // Heights as if the dragged row were gone. A row is above the dragged
    // one once the dragged edge passed its middle: its top plus half of
    // both heights is above the dragged centre (rows of different heights
    // swap symmetrically, and a drop in place changes nothing).
    function yWithout(k) { return k > from ? rows[k].y - hd : rows[k].y; }
    var p = 0;
    while (p < cand.length && yWithout(cand[p]) + (rows[cand[p]].h + hd) / 2 < y) p++;
    if (!sched && p < 1) p = 1;                       // never above the Unscheduled header
    var above = p > 0 ? rows[cand[p - 1]] : null;
    var below = p < cand.length ? cand[p] : (sched ? uIdx : rows.length);
    var ids = chart.tasks.filter(function (t) { return t.id !== id; });
    function at(tid) { for (var j = 0; j < ids.length; j++) if (ids[j].id === tid) return j; return -1; }
    var index, group;
    if (!sched) {
      group = undefined;
      if (above && above.kind === 'task') index = at(above.id) + 1;
      else {
        var firstU = -1;
        for (var u = 0; u < ids.length; u++) if (typeof ids[u].start !== 'number') { firstU = u; break; }
        index = firstU >= 0 ? firstU : ids.length;
      }
    } else if (!above) {
      group = null;
      index = 0;
    } else if (above.kind === 'task') {
      group = above.group ? above.group.id : null;
      index = at(above.id) + 1;
    } else {
      group = above.id;
      var first = -1;
      for (var q = 0; q < ids.length; q++) if (ids[q].group === above.id) { first = q; break; }
      index = first >= 0 ? first : ids.length;
    }
    var out = { index: index, group: group, from: from, lo: 0, hi: -1, dir: 0, y: 0, changed: false };
    if (below > from) { out.lo = from + 1; out.hi = below - 1; out.dir = -1; }
    else { out.lo = below; out.hi = from - 1; out.dir = 1; }
    out.y = above ? yWithout(cand[p - 1]) + above.h : (sched ? 0 : rows[uIdx].y + rows[uIdx].h);
    var cur = -1;
    for (var c = 0; c < chart.tasks.length; c++) if (chart.tasks[c].id === id) { cur = c; break; }
    // An ungrouped task keeps a group id that names no group (a shadow,
    // §5.3): staying ungrouped leaves it alone.
    if (out.group === null && !validGroup(chart, task.group)) out.group = undefined;
    // The dragged row's own slot: a drop there changes nothing, even when
    // the task list holds hidden (unscheduled) tasks next to it.
    var own = 0;
    while (own < cand.length && cand[own] < from) own++;
    out.changed = p !== own && (index !== cur || (out.group !== undefined && out.group !== task.group));
    if (!out.changed) { out.lo = 0; out.hi = -1; out.dir = 0; }
    return out;
  };
  function validGroup(chart, gid) {
    if (!gid) return false;
    for (var i = 0; i < chart.groups.length; i++) if (chart.groups[i].id === gid) return true;
    return false;
  }

  /*
   * contentBounds(chart, rows, cam, today) -> {minX, maxX, totalH}: the
   * dated span (widened to include today) in content pixels, for
   * scale.clampCamera.
   */
  L.contentBounds = function (chart, built, cam, today, out) {
    var r = GT.model.range(chart);
    var lo = r ? Math.min(r.min, today) : today, hi = r ? Math.max(r.max, today) : today;
    var o = out || {};
    o.minX = (lo - cam.epoch) * cam.ppd;
    o.maxX = (hi + 1 - cam.epoch) * cam.ppd;
    o.totalH = built.totalH;
    return o;
  };

  // The epoch of §11.2: 60 days before the earliest date or today.
  L.epochFor = function (chart, today) {
    var r = GT.model.range(chart);
    return (r ? Math.min(r.min, today) : today) - GT.scale.EPOCH_PAD;
  };

  /*
   * colorFor(task, summary, groupIndex, settings, group) -> palette name
   * (§6.2). A task's own colour wins in every mode (it is an override);
   * then group mode uses the group's colour or an automatic hue, task mode
   * an automatic hue (never slate), status mode the class. Unknown names
   * fall back.
   */
  var STATUS_HUE = { done: 'emerald', late: 'rose', doing: 'blue', todo: 'slate', none: 'slate', dropped: 'slate' };
  function valid(c) { return GT.model.COLORS.indexOf(c) >= 0; }
  function hashNum(s) { return parseInt(GT.block.hash(String(s)), 16) >>> 0; }
  L.colorFor = function (task, summary, groupIndex, settings, group) {
    var by = settings && settings.colorBy;
    var auto = GT.model.AUTO_HUES;
    if (task && valid(task.color)) return task.color;
    if (by === 'group') {
      if (group && valid(group.color)) return group.color;
      // Ungrouped tasks are neutral (M8 review): not the first group's hue.
      if (!(groupIndex >= 0)) return 'slate';
      return auto[groupIndex % auto.length];
    }
    if (by === 'task') {
      return auto[hashNum(task ? (task.note || task.id) : '') % auto.length];
    }
    var cls = summary && summary.cls;
    return STATUS_HUE[cls] || 'slate';
  };
  L.STATUS_HUE = STATUS_HUE;

  /* ------------------------------------------- completion styles (§12.4) */

  L.STYLES = ['fill', 'segments', 'dots'];
  L.SEG_MAX = 24;                 // segments fall back to fill above this many cells
  L.SEG_MIN_CELL = 6;             // ... or when a cell would be narrower (px)
  L.SEG_GAP = 2;                  // px between cells
  L.DOTS_MAX = 12;                // then "+n"
  L.DOTS_INSIDE_MIN_H = 24;       // bar height from which dots sit under the label

  // The style a chart asks for; unknown values render as fill (§5.5).
  L.styleOf = function (settings) {
    var s = settings && settings.progressStyle;
    return L.STYLES.indexOf(s) >= 0 ? s : 'fill';
  };
  // Whether n segment cells fit a bar w px wide (2 px gaps, 6 px cells).
  L.segFits = function (n, w) {
    if (!(n > 0) || n > L.SEG_MAX) return false;
    return (w - L.SEG_GAP * (n - 1)) / n >= L.SEG_MIN_CELL;
  };
  function pct(i, n) { return Math.round(i * 1e6 / n) / 1e4 + '%'; }
  // Cell i's right edge (and the next cell's left edge): half the gap each side.
  function edgeAt(i, n, side) {
    if (i <= 0) return '0%';
    if (i >= n) return '100%';
    return 'calc(' + pct(i, n) + (side < 0 ? ' - ' : ' + ') + (L.SEG_GAP / 2) + 'px)';
  }
  /*
   * segmentStops(bits, w, late) -> null (fall back to fill) or
   *   {n, done, mask, image, late}
   * One cell per bit in bits order (§12.4, D11): done cells in --h-fill,
   * open cells in --h-tint, or --warn at 35% with a 45° hatch when the task
   * is late. Stops are percentages with the gap in px (calc), so the
   * strings do not depend on the bar width and are rebuilt only when bits,
   * lateness or style change (§14.3 rule 7).
   *   mask   the cells opaque, the 2 px gaps transparent (mask-image)
   *   image  background-image layers: the done cells over the late hatch
   * w (optional) checks the width fallback: cells under 6 px.
   */
  L.segmentStops = function (bits, w, late) {
    var n = typeof bits === 'string' ? bits.length : 0;
    if (!n || n > L.SEG_MAX || !/^[01]+$/.test(bits)) return null;
    if (typeof w === 'number' && !L.segFits(n, w)) return null;
    var mask = [], cells = [], stripe = [], done = 0;
    for (var i = 0; i < n; i++) {
      var end = edgeAt(i + 1, n, -1);
      if (i > 0) mask.push('transparent 0 ' + edgeAt(i, n, 1));
      mask.push('#000 0 ' + end);
      var on = bits.charAt(i) === '1';
      if (on) done++;
      cells.push((on ? 'var(--h-fill)' : 'transparent') + ' 0 ' + end);
      stripe.push((on ? 'transparent' : 'var(--warn)') + ' 0 ' + end);
    }
    var image = 'linear-gradient(90deg, ' + cells.join(', ') + ')';
    // Late open cells (M8 review, calmer): solid --warn-soft (the element's
    // colour) with a 2 px --warn stripe on top, sized by CSS (.g-seg.late).
    var isLate = !!late && done < n;
    if (isLate) image += ', linear-gradient(90deg, ' + stripe.join(', ') + ')';
    return { n: n, done: done, late: isLate, mask: 'linear-gradient(90deg, ' + mask.join(', ') + ')', image: image };
  };
  /*
   * dotsOf(summary) -> {list, more}: the dots style's row (§12.4). list is
   * one character per shown dot, 'd' done, 'o' open, 'l' open and late, in
   * bits order (or the done ones first when bits is unknown); at most 12,
   * `more` counts the rest ("+n").
   */
  L.dotsOf = function (summary) {
    var s = summary || {}, total = s.total > 0 ? s.total : 0, done = Math.min(total, s.done > 0 ? s.done : 0);
    var bits = typeof s.bits === 'string' && s.bits.length === total && /^[01]*$/.test(s.bits) ? s.bits : '';
    var open = s.cls === 'late' ? 'l' : 'o', list = '';
    var shown = Math.min(total, L.DOTS_MAX);
    for (var i = 0; i < shown; i++) list += (bits ? bits.charAt(i) === '1' : i < done) ? 'd' : open;
    return { list: list, more: total - shown };
  };

  /*
   * dotsStyle(list) -> {image, pos, width}: a dots row as background layers
   * of one element (6 px dots every 9 px): done a disc in --dot-on, open a
   * ring, late a --warn centre inside an --dot-on ring (3:1 on the fill,
   * M8 review). --dot-on is --h-ink inside the bar, --h-fill under it.
   */
  L.DOT_STEP = 9;
  var DOT = {
    d: 'radial-gradient(circle, var(--dot-on) 0 2.6px, transparent 3px)',
    o: 'radial-gradient(circle, transparent 0 1.6px, var(--dot-on) 1.9px 2.7px, transparent 3px)',
    l: 'radial-gradient(circle, var(--warn) 0 1.5px, var(--dot-on) 1.9px 2.7px, transparent 3px)'
  };
  L.dotsStyle = function (list) {
    var img = [], pos = [];
    for (var i = 0; i < list.length; i++) { img.push(DOT[list.charAt(i)] || DOT.o); pos.push(i * L.DOT_STEP + 'px 0'); }
    return { image: img.join(', ') || 'none', pos: pos.join(', ') || '0 0', width: list.length ? list.length * L.DOT_STEP : 0 };
  };

  /*
   * ghostGeom(row, cam, dens, today, out) -> the dashed 5-day ghost bar of
   * an unscheduled task, at today (§12.6). Content pixels, like barGeom.
   */
  L.GHOST_DAYS = 5;
  L.ghostGeom = function (row, cam, dens, today, out) {
    var g = out || {};
    g.x = Math.round((today - cam.epoch) * cam.ppd);
    g.w = Math.max(2, Math.round((today + L.GHOST_DAYS - cam.epoch) * cam.ppd) - g.x);
    g.y = Math.round(row.y + (row.h - dens.bar) / 2);
    g.h = dens.bar;
    g.ms = false;
    return g;
  };

  /*
   * legend(chart, classes, settings) -> the legend card's content (§12.7):
   *   {by, style, rows: [{kind: 'class'|'group', key, hue, label}],
   *    extras: ['today', 'weekend'?, 'milestone'?], owned}
   * owned: a task has its own colour, which the status and group modes keep
   * (tasks in o.missing, {taskId: 1}, do not count: they are drawn slate).
   * classes: the classes present on the chart (plus 'missing'). Labels are
   * English source strings (the caller translates class labels; group
   * titles are note text).
   */
  var CLASS_ORDER = ['done', 'doing', 'late', 'todo', 'none', 'dropped', 'missing'];
  var CLASS_LABEL = { done: 'Done', doing: 'In progress', late: 'Overdue', todo: 'To do', none: 'No sub-items', dropped: 'Dropped', missing: 'Missing note' };
  L.CLASS_LABEL = CLASS_LABEL;
  L.legend = function (chart, classes, settings, o) {
    o = o || {};
    var set = settings || {}, by = ['status', 'group', 'task'].indexOf(set.colorBy) >= 0 ? set.colorBy : 'status';
    var rows = [], seen = {};
    (classes || []).forEach(function (c) { seen[c] = 1; });
    if (by === 'status') {
      CLASS_ORDER.forEach(function (c) {
        if (seen[c]) rows.push({ kind: 'class', key: c, hue: c === 'missing' ? 'slate' : STATUS_HUE[c], label: CLASS_LABEL[c] });
      });
    } else {
      if (by === 'group') {
        var known = {};
        (chart ? chart.groups : []).forEach(function (g, i) {
          known[g.id] = 1;
          rows.push({ kind: 'group', key: g.id, hue: L.colorFor(null, null, i, { colorBy: 'group' }, g), label: g.title || '' });
        });
        if (chart && chart.tasks.some(function (t) { return !t.group || !known[t.group]; })) rows.push({ kind: 'group', key: '', hue: 'slate', label: 'No group', nogroup: true });
      }
      // Colour shows the group or task here, so the status cues that are
      // not colour get their own rows (M8 review): overdue, dropped, missing.
      ['late', 'dropped', 'missing'].forEach(function (c) {
        if (seen[c]) rows.push({ kind: 'cue', key: c, hue: 'slate', label: CLASS_LABEL[c] });
      });
    }
    var extras = ['today'];
    if (o.weekends !== false) extras.push('weekend');
    if (chart && chart.tasks.some(function (t) { return t.milestone; })) extras.push('milestone');
    // A task's own colour overrides status and group colours (device feedback round 1).
    // A missing note is drawn slate whatever its colour, so it does not count (o.missing: {taskId: 1}).
    var gone = o.missing || {};
    var owned = by !== 'task' && !!chart && chart.tasks.some(function (t) { return valid(t.color) && !gone[t.id]; });
    return { by: by, style: L.styleOf(set), rows: rows, extras: extras, owned: owned };
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
