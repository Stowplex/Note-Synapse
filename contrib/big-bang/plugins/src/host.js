/*
 * Big Bang - the Synapse bridge, and the in-memory mock that stands in for it.
 *
 * Everything that touches the host app goes through here. With no Flutter
 * bridge present (a desktop browser, the dev harness, node) a mock takes over,
 * so the whole app is drivable without a phone.
 *
 * Six facts about the real API are encoded here rather than rediscovered:
 *
 *   - Raw note text comes from `runQuery`, never `exportNotes`.
 *     exportNotes returns a RENDERED share-export, with section labels and
 *     localised headings. It is not the note's text and must never be spliced.
 *   - The `notes` table is camelCase: id, title, content, type, createdAt,
 *     updatedAt, pinned, isArchived.
 *   - runQuery caps results at 100 rows and says so (`truncated`, `totalRows`).
 *     Anything that can exceed that pages with LIMIT/OFFSET.
 *   - Excerpts are truncated IN SQL (substr(content, 1, 400)). note.content is
 *     one of the columns the project flags as potentially huge, and a plain
 *     rawQuery has no chunked-TEXT handling. For the same reason every read of
 *     a whole note asks for length(content) alongside it and refuses a body
 *     that came back shorter than the column says it is.
 *   - updateNotes answers {success, updatedCount, errors?}. success:true only
 *     means the call ran; an entry can still be refused.
 *   - saveNotes answers {success, savedCount, savedNoteIds}. The ids come back
 *     in the order of the notes that SAVED, so an entry that was skipped makes
 *     savedNoteIds shorter than what went in and the positions stop lining up.
 *   - pickNotes returns REFERENCES: ids and titles, never content. Choosing
 *     nothing comes back as `cancelled`, and a context with no screen to show
 *     it on answers {success:false, error:'no_ui'}.
 *   - openMerge opens a screen the user drives. `cancelled:true` means no note
 *     came back - usually a back-out, sometimes a merge that saved and did not
 *     report - so it is never a retry signal. And `mergedNoteId` MAY be one of
 *     the ids that went in, because the merge screen's replace mode rewrites
 *     the first source in place.
 *   - A task's status in the notes table is 'todo' | 'in_progress' |
 *     'complete' | 'abandoned'. Not 'completed': the host parses anything it
 *     does not recognise as 'todo', so a near miss silently un-completes a
 *     task rather than failing.
 *   - chatAI answers with a STRING. There is no JSON mode and no schema mode,
 *     so anything read out of an answer is parsed out of prose, and a line
 *     that does not parse is dropped rather than failing the batch.
 *   - The host RENAMES every file it saves: generateUniqueFileName turns
 *     `x.png` into `x_<uuid>.png`, and both the attachments row's fileName and
 *     the basename of its filePath carry that uuid. So a file is always sent
 *     under its original name and a previous copy is found by that pattern -
 *     sending the stored name back grows a second uuid on every save.
 *   - A content `replace` with EMPTY text is meaningful and clears the note.
 *     note_modification_service.dart carves `replace` out of its empty-text
 *     no-op deliberately - "an empty replacement is meaningful: it clears the
 *     note" - so clearing a board needs no retry, no probe and no second write.
 *
 * And one rule that outranks all of them: a failed read ABORTS the save. There
 * is no fallback to a stale snapshot, because a content `replace` written from
 * one would destroy whatever the user typed in the real editor meanwhile.
 */
