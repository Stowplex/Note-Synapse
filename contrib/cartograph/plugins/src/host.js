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
    // ?att=slides.pdf,photo.png hangs attachments off the mock note, the way a
    // note_action launch advertises them through Synapse.Notes[0].attachmentPaths.
    var fixtureAtts = [];
    try {
      var qp = new URLSearchParams(global.location ? global.location.search : '');
      fixture = qp.get('md') || '';
      fixtureAtts = (qp.get('att') || '').split(',').map(function (s) { return s.trim(); }).filter(Boolean)
        .map(function (name) { return { path: '/mock/attachments/' + name, fileName: name, mimeType: '' }; });
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
          tags: ['product'],
          attachments: fixtureAtts
        },
        'mock-note-2': { id: 'mock-note-2', title: 'Interview script', content: '## Warm up\n- Tell me about your week.\n', tags: [] },
        // A note that is nothing but a file: no markdown at all, one PDF.
        'mock-note-5': {
          id: 'mock-note-5', title: 'Lecture slides', content: '', tags: [],
          attachments: [{ path: '/mock/attachments/slides.pdf', fileName: 'slides.pdf', mimeType: 'application/pdf' }]
        },
        'mock-note-3': {
          id: 'mock-note-3', title: 'Quarterly review',
          content: 'Notes from the review.\n\n[\uD83D\uDDFA Mind map](synapseresource://note/mock-note-4?via=cartograph)\n',
          tags: []
        },
        'mock-note-4': {
          id: 'mock-note-4', title: 'Quarterly review \u2014 map',
          content: '# Quarterly review\n\n## Wins\n- Shipped sync\n\n## Misses\n- Docs slipped\n',
          tags: []
        }
      },
      seq: 5
    };
    var mockNoteView = function (n) {
      return {
        id: n.id, title: n.title, content: n.content, tags: n.tags,
        attachmentPaths: (n.attachments || []).map(function (a) { return a.path; })
      };
    };
    var mockParams = {};
    try {
      new URLSearchParams(global.location ? global.location.search : '').forEach(function (v, k) {
        if (k !== 'md') mockParams[k] = v;
      });
    } catch (e) { /* not in a browser */ }
    // ?standalone=1 drops the note, which is how a `normal` launch arrives.
    var mockStandalone = false;
    try {
      mockStandalone = new URLSearchParams(global.location ? global.location.search : '').has('standalone');
    } catch (e) { /* not in a browser */ }
    global.__mockNotes = function () { return mock.notes; };
    global.Synapse = S = {
      Notes: mockStandalone ? [] : [mockNoteView(mock.notes['mock-note-1'])],
      Params: mockParams,
      exportNotes: function (ids) {
        var out = [];
        (ids || []).forEach(function (id) {
          var n = mock.notes[id];
          if (!n) return;
          out.push({
            id: n.id, title: n.title, markdown: '# ' + n.title + '\n\n' + n.content,
            attachments: (n.attachments || []).map(function (a, i) {
              return { id: 'att-' + i, path: a.path, fileName: a.fileName, mimeType: a.mimeType || '' };
            })
          });
        });
        return Promise.resolve({ success: true, notes: out });
      },
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
        (global.__mockUpdates = global.__mockUpdates || []).push(list);
        list.forEach(function (u) {
          var n = mock.notes[u.id];
          if (!n) return;
          if (u.modification && u.modification.content) n.content = u.modification.content.text;
          else if (typeof u.content === 'string') n.content = u.content;
          if (u.title) n.title = u.title;
          // Attachments, the way the host does it: every saved file is renamed
          // to <stem>_<uuid><ext>, and `removed` names stored paths.
          var am = u.modification && u.modification.attachments;
          if (am) {
            n.attachments = n.attachments || [];
            (am.removed || []).forEach(function (p) {
              n.attachments = n.attachments.filter(function (a) { return a.path !== p; });
            });
            (am.added || []).forEach(function (a) {
              if (!a || a.type !== 'base64' || !a.fileName) return;
              var dot = a.fileName.lastIndexOf('.');
              var stem = dot > 0 ? a.fileName.slice(0, dot) : a.fileName, ext = dot > 0 ? a.fileName.slice(dot) : '';
              var uuid = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (ch) {
                var r = Math.random() * 16 | 0; return (ch === 'x' ? r : (r & 3 | 8)).toString(16);
              });
              n.attachments.push({ path: '/mock/attachments/' + stem + '_' + uuid + ext, fileName: a.fileName, mimeType: a.mimeType || '', data: a.data });
            });
          }
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
        // Scripted first (window.__CG_PICK__), so tests never hit a dialog.
        var queue = global.__CG_PICK__;
        var pick = null;
        if (typeof queue === 'function') pick = queue();
        else if (Array.isArray(queue) && queue.length) pick = queue.shift();
        else if (typeof queue === 'string') pick = queue;
        if (pick === null || pick === undefined) {
          var ids = Object.keys(mock.notes);
          pick = global.prompt('Mock note picker - id to attach:\n' +
            ids.map(function (i) { return i + ' = ' + mock.notes[i].title; }).join('\n'), ids[1] || ids[0]);
        }
        var ids = Array.isArray(pick) ? pick : [pick];
        ids = ids.filter(function (i) { return i && mock.notes[i]; });
        if (!ids.length) return Promise.resolve({ success: true, cancelled: true, notes: [] });
        return Promise.resolve({
          success: true,
          notes: ids.map(function (i) { return { id: i, title: mock.notes[i].title }; })
        });
      },
      openNote: function (id) { global.console.log('[mock] openNote', id); return Promise.resolve({ success: true }); },
      loadAppState: function () { return Promise.resolve({ success: true, state: mock.state || {} }); },
      storeAppState: function (st) { mock.state = st; return Promise.resolve({ success: true }); },
      /*
       * Scripted, not simulated. Tests push canned answers - including bad ones
       * (prose, a fenced outline, an empty reply) - onto window.__CG_AI__ and
       * assert on what the app does with them. No model, no network.
       */
      chatAI: function (prompt, opts) {
        var queue = global.__CG_AI__;
        var answer;
        if (typeof queue === 'function') answer = queue(prompt, opts);
        else if (Array.isArray(queue) && queue.length) answer = queue.shift();
        (global.__CG_AI_PROMPTS__ = global.__CG_AI_PROMPTS__ || []).push(prompt);
        (global.__CG_AI_OPTS__ = global.__CG_AI_OPTS__ || []).push(opts || {});
        if (answer === undefined) {
          answer = '# Mock map\n\n## First theme\n- point one\n- point two\n\n## Second theme\n- point three\n';
        }
        if (answer && answer.__error) return Promise.resolve({ success: false, error: answer.__error });
        return new Promise(function (r) { setTimeout(function () { r({ success: true, response: answer }); }, 10); });
      }
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
      attachmentPaths: Array.isArray(n.attachmentPaths) ? n.attachmentPaths.slice() : [],
      isBlockScope: n.isBlockScope === true,
      parentNoteId: n.parentNoteId || null
    } : null;
  };

  /*
   * Attach one file to a note, optionally removing earlier ones in the same
   * write, so a replacement is one approval and never leaves two copies. The
   * host renames the saved file to <stem>_<uuid><ext>; always send the
   * human name, never a stored one, or a uuid is appended on every save.
   */
  HOST.attachFile = function (noteId, file, removePaths) {
    if (!S || !S.updateNotes) return Promise.reject(new Error('no host'));
    var attachments = { added: [{ type: 'base64', data: file.data, fileName: file.fileName, mimeType: file.mimeType || '' }] };
    if (removePaths && removePaths.length) attachments.removed = removePaths.slice();
    return S.updateNotes([{ id: noteId, modification: { attachments: attachments } }]).then(function (r) {
      if (!r || r.success === false) throw new Error((r && r.error) || 'the attachment was declined');
      if (r.errors && r.errors.length) throw new Error(r.errors[0]);
      if (r.updatedCount === 0) throw new Error('the attachment was declined');
      return true;
    });
  };

  /*
   * The files attached to a note, as [{ path, fileName }]. `path` is absolute
   * and is what Synapse.chatAI's `attachments` option takes; `fileName` is the
   * human name, for the prompt and the preview. exportNotes is the one API that
   * lists attachments for an arbitrary note (a block-scoped id resolves to its
   * parent's files there). If it is unavailable, the current note's own
   * attachmentPaths still serve - the host's basenames carry a uuid suffix, so
   * the name is tidied for display.
   */
  HOST.attachmentsOf = function (id) {
    var fromCurrent = function () {
      var n = HOST.note();
      if (!n || n.id !== id) return [];
      return (n.attachmentPaths || []).map(function (p) {
        var base = String(p).split('/').pop();
        var m = /^(.*)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(\.[^.]+)?$/i.exec(base);
        return { path: p, fileName: m ? m[1] + (m[2] || '') : base };
      });
    };
    if (!S || !S.exportNotes || !id) return Promise.resolve(fromCurrent());
    return S.exportNotes([id], { includeSubNotesAndLinkedNotes: false, includeAttachmentList: true })
      .then(function (r) {
        var note = r && r.success && Array.isArray(r.notes) ? r.notes[0] : null;
        if (!note || !Array.isArray(note.attachments)) return fromCurrent();
        return note.attachments.filter(function (a) { return a && a.path; }).map(function (a) {
          return { path: a.path, fileName: a.fileName || String(a.path).split('/').pop(), mimeType: a.mimeType || '' };
        });
      })
      .catch(fromCurrent);
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

  HOST.ai = function (prompt, options) {
    if (!S || !S.chatAI) return Promise.reject(new Error('AI is not available here'));
    var opts = { temperature: 0.2 };
    if (options) Object.keys(options).forEach(function (k) { opts[k] = options[k]; });
    return S.chatAI(prompt, opts).then(function (r) {
      if (!r || r.success === false) throw new Error((r && r.error) || 'the AI did not answer');
      var text = r.response;
      if (Array.isArray(text)) {
        text = text.map(function (p) { return typeof p === 'string' ? p : (p && p.text) || ''; }).join('\n');
      }
      if (typeof text !== 'string' || !text.trim()) throw new Error('the AI returned nothing');
      return text;
    });
  };

  HOST.loadState = function () {
    if (!S || !S.loadAppState) return Promise.resolve({});
    return S.loadAppState().then(function (r) {
      if (r && r.success && r.state) return r.state;
      return (r && typeof r === 'object' && !r.success) ? r : {};
    }).catch(function () { return {}; });
  };

  HOST.storeState = function (state) {
    if (!S || !S.storeAppState) return Promise.resolve();
    return S.storeAppState(state || {}).catch(function () {});
  };

  HOST.MAP_MARKER = '?via=cartograph';

  HOST.mapLink = function (id, title) {
    return '[\uD83D\uDDFA Mind map](synapseresource://note/' + sqlId(id) + HOST.MAP_MARKER + ')';
  };

  var RE_MAP_LINK = /\[[^\]]*\]\(\s*synapseresource:\/\/note\/([^)?\s]+)\?[^)]*via=cartograph[^)]*\)/i;
  HOST.RE_MAP_LINK = RE_MAP_LINK;

  HOST.mapIdIn = function (content) {
    var m = RE_MAP_LINK.exec(String(content == null ? '' : content));
    return m ? m[1] : null;
  };

  /*
   * Maps are found through the notes that link to them: the companion itself is
   * an ordinary note and carries no backlink, by design. A map nothing links to
   * is reachable through Recent and Browse instead.
   */
  HOST.findMaps = function () {
    return HOST.query(
      "SELECT id, title, content FROM notes WHERE content LIKE '%" + HOST.MAP_MARKER + "%'"
    ).then(function (rows) {
      var pairs = [], want = {};
      rows.forEach(function (r) {
        var id = HOST.mapIdIn(r.content);
        if (!id) return;
        pairs.push({ mapId: id, sourceId: r.id, sourceTitle: r.title });
        want[id] = true;
      });
      var ids = Object.keys(want);
      if (!ids.length) return [];
      return HOST.readNotes(ids).then(function (maps) {
        var byId = {};
        maps.forEach(function (m) { byId[m.id] = m; });
        return pairs.filter(function (p) { return byId[p.mapId]; }).map(function (p) {
          return {
            id: p.mapId,
            title: byId[p.mapId].title,
            content: byId[p.mapId].content,
            sourceId: p.sourceId,
            sourceTitle: p.sourceTitle
          };
        });
      });
    });
  };

  HOST.openNote = function (id) {
    if (!S || !S.openNote) return Promise.resolve();
    return S.openNote(id, false).catch(function () {});
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = CG;
})(typeof window !== 'undefined' ? window : globalThis);
