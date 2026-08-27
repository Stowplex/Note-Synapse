/*
 * Cartograph - the Synapse bridge.
 *
 * Everything that touches the host app goes through here. When the Flutter
 * bridge is absent (a desktop browser, the dev harness) a small in-memory mock
 * takes over, so the whole app is drivable without the phone.
 */
(function (global) {
  'use strict';
  var CG = (global.CG = global.CG || {});
  var HOST = (CG.host = {});

  var S = global.Synapse;
  HOST.isMock = !(global.flutter_inappwebview && S);

  function sqlId(id) { return String(id == null ? '' : id).replace(/[^A-Za-z0-9_\-]/g, ''); }
  HOST.sqlId = sqlId;

  /* ------------------------------------------------------------------ mock */

  var mock = null;
  if (HOST.isMock) {
    var fixture = '';
    try {
      var qp = new URLSearchParams(global.location ? global.location.search : '');
      fixture = qp.get('md') || '';
    } catch (e) { /* not in a browser */ }
    mock = {
      notes: {
        'mock-note-1': {
          id: 'mock-note-1',
          title: 'Product plan',
          content: fixture || [
            '# Product plan',
            '',
            'The one-page view of where this is going.',
            '',
            '## Discovery',
            '- Customer interviews',
            '  - Recruit 8 users',
            '  - Write the script',
            '- Competitive teardown',
            '',
            '## Design',
            '- [x] Wireframes',
            '- [ ] Visual language',
            '  - Colour and type',
            '- [ ] Motion study',
            '',
            '## Build',
            '1. API surface',
            '2. Sync engine',
            '3. Offline cache',
            '',
            '## Launch',
            '- Beta cohort',
            '- Public GA',
            ''
          ].join('\n'),
          tags: ['product']
        },
        'mock-note-2': { id: 'mock-note-2', title: 'Interview script', content: '## Warm up\n- Tell me about your week.\n', tags: [] }
      },
      seq: 2
    };
    var mockParams = {};
    try {
      new URLSearchParams(global.location ? global.location.search : '').forEach(function (v, k) {
        if (k !== 'md') mockParams[k] = v;
      });
    } catch (e) { /* not in a browser */ }
    global.Synapse = S = {
      Notes: [mock.notes['mock-note-1']],
      Params: mockParams,
      runQuery: function (sql) {
        var m = /from\s+notes\s+where\s+id\s+in\s*\(([^)]*)\)/i.exec(sql) || /from\s+notes\s+where\s+id\s*=\s*'([^']*)'/i.exec(sql);
        var ids = m ? m[1].split(',').map(function (x) { return x.trim().replace(/^'|'$/g, ''); }) : [];
        var like = /content\s+like\s+'%([^%']*)%'/i.exec(sql);
        var rows = [];
        Object.keys(mock.notes).forEach(function (k) {
          var n = mock.notes[k];
          if (like) { if (n.content.indexOf(like[1]) >= 0) rows.push({ id: n.id, title: n.title, content: n.content }); }
          else if (ids.indexOf(n.id) >= 0) rows.push({ id: n.id, title: n.title, content: n.content });
        });
        return Promise.resolve({ success: true, data: rows });
      },
      updateNotes: function (list) {
        list.forEach(function (u) {
          var n = mock.notes[u.id];
          if (!n) return;
          if (u.modification && u.modification.content) n.content = u.modification.content.text;
          else if (typeof u.content === 'string') n.content = u.content;
          if (u.title) n.title = u.title;
        });
        return Promise.resolve({ success: true, updatedCount: list.length });
      },
      saveNotes: function (list) {
        list.forEach(function (n) {
          mock.seq += 1;
          var id = 'mock-note-' + mock.seq;
          mock.notes[id] = { id: id, title: n.title || 'Untitled', content: n.content || '', tags: n.tags || [] };
        });
        return Promise.resolve({ success: true, savedCount: list.length });
      },
      pickNotes: function () {
        var ids = Object.keys(mock.notes);
        var pick = global.prompt('Mock note picker - id to attach:\n' + ids.map(function (i) { return i + ' = ' + mock.notes[i].title; }).join('\n'), ids[1] || ids[0]);
        if (!pick || !mock.notes[pick]) return Promise.resolve({ success: true, cancelled: true, notes: [] });
        return Promise.resolve({ success: true, notes: [{ id: pick, title: mock.notes[pick].title }] });
      },
      openNote: function (id) { global.console.log('[mock] openNote', id); return Promise.resolve({ success: true }); }
    };
  }

  /* ------------------------------------------------------------------ api */

  HOST.note = function () {
    var n = (S && S.Notes && S.Notes[0]) || null;
    return n ? {
      id: n.id,
      title: n.title || '',
      content: n.content || '',
      tags: n.tags || [],
      isBlockScope: n.isBlockScope === true
    } : null;
  };

  HOST.params = function () { return (S && S.Params) || {}; };

  HOST.query = function (sql) {
    if (!S || !S.runQuery) return Promise.resolve([]);
    return S.runQuery(sql).then(function (r) {
      if (r && r.success && Array.isArray(r.data)) return r.data;
      return [];
    }).catch(function () { return []; });
  };

  HOST.readNotes = function (ids) {
    var clean = (ids || []).map(sqlId).filter(Boolean);
    if (!clean.length) return Promise.resolve([]);
    var list = clean.map(function (i) { return "'" + i + "'"; }).join(',');
    return HOST.query('SELECT id, title, content FROM notes WHERE id IN (' + list + ')');
  };

  HOST.readContent = function (id) {
    return HOST.readNotes([id]).then(function (rows) { return rows.length ? rows[0].content : null; });
  };

  // Always the `modification` form: it is the only one a block-scoped note
  // accepts, and it behaves identically for an ordinary note.
  HOST.writeContent = function (id, content) {
    if (!S || !S.updateNotes) return Promise.reject(new Error('no host'));
    return S.updateNotes([{ id: id, modification: { content: { action: 'replace', text: content } } }])
      .then(function (r) {
        if (r && r.success === false) throw new Error(r.error || 'update failed');
        if (r && r.errors && r.errors.length) throw new Error(r.errors[0]);
        return true;
      });
  };

  /*
   * saveNotes reports only a count, never the new id, so the note is created
   * carrying a one-shot marker, found by that marker, then cleaned up.
   */
  HOST.createNote = function (spec) {
    if (!S || !S.saveNotes) return Promise.reject(new Error('no host'));
    var nonce = 'cgmk' + Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
    var body = (spec.content || '').replace(/\s+$/, '');
    var seeded = body + (body ? '\n\n' : '') + '<!-- ' + nonce + ' -->';
    return S.saveNotes([{ title: spec.title || 'Untitled', content: seeded, tags: spec.tags || [] }])
      .then(function (r) {
        if (!r || r.success === false) throw new Error((r && r.error) || 'could not create the note');
        return HOST.query("SELECT id, title FROM notes WHERE content LIKE '%" + nonce + "%' LIMIT 2");
      })
      .then(function (rows) {
        if (!rows.length) throw new Error('the note was created but could not be found again');
        var id = rows[0].id;
        return HOST.writeContent(id, body).then(function () { return { id: id, title: spec.title || 'Untitled' }; });
      });
  };

  HOST.pickNotes = function (options) {
    if (!S || !S.pickNotes) return Promise.resolve([]);
    return S.pickNotes(options || {}).then(function (r) {
      if (!r || r.cancelled || !r.notes) return [];
      return r.notes;
    }).catch(function () { return []; });
  };

  HOST.openNote = function (id) {
    if (!S || !S.openNote) return Promise.resolve();
    return S.openNote(id, false).catch(function () {});
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = CG;
})(typeof window !== 'undefined' ? window : globalThis);
