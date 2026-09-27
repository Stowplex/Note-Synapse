/*
 * node dev/mutants/run.js [name ...] - single-rule mutation check (task-groups
 * plan G4). Each mutant replaces one exact, unique piece of one source file in
 * a scratch copy of contrib/gantt, runs the node suite there (GT_SEED defaults
 * to 7) and counts the failing assertions. A mutant is killed when at least
 * one assertion fails or the suite aborts. The working tree is never touched.
 *
 * Env: GT_SEED (default 7), GT_MUT_DIR (scratch root, default os.tmpdir()),
 * GT_MUT_JOBS (parallel runs, default 4).
 */
var fs = require('fs'), path = require('path'), os = require('os'), cp = require('child_process');
var root = path.join(__dirname, '..', '..');
var R = String.raw;

var MUTANTS = [
  // block.js: the boundary (5.2.2)
  { name: 'B1_heading_any_level', file: 'block.js', rule: 'matchesH: the list heading must be at level L',
    from: 'return hd.level === conf.L && (', to: 'return (' },
  { name: 'B2_no_closing_strip', file: 'block.js', rule: 'matchesH: text matched with the closing sequence stripped',
    from: 'norm(hd.stripped) === want || norm(hd.text) === want', to: 'norm(hd.text) === want' },
  { name: 'B3_indented_heading', file: 'block.js', rule: 'HEAD_RE: at most one leading space',
    from: R`var HEAD_RE = /^ ?(#{1,6})`, to: R`var HEAD_RE = /^ {0,3}(#{1,6})` },
  { name: 'B4_heading_in_code', file: 'block.js', rule: 'findHeading: lines inside other code blocks skipped',
    from: 'for (var k = F - 1; k >= 0; k--) {\n      if (code[k]) continue;', to: 'for (var k = F - 1; k >= 0; k--) {' },
  // block.js: line classes and copies (5.2.3, 5.2.4)
  { name: 'C1_level_L_marker', file: 'block.js', rule: 'parseList: MARKER is level L + 1 only',
    from: "if (hd && hd.level === L + 1) { row.cls = 'MARKER'", to: "if (hd && (hd.level === L + 1 || hd.level === L)) { row.cls = 'MARKER'" },
  { name: 'C2_legacy_any_title', file: 'block.js', rule: "parseList: a LEGACY bold line names a JSON group",
    from: "k + 1 < F && gTitles[norm(b[1]) || 'Untitled'] ? link(k + 1)", to: 'k + 1 < F ? link(k + 1)' },
  { name: 'C3_legacy_any_indent', file: 'block.js', rule: 'parseList: LEGACY needs a sub line indented by exactly two',
    from: 'if (nx && nx.indent === 2 && nx.marked && nx.task)', to: 'if (nx && nx.marked && nx.task)' },
  { name: 'C4_copies_threshold', file: 'block.js', rule: 'copies: two MARKED lines make a task ambiguous',
    from: 'if (c.v.length >= 2 || (c.v.length === 0 && c.p.length >= 2))', to: 'if (c.v.length >= 3 || (c.v.length === 0 && c.p.length >= 2))' },
  { name: 'C5_greedy_link_text', file: 'block.js', rule: 'LINK_RE: link text excludes "]("',
    from: R`\\[((?:(?!\\]\\()[\\s\\S])*)\\]`, to: R`\\[([\\s\\S]*)\\]` },
  // block.js mapMarkers + model.js applyList (§6.1)
  { name: 'A1_dup_becomes_new', file: 'block.js', rule: 'mapMarkers (d): a marker titled like a paired group is a duplicate',
    from: "if (titles[r.title]) { r.kind = 'duplicate'; r.dupOf = groups[gn.indexOf(r.title)].id; return; }", to: '' },
  { name: 'A2_position_untightened', file: 'block.js', rule: 'mapMarkers (c): position pairing only for a group with no listed task',
    from: 'if (left.length === 1 && leftG.length === 1 && unlisted(leftG[0]))', to: 'if (left.length === 1 && leftG.length === 1)' },
  { name: 'A3_gone_not_held', file: 'model.js', rule: 'applyList step 3: tasks of a gone group are held',
    from: "if (sec.kind === 'held' || (t.group !== null && gone[t.group])) {", to: "if (sec.kind === 'held') {" },
  { name: 'A4_new_group_appended', file: 'model.js', rule: 'applyList step 4: a new group goes after the group above it',
    from: 'var at = placed === null ? 0 : indexOf(cur.groups, placed) + 1;', to: 'var at = cur.groups.length;' },
  { name: 'A5_no_rename', file: 'model.js', rule: 'applyList step 2: overlap and position pairs take the marker text',
    from: "sec.rename = (m.kind === 'overlap' || m.kind === 'position') && exists;", to: 'sec.rename = false;' },
  { name: 'A6_no_task_order', file: 'model.js', rule: 'applyList step 4: listed tasks take their slots in note order',
    from: "if (ids.length > 1) run({ op: 'order', ids: ids });", to: '' },
  { name: 'A7_no_group_order', file: 'model.js', rule: 'applyList step 4: mapped groups take their slots in note order',
    from: "run({ op: 'gorder', ids: mapped });", to: '' },
  // layout.js (§8.1, §8.7)
  { name: 'L1_slot_always', file: 'layout.js', rule: 'buildRows: the No-group slot only without a scheduled ungrouped task',
    from: 'if (opts.dragSlot && chart.groups.length && !rows.length) {', to: 'if (opts.dragSlot && chart.groups.length) {' },
  { name: 'L2_band_whole_zone', file: 'layout.js', rule: 'split: the band is the lower half of the zone',
    from: 'return (top + o.thr(h)) / 2;', to: 'return top;' },
  { name: 'L3_count_scheduled_only', file: 'layout.js', rule: 'buildRows: a header counts every member',
    from: 'h: d.grp, n: all.length, un:', to: 'h: d.grp, n: list.length, un:' },
  { name: 'L4_hidden_never', file: 'layout.js', rule: 'hiddenDrop: a drop into a collapsed group is out of sight',
    from: "if (rows[i].kind === 'group' && rows[i].id === group) return !!rows[i].collapsed;", to: "if (rows[i].kind === 'group' && rows[i].id === group) return false;" },
  // store.js: the removal gate and la (§6.2, §6.3)
  { name: 'S1_gate_no_wrotekey', file: 'store.js', rule: 'mirrorGap: the read body key must be the key this store wrote',
    from: 'if (!g || g.missing || g.key !== s.key || g.bodyKey !== s.wroteKey) return null;', to: 'if (!g || g.missing || g.key !== s.key) return null;' },
  { name: 'S2_gate_no_session_key', file: 'store.js', rule: "mirrorGap: the read key must be the session's",
    from: 'if (!g || g.missing || g.key !== s.key || g.bodyKey !== s.wroteKey) return null;', to: 'if (!g || g.missing || g.bodyKey !== s.wroteKey) return null;' },
  { name: 'S3_la_unchecked', file: 'store.js', rule: 'noteFold: the toast shows once per composite key (la)',
    from: '      if (seen === h) return;\n      s.la = h;', to: '      s.la = h;' },
  { name: 'S4_la_kept_on_write', file: 'store.js', rule: 'agree: a write clears la',
    from: "hadLa = !!s.la || (s.la === null && !!(ce && ce.la));\n      s.la = '';", to: 'hadLa = false;' },
  // Equivalent: a fold that changed the chart always reports a move, rename,
  // new group or reorder (each patch applyList runs sets one of them), so
  // this guard is redundant with fold.changed and key !== bodyKey.
  { name: 'S5_toast_empty_report', file: 'store.js', rule: 'noteFold: no toast for a fold with nothing to report', equivalent: true,
    from: '      if (!foldNews(fr.fold.report)) return;\n', to: '' },
  { name: 'S6_la_session_only', file: 'store.js', rule: "noteFold: la is read from the device cache, not only the session",
    from: "seen = s.la !== null ? s.la : (ce && typeof ce.la === 'string' ? ce.la : null)", to: 'seen = s.la' },
  { name: 'S7_toast_in_embed', file: 'store.js', rule: 'noteFold: never in an embed',
    from: "if (L.embed || !fr || fr.status !== 'ok'", to: "if (!fr || fr.status !== 'ok'" },
  { name: 'S8_la_not_cached_on_reload', file: 'store.js', rule: 'silentReload: a toast shown writes la to the cache',
    from: '      if (s.la !== la) cachePut(s);', to: '' }
];

