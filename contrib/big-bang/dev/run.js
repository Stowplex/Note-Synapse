// node dev/run.js  - runs the browser-independent assertions
var fs = require('fs'), path = require('path');
var base = path.join(__dirname, '..', 'plugins', 'src');
// gestures.js and app.js need a DOM and are covered by dev/app_smoke.html;
// everything here runs without one. render.js is loaded but never MADE: its
// factory needs a document, its constants and its width rule do not, and
// export.js reads both - so the picture the export draws is asserted on here,
// with no browser, against the same numbers the screen uses.
['board', 'model', 'host', 'notes', 'render', 'ai', 'export'].forEach(function (f) {
  eval(fs.readFileSync(path.join(base, f + '.js'), 'utf8'));
});
globalThis.BB_FIXTURES = {};
fs.readdirSync(path.join(__dirname, 'fixtures')).forEach(function (f) {
  globalThis.BB_FIXTURES[f] = fs.readFileSync(path.join(__dirname, 'fixtures', f), 'utf8');
});
require('./spec.js');
globalThis.BB.spec.run().then(function (res) {
  var fail = res.filter(function (r) { return !r.pass; });
  res.forEach(function (r) { if (!r.pass) console.log('FAIL  ' + r.name + (r.detail ? '\n      ' + String(r.detail).replace(/\n/g, '\n      ') : '')); });
  console.log('\n' + (res.length - fail.length) + '/' + res.length + ' assertions passed');
  process.exit(fail.length ? 1 : 0);
});
