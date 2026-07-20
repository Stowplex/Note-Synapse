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
            var id = 'att-' + attSeq++;
            var path = '/stub/attachments/' + id + '-' + name;
            var data = a.data || '';
            var b64 = data.indexOf(',') >= 0 ? data.slice(data.indexOf(',') + 1) : data;
            files[path] = function () { return b64; };
            attachments.push({ id: id, path: path, fileName: name, mimeType: 'application/octet-stream' });
          });
        }
      });
      return Promise.resolve({ success: true, updatedCount: updates.length });
    },
  };
})();
