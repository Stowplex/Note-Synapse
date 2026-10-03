/*
 * Gantt G3 chart UX assertions (task-groups plan §8.1, §8.2, §8.3, §8.7,
 * §8.8, §10.1 "layout"): buildRows counts and the drag-only No-group slot
 * row, reorderTarget's header bands and slot, the camera compensation,
 * stepTarget (Alt+Up/Down), the renderer's header states on a small fake
 * DOM, and the PRESS_GROUP long press. Runs under node (dev/run.js) and in
 * the browser (dev/auto_smoke.html).
 */
(function (global) {
  'use strict';
  var GT = global.GT, SPEC = GT.spec;
  var A = SPEC.api, ok = A.ok, eq = A.eq;
  var LY = GT.layout, M = GT.model, D = GT.dates, G = GT.gestures, I = GT.i18n;

  function json(x) { return JSON.stringify(x); }
  function chart(d) { return M.coerce(d).chart; }
  function rowIds(b) { return b.rows.map(function (r) { return r.id; }).join(' '); }
  function rowIdx(rows, id) { for (var i = 0; i < rows.length; i++) if (rows[i].id === id) return i; return -1; }
  function rowOf(rows, id) { return rows[rowIdx(rows, id)]; }
  function order(c) { return c.tasks.map(function (t) { return t.id + (t.group ? '/' + t.group : ''); }).join(' '); }
  function idsWithout(c, id) { return c.tasks.filter(function (t) { return t.id !== id; }).map(function (t) { return t.id; }); }
  function apply(c, id, t) { return M.reorder(c, id, t.index, t.group).chart; }

  /*
   * A: u1 ungrouped; s1 ungrouped with a shadow group; g1 Discovery a1 a2
   * (x2 undated); g2 Build b1 b2; g3 Later empty; g4 Someday x3 (undated
   * only); x1 ungrouped undated. Rows: u1 s1 g1 a1 a2 g2 b1 b2 g3 g4
   * ~unscheduled x1 x2 x3.
   */
  function chartA() {
    return chart({
      v: 1,
      groups: [{ id: 'g1', title: 'Discovery' }, { id: 'g2', title: 'Build' }, { id: 'g3', title: 'Later' }, { id: 'g4', title: 'Someday' }],
      tasks: [
        { id: 'u1', note: 'n-u1', title: 'U1', start: '2026-10-01', end: '2026-10-03' },
        { id: 'a1', note: 'n-a1', title: 'A1', start: '2026-10-02', end: '2026-10-05', group: 'g1' },
        { id: 'x1', note: 'n-x1', title: 'X1' },
        { id: 'a2', note: 'n-a2', title: 'A2', start: '2026-10-06', end: '2026-10-09', group: 'g1' },
        { id: 'b1', note: 'n-b1', title: 'B1', start: '2026-10-07', end: '2026-10-12', group: 'g2' },
        { id: 'b2', note: 'n-b2', title: 'B2', start: '2026-10-11', group: 'g2', milestone: true },
        { id: 'x2', note: 'n-x2', title: 'X2', group: 'g1' },
        { id: 's1', note: 'n-s1', title: 'S1', start: '2026-10-04', group: 'zz' },
        { id: 'x3', note: 'n-x3', title: 'X3', group: 'g4' }
      ]
    });
  }
  /*
   * B: no scheduled ungrouped task. g1 a1 a2; g2 b1 (x2 undated); g3 empty;
   * x1 ungrouped undated.
   */
  function chartB(extra) {
    var tasks = [
      { id: 'a1', note: 'n-a1', title: 'A1', start: '2026-10-02', end: '2026-10-05', group: 'g1' },
      { id: 'x1', note: 'n-x1', title: 'X1' },
      { id: 'a2', note: 'n-a2', title: 'A2', start: '2026-10-06', end: '2026-10-09', group: 'g1' },
      { id: 'b1', note: 'n-b1', title: 'B1', start: '2026-10-07', end: '2026-10-12', group: 'g2' },
      { id: 'x2', note: 'n-x2', title: 'X2', group: 'g2' }
    ];
    for (var i = 0; i < (extra || 0); i++) {
      tasks.push({ id: 'e' + i, note: 'n-e' + i, title: 'E' + i, start: '2026-10-' + (10 + (i % 18)), group: i % 2 ? 'g1' : 'g2' });
    }
    return chart({ v: 1, groups: [{ id: 'g1', title: 'Discovery' }, { id: 'g2', title: 'Build' }, { id: 'g3', title: 'Later' }], tasks: tasks });
  }
  function built(c, collapsed, slot, density) { return LY.buildRows(c, collapsed || [], density || 'comfortable', { dragSlot: !!slot }); }

  /* ---------------------------------------------------------------- M6 oracle */
  // The M6 reorderTarget as it stood before G3 (layout.js at 2026-09-27),
  // kept as an oracle: outside a band or the slot, G3 must answer the same.
  function m6Target(rows, chart0, id, y) {
    var from = -1, uIdx = rows.length;
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].kind === 'task' && rows[i].id === id) from = i;
      if (rows[i].kind === 'group' && rows[i].id === LY.UNSCHED) uIdx = i;
    }
    if (from < 0) return null;
    var task = rows[from].task, hd = rows[from].h, sched = typeof task.start === 'number';
    var lo0 = sched ? 0 : uIdx, hi0 = sched ? uIdx - 1 : rows.length - 1, cand = [];
    for (var k = lo0; k <= hi0; k++) if (k !== from) cand.push(k);
    function yWithout(k) { return k > from ? rows[k].y - hd : rows[k].y; }
    var p = 0;
    while (p < cand.length && yWithout(cand[p]) + (rows[cand[p]].h + hd) / 2 < y) p++;
    if (!sched && p < 1) p = 1;
    var above = p > 0 ? rows[cand[p - 1]] : null;
    var below = p < cand.length ? cand[p] : (sched ? uIdx : rows.length);
    var ids = chart0.tasks.filter(function (t) { return t.id !== id; });
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
    } else if (!above) { group = null; index = 0; }
    else if (above.kind === 'task') { group = above.group ? above.group.id : null; index = at(above.id) + 1; }
    else {
      group = above.id;
      var first = -1;
      for (var q = 0; q < ids.length; q++) if (ids[q].group === above.id) { first = q; break; }
      index = first >= 0 ? first : ids.length;
    }
    var out = { index: index, group: group, from: from, lo: 0, hi: -1, dir: 0, y: 0, changed: false };
    if (below > from) { out.lo = from + 1; out.hi = below - 1; out.dir = -1; } else { out.lo = below; out.hi = from - 1; out.dir = 1; }
    out.y = above ? yWithout(cand[p - 1]) + above.h : (sched ? 0 : rows[uIdx].y + rows[uIdx].h);
    var cur = -1;
    for (var c = 0; c < chart0.tasks.length; c++) if (chart0.tasks[c].id === id) { cur = c; break; }
    var valid = !!task.group && chart0.groups.some(function (g) { return g.id === task.group; });
    if (out.group === null && !valid) out.group = undefined;
    var own = 0;
    while (own < cand.length && cand[own] < from) own++;
    out.changed = p !== own && (index !== cur || (out.group !== undefined && out.group !== task.group));
    if (!out.changed) { out.lo = 0; out.hi = -1; out.dir = 0; }
    return out;
  }
  // The M6 keyboard step (app.js nudgeOrder before G3): the neighbour row's slot.
  function m6Nudge(rows, c, id, dir) {
    var from = rowIdx(rows, id), nb = rows[from + dir];
    if (from < 0 || !nb) return null;
    var hd = rows[from].h;
    var y = dir < 0 ? nb.y + (nb.h + hd) / 2 - 0.5 : nb.y - hd + (nb.h + hd) / 2 + 0.5;
    return LY.reorderTarget(rows, c, id, y);
  }
  function core(t) { return t ? { index: t.index, group: t.group, lo: t.lo, hi: t.hi, dir: t.dir, y: t.y, changed: t.changed } : null; }

  /* ------------------------------------------------------------ buildRows */
  function rowsSpec() {
    var c = chartA(), b = built(c);
    eq('rows: D15 order, empty and undated-only groups keep a header', rowIds(b), 'u1 s1 g1 a1 a2 g2 b1 b2 g3 g4 ~unscheduled x1 x2 x3');
    var g1 = rowOf(b.rows, 'g1'), g2 = rowOf(b.rows, 'g2'), g3 = rowOf(b.rows, 'g3'), g4 = rowOf(b.rows, 'g4'), un = rowOf(b.rows, LY.UNSCHED);
    eq('counts: n is every member, scheduled or not (§8.7)', [g1.n, g2.n, g3.n, g4.n].join(','), '3,2,0,1');
    eq('counts: un is the undated members', [g1.un, g2.un, g3.un, g4.un].join(','), '1,0,0,1');
    eq('empty: only a group no task names (§8.8)', [g1.empty, g2.empty, g3.empty, g4.empty].join(','), 'false,false,true,false');
    eq('counts: the Unscheduled header counts every undated task', un.n, 3);
    ok('counts: a shadow group names no header', b.rows.every(function (r) { return r.kind !== 'group' || r.id !== 'zz'; }) && rowOf(b.rows, 's1').group === null);
    var bc = built(c, ['g1', 'g4']);
    eq('counts: a collapsed group keeps its counts', [rowOf(bc.rows, 'g1').n, rowOf(bc.rows, 'g1').un, rowOf(bc.rows, 'g4').n].join(','), '3,1,1');
    // A task whose note is missing is still a member; a milestone without a note too.
    var cm = chart({ v: 1, groups: [{ id: 'g1', title: 'G' }], tasks: [
      { id: 'm1', title: 'Launch', start: '2026-10-05', milestone: true, group: 'g1' },
      { id: 'k1', note: 'gone', title: 'Gone note', group: 'g1' }] });
    var bm = built(cm);
    eq('counts: a note-less milestone and a missing (undated) note both count', [rowOf(bm.rows, 'g1').n, rowOf(bm.rows, 'g1').un, rowOf(bm.rows, 'g1').empty].join(','), '2,1,false');
    eq('slot: absent without a drag', built(chartB()).slot, -1);

    // The slot row (§8.1).
    var bs = built(chartB(), [], true);
    eq('slot: first row while dragging, above the first header', rowIds(bs), '~nogroup g1 a1 a2 g2 b1 g3 ~unscheduled x1 x2');
    eq('slot: kind, id, index', [bs.rows[0].kind, bs.rows[0].id, bs.slot, LY.NOGROUP].join(','), 'slot,~nogroup,0,~nogroup');
    eq('slot: a task row high, and every row below moves down by it', [bs.rows[0].h, bs.rows[1].y, bs.totalH - built(chartB()).totalH].join(','), '44,44,44');
    eq('slot: 36 px in compact', built(chartB(), [], true, 'compact').rows[0].h, 36);
    eq('slot: the tablet row height', LY.buildRows(chartB(), [], 'comfortable', { dragSlot: true, rowH: 40 }).rows[0].h, 40);
    eq('slot: index and header maps follow the shift', [bs.index.a1, bs.groups.g1, bs.groups[LY.UNSCHED]].join(','), '2,1,7');
    eq('slot: none when a scheduled task is ungrouped', built(chartA(), [], true).slot, -1);
    eq('slot: none on a chart without groups', built(chart({ v: 1, tasks: [{ id: 'x', note: 'n', title: 'X' }] }), [], true).slot, -1);
    eq('slot: undated ungrouped tasks do not count', built(chartB(), [], true).slot, 0);
    var shadowOnly = chart({ v: 1, groups: [{ id: 'g1', title: 'G' }], tasks: [{ id: 's', note: 'n', title: 'S', start: '2026-10-01', group: 'zz' }] });
    eq('slot: a scheduled task with a shadow group is ungrouped, so no slot', built(shadowOnly, [], true).slot, -1);
    eq('slot: present with every group collapsed', rowIds(built(chartB(), ['g1', 'g2', 'g3'], true)), '~nogroup g1 g2 g3 ~unscheduled x1 x2');

    // Camera compensation (§8.1): sy grows by h when sy >= h.
    eq('slotShift: at the top nothing is compensated', [LY.slotShift(0, 44), LY.slotShift(43, 44), LY.slotShift(43.9, 44)].join(','), '0,0,0');
    eq('slotShift: from sy >= h the camera takes the whole row', [LY.slotShift(44, 44), LY.slotShift(500, 44), LY.slotShift(36, 36)].join(','), '44,44,36');
    var bb = built(chartB(40)), bb2 = built(chartB(40), [], true), bad = [];
    [0, 20, 44, 45, 300, 1000].forEach(function (sy) {
      var dy = LY.slotShift(sy, 44);
      bb.rows.forEach(function (r) {
        var r2 = rowOf(bb2.rows, r.id), before = r.y - sy, after = r2.y - (sy + dy);
        if (after !== before + (dy ? 0 : 44)) bad.push(sy + ':' + r.id);
      });
    });
    eq('slotShift: from sy >= h every row keeps its screen y; at the top every row slides down by h', bad.join(' '), '');
  }

  /* -------------------------------------------------------- reorderTarget */
  function targetSpec() {
    var c = chartA(), rows = built(c, ['g2']).rows;
    eq('A with Build collapsed', rows.map(function (r) { return r.id; }).join(' '), 'u1 s1 g1 a1 a2 g2 g3 g4 ~unscheduled x1 x2 x3');
    // u1 dragged (hd 44). Without it: a2 at 120 (44 px), g2 at 164 (32 px).
    var thrA2 = 120 + (44 + 44) / 2, thrG2 = 164 + (32 + 44) / 2, mid = (thrA2 + thrG2) / 2;
    eq('band: the zone before a collapsed header is 38 px, two 19 px halves', [thrG2 - thrA2, mid - thrA2, thrG2 - mid].join(','), '38,19,19');
    var t0 = LY.reorderTarget(rows, c, 'u1', mid);
    eq('band: the upper half (to the midpoint) is "before" the header: after A2 in Discovery', [t0.group, t0.index, t0.into === undefined].join(','), 'g1,' + (idsWithout(c, 'u1').indexOf('a2') + 1) + ',true');
    ok('band: the upper half equals the M6 rule', json(core(t0)) === json(core(m6Target(rows, c, 'u1', mid))), json(t0));
    var t1 = LY.reorderTarget(rows, c, 'u1', mid + 0.01);
    eq('band: the lower half is into Build', [t1.into, t1.group, t1.changed].join(','), 'g2,g2,true');
    eq('band: into Build is its end (moveToGroup), nothing shifts', [t1.index, t1.lo > t1.hi, t1.dir].join(','), (idsWithout(c, 'u1').indexOf('b2') + 1) + ',true,0');
    eq('band: the index is model.moveToGroup\'s', order(apply(c, 'u1', t1)), order(M.moveToGroup(c, 'u1', 'g2').chart));
    var t2 = LY.reorderTarget(rows, c, 'u1', thrG2);
    eq('band: up to the header threshold itself', t2.into, 'g2');
    var t3 = LY.reorderTarget(rows, c, 'u1', thrG2 + 0.01);
    eq('band: past the threshold (reorderTarget p) the task joins Build first', [t3.into === undefined, t3.group, t3.index].join(','), 'true,g2,' + idsWithout(c, 'u1').indexOf('b1'));
    eq('band: the insertion y of a band is the header bottom', t1.y, 164 + 32);
    // Review round 1 (major): just under a collapsed header the task joins
    // that hidden group (first, M6); the target says its row will be hidden.
    var hz = LY.reorderTarget(rows, c, 'u1', thrG2 + 5);
    eq('hidden: a drop under a collapsed header goes into it, first, and is flagged hidden', [hz.group, hz.into === undefined, hz.hidden, hz.changed].join(','), 'g2,true,true,true');
    eq('hidden: a band into a collapsed group is hidden too', [t1.hidden, t0.hidden].join(','), 'true,false');
    var ex = LY.reorderTarget(built(c).rows, c, 'u1', thrG2 + 5);
    eq('hidden: under an expanded header the row stays visible', [ex.group, ex.hidden].join(','), 'g2,false');
    var e3 = LY.reorderTarget(rows, c, 'u1', 196 + 38 + 0.01);      // just under Later
    eq('hidden: under an empty expanded header the row is visible (first in Later)', [e3.group, e3.hidden].join(','), 'g3,false');
    ok('band: the collapsed group stays collapsed in the rows of the result', rowIds(built(apply(c, 'u1', t1), ['g2'])).indexOf('b2') < 0);
    eq('band: expanded afterwards, the task is Build\'s last row', rowIds(built(apply(c, 'u1', t1))).replace(/ g3.*/, ''), 's1 g1 a1 a2 g2 b1 b2 u1');

    // An empty (expanded) header after a collapsed one: 32 px zone, 16 px halves.
    var thrG3 = 196 + 38, midG3 = (thrG2 + thrG3) / 2;
    var e0 = LY.reorderTarget(rows, c, 'u1', midG3), e1 = LY.reorderTarget(rows, c, 'u1', midG3 + 0.01);
    eq('band: before an empty header, the upper half joins the collapsed Build first', [e0.group, e0.into === undefined].join(','), 'g2,true');
    eq('band: the lower half is into the empty Later', [e1.into, e1.group, e1.index].join(','), 'g3,g3,' + (idsWithout(c, 'u1').indexOf('b2') + 1));
    // A header whose members are all undated has no rows: it has a band too.
    var thrG4 = 228 + 38, e2 = LY.reorderTarget(rows, c, 'u1', (thrG3 + thrG4) / 2 + 0.01);
    eq('band: a header with only undated members is entered at its end', [e2.into, e2.index].join(','), 'g4,' + (idsWithout(c, 'u1').indexOf('x3') + 1));

    // No band on an expanded header with task rows.
    var rx = built(c).rows, xa2 = 120 + 44, xg2 = 164 + 38;
    var n0 = LY.reorderTarget(rx, c, 'u1', xg2 - 0.5);
    ok('no band: just above an expanded Build with rows is still after A2 (M6)', n0.into === undefined && n0.group === 'g1' && json(core(n0)) === json(core(m6Target(rx, c, 'u1', xg2 - 0.5))), json(n0));
    ok('no band: every y over an expanded header with rows equals M6', [xa2 + 1, (xa2 + xg2) / 2, (xa2 + xg2) / 2 + 1, xg2, xg2 + 1].every(function (y) {
      return json(core(LY.reorderTarget(rx, c, 'u1', y))) === json(core(m6Target(rx, c, 'u1', y)));
    }));
    // No band on Unscheduled: a scheduled task never reaches it, an
    // unscheduled one just above it stays first inside it.
    var ux = LY.reorderTarget(rx, c, 'x2', rowOf(rx, LY.UNSCHED).y + 30);
    ok('no band on Unscheduled: an unscheduled task above its threshold stays first in it, group unchanged', ux.group === undefined && ux.into === undefined && ux.slot === undefined, json(ux));
    var sx = LY.reorderTarget(rx, c, 'a1', 99999);
    ok('no band on Unscheduled: a scheduled task at the bottom joins the last group first (M6)', sx.into === undefined && sx.group === 'g4', json(sx));

    // Unscheduled tasks change group on a band, keeping their index (§8.1).
    var ry = built(c, ['g2']).rows;
    var ya2 = rowOf(ry, 'a2').y + 44, yg2 = rowOf(ry, 'g2').y + 38;      // x1 is below: nothing above it moves
    var u0 = LY.reorderTarget(ry, c, 'x1', (ya2 + yg2) / 2 + 1);
    eq('unscheduled: onto the collapsed Build band', [u0.into, u0.group, u0.index, u0.changed, u0.lo > u0.hi].join(','), 'g2,g2,' + c.tasks.map(function (t) { return t.id; }).indexOf('x1') + ',true,true');
    var ua = apply(c, 'x1', u0);
    ok('unscheduled: the group changes, the order and the missing dates do not', M.task(ua, 'x1').group === 'g2' && M.task(ua, 'x1').start === null && order(ua).replace('x1/g2', 'x1') === order(c), order(ua));
    ok('unscheduled: it stays in Unscheduled', rowIds(built(ua, ['g2'])).indexOf('~unscheduled x1') >= 0);
    var u1 = LY.reorderTarget(ry, c, 'x1', (ya2 + yg2) / 2 - 1);
    ok('unscheduled: the upper half of the zone is no target (first in Unscheduled)', u1.group === undefined && u1.into === undefined, json(u1));
    var y4a = rowOf(ry, 'g3').y + 38, y4b = rowOf(ry, 'g4').y + 38;
    var u2 = LY.reorderTarget(ry, c, 'x3', (y4a + y4b) / 2 + 1);
    ok('no-change: an unscheduled task onto its own group\'s band', u2.into === 'g4' && !u2.changed, json(u2));
    var u3 = LY.reorderTarget(ry, c, 'x2', rowOf(ry, 'a1').y + 10);
    ok('unscheduled: over an expanded group with rows nothing changes group', u3.group === undefined && u3.into === undefined, json(u3));

    // No-change drops: every task dropped where it rests.
    [[c, []], [c, ['g2']], [c, ['g1', 'g2', 'g3', 'g4']], [chartB(), []], [chartB(), ['g1']], [chartB(), ['g2', 'g3']]].forEach(function (cs, k) {
      [false, true].forEach(function (slot) {
        var rr = built(cs[0], cs[1], slot).rows, moved = [];
        rr.forEach(function (r) {
          if (r.kind !== 'task') return;
          var t = LY.reorderTarget(rr, cs[0], r.id, r.y + r.h / 2);
          if (!t || t.changed || t.lo <= t.hi) moved.push(r.id + json(t));
        });
        eq('no-change: every task dropped in place changes nothing (case ' + k + (slot ? ', slot' : '') + ')', moved.join(' '), '');
      });
    });
    // The own-slot split: the last task above a collapsed header.
    var rb = built(chartB(), ['g2']).rows, a2 = rowOf(rb, 'a2'), rest = a2.y + 22, thrB = a2.y + 38;
    var o0 = LY.reorderTarget(rb, chartB(), 'a2', rest + 7.9), o1 = LY.reorderTarget(rb, chartB(), 'a2', rest + 8.1);
    eq('own slot: the band starts halfway between the resting centre and the threshold', [!o0.changed, o1.into, o1.changed].join(','), 'true,g2,true');
    ok('own slot: a jitter of a few px at lift stays in place', [1, 3, 5, 7].every(function (d) { return !LY.reorderTarget(rb, chartB(), 'a2', rest + d).changed; }));
    // A task alone in an expanded group: its own header's band is no change.
    var solo = chartB(), rs = built(solo).rows, b1 = rowOf(rs, 'b1'), g2r = rowOf(rs, 'g2');
    var thrOwn = g2r.y + 38, lb = rowOf(rs, 'a2').y + 44;
    var s0 = LY.reorderTarget(rs, solo, 'b1', (lb + thrOwn) / 2 + 1);
    ok('no-change: the only row of a group onto its own header band', s0.into === 'g2' && !s0.changed && s0.lo > s0.hi, json(s0) + ' ' + b1.y);
    var s1 = LY.reorderTarget(rs, solo, 'b1', (lb + thrOwn) / 2 - 1);
    ok('... and its upper half leaves the group (after A2)', s1.group === 'g1' && s1.changed, json(s1));

    // The No-group slot (§8.1).
    var cb = chartB(), rz = built(cb, [], true).rows;
    eq('B while dragging', rz.map(function (r) { return r.id; }).join(' '), '~nogroup g1 a1 a2 g2 b1 g3 ~unscheduled x1 x2');
    // b1 dragged: thr(slot) 44, thr(g1) 82.
    [-30, 0, 10, 44, 60, 82].forEach(function (y) {
      var t = LY.reorderTarget(rz, cb, 'b1', y);
      ok('slot: y ' + y + ' is the slot (No group)', t.slot === true && t.group === null && t.changed && t.lo > t.hi && t.dir === 0, json(t));
    });
    var z1 = LY.reorderTarget(rz, cb, 'b1', 10);
    eq('slot: the index is moveToGroup(…, null)\'s', order(apply(cb, 'b1', z1)), order(M.moveToGroup(cb, 'b1', null).chart));
    eq('slot: after the drop b1 is the first (ungrouped) row', rowIds(built(apply(cb, 'b1', z1))).slice(0, 5), 'b1 g1');
    eq('slot: the insertion y is the slot row\'s top', z1.y, 0);
    var z2 = LY.reorderTarget(rz, cb, 'b1', 82.01);
    ok('slot: past the first header\'s threshold b1 joins Discovery first', z2.slot === undefined && z2.group === 'g1' && z2.index === 0, json(z2));
    // With the first header collapsed, the zone between the slot and it splits.
    var rzc = built(cb, ['g1'], true).rows;
    var zc0 = LY.reorderTarget(rzc, cb, 'b1', 63), zc1 = LY.reorderTarget(rzc, cb, 'b1', 63.01);
    eq('slot: before a collapsed first header, the upper half is the slot and the lower half its band', [zc0.slot, zc1.into].join(','), 'true,g1');
    // An unscheduled task with a group may go to the slot; one without stays.
    var zx = LY.reorderTarget(rz, cb, 'x2', 10);
    eq('slot: an unscheduled task in Build leaves it, index kept', [zx.slot, zx.group, zx.index, zx.changed].join(','), 'true,,' + cb.tasks.map(function (t) { return t.id; }).indexOf('x2') + ',true');
    var zu = LY.reorderTarget(rz, cb, 'x1', 10);
    ok('slot: an ungrouped unscheduled task on the slot changes nothing', zu.slot && !zu.changed && zu.group === undefined, json(zu));
    // Drop in place of the first task under the slot changes nothing.
    ok('slot: a1 in place (below the slot and Discovery) changes nothing', !LY.reorderTarget(rz, cb, 'a1', rowOf(rz, 'a1').y + 22).changed);
  }

  /* --------------------------------------------- property over random charts */
  function rng(seed) {
    var s = seed >>> 0 || 1;
    return function () { s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0; return s / 4294967296; };
  }
  function seed() { return typeof global.GT_SEED === 'number' && isFinite(global.GT_SEED) ? global.GT_SEED : 20260927; }
  function propertySpec() {
    var r = rng(seed() * 7919 + 3), fails = [], stats = { targets: 0, bands: 0, slots: 0, m6: 0, m6slot: 0 };
    function pick(a) { return a[Math.floor(r() * a.length)]; }
    for (var n = 0; n < 60 && fails.length < 5; n++) {
      var ng = Math.floor(r() * 5), groups = [], tasks = [];
      for (var g = 0; g < ng; g++) groups.push({ id: 'g' + g, title: 'G' + g });
      var nt = Math.floor(r() * 12);
      for (var t = 0; t < nt; t++) {
        var gg = r() < 0.2 ? null : (r() < 0.08 ? 'zz' : (ng ? 'g' + Math.floor(r() * ng) : null));
        var dated = r() < 0.75, d0 = 1 + Math.floor(r() * 20);
        tasks.push({ id: 't' + t, note: 'n' + t, title: 'T' + t, start: dated ? '2026-10-' + (d0 < 10 ? '0' : '') + d0 : undefined, group: gg || undefined });
      }
      var c = chart({ v: 1, groups: groups, tasks: tasks });
      var col = groups.filter(function () { return r() < 0.35; }).map(function (x) { return x.id; });
      if (r() < 0.2) col.push(LY.UNSCHED);
      var slot = r() < 0.6, b = built(c, col, slot), rows = b.rows;
      rows.forEach(function (row) {
        if (row.kind !== 'task') return;
        for (var y = -50; y <= b.totalH + 50; y += 2 + r() * 3) {
          var tg = LY.reorderTarget(rows, c, row.id, y), tsk = row.task, where = 'chart ' + n + ' ' + row.id + ' y ' + y.toFixed(2) + ' ' + json(tg);
          stats.targets++;
          if (!tg) { fails.push('null: ' + where); continue; }
          var res = M.reorder(c, row.id, tg.index, tg.group), noop = res.inverse.length === 0;
          if (tg.changed && noop) fails.push('changed but a no-op: ' + where);
          if (tg.into !== undefined || tg.slot) {
            if (tg.into !== undefined) stats.bands++; else stats.slots++;
            if (tg.lo <= tg.hi) fails.push('a band or slot shifts rows: ' + where);
            var after = M.task(res.chart, row.id);
            if (tg.into !== undefined && after.group !== tg.into) fails.push('into but not in the group: ' + where);
            if (tg.slot && after.group && c.groups.some(function (x) { return x.id === after.group; })) fails.push('slot but still grouped: ' + where);
            if (typeof tsk.start !== 'number' && tg.index !== c.tasks.indexOf(M.task(c, row.id))) fails.push('unscheduled index moved: ' + where);
            if (typeof tsk.start === 'number' && tg.changed && tg.into !== undefined) {
              var rb2 = built(res.chart).rows, gi = rowIdx(rb2, tg.into), last = gi;
              while (last + 1 < rb2.length && rb2[last + 1].kind === 'task') last++;
              if (rb2[last].id !== row.id) fails.push('into: not the last row of the group: ' + where);
            }
            var bandRow = tg.into !== undefined ? rows[rowIdx(rows, tg.into)] : null;
            if (bandRow && !(bandRow.collapsed || bandRow.n - bandRow.un === 0 || rows.every(function (x) { return x.kind !== 'task' || typeof x.task.start !== 'number' || x.group === null || x.group.id !== tg.into || x.id === row.id; })))
              fails.push('band on a header with other rows: ' + where);
          } else {
            stats.m6++;
            var o, want;
            if (!slot || b.slot < 0) { o = m6Target(rows, c, row.id, y); want = core(o); }
            else {
              // Review round 1: with the slot row, M6 over the rows without it
              // at y - h, shifted back by one row and h px.
              var h0 = rows[b.slot].h;
              o = m6Target(built(c, col, false).rows, c, row.id, y - h0);
              want = core(o);
              if (want.changed) { want.lo += 1; want.hi += 1; }
              want.y += h0;
              stats.m6slot++;
            }
            if (json(want) !== json(core(tg))) fails.push('differs from M6: ' + where + ' m6 ' + json(o));
            if (slot && b.slot >= 0 && tg.group === null && typeof tsk.start === 'number') fails.push('ungrouped without the slot: ' + where);
          }
        }
      });
    }
    eq('property (seed ' + seed() + '): bands and the slot obey §8.1, every other target equals M6', fails.slice(0, 5).join('\n'), '');
    ok('property: exercised bands, slots and M6 targets (' + json(stats) + ')', stats.bands > 50 && stats.slots > 20 && stats.m6 > 500 && stats.m6slot > 100);
  }

  /* ---------------------------------------------------------- stepTarget */
  function stepSpec() {
    var c = chartA(), rows = built(c).rows, same = [], more = [];
    rows.forEach(function (r) {
      if (r.kind !== 'task') return;
      [-1, 1].forEach(function (dir) {
        var old = m6Nudge(rows, c, r.id, dir), now = LY.stepTarget(rows, c, r.id, dir);
        if (now && now.into !== undefined) return;             // a band in the way (below)
        if (old && old.changed) { if (json(core(old)) !== json(core(now))) same.push(r.id + dir + ' ' + json(old) + ' vs ' + json(now)); }
        else if (now) more.push(r.id + dir + ':' + now.group + '@' + now.index);
      });
    });
    eq('stepTarget: with no bandable header in the way it equals the M6 neighbour step', same.join('\n'), '');
    // Where M6 stopped (its neighbour slot changed nothing), step goes on.
    ok('stepTarget: where the M6 step changed nothing it may step further', more.every(function (s) { return /^(u1|s1|a1|a2|b1|b2|x1|x2|x3)/.test(s); }), more.join(' '));
    var cb = chartB(), rb = built(cb).rows;
    var up = LY.stepTarget(rb, cb, 'b1', -1);
    eq('stepTarget: Alt+Up on the only task of Build leaves its group (after A2)', [up.group, up.index, up.changed].join(','), 'g1,' + (idsWithout(cb, 'b1').indexOf('a2') + 1) + ',true');
    ok('... where the M6 step changed nothing (its own band)', !m6Nudge(rb, cb, 'b1', -1).changed);
    var dn = LY.stepTarget(rb, cb, 'b1', 1);
    eq('stepTarget: Alt+Down on it enters the empty Later below', [dn.into, dn.group].join(','), 'g3,g3');
    var rc = built(cb, ['g2']).rows, d2 = LY.stepTarget(rc, cb, 'a2', 1);
    eq('stepTarget: Alt+Down from the last task above a collapsed group enters it at its end', [d2.into, d2.group, d2.index].join(','), 'g2,g2,' + idsWithout(cb, 'a2').length);
    var a1up = LY.stepTarget(rb, cb, 'a1', -1);
    eq('stepTarget: Alt+Up on the first task under the first header leaves every group (M6)', [a1up.group, a1up.index].join(','), ',0');
    eq('stepTarget: Alt+Up on the first row of the chart: nothing', LY.stepTarget(rows, c, 'u1', -1), null);
    var b2dn = LY.stepTarget(rows, c, 'b2', 1);
    eq('stepTarget: Alt+Down from the last task of Build into the empty Later below it', [b2dn.into, b2dn.index].join(','), 'g3,' + (idsWithout(c, 'b2').indexOf('b1') + 1));
    var ru = built(c).rows;
    eq('stepTarget: an unscheduled task at the top of Unscheduled stays in it', LY.stepTarget(ru, c, 'x1', -1), null);
    var xd = LY.stepTarget(ru, c, 'x1', 1);
    ok('stepTarget: an unscheduled task steps down inside Unscheduled, group unchanged', xd && xd.group === undefined && xd.into === undefined, json(xd));
    eq('stepTarget: unknown task or no direction', [LY.stepTarget(ru, c, 'nope', 1), LY.stepTarget(ru, c, 'a1', 0)].join(','), ',');
  }

  /* ------------------------------------------------------ render (fake DOM) */
  function fakeDom() {
    var rects = [], ops = [];
    var ctx = typeof Proxy === 'function' ? new Proxy({
      measureText: function (s) { return { width: String(s).length * 6 }; },
      fillRect: function (x, y, w, h) { rects.push([x, y, w, h]); ops.push(['rect', x, y, w, h]); },
      fillText: function (s, x, y) { ops.push(['text', s, x, y]); }
    }, {
      get: function (t, k) { return k in t ? t[k] : function () {}; },
      set: function (t, k, v) { t[k] = v; return true; }
    }) : null;
    var doc = {};
    function El(tag) {
      var e = this;
      this.tagName = String(tag).toUpperCase(); this.ownerDocument = doc; this.children = []; this.parentNode = null;
      this.className = ''; this.attrs = {}; this.hidden = false; this.width = 0; this.height = 0; this.own = '';
      this.style = { setProperty: function (k, v) { this[k] = v; }, getPropertyValue: function (k) { return this[k] || ''; } };
      this.classList = {
        contains: function (c) { return e.className.split(/\s+/).indexOf(c) >= 0; },
        toggle: function (c, on) {
          var l = e.className.split(/\s+/).filter(Boolean), i = l.indexOf(c);
          if (on === undefined) on = i < 0;
          if (on && i < 0) l.push(c);
          if (!on && i >= 0) l.splice(i, 1);
          e.className = l.join(' ');
          return on;
        }
      };
    }
    El.prototype.appendChild = function (c) {
      if (c.parentNode) c.parentNode.children.splice(c.parentNode.children.indexOf(c), 1);
      c.parentNode = this; this.children.push(c); return c;
    };
    El.prototype.setAttribute = function (k, v) { this.attrs[k] = String(v); };
    El.prototype.getAttribute = function (k) { return Object.prototype.hasOwnProperty.call(this.attrs, k) ? this.attrs[k] : null; };
    El.prototype.focus = function () {};
    El.prototype.getContext = function () { return ctx; };
    Object.defineProperty(El.prototype, 'textContent', {
      get: function () { return this.own + this.children.map(function (c) { return c.textContent; }).join(''); },
      set: function (v) { this.children = []; this.own = String(v); }
    });
    function walk(el, fn) { el.children.forEach(function (c) { fn(c); walk(c, fn); }); }
    El.prototype.querySelectorAll = function (sel) {
      var cls = sel.replace(/^\./, ''), out = [];
      walk(this, function (c) { if (c.classList.contains(cls)) out.push(c); });
      return out;
    };
    El.prototype.querySelector = function (sel) { return this.querySelectorAll(sel)[0] || null; };
    doc.createElement = function (tag) { return new El(tag); };
    doc.documentElement = new El('html');
    doc.body = new El('body');
    doc.defaultView = {};
    var root = new El('div');
    root.className = 'g-root';
    ['g-hdr-cv', 'g-grid-cv', 'g-names', 'g-body', 'g-bars', 'g-empty', 'g-overlay', 'g-handles', 'g-allc'].forEach(function (k) {
      var e = root.appendChild(new El(/cv$/.test(k) ? 'canvas' : 'div'));
      e.className = k;
    });
    root.querySelector('.g-names').appendChild(new El('div')).className = 'g-names-inner';
    return { root: root, ok: !!ctx, rects: rects, ops: ops };
  }
  function mount(c, o) {
    o = o || {};
    var dom = fakeDom(), t = D.parse('2026-10-01') * 864e5 + 12 * 36e5, timers = [];
    var view = GT.render.create(dom.root, {
      i18n: I, now: function () { return t; }, frame: function () { return 1; }, cancelFrame: function () {},
      setInterval: function () { return 1; }, clearInterval: function () {}, dpr: 1, perf: function () { return 0; },
      setTimeout: function (f) { timers.push(f); return timers.length; }
    });
    view.setSize(o.w || 390, o.h || 700);
    view.setData({ chart: c, collapsed: o.collapsed || [], editable: o.editable !== false, today: D.parse('2026-10-01') });
    view.flushNow();
    function shown(cls) { return dom.root.querySelectorAll(cls).filter(function (e) { return e.style.display !== 'none'; }); }
    return {
      view: view, root: dom.root, rects: dom.rects, ops: dom.ops,
      header: function (id) { return shown('.g-grp').filter(function (e) { return e.getAttribute('data-group') === id; })[0] || null; },
      name: function (id) { return shown('.g-name').filter(function (e) { return e.getAttribute('data-id') === id; })[0] || null; },
      slot: function () { return shown('.g-slot')[0] || null; },
      ty: function (e) { var m = /translate3d\(0,(-?[\d.]+)px/.exec(e.style.transform || ''); return m ? Number(m[1]) : NaN; },
      kid: function (e, cls) { return e.querySelector(cls); },
      frame: function () { view.flushNow(); }
    };
  }
  function renderSpec() {
    if (typeof Proxy !== 'function') { ok('render spec needs Proxy (skipped)', true); return; }
    var saved = I.language;
    I.setLanguage('en-US');
    var v = mount(chartA(), { collapsed: ['g2'] });
    var h1 = v.header('g1'), h2 = v.header('g2'), h3 = v.header('g3'), h4 = v.header('g4'), hu = v.header(LY.UNSCHED);
    ok('render: every header is painted', h1 && h2 && h3 && h4 && hu);
    eq('render: counts are every member (§8.7)', [h1, h2, h3, h4, hu].map(function (e) { return v.kid(e, '.g-gn').textContent; }).join(','), '3,2,0,1,3');
    eq('render: secondary text: "{n} unscheduled", nothing, "Drag tasks here" (§8.8)', [h1, h2, h3, h4, hu].map(function (e) { return v.kid(e, '.g-gh').textContent; }).join('|'), '1 unscheduled||Drag tasks here|1 unscheduled|');
    eq('render: the label names the unscheduled members', h1.getAttribute('aria-label') + ' / ' + h4.getAttribute('aria-label'), 'Discovery, 3 tasks, 1 unscheduled / Someday, 1 task, 1 unscheduled');
    eq('render: labels without unscheduled members keep "{title}, {n} task(s)"', [h2, h3, hu].map(function (e) { return e.getAttribute('aria-label'); }).join(' / '), 'Build, 2 tasks / Later, 0 tasks / Unscheduled, 3 tasks');
    ok('render: an empty group is .empty, an undated-only one is not', h3.classList.contains('empty') && !h4.classList.contains('empty') && !hu.classList.contains('empty'));
    // Chevron and aria-expanded (§8.7).
    var ch = v.kid(h2, '.g-chev');
    eq('render: the chevron is ▾, aria-hidden, rotated by .collapsed', [ch.textContent, ch.getAttribute('aria-hidden'), h2.classList.contains('collapsed'), h1.classList.contains('collapsed')].join(','), '▾,true,true,false');
    eq('render: aria-expanded follows the collapsed set', [h1.getAttribute('aria-expanded'), h2.getAttribute('aria-expanded'), h1.getAttribute('role')].join(','), 'true,false,button');
    var ro = mount(chartA(), { editable: false });
    eq('render: a read-only chart has no "Drag tasks here"', v.kid(ro.header('g3'), '.g-gh').textContent, '');
    // Review round 1: under R.HINT_MIN the grid draws each header's hint in its body strip.
    v.frame();
    var bh = v.view.bodyHints(), narrow = v.view.nameW() < GT.render.HINT_MIN;
    eq('render: body-strip hints follow the column width (' + v.view.nameW() + ' px)', bh.map(function (x) { return x.id + ':' + x.text; }).join('|'),
      narrow ? 'g1:1 unscheduled|g3:Drag tasks here|g4:1 unscheduled' : '');
    ok('render: body-strip hints sit at the body\'s left edge, mid-row', bh.every(function (x) { var r = rowOf(v.view.rows(), x.id); return x.x === 8 && Math.abs(x.y - (r.y - v.view.camera().sy + r.h / 2)) < 0.01; }));
    // Review round 2: each body hint sits on a backing drawn just before it,
    // and nothing drawn after it (the today line) crosses the text.
    var vt = mount(chartA(), { collapsed: ['g2'] });
    vt.ops.length = 0;
    vt.view.invalidate(GT.render.FLAGS.CAM);
    vt.frame();
    var texts = vt.ops.map(function (o, i) { return [o, i]; }).filter(function (p) { return p[0][0] === 'text' && p[0][1] === 'Drag tasks here'; });
    ok('render: the body hint was drawn this frame', texts.length === 1);
    ok('render: a backing covers the body hint, drawn just before it', texts.every(function (p) {
      var o = p[0], b = vt.ops[p[1] - 1], w = o[1].length * 6;
      return b && b[0] === 'rect' && b[1] <= o[2] - 4 && b[1] + b[3] >= o[2] + w + 4 && b[2] < o[3] && b[2] + b[4] > o[3];
    }), json(vt.ops.slice(-8)));
    ok('render: nothing is drawn over the body hint after it', texts.every(function (p) {
      var o = p[0], w = o[1].length * 6;
      return vt.ops.slice(p[1] + 1).every(function (q) { return q[0] !== 'rect' || q[1] > o[2] + w || q[1] + q[3] < o[2] || q[2] > o[3] + 6 || q[2] + q[4] < o[3] - 6; });
    }));
    // A 240 px tablet column shows the hints in the headers, none in the body (HINT_MIN 230).
    var wide = mount(chartA(), { w: 1024 });
    eq('render: a ' + wide.view.nameW() + ' px column draws no body hints', wide.view.nameW() >= GT.render.HINT_MIN && wide.view.bodyHints().length, 0);
    eq('render: HINT_MIN is past the 195 px portrait maximum', GT.render.HINT_MIN > GT.render.clampNameW(1000, 390), true);
    ro.frame();
    ok('render: a read-only chart draws no "Drag tasks here" in the body', ro.view.bodyHints().every(function (x) { return x.text !== 'Drag tasks here'; }));

    // Drop target states (§8.2).
    v.view.setPreview({ kind: 'reorder', id: 'u1', dy: 40, from: 0, lo: 0, hi: -1, dir: 0, hd: 44, into: 'g2', changed: true });
    v.frame();
    eq('render: a band target is .drop with the count n+1', [v.header('g2').classList.contains('drop'), v.kid(v.header('g2'), '.g-gn').textContent].join(','), 'true,3');
    ok('render: no other header is .drop', !v.header('g1').classList.contains('drop') && !v.header('g3').classList.contains('drop'));
    v.view.setPreview({ kind: 'reorder', id: 'b1', dy: 0, from: 0, lo: 0, hi: -1, dir: 0, hd: 44, into: 'g2', changed: false });
    v.frame();
    eq('render: a band target that changes nothing is not highlighted', [v.header('g2').classList.contains('drop'), v.kid(v.header('g2'), '.g-gn').textContent].join(','), 'false,2');
    // Review round 1 (major): a plain target into a collapsed group (no band)
    // highlights its header too; an expanded group's header is not highlighted.
    v.view.setPreview({ kind: 'reorder', id: 'u1', dy: 40, from: 0, lo: 0, hi: -1, dir: 0, hd: 44, group: 'g2', hidden: true, changed: true });
    v.frame();
    eq('render: a drop under a collapsed header is .drop with n+1', [v.header('g2').classList.contains('drop'), v.kid(v.header('g2'), '.g-gn').textContent].join(','), 'true,3');
    v.view.setPreview({ kind: 'reorder', id: 'u1', dy: 40, from: 0, lo: 2, hi: 3, dir: 1, hd: 44, group: 'g1', hidden: false, changed: true });
    v.frame();
    ok('render: a visible target group is not highlighted', !v.header('g1').classList.contains('drop') && v.kid(v.header('g1'), '.g-gn').textContent === '3');
    v.view.setPreview(null);
    v.frame();
    v.view.flash('g2');
    v.frame();
    ok('render: a header flashes by its id (after a drop into a collapsed group)', v.header('g2').classList.contains('flash'));

    // The slot row at the top of the list: rows slide down by h.
    var s = mount(chartB());
    eq('render: no slot row before a drag', s.slot(), null);
    var yG1 = s.ty(s.header('g1')), yA1 = s.ty(s.name('a1'));
    var on = s.view.setDragSlot(true);
    s.frame();
    eq('render: setDragSlot at the top: {h: 44, dy: 0}, the camera stays', json(on) + ' ' + s.view.camera().sy, '{"h":44,"dy":0} 0');
    var el = s.slot();
    ok('render: the slot row is painted in the name column', !!el);
    eq('render: slot label, aria-hidden, place', [el && el.textContent, el && el.getAttribute('aria-hidden'), el && s.ty(el), el && el.style.height].join(','), 'No group,true,0,44px');
    eq('render: the rows below slide down by 44', [s.ty(s.header('g1')) - yG1, s.ty(s.name('a1')) - yA1].join(','), '44,44');
    eq('render: the view rows hold the slot', s.view.rows()[0].id, LY.NOGROUP);
    s.view.setPreview({ kind: 'reorder', id: 'b1', dy: 0, from: 5, lo: 0, hi: -1, dir: 0, hd: 44, slot: true, changed: true });
    s.frame();
    ok('render: the slot target is .drop', s.slot().classList.contains('drop'));
    var hs = s.view.hitAt(10, s.view.hdrH() + 10);
    ok('render: a press on the slot row hits nothing', hs.kind === 'none' && hs.taskId === null && hs.groupId === null, json(hs));
    eq('render: ... and names no row index', hs.rowIndex, -1);
    s.view.setPreview(null);
    var off = s.view.setDragSlot(false);
    s.frame();
    eq('render: setDragSlot(false) returns what it took off; the slot goes', json(off) + ' ' + s.slot(), '{"h":44,"dy":0} null');
    eq('render: the rows are back', [s.ty(s.header('g1')), s.ty(s.name('a1'))].join(','), [yG1, yA1].join(','));

    // Scrolled: the camera takes the slot, nothing moves on screen.
    var sc = mount(chartB(40));
    sc.view.setCamera({ sx: sc.view.camera().sx, sy: 200, ppd: sc.view.camera().ppd });
    sc.frame();
    var ids = ['g2', 'b1', 'e0', 'e2'], before = ids.map(function (id) { var e = sc.header(id) || sc.name(id); return e ? sc.ty(e) - 200 : null; });
    var on2 = sc.view.setDragSlot(true);
    sc.frame();
    var sy2 = sc.view.camera().sy;
    eq('render: scrolled, setDragSlot grows sy by h', json(on2) + ' ' + sy2, '{"h":44,"dy":44} 244');
    eq('render: scrolled, every row keeps its screen y', json(ids.map(function (id) { var e = sc.header(id) || sc.name(id); return e ? sc.ty(e) - sy2 : null; })), json(before));
    sc.view.setDragSlot(false);
    sc.frame();
    eq('render: the drop takes the same 44 off again', sc.view.camera().sy, 200);
    eq('render: repeated calls are idempotent', json(sc.view.setDragSlot(false)) + ' ' + sc.view.dragSlot(), 'null null');
    // Review round 1: the removal uses slotShift at the current sy, so an
    // autoscroll between lift and drop never makes the rows jump.
    var au = mount(chartB(40));
    au.view.setDragSlot(true);                                   // at the top: dy 0
    au.view.setCamera({ sx: au.view.camera().sx, sy: 300, ppd: au.view.camera().ppd });
    au.frame();
    var bs = ['e10', 'e12', 'e14'].map(function (id) { var e = au.name(id); return e ? au.ty(e) - 300 : null; });
    var offA = au.view.setDragSlot(false);
    au.frame();
    var syA = au.view.camera().sy;
    eq('render: lifted at the top, dropped at sy 300: the camera gives back 44', json(offA) + ' ' + syA, '{"h":44,"dy":44} 256');
    eq('render: ... and no row moves on screen', json(['e10', 'e12', 'e14'].map(function (id) { var e = au.name(id); return e ? au.ty(e) - syA : null; })), json(bs));
    var ad = mount(chartB(40));
    ad.view.setCamera({ sx: ad.view.camera().sx, sy: 200, ppd: ad.view.camera().ppd });
    ad.view.setDragSlot(true);                                   // dy 44, sy 244
    ad.view.setCamera({ sx: ad.view.camera().sx, sy: 20, ppd: ad.view.camera().ppd });
    var offD = ad.view.setDragSlot(false);
    eq('render: lifted scrolled, autoscrolled to the top: nothing is taken off (rows slide up)', json(offD) + ' ' + ad.view.camera().sy, '{"h":44,"dy":0} 20');
    // Review round 1: the grid's zebra stripes skip the slot row, so no
    // stripe flips at lift or drop.
    var zb = mount(chartB(40), { trace: true });
    zb.view.setCamera({ sx: zb.view.camera().sx, sy: 200, ppd: zb.view.camera().ppd });
    zb.frame();
    function stripes() { zb.rects.length = 0; zb.view.invalidate(); zb.frame(); return zb.rects.filter(function (r) { return r[0] === 0 && r[3] < 100; }).map(function (r) { return r[1]; }).join(','); }
    var z0 = stripes();
    zb.view.setDragSlot(true);
    var z1 = stripes();
    ok('render: the zebra is unchanged at lift (sy compensated)', z0 === z1 && z0.length > 0, z0 + ' | ' + z1);
    // A chart with a scheduled ungrouped task has no slot: nothing changes.
    var na = mount(chartA());
    eq('render: no slot row on a chart with ungrouped scheduled tasks', json(na.view.setDragSlot(true)) + ' ' + na.view.camera().sy + ' ' + na.slot(), 'null 0 null');
    na.view.setDragSlot(false);
    I.setLanguage(saved);
  }

  /* ------------------------------------------------------------- gestures */
  function rig(longAnswer) {
    var L = {}, t = 1000, timers = [], log = { taps: [], longs: [], pans: 0, cancels: [], live: [] };
    var el = { addEventListener: function (n, f) { L[n] = f; }, removeEventListener: function () {}, setPointerCapture: function () {}, releasePointerCapture: function () {} };
    var api = {
      hit: function (target, x, y, out) { if (!target) return null; out.kind = target.kind; out.id = target.id || null; return out; },
      toX: function (x) { return x - 100; },
      panBy: function () { log.pans++; return 3; },
      zoomAt: function () {},
      live: function (on) { log.live.push(on); },
      tap: function (kind, id) { log.taps.push(kind + ':' + id); },
      cancelDrag: function (st) { log.cancels.push(st); },
      longPress: function (kind, id) { log.longs.push(kind + ':' + id); return longAnswer(kind, id); }
    };
    var h = G.attach(el, api, {
      now: function () { return t; }, frame: function () { return 1; }, cancelFrame: function () {},
      setTimeout: function (f, ms) { timers.push({ f: f, at: t + ms, live: true }); return timers.length; },
      clearTimeout: function (k) { if (timers[k - 1]) timers[k - 1].live = false; }
    });
    function ev(id, x, y, extra) { var e = { pointerId: id, clientX: x, clientY: y, pointerType: 'touch', button: 0, target: null }; for (var k in extra) e[k] = extra[k]; return e; }
    return {
      h: h, log: log,
      down: function (id, x, y, target, extra) { var e = ev(id, x, y, extra); e.target = target; L.pointerdown(e); },
      move: function (id, x, y) { t += 16; L.pointermove(ev(id, x, y)); },
      up: function (id, x, y, extra) { L.pointerup(ev(id, x, y, extra)); },
      cancel: function (id) { L.pointercancel(ev(id, 0, 0)); },
      wait: function (ms) {
        var end = t + ms;
        for (;;) {
          var next = null;
          timers.forEach(function (x) { if (x.live && x.at <= end && (!next || x.at < next.at)) next = x; });
          if (!next) break;
          t = next.at; next.live = false; next.f();
        }
        t = end;
      }
    };
  }
  function gestureSpec() {
    var HDR = { kind: 'group', id: 'g1' };
    var yes = function () { return true; }, no = function () { return false; };
    var r = rig(yes);
    r.down(1, 60, 300, HDR);
    r.wait(G.LONG_MS - 1);
    eq('PRESS_GROUP: no long press before LONG_MS', r.log.longs.length + ':' + r.h.state(), '0:PRESS_GROUP');
    r.wait(1);
    eq('PRESS_GROUP: LONG_MS reports {kind: group, id}', r.log.longs.join(','), 'group:g1');
    eq('PRESS_GROUP: taken, the gesture is GROUP_SHEET', r.h.state(), 'GROUP_SHEET');
    r.move(1, 60, 360);
    r.move(1, 60, 420);
    eq('GROUP_SHEET: moves do not pan', r.log.pans, 0);
    r.up(1, 60, 420);
    eq('GROUP_SHEET: the release is not a tap (no fold)', r.log.taps.length + ':' + r.h.state(), '0:IDLE');

    var d = rig(no);
    d.down(1, 60, 300, HDR);
    d.wait(1000);
    d.up(1, 60, 300);
    eq('PRESS_GROUP: an owner that refuses keeps the press: the release still folds', d.log.longs.join(',') + '|' + d.log.taps.join(','), 'group:g1|group:g1');
    var q = rig(yes);
    q.down(1, 60, 300, HDR);
    q.wait(120);
    q.up(1, 60, 300);
    eq('PRESS_GROUP: a quick tap folds and reports no long press', q.log.longs.length + '|' + q.log.taps.join(','), '0|group:g1');
    var p = rig(yes);
    p.down(1, 60, 300, HDR);
    p.move(1, 60, 320);
    eq('PRESS_GROUP: move > slop before LONG pans (rows only)', p.h.state() + ':' + (p.log.pans > 0), 'PAN:true');
    p.wait(1000);
    p.up(1, 60, 320);
    eq('PRESS_GROUP: a pan never becomes a long press or a tap', p.log.longs.length + ':' + p.log.taps.length, '0:0');
    var m = rig(yes);
    m.down(1, 60, 300, HDR, { pointerType: 'mouse' });
    m.wait(1000);
    m.up(1, 60, 300, { pointerType: 'mouse' });
    eq('PRESS_GROUP: mouse has no long press (§13.2); the click folds', m.log.longs.length + '|' + m.log.taps.join(','), '0|group:g1');
    var f = rig(yes);
    f.down(1, 60, 300, HDR);
    f.wait(100);
    f.down(2, 200, 400, { kind: 'bg' });
    f.wait(1000);
    eq('PRESS_GROUP: a second finger pinches and cancels the long press', f.h.state() + ':' + f.log.longs.length, 'PINCH:0');
    var c = rig(yes);
    c.down(1, 60, 300, HDR);
    c.wait(G.LONG_MS);
    c.cancel(1);
    eq('GROUP_SHEET: a cancel ends it quietly', c.h.state() + ':' + c.log.taps.length, 'IDLE:0');
    var b = rig(yes);
    b.down(1, 300, 300, { kind: 'bar', id: 't1' });
    b.wait(G.LONG_MS);
    eq('bars keep their long press (ARMED)', b.log.longs.join(',') + ':' + b.h.state(), 'bar:t1:ARMED');
  }

  /* ------------------------------------ phase 2: strings and shell CSS */

  // §9: the G3 strings, en keys with their zh-CN text.
  var ZH_G3 = {
    'Add group': '添加分组', 'Groups': '分组', 'Group name': '分组名称', 'A group needs a name': '分组需要名称',
    'New group…': '新建分组…', 'Move to new group': '移到新分组', 'Move up': '上移', 'Move down': '下移',
    'Delete group': '删除分组', 'Tap again to delete the group': '再点一次以删除分组', 'Drag tasks here': '将任务拖到这里',
    'Removed from its group': '已移出分组', 'The task list needs a heading': '任务列表需要标题', 'Task list heading': '任务列表标题', 'Heading level': '标题级别',
    'This name is the task list heading': '这个名称与任务列表标题相同'
  };
  var ZH_G3_PATTERNS = {
    'Deleted group “{title}”. Its tasks are now ungrouped.': '已删除分组“{title}”，其中的任务已移出分组。',
    'Moved to {group}': '已移到“{group}”',
    '{n} unscheduled': '{n} 个未排期',
    '{title}, {n} task(s), {m} unscheduled': '{title}，{n} 个任务，{m} 个未排期'
  };
  function stringsSpec() {
    Object.keys(ZH_G3).forEach(function (k) { eq('G3 string zh-CN: ' + k, I.ZH[k], ZH_G3[k]); });
    Object.keys(ZH_G3_PATTERNS).forEach(function (k) { eq('G3 pattern zh-CN: ' + k, I.PATTERNS[k], ZH_G3_PATTERNS[k]); });
    I.setLanguage('zh-CN');
    var zh = [I.fmt('Moved to {group}', { group: 'Build' }), I.fmt('{title}, {n} task(s), {m} unscheduled', { title: 'Build', n: 2, m: 1 }),
      I.fmt('Deleted group “{title}”. Its tasks are now ungrouped.', { title: 'Build' })].join('|');
    I.setLanguage('en-US');
    eq('G3 strings: zh-CN formatting', zh, '已移到“Build”|Build，2 个任务，1 个未排期|已删除分组“Build”，其中的任务已移出分组。');
    eq('G3 strings: en plural', I.fmt('{title}, {n} task(s), {m} unscheduled', { title: 'Build', n: 1, m: 1 }), 'Build, 1 task, 1 unscheduled');
  }

  // The shell's G3 rules (§8.2, review round 1 of phase 1): the header flash
  // stops under reduced motion in both blocks and leaves no static tint there.
  function cssSpec() {
    var css = global.GT_SHELL;
    if (!css) { ok('the G3 CSS spec needs GT_SHELL (node only)', true); return; }
    function block(start) {
      var i = css.indexOf(start);
      if (i < 0) return '';
      var depth = 0, j = css.indexOf('{', i);
      for (var k = j; k < css.length; k++) { if (css[k] === '{') depth++; else if (css[k] === '}' && --depth === 0) return css.slice(j, k + 1); }
      return '';
    }
    var media = block('@media (prefers-reduced-motion: reduce)');
    var cls = css.split('\n').filter(function (l) { return l.indexOf(':root.reduce-motion') === 0 || /^\s*:root\.reduce-motion/.test(l); }).join('\n');
    ok('reduced motion (media): .g-grp.flash is in the animation: none rule', /\.g-grp\.flash[^{]*\{\s*animation:\s*none/.test(media) || /\.g-grp\.flash,[^{]*\{\s*animation:\s*none/.test(media), media.slice(0, 200));
    ok('reduced motion (class): .g-grp.flash is in the animation: none rule', /:root\.reduce-motion \.g-grp\.flash[^{]*\{\s*animation:\s*none/.test(cls) || /:root\.reduce-motion \.g-grp\.flash,/.test(cls), cls.slice(0, 200));
    ok('reduced motion: no static tint on a flashed header (it would read as a drop target)', !/\.g-grp\.flash\s*\{\s*background/.test(media) && !/reduce-motion \.g-grp\.flash\s*\{\s*background/.test(cls));
    ['.g-grp .g-gh {', '.g-grp .g-gh:empty {', '.g-grp.drop {', '.g-grp.drop .g-gn {', '.g-grp.flash {', '.g-slot {', '.g-slot.drop::before {', '.g-root.mini .g-grp .g-gh {']
      .forEach(function (sel) { ok('G3 CSS rule ' + sel, css.indexOf(sel) >= 0); });
    ok('.g-grp.drop tints with the group hue (--h-fill) and outlines in accent', /\.g-grp\.drop \{[^}]*--accent[^}]*--h-fill/.test(css));
  }

  SPEC.suites.push({ name: 'the G3 strings spec', fn: stringsSpec });
  SPEC.suites.push({ name: 'the G3 shell CSS spec', fn: cssSpec });
  SPEC.suites.push({ name: 'the G3 rows spec', fn: rowsSpec });
  SPEC.suites.push({ name: 'the G3 reorder target spec', fn: targetSpec });
  SPEC.suites.push({ name: 'the G3 reorder target property', fn: propertySpec });
  SPEC.suites.push({ name: 'the G3 keyboard step spec', fn: stepSpec });
  SPEC.suites.push({ name: 'the G3 render spec', fn: renderSpec });
  SPEC.suites.push({ name: 'the G3 PRESS_GROUP spec', fn: gestureSpec });

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
