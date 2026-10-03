/*
 * Gantt host.js assertions that need a real DOM (dev/auto_smoke.html only):
 * the §7.6 resume triggers and synapse:* events on a real window and
 * document, and installMock's sessionStorage persistence across a page
 * reload (an iframe srcdoc with the mock host, the Big Bang pattern).
 */
(function (global) {
  'use strict';
  var GT = global.GT, H = GT.host, SPEC = GT.spec;
  var A = SPEC.api, ok = A.ok, eq = A.eq, acase = A.acase;
  var doc = global.document;

  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  // A srcdoc frame that loads the host modules and runs `body`; resolves the
  // first message it posts.
  var SRC = ['i18n', 'dates', 'model', 'undo', 'block', 'md', 'host'].map(function (m) {
    return '<script src="../plugins/src/' + m + '.js"><\/script>';
  }).join('');
  function frame(tag, body) {
    return new Promise(function (resolve) {
      var f = doc.createElement('iframe');
      f.style.display = 'none';
      function onMsg(e) {
        if (!e.data || e.data.tag !== tag) return;
        global.removeEventListener('message', onMsg);
        resolve({ data: e.data, frame: f });
      }
      global.addEventListener('message', onMsg);
      f.srcdoc = '<!doctype html><meta charset="utf-8">' + SRC + '<script>' + body + '<\/script>';
      doc.body.appendChild(f);
    });
  }
  function post(tag) { return 'function post(d){d.tag=' + JSON.stringify(tag) + ';parent.postMessage(d,"*");}'; }

  function domSpec() {
    if (!doc || typeof global.addEventListener !== 'function') { ok('dom spec needs a browser (skipped in node)', true); return; }

    acase('dom: resume triggers on the real window and document', function () {
      var t = 0, got = [], iv = null, state = 'visible';
      var syn = { openNote: function () { return Promise.resolve({ success: true }); } };
      var h = H.create(syn, { now: function () { return t; }, setInterval: function (fn) { iv = fn; return 1; }, clearInterval: function () { iv = null; } });
      var desc = Object.getOwnPropertyDescriptor(doc, 'visibilityState');
      Object.defineProperty(doc, 'visibilityState', { configurable: true, get: function () { return state; } });
      var off = h.onResume(function (why) { got.push(why); });
      global.dispatchEvent(new Event('focus'));
      t = 300; global.dispatchEvent(new Event('pageshow'));
      t = 600; state = 'hidden'; doc.dispatchEvent(new Event('visibilitychange'));
      t = 900; iv();
      eq('dom resume: focus and pageshow fire; hidden and a hidden interval do not', got.join(','), 'focus,pageshow');
      t = 1200; state = 'visible'; doc.dispatchEvent(new Event('visibilitychange'));
      t = 1500; iv();
      eq('dom resume: visible and the interval fire', got.join(','), 'focus,pageshow,visible,interval');
      t = 1800; global.dispatchEvent(new Event('pointerdown'));
      eq('dom resume: pointerdown before openNote does nothing', got.length, 4);
      return h.openNote('a').then(function (r) {
        ok('dom resume: openNote ok', r.ok);
        t = 2100; doc.body.dispatchEvent(new Event('pointerdown', { bubbles: true }));
        t = 2400; doc.body.dispatchEvent(new Event('pointerdown', { bubbles: true }));
        eq('dom resume: the first pointerdown after openNote fires once (capture on window)', got.join(','), 'focus,pageshow,visible,interval,pointer');
        off();
        t = 5000; global.dispatchEvent(new Event('focus'));
        eq('dom resume: off() removes the listeners', got.length, 5);
        ok('dom resume: off() clears the interval', iv === null);
        if (desc) Object.defineProperty(doc, 'visibilityState', desc); else delete doc.visibilityState;
      });
    });

    acase('dom: synapse:* events arrive as CustomEvent detail', function () {
      var syn = { locale: 'en-US' }, h = H.create(syn, {}), seen = [];
      var off1 = h.on('localechanged', function (d) { seen.push(d); });
      var off2 = h.on('spacechanged', function (d) { seen.push(d && d.name); });
      global.dispatchEvent(new CustomEvent('synapse:localechanged', { detail: 'zh-CN' }));
      global.dispatchEvent(new CustomEvent('synapse:spacechanged', { detail: { id: 's', name: 'Work', tags: [] } }));
      off1(); off2();
      global.dispatchEvent(new CustomEvent('synapse:localechanged', { detail: 'en-US' }));
      eq('dom events: detail passed, off() works', seen.join(','), 'zh-CN,Work');
      return Promise.resolve();
    });

    acase('dom: two mock instances in one page share sessionStorage', function () {
      var key = 'gt-mock-appstate:dom-two';
      try { global.sessionStorage.removeItem(key); } catch (e) { /* blocked */ }
      var a = H.installMock([{ id: 'n1', content: 'x' }], { global: false, storage: global.sessionStorage, appId: 'dom-two' });
      var b = H.installMock(null, { global: false, storage: global.sessionStorage, appId: 'dom-two', db: a.db });
      return a.host.storeState({ journal: { c1: { at: 5 } } }).then(function (r) {
        ok('dom two: stored', r.ok && typeof global.sessionStorage.getItem(key) === 'string');
        return b.host.loadState();
      }).then(function (r) {
        ok('dom two: the second instance loads it', r.ok && r.data.journal.c1.at === 5);
        global.sessionStorage.removeItem(key);
      });
    });

    acase('dom: installMock persists appState in sessionStorage across a reload', function () {
      var key = 'gt-mock-appstate:dom-reload';
      try { global.sessionStorage.removeItem(key); } catch (e) { /* blocked */ }
      var first = post('first') +
        'var m = GT.host.installMock([{id:"c1",title:"C",content:"x"}], {appId:"dom-reload"});' +
        'var got = [];' +
        'GT.host.onResume(function (w) { got.push(w); });' +
        'window.dispatchEvent(new Event("focus"));' +
        'var loc = [];' +
        'GT.host.on("localechanged", function (d) { loc.push(d); });' +
        'm.emit("localechanged", "zh-CN");' +
        'GT.host.storeState({v:1, prefs:{theme:"dark"}}).then(function (r) {' +
        '  post({ok: r.ok, global: window.Synapse === m.synapse, storage: m.storage === window.sessionStorage,' +
        '        resume: got.join(","), locale: loc.join(","), hostLocale: GT.host.locale(), notes: GT.host.launch().notes.length});' +
        '});';
      var second = post('second') +
        'GT.host.installMock([], {appId:"dom-reload"});' +
        'GT.host.loadState().then(function (r) { post({ok: r.ok, data: r.data}); });';
      return frame('first', first).then(function (res) {
        var d = res.data;
        ok('dom reload: storeState ok', d.ok);
        ok('dom reload: installMock sets window.Synapse by default', d.global === true);
        ok('dom reload: the default storage is sessionStorage in a browser', d.storage === true);
        eq('dom reload: GT.host follows the global mock and its window events', d.resume, 'focus');
        eq('dom reload: mock.emit dispatches a real synapse:localechanged', d.locale + '|' + d.hostLocale, 'zh-CN|zh-CN');
        eq('dom reload: no Notes means a standalone launch', d.notes, 0);
        ok('dom reload: the blob is in the parent origin\'s sessionStorage', /"theme":"dark"/.test(global.sessionStorage.getItem(key) || ''));
        res.frame.parentNode.removeChild(res.frame);
        return frame('second', second);
      }).then(function (res) {
        ok('dom reload: a reloaded page with a new mock sees the blob', res.data.ok && res.data.data.prefs.theme === 'dark');
        res.frame.parentNode.removeChild(res.frame);
        global.sessionStorage.removeItem(key);
        return sleep(0);
      });
    });
  }

  SPEC.suites.push({ name: 'the dom host spec', fn: domSpec });
  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
