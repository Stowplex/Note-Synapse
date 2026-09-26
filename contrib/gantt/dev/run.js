// node dev/run.js - runs the browser-independent assertions.
// GT_SEED=<n> node dev/run.js reruns the region property test with that seed.
var fs = require('fs'), path = require('path');
var base = path.join(__dirname, '..', 'plugins', 'src');

// Load order is D18. render.js and app.js touch no DOM at load time; their
// DOM behaviour is covered by the Chrome pages.
var MODULES = ['i18n', 'dates', 'model', 'undo', 'block', 'md', 'host', 'store', 'scale', 'layout', 'theme', 'render', 'gestures', 'sheet', 'app'];
MODULES.forEach(function (f) {
  eval(fs.readFileSync(path.join(base, f + '.js'), 'utf8'));
});

// host.js owns GT.APP_UUID (the Gantt.yaml uuid since M4). Fixtures spell it {{APP_UUID}}.
if (!globalThis.GT.APP_UUID) throw new Error('host.js did not define GT.APP_UUID');

globalThis.GT_FIXTURES = {};
fs.readdirSync(path.join(__dirname, 'fixtures')).forEach(function (f) {
  var text = fs.readFileSync(path.join(__dirname, 'fixtures', f), 'utf8');
  globalThis.GT_FIXTURES[f] = text.split('{{APP_UUID}}').join(globalThis.GT.APP_UUID);
});

// Every source file, for the grep rules.
globalThis.GT_SOURCES = {};
fs.readdirSync(base).forEach(function (f) {
  if (/\.js$/.test(f)) globalThis.GT_SOURCES[f] = fs.readFileSync(path.join(base, f), 'utf8');
});

// The shell, for the token and palette tables (dev/view_spec.js).
globalThis.GT_SHELL = fs.readFileSync(path.join(__dirname, '..', 'plugins', 'gantt.html'), 'utf8');

if (process.env.GT_SEED) globalThis.GT_SEED = Number(process.env.GT_SEED);

require('./spec.js');
require('./host_spec.js');
require('./store_spec.js');
require('./view_spec.js');
require('./gesture_spec.js');
require('./edit_spec.js');
require('./style_spec.js');
require('./m9_spec.js');
globalThis.GT.spec.run().then(function (res) {
  var fail = res.filter(function (r) { return !r.pass; });
  res.forEach(function (r) { if (!r.pass) console.log('FAIL  ' + r.name + (r.detail ? '\n      ' + String(r.detail).replace(/\n/g, '\n      ') : '')); });
  console.log('\n' + (res.length - fail.length) + '/' + res.length + ' assertions passed');
  process.exit(fail.length ? 1 : 0);
});
