// node dev/run.js  - runs the browser-independent assertions
var fs = require('fs'), path = require('path');
var base = path.join(__dirname, '..', 'plugins', 'src');
['md', 'edit', 'sidecar', 'layout', 'view'].forEach(function (f) {
  eval(fs.readFileSync(path.join(base, f + '.js'), 'utf8'));
});
globalThis.CG_FIXTURES = {};
fs.readdirSync(path.join(__dirname, 'fixtures')).forEach(function (f) {
  globalThis.CG_FIXTURES[f] = fs.readFileSync(path.join(__dirname, 'fixtures', f), 'utf8');
});
require('./spec.js');
var res = globalThis.CG.spec.run();
var fail = res.filter(function (r) { return !r.pass; });
res.forEach(function (r) { if (!r.pass) console.log('FAIL  ' + r.name + (r.detail ? '\n      ' + r.detail.replace(/\n/g, '\n      ') : '')); });
console.log('\n' + (res.length - fail.length) + '/' + res.length + ' assertions passed');
process.exit(fail.length ? 1 : 0);
