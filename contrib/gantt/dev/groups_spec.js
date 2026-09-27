/*
 * Gantt G2 model assertions (task-groups plan §6.1, §7, §10.1 "model"):
 * model.applyList (the fold of the note's list into the chart), the gorder
 * patch, moveToGroup, moveGroup, merge3 over folds and group edits, and the
 * fold half of the hand-edits property (fold equality against an oracle
 * computed from the edit, idempotence, inverse, convergence in one save).
 * Pure: no store. Runs under node (dev/run.js) and in the browser
 * (dev/auto_smoke.html).
 */
(function (global) {
  'use strict';
  var GT = global.GT, SPEC = GT.spec;
  var A = SPEC.api, ok = A.ok, eq = A.eq, fix = A.fix;
  var B = GT.block, M = GT.model;

  function json(x) { return JSON.stringify(x); }
  function chart(d) { return M.coerce(d).chart; }
  function ser(c) { return B.serialize(c); }
  function ids(l) { return l.map(function (x) { return x.id; }); }
  // G2 phase 2: read folds; these model cases fold the block's own chart
  // (`json`) themselves, so the read is presented unfolded.
  function LR(text) { var r = B.read(text, { list: true, listDefault: 'Tasks' }); return r.json ? Object.assign({}, r, { chart: r.json, folded: r.chart }) : r; }
  function RP(c, sums, o) { return B.regionParts(c, sums, Object.assign({ list: true }, o || {})); }
  function fold(text) { var r = LR(text); return { r: r, f: M.applyList(r.chart, r.list) }; }
  // One chart save as the phase-2 store will do it (§6.4): the live chart
  // written with the read's blocks in place of the read's region.
  function saveWith(text, r, live, sums) {
    var p = RP(live, sums || {}, { embedOutside: r.embedOutside, attach: r.list ? r.list.attach : {}, ambiguous: r.list ? r.list.ambiguous : [] });
    return text.slice(0, r.region.start) + (p.spill ? p.spill + '\n\n' : '') + p.text + text.slice(r.region.end);
  }
  // Read, fold, save.
  function foldSave(text) { var x = fold(text); return saveWith(text, x.r, x.f.chart); }
  function freeze(x) {
    if (x && typeof x === 'object' && !Object.isFrozen(x)) { Object.freeze(x); Object.keys(x).forEach(function (k) { freeze(x[k]); }); }
    return x;
  }
  function gtitles(c) { return c.groups.map(function (g) { return g.id + ':' + g.title; }); }
  function groupOf(c, id) { return M.task(c, id).group; }
  // Every check a fold result must pass whatever the note: pure inverse,
  // forward patch, coerce-clean, idempotent on the same list.
  function laws(c, list, f) {
    var bad = [];
    if (ser(M.applyPatch(f.chart, f.inverse).chart) !== ser(c)) bad.push('inverse');
    if (ser(M.applyPatch(c, f.patch).chart) !== ser(f.chart)) bad.push('patch');
    if (ser(M.coerce(JSON.parse(ser(f.chart))).chart) !== ser(f.chart)) bad.push('coerce');
    // In memory too: a shadow group value equal to a new group's id reads
    // back as membership (review round 1 of G2 phase 1).
    if (!M.same(M.coerce(JSON.parse(ser(f.chart))).chart, f.chart)) bad.push('coerce in memory');
    if (M.applyList(f.chart, list).changed) bad.push('idempotent');
    if (f.changed !== (ser(f.chart) !== ser(c))) bad.push('changed flag');
    return bad;
  }

  /* ================================================= synthetic chart */

  var SYN = { v: 1, settings: { listHeading: 'Tasks' },
    groups: [{ id: 'gA', title: 'Alpha' }, { id: 'gB', title: 'Beta', color: 'teal' }, { id: 'gC', title: 'Gamma' }],
    tasks: [
      { id: 'u1', note: 'nu1', title: 'U1', start: '2026-10-01' },
      { id: 'a1', note: 'na1', title: 'A1', start: '2026-10-02', group: 'gA' },
      { id: 'a2', note: 'na2', title: 'A2', start: '2026-10-03', group: 'gA' },
      { id: 'b1', note: 'nb1', title: 'B1', start: '2026-10-04', group: 'gB' },
      { id: 'b2', note: 'nb2', title: 'B2', start: '2026-10-05', group: 'gB' },
      { id: 'm1', title: 'Gate', start: '2026-10-06', milestone: true, group: 'gB' }
    ] };
  function syn(d) { return chart(d || SYN); }
  function synNote(c) { return 'Intro.\n\n' + RP(c || syn(), {}).text + '\n\nTail.'; }
  function tline(c, id) { var t = M.task(c, id); return '- [' + t.title + '](synapseresource://note/' + t.note + '?via=gantt) · ' + GT.dates.format(t.start); }
  function without(text, line) { var i = text.indexOf(line + '\n'); return text.slice(0, i) + text.slice(i + line.length + 1); }
  function insertAfter(text, anchor, line) { var i = text.indexOf(anchor + '\n') + anchor.length + 1; return text.slice(0, i) + line + '\n' + text.slice(i); }
  function moveLine(text, line, anchor) { return insertAfter(without(text, line), anchor, line); }

  /* ============================================================ gorder */

  function gorderSpec() {
    var c = syn();
    var r = M.applyPatch(c, [{ op: 'gorder', ids: ['gC', 'gA', 'gB'] }]);
    eq('gorder: the listed groups take their slots in order', json(ids(r.chart.groups)), json(['gC', 'gA', 'gB']));
    eq('gorder: inverse restores', json(ids(M.applyPatch(r.chart, r.inverse).chart.groups)), json(['gA', 'gB', 'gC']));
    eq('gorder: a subset keeps the others in place', json(ids(M.applyPatch(c, [{ op: 'gorder', ids: ['gC', 'gA'] }]).chart.groups)), json(['gC', 'gB', 'gA']));
    var r2 = M.applyPatch(c, [{ op: 'gorder', ids: ['gone', 'gB', 'gB', 7, null, 'gA'] }]);
    eq('gorder: unknown, repeated and non-string ids are skipped', json(ids(r2.chart.groups)), json(['gB', 'gA', 'gC']));
    ['nope', null, { length: 2 }, 5].forEach(function (bad) {
      var rb = M.applyPatch(c, [{ op: 'gorder', ids: bad }]);
      ok('gorder: ids ' + json(bad) + ' is a no-op without inverse', rb.chart === c && rb.inverse.length === 0);
    });
    var rn = M.applyPatch(c, [{ op: 'gorder', ids: ['gA', 'gB', 'gC'] }]);
    ok('gorder: the current order is a no-op without inverse', rn.chart === c && rn.inverse.length === 0);
    ok('gorder: tasks untouched', r.chart.tasks === c.tasks);
    var fz = freeze(syn());
    var rf = M.applyPatch(fz, [{ op: 'gorder', ids: ['gB', 'gA'] }]);
    eq('gorder: frozen input', json(ids(rf.chart.groups)), json(['gB', 'gA', 'gC']));
    // Added since: a group inserted after the inverse was taken keeps its slot.
    var added = M.applyPatch(r.chart, [{ op: 'group', id: 'gN', index: 1, group: { id: 'gN', title: 'New', color: null, _x: {} } }]).chart;
    eq('gorder: a group added since keeps its slot', json(ids(M.applyPatch(added, r.inverse).chart.groups)), json(['gA', 'gN', 'gB', 'gC']));
  }

  /* ========================================================= moveGroup */

  function moveGroupSpec() {
    var c = syn();
    var r = M.moveGroup(c, 'gC', 0);
    eq('moveGroup: moves', json(ids(r.chart.groups)), json(['gC', 'gA', 'gB']));
    eq('moveGroup: inverse is one gorder', json(r.inverse), json([{ op: 'gorder', ids: ['gA', 'gB', 'gC'] }]));
    eq('moveGroup: inverse restores', ser(M.applyPatch(r.chart, r.inverse).chart), ser(c));
    eq('moveGroup: clamps high', json(ids(M.moveGroup(c, 'gA', 99).chart.groups)), json(['gB', 'gC', 'gA']));
    eq('moveGroup: clamps low', json(ids(M.moveGroup(c, 'gC', -4).chart.groups)), json(['gC', 'gA', 'gB']));
    ok('moveGroup: same index is a no-op', M.moveGroup(c, 'gB', 1).chart === c && !M.moveGroup(c, 'gB', 1).inverse.length);
    ok('moveGroup: unknown group or bad index is a no-op', M.moveGroup(c, 'gX', 0).chart === c && M.moveGroup(c, 'gA', NaN).chart === c && M.moveGroup(c, 'gA', '1').chart === c);
    ok('moveGroup: tasks and records untouched', r.chart.tasks === c.tasks && r.chart.groups[0] === c.groups[2]);
    ok('moveGroup: frozen input', M.moveGroup(freeze(syn()), 'gA', 2).chart.groups[2].id === 'gA');
    // After a merge that added a group (§10.1): mine moved Gamma first, theirs added a group.
    var theirs = M.addGroup(c, { title: 'Delta' }, 1);
    var mg = M.merge3(c, r.chart, theirs.chart);
    eq('moveGroup: merge with an added group, no conflict', mg.conflicts.length, 0);
    eq('moveGroup: merged order keeps my move and their group', json(ids(mg.chart.groups)), json(['gC', 'gA', theirs.id, 'gB']));
    eq('moveGroup: undo after that merge restores my order and keeps theirs in its slot',
      json(ids(M.applyPatch(mg.chart, r.inverse).chart.groups)), json(['gA', 'gB', theirs.id, 'gC']));
  }

  /* ======================================================= moveToGroup */

  function moveToGroupSpec() {
    var c = syn();
    function order(x) { return ids(x.chart.tasks).join(','); }
    var r = M.moveToGroup(c, 'u1', 'gA');
    eq('moveToGroup: end of the group', order(r) + '|' + groupOf(r.chart, 'u1'), 'a1,a2,u1,b1,b2,m1|gA');
    eq('moveToGroup: inverse is reorder\'s (order + set group)', json(r.inverse.map(function (p) { return p.op; })), json(['order', 'set']));
    eq('moveToGroup: inverse restores', ser(M.applyPatch(r.chart, r.inverse).chart), ser(c));
    eq('moveToGroup: after a task of that group', order(M.moveToGroup(c, 'b2', 'gA', { after: 'a1' })), 'u1,a1,b2,a2,b1,m1');
    eq('moveToGroup: after a task of another group falls back to the end', order(M.moveToGroup(c, 'u1', 'gA', { after: 'b1' })), 'a1,a2,u1,b1,b2,m1');
    eq('moveToGroup: after itself falls back to the end', order(M.moveToGroup(c, 'a1', 'gA', { after: 'a1' })), 'u1,a2,a1,b1,b2,m1');
    var g = M.moveToGroup(c, 'a1', 'gC');
    eq('moveToGroup: an empty group goes after the last task of the nearest earlier group', order(g) + '|' + groupOf(g.chart, 'a1'), 'u1,a2,b1,b2,m1,a1|gC');
    var c2 = chart(Object.assign({}, SYN, { groups: [{ id: 'gZ', title: 'Zero' }].concat(SYN.groups) }));
    eq('moveToGroup: an empty first group with no earlier tasks goes first', order(M.moveToGroup(c2, 'b2', 'gZ')), 'b2,u1,a1,a2,b1,m1');
    eq('moveToGroup: ungrouped goes after the last ungrouped task', order(M.moveToGroup(c, 'b1', null)) + '|' + groupOf(M.moveToGroup(c, 'b1', null).chart, 'b1'), 'u1,b1,a1,a2,b2,m1|null');
    var c3 = chart(Object.assign({}, SYN, { tasks: SYN.tasks.slice(1) }));
    eq('moveToGroup: ungrouped with no ungrouped task goes first', order(M.moveToGroup(c3, 'b1', null)), 'b1,a1,a2,b2,m1');
    eq('moveToGroup: undefined group means ungrouped', groupOf(M.moveToGroup(c, 'a1').chart, 'a1'), null);
    eq('moveToGroup: an explicit index', order(M.moveToGroup(c, 'u1', 'gB', 3)) + '|' + groupOf(M.moveToGroup(c, 'u1', 'gB', 3).chart, 'u1'), 'a1,a2,b1,u1,b2,m1|gB');
    ok('moveToGroup: unknown group or task is a no-op', M.moveToGroup(c, 'u1', 'gX').chart === c && M.moveToGroup(c, 'zz', 'gA').chart === c);
    ok('moveToGroup: already last in that group is a no-op', M.moveToGroup(c, 'a2', 'gA').chart === c);
    var sh = chart({ v: 1, groups: [{ id: 'g1', title: 'G' }], tasks: [{ id: 't1', note: 'n1', group: 'gone-1' }] });
    var rs = M.moveToGroup(sh, 't1', 'g1');
    ok('moveToGroup: a shadow group is dropped when the task moves', rs.chart.tasks[0].group === 'g1' && !('group' in rs.chart.tasks[0]._x));
    eq('moveToGroup: ...and its inverse brings the shadow back', ser(M.applyPatch(rs.chart, rs.inverse).chart), ser(sh));
    ok('moveToGroup: frozen input', groupOf(M.moveToGroup(freeze(syn()), 'u1', 'gC').chart, 'u1') === 'gC');
    // The Remove flow (§6.3): removeGroup then moveToGroup to a held task's placement.
    var x = fold(fix('list-heading-deleted.md')), p = x.f.report.placement;
    var rm = M.removeGroup(x.f.chart, 'g2').chart;
    rm = M.moveToGroup(rm, 't3', p.t3.group, { after: p.t3.after }).chart;
    rm = M.moveToGroup(rm, 't4', p.t4.group, { after: p.t4.after }).chart;
    eq('moveToGroup: Remove puts held tasks where the note shows them', json(rm.tasks.filter(function (t) { return t.group === 'g1'; }).map(function (t) { return t.id; })), json(['t1', 't2', 't3', 't4']));
    var hdx = fix('list-heading-deleted.md'), saved = saveWith(hdx, LR(hdx), rm);
    function head(s) { return s.slice(0, s.indexOf('```synapse-gantt')); }
    eq('moveToGroup: ...and the save leaves the list as the user left it', head(saved), head(hdx));
  }

  /* ======================================================== fixtures */

  function fixtureSpec() {
    var basic = fold(fix('list-basic.md'));
    ok('applyList: list-basic changes nothing', !basic.f.changed && !basic.f.inverse.length && basic.f.chart === basic.r.chart);
    eq('applyList: list-basic report is empty', json([basic.f.moves, basic.f.renames, basic.f.newGroups, basic.f.report.held, basic.f.report.goneGroups]), json([[], [], [], [], []]));

    var nh = fold(fix('list-new-heading.md')), qa = nh.r.list.sections[4].marker.gid;
    var taken = {};
    nh.r.chart.tasks.forEach(function (t) { taken[t.id] = true; });
    nh.r.chart.groups.forEach(function (g) { taken[g.id] = true; });
    eq('applyList new: the derived id is derivedId(g, list:QA#0, chart ids)', qa, B.derivedId('g', 'list:QA#0', taken));
    eq('applyList new: QA added after Launch, untitled colour', json(gtitles(nh.f.chart)), json(['g1:Discovery', 'g2:Build', 'g3:Launch', qa + ':QA']));
    ok('applyList new: the new group has no colour', M.group(nh.f.chart, qa).color === null);
    eq('applyList new: Beta cut folded into QA', groupOf(nh.f.chart, 't4'), qa);
    eq('applyList new: report', json([nh.f.newGroups, nh.f.moves]), json([[{ id: qa, title: 'QA' }], [{ id: 't4', from: 'g2', to: qa }]]));
    ok('applyList new: changed', nh.f.changed);
    eq('applyList new: the same id on a read with text added above', fold('Prose.\n\n' + fix('list-new-heading.md')).f.newGroups[0].id, qa);
    var s1 = foldSave(fix('list-new-heading.md')), again = fold(s1);
    ok('applyList new: one save writes ### QA with Beta cut under it', s1.indexOf('### QA\n- ◆ [Beta cut]') > 0, s1);
    ok('applyList new: the saved note folds to nothing (key = body key)', !again.f.changed && ser(again.r.chart) === ser(nh.f.chart));
    eq('applyList new: the laws hold', json(laws(nh.r.chart, nh.r.list, nh.f)), '[]');

    var rn = fold(fix('list-renamed-heading.md'));
    eq('applyList renamed: same ids, new titles', json(gtitles(rn.f.chart)), json(['g1:Discovery', 'g2:Construction', 'g3:Release']));
    eq('applyList renamed: report', json(rn.f.renames), json([{ id: 'g2', from: 'Build', to: 'Construction' }, { id: 'g3', from: 'Launch', to: 'Release' }]));
    ok('applyList renamed: colour kept, nothing moved', M.group(rn.f.chart, 'g2').color === 'teal' && !rn.f.moves.length);
    eq('applyList renamed: the laws hold', json(laws(rn.r.chart, rn.r.list, rn.f)), '[]');

    var ro = fold(fix('list-reordered-sections.md'));
    eq('applyList reordered: group order follows the note', json(ids(ro.f.chart.groups)), json(['g2', 'g1', 'g3']));
    ok('applyList reordered: groupsReordered, no task moved or reordered', ro.f.report.groupsReordered && !ro.f.report.tasksReordered && !ro.f.moves.length);
    eq('applyList reordered: inverse is one gorder', json(ro.f.inverse), json([{ op: 'gorder', ids: ['g1', 'g2', 'g3'] }]));

    var hd = fold(fix('list-heading-deleted.md'));
    ok('applyList heading deleted: Build kept, its tasks held in Build, nothing changes', !hd.f.changed && groupOf(hd.f.chart, 't3') === 'g2' && groupOf(hd.f.chart, 't4') === 'g2');
    eq('applyList heading deleted: gone, held, placement', json([hd.f.report.goneGroups, hd.f.report.held, hd.f.report.placement]),
      json([['g2'], ['t3', 't4'], { t3: { group: 'g1', after: 't2' }, t4: { group: 'g1', after: 't3' } }]));
    eq('applyList heading deleted: deleted.groups', json(hd.f.deleted.groups), json(['g2']));

    var dm = fold(fix('list-duplicate-marker.md'));
    ok('applyList duplicate marker: nothing created, Kickoff held ungrouped', !dm.f.changed && dm.f.chart.groups.length === 3 && groupOf(dm.f.chart, 't0') === null);
    eq('applyList duplicate marker: held with the duplicate\'s group as placement', json([dm.f.report.held, dm.f.report.placement, dm.f.report.duplicates.length]), json([['t0'], { t0: { group: 'g2', after: null } }, 1]));

    var nv = fold(fix('list-no-via.md'));
    eq('applyList no-via: Kickoff folded into Build', groupOf(nv.f.chart, 't0'), 'g2');
    eq('applyList no-via: Build\'s order is the note\'s', json(nv.f.chart.tasks.filter(function (t) { return t.group === 'g2'; }).map(function (t) { return t.id; })), json(['t3', 't4', 't0']));
    ok('applyList no-via: a save rewrites it MARKED and folds to nothing', !fold(foldSave(fix('list-no-via.md'))).f.changed);

    var sg = fold(fix('list-shadow-group.md'));
    ok('applyList shadow: no change, the shadow is kept', !sg.f.changed && sg.f.chart.tasks[0]._x.group === 'gone-1');

    var ci = fold(fix('list-copy-inside.md'));
    ok('applyList copy inside: the ambiguous task keeps its JSON group and is not reported moved', groupOf(ci.f.chart, 't3') === 'g2' && ci.f.report.ambiguous.indexOf('t3') >= 0 && !ci.f.moves.some(function (m) { return m.id === 't3'; }));

    var ob = fold(fix('list-older-build.md'));
    ok('applyList older build: no group created, nothing folded', !ob.f.changed && ob.f.chart.groups.length === 3 && ob.f.report.duplicates.length === 2, json(ob.f.report));

    var ta = fold(fix('list-typed-above-fence.md'));
    eq('applyList typed above fence: QA becomes the last group, empty', json([gtitles(ta.f.chart).slice(-1)[0].split(':')[1], ta.f.moves.length]), json(['QA', 0]));
    var sa = foldSave(fix('list-typed-above-fence.md'));
    ok('applyList typed above fence: written as ### QA after the line, then stable', sa.indexOf('Ask Ana about the date\n\n### QA\n\n```synapse-gantt') > 0 && foldSave(sa) === sa && !fold(sa).f.changed, sa);

    ['list-untitled-group.md', 'list-duplicate-titles.md', 'list-plain-elsewhere.md', 'list-typed-headings.md', 'list-foreign-links.md',
      'list-attached-notes.md', 'list-embed.md', 'list-cjk.md', 'list-crlf.md', 'list-level-3.md', 'list-closing-sequence.md',
      'list-group-named-like-heading.md', 'list-empty-group.md', 'list-level-l-text.md', 'list-copy-above.md', 'list-user-sections-above.md'].forEach(function (f) {
      var x = fold(fix(f));
      ok('applyList: ' + f + ' folds to nothing', !x.f.changed, json(x.f.report));
    });
    eq('applyList plain elsewhere: reported, not folded', json(fold(fix('list-plain-elsewhere.md')).f.report.plainElsewhere), json(['t3']));
    var lm = fold(fix('list-level-mismatch.md'));
    ok('applyList level mismatch: Build gone and kept, its tasks held', !lm.f.changed && json(lm.f.report.goneGroups) === json(['g2']) && lm.f.report.held.length === 2, json(lm.f.report));
    ok('applyList: a null list or a list without sections is a no-op', !M.applyList(basic.r.chart, null).changed && !M.applyList(basic.r.chart, {}).changed);
  }

  /* ======================================================= synthetic */

  function syntheticSpec() {
    var c = syn(), x0 = synNote(c);
    ok('syn: the written note folds to nothing', !fold(x0).f.changed);

    var sw = moveLine(x0, tline(c, 'a1'), tline(c, 'a2'));
    var f = fold(sw).f;
    eq('syn: lines swapped inside a group reorder the tasks', json(ids(f.chart.tasks)), json(['u1', 'a2', 'a1', 'b1', 'b2', 'm1']));
    ok('syn: ...tasksReordered, nothing moved', f.report.tasksReordered && !f.moves.length);

    var mv = moveLine(x0, tline(c, 'u1'), tline(c, 'b1'));
    f = fold(mv).f;
    eq('syn: an ungrouped line moved into Beta', groupOf(f.chart, 'u1') + '|' + json(f.chart.tasks.filter(function (t) { return t.group === 'gB'; }).map(function (t) { return t.id; })), 'gB|' + json(['b1', 'u1', 'b2', 'm1']));
    ok('syn: ...not reported as a reorder', !f.report.tasksReordered);
    var out = insertAfter(without(x0, tline(c, 'b2')), '## Tasks\n', tline(c, 'b2'));
    f = fold(out).f;
    eq('syn: a line moved to the top is ungrouped, before U1', groupOf(f.chart, 'b2') + '|' + json(f.chart.tasks.filter(function (t) { return t.group === null && t.note; }).map(function (t) { return t.id; })), 'null|' + json(['b2', 'u1']));
    ok('syn: the note-less milestone keeps its group', groupOf(f.chart, 'm1') === 'gB');

    var two = x0.replace('### Alpha\n', '### Apple\n').replace('### Beta\n', '### Banana\n');
    f = fold(two).f;
    eq('syn: two renames at once pair by overlap', json(gtitles(f.chart)), json(['gA:Apple', 'gB:Banana', 'gC:Gamma']));
    f = fold(x0.replace('### Gamma\n', '### Later\n')).f;
    eq('syn: an empty group renamed pairs by position', json(gtitles(f.chart).slice(-1)), json(['gC:Later']));
    var empty2 = chart(Object.assign({}, SYN, { groups: SYN.groups.concat([{ id: 'gD', title: 'Delta' }]) }));
    var e2 = synNote(empty2).replace('### Gamma\n', '### G2\n').replace('### Delta\n', '### D2\n');
    f = fold(e2).f;
    ok('syn: two empty groups renamed at once are two new groups and two gone ones', f.newGroups.length === 2 && json(f.report.goneGroups) === json(['gC', 'gD']), json(f.report));

    var twoQA = x0.replace('### Gamma\n', '### QA\n' + tline(c, 'a2') + '\n\n### QA\n' + tline(c, 'b2') + '\n\n### Gamma\n').replace(tline(c, 'a2') + '\n', '').replace(tline(c, 'b2') + '\n', '');
    var q = fold(twoQA), nq = q.f.newGroups;
    var tk = {};
    c.tasks.forEach(function (t) { tk[t.id] = true; });
    c.groups.forEach(function (g) { tk[g.id] = true; });
    var q0 = B.derivedId('g', 'list:QA#0', tk), q1 = B.derivedId('g', 'list:QA#1', tk);
    eq('syn: two new markers with one title get #0 and #1 ids', json(nq.map(function (g) { return g.id; })), json([q0, q1]));
    eq('syn: ...placed after Beta in note order, before Gamma', json(ids(q.f.chart.groups)), json(['gA', 'gB', q0, q1, 'gC']));
    ok('syn: ...and folded', groupOf(q.f.chart, 'a2') === q0 && groupOf(q.f.chart, 'b2') === q1, json(q.f.moves));
    eq('syn: ...the laws hold', json(laws(q.r.chart, q.r.list, q.f)), '[]');

    // taken: the derived id skips an id the chart holds (a renamed or gone group).
    var clash = B.derivedId('g', 'list:QA#0', {});
    var cc = chart(Object.assign({}, SYN, { groups: SYN.groups.concat([{ id: clash, title: 'Old' }]) }));
    var ct = synNote(cc).replace('### Old\n', '### QA\n\n### QB\n');
    var cf = fold(ct).f;
    ok('syn: the new id never collides with a gone group\'s id', cf.newGroups.length === 2 && cf.newGroups[0].id !== clash &&
      cf.newGroups[0].id === B.derivedId('g', 'list:QA#0', (function () { var t = {}; cc.tasks.concat(cc.groups).forEach(function (x) { t[x.id] = true; }); return t; })()) &&
      json(cf.report.goneGroups) === json([clash]), json(cf.report));
    // With one new marker and one gone group left, (c) pairs them: a rename.
    eq('syn: one unknown marker and one unpaired group pair by position', json(fold(synNote(cc).replace('### Old\n', '### QA\n')).f.renames), json([{ id: clash, from: 'Old', to: 'QA' }]));

    var top = x0.replace('## Tasks\n\n', '## Tasks\n\n### First\n\n');
    f = fold(top).f;
    eq('syn: a new marker above every group goes first and takes the ungrouped tasks', json(gtitles(f.chart)[0].split(':')[1]) + groupOf(f.chart, 'u1'), json('First') + f.newGroups[0].id);

    var del = x0.replace('### Beta\n', '');
    f = fold(del).f;
    eq('syn: Beta\'s marker deleted: held under Alpha with placements', json([f.report.held, f.report.placement.b1, f.report.placement.b2]),
      json([['b1', 'b2'], { group: 'gA', after: 'a2' }, { group: 'gA', after: 'b1' }]));
    ok('syn: ...Beta kept with its tasks', !f.changed);

    var copy = insertAfter(x0, tline(c, 'a2'), tline(c, 'b1'));
    f = fold(copy).f;
    ok('syn: a MARKED copy makes the task ambiguous; never folded', groupOf(f.chart, 'b1') === 'gB' && f.report.ambiguous.indexOf('b1') >= 0 && f.deleted.tasks.indexOf('b1') < 0);
    var gone = without(x0, tline(c, 'b1'));
    eq('syn: a deleted line is unlisted (deleted.tasks), not changed', json(fold(gone).f.deleted.tasks), json(['b1']));

    // Stale list: the list read against the input, applied to the fold.
    var st = fold(twoQA);
    ok('syn: applying the same list twice changes nothing', !M.applyList(st.f.chart, st.r.list).changed);
    ok('syn: remap names each section\'s group', json(st.f.remap) === json([null, 'gA', 'gB', q0, q1, 'gC']), json(st.f.remap));

    // Purity: frozen chart and list.
    var pr = LR(twoQA), before = ser(pr.chart) + json(pr.list);
    freeze(pr.chart); freeze(pr.list);
    var pf;
    try { pf = M.applyList(pr.chart, pr.list); } catch (e) { pf = null; }
    ok('syn: pure over frozen inputs', pf && pf.changed && ser(pr.chart) + json(pr.list) === before);

    // A shadow task under a marker moves and drops its shadow.
    var shd = chart(Object.assign({}, SYN, { tasks: SYN.tasks.concat([{ id: 's1', note: 'ns1', title: 'S1', group: 'gone-9' }]) }));
    var sx = synNote(shd), sline = '- [S1](synapseresource://note/ns1?via=gantt)';
    ok('syn: an ungrouped shadow task folds to nothing', !fold(sx).f.changed);
    var sm = fold(moveLine(sx, sline, tline(c, 'a2'))).f;
    ok('syn: a shadow task moved into Alpha takes it and drops the shadow', groupOf(sm.chart, 's1') === 'gA' && !('group' in M.task(sm.chart, 's1')._x));

    // G2 phase 1 review round 1.
    // (major, defect 2) Beta's marker deleted (its tasks now under Alpha)
    // and ### QA typed: no rename by position, QA is new, Beta gone and held.
    var bq = LR(x0.replace('### Beta\n', '').replace('### Gamma\n', '### QA\n\n### Gamma\n')), bqf = M.applyList(bq.chart, bq.list);
    var qaSec = bq.list.sections.filter(function (s) { return s.marker && s.marker.title === 'QA'; })[0];
    ok('Beta/QA: QA is a new group, not Beta renamed', qaSec.marker.kind === 'new' && qaSec.gid !== 'gB' && !bqf.renames.length, json(qaSec.marker));
    eq('Beta/QA: Beta gone, B1 and B2 held with their place under Alpha', json([bqf.report.goneGroups, bqf.report.held, bqf.report.placement.b1]),
      json([['gB'], ['b1', 'b2'], { group: 'gA', after: 'a2' }]));
    ok('Beta/QA: ...the fold adds QA after Alpha (the group above it) and keeps Beta with its tasks', gtitles(bqf.chart).join() === 'gA:Alpha,' + qaSec.gid + ':QA,gB:Beta,gC:Gamma' && groupOf(bqf.chart, 'b1') === 'gB', gtitles(bqf.chart).join());
    var bq2 = LR(without(without(x0.replace('### Beta\n', ''), tline(c, 'b1')), tline(c, 'b2')).replace('### Gamma\n', '### QA\n\n### Gamma\n'));
    ok('Beta/QA: with Beta\'s task lines deleted too, QA renames Beta by position', M.applyList(bq2.chart, bq2.list).renames.length === 1 &&
      bq2.list.sections.filter(function (s) { return s.marker && s.marker.title === 'QA'; })[0].gid === 'gB');
    ok('Beta/QA: the laws hold', laws(bq.chart, bq.list, bqf).length === 0, json(laws(bq.chart, bq.list, bqf)));

    // (minor) a derived id never equals a task's shadow group value.
    var s2 = { id: 's2', note: 'ns2', title: 'S2' }, pre = chart(Object.assign({}, SYN, { tasks: SYN.tasks.concat([s2]) }));
    var tk = {};
    pre.tasks.forEach(function (t) { tk[t.id] = true; });
    pre.groups.forEach(function (g) { tk[g.id] = true; });
    var clashId = B.derivedId('g', 'list:QA#0', tk);
    var shc = chart(Object.assign({}, SYN, { tasks: SYN.tasks.concat([Object.assign({ group: clashId }, s2)]) }));
    ok('shadow: the task holds the derived id as a shadow group', groupOf(shc, 's2') === null && M.task(shc, 's2')._x.group === clashId);
    var shx = LR(synNote(shc).replace('### Gamma\n', '### QA\n\n### Gamma\n')), shf = M.applyList(shx.chart, shx.list);
    ok('shadow: the new group\'s id is not the shadow value', shf.newGroups.length === 1 && shf.newGroups[0].id !== clashId, json(shf.newGroups));
    ok('shadow: the fold survives serialise and coerce in memory (S2 stays ungrouped)', M.same(M.coerce(JSON.parse(ser(shf.chart))).chart, shf.chart) &&
      groupOf(M.coerce(JSON.parse(ser(shf.chart))).chart, 's2') === null);

    // (minor) same title before overlap: a marker titled like Beta pairs
    // with Beta even when every task under it is Alpha's.
    var tv = chart({ v: 1, settings: { listHeading: 'Tasks' }, groups: [{ id: 'gA', title: 'Alpha' }, { id: 'gB', title: 'Beta' }],
      tasks: [{ id: 'a1', note: 'na1', title: 'A1', start: '2026-10-02', group: 'gA' }, { id: 'a2', note: 'na2', title: 'A2', start: '2026-10-03', group: 'gA' },
        { id: 'b1', note: 'nb1', title: 'B1', start: '2026-10-04', group: 'gB' }] });
    var tvx = LR('## Tasks\n\n### Beta\n' + tline(tv, 'a1') + '\n' + tline(tv, 'a2') + '\n\n### Gamma\n' + tline(tv, 'b1') + '\n\n' + B.fence(tv));
    eq('title vs overlap: ### Beta pairs with Beta by title, not Alpha by overlap', tvx.list.sections[1].marker.kind + ':' + tvx.list.sections[1].gid, 'same:gB');
    var tvf = M.applyList(tvx.chart, tvx.list);
    ok('title vs overlap: Gamma is new, Alpha gone with A1 and A2 held, B1 moves to Gamma', tvx.list.sections[2].marker.kind === 'new' &&
      json(tvf.report.goneGroups) === '["gA"]' && json(tvf.report.held) === '["a1","a2"]' && groupOf(tvf.chart, 'b1') === tvx.list.sections[2].gid, json(tvf.report));

    // (minor) an ambiguous id inside a section of a hand-built list is never folded.
    var hb = { sections: [{ marker: null, tasks: [] }, { marker: { gid: 'gB', kind: 'same', title: 'Beta' }, tasks: ['a1', 'b1'] }], ambiguous: ['a1'] };
    var hbf = M.applyList(tv, hb);
    ok('ambiguous guard: a1 listed under Beta but ambiguous keeps Alpha', groupOf(hbf.chart, 'a1') === 'gA' && !hbf.moves.length && json(hbf.report.ambiguous) === '["a1"]', json(hbf.report));

    // (nit) a new marker with a closing sequence takes the title without it.
    var cs = LR(x0.replace('### Gamma\n', '### QA ##\n\n### Gamma\n')), csf = M.applyList(cs.chart, cs.list);
    eq('closing sequence: ### QA ## makes a group titled QA', json(csf.newGroups.map(function (g) { return g.title; })), json(['QA']));
    ok('closing sequence: written as ### QA, then stable', !M.applyList(LR(saveWith(x0.replace('### Gamma\n', '### QA ##\n\n### Gamma\n'), cs, csf.chart)).chart,
      LR(saveWith(x0.replace('### Gamma\n', '### QA ##\n\n### Gamma\n'), cs, csf.chart)).list).changed);
  }

  /* =========================================================== merge3 */

  function mergeSpec() {
    var x = fold(fix('list-new-heading.md')), c = x.r.chart, f = x.f.chart;
    var m = M.merge3(c, f, f);
    ok('merge3: two folds of the same note, no conflict, the fold', !m.conflicts.length && ser(m.chart) === ser(f));
    var other = fold('Text on the other device.\n\n' + fix('list-new-heading.md')).f.chart;
    var mine = M.moveTask(f, 't1', 2).chart;
    m = M.merge3(c, mine, other);
    ok('merge3: a fold on each device plus my edit: no conflict, both kept', !m.conflicts.length && M.task(m.chart, 't1').start === M.task(f, 't1').start + 2 &&
      groupOf(m.chart, 't4') === x.f.newGroups[0].id && m.chart.groups.length === 4, json(m.conflicts));
    var mine2 = M.applyList(c, x.r.list).chart;
    eq('merge3: my fold against an unfolded theirs keeps the fold', ser(M.merge3(c, mine2, c).chart), ser(f));

    var s = syn(), note = synNote(s);
    var theirs = fold(moveLine(note, tline(s, 'b1'), '### Gamma')).f.chart;
    var mineG = M.moveToGroup(s, 'b1', 'gA').chart;
    m = M.merge3(s, mineG, theirs);
    eq('merge3: moved to different groups on both sides is <tid>.group', json(m.conflicts.map(function (k) { return k.key; })), json(['b1.group']));
    eq('merge3: ...resolved mine', groupOf(M.merge3(s, mineG, theirs, { resolutions: { 'b1.group': 'mine' } }).chart, 'b1'), 'gA');

    var renamed = fold(note.replace('### Beta\n', '### Bravo\n')).f.chart;
    m = M.merge3(s, M.removeGroup(s, 'gB').chart, renamed);
    eq('merge3: a group deleted here and renamed in the note is <gid>.removed', json(m.conflicts.map(function (k) { return k.key; })), json(['gB.removed']));

    var rA = M.renameGroup(s, 'gA', 'Aardvark').chart, rB = fold(note.replace('### Alpha\n', '### Apple\n')).f.chart;
    eq('merge3: renamed differently on both sides is <gid>.title', json(M.merge3(s, rA, rB).conflicts.map(function (k) { return k.key; })), json(['gA.title']));

    var bT = chart({ v: 1, settings: { listHeading: 'Tasks' } }), tZ = chart({ v: 1, settings: { listHeading: '任务' } });
    m = M.merge3(bT, bT, tZ);
    ok('merge3: listHeading from another locale over an untouched base: theirs, no conflict', !m.conflicts.length && m.chart.settings.listHeading === '任务');
    var b0 = chart({ v: 1 });
    eq('merge3: a heading set differently on both sides is settings.listHeading', json(M.merge3(b0, bT, tZ).conflicts.map(function (k) { return k.key; })), json(['settings.listHeading']));
    var lv = M.setSettings(bT, { listLevel: 3 }).chart, sk = M.setSettings(bT, { seedSkip: '0123abcd' }).chart;
    m = M.merge3(bT, lv, sk);
    ok('merge3: listLevel and seedSkip merge per key', !m.conflicts.length && m.chart.settings.listLevel === 3 && m.chart.settings.seedSkip === '0123abcd');

    var g1 = M.moveGroup(s, 'gC', 0).chart, g2 = M.moveGroup(s, 'gA', 2).chart;
    m = M.merge3(s, g1, g2);
    ok('merge3: group reorders on both sides never conflict', !m.conflicts.length && m.chart.groups.length === 3, json(m.conflicts));
  }

  /* ======================================================== properties */

  function mulberry32(a) {
    return function () {
      a |= 0; a = (a + 0x6D2B79F5) | 0;
      var t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  function seedOf() {
    return typeof global.GT_SEED === 'number' && isFinite(global.GT_SEED) ? global.GT_SEED : (Date.now() % 2147483647);
  }
  function hashes(n) { return new Array(n + 1).join('#'); }

  var TITLES = ['Plan', 'Fix [bug] **now**', 'a ] b', '[draft', '◆ diamond first', '设计评审', 'Launch 🚀', '',
    'x\ny', 'tab\there', '[[nested]]', ']', '**bold**', 'Q4 · 3/5', 'a](synapseresource://note/zz?via=gantt)',
    '  spaced  ', 'Untitled', 'Build', 'Build', 'QA'];
  var HEADS = ['Tasks', '任务', '计划 [草稿]', 'Road map'];

  // A chart like list_spec's generator (task-groups §10.1): duplicate, "",
  // Untitled and h-equal titles, empty groups, shadows, note-less tasks.
  function gen(rng, n) {
    function int(a, b) { return a + Math.floor(rng() * (b - a + 1)); }
    function pick(l) { return l[int(0, l.length - 1)]; }
    var L = int(1, 3), h = pick(HEADS), ng = int(0, 5), groups = [], tasks = [];
    for (var g = 0; g < ng; g++) {
      var gr = { id: 'g' + (g + 1), title: rng() < 0.12 ? h : pick(TITLES) };
      if (rng() < 0.2) gr.color = 'teal';
      groups.push(gr);
    }
    var nt = int(0, 10);
    for (var i = 0; i < nt; i++) {
      var kind = pick(['ranged', 'oneday', 'unsched', 'ms-note', 'ms-bare']);
      var t = { id: 't' + i, title: pick(TITLES) };
      if (kind !== 'ms-bare') t.note = 'n' + n + '-' + i;
      if (kind === 'ranged') { t.start = '2026-10-0' + int(1, 5); t.end = '2026-11-1' + int(0, 9); }
      else if (kind !== 'unsched') t.start = '2026-10-1' + int(0, 9);
      if (/^ms/.test(kind)) t.milestone = true;
      var r = rng();
      if (ng && r < 0.6) t.group = 'g' + int(1, ng); else if (r < 0.7) t.group = 'gone-' + int(1, 3);
      tasks.push(t);
    }
    // Shuffle so tasks[] is not ordered by group (the written list is).
    for (var s = tasks.length - 1; s > 0; s--) { var j = int(0, s), tmp = tasks[s]; tasks[s] = tasks[j]; tasks[j] = tmp; }
    var settings = { listHeading: h, embed: rng() < 0.3 };
    if (L !== 2) settings.listLevel = L;
    return { c: chart({ v: 1, settings: settings, groups: groups, tasks: tasks }), L: L, h: h };
  }
  // Attachable items (§5.3), a subset of list_spec's.
  function genItem(rng, g) {
    function int(a, b) { return a + Math.floor(rng() * (b - a + 1)); }
    function pick(l) { return l[int(0, l.length - 1)]; }
    var noted = g.c.tasks.filter(function (t) { return t.note; }), L = g.L;
    var levels = [1, 2, 3, 4, 5, 6].filter(function (x) { return x !== L + 1; });
    return pick([
      function () { return 'Remember the launch room.'; },
      function () { return 'First paragraph.\n\nSecond paragraph.'; },
      function () { return '  - Owner: Ana'; },
      function () { return '- **Waiting on legal**'; },
      function () { return hashes(pick(levels)) + ' Notes'; },
      function () { return hashes(L) + ' Aside'; },
      function () { return '```\n' + hashes(L + 1) + ' Fake marker\n' + (noted.length ? '- [X](synapseresource://note/' + pick(noted).note + '?via=gantt)\n' : '') + '```'; },
      function () { return '- [Other](synapseresource://note/zz-' + int(0, 99) + '?via=gantt)'; },
      function () { return '  - [Ref](synapseresource://note/zz-' + int(0, 99) + ')'; },
      function () { var t = noted.length ? pick(noted) : null; return t ? '[' + B.ltext(t.title) + '](synapseresource://note/' + t.note + ')' : 'no task'; },
      function () { return noted.length ? '- [T](synapseresource://note/' + pick(noted).note + '?via=gantt) with text after' : 'x'; }
    ])();
  }
  function writtenNote(rng, n) {
    var g = gen(rng, n), owners = Object.keys(RP(g.c, {}).attach), A = {};
    owners.forEach(function (k) {
      A[k] = [];
      if (rng() < 0.3) { var cnt = 1 + Math.floor(rng() * 2); for (var i = 0; i < cnt; i++) A[k] = A[k].concat(genItem(rng, g).split('\n')); }
    });
    var P = rng() < 0.5 ? '' : (rng() < 0.5 ? 'Intro.\n\n' : hashes(g.L) + ' ' + B.htext(g.h) + '\nMy own list.\n\n');
    var r = RP(g.c, {}, { attach: A });
    return { g: g, text: P + r.text + (rng() < 0.5 ? '' : '\n\nTail.') };
  }

  // Written lists fold to nothing (§6.1 properties): 300 charts.
  function writtenSpec() {
    var seed = seedOf() + 21, rng = mulberry32(seed), fails = 0, first = '', shuffled = 0;
    for (var n = 0; n < 300; n++) {
      var w = writtenNote(rng, n), x = fold(w.text);
      if (w.g.c.groups.length && w.g.c.tasks.some(function (t, k, arr) { return k > 1 && arr[k - 2].group === t.group && arr[k - 1].group !== t.group; })) shuffled++;
      if (x.f.changed || x.f.report.held.length) { fails++; if (!first) first = '#' + n + ' ' + json(x.f.report) + '\n' + w.text; }
    }
    ok('fold: 300 written lists fold to nothing, tasks[] in any order (seed ' + seed + ')', fails === 0, fails + ' failures; first: ' + first);
    ok('fold: the generator interleaves groups in tasks[] (' + shuffled + ')', shuffled > 60);
    // The literal §6.1 step 4 (one order over every owned task) is not this:
    // ungrouped tasks come first in the note whatever their tasks[] slot.
    var lit = chart({ v: 1, settings: { listHeading: 'Tasks' }, groups: [{ id: 'g1', title: 'G' }],
      tasks: [{ id: 'a', note: 'na', title: 'A', group: 'g1' }, { id: 'b', note: 'nb', title: 'B' }] });
    var lr = LR(RP(lit, {}).text);
    ok('fold: spec defect 1 counterexample folds to nothing (per-group order)', lr.list.sections[0].tasks[0] === 'b' && !M.applyList(lit, lr.list).changed);
  }

  /*
   * An oracle for the fold, written from §6.1 apart from model.js and
   * block.mapMarkers: sections [{title|null, tasks}] (the first one the
   * ungrouped part) as the edit left them, to the expected chart.
   */
  function oracleFold(c, sections) {
    var groups = c.groups, gn = groups.map(function (g) { return B.norm(g.title) || 'Untitled'; });
    var gOf = {};
    c.tasks.forEach(function (t) { gOf[t.id] = t.group; });
    var mk = sections.slice(1).map(function (s) { return { title: s.title, tasks: s.tasks, gid: null, kind: null, dupOf: null }; });
    var used = groups.map(function () { return false; });
    function ov(m, j) { return m.tasks.filter(function (id) { return gOf[id] === groups[j].id; }).length; }
    function pair(m, j, kind) { m.gid = groups[j].id; m.kind = kind; used[j] = true; }
    var seenT = [];
    mk.forEach(function (m) { if (seenT.indexOf(m.title) < 0) seenT.push(m.title); });
    seenT.forEach(function (T) {
      var ms = mk.filter(function (m) { return m.title === T; }), gs = [];
      gn.forEach(function (t, j) { if (t === T) gs.push(j); });
      while (ms.length && gs.length) {
        var bi = 0, bj = 0, bo = -1;
        ms.forEach(function (m, a) { gs.forEach(function (j, b) { var o = ov(m, j); if (o > bo) { bo = o; bi = a; bj = b; } }); });
        pair(ms[bi], gs[bj], 'same');
        ms.splice(bi, 1);
        gs.splice(bj, 1);
      }
    });
    mk.forEach(function (m) {
      if (m.gid !== null || gn.indexOf(m.title) >= 0) return;
      var best = -1, bo = 0;
      groups.forEach(function (g, j) { if (!used[j] && ov(m, j) > bo) { bo = ov(m, j); best = j; } });
      if (best >= 0) pair(m, best, 'overlap');
    });
    var left = mk.filter(function (m) { return m.gid === null && gn.indexOf(m.title) < 0; });
    var leftG = [];
    used.forEach(function (u, j) { if (!u) leftG.push(j); });
    // G2 phase 2 (defect 2): only a group none of whose tasks is listed.
    var listedAny = {};
    sections.forEach(function (s) { s.tasks.forEach(function (id) { listedAny[id] = true; }); });
    var free = function (j) { return !c.tasks.some(function (t) { return t.group === groups[j].id && listedAny[t.id]; }); };
    if (left.length === 1 && leftG.length === 1 && free(leftG[0])) pair(left[0], leftG[0], 'position');
    var taken = {}, cnt = {};
    // Shadow group values are taken too (§6.1 (e), G2 phase 1 review).
    c.tasks.forEach(function (t) { taken[t.id] = true; if (t._x && typeof t._x.group === 'string') taken[t._x.group] = true; });
    groups.forEach(function (g) { taken[g.id] = true; });
    mk.forEach(function (m) {
      if (m.gid !== null) return;
      if (gn.indexOf(m.title) >= 0) { m.kind = 'duplicate'; return; }
      var k = cnt[m.title] || 0;
      cnt[m.title] = k + 1;
      m.gid = B.derivedId('g', 'list:' + m.title + '#' + k, taken);
      m.kind = 'new';
    });
    var gone = {};
    groups.forEach(function (g, j) { if (!used[j]) gone[g.id] = true; });
    // Groups: mapped ones in note order in their slots, new ones after the one above.
    var gl = groups.map(function (g) { return { id: g.id, title: g.title, color: g.color, _x: g._x }; });
    var mapped = mk.filter(function (m) { return m.kind === 'same' || m.kind === 'overlap' || m.kind === 'position'; });
    var slots = [];
    gl.forEach(function (g, k) { if (mapped.some(function (m) { return m.gid === g.id; })) slots.push(k); });
    var byId = {};
    gl.forEach(function (g) { byId[g.id] = g; });
    mapped.forEach(function (m, k) { gl[slots[k]] = byId[m.gid]; });
    var placed = null;
    mk.forEach(function (m) {
      if (m.kind === 'new') {
        var at = 0;
        if (placed !== null) gl.forEach(function (g, k) { if (g.id === placed) at = k + 1; });
        gl.splice(at, 0, { id: m.gid, title: m.title, color: null, _x: {} });
      }
      if (m.kind !== 'duplicate') placed = m.gid;
      if ((m.kind === 'overlap' || m.kind === 'position') && byId[m.gid].title !== m.title) {
        var x = {};
        Object.keys(byId[m.gid]._x || {}).forEach(function (k) { if (k !== 'title') x[k] = byId[m.gid]._x[k]; });
        var ng = { id: m.gid, title: m.title, color: byId[m.gid].color, _x: x };
        gl = gl.map(function (g) { return g.id === m.gid ? ng : g; });
      }
    });
    // Tasks: membership, then per group the listed tasks in note order in their slots.
    var tl = c.tasks.slice(), target = {};
    sections.forEach(function (s, i) {
      var m = i ? mk[i - 1] : null;
      s.tasks.forEach(function (id) {
        if ((m && m.kind === 'duplicate') || (gOf[id] !== null && gone[gOf[id]])) return;
        target[id] = m ? m.gid : null;
      });
    });
    tl = tl.map(function (t) {
      if (!(t.id in target) || t.group === target[t.id]) return t;
      var x = {};
      Object.keys(t._x || {}).forEach(function (k) { if (k !== 'group') x[k] = t._x[k]; });
      return Object.assign({}, t, { group: target[t.id], _x: x });
    });
    sections.forEach(function (s, i) {
      var m = i ? mk[i - 1] : null;
      if (m && m.kind === 'duplicate') return;
      var mine = s.tasks.filter(function (id) { return id in target; }), sl = [], byT = {};
      tl.forEach(function (t, k) { if (mine.indexOf(t.id) >= 0) { sl.push(k); byT[t.id] = t; } });
      mine.forEach(function (id, k) { tl[sl[k]] = byT[id]; });
    });
    return { v: c.v, settings: c.settings, groups: gl, tasks: tl, _x: c._x };
  }

  /*
   * Hand edits (§5.3, §10.1), the fold half: random edits of each §6.3 kind
   * inside a written region; the fold of the edited note equals the
   * oracle's chart; laws (inverse, patch, coerce, idempotent); read, write,
   * read converges in one save with a fold that changes nothing; merge3 of
   * two folds of the same note has no conflict.
   */
  function handEditSpec() {
    var seed = seedOf() + 13, rng = mulberry32(seed), runs = 0, fails = 0, first = '', kinds = {}, stats = { changed: 0, held: 0, newG: 0, renamed: 0, reord: 0, moved: 0 }, originChecked = 0;
    function fail(n, why) { fails++; if (!first) first = 'edit #' + n + ': ' + why; }
    function int(a, b) { return a + Math.floor(rng() * (b - a + 1)); }
    function safeCuts(nl) {
      var out = [], open = null;
      for (var i = 0; i <= nl.length; i++) {
        if (!open) out.push(i);
        if (i === nl.length) break;
        var t = nl[i].text;
        if (open) { if (B.closes(t, open)) open = null; } else { var o = B.opening(t); if (o) open = o; }
      }
      return out;
    }
    // At least 500 edits, then more (up to 2000) until every coverage
    // minimum below is reached, so what the property exercises does not
    // depend on the seed (G2 phase 2 review round 2: the minimums were
    // missed by a few about one run in eight).
    var KINDS = ['move', 'reorder', 'heading', 'rename', 'delete', 'swap', 'foreign', 'plain', 'prose', 'code', 'levelL', 'indent'];
    function covered() {
      return stats.moved > 60 && stats.held > 10 && stats.newG > 20 && stats.renamed > 10 && stats.reord > 30 && originChecked > 300 &&
        KINDS.every(function (k) { return kinds[k] > 5; });
    }
    for (var n = 0; (runs < 500 || (!covered() && runs < 2000)) && n < 20000; n++) {
      var w = writtenNote(rng, n), g = w.g, c = g.c, text = w.text, rd = LR(text), list = rd.list;
      if (!list) { fail(n, 'no list'); continue; }
      var ls = text.split('\n'), hl = list.heading.line, F = ls.indexOf('```synapse-gantt');
      var byLine = {};
      list.rows.forEach(function (x) { byLine[x.line] = x; });
      // Marker metas carry the title as written (the text after the hashes)
      // and the group the writer wrote them for (every group gets one
      // marker, in order), so the oracle takes titles from the edit strings.
      var lines = [], mk = 0;
      for (var k = hl + 1; k < F; k++) {
        var row = byLine[k], meta = { text: ls[k], cls: row.cls, task: row.owned ? row.task : null };
        if (row.cls === 'MARKER') { meta.title = ls[k].slice(g.L + 2); meta.origin = c.groups[mk++].id; }
        lines.push(meta);
      }
      var gset = {};
      c.groups.forEach(function (gg) { gset[B.norm(gg.title) || 'Untitled'] = true; });
      var tasks = lines.filter(function (m) { return m.task; }), markers = lines.filter(function (m) { return m.cls === 'MARKER'; });
      var ops = ['heading', 'prose', 'foreign', 'levelL', 'code'];
      if (tasks.length) ops.push('move', 'move', 'move', 'move', 'plain', 'reorder', 'indent');
      // delete twice: the indent kind (review round 1) shares the runs.
      if (markers.length) ops.push('rename', 'delete', 'delete');
      if (markers.length >= 2) ops.push('swap');
      var op = ops[int(0, ops.length - 1)], nl = lines.slice(), p, cuts = safeCuts(nl);
      function insert(at, metas) { nl.splice.apply(nl, [at, 0].concat(metas)); }
      function pickCut() { return cuts[int(0, cuts.length - 1)]; }
      if (op === 'move' || op === 'reorder') {
        var tm = tasks[int(0, tasks.length - 1)], from = nl.indexOf(tm);
        nl.splice(from, 1);
        var c2 = safeCuts(nl);
        if (op === 'reorder') {
          // Within its own section: just above or below a neighbouring owned line.
          var near = nl.filter(function (m, k) { return m.task && Math.abs(k - from) <= 3; });
          p = near.length ? nl.indexOf(near[int(0, near.length - 1)]) + int(0, 1) : from;
          if (c2.indexOf(p) < 0) p = from;
        } else p = c2[int(0, c2.length - 1)];
        insert(p, [tm]);
      } else if (op === 'heading') {
        var title = ['QA', 'Review', '测试', c.groups.length ? B.htext(c.groups[int(0, c.groups.length - 1)].title) : 'Later'][int(0, 3)];
        insert(pickCut(), [{ text: hashes(g.L + 1) + ' ' + title, cls: 'MARKER', task: null, title: title, origin: null }]);
      } else if (op === 'rename') {
        var mm = markers[int(0, markers.length - 1)], rt = 'Renamed ' + int(0, 3);
        nl[nl.indexOf(mm)] = { text: hashes(g.L + 1) + ' ' + rt, cls: 'MARKER', task: null, title: rt, origin: mm.origin };
      } else if (op === 'delete') {
        nl.splice(nl.indexOf(markers[int(0, markers.length - 1)]), 1);
      } else if (op === 'swap') {
        var mi = int(0, markers.length - 2), a0 = nl.indexOf(markers[mi]), b0 = nl.indexOf(markers[mi + 1]);
        var b1 = mi + 2 < markers.length ? nl.indexOf(markers[mi + 2]) : nl.length;
        nl = nl.slice(0, a0).concat(nl.slice(b0, b1), nl.slice(a0, b0), nl.slice(b1));
      } else if (op === 'foreign') {
        insert(pickCut(), [{ text: '[Vendor](synapseresource://note/zz-' + int(0, 9) + ')', cls: 'LINK', task: null }]);
      } else if (op === 'plain') {
        var pid = tasks[int(0, tasks.length - 1)].task, pt = M.task(c, pid);
        insert(pickCut(), [{ text: '[' + B.ltext(pt.title) + '](synapseresource://note/' + pt.note + ')', cls: 'LINK', task: null }]);
      } else if (op === 'prose') {
        insert(rng() < 0.3 ? nl.length : pickCut(), [{ text: 'Typed by hand ' + n, cls: 'TEXT', task: null }]);
      } else if (op === 'code') {
        insert(pickCut(), ['```', hashes(g.L + 1) + ' not a marker', '```'].map(function (x) { return { text: x, cls: 'CODE', task: null }; }));
      } else if (op === 'levelL') {
        insert(pickCut(), [{ text: hashes(g.L) + ' Group ' + n, cls: 'TEXT', task: null }]);
      } else if (op === 'indent') {
        // A note indented under a task: attached, never a fold.
        var ti = tasks[int(0, tasks.length - 1)];
        insert(nl.indexOf(ti) + 1, [{ text: '  - note ' + n, cls: 'TEXT', task: null }]);
      }
      kinds[op] = (kinds[op] || 0) + 1;
      runs++;
      // The oracle's sections, from the edit's metas.
      var secs = [{ title: null, tasks: [] }];
      nl.forEach(function (m) {
        if (m.cls === 'MARKER') secs.push({ title: m.title, tasks: [] });
        else if (m.task) secs[secs.length - 1].tasks.push(m.task);
      });
      var edited = ls.slice(0, hl + 1).concat(nl.map(function (m) { return m.text; }), ls.slice(F)).join('\n');
      var re = LR(edited);
      if (!re.list || re.list.ambiguous.length) { fail(n, op + ': no list or ambiguous\n' + edited); continue; }
      if (n % 7 === 0) { freeze(re.chart); freeze(re.list); }
      var f;
      try { f = M.applyList(re.chart, re.list); } catch (e) { fail(n, op + ': threw ' + (e && e.stack)); continue; }
      // The mapping from the edit's meaning (independent of the §6.1
      // algorithm): with unique group titles, every marker whose title no
      // other marker shares maps to the group it was written for (a rename
      // keeps it: overlap, or position for an empty group), and a typed one
      // is new.
      var uniq = Object.keys(gset).length === c.groups.length, mcount = {};
      nl.forEach(function (m) { if (m.cls === 'MARKER') mcount[m.title] = (mcount[m.title] || 0) + 1; });
      if (uniq) {
        var mi2 = 0, bad2 = null;
        nl.forEach(function (m) {
          if (m.cls !== 'MARKER') return;
          var sec = re.list.sections[++mi2];
          if (mcount[m.title] !== 1 || (m.origin === null && gset[m.title])) return;
          if (m.origin !== null && (m.title === B.htext(M.group(c, m.origin).title) || !gset[m.title])) {
            originChecked++;
            if (sec.gid !== m.origin) bad2 = m.title + ' maps to ' + sec.gid + ', not ' + m.origin;
          } else if (m.origin === null) {
            originChecked++;
            if (sec.marker.kind !== 'new') bad2 = m.title + ' is ' + sec.marker.kind + ', not new';
          }
        });
        if (bad2) { fail(n, op + ': mapping by meaning: ' + bad2 + '\n' + edited); continue; }
      }
      var want = ser(oracleFold(re.chart, secs));
      if (ser(f.chart) !== want) { fail(n, op + ': fold differs from the oracle\n--- oracle\n' + want + '\n--- fold\n' + ser(f.chart) + '\n--- note\n' + edited); continue; }
      var bad = laws(re.chart, re.list, f);
      if (bad.length) { fail(n, op + ': laws ' + json(bad)); continue; }
      var moved = re.chart.tasks.filter(function (t) { return M.task(f.chart, t.id).group !== t.group; }).map(function (t) { return t.id; });
      if (json(moved.slice().sort()) !== json(f.moves.map(function (m) { return m.id; }).sort())) { fail(n, op + ': moves report ' + json(f.moves) + ' vs ' + json(moved)); continue; }
      var mg = M.merge3(re.chart, f.chart, M.applyList(LR('Other device.\n\n' + edited).chart, LR('Other device.\n\n' + edited).list).chart);
      if (mg.conflicts.length || ser(mg.chart) !== ser(f.chart)) { fail(n, op + ': merge3 of two folds ' + json(mg.conflicts)); continue; }
      // Read, write, read: one save converges and the second fold is empty.
      var s1 = saveWith(edited, re, f.chart), r2 = LR(s1);
      if (!r2.list) { fail(n, op + ': no list after the save\n' + s1); continue; }
      var f2 = M.applyList(r2.chart, r2.list);
      if (f2.changed || ser(r2.chart) !== ser(f.chart)) { fail(n, op + ': second fold ' + json(f2.report) + '\n' + edited + '\n---\n' + s1); continue; }
      if (saveWith(s1, r2, r2.chart) !== s1) { fail(n, op + ': the third text differs from the second\n' + s1); continue; }
      if (f.changed) stats.changed++;
      if (f.report.held.length) stats.held++;
      if (f.newGroups.length) stats.newG++;
      if (f.renames.length) stats.renamed++;
      if (f.report.tasksReordered || f.report.groupsReordered) stats.reord++;
      if (f.moves.length) stats.moved++;
    }
    ok('hand edits: at least 500 folds equal the oracle, obey the laws and converge in one save (seed ' + seed + ')', fails === 0 && runs >= 500,
      runs + ' runs, ' + fails + ' failures; first: ' + first);
    ok('hand edits: every edit kind ran ' + json(kinds), KINDS.every(function (k) { return kinds[k] > 5; }));
    ok('hand edits: markers checked against the edit\'s meaning (' + originChecked + ')', originChecked > 300, String(originChecked));
    ok('hand edits: folds exercised moves, holds, new groups, renames and reorders ' + json(stats),
      stats.moved > 60 && stats.held > 10 && stats.newG > 20 && stats.renamed > 10 && stats.reord > 30);
  }

  function perfSpec() {
    var groups = [], tasks = [], lines = [];
    for (var g = 0; g < 30; g++) groups.push({ id: 'g' + g, title: 'Group ' + g });
    for (var i = 0; i < 300; i++) tasks.push({ id: 't' + i, note: 'n' + i, title: 'Task ' + i, start: '2026-10-01', group: 'g' + (i % 30) });
    var c = chart({ v: 1, settings: { listHeading: 'Tasks' }, groups: groups, tasks: tasks });
    var text = RP(c, {}).text;
    // Every task line moved to the next group's section, groups reversed.
    var parts = text.split('\n\n'), heads = parts.slice(1, 31).map(function (p) { return p.split('\n'); });
    var body = heads.map(function (h, k) { return [h[0]].concat(heads[(k + 1) % 30].slice(1)).join('\n'); }).reverse();
    var edited = [parts[0]].concat(body, parts.slice(31)).join('\n\n');
    function best(fn) { var t = Infinity; for (var k = 0; k < 5; k++) { var s = Date.now(); fn(); t = Math.min(t, Date.now() - s); } return t; }
    var x = fold(edited);
    ok('performance: the edited 300-task note folds every task and group', x.f.moves.length === 300 && x.f.report.groupsReordered);
    var tf = best(function () { var r = LR(edited); M.applyList(r.chart, r.list); });
    ok('performance: read plus fold under 30 ms (' + tf + ' ms)', tf < 30);
  }

  SPEC.suites.push({ name: 'the G2 gorder spec', fn: gorderSpec });
  SPEC.suites.push({ name: 'the G2 moveGroup spec', fn: moveGroupSpec });
  SPEC.suites.push({ name: 'the G2 moveToGroup spec', fn: moveToGroupSpec });
  SPEC.suites.push({ name: 'the G2 fold fixture spec', fn: fixtureSpec });
  SPEC.suites.push({ name: 'the G2 fold synthetic spec', fn: syntheticSpec });
  SPEC.suites.push({ name: 'the G2 merge spec', fn: mergeSpec });
  SPEC.suites.push({ name: 'the G2 written lists property', fn: writtenSpec });
  SPEC.suites.push({ name: 'the G2 hand edits fold property', fn: handEditSpec });
  SPEC.suites.push({ name: 'the G2 fold performance guard', fn: perfSpec });

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