function copyDir(src, dst) {
  fs.mkdirSync(dst, { recursive: true });
  fs.readdirSync(src, { withFileTypes: true }).forEach(function (e) {
    if (e.name === 'mutants' || e.name === 'node_modules') return;
    var a = path.join(src, e.name), b = path.join(dst, e.name);
    if (e.isDirectory()) copyDir(a, b); else fs.copyFileSync(a, b);
  });
}

function count(hay, needle) { var n = 0, i = 0; while ((i = hay.indexOf(needle, i)) >= 0) { n++; i += needle.length; } return n; }

var want = process.argv.slice(2);
var list = MUTANTS.filter(function (m) { return !want.length || want.indexOf(m.name) >= 0; });
var seed = process.env.GT_SEED || '7';
var jobs = +(process.env.GT_MUT_JOBS || 4);
var scratch = fs.mkdtempSync(path.join(process.env.GT_MUT_DIR || os.tmpdir(), 'gt-mut-'));

function prepare(m) {
  var dir = path.join(scratch, m.name);
  copyDir(path.join(root, 'plugins'), path.join(dir, 'plugins'));
  copyDir(path.join(root, 'dev'), path.join(dir, 'dev'));
  var f = path.join(dir, 'plugins', 'src', m.file), src = fs.readFileSync(f, 'utf8');
  var n = count(src, m.from);
  if (n !== 1) return { dir: dir, error: 'anchor found ' + n + ' times' };
  fs.writeFileSync(f, src.replace(m.from, function () { return m.to; }), 'utf8');
  return { dir: dir };
}

