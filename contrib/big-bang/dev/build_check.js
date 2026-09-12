/*
 * node dev/build_check.js - assert the INSTALLABLE apps, which are the only
 * part of this plugin a user ever sees.
 *
 * plugins/build.sh emits two YAMLs from one HTML, and until this existed
 * nothing tested either of them: a milestone could ship a perfect suite
 * against src/*.js and an installable app that was three milestones old, or
 * that fetched a file the host does not have, or that did not parse at all.
 *
 * What is asserted, and why each one is a real failure mode:
 *
 *   The YAML parses, as a mapping of plain top-level keys. "Big Bang: this
 *   note" carries a colon, which is a mapping indicator in a plain scalar and
 *   makes the whole file unparseable - build.sh quotes the names for exactly
 *   this reason, and this is what proves it worked. There is no YAML parser in
 *   this repo's node, so the reader below accepts only the shape build.sh
 *   emits and REFUSES anything it does not fully understand, which is the
 *   right way round: a file it cannot read is a failure, not a pass.
 *
 *   The base64 `code` round-trips to the HTML that would be built from the
 *   sources as they stand right now. That is one assertion covering two
 *   things: the YAML is not stale, and the inlining really produced the file
 *   the browser suites have been testing.
 *
 *   The emitted HTML loads NOTHING from outside itself. An installed app is a
 *   row in a table; a <script src> in it is a blank screen on a phone.
 */
var fs = require('fs');
var path = require('path');

var root = path.join(__dirname, '..', 'plugins');
var results = [];
function ok(name, cond, detail) { results.push({ name: name, pass: !!cond, detail: cond ? '' : (detail || '') }); }
function eq(name, a, b) { ok(name, a === b, a === b ? '' : 'expected ' + JSON.stringify(b) + ', got ' + JSON.stringify(a)); }

/* ------------------------------------------------- the HTML build.sh makes */

// The same inlining, written independently of the shell that does it: this
// has to be able to disagree with build.sh, or it is asserting nothing.
var MODULES = ['i18n', 'board', 'model', 'host', 'notes', 'render', 'gestures', 'ai', 'export', 'app'];
// The one line each module has and no other file does.
var MARKER = {
  i18n: 'BB.i18n =',
  board: '(BB.board = {})',
  model: '(BB.model = {})',
  host: '(BB.host = {})',
  notes: '(BB.notes = {})',
  render: '(BB.render = {})',
  gestures: '(BB.gestures = {})',
  ai: '(BB.ai = {})',
  export: '(BB.export = {})',
  app: '(BB.app = {})'
};
function buildHtml() {
  var src = fs.readFileSync(path.join(root, 'big-bang.html'), 'utf8');
  var out = [];
  src.split('\n').forEach(function (line, i, all) {
    if (i === all.length - 1 && line === '') return;      // the file's own last newline
    var hit = null;
    MODULES.forEach(function (m) {
      if (line.indexOf('<script src="src/' + m + '.js"></script>') >= 0) hit = m;
    });
    if (!hit) { out.push(line); return; }
    var js = fs.readFileSync(path.join(root, 'src', hit + '.js'), 'utf8').replace(/<\/script>/g, '<\\/script>');
    out.push('  <script>');
    out.push(js);
    out.push('  </script>');
  });
  return out.join('\n') + '\n';
}

/* ------------------------------------------------------- a strict YAML read */

/*
 * The subset build.sh emits: top-level `key: value` lines, values either a
 * double-quoted scalar or a plain one with no colon-space in it. Anything
 * else - indentation, a list, a block scalar, a duplicate key, a plain value
 * that WOULD be re-read as a nested mapping - is refused rather than guessed
 * at, because the guess is exactly the bug this is looking for.
 */
