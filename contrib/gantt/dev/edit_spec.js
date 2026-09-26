/*
 * Gantt editing (M6, plan §13.2 to §13.4): layout.reorderTarget, drag
 * snapping (app.dragDates: scale.snapDelta plus dates.snap on workdays),
 * the sheet's pure helpers (side panel rule, keyboard height, detents),
 * and zh-CN entries for the strings app.js builds from tables. Runs under
 * node (dev/run.js) and in the browser (dev/auto_smoke.html).
 */
(function (global) {
  'use strict';
  var GT = global.GT, SPEC = GT.spec;
  var A = SPEC.api, ok = A.ok, eq = A.eq;
  var LY = GT.layout, M = GT.model, D = GT.dates, SH = GT.sheet, I = GT.i18n;

  // u1 ungrouped; g1: a1 a2; g2: b1 b2; g3 empty; x1 x2 unscheduled (x2 in g1).
  function chart() {
    var d = function (s) { return s; };
    return M.coerce({
      v: 1,
      groups: [{ id: 'g1', title: 'Discovery' }, { id: 'g2', title: 'Build' }, { id: 'g3', title: 'Later' }],
      tasks: [
        { id: 'u1', note: 'n-u1', title: 'U1', start: d('2026-10-01'), end: '2026-10-03' },
        { id: 'a1', note: 'n-a1', title: 'A1', start: '2026-10-02', end: '2026-10-05', group: 'g1' },
        { id: 'x1', note: 'n-x1', title: 'X1' },
        { id: 'a2', note: 'n-a2', title: 'A2', start: '2026-10-06', end: '2026-10-09', group: 'g1' },
        { id: 'b1', note: 'n-b1', title: 'B1', start: '2026-10-07', end: '2026-10-12', group: 'g2' },
        { id: 'b2', note: 'n-b2', title: 'B2', start: '2026-10-11', group: 'g2', milestone: true },
        { id: 'x2', note: 'n-x2', title: 'X2', group: 'g1' }
      ]
    }).chart;
  }
  function order(c) { return c.tasks.map(function (t) { return t.id + (t.group ? '/' + t.group : ''); }).join(' '); }
  function rowsOf(c, collapsed) { return LY.buildRows(c, collapsed || [], 'comfortable').rows; }
  function rowIdx(rows, id) { for (var i = 0; i < rows.length; i++) if (rows[i].id === id) return i; return -1; }
  function mid(rows, id) { var r = rows[rowIdx(rows, id)]; return r.y + r.h / 2; }
  // Drop task `id` so its centre sits just below (after=true) or above row `at`.
  function dropAt(c, rows, id, at, after) {
    var from = rowIdx(rows, id), k = rowIdx(rows, at), r = rows[k], hd = rows[from].h;
    var y0 = k > from ? r.y - hd : r.y;
    var y = after ? y0 + (r.h + hd) / 2 + 1 : y0 + (r.h + hd) / 2 - 1;
    return LY.reorderTarget(rows, c, id, y);
  }
  function apply(c, id, t) { return M.reorder(c, id, t.index, t.group).chart; }

  function reorderSpec() {
    var c = chart(), rows = rowsOf(c);
    eq('rows (D15 order)', rows.map(function (r) { return r.id; }).join(' '), 'u1 g1 a1 a2 g2 b1 b2 g3 ~unscheduled x1 x2');
    var t0 = LY.reorderTarget(rows, c, 'a2', mid(rows, 'a2'));
    ok('dropping in place changes nothing', t0 && !t0.changed && t0.lo > t0.hi, JSON.stringify(t0));
    eq('unknown id: null', LY.reorderTarget(rows, c, 'nope', 10), null);

    // Within a group: a2 above a1.
    var t1 = dropAt(c, rows, 'a2', 'a1', false);
    eq('a2 above a1: same group', t1.group, 'g1');
    eq('a2 above a1: order', order(apply(c, 'a2', t1)), 'u1 a2/g1 a1/g1 x1 b1/g2 b2/g2 x2/g1');
    eq('a2 above a1: a1 shifts down by the row height', [t1.lo, t1.hi, t1.dir].join(','), [rowIdx(rows, 'a1'), rowIdx(rows, 'a1'), 1].join(','));
    ok('a2 above a1: changed', t1.changed);

    // Across groups: a1 after b1 joins g2.
    var t2 = dropAt(c, rows, 'a1', 'b1', true);
    eq('a1 after b1 joins Build', t2.group, 'g2');
    eq('a1 after b1: order', order(apply(c, 'a1', t2)), 'u1 x1 a2/g1 b1/g2 a1/g2 b2/g2 x2/g1');
    eq('a1 after b1: rows a2..b1 shift up', [t2.lo, t2.hi, t2.dir].join(','), [rowIdx(rows, 'a1') + 1, rowIdx(rows, 'b1'), -1].join(','));
    var shown = rowsOf(apply(c, 'a1', t2)).map(function (r) { return r.id; }).join(' ');
    eq('a1 after b1: the new rows put it under b1', shown, 'u1 g1 a2 g2 b1 a1 b2 g3 ~unscheduled x1 x2');

    // Just under a group header: first in that group.
    var t3 = dropAt(c, rows, 'b2', 'g1', true);
    eq('b2 under the Discovery header joins g1', t3.group, 'g1');
    eq('b2 under the Discovery header is its first row', rowsOf(apply(c, 'b2', t3)).map(function (r) { return r.id; }).join(' '), 'u1 g1 b2 a1 a2 g2 b1 g3 ~unscheduled x1 x2');
    // Into an empty group.
    var t4 = dropAt(c, rows, 'a1', 'g3', true);
    eq('a1 under the empty Later header joins g3', t4.group, 'g3');
    ok('a1 into g3 renders under Later', /g3 a1 ~unscheduled/.test(rowsOf(apply(c, 'a1', t4)).map(function (r) { return r.id; }).join(' ')));
    // To the top: ungrouped.
    var t5 = LY.reorderTarget(rows, c, 'b1', -50);
    eq('b1 at the very top is ungrouped, first', [t5.group, t5.index].join(','), ',0');
    eq('b1 at the top: rows', rowsOf(apply(c, 'b1', t5)).map(function (r) { return r.id; }).join(' ').slice(0, 5), 'b1 u1');
    // An ungrouped task after an ungrouped one stays ungrouped (no group write).
    var t6 = dropAt(c, rows, 'a1', 'u1', true);
    eq('a1 right after u1 becomes ungrouped', t6.group, null);
    var t6b = LY.reorderTarget(rows, c, 'u1', mid(rows, 'u1') + 5);
    ok('u1 nudged in place: nothing changes, and a group-less task is not rewritten', t6b.group === undefined && !t6b.changed, JSON.stringify(t6b));
    var t6c = LY.reorderTarget(rows, c, 'a2', mid(rows, 'a2') + 10);
    var t6d = LY.reorderTarget(rows, c, 'a2', mid(rows, 'a2') + 20);
    eq('a2 20 px down (its bottom past the Build header middle) joins Build first', [t6d.group, t6d.changed].join(','), 'g2,true');
    ok('a2 nudged 10 px down (its bottom short of the header middle) stays put', !t6c.changed, JSON.stringify(t6c));

    // Scheduled tasks stay above the Unscheduled group.
    var t7 = LY.reorderTarget(rows, c, 'a1', 99999);
    ok('a scheduled task dragged to the bottom lands before Unscheduled', t7.group === 'g3' && rowsOf(apply(c, 'a1', t7)).map(function (r) { return r.id; }).join(' ').indexOf('a1 ~unscheduled') > 0, JSON.stringify(t7));
    // Unscheduled tasks stay inside Unscheduled, groups unchanged.
    var t8 = dropAt(c, rows, 'x2', 'x1', false);
    eq('x2 above x1: group left alone', t8.group, undefined);
    eq('x2 above x1: order', order(apply(c, 'x2', t8)).split(' ').filter(function (s) { return s[0] === 'x'; }).join(' '), 'x2/g1 x1');
    var t9 = LY.reorderTarget(rows, c, 'x1', -100);
    ok('an unscheduled task never goes above the Unscheduled header', t9.lo >= rowIdx(rows, '~unscheduled') + 1 || !t9.changed, JSON.stringify(t9));

    // Collapsed group: its header is a target, the hidden rows are not.
    var rc = rowsOf(c, ['g1']);
    var t10 = dropAt(c, rc, 'b1', 'g1', true);
    eq('under a collapsed header: joins it, first', [t10.group, t10.index].join(','), 'g1,' + c.tasks.filter(function (t) { return t.id !== 'b1'; }).map(function (t) { return t.id; }).indexOf('a1'));
    // Crossing into a group moves the dragged row by one slot per row passed.
    var t11 = dropAt(c, rows, 'u1', 'a1', true);
    eq('u1 past a1 joins g1 after a1', [t11.group, order(apply(c, 'u1', t11)).split(' ').slice(0, 2).join(' ')].join('|'), 'g1|a1/g1 u1/g1');
    var ra = rows[rowIdx(rows, 'a1')];
    eq('insertion line y is the bottom of a1 without the dragged row', t11.y, ra.y - rows[0].h + ra.h);
  }

  function snapSpec() {
    var set = M.empty().settings;                 // Mon to Fri
    var P = D.parse;
    var task = { start: P('2026-10-05'), end: P('2026-10-09'), milestone: false };   // Mon..Fri
    var r = GT.app.dragDates('move', task, 3 * 16 + 5, 16, set);
    eq('week tier: 3.3 days snaps to +3 (Thu)', [D.format(r.start), D.format(r.end), r.delta].join(' '), '2026-10-08 2026-10-12 3');
    var r2 = GT.app.dragDates('move', task, 5 * 16, 16, set);
    eq('a move onto Saturday snaps forward to Monday (dates.snap)', [D.format(r2.start), r2.delta].join(' '), '2026-10-12 7');
    var r3 = GT.app.dragDates('move', task, -2 * 16, 16, set);
    eq('a move back onto Saturday snaps back to Friday', [D.format(r3.start), r3.delta].join(' '), '2026-10-02 -3');
    var r4 = GT.app.dragDates('move', task, 4 * 16, 16, set);
    eq('Friday is a workday: no extra snap', r4.delta, 4);
    var wk = { start: P('2026-10-10'), end: P('2026-10-11'), milestone: false };     // a weekend task
    eq('a task that starts on a weekend moves by the plain delta', GT.app.dragDates('move', wk, 16, 16, set).delta, 1);
    var hol = M.setSettings(M.empty(), { holidays: [P('2026-10-08')] }).chart.settings;
    eq('a holiday is skipped like a weekend', D.format(GT.app.dragDates('move', task, 3 * 16, 16, hol).start), '2026-10-09');
    // Month tier snaps by 7 days and keeps the weekday; no workday snap.
    var r5 = GT.app.dragDates('move', task, 12 * 5, 5, set);
    eq('month tier: 12 days snaps to +14 (7-day steps)', r5.delta, 14);
    eq('... and keeps the weekday', D.dow(r5.start), D.dow(task.start));
    eq('small moves snap to zero', GT.app.dragDates('move', task, 7, 16, set).delta, 0);
    ok('snapping is symmetric', GT.app.dragDates('move', task, -3 * 16 - 5, 16, set).delta === -3);
    // Resize.
    var e1 = GT.app.dragDates('end', task, 16 * 3, 16, set);
    eq('resize end +3 lands on Monday (Sat and Sun skipped)', [D.format(e1.end), e1.delta].join(' '), '2026-10-12 3');
    var e2 = GT.app.dragDates('end', task, -16 * 20, 16, set);
    eq('resize end never before the start: a one-day task', D.format(e2.start) + ' ' + e2.end, '2026-10-05 null');
    var s1 = GT.app.dragDates('start', task, -16, 16, set);
    eq('resize start -1 onto Sunday snaps back to Friday', D.format(s1.start), '2026-10-02');
    var s2 = GT.app.dragDates('start', task, 16 * 30, 16, set);
    eq('resize start never after the end', D.format(s2.start) + ' ' + s2.end, '2026-10-09 null');
    var one = { start: P('2026-10-06'), end: null, milestone: false };
    eq('a one-day task moves as a one-day task', GT.app.dragDates('move', one, 16, 16, set).end, null);
    var ms = { start: P('2026-10-06'), end: null, milestone: true };
    eq('a milestone moves its start only', [GT.app.dragDates('move', ms, 16, 16, set).delta, GT.app.dragDates('move', ms, 16, 16, set).end].join(','), '1,');
    // The commits the drags make are the model transforms.
    var c = chart();
    var mv = M.moveTask(c, 'a1', 3);
    ok('the MOVE commit has an inverse that restores the chart', M.same(M.applyPatch(mv.chart, mv.inverse).chart, c));
    var rz = M.resizeTask(c, 'a1', 'end', P('2026-10-20'));
    ok('the RESIZE commit has an inverse that restores the chart', M.same(M.applyPatch(rz.chart, rz.inverse).chart, c));
  }

  function sheetSpec() {
    ok('portrait phone: bottom sheet', !SH.sideOf(390, 844));
    ok('landscape phone 844x390: side panel', SH.sideOf(844, 390));
    ok('landscape narrower than 640: bottom sheet', !SH.sideOf(600, 360));
    ok('tablet portrait 820x1180: side panel', SH.sideOf(820, 1180));
    eq('no visualViewport: no keyboard', SH.kbOf(800, null), 0);
    eq('keyboard height from visualViewport', SH.kbOf(800, { height: 480, offsetTop: 0 }), 320);
    eq('scrolled visual viewport', SH.kbOf(800, { height: 480, offsetTop: 20 }), 300);
    eq('never negative', SH.kbOf(800, { height: 900, offsetTop: 0 }), 0);
    eq('grab up: FULL', SH.nextDetent('peek', -60), 'full');
    eq('grab down from FULL: PEEK', SH.nextDetent('full', 60), 'peek');
    eq('grab down from PEEK: closed', SH.nextDetent('peek', 60), null);
    eq('a short grab drag stays', SH.nextDetent('peek', 10), 'peek');
    eq('scrim tap at FULL: PEEK', SH.scrimTap('full'), 'peek');
    eq('field below the view scrolls it up', SH.scrollFor(500, 40, 0, 300), 248);
    eq('field in view: no scroll', SH.scrollFor(100, 40, 0, 300), 0);
    eq('field above the view', SH.scrollFor(20, 40, 100, 300), 12);
    // Review round 1: date inputs never swap and ignore a cleared field.
    var vm = { start: 100, end: 104, milestone: false };
    eq('datesFor: a cleared field is ignored', SH.datesFor('start', vm, null), null);
    eq('datesFor: a cleared end is ignored', SH.datesFor('end', vm, null), null);
    eq('datesFor: a start inside the range keeps the end', JSON.stringify(SH.datesFor('start', vm, 102)), '{"start":102,"end":104}');
    eq('datesFor: a start past the end moves the end with it (duration kept)', JSON.stringify(SH.datesFor('start', vm, 110)), '{"start":110,"end":114}');
    eq('datesFor: an end before the start clamps to a one-day task', JSON.stringify(SH.datesFor('end', vm, 90)), '{"start":100,"end":100}');
    eq('datesFor: an end of an unscheduled task schedules one day', JSON.stringify(SH.datesFor('end', { start: null, end: null }, 50)), '{"start":50,"end":50}');
    eq('datesFor: a milestone takes the start only', JSON.stringify(SH.datesFor('start', { start: 5, end: null, milestone: true }, 9)), '{"start":9,"end":null}');
    eq('sideAfter: a height-only change (the keyboard) never flips', SH.sideAfter(false, 700, 700, 400), false);
    eq('sideAfter: a width change re-decides', SH.sideAfter(false, 390, 844, 390), true);
    ok('sheet.js holds no palette list of its own', !SH.COLORS);
    var src = global.GT_SOURCES && global.GT_SOURCES['sheet.js'];
    if (src) {
      var code = src.replace(/\/\*[\s\S]*?\*\/|\/\/.*$/gm, '');
      ok('sheet.js has the §4.2 surface', ['init', 'openTask', 'openMenu', 'openForm', 'update', 'close', 'isOpen', 'detent'].every(function (f) { return new RegExp('SH\\.' + f + ' = ').test(code); }));
      ok('sheet.js writes note text with textContent only (innerHTML only for the constant icon)', (code.match(/innerHTML/g) || []).length === 1 && /innerHTML = '<svg/.test(code));
      ok('sheet.js never reads the model or the store', !/GT\.(model|store|host|render)\b/.test(code));
      ok('sheet.js avoids scrollIntoView (§13.4)', !/scrollIntoView/.test(code));
    }
  }

  function i18nSpec() {
    var saved = I.language;
    I.setLanguage('zh-CN');
    var miss = [];
    function chk(s) { if (I.text(s) === s) miss.push(s); }
    Object.keys(GT.app.PILL).forEach(function (k) { chk(GT.app.PILL[k]); });
    Object.keys(GT.app.FIELD).forEach(function (k) { chk(GT.app.FIELD[k]); });
    Object.keys(SH.COLOR_NAMES).forEach(function (k) { chk(SH.COLOR_NAMES[k]); });
    ['Undo', 'Redo', 'Move', 'Resize', 'Reorder', 'Change dates', 'Milestone', 'Colour', 'Rename', 'Add milestone',
      'Couldn’t undo: not approved', 'Couldn’t undo: the note changed', 'Repair this chart?', 'Use the first chart block?',
      'Repair replaces the text below with an empty chart. The rest of the note is kept.',
      'The first chart block is saved in place. The other block stays in the note as text.'].forEach(chk);
    eq('every M6 string built from a table has a zh-CN entry', miss.join('\n'), '');
    // §9.1.3: the notice names the host's labels exactly.
    var zh = GT.app.noticeText();
    ok('zh notice names 在本次会话中允许 and 允许', zh.indexOf('“在本次会话中允许”') >= 0 && zh.indexOf('再点“允许”') >= 0, zh);
    eq('zh undo label', I.fmt('Undo: {action} “{title}”', { action: 'Move', title: 'X' }), '撤销：移动“X”');
    eq('zh redo label', I.fmt('Redo: {action} “{title}”', { action: 'Reorder', title: 'X' }), '重做：调整顺序“X”');
    I.setLanguage('en-US');
    eq('en notice, exact §9.1.3 wording', GT.app.noticeText(), 'Note Synapse asks before an app edits a note. Tick \'Allow for this session\', then Approve, so the chart can save as you work.');
    eq('en undo label', I.fmt('Undo: {action} “{title}”', { action: 'Move', title: 'Sync engine' }), 'Undo: Move “Sync engine”');
    eq('duration', I.fmt('Duration: {n} day(s)', { n: 1 }) + ' / ' + I.fmt('Duration: {n} day(s)', { n: 5 }), 'Duration: 1 day / Duration: 5 days');
    I.setLanguage(saved);
  }

  SPEC.suites.push({ name: 'the reorder target spec (M6)', fn: reorderSpec });
  SPEC.suites.push({ name: 'the drag snapping spec (M6)', fn: snapSpec });
  SPEC.suites.push({ name: 'the sheet helpers spec (M6)', fn: sheetSpec });
  SPEC.suites.push({ name: 'the M6 i18n spec', fn: i18nSpec });
  // M7: strings app.js and sheet.js build indirectly (ternaries, undo
  // actions), the subnote explanation, and the zh-CN section default.
  function m7I18nSpec() {
    var saved = I.language;
    I.setLanguage('zh-CN');
    var miss = [];
    function chk(s) { if (I.text(s) === s) miss.push(s); }
    ['Add notes', 'Create task note', 'Remove', 'Toggle item', 'Loading…', 'Couldn’t load the items.',
      'The note picker is not available here.', 'The note picker could not be opened.',
      'Not changed: not approved', 'Couldn’t change it: the note changed',
      'Sub-notes, one per line', 'Checklist items, one per line', 'The task note could not be created.',
      'This chart can’t be edited right now.', 'Tap again to remove', 'Remove from chart', 'Checklist', 'Sub-notes',
      'Whole note', 'This note is too large to list here. Open the note to tick its items.'].forEach(chk);
    eq('every M7 string built indirectly has a zh-CN entry', miss.join('\n'), '');
    eq('zh undo label for a toggle', I.fmt('Undo: {action} “{title}”', { action: 'Toggle item', title: 'X' }), '撤销：切换子项“X”');
    var zh = I.fmt(GT.app.SUB_NOTICE, { allow: I.text('Allow for this session') });
    ok('zh subnote explanation names 在本次会话中允许', zh.indexOf('“在本次会话中允许”') >= 0 && zh !== GT.app.SUB_NOTICE, zh);
    eq('zh counted strings', I.fmt('Import {n} linked note(s) as tasks', { n: 3 }) + '|' + I.fmt('Dates not written to {n} task note(s)', { n: 1 }), '将 3 条链接的笔记导入为任务|有 1 条任务笔记未写入日期');
    eq('a new zh-CN chart gets the section 清单 (D14, §15.1)', GT.md.defaultSection('zh-CN'), '清单');
    I.setLanguage('en-US');
    eq('en plurals', I.fmt('Import {n} linked note(s) as tasks', { n: 1 }) + '|' + I.fmt('Dates not written to {n} task note(s)', { n: 2 }), 'Import 1 linked note as tasks|Dates not written to 2 task notes');
    ok('en subnote explanation names Allow for this session', I.fmt(GT.app.SUB_NOTICE, { allow: 'Allow for this session' }).indexOf("'Allow for this session'") > 0);
    eq('an en-US chart gets Checklist', GT.md.defaultSection('en-US'), 'Checklist');
    I.setLanguage(saved);
  }
  SPEC.suites.push({ name: 'the M7 i18n spec', fn: m7I18nSpec });

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