function runOne(m, done) {
  var p = prepare(m);
  if (p.error) return done({ m: m, error: p.error });
  var env = Object.assign({}, process.env, { GT_SEED: seed });
  cp.execFile(process.execPath, [path.join(p.dir, 'dev', 'run.js')], { env: env, maxBuffer: 64 << 20, timeout: 600000 }, function (err, out, errOut) {
    out = String(out || '');
    var fails = out.split('\n').filter(function (l) { return /^FAIL {2}/.test(l); }).map(function (l) { return l.slice(6); });
    var tot = /(\d+)\/(\d+) assertions passed/.exec(out);
    var aborted = !tot;
    done({ m: m, fails: fails, aborted: aborted, total: tot ? tot[2] : '?', tail: aborted ? String(errOut || out).split('\n').slice(-4).join(' | ') : '' });
  });
}

var queue = list.slice(), results = [], running = 0;
function next() {
  while (running < jobs && queue.length) {
    running++;
    runOne(queue.shift(), function (r) {
      results.push(r);
      running--;
      var m = r.m;
      if (r.error) console.log('ERROR    ' + m.name + ': ' + r.error);
      else if (m.equivalent && !r.fails.length && !r.aborted) console.log('equiv    ' + m.name + ' (' + m.file + ': ' + m.rule + '): survives, as expected');
      else if (r.fails.length || r.aborted) console.log('killed   ' + m.name + ' (' + m.file + ': ' + m.rule + '): ' + (r.aborted ? 'suite aborted ' + r.tail : r.fails.length + ' failures, e.g. ' + r.fails[0]));
      else console.log('SURVIVED ' + m.name + ' (' + m.file + ': ' + m.rule + ')');
      if (!queue.length && !running) finish(); else next();
    });
  }
}
function finish() {
  var real = results.filter(function (r) { return !r.m.equivalent; });
  var killed = real.filter(function (r) { return !r.error && (r.fails.length || r.aborted); }).length;
  console.log('\n' + killed + '/' + real.length + ' mutants killed, ' + (results.length - real.length) + ' equivalent not counted (GT_SEED=' + seed + ', scratch ' + scratch + ')');
  process.exitCode = killed === real.length ? 0 : 1;
}
next();
