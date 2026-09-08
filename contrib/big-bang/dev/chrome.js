/*
 * node dev/chrome.js [path] - run a dev page in headless Chrome and report it.
 *
 * It exists because two traps make an ad-hoc `chrome --dump-dom` lie:
 *
 *   Chrome writes the DOM when --virtual-time-budget expires and then NEVER
 *   EXITS. A runner that waits for the process ends up killed by a timeout
 *   with an empty file, and "0 failures" against a 0-byte dump has been
 *   reported as a pass more than once in this project. So the dump is polled
 *   until its size stops changing AND it contains the page's summary, and only
 *   then is the browser killed.
 *
 *   A REUSED --user-data-dir serves the plugin's own source out of the HTTP
 *   cache, so a change to src/*.js may not be in the run at all - which makes
 *   a mutation look killed when nothing tested it. Every run gets a fresh
 *   profile directory, and it is removed afterwards.
 *
 * And one that made THIS runner lie. A dump is not a result. The page ships
 * with `<div id="sum">running…</div>` in its markup, so a run that never
 * finished still has a summary div, still has no failure rows, and still
 * exited 0 - a promise that neither settles nor times out was reported as a
 * pass, with 184 KB of dump and `sum: running…` printed right above it. So the
 * summary has to PARSE as a count, the count has to be non-zero, and it has to
 * reach the floor below: a run cut off two thirds of the way through is a
 * failure, not a smaller pass. FLOORS is the number the page is known to
 * execute; raise it when the page grows, and never lower it to make a run go
 * green.
 *
 * Serve the directory first (the pages fetch fixtures and modules):
 *   cd contrib/big-bang && python3 -m http.server 8781
 *   node dev/chrome.js dev/app_smoke.html
 *
 * Env: BB_PORT, BB_BUDGET, CHROME, BB_MIN (override the floor for one run).
 */
var cp = require('child_process');
var fs = require('fs');
var os = require('os');
var path = require('path');

var page = process.argv[2] || 'dev/app_smoke.html';
var port = process.env.BB_PORT || '8781';
var url = /^https?:/.test(page) ? page : 'http://127.0.0.1:' + port + '/' + page.replace(/^\.?\//, '');
/*
 * The VIRTUAL-time budget, and it is not real seconds: the app smoke page
 * spends ~22 s of it on debounce and toast windows it deliberately asserts on,
 * and burns that in under 3 s of wall clock. Raising it therefore costs
 * nothing measurable (900 000 and 60 000 both finish in ~2.9 s) while removing
 * a cliff that M6 and M7 would otherwise walk into: when the budget expires
 * mid-run, report() never runs, virtual time stops advancing and the dump
 * carries `sum: running…`.
 */
var budget = process.env.BB_BUDGET || '300000';

/*
 * What each page is known to execute, so that a run which stopped a third of
 * the way through cannot come back green with a smaller number. Keyed by the
 * page's file name; a page not listed here only has to report a non-zero
 * count. BB_MIN overrides it for one run - for bisecting, not for CI.
 */
var FLOORS = {
  'app_smoke.html': 1389,
  'auto_smoke.html': 1148
};
var floor = process.env.BB_MIN ? Number(process.env.BB_MIN)
  : (FLOORS[path.basename(page.split('?')[0])] || 1);
var CHROME = process.env.CHROME ||
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

var profile = fs.mkdtempSync(path.join(os.tmpdir(), 'bb-chrome-'));
var out = path.join(profile, 'dump.html');
var fd = fs.openSync(out, 'w');

var child = cp.spawn(CHROME, [
  '--headless=new',
  '--disable-gpu',
  '--no-sandbox',
  '--user-data-dir=' + profile,
  '--virtual-time-budget=' + budget,
  '--dump-dom',
  url
], { stdio: ['ignore', fd, 'pipe'] });

var stderr = '';
child.stderr.on('data', function (b) { stderr += b.toString(); });

/*
 * MAX is REAL time and must not track the virtual budget. A page holding an
 * outstanding fetch pauses virtual time indefinitely - the budget never
 * expires, so the dump is never written - and with MAX tied to the budget,
 * raising the budget would turn that hang into a quarter-hour wait instead of
 * a failure. BB_MAX overrides it.
 */
var last = -1, stable = 0, waited = 0;
var TICK = 400, MAX = Number(process.env.BB_MAX || 90000);

function done(code, note) {
  try { child.kill('SIGKILL'); } catch (e) { /* already gone */ }
  var text = '';
  try { text = fs.readFileSync(out, 'utf8'); } catch (e) { /* never written */ }
  // Chrome can keep creating profile files for a few milliseconds after
  // SIGKILL. Let Node retry ENOTEMPTY/EBUSY instead of losing an otherwise
  // complete assertion report to a cleanup race.
  fs.rmSync(profile, { recursive: true, force: true, maxRetries: 8, retryDelay: 100 });
  if (!text.length) {
    console.log('EMPTY DUMP - nothing was rendered. Is the server up on ' + url + '?');
    if (stderr) console.log(stderr.split('\n').slice(0, 8).join('\n'));
    process.exit(2);
  }
  var sum = /<div id="sum"[^>]*>([\s\S]*?)<\/div>/.exec(text);
  var summary = sum ? sum[1].trim() : '';
  var fails = text.match(/class="row fail"/g) || [];
  console.log('dump: ' + text.length + ' bytes' + (note ? ' (' + note + ')' : ''));
  console.log('sum : ' + (summary || '(no summary in the dump)'));
  if (fails.length) {
    var re = /<div class="row fail">([\s\S]*?)<\/div>(?:\s*<pre>([\s\S]*?)<\/pre>)?/g, m;
    while ((m = re.exec(text))) {
      console.log('FAIL  ' + m[1].trim() + (m[2] ? '\n      ' + m[2].trim().replace(/\n/g, '\n      ') : ''));
    }
  }

  // The page's own count, or nothing. `running…` is the markup the page ships
  // with, so "there is a summary div" says only that the HTML parsed.
  var counted = /^(\d+)\/(\d+)\s/.exec(summary);
  var passed = counted ? Number(counted[1]) : 0;
  var ran = counted ? Number(counted[2]) : 0;
  var why = [];
  if (!counted) {
    why.push(summary
      ? 'the page never finished - its summary still says ' + JSON.stringify(summary)
      : 'the dump carries no summary at all');
  } else {
    console.log('ran : ' + ran + ' assertions, ' + passed + ' passed, floor ' + floor);
    if (!ran) why.push('the page reported ZERO assertions');
    else if (ran < floor) {
      why.push('only ' + ran + ' assertions ran, below the floor of ' + floor +
        ' - the run was cut short. Raise FLOORS in dev/chrome.js only when the page really has fewer.');
    }
    if (passed < ran) why.push((ran - passed) + ' assertion(s) failed');
  }
  if (fails.length && !why.length) why.push(fails.length + ' failure row(s)');
  why.forEach(function (w) { console.log('NOT A PASS: ' + w); });
  process.exit(why.length || fails.length ? 1 : 0);
}

var timer = setInterval(function () {
  waited += TICK;
  var size = 0;
  try { size = fs.statSync(out).size; } catch (e) { size = 0; }
  // A dump that has stopped growing AND carries the page's own summary is a
  // finished run; a page still working has neither.
  if (size > 0 && size === last) stable++; else stable = 0;
  last = size;
  if (stable >= 3) { clearInterval(timer); return done(0, 'settled after ' + waited + 'ms'); }
  if (waited > MAX) { clearInterval(timer); return done(1, 'gave up after ' + waited + 'ms'); }
}, TICK);