(function (global) {
  'use strict';
  var BB = (global.BB = global.BB || {});
  var BOARD = BB.board;
  var HOST = (BB.host = {});

  var S = global.Synapse;
  HOST.isMock = !(global.flutter_inappwebview && S);
  HOST.PAGE = 100;              // runQuery's row cap
  HOST.EXCERPT = 400;           // characters, truncated in SQL
  HOST.BOARDS = 24;             // boards on the home list, per read

  function sqlId(id) { return String(id == null ? '' : id).replace(/[^A-Za-z0-9_\-]/g, ''); }
  HOST.sqlId = sqlId;

  /* ------------------------------------------------------------------ mock */

  /*
   * The mock is a small note store plus a SQL-shaped reader. It is deliberately
   * unfriendly in the same places the real host is:
   *
   *   - runQuery returns at most 100 rows, with truncated/totalRows set.
   *   - updateNotes with a content `replace` of empty text CLEARS the note,
   *     exactly as the real host does; an empty append or prepend is the no-op.
   *   - mock.outsideEdit(...) runs just before the next read, which is how a
   *     test puts a concurrent editor between a load and a save.
   */
  function installMock(seed) {
    var mock = {
      notes: {},
      tags: {},                 // noteId -> [{ name, color }]
      // The relationships table, as far as a board can see it: one row per
      // link, and a removal takes out BOTH directions between the pair,
      // exactly as note_modification_service does.
      links: [],
      /*
       * The attachments table, as far as a board can see it: one row per file,
       * keyed by note. Every row is stored the way the host stores it - a
       * RELATIVE path under attachments/, and a fileName that is the basename
       * INCLUDING the uuid the host wedged in. That is the whole point of the
       * mock having this table at all: the host renames every saved file to
       * <stem>_<uuid><ext>, and a plugin that re-sent the stored name would
       * grow a second uuid on every export.
       */
      attachments: {},          // noteId -> [{ path, fileName, mimeType, createdAt }]
      seq: 0,
      attSeq: 0,
      uuidSeq: 0,
      queries: [],
      updates: [],
      saves: [],
      merges: [],
      picks: [],
      prompts: [],              // every prompt chatAI was given, in order
      rowCap: HOST.PAGE,
      pending: null
    };

    /*
     * A uuid, in shape only. The real one is random and this one counts, which
     * is what makes an export's stored name reproducible in a test; what
     * matters is that it MATCHES the pattern the host's generateUniqueFileName
     * produces, because recognising a previous export is a regex over exactly
     * that shape.
     */
    function fakeUuid() {
      var n = (++mock.uuidSeq).toString(16);
      function pad(s, w) { while (s.length < w) s = '0' + s; return s; }
      return pad(n, 8) + '-0000-4000-a000-' + pad(n, 12);
    }
    mock.fakeUuid = fakeUuid;

    /*
     * A file saved onto a note, renamed exactly as FileUtils does:
     * `<base>_<uuid><ext>`, stored relative to the app's attachments
     * directory, and listed under a fileName that is that basename - which is
     * what _insertAttachment writes into the column.
     */
    mock.attach = function (noteId, name, mime) {
      var n = String(name == null ? '' : name);
      var dot = n.lastIndexOf('.');
      var stem = dot > 0 ? n.slice(0, dot) : n;
      var ext = dot > 0 ? n.slice(dot) : '';
      var unique = stem + '_' + fakeUuid() + ext;
      var rec = {
        path: 'attachments/' + unique, fileName: unique,
        mimeType: String(mime == null ? '' : mime), createdAt: ++mock.attSeq
      };
      if (!mock.attachments[noteId]) mock.attachments[noteId] = [];
      mock.attachments[noteId].push(rec);
      return rec;
    };
    mock.filesOn = function (noteId) { return (mock.attachments[noteId] || []).slice(); };

    mock.put = function (note) {
      // A generated id must not land on one that is already taken. The board
      // note is usually 'mock-note-1', and a counter that started at zero
      // handed exactly that id to the first note a plugin created - which
      // replaced the board with a promoted sticky.
      var id = note.id;
      if (!id) { do { id = 'mock-note-' + (++mock.seq); } while (mock.notes[id]); }
      mock.notes[id] = {
        id: id,
        title: note.title || 'Untitled',
        content: note.content == null ? '' : String(note.content),
        // 'note' or 'task', exactly as the notes table spells it.
        type: note.type === 'task' ? 'task' : 'note',
        status: typeof note.status === 'string' ? note.status : null,
        // INTEGER NOT NULL DEFAULT 0 in the real schema, and 0/1 here for the
        // same reason: the board home filters archived notes out in SQL, and a
        // mock that had no such column could not show that it works.
        isArchived: note.isArchived ? 1 : 0,
        updatedAt: note.updatedAt || ('2026-01-01T00:00:' + String(Object.keys(mock.notes).length % 60 + 100).slice(1) + 'Z')
      };
      // Tags live in their own two tables, so the mock keeps them beside the
      // note rather than on it: a card's chips are a JOIN, not a column.
      mock.tags[id] = (Array.isArray(note.tags) ? note.tags : []).map(function (t) {
        if (typeof t === 'string') return { name: t, color: '' };
        return { name: String((t && t.name) || ''), color: String((t && t.color) || '') };
      }).filter(function (t) { return !!t.name; });
      return mock.notes[id];
    };
    mock.get = function (id) { return mock.notes[id] || null; };
    mock.content = function (id) { return mock.notes[id] ? mock.notes[id].content : null; };
    mock.setContent = function (id, text) {
      if (!mock.notes[id]) return null;
      mock.notes[id].content = String(text == null ? '' : text);
      return mock.notes[id];
    };
    /*
     * Schedule an edit made outside Big Bang. It fires just before the next
     * read, which is where a save's re-read finds it: the user typing in the
     * real editor while the board was open. (An edit landing in the gap
     * between the re-read and the write is a race nothing can win, and is not
     * what this models.)
     */
    mock.outsideEdit = function (fn) { mock.pending = fn; };
    mock.reset = function () {
      mock.queries.length = 0;
      mock.updates.length = 0;
      mock.saves.length = 0;
      mock.merges.length = 0;
      mock.picks.length = 0;
      mock.prompts.length = 0;
      mock.pending = null;
    };
    // The tag names on a note, which is what a board ever asks about.
    mock.tagNames = function (id) {
      return (mock.tags[id] || []).map(function (t) { return t.name; });
    };
    // Is there a relationship between these two notes, either way round?
    mock.linked = function (a, b) {
      return mock.links.some(function (l) {
        return (l.from === a && l.to === b) || (l.from === b && l.to === a);
      });
    };

    /*
     * Canned answers, so a test can drive a path the mock cannot reach on its
     * own: a cancelled merge, a write refused with updatedCount:0, a save that
     * came back with no ids. A function is called with the arguments; an array
     * is consumed one answer at a time and falls through to the mock when it
     * runs out.
     */
    function canned(scripted, arg) {
      if (typeof scripted === 'function') return scripted(arg);
      if (Array.isArray(scripted) && scripted.length) return scripted.shift();
      return undefined;
    }

    // What a scripted AI answer means, once it has arrived. A string is the
    // response text; anything else is the host's own reply object, passed
    // through untouched so a refusal can be scripted as one.
    function aiAnswer(scripted) {
      if (typeof scripted === 'string') return { success: true, response: scripted };
      return scripted;
    }

    // What a scripted picker answer means, once it has arrived - so that a
    // promised one and an immediate one are read by the same rules.
    function pickAnswer(scripted) {
      if (scripted && typeof scripted === 'object' && !Array.isArray(scripted) &&
          (scripted.success !== undefined || scripted.cancelled !== undefined || scripted.notes !== undefined)) {
        return scripted;
      }
      if (scripted === undefined || scripted === null) return { success: true, cancelled: true, notes: [] };
      var list = Array.isArray(scripted) ? scripted : [scripted];
      var notes = list.map(function (n) {
        var id = typeof n === 'string' ? n : String((n && n.id) || '');
        var rec = mock.notes[id];
        if (!rec) return null;
        return { id: rec.id, title: rec.title };
      }).filter(Boolean);
      if (!notes.length) return { success: true, cancelled: true, notes: [] };
      return { success: true, notes: notes };
    }

    (seed || []).forEach(mock.put);
    if (!Object.keys(mock.notes).length) {
      mock.put({ id: 'mock-note-1', title: 'Sprint planning', content: '# Sprint planning\n\nWe agreed to cut scope on the importer.\n' });
      mock.put({ id: 'mock-note-2', title: 'Interview script', content: '## Warm up\n- Tell me about your week.\n' });
      mock.put({ id: 'mock-note-3', title: 'Pricing', content: 'Three tiers, annual only.\n' });
    }

    /* ---- a SQL-shaped reader, not a SQL engine ---- */

    function projection(sql) {
      var m = /^\s*select\s+([\s\S]+?)\s+from\s+notes/i.exec(sql);
      if (!m) return null;
      return m[1].split(/,(?![^(]*\))/).map(function (part) {
        var p = part.trim();
        var as = /\s+as\s+([A-Za-z_][A-Za-z0-9_]*)\s*$/i.exec(p);
        var name = as ? as[1] : p;
        if (as) p = p.slice(0, as.index).trim();
        var sub = /^substr\s*\(\s*([A-Za-z_]+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)$/i.exec(p);
        if (sub) return { name: name, col: sub[1], from: parseInt(sub[2], 10), len: parseInt(sub[3], 10) };
        var len = /^length\s*\(\s*([A-Za-z_]+)\s*\)$/i.exec(p);
        if (len) return { name: name, col: len[1], measure: true };
        /*
         * How many times a literal occurs in a column, counted the way SQLite
         * can count it: the length lost by replacing it with nothing, divided
         * by its own length. It is what the board home uses to say how many
         * cards a board has without hauling anybody's note across the bridge,
         * and the mock recognises the exact shape rather than evaluating SQL.
         */
        var occ = /^\(\s*length\s*\(\s*([A-Za-z_]+)\s*\)\s*-\s*length\s*\(\s*replace\s*\(\s*([A-Za-z_]+)\s*,\s*'((?:[^']|'')*)'\s*,\s*''\s*\)\s*\)\s*\)\s*\/\s*(\d+)$/i.exec(p);
        if (occ && occ[1] === occ[2]) {
          return { name: name, col: occ[1], needle: occ[3].replace(/''/g, "'"), div: parseInt(occ[4], 10) };
        }
        return { name: name, col: p };
      });
    }

    function rowsFor(sql) {
      var all = Object.keys(mock.notes).map(function (k) { return mock.notes[k]; });
      var inList = /where[\s\S]*?\bid\s+in\s*\(([^)]*)\)/i.exec(sql);
      var eq = /where[\s\S]*?\bid\s*=\s*'([^']*)'/i.exec(sql);
      var like = /where[\s\S]*?\bcontent\s+like\s+'%([^%']*)%'/i.exec(sql);
      if (inList) {
        var want = {};
        inList[1].split(',').forEach(function (x) { want[x.trim().replace(/^'|'$/g, '')] = 1; });
        all = all.filter(function (n) { return want[n.id]; });
      } else if (eq) {
        all = all.filter(function (n) { return n.id === eq[1]; });
      } else if (like) {
        all = all.filter(function (n) { return n.content.indexOf(like[1]) >= 0; });
      }
      // The one other predicate the mock understands, because the board home
      // depends on it: an archived note is not offered as a board.
      if (/\bisArchived\s*=\s*0\b/i.test(sql)) {
        all = all.filter(function (n) { return !n.isArchived; });
      }
      var order = /order\s+by\s+([A-Za-z_]+)\s*(desc|asc)?/i.exec(sql);
      if (order) {
        var col = order[1], dir = (order[2] || 'asc').toLowerCase() === 'desc' ? -1 : 1;
        all.sort(function (a, b) {
          var x = a[col], y = b[col];
          return (x < y ? -1 : x > y ? 1 : 0) * dir;
        });
      } else {
        all.sort(function (a, b) { return a.id < b.id ? -1 : a.id > b.id ? 1 : 0; });
      }
      var lim = /limit\s+(\d+)/i.exec(sql), off = /offset\s+(\d+)/i.exec(sql);
      if (off) all = all.slice(parseInt(off[1], 10));
      if (lim) all = all.slice(0, parseInt(lim[1], 10));
      return all;
    }

    /*
     * The one join the mock knows: note_tags against tags. It is not a query
     * planner - it recognises the shape readTags asks for, applies the id list,
     * and pages it exactly as the notes reader does, because a board of many
     * tagged notes is precisely where the 100-row cap bites.
     */
    function tagRowsFor(sql) {
      var want = null;
      var inList = /where[\s\S]*?noteId\s+in\s*\(([^)]*)\)/i.exec(sql);
      if (inList) {
        want = {};
        inList[1].split(',').forEach(function (x) { want[x.trim().replace(/^'|'$/g, '')] = 1; });
      }
      var rows = [];
      Object.keys(mock.notes).sort().forEach(function (id) {
        if (want && !want[id]) return;
        (mock.tags[id] || []).slice().sort(function (a, b) {
          return a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
        }).forEach(function (t) {
          rows.push({ noteId: id, name: t.name, color: t.color });
        });
      });
      return rows;
    }

    /*
     * The attachments table, read the one way a board reads it: the files on
     * one note, oldest first. Like tagRowsFor this recognises the shape rather
     * than evaluating SQL, and it pages the same way, because a note with more
     * than a hundred files is a note whose export would otherwise not be found.
     */
    function attachmentRowsFor(sql) {
      var want = null;
      var eqNote = /where[\s\S]*?\bnoteId\s*=\s*'([^']*)'/i.exec(sql);
      var inNote = /where[\s\S]*?\bnoteId\s+in\s*\(([^)]*)\)/i.exec(sql);
      if (eqNote) { want = {}; want[eqNote[1]] = 1; }
      else if (inNote) {
        want = {};
        inNote[1].split(',').forEach(function (x) { want[x.trim().replace(/^'|'$/g, '')] = 1; });
      }
      var rows = [];
      Object.keys(mock.attachments).sort().forEach(function (id) {
        if (want && !BOARD.has(want, id)) return;
        mock.attachments[id].slice().sort(function (a, b) { return a.createdAt - b.createdAt; })
          .forEach(function (a) {
            rows.push({ noteId: id, filePath: a.path, fileName: a.fileName });
          });
      });
      return rows;
    }

    /*
     * A task status, parsed the way the host parses it.
     *
     * The notes table spells the four states 'todo', 'in_progress', 'complete'
     * and 'abandoned', and _mergeNoteData turns ANYTHING else into 'todo'.
     * That default is why this is faithful rather than lenient: a plugin that
     * sends 'completed' is not refused, it silently un-completes the task, and
     * a mock that quietly accepted the near miss would hide it.
     */
    var STATUS = { todo: 1, in_progress: 1, complete: 1, abandoned: 1 };
    function taskStatus(v) {
      var s = String(v == null ? '' : v).toLowerCase();
      return BOARD.has(STATUS, s) ? s : 'todo';
    }

    /*
     * Granular modification mode, over the fields the host recognises:
     * content, title, tags, link, attachments, subnote. A modification naming
     * NONE of them is a silent success rather than an error - the host's own
     * isNoOpModification carves that out deliberately - and every recognised
     * field in one object is applied, because the host applies them all.
     *
     * -> true, or the host's own message for an entry it refused.
     */
    function applyModification(n, mod) {
      if (mod.content && typeof mod.content === 'object') {
        var action = mod.content.action || 'replace';
        var text = mod.content.text == null ? '' : String(mod.content.text);
        // Empty append/prepend is a no-op; an empty REPLACE clears the note.
        // note_modification_service.dart:509 makes that distinction
        // explicitly, and it is the whole reason clearing a board works.
        if (!(text === '' && action !== 'replace')) {
          if (action === 'append') n.content = n.content + '\n' + text;
          else if (action === 'prepend') n.content = text + '\n' + n.content;
          else n.content = text;
        }
      }
      if (mod.title && typeof mod.title === 'object' && typeof mod.title.new_title === 'string') {
        n.title = mod.title.new_title;
      }
      if (mod.tags && typeof mod.tags === 'object') {
        var have = mock.tags[n.id] || (mock.tags[n.id] = []);
        (mod.tags.added || []).forEach(function (t) {
          var name = String(t == null ? '' : t);
          if (!name) return;
          var dup = have.some(function (x) { return x.name === name; });
          if (!dup) have.push({ name: name, color: '' });
        });
        (mod.tags.removed || []).forEach(function (t) {
          var name = String(t == null ? '' : t);
          mock.tags[n.id] = mock.tags[n.id].filter(function (x) { return x.name !== name; });
          have = mock.tags[n.id];
        });
      }
      if (mod.link) {
        var added = Array.isArray(mod.link) ? mod.link : (mod.link.added || []);
        var removed = Array.isArray(mod.link) ? [] : (mod.link.removed || []);
        added.forEach(function (l) {
          if (!l || typeof l !== 'object' || typeof l.target !== 'string') return;
          // No de-duplication: the host inserts a row per call, which is why a
          // board must not offer to write the same relationship twice.
          mock.links.push({ from: n.id, to: l.target, type: l.relation || 'related' });
        });
        removed.forEach(function (target) {
          var t = String(target == null ? '' : target);
          // BOTH directions, exactly as the host's delete does.
          mock.links = mock.links.filter(function (l) {
            return !((l.from === n.id && l.to === t) || (l.from === t && l.to === n.id));
          });
        });
      }
      /*
       * Attachments, added and removed, exactly as the host applies them.
       *
       *   `added` takes a base64 object - {type, data, fileName} - and the
       *   file lands under a name the HOST chose: processAttachment hands the
       *   bytes to saveFileToPrivateStorage, which appends a uuid to the stem.
       *   It also takes a plain path string, and that one is VERIFIED: an
       *   attachment path the database does not know throws, and the whole
       *   entry fails. A mock that accepted any string would hide the one
       *   mistake this API invites - echoing back the stored name of a file
       *   that has already been renamed once.
       *
       *   `removed` is matched against the stored path, which is the relative
       *   one, because that is what the note's attachmentPaths hold.
       */
      if (mod.attachments && typeof mod.attachments === 'object') {
        var mine = mock.attachments[n.id] || (mock.attachments[n.id] = []);
        var bad = null;
        (mod.attachments.added || []).forEach(function (a) {
          if (bad) return;
          if (a && typeof a === 'object' && a.type === 'base64' &&
              typeof a.data === 'string' && a.data && typeof a.fileName === 'string' && a.fileName) {
            mock.attach(n.id, a.fileName, a.mimeType || '');
            return;
          }
          if (typeof a === 'string' && a) {
            var known = mine.some(function (x) { return x.path === a; });
            if (!known) bad = 'Invalid attachment path: ' + a + ' - file not found in database';
            return;
          }
          bad = 'Invalid attachment format: ' + JSON.stringify(a);
        });
        if (bad) return bad;
        (mod.attachments.removed || []).forEach(function (p) {
          var want = String(p == null ? '' : p);
          mock.attachments[n.id] = (mock.attachments[n.id] || []).filter(function (x) { return x.path !== want; });
        });
      }
      // Recognised or not, the host counts it: a modification naming none of
      // the fields it knows is a silent no-op SUCCESS, not a refusal.
      return true;
    }

    global.Synapse = S = {
      Notes: [],
      Params: {},
      locale: (global.navigator && global.navigator.language) || 'en-US',
      __mock: mock,
      runQuery: function (sql) {
        if (mock.pending) { var edit = mock.pending; mock.pending = null; edit(mock); }
        mock.queries.push(sql);
        var scripted = global.__BB_QUERY__;
        var canned = typeof scripted === 'function' ? scripted(sql)
          : (Array.isArray(scripted) && scripted.length ? scripted.shift() : undefined);
        if (canned !== undefined && canned !== null) return Promise.resolve(canned);
        if (!/^\s*select\b/i.test(sql)) return Promise.resolve({ success: false, error: 'the mock only reads' });
        if (/\bfrom\s+note_tags\b/i.test(sql)) {
          var tagged = tagRowsFor(sql);
          var tOff = /offset\s+(\d+)/i.exec(sql), tLim = /limit\s+(\d+)/i.exec(sql);
          var tTotal = tagged.length;
          if (tOff) tagged = tagged.slice(parseInt(tOff[1], 10));
          tagged = tagged.slice(0, Math.min(mock.rowCap, tLim ? parseInt(tLim[1], 10) : mock.rowCap));
          var tOut = { success: true, data: tagged };
          if (tTotal > mock.rowCap) { tOut.truncated = true; tOut.totalRows = tTotal; }
          return Promise.resolve(tOut);
        }
        if (/\bfrom\s+attachments\b/i.test(sql)) {
          var files = attachmentRowsFor(sql);
          var aOff = /offset\s+(\d+)/i.exec(sql), aLim = /limit\s+(\d+)/i.exec(sql);
          var aTotal = files.length;
          if (aOff) files = files.slice(parseInt(aOff[1], 10));
          files = files.slice(0, Math.min(mock.rowCap, aLim ? parseInt(aLim[1], 10) : mock.rowCap));
          var aOut = { success: true, data: files };
          if (aTotal > mock.rowCap) { aOut.truncated = true; aOut.totalRows = aTotal; }
          return Promise.resolve(aOut);
        }
        var cols = projection(sql);
        if (!cols) return Promise.resolve({ success: false, error: 'the mock could not parse that query' });
        var matched = rowsFor(sql);
        var total = matched.length;
        var page = matched.slice(0, mock.rowCap);
        var data = page.map(function (n) {
          var row = {};
          cols.forEach(function (c) {
            var v = n[c.col];
            if (v === undefined) v = null;
            // SQLite's length() counts characters, not UTF-16 code units, so
            // the mock does too: a note of emoji measures shorter here than
            // JS's own .length, which is exactly why the guard on the other
            // side of this is one-sided.
            if (c.measure) v = typeof v === 'string' ? Array.from(v).length : null;
            else if (c.needle) {
              // Exactly the arithmetic the SQL does, so a mistake in the
              // divisor shows up here as a wrong count rather than being
              // quietly agreed with.
              var s = typeof v === 'string' ? v : '';
              var lost = Array.from(s).length - Array.from(s.split(c.needle).join('')).length;
              v = c.div > 0 ? Math.floor(lost / c.div) : 0;
            } else if (c.len && typeof v === 'string') v = v.substr(c.from - 1, c.len);
            row[c.name] = v;
          });
          return row;
        });
        var out = { success: true, data: data };
        if (total > mock.rowCap) { out.truncated = true; out.totalRows = total; }
        return Promise.resolve(out);
      },
      updateNotes: function (list) {
        mock.updates.push(JSON.parse(JSON.stringify(list)));
        var scripted = canned(global.__BB_UPDATE__, list);
        if (scripted !== undefined && scripted !== null) return Promise.resolve(scripted);
        var updated = 0, errors = [];
        (list || []).forEach(function (u) {
          var n = u && u.id ? mock.notes[u.id] : null;
          if (!n) { errors.push('Note not found: ' + (u && u.id)); return; }
          if (u.modification && typeof u.modification === 'object') {
            var applied = applyModification(n, u.modification);
            if (applied === true) updated++;
            else errors.push(String(applied));
            return;
          }
          // Full replacement: every field PRESENT replaces its value, and the
          // rest of the note is left as it was.
          var touched = false;
          if (typeof u.content === 'string') { n.content = u.content; touched = true; }
          if (typeof u.title === 'string') { n.title = u.title; touched = true; }
          if (typeof u.type === 'string') { n.type = u.type === 'task' ? 'task' : 'note'; touched = true; }
          if (u.status != null) { n.status = taskStatus(u.status); touched = true; }
          if (Array.isArray(u.tags)) {
            mock.tags[n.id] = u.tags.map(function (t) {
              return typeof t === 'string' ? { name: t, color: '' } : { name: String((t && t.name) || ''), color: '' };
            }).filter(function (t) { return !!t.name; });
            touched = true;
          }
          if (touched) updated++;
          else errors.push('Nothing to change on ' + u.id);
        });
        var res = { success: true, updatedCount: updated };
        if (errors.length) res.errors = errors;
        return Promise.resolve(res);
      },
      saveNotes: function (list) {
        mock.saves.push(JSON.parse(JSON.stringify(list || [])));
        var scripted = canned(global.__BB_SAVE__, list);
        if (scripted !== undefined && scripted !== null) return Promise.resolve(scripted);
        var ids = [];
        (list || []).forEach(function (n) {
          if (!n || typeof n !== 'object') return;
          ids.push(mock.put({ title: n.title, content: n.content, type: n.type, status: n.status }).id);
        });
        // savedCount is savedNoteIds.length, and an entry that did not save is
        // simply absent - the positions do not line up with what went in.
        return Promise.resolve({ success: true, savedCount: ids.length, savedNoteIds: ids });
      },

      /*
       * The merge screen, as far as a plugin can see it.
       *
       * The default merge here CREATES a note, which is only one of the two
       * things the real screen does: replace mode rewrites the FIRST source in
       * place and hands back that source's own id. Both have to be drivable,
       * so `window.__BB_MERGE__` scripts the answer - including a cancel, an
       * error, and the id of a source, which is the case a board gets wrong by
       * adding a second card for a note it already draws.
       */
      openMerge: function (notes) {
        var ids = (notes || []).map(function (n) {
          return typeof n === 'string' ? n : String((n && n.id) || '');
        }).filter(Boolean);
        var seen = Object.create(null), distinct = [];
        ids.forEach(function (id) { if (!BOARD.has(seen, id)) { seen[id] = 1; distinct.push(id); } });
        mock.merges.push(distinct.slice());
        var scripted = canned(global.__BB_MERGE__, distinct.slice());
        if (scripted !== undefined && scripted !== null) return Promise.resolve(scripted);
        // The host counts DISTINCT notes, not entries: a repeated id and a set
        // of block ids from one note both collapse to one source.
        if (distinct.length < 2) {
          return Promise.resolve({
            success: false,
            error: 'openMerge needs at least two notes; ' + ids.length + ' entries resolved to ' +
              distinct.length + ' distinct note(s)'
          });
        }
        var live = distinct.filter(function (id) { return !!mock.notes[id]; });
        if (live.length < 2) return Promise.resolve({ success: false, error: 'openMerge needs at least two notes' });
        var merged = mock.put({
          title: 'Merged: ' + live.map(function (id) { return mock.notes[id].title; }).join(' + '),
          content: live.map(function (id) { return mock.notes[id].content; }).join('\n\n')
        });
        return Promise.resolve({ success: true, mergedNoteId: merged.id });
      },
      /*
       * The native multi-note picker, as far as a plugin can see it: it hands
       * back REFERENCES - ids and titles - and never content.
       *
       * Scripted through `window.__BB_PICK__`, because there is no picker in a
       * browser and a prompt() in a headless run hangs the suite. A function or
       * an array may return a list of ids, a list of {id,title}, or one of the
       * host's own answers ({cancelled:true}, {success:false,error:'no_ui'});
       * with nothing scripted the mock cancels, which is the answer that
       * changes nothing.
       *
       * It may also return a PROMISE of any of those, exactly as __BB_MERGE__
       * may - a picker that stays open until the test says otherwise. The real
       * one is a screen the user drives, and what the board does across that
       * window is the whole reason there is a guard on the answer.
       */
      pickNotes: function (options) {
        mock.picks.push(options || {});
        var scripted = canned(global.__BB_PICK__, options || {});
        if (scripted && typeof scripted.then === 'function') {
          return Promise.resolve(scripted).then(pickAnswer);
        }
        return Promise.resolve(pickAnswer(scripted));
      },
      /*
       * The app's AI channel, as far as a plugin can see it: a prompt in, a
       * string out, and no schema mode of any kind.
       *
       * Scripted through `window.__BB_AI__`, and SCRIPTED rather than
       * simulated on purpose. The interesting answers are the bad ones - an
       * answer with no parseable line in it, one naming cards that are not on
       * the board, one that is a refusal, one that never arrives - and a mock
       * that invented plausible answers could produce none of them on demand.
       * A bare string is the response and stands for every call; an object is
       * the whole reply; an ARRAY is consumed one answer at a time, like every
       * other scripting hook here; a promise is an answer that has not come
       * back yet, which is how a timeout is driven. With nothing scripted the
       * mock declines, because a browser has no model behind it and pretending
       * otherwise is the one answer that would make the fallback path
       * untestable.
       */
      chatAI: function (prompt, options) {
        var text = String(prompt == null ? '' : prompt);
        mock.prompts.push(text);
        var scripted = global.__BB_AI__;
        if (typeof scripted === 'function') scripted = scripted({ prompt: text, options: options || {} });
        else if (Array.isArray(scripted)) scripted = scripted.length ? scripted.shift() : undefined;
        if (scripted === undefined || scripted === null) {
          return Promise.resolve({ success: false, error: 'no model is configured for this mock' });
        }
        if (scripted && typeof scripted.then === 'function') return Promise.resolve(scripted).then(aiAnswer);
        return Promise.resolve(aiAnswer(scripted));
      },
      openNote: function (id) { return Promise.resolve({ success: true, id: id }); },
      loadAppState: function () { return Promise.resolve({ success: true, state: mock.state || {} }); },
      storeAppState: function (st) { mock.state = st; return Promise.resolve({ success: true }); }
    };
    HOST.mock = mock;
    return mock;
  }
  HOST.installMock = installMock;

  if (HOST.isMock) {
    var seedNotes = null, standalone = false, params = {};
    try {
      var qp = new URLSearchParams(global.location ? global.location.search : '');
      standalone = qp.has('standalone');
      var md = qp.get('board');
      if (md !== null) seedNotes = [{ id: 'mock-note-1', title: 'Sprint planning', content: md }];
      // ?seed=[{id,title,content}] puts the OTHER notes in the store - the ones
      // a board's cards point at. Without it a seeded board resolves to nothing
      // but tombstones, since ?board= replaces the default three notes.
      var seed = qp.get('seed');
      if (seed) {
        try {
          var extra = JSON.parse(seed);
          if (Array.isArray(extra)) {
            seedNotes = seedNotes || [];
            extra.forEach(function (n) { if (n && typeof n === 'object') seedNotes.push(n); });
          }
        } catch (e2) { /* a harness typo is not worth a broken boot */ }
      }
      /*
       * Everything else on the URL becomes Synapse.Params, which is how the
       * real host delivers an embed's query string - so `?mode=embed` and
       * `?standalone=1` reach the app exactly as they would on a phone.
       *
       * `board` is the one name the two interfaces disagree about. On the URL
       * it is the harness's own control - the MARKDOWN of the note to open,
       * per the convention M2 established and every dev page still uses - and
       * to the app it is the note ID to open (§ Two apps, one HTML). So the
       * harness spells the app's one `?boardId=`, and it arrives as
       * Params.board, which is the only name app.js ever reads.
       */
      qp.forEach(function (v, k) {
        if (k === 'board' || k === 'seed' || k === 'boardId' || k === 'notes') return;
        params[k] = v;
      });
      if (qp.get('boardId')) params.board = qp.get('boardId');
    } catch (e) { /* not in a browser */ }
    var m = installMock(seedNotes);
    S.Params = params;
    S.locale = params.locale || S.locale || 'en-US';
    global.setLocale = function (tag) {
      S.locale = tag;
      if (typeof global.dispatchEvent === 'function' && typeof global.CustomEvent === 'function') {
        global.dispatchEvent(new global.CustomEvent('synapse:localechanged', { detail: tag }));
      }
    };
    /*
     * What the app was LAUNCHED with, which is a different thing from what is
     * in the store. `?notes=a,b,c` is how the harness arrives as a note-action
     * launch on a multi-selection - the case that makes a new board out of all
     * of them - since a browser has no note list to select in.
     */
    var picked = null;
    try {
      var want = new URLSearchParams(global.location ? global.location.search : '').get('notes');
      if (want) {
        picked = want.split(',').map(function (id) { return m.notes[id.trim()]; }).filter(Boolean);
      }
    } catch (e2) { /* not in a browser */ }
    /*
     * ?standalone=1 drops the note, which is how a `normal` launch arrives.
     * An explicit ?notes= outranks it, so that the two can be given TOGETHER -
     * which is the only way to drive the row of the launch table that says
     * `?standalone=1` forces the home even with a note in hand.
     */
    var first = m.notes['mock-note-1'] || m.notes[Object.keys(m.notes)[0]];
    if (picked && picked.length) {
      S.Notes = picked.map(function (n) {
        return { id: n.id, title: n.title, content: n.content, tags: [] };
      });
    } else {
      S.Notes = (standalone || !first) ? [] : [{ id: first.id, title: first.title, content: first.content, tags: [] }];
    }
  }

  /* ------------------------------------------------------------------- api */

  HOST.notes = function () {
    return ((S && S.Notes) || []).map(function (n) {
      return {
        id: n.id,
        title: n.title || '',
        content: n.content || '',
        tags: n.tags || [],
        isBlockScope: n.isBlockScope === true,
        parentNoteId: n.parentNoteId || null
      };
    });
  };

  HOST.note = function () { return HOST.notes()[0] || null; };
  HOST.params = function () { return (S && S.Params) || {}; };

  /*
   * query(sql) -> { ok, rows, truncated, totalRows, error }
   *
   * `ok:false` is a real failure and callers must treat it as one: an empty
   * `rows` on a failed read looks exactly like a note with no content, and
   * confusing the two is how a board gets written over somebody's text.
   */
  HOST.query = function (sql) {
    if (!S || !S.runQuery) return Promise.resolve({ ok: false, rows: [], error: 'no host' });
    return S.runQuery(sql).then(function (r) {
      if (!r || r.success === false) return { ok: false, rows: [], error: (r && r.error) || 'the query failed' };
      return {
        ok: true,
        rows: Array.isArray(r.data) ? r.data : [],
        truncated: r.truncated === true,
        totalRows: typeof r.totalRows === 'number' ? r.totalRows : null
      };
    }).catch(function (e) {
      return { ok: false, rows: [], error: String((e && e.message) || e) };
    });
  };

  /*
   * Page past the 100-row cap. `sqlFor(limit, offset)` builds each page; the
   * loop stops when a page comes back short. `pages` is a sanity bound, not a
   * policy: a board that needs more than 5000 rows has a different problem.
   * Stopping on the bound sets `capped`, so a caller can tell a complete
   * answer from one that ran out of patience.
   */
  HOST.queryAll = function (sqlFor, opts) {
    opts = opts || {};
    var limit = opts.limit || HOST.PAGE, maxPages = opts.pages || 50;
    var rows = [], offset = 0, pages = 0;
    function step() {
      return HOST.query(sqlFor(limit, offset)).then(function (r) {
        if (!r.ok) return { ok: false, rows: rows, error: r.error };
        rows = rows.concat(r.rows);
        pages++;
        if (r.rows.length < limit || pages >= maxPages) return { ok: true, rows: rows, pages: pages, capped: pages >= maxPages && r.rows.length === limit };
        offset += limit;
        return step();
      });
    }
    return step();
  };

  /*
   * The raw markdown of one note, straight out of the table.
   * -> { ok: true, content } | { ok: false, error }
   *
   * length(content) comes back with it and is checked. note.content is one of
   * the columns the project flags as very large, and every save turns whatever
   * this returns into a whole-body `replace`: a body that arrived short would
   * be written back as the note, silently dropping the tail. The comparison is
   * one-sided on purpose - SQLite counts characters and JS counts UTF-16 code
   * units, so a note full of emoji reads LONGER than the column measures and
   * only a genuinely short read trips the guard.
   */
  HOST.readContent = function (id) {
    var clean = sqlId(id);
    if (!clean) return Promise.resolve({ ok: false, error: 'no note id' });
    return HOST.query("SELECT id, content, length(content) AS clen FROM notes WHERE id = '" + clean + "' LIMIT 1").then(function (r) {
      if (!r.ok) return { ok: false, error: r.error };
      if (!r.rows.length) return { ok: false, error: 'the note could not be read' };
      var c = r.rows[0].content;
      var text = typeof c === 'string' ? c : '';
      var clen = r.rows[0].clen;
      if (typeof clen === 'number' && text.length < clen) {
        return { ok: false, error: 'the note came back truncated (' + text.length + ' of ' + clen + ' characters)' };
      }
      return { ok: true, content: text };
    });
  };

  /*
   * One note's title, and nothing else about it. -> the title, or ''.
   *
   * Deliberately NOT readExcerpts: this is the board note, which is not a card
   * and whose body nothing draws, and `substr(content, ...)` on it would be a
   * read of somebody's note to fill in a bar.
   */
  HOST.readTitle = function (id) {
    var clean = sqlId(id);
    if (!clean) return Promise.resolve('');
    return HOST.query("SELECT id, title FROM notes WHERE id = '" + clean + "' LIMIT 1").then(function (r) {
      if (!r.ok || !r.rows.length) return '';
      return typeof r.rows[0].title === 'string' ? r.rows[0].title : '';
    });
  };

  /*
   * Titles and bounded excerpts for a list of notes, for the cards. Truncated
   * in SQL, chunked so no single IN-list can exceed the row cap, and paged
   * within each chunk in case it does anyway.
   * -> { ok, rows: [{id, title, type, status, excerpt}], missing: [id] }
   *
   * `type` and `status` are plain, small columns on the same row - the notes
   * table spells type as 'note' or 'task' and status as the task's own state -
   * so a card can show the task marker the plan asks for without a second
   * query. Only `content` is ever large, and only `content` is truncated.
   */
  HOST.readExcerpts = function (ids, opts) {
    opts = opts || {};
    var chars = opts.chars || HOST.EXCERPT;
    var clean = [], seen = Object.create(null);
    (ids || []).forEach(function (i) {
      var c = sqlId(i);
      if (c && !BOARD.has(seen, c)) { seen[c] = 1; clean.push(c); }
    });
    if (!clean.length) return Promise.resolve({ ok: true, rows: [], missing: [] });

    var chunks = [];
    for (var i = 0; i < clean.length; i += HOST.PAGE) chunks.push(clean.slice(i, i + HOST.PAGE));

    var rows = [];
    function step(k) {
      if (k >= chunks.length) {
        var got = Object.create(null);
        rows.forEach(function (r) { got[r.id] = 1; });
        return Promise.resolve({
          ok: true, rows: rows,
          missing: clean.filter(function (id) { return !BOARD.has(got, id); })
        });
      }
      var list = chunks[k].map(function (x) { return "'" + x + "'"; }).join(',');
      return HOST.queryAll(function (limit, offset) {
        return 'SELECT id, title, type, status, substr(content, 1, ' + chars + ') AS excerpt FROM notes' +
          ' WHERE id IN (' + list + ') ORDER BY id LIMIT ' + limit + ' OFFSET ' + offset;
      }).then(function (r) {
        if (!r.ok) return { ok: false, rows: rows, error: r.error };
        rows = rows.concat(r.rows);
        return step(k + 1);
      });
    }
    return step(0);
  };

  /*
   * The tags on a list of notes, for the chips on their cards.
   * -> { ok, rows: [{noteId, name, color}], error }
   *
   * A genuine second query: tags are two tables away (note_tags ⋈ tags) and no
   * projection of `notes` can reach them. It follows readExcerpts' discipline
   * for the same reasons - the ids are chunked so one IN-list can never exceed
   * the row cap, and each chunk is paged, because the ROW count here is not the
   * note count: thirty notes with four tags each is a hundred and twenty rows
   * out of a query that stops at a hundred, and the notes that fell off the end
   * would silently lose their chips.
   *
   * Nothing here is load-bearing. Tags are decoration on a card, so a caller
   * that gets `ok:false` draws the board without them rather than failing.
   */
  HOST.readTags = function (ids) {
    var clean = [], seen = Object.create(null);
    (ids || []).forEach(function (i) {
      var c = sqlId(i);
      if (c && !BOARD.has(seen, c)) { seen[c] = 1; clean.push(c); }
    });
    if (!clean.length) return Promise.resolve({ ok: true, rows: [] });

    var chunks = [];
    for (var i = 0; i < clean.length; i += HOST.PAGE) chunks.push(clean.slice(i, i + HOST.PAGE));

    var rows = [];
    function step(k) {
      if (k >= chunks.length) return Promise.resolve({ ok: true, rows: rows });
      var list = chunks[k].map(function (x) { return "'" + x + "'"; }).join(',');
      return HOST.queryAll(function (limit, offset) {
        return 'SELECT nt.noteId AS noteId, t.name AS name, t.color AS color' +
          ' FROM note_tags nt JOIN tags t ON t.id = nt.tagId' +
          ' WHERE nt.noteId IN (' + list + ') ORDER BY nt.noteId, t.name LIMIT ' + limit + ' OFFSET ' + offset;
      }).then(function (r) {
        if (!r.ok) return { ok: false, rows: rows, error: r.error };
        rows = rows.concat(r.rows);
        return step(k + 1);
      });
    }
    return step(0);
  };

  /*
   * The board home's own read: every note that holds a board block, most
   * recently touched first.
   * -> { ok, boards: [{ id, title, updatedAt, cards }], more, counts, error }
   *
   * Three things about it are deliberate.
   *
   *   The row cap is respected by construction. It asks for ONE more row than
   *   it will show, so `more` is the honest answer to "is this the whole list"
   *   without a second query and without ever approaching a hundred rows. A
   *   caller wanting more asks again with a bigger limit; nothing here pages
   *   blindly through a table that could be the user's whole library.
   *
   *   The card count is computed IN SQL and costs no content. note.content is
   *   one of the columns the project flags as potentially huge, and a home
   *   screen that read thirty boards' bodies to print "8 cards" would be the
   *   most expensive screen in the app. `length(x) - length(replace(x, lit,
   *   ''))` over the literal an item's `k` field is written as counts the
   *   occurrences and returns an integer. It is an estimate in one direction
   *   only: a note that QUOTES the format in prose counts it too. A count is a
   *   hint on a row, and a wrong hint costs a glance, so that is a fair trade
   *   for not reading the library.
   *
   *   And it falls back. The count expression is more SQL than anything else
   *   here asks of the host, and the host classifies a query it cannot parse
   *   as a WRITE - which would put an approval dialog in front of a list. If
   *   the counted query fails for any reason the plain one runs instead and
   *   the rows come back with `cards: null`, which the home draws as no count
   *   rather than as zero.
   */
  function boardSql(limit, offset, counts) {
    var cols = 'id, title, updatedAt';
    if (counts) {
      cols += ", (length(content) - length(replace(content, '\"k\":\"note\"', ''))) / 10 AS notes" +
        ", (length(content) - length(replace(content, '\"k\":\"sticky\"', ''))) / 12 AS stickies";
    }
    return 'SELECT ' + cols + ' FROM notes' +
      " WHERE content LIKE '%" + BOARD.INFO + "%' AND isArchived = 0" +
      ' ORDER BY updatedAt DESC LIMIT ' + limit + ' OFFSET ' + offset;
  }
  HOST.boardSql = boardSql;

  HOST.findBoards = function (opts) {
    opts = opts || {};
    var want = Math.max(1, Math.min(HOST.PAGE - 1, opts.limit || HOST.BOARDS));
    var offset = Math.max(0, opts.offset || 0);

    function shape(rows, counts) {
      var more = rows.length > want;
      return {
        ok: true, more: more, counts: counts,
        boards: rows.slice(0, want).map(function (r) {
          var n = typeof r.notes === 'number' ? r.notes : null;
          var s = typeof r.stickies === 'number' ? r.stickies : null;
          return {
            id: typeof r.id === 'string' ? r.id : String(r.id == null ? '' : r.id),
            title: typeof r.title === 'string' ? r.title : '',
            /*
             * A NUMBER on a phone. `notes.updatedAt` is declared
             * `INTEGER NOT NULL` and written as millisecondsSinceEpoch, and
             * runQuery passes column values through as they are - so the
             * string test alone threw the date away on every device and left
             * the board home with no time under any of its rows. The browser
             * mock stores an ISO string, which is why the harness never saw
             * it. Both are carried as they arrive, and A.ago reads either.
             */
            updatedAt: typeof r.updatedAt === 'number' && isFinite(r.updatedAt) ? r.updatedAt
              : (typeof r.updatedAt === 'string' ? r.updatedAt : ''),
            cards: counts && (n !== null || s !== null) ? (n || 0) + (s || 0) : null
          };
        }).filter(function (b) { return !!b.id; })
      };
    }

    return HOST.query(boardSql(want + 1, offset, true)).then(function (r) {
      if (r.ok) return shape(r.rows, true);
      return HOST.query(boardSql(want + 1, offset, false)).then(function (p) {
        if (!p.ok) return { ok: false, boards: [], more: false, counts: false, error: p.error };
        return shape(p.rows, false);
      });
    });
  };

  /*
   * The native multi-note picker. It answers with REFERENCES - ids and titles,
   * never content - which is exactly what a board card needs.
   * -> { ok, notes: [{id, title}], cancelled, error, reason }
   *
   * Choosing nothing is a cancel, not a failure: both mean the board is
   * unchanged, and a caller that had to tell them apart would be inventing a
   * distinction the user did not make. 'no_ui' is kept as `reason` because
   * that one is worth saying out loud - it means this context has no screen to
   * put a picker on, and asking again will not help.
   */
  HOST.pickNotes = function (options) {
    if (!S || !S.pickNotes) return Promise.resolve({ ok: false, notes: [], error: 'this app cannot open the note picker' });
    return Promise.resolve(S.pickNotes(options || {})).then(function (r) {
      if (!r || r.success === false) {
        var why = (r && r.error) || 'the note picker could not be opened';
        return {
          ok: false, notes: [],
          reason: why === 'no_ui' ? 'no_ui' : '',
          error: why === 'no_ui' ? 'there is no screen here to show the note picker on' : why
        };
      }
      var notes = (Array.isArray(r.notes) ? r.notes : []).map(function (n) {
        return {
          id: String((n && n.id) || ''),
          title: typeof (n && n.title) === 'string' ? n.title : ''
        };
      }).filter(function (n) { return !!n.id; });
      if (r.cancelled === true || !notes.length) return { ok: true, cancelled: true, notes: [] };
      return { ok: true, cancelled: false, notes: notes };
    }).catch(function (e) {
      return { ok: false, notes: [], error: String((e && e.message) || e) };
    });
  };

  /*
   * Open a note in the app. Not a board edit and not a write: the board is
   * exactly as it was when the user comes back. It lives here rather than in
   * app.js so that every reach for the Synapse object is in one file, and so
   * that a host with no openNote is a `false`, not a crash.
   */
  HOST.openNote = function (id) {
    if (!id || !S || !S.openNote) return Promise.resolve(false);
    return Promise.resolve(S.openNote(id)).then(function () { return true; }, function () { return false; });
  };

  /*
   * updateNotes, and the one reading of its answer.
   * -> { ok, updatedCount, errors: [], error }
   *
   * `success:true` only means the CALL ran. Every entry in it can still be
   * refused - the note has an immutable workflow tag, the target block moved,
   * a temp file expired - and the only way to tell is `updatedCount` and
   * `errors`. So:
   *
   *   nothing updated            -> ok:false, and `error` is the host's own
   *                                 first message when it gave one.
   *   some updated, some refused -> ok:TRUE, with `errors` carried through.
   *                                 A batch of five tags where one note is
   *                                 gone really did tag four, and calling that
   *                                 a failure would have the caller retry a
   *                                 write that has already landed.
   *
   * Every note write in Big Bang goes through here, and every caller is
   * expected to look at `updatedCount` rather than at `ok` alone.
   */
  HOST.update = function (list) {
    if (!S || !S.updateNotes) return Promise.resolve({ ok: false, updatedCount: 0, errors: [], error: 'no host' });
    return Promise.resolve(S.updateNotes(list)).then(function (r) {
      var errors = (r && Array.isArray(r.errors)) ? r.errors.slice() : [];
      if (!r || r.success === false) {
        return { ok: false, updatedCount: 0, errors: errors, error: (r && r.error) || 'the write was declined' };
      }
      var n = typeof r.updatedCount === 'number' ? r.updatedCount : 0;
      if (n <= 0) {
        return {
          ok: false, updatedCount: 0, errors: errors,
          error: errors.length ? errors[0] : 'the write was declined'
        };
      }
      return { ok: true, updatedCount: n, errors: errors };
    }).catch(function (e) {
      return { ok: false, updatedCount: 0, errors: [], error: String((e && e.message) || e) };
    });
  };

  /*
   * Write a note's whole body. Always the `modification` form: it is the only
   * one a block-scoped note accepts and it behaves identically for an ordinary
   * one. An empty `content` clears the note, which is what clearing a board
   * out of a note that held nothing else means.
   *
   * One entry, so a partial success cannot happen: any error at all is this
   * write's error, and it is a failure.
   */
  HOST.writeContent = function (id, content) {
    return HOST.update([{ id: id, modification: { content: { action: 'replace', text: content } } }])
      .then(function (r) {
        if (!r.ok) return { ok: false, error: r.error, errors: r.errors };
        if (r.errors && r.errors.length) return { ok: false, error: r.errors[0], errors: r.errors };
        return { ok: true, updatedCount: r.updatedCount };
      });
  };

  /* --------------------------------------------------------- attachments */

  /*
   * The files already on a note. -> { ok, files: [{ path, fileName }], error }
   *
   * Read straight out of the attachments table rather than through
   * exportNotes, which renders a whole share-export - sub-notes, linked notes,
   * localised section headings - to answer "what files are on this note".
   * `filePath` is the RELATIVE path the host stores, and it is the string an
   * attachments.removed takes: note.attachmentPaths hold that same value, and
   * a removal is a set difference over it.
   *
   * Paged, because the row cap counts FILES here rather than notes, and a note
   * with a hundred and one of them would silently hide the hundred and first -
   * which, if that were the previous export, means the next one piles up
   * beside it instead of replacing it.
   */
  HOST.attachmentsOf = function (noteId) {
    var clean = sqlId(noteId);
    if (!clean) return Promise.resolve({ ok: false, files: [], error: 'no note id' });
    return HOST.queryAll(function (limit, offset) {
      return "SELECT filePath, fileName FROM attachments WHERE noteId = '" + clean + "'" +
        ' ORDER BY createdAt, filePath LIMIT ' + limit + ' OFFSET ' + offset;
    }).then(function (r) {
      if (!r.ok) return { ok: false, files: [], error: r.error };
      return {
        ok: true,
        files: r.rows.map(function (row) {
          var p = typeof row.filePath === 'string' ? row.filePath : '';
          return { path: p, fileName: typeof row.fileName === 'string' && row.fileName ? row.fileName : p.split('/').pop() };
        }).filter(function (f) { return !!f.path; })
      };
    });
  };

  /*
   * One file onto a note, and the files it stands in for taken off in the same
   * call. -> { ok, updatedCount, error }
   *
   * `fileName` must be the ORIGINAL, human name every single time. The host
   * renames what it saves - generateUniqueFileName turns `Board — board.png`
   * into `Board — board_<uuid>.png` - so a caller that read the stored name
   * back and sent THAT would produce `Board — board_<uuid>_<uuid>.png`, and a
   * name that grows a uuid per export is a name no later export recognises.
   *
   * One entry, so there is no partial success to interpret: an error at all is
   * this attachment's error.
   */
  HOST.attachFile = function (noteId, file, removePaths) {
    var atts = {
      added: [{
        type: 'base64', data: file.data, fileName: file.fileName, mimeType: file.mimeType || ''
      }]
    };
    if (removePaths && removePaths.length) atts.removed = removePaths.slice();
    return HOST.update([{ id: noteId, modification: { attachments: atts } }]).then(function (r) {
      if (!r.ok) return { ok: false, error: r.error, errors: r.errors };
      if (r.errors && r.errors.length) return { ok: false, error: r.errors[0], errors: r.errors };
      return { ok: true, updatedCount: r.updatedCount };
    });
  };

  /* ------------------------------------------------------------------- ai */

  /*
   * The app's AI channel. -> { ok, text } | { ok: false, reason, error }
   *
   * Everything the board asks a model goes through here, and three facts about
   * it are encoded rather than rediscovered:
   *
   *   There is no schema mode. chatAI answers with a STRING, and the only
   *   response_type beyond that is a multi-part array of text, images and
   *   audio - none of which is JSON with a shape anybody promised. So the
   *   caller parses prose, and a parser that cannot make sense of a line drops
   *   that line rather than the answer.
   *
   *   A host may have no model at all, and that is not an error state. It is
   *   `reason:'no-model'`, said once, and the board goes on working: nothing
   *   about a board depends on a model being available.
   *
   *   It can simply not come back. The bridge call is a real await into
   *   Flutter and the model behind it is a network service, so the wait is
   *   bounded here - not by the caller, which would leave the promise
   *   outstanding and the board saying `thinking…` for the rest of the session.
   *   The late answer, if it ever arrives, is dropped: `settled` is what
   *   guarantees the caller is told exactly once.
   */
  HOST.AI_TIMEOUT = 45000;
  HOST.hasAI = function () { return !!(S && typeof S.chatAI === 'function'); };

  HOST.chatAI = function (prompt, opts) {
    opts = opts || {};
    if (!HOST.hasAI()) {
      return Promise.resolve({ ok: false, reason: 'no-model', error: 'this app cannot reach a model here' });
    }
    var ms = typeof opts.timeout === 'number' && opts.timeout > 0 ? opts.timeout : HOST.AI_TIMEOUT;
    return new Promise(function (resolve) {
      var settled = false;
      var timer = setTimeout(function () {
        if (settled) return;
        settled = true;
        resolve({ ok: false, reason: 'timeout', error: 'the model did not answer in time' });
      }, ms);
      function done(v) {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(v);
      }
      var p;
      // A host that throws on the stack rather than rejecting never reaches a
      // .then pair, and the board would wait out the whole timeout for it.
      try { p = S.chatAI(prompt, opts.options || {}); }
      catch (e) { return done({ ok: false, reason: 'failed', error: String((e && e.message) || e) }); }
      Promise.resolve(p).then(function (r) {
        if (!r || r.success === false) {
          return done({ ok: false, reason: 'refused', error: (r && r.error) || 'the model declined to answer' });
        }
        var text = typeof r.response === 'string' ? r.response : '';
        if (!text.replace(/\s+/g, '')) {
          return done({ ok: false, reason: 'empty', error: 'the model answered with nothing' });
        }
        done({ ok: true, text: text });
      }, function (e) {
        done({ ok: false, reason: 'failed', error: String((e && e.message) || e) });
      });
    });
  };

  /* ------------------------------------------------ writes to OTHER notes */

  /*
   * Everything below writes to a note that is not the board's. Each one is a
   * deliberate act the user was asked about first (see app.js `ask`), and each
   * reports what the host actually did rather than that the call returned.
   */

  /*
   * A new note, from a sticky. saveNotes hands back the ids it created, in the
   * order of the notes that SAVED - an entry that was skipped is simply absent
   * - so the id is taken from savedNoteIds[0] and a response without one is a
   * failure, not a note we can go looking for.
   */
  HOST.createNote = function (title, content) {
    if (!S || !S.saveNotes) return Promise.resolve({ ok: false, error: 'no host' });
    return Promise.resolve(S.saveNotes([{ title: title, content: content, type: 'note' }])).then(function (r) {
      if (!r || r.success === false) return { ok: false, error: (r && r.error) || 'the note could not be created' };
      var ids = Array.isArray(r.savedNoteIds) ? r.savedNoteIds : [];
      if (!ids.length || typeof ids[0] !== 'string' || !ids[0]) {
        return { ok: false, error: 'the note was not created' };
      }
      return { ok: true, id: ids[0] };
    }).catch(function (e) { return { ok: false, error: String((e && e.message) || e) }; });
  };

  /*
   * A real relationship between two notes, and its removal.
   *
   * `link` takes the {added, removed} object as well as the bare array the
   * prompt documents; the object form is used both ways round so the two calls
   * read alike. The REMOVAL deletes every relationship between the pair in
   * BOTH directions - note_modification_service's delete is written that way -
   * so it takes out a link-back the merge screen wrote as readily as one Big
   * Bang did, and the sheet that offers it has to say so.
   */
  HOST.linkNotes = function (a, b, relation) {
    return HOST.update([{
      id: a,
      modification: { link: { added: [{ relation: relation || 'related', target: b }] } }
    }]);
  };

  HOST.unlinkNotes = function (a, b) {
    return HOST.update([{ id: a, modification: { link: { removed: [b] } } }]);
  };

  // One tag, added to each of several notes, in one call and one approval.
  HOST.tagNotes = function (ids, name) {
    return HOST.update((ids || []).map(function (id) {
      return { id: id, modification: { tags: { added: [name] } } };
    }));
  };

  /*
   * A task ticked or unticked.
   *
   * Full-replacement mode, because `status` is not one of the six fields the
   * granular modification schema knows (content, title, tags, link,
   * attachments, subnote) and a modification naming none of them is a silent
   * no-op success - the tick would report that it worked and change nothing.
   * Only `status` is sent: every field left out keeps the value the note has.
   */
  HOST.STATUS_DONE = 'complete';
  HOST.STATUS_TODO = 'todo';
  HOST.setTaskStatus = function (id, status) {
    return HOST.update([{ id: id, status: status }]);
  };

  /*
   * The merge screen. -> { ok, mergedNoteId, cancelled, error }
   *
   * `cancelled` is reported, never acted on: it means no note came back, which
   * is usually a back-out and is sometimes a merge that saved without
   * reporting. Retrying it would make a second merged note.
   */
  HOST.openMerge = function (noteIds) {
    if (!S || !S.openMerge) return Promise.resolve({ ok: false, error: 'this app cannot open the merge screen' });
    return Promise.resolve(S.openMerge(noteIds || [])).then(function (r) {
      if (!r || r.success === false) return { ok: false, error: (r && r.error) || 'the merge screen could not be opened' };
      if (typeof r.mergedNoteId === 'string' && r.mergedNoteId) return { ok: true, mergedNoteId: r.mergedNoteId };
      return { ok: true, cancelled: true };
    }).catch(function (e) { return { ok: false, error: String((e && e.message) || e) }; });
  };

  /* ------------------------------------------------------- load / save cycle */

  /*
   * A session is the handle the app holds between opening a board and saving
   * it: { noteId, key, readOnly, status }, where `key` is the block exactly as
   * it stood when we last agreed with the note. It is what a conflict is
   * measured against.
   */
  HOST.loadBoard = function (noteId) {
    return HOST.readContent(noteId).then(function (r) {
      if (!r.ok) return { ok: false, error: r.error };
      var read = BOARD.read(r.content);
      // A block we do not understand must not be overwritten by a save that
      // was never told about it.
      var readOnly = read.status === 'future';
      return {
        ok: true,
        session: { noteId: noteId, key: read.key, readOnly: readOnly, status: read.status },
        content: r.content,
        board: read.board,
        status: read.status,
        v: read.v,
        dropped: read.dropped,
        extra: read.extra,
        reason: read.reason,
        readOnly: readOnly,
        // What the scan already knows, handed on rather than made findable
        // again. note.content is one of the columns the project flags as
        // potentially huge, and a caller that re-scans it to learn whether the
        // note ends inside a fence pays for a second full pass over it.
        span: read.span,
        spans: read.spans,
        openAtEnd: read.openAtEnd,
        shadowed: read.shadowed
      };
    });
  };

  /*
   * The save cycle, and the only place a board is written:
   *
   *   1. re-read the note's current content
   *   2. refuse if what is there now is not a block we are entitled to replace
   *   3. splice OUR block into that fresh text
   *   4. write it back
   *
   * A fresh text carrying a DIFFERENT block than the one we loaded is a
   * conflict; it is reported, never resolved here. An ordinary body edit made
   * in the real editor meanwhile is not a conflict and is never mentioned: it
   * survives untouched because step 3 starts from the text that contains it.
   *
   * Four things are refused outright, and each takes the same escape hatch -
   * opts.force, meaning the user was shown THAT reason and said yes:
   *
   *   'conflict'   another Big Bang session saved a different block meanwhile.
   *   'read-only'  a block from a newer Big Bang. Never read, so a save would
   *                replace a format we do not understand with an empty board.
   *   'malformed'  a hand-damaged block, or a note ending inside an unclosed
   *                fence. Its span is a guess, and replacing a guess is how the
   *                prose under an unterminated fence disappears.
   *   'extra'      more than one board block in the note. Only the first was
   *                ever read; saving would drop the others.
   *
   * `opts.force` NAMES the reason it answers: a string, or an array of them.
   * A user who was shown a conflict and said "keep mine" has agreed to overwrite
   * the other session's block and nothing else; if the same save then finds the
   * note damaged, or holding a second board, that is a different question and
   * it is asked separately. `force:true` still means all of them, because it is
   * the only honest reading of a caller that named none - but the app never
   * sends it.
   *
   * -> { ok: true, content, key, unchanged? }
   *    { ok: false, reason: 'read-only' | 'read-failed' | 'conflict' | 'write-failed'
   *                       | 'malformed' | 'extra', ... }
   *
   * Saves are serialised per session. Two overlapping saves would both read
   * the same fresh text, both agree there was no conflict, and both write -
   * the second from text captured before the first landed, so the first save
   * and any body edit between them would vanish with nothing reported.
   */
  /*
   * Was THIS refusal the one the user was shown and agreed to?
   * `true` (or 'all') is every reason; a string or an array is exactly those.
   */
  function forced(opts, reason) {
    var f = opts.force;
    if (f === true || f === 'all') return true;
    if (typeof f === 'string') return f === reason;
    if (Array.isArray(f)) return f.indexOf(reason) >= 0;
    return false;
  }
  HOST.forced = forced;

  HOST.saveBoard = function (session, board, opts) {
    opts = opts || {};
    if (!session || !session.noteId) return Promise.resolve({ ok: false, reason: 'read-failed', error: 'no note' });
    if (session.readOnly && !forced(opts, 'read-only')) {
      return Promise.resolve({ ok: false, reason: 'read-only', error: 'this board was written by a newer version of Big Bang' });
    }
    var queued = (session.queue || Promise.resolve()).then(
      function () { return saveOnce(session, board, opts); },
      function () { return saveOnce(session, board, opts); }
    );
    // The queue must not inherit a rejection, or every later save on this
    // session would jump the failed one instead of following it.
    session.queue = queued.then(function () { }, function () { });
    return queued;
  };

  function saveOnce(session, board, opts) {
    return HOST.readContent(session.noteId).then(function (r) {
      // Rule zero: a failed read aborts. Never splice into a remembered copy.
      if (!r.ok) return { ok: false, reason: 'read-failed', error: r.error };
      var fresh = r.content;
      var fr = BOARD.read(fresh);
      var base = session.key || '';

      if (!forced(opts, 'conflict') && fr.key !== base) {
        return {
          ok: false,
          reason: 'conflict',
          theirs: fr.board,
          theirsStatus: fr.status,
          change: BOARD.describeChange(fr.board, board),
          content: fresh,
          key: fr.key
        };
      }
      if (!forced(opts, 'extra') && fr.extra) {
        return {
          ok: false,
          reason: 'extra',
          error: 'this note holds ' + (fr.extra + 1) + ' board blocks; only the first was read, and saving would remove the ' +
            (fr.extra === 1 ? 'other' : 'others'),
          extra: fr.extra,
          content: fresh
        };
      }
      if (!forced(opts, 'malformed') && fr.status === 'malformed') {
        return {
          ok: false,
          reason: 'malformed',
          error: 'the block in this note is damaged (' + fr.reason + '); saving would replace it',
          detail: fr.reason,
          content: fresh
        };
      }
      // Nothing to replace, and nowhere safe to append: the note ends inside
      // somebody's unterminated code fence, so a block written at the end
      // would be part of it and invisible to the next open - which would then
      // append another one beside it.
      if (!forced(opts, 'malformed') && !fr.span && fr.openAtEnd && !BOARD.isEmpty(board)) {
        return {
          ok: false,
          reason: 'malformed',
          error: 'this note ends inside an unclosed code fence, so a board block added here would be part of it',
          detail: 'the note ends inside an unclosed code fence',
          content: fresh
        };
      }
      if (!forced(opts, 'read-only') && fr.status === 'future') {
        session.readOnly = true;
        return { ok: false, reason: 'read-only', error: 'this board was written by a newer version of Big Bang' };
      }

      var next = BOARD.splice(fresh, board);
      if (next === fresh) {
        agree(session, fresh);
        return { ok: true, unchanged: true, content: next, key: session.key };
      }
      return HOST.writeContent(session.noteId, next).then(function (w) {
        if (!w.ok) return { ok: false, reason: 'write-failed', error: w.error, errors: w.errors };
        agree(session, next);
        return { ok: true, content: next, key: session.key, cleared: next === '' };
      });
    });
  }

  // The session now agrees with the note: this text is what a later save
  // measures its conflict against, and whatever we refused to write over is
  // no longer there to refuse.
  function agree(session, text) {
    var read = BOARD.read(text);
    session.key = read.key;
    session.status = read.status;
    session.readOnly = read.status === 'future';
  }

  if (typeof module !== 'undefined' && module.exports) module.exports = BB;
})(typeof window !== 'undefined' ? window : globalThis);
