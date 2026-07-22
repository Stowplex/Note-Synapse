// Browser-only stub of the window.Synapse surface Table Studio uses, for
// developing the plugin outside Note Synapse. Not part of the shipped app.
(function () {
  'use strict';

  var SAMPLE_CSV = 'Name,Qty,Price\nApples,4,2.50\n"Pears, ripe",2,3.10\n';

  var noteContent = [
    '# Groceries',
    '',
    'Weekly shopping list.',
    '',
    '| Item | Qty | Notes |',
    '| ---- | --: | ----- |',
    '| Milk | 2   | oat \\| soy |',
    '| Eggs | 12  | free range |',
    '',
    '```',
    '| not | a table |',
    '| --- | ------- |',
    '```',
    '',
    '| Store | Rating |',
    '| :---: | -----: |',
    '| Co-op | 4      |',
  ].join('\n');

  var attachments = [
    {
      id: 'att-1',
      path: '/stub/attachments/list.csv',
      fileName: 'list.csv',
      mimeType: 'text/csv',
    },
    {
      id: 'att-2',
      path: '/stub/attachments/book.xlsx',
      fileName: 'book.xlsx',
      mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    },
  ];
  // File contents: strings are utf-8 text; functions lazily return base64
  // (used for the xlsx sample, built with the plugin's own SheetJS bundle).
  var files = {
    '/stub/attachments/list.csv': SAMPLE_CSV,
    '/stub/attachments/book.xlsx': function () {
      var XLSX = window.XLSX;
      var wb = XLSX.utils.book_new();
      var sales = XLSX.utils.aoa_to_sheet([
        ['Product', 'Total'],
        ['Widget', 42],
        ['Gadget', 7],
      ]);
      sales.B2.f = '21*2';
      // A date-formatted cell: the editor must round-trip its number format.
      sales.C2 = { t: 'n', v: 45123, z: 'yyyy-mm-dd' };
      sales['!ref'] = 'A1:C3';
      XLSX.utils.book_append_sheet(wb, sales, 'Sales');
      var info = XLSX.utils.aoa_to_sheet([['Notes'], ['keep me']]);
      XLSX.utils.book_append_sheet(wb, info, 'Info');
      return XLSX.write(wb, { bookType: 'xlsx', type: 'base64' });
    },
  };
  var attSeq = 3;

  function b64encode(text) {
    var bytes = new TextEncoder().encode(text);
    var bin = '';
    for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
    return btoa(bin);
  }

  function bytesToB64(bytes) {
    var bin = '';
    var CHUNK = 0x8000;
    for (var i = 0; i < bytes.length; i += CHUNK) {
      bin += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
    }
    return btoa(bin);
  }
  function b64ToBytes(b64) {
    var bin = atob(b64);
    var bytes = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
  }

  // In-memory app state (the real host persists this in its database).
  var appState = {};

  /**
   * proxyFetch stub. Engine URLs are served from dev/univer-mirror/<name>
   * when that directory exists (populate it with fetch_univer_mirror.sh for
   * offline runs); anything else — including a missing mirror — falls back
   * to a real browser fetch of the URL.
   */
  function stubProxyFetch(url, options) {
    var target = url;
    var bridge = window.UniverBridge;
    if (bridge) {
      var all = bridge.ENGINE.js.concat(bridge.ENGINE.css);
      for (var i = 0; i < all.length; i++) {
        if (url.indexOf(all[i].path) >= 0) {
          target = 'univer-mirror/' + all[i].name;
          break;
        }
      }
    }
    var attempt = function (u) {
      return fetch(u).then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.arrayBuffer().then(function (buf) {
          return {
            status: 'success',
            statusCode: 200,
            content: {
              mime: 'application/octet-stream',
              data: bytesToB64(new Uint8Array(buf)),
            },
          };
        });
      });
    };
    return attempt(target).catch(function (e) {
      if (target !== url) return attempt(url); // mirror miss -> real CDN
      return { status: 'error', error: String((e && e.message) || e) };
    });
  }

  window.Synapse = {
    Notes: [
      {
        id: 'note-1',
        title: 'Groceries',
        content: noteContent,
        tags: [],
        attachmentPaths: ['attachments/list.csv'],
      },
    ],
    Params: {},
    exportNotes: function (ids) {
      return Promise.resolve({
        success: true,
        notes: ids.map(function (id) {
          return {
            id: id,
            title: 'Groceries',
            markdown: '# rendered export, not raw content',
            attachments: attachments.slice(),
          };
        }),
      });
    },
    runQuery: function (sql) {
      console.log('[stub runQuery]', sql);
      return Promise.resolve({
        success: true,
        data: [{ content: noteContent }],
      });
    },
    readAttachment: function (path) {
      if (files[path] == null) {
        return Promise.resolve({ success: false, error: 'not found: ' + path });
      }
      var f = files[path];
      return Promise.resolve({
        success: true,
        data: typeof f === 'function' ? f() : b64encode(f),
        mimeType: 'application/octet-stream',
      });
    },
    updateNotes: function (updates) {
      console.log('[stub updateNotes]', JSON.stringify(updates, null, 2));
      updates.forEach(function (u) {
        var mod = u.modification || {};
        if (mod.content) {
          if (mod.content.action === 'replace') noteContent = mod.content.text;
          if (mod.content.action === 'append') noteContent += '\n' + mod.content.text;
        }
        if (mod.attachments) {
          (mod.attachments.removed || []).forEach(function (p) {
            attachments = attachments.filter(function (a) {
              return a.path !== p && 'attachments/' + a.fileName !== p;
            });
          });
          (mod.attachments.added || []).forEach(function (a) {
            var name = a.fileName || 'file.bin';
            var seq = attSeq++;
            var id = 'att-' + seq;
            // Mirror the real host: every stored file is renamed to
            // "<stem>_<uuid>.<ext>" by generateUniqueFileName.
            var dot = name.lastIndexOf('.');
            var stem = dot >= 0 ? name.slice(0, dot) : name;
            var ext = dot >= 0 ? name.slice(dot) : '';
            var fakeUuid =
              '00000000-0000-4000-8000-' + String(seq).padStart(12, '0');
            var stored = stem + '_' + fakeUuid + ext;
            var path = '/stub/attachments/' + stored;
            var data = a.data || '';
            var b64 = data.indexOf(',') >= 0 ? data.slice(data.indexOf(',') + 1) : data;
            files[path] = function () { return b64; };
            attachments.push({ id: id, path: path, fileName: stored, mimeType: 'application/octet-stream' });
          });
        }
      });
      return Promise.resolve({ success: true, updatedCount: updates.length });
    },
    proxyFetch: function (url, options) {
      return stubProxyFetch(url, options);
    },
    crypto: {
      digest: function (algo, input) {
        if (algo !== 'sha256' || !input || typeof input.base64 !== 'string') {
          return Promise.resolve({ success: false, error: 'unsupported' });
        }
        var data = b64ToBytes(input.base64);
        return crypto.subtle.digest('SHA-256', data).then(function (buf) {
          var arr = Array.from(new Uint8Array(buf));
          var hex = arr.map(function (b) { return b.toString(16).padStart(2, '0'); }).join('');
          return { success: true, hex: hex };
        });
      },
    },
    loadAppState: function () {
      return Promise.resolve({ success: true, data: JSON.parse(JSON.stringify(appState)) });
    },
    storeAppState: function (st) {
      appState = JSON.parse(JSON.stringify(st || {}));
      return Promise.resolve({ success: true });
    },
  };
})();