function readYaml(text) {
  var map = Object.create(null), order = [];
  var lines = String(text).split('\n');
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (i === lines.length - 1 && line === '') continue;
    if (!line.length) throw new Error('line ' + (i + 1) + ' is blank');
    if (line === 'i18n:') {
      if (Object.prototype.hasOwnProperty.call(map, 'i18n')) throw new Error('duplicate key i18n');
      var locale = /^  ([A-Za-z]{2}(?:-[A-Za-z]{2})?):$/.exec(lines[++i] || '');
      var localName = /^    name: "(.*)"$/.exec(lines[++i] || '');
      var localDescription = /^    description: "(.*)"$/.exec(lines[++i] || '');
      if (!locale || !localName || !localDescription) throw new Error('i18n is not the expected locale mapping');
      map.i18n = {};
      map.i18n[locale[1]] = {
        name: JSON.parse('"' + localName[1] + '"'),
        description: JSON.parse('"' + localDescription[1] + '"')
      };
      order.push('i18n');
      continue;
    }
    if (/^\s/.test(line)) throw new Error('line ' + (i + 1) + ' is indented, so it is not a top-level key');
    var m = /^([A-Za-z_][A-Za-z0-9_]*):[ ](.*)$/.exec(line);
    if (!m) throw new Error('line ' + (i + 1) + ' is not `key: value`: ' + JSON.stringify(line.slice(0, 40)));
    var key = m[1], raw = m[2];
    if (Object.prototype.hasOwnProperty.call(map, key)) throw new Error('duplicate key ' + key);
    var value;
    if (raw.charAt(0) === '"') {
      if (raw.charAt(raw.length - 1) !== '"' || raw.length < 2) throw new Error(key + ' is not a closed quoted scalar');
      value = JSON.parse(raw);
    } else {
      if (/:\s/.test(raw)) throw new Error(key + ' is a plain scalar holding a mapping indicator: ' + JSON.stringify(raw.slice(0, 40)));
      if (/^[-?&*!|>%@`{}[]/.test(raw)) throw new Error(key + ' is a plain scalar starting with an indicator character');
      value = raw;
    }
    map[key] = value;
    order.push(key);
  }
  return { map: map, keys: order };
}

/* ------------------------------------------------------------------- check */

var expected;
try {
  expected = buildHtml();
  ok('the sources inline into one HTML', expected.length > 10000, expected.length + ' bytes');
} catch (e) {
  ok('the sources inline into one HTML', false, String(e && e.message));
  expected = null;
}

var APPS = [
  { file: 'Big_Bang.yaml', name: 'Big Bang', type: 'normal', uuid: '9f6001dd-661d-4aa7-ba18-c54164b94338' },
  { file: 'Big_Bang_This_Note.yaml', name: 'Big Bang: this note', type: 'note_action', uuid: '51c3806d-b1e4-4fd4-b1ac-bb58124afef7' }
];

var codes = [];
APPS.forEach(function (app) {
  var text = '';
  try { text = fs.readFileSync(path.join(root, app.file), 'utf8'); }
  catch (e) { ok(app.file + ' was built', false, String(e && e.message)); return; }
  ok(app.file + ' was built', text.length > 1000, text.length + ' bytes');

  var y = null;
  try { y = readYaml(text); }
  catch (e) { ok(app.file + ' parses as YAML', false, String(e && e.message)); return; }
  ok(app.file + ' parses as YAML', true);
  eq(app.file + ' has exactly the keys the host reads',
    y.keys.join(','), 'name,uuid,app_type,description,i18n,author,license,code');

  eq(app.file + ' is named for what it is', y.map.name, app.name);
  eq(app.file + ' declares its launch type', y.map.app_type, app.type);
  eq(app.file + ' keeps its uuid', y.map.uuid, app.uuid);
  eq(app.file + ' is attributed', y.map.author, 'Bruce Li');
  eq(app.file + ' is licensed', y.map.license, 'Apache-2.0');
  ok(app.file + ' carries a Simplified Chinese name',
    !!(y.map.i18n && y.map.i18n['zh-CN'] && y.map.i18n['zh-CN'].name));
  ok(app.file + ' says what the app does', /board/i.test(y.map.description) && y.map.description.length > 120,
    y.map.description);
  ok(app.file + ' describes it in prose, not as its own name', y.map.description !== y.map.name);

  var html = '';
  try { html = Buffer.from(y.map.code, 'base64').toString('utf8'); }
  catch (e) { ok(app.file + ' carries decodable base64', false, String(e && e.message)); return; }
  ok(app.file + ' carries decodable base64', html.length > 10000, html.length + ' bytes');
  codes.push(y.map.code);

  ok(app.file + ' round-trips to the HTML the sources build right now', html === expected,
    'the YAML is ' + html.length + ' bytes, the sources build ' + (expected || '').length +
    ' - run plugins/build.sh');
  ok(app.file + ' is a document, from the first byte', /^<!doctype html>/i.test(html), html.slice(0, 40));
  ok(app.file + ' loads no external script',
    !/<script[^>]+\bsrc\s*=/i.test(html), (/<script[^>]+src[^>]*>/i.exec(html) || [''])[0]);
  ok(app.file + ' pulls in no stylesheet either', !/<link[^>]+stylesheet/i.test(html));
  ok(app.file + ' has no src="src/ left in it', html.indexOf('src="src/') < 0);
  ok(app.file + ' boots the app', html.indexOf('BB.app.boot()') >= 0);
  // Every module, by the one line only that module has: the assignment that
  // puts it on the BB namespace. Anything less specific ("BB.host appears
  // somewhere") is satisfied by the file that CALLS it.
  MODULES.forEach(function (m) {
    ok(app.file + ' carries src/' + m + '.js', html.indexOf(MARKER[m]) >= 0, MARKER[m]);
  });
  /*
   * Every literal </script> in the sources has to have been escaped on the way
   * in, or the page ends early and everything after it is body text.
   *
   * The count on its own is not enough, and for most of this plugin's life it
   * was not even a test: while no source file held a literal </script>, the
   * two numbers agreed whether build.sh escaped anything or not, and deleting
   * the sed from build.sh changed nothing here. So the sources are asked FIRST
   * whether they still contain one - a guard that has quietly become vacuous
   * is worse than no guard, because the report says it passed - and then the
   * built HTML is asked whether the escaped form is what came out.
   */
  var literals = MODULES.reduce(function (n, m) {
    var js = fs.readFileSync(path.join(root, 'src', m + '.js'), 'utf8');
    return n + (js.match(/<\/script>/g) || []).length;
  }, 0);
  ok(app.file + ': the sources still hold a literal </script> for the escaping to act on',
    literals > 0, 'none found in src/*.js - the two assertions below are now vacuous');
  eq(app.file + ' carries every one of them escaped',
    (html.match(/<\\\/script>/g) || []).length, literals);
  var opens = (html.match(/<script\b/gi) || []).length;
  var closes = (html.match(/<\/script>/gi) || []).length;
  eq(app.file + ' closes exactly as many script elements as it opens', closes, opens);
});

if (codes.length === 2) {
  ok('both apps ship the SAME html - one source, two launch types', codes[0] === codes[1]);
}
eq('two apps were checked', codes.length, 2);

var fails = results.filter(function (r) { return !r.pass; });
results.forEach(function (r) {
  if (!r.pass) console.log('FAIL  ' + r.name + (r.detail ? '\n      ' + String(r.detail).replace(/\n/g, '\n      ') : ''));
});
console.log('\n' + (results.length - fails.length) + '/' + results.length + ' build assertions passed');
process.exit(fails.length ? 1 : 0);
