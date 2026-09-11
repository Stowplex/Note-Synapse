// node dev/run.js  - protocol-client assertions, no browser needed.
//
// Evaluates the plugin's page script inside a vm context with a stubbed DOM
// and Synapse bridge, then drives the NotebookLM client against captured
// batchexecute envelopes (see fixtures/). Covers the two ways the service
// drifted in 2026-09: the notebook.google.com host move and the slot-5
// gRPC error rows that replaced the ["er", …] envelope.
'use strict';
var fs = require('fs'), path = require('path'), vm = require('vm');

var html = fs.readFileSync(
  path.join(__dirname, '..', 'plugins', 'notebooklm_manager.html'), 'utf8');
var script = /<script>([\s\S]*)<\/script>/.exec(html)[1];

// ---------------------------------------------------------------- stubs
function element() {
  return {
    className: '', textContent: '', innerHTML: '', value: '', onclick: null,
    style: {}, classList: { toggle: function () {}, add: function () {}, remove: function () {} },
    appendChild: function () {}, querySelectorAll: function () { return []; },
  };
}
var elements = {};
var document = {
  getElementById: function (id) { return elements[id] || (elements[id] = element()); },
  createElement: function () { return element(); },
};

// Programmable transport: each test sets `routes` to a function(url, opts)
// returning the proxyFetch result.
var routes = function () { throw new Error('no route'); };
var calls = [];
var stored = null;
var Synapse = {
  proxyFetch: function (url, opts) {
    calls.push({ url: url, opts: opts || {} });
    return Promise.resolve(routes(url, opts || {}));
  },
  loadAppState: function () { return Promise.resolve({ success: true, data: stored }); },
  storeAppState: function (s) { stored = JSON.parse(JSON.stringify(s)); return Promise.resolve({ success: true }); },
  session: {
    status: function () { return Promise.resolve({ loggedIn: false }); },
    requestLogin: function () { return Promise.resolve({ loggedIn: false }); },
  },
  // No tool.env ⇒ isInteractive() is true, but no tool.registered ⇒ nothing to register.
  tool: {},
};

var ctx = {
  console: console, setTimeout: setTimeout, clearTimeout: clearTimeout,
  document: document, Synapse: Synapse, alert: function () {},
  crypto: { randomUUID: function () { return '00000000-0000-4000-8000-000000000000'; } },
  URL: URL, JSON: JSON, Promise: Promise, Error: Error, Array: Array, Object: Object,
  String: String, Number: Number, Math: Math, Date: Date, Set: Set, RegExp: RegExp,
  encodeURIComponent: encodeURIComponent, decodeURIComponent: decodeURIComponent,
};
ctx.window = ctx;
vm.createContext(ctx);
vm.runInContext(script, ctx, { filename: 'notebooklm_manager.html' });

// Reach the script's top-level bindings (const/let are not context props).
function get(expr) { return vm.runInContext(expr, ctx); }
function set(expr) { vm.runInContext(expr, ctx); }

// ---------------------------------------------------------------- fixtures
var FX = {};
fs.readdirSync(path.join(__dirname, 'fixtures')).forEach(function (f) {
  FX[f.replace(/\.txt$/, '')] = fs.readFileSync(path.join(__dirname, 'fixtures', f), 'utf8');
});
var NEW = 'https://notebook.google.com', OLD = 'https://notebooklm.google.com';
var PAGE_HTML = '<html>"SNlM0e":"AT-TOKEN","FdrFJe":"1234567890","cfb2h":"boq_labs-tailwind-frontend_20260909.10_p1"</html>';

function text(data, extra) {
  return Object.assign({ status: 'success', statusCode: 200, headers: {},
    content: { mime: 'text/plain', data: data } }, extra || {});
}

// ---------------------------------------------------------------- spec
var results = [];
function ok(name, cond, detail) { results.push({ name: name, pass: !!cond, detail: cond ? '' : (detail || '') }); }
function eq(name, a, b) { ok(name, a === b, 'expected ' + JSON.stringify(b) + ', got ' + JSON.stringify(a)); }

function reset(origin) {
  calls.length = 0;
  set("tokens = { at: '', fsid: '', bl: '' }; nlmOrigin = " + JSON.stringify(origin || NEW) + ';');
}

var cases = [];
function it(name, fn) { cases.push({ name: name, fn: fn }); }

it('parses a successful list on the new host', async function () {
  reset(NEW);
  routes = function (url) {
    if (url === NEW + '/') return text(PAGE_HTML);
    if (url.indexOf(NEW + '/_/LabsTailwindUi/data/batchexecute?rpcids=wXbhsf') === 0) return text(FX.list_ok);
    throw new Error('unexpected ' + url);
  };
  var nbs = await get('nlmClient').listNotebooks();
  eq('two notebooks', nbs.length, 2);
  eq('title', nbs[0].title, 'Papers');
  eq('id', nbs[0].id, 'b19e4386-12f2-4c00-abd2-21ffd029a42e');
  eq('emoji', nbs[0].emoji, '📚');
  var rpc = calls[1];
  ok('f.sid + bl carried', /f\.sid=1234567890/.test(rpc.url) && /bl=boq_labs/.test(rpc.url), rpc.url);
  eq('origin header', rpc.opts.headers.origin, NEW);
  eq('csrf header', rpc.opts.headers['x-goog-csrf-token'], 'AT-TOKEN');
  ok('at in body', /&at=AT-TOKEN$/.test(rpc.opts.body), rpc.opts.body);
});

it('adopts the host the app page redirects to', async function () {
  reset(OLD);
  stored = null;
  routes = function (url) {
    if (url === OLD + '/') return text(PAGE_HTML, { redirectedTo: NEW + '/' });
    if (url.indexOf(NEW + '/_/LabsTailwindUi') === 0) return text(FX.list_ok);
    if (url.indexOf(OLD + '/_/LabsTailwindUi') === 0) throw new Error('posted to the old host');
    throw new Error('unexpected ' + url);
  };
  var nbs = await get('nlmClient').listNotebooks();
  eq('list still works', nbs.length, 2);
  eq('origin switched', get('nlmOrigin'), NEW);
  await new Promise(function (r) { setTimeout(r, 0); });
  eq('origin persisted', stored && stored.origin, NEW);
});

it('restores a persisted origin on load', async function () {
  reset(OLD);
  stored = { syncMap: {}, collections: {}, origin: NEW };
  set('nlmOrigin = NLM.DEFAULT_ORIGIN;');
  await get('loadState')();
  eq('stored origin adopted', get('nlmOrigin'), NEW);
  stored = { syncMap: {}, collections: {}, origin: 'https://evil.example' };
  set('nlmOrigin = NLM.DEFAULT_ORIGIN;');
  await get('loadState')();
  eq('unlisted origin ignored', get('nlmOrigin'), NEW);
});

it('treats a redirect to Google sign-in as not logged in', async function () {
  reset(NEW);
  routes = function (url) {
    if (url === NEW + '/') return text('<html>login</html>', { redirectedTo: 'https://accounts.google.com/ServiceLogin?x=1' });
    throw new Error('unexpected ' + url);
  };
  var err = await get('nlmClient').listNotebooks().catch(function (e) { return e; });
  eq('not_logged_in', err && err.message, 'not_logged_in');
});

it('maps a slot-5 UNAUTHENTICATED row to session_expired after one re-scrape', async function () {
  reset(NEW);
  var scrapes = 0;
  routes = function (url) {
    if (url === NEW + '/') { scrapes++; return text(PAGE_HTML); }
    if (url.indexOf('batchexecute') !== -1) return text(FX.list_unauth);
    throw new Error('unexpected ' + url);
  };
  var err = await get('nlmClient').listNotebooks().catch(function (e) { return e; });
  eq('session_expired', err && err.message, 'session_expired');
  eq('re-scraped once', scrapes, 2);
  ok('friendly text', /reconnect/.test(get('friendlyError')(err)));
});

it('maps a slot-5 RESOURCE_EXHAUSTED row to rate_limited', async function () {
  reset(NEW);
  routes = function (url) {
    if (url === NEW + '/') return text(PAGE_HTML);
    return text(FX.list_quota);
  };
  var err = await get('nlmClient').listNotebooks().catch(function (e) { return e; });
  eq('rate_limited', err && err.message, 'rate_limited');
});

it('surfaces other slot-5 codes with the gRPC name and user message', async function () {
  reset(NEW);
  routes = function (url) {
    if (url === NEW + '/') return text(PAGE_HTML);
    return text(FX.list_invalid);
  };
  var err = await get('nlmClient').listNotebooks().catch(function (e) { return e; });
  eq('code', err && err.code, 3);
  eq('name', err && err.grpcName, 'INVALID_ARGUMENT');
  var msg = get('friendlyError')(err);
  ok('message names the code', /code 3 INVALID_ARGUMENT/.test(msg), msg);
  ok('message carries the detail', /Something went wrong/.test(msg), msg);
});

it('still honours the legacy ["er", …] envelope', async function () {
  reset(NEW);
  routes = function (url) {
    if (url === NEW + '/') return text(PAGE_HTML);
    return text(FX.list_er401);
  };
  var err = await get('nlmClient').listNotebooks().catch(function (e) { return e; });
  eq('legacy 401 → nlm_error_401 after retry', err && err.message, 'nlm_error_401');
});

it('flags a rotated rpc id instead of returning nothing', async function () {
  reset(NEW);
  routes = function (url) {
    if (url === NEW + '/') return text(PAGE_HTML);
    return text(FX.list_other_rpc);
  };
  var err = await get('nlmClient').listNotebooks().catch(function (e) { return e; });
  eq('drift', err && err.message, 'nlm_error_drift');
});

it('flags a present row with no payload and no status', async function () {
  reset(NEW);
  routes = function (url) {
    if (url === NEW + '/') return text(PAGE_HTML);
    return text(")]}'\n\n40\n[[\"wrb.fr\",\"wXbhsf\",null,null,null,null,\"generic\"]]\n");
  };
  var err = await get('nlmClient').listNotebooks().catch(function (e) { return e; });
  eq('empty', err && err.message, 'nlm_error_empty');
});

it('reconciles an accepted-pending add-source by title', async function () {
  reset(NEW);
  var detailCalls = 0;
  routes = function (url) {
    if (url === NEW + '/') return text(PAGE_HTML);
    if (url.indexOf('rpcids=izAoDd') !== -1) return text(FX.add_source_pending);
    if (url.indexOf('rpcids=rLM1Ne') !== -1) { detailCalls++; return text(FX.detail_ok); }
    throw new Error('unexpected ' + url);
  };
  var id = await get('nlmClient').addTextSource('b19e4386-12f2-4c00-abd2-21ffd029a42e', 'My Note', 'body');
  eq('source id recovered', id, '6d6a8e1a-2f2b-4b1c-9d1e-6f1a2b3c4d5e');
  eq('one detail poll', detailCalls, 1);
});

it('omits f.sid/bl from the query string when unknown', function () {
  reset(NEW);
  set("tokens = { at: 'x', fsid: '', bl: '' };");
  var q = get('sessionQuery')();
  ok('no empty params', q.indexOf('f.sid=') === -1 && q.indexOf('bl=') === -1, q);
});

(async function () {
  for (var i = 0; i < cases.length; i++) {
    try { await cases[i].fn(); }
    catch (e) { ok(cases[i].name, false, String(e && e.stack || e)); }
  }
  var fail = results.filter(function (r) { return !r.pass; });
  results.forEach(function (r) { if (!r.pass) console.log('FAIL  ' + r.name + '\n      ' + r.detail); });
  console.log('\n' + (results.length - fail.length) + '/' + results.length + ' assertions passed');
  process.exit(fail.length ? 1 : 0);
})();
