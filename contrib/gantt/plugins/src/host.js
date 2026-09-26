/*
 * Gantt - the Synapse bridge (plan §4.2 host row, §7, §8, §9.1.3, §10.1) and
 * the mock that stands in for it (§17.1).
 *
 * This is the only file that references Synapse or listens to synapse:*
 * events (D25). Every call resolves {ok, ...} and never throws or rejects.
 *
 * Bridge facts, read in this worktree (lib/services/user_app_runtime_bridge.dart
 * unless named otherwise; "api doc" is assets/prompts/user_app/api_documentation.md):
 *   - runQuery(sql) -> {success, data, truncated?, totalRows?} | {success:false, error}.
 *     Rows are capped at 100 after the full fetch (bridge 738-750,
 *     sql_query_service.dart:348, 422-439; api doc 1-14). A write asks for its
 *     own approval unless session-approved; a denial is
 *     'User denied the SQL write operation.' (bridge 703-727).
 *   - updateNotes(list) -> {success, updatedCount, errors?, error?}; a denial is
 *     {success:false, error:'User denied modification.'} (bridge 2011-2146).
 *     A non-plugin-facing error is redacted to
 *     'Updating note <id> failed. See the app log for details.' (bridge 3276-3288);
 *     since M10 the text is 'Updating note <id> failed: <message>' and the three
 *     replace_text failures arrive verbatim. Only the id in it is read here.
 *     Entries with `modification` go through NoteModificationService; others
 *     are full replacement, where only the keys present change (bridge 3230-3275, 3415-3530).
 *   - saveNotes(list) -> {success, savedCount, savedNoteIds}; a note that fails
 *     to build is skipped silently (bridge 1905-1935, 3004-3026). buildNote
 *     trims title and content (note_modification_service.dart:278-359).
 *   - pickNotes(options) -> {success, notes:[{id,title}]} |
 *     {success:true, cancelled:true, notes:[]} | {success:false, error:'no_ui'} (bridge 1600-1621).
 *   - openNote(id, replaceWindow) -> {success} once the route is pushed (bridge 1965-2008).
 *   - loadAppState() -> {success:true, data: state|null} (bridge 315-318, 794-822; api doc 17-18).
 *   - storeAppState(state) -> {success}; replaces the whole blob (bridge 311-314, 766-790).
 *   - Synapse.Notes, Params, space, locale are published by the bootstrap; there
 *     is no theme (bridge 481-484). 'synapse:localechanged' and
 *     'synapse:spacechanged' fire on window with the new value as detail
 *     (bridge 513-516, 555-579, 630-640; api doc 728-775).
 */
(function (global) {
  'use strict';
  var GT = (global.GT = global.GT || {});
  var H = (GT.host = {});

  // The `normal` app's uuid (Gantt.yaml), generated once in M4 and never
  // changed (§17.3): the embed line names it. Fixtures spell it {{APP_UUID}}.
  GT.APP_UUID = 'aac1665f-3f18-425c-a2f5-6e6001d75326';

  H.ROW_CAP = 100;          // runQuery cap (sql_query_service.dart:348)
  H.META_CHUNK = 99;        // §7.1
  H.AGG_CHUNK = 100;        // §7.2 / §7.3: one row per note at most, so 100 ids fit LIMIT 100
  H.WIN_CHUNK = 20;         // §7.4
  H.WIN = 16000;            // §7.4 window size
  H.WIN_BACK = 200;         // §7.4 characters kept before the heading
  H.PAGE_SIZE = 65536;      // §7.4 paged fallback
  H.PAGE_CAP = 262144;      // §7.4 paged fallback cap
  H.HOME_PAGE = 25;         // §7.7 rows shown per page (the query asks for one more)
  H.REF_LIMIT = 10;         // §7.7 chooser
  H.HEAD_LEN = 64;          // §7.7 window length
  H.HEAD_BACK = 4;          // §7.7 characters before the fence
  H.RESUME_MS = 30000;      // §7.6 poll interval
  H.COALESCE_MS = 250;      // DOM resume triggers closer than this fire once
  H.DENIED = 'User denied modification.';              // bridge 2112
  H.SQL_DENIED = 'User denied the SQL write operation.'; // bridge 721
  H.STATUSES = ['todo', 'in_progress', 'complete', 'abandoned'];

  var INFO = 'synapse-gantt';
  var FENCE = '```' + INFO;

  /* ------------------------------------------------------------ helpers */

  function msg(e) { return String((e && e.message) || e); }
  function isObj(x) { return !!x && typeof x === 'object' && !Array.isArray(x); }
  function str(x) { return typeof x === 'string' ? x : ''; }
  function num(x) {
    if (typeof x === 'number' && isFinite(x)) return x;
    if (typeof x === 'string' && x.trim() && isFinite(Number(x))) return Number(x);
    return null;
  }
  function clone(x) { return x === undefined ? undefined : JSON.parse(JSON.stringify(x)); }
  function has(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }

  var ID_RE = /^[A-Za-z0-9_-]+$/;
  function sqlId(id) { return typeof id === 'string' && ID_RE.test(id) ? id : null; }
  H.sqlId = sqlId;
  function sqlStr(s) { return "'" + String(s).replace(/\u0000/g, '').replace(/'/g, "''") + "'"; }
  H.sqlStr = sqlStr;

  // Distinct valid ids in order; invalid ones are returned apart.
  function cleanIds(ids) {
    var seen = Object.create(null), good = [], bad = [];
    (Array.isArray(ids) ? ids : []).forEach(function (id) {
      if (typeof id !== 'string' || seen[id]) return;
      seen[id] = 1;
      if (sqlId(id)) good.push(id); else bad.push(id);
    });
    return { good: good, bad: bad };
  }
  function chunks(list, n) {
    var out = [];
    for (var i = 0; i < list.length; i += n) out.push(list.slice(i, i + n));
    return out;
  }
  function inList(ids) { return ids.map(function (x) { return "'" + x + "'"; }).join(','); }

  // Wrap an async body so it never throws or rejects.
  function safe(fn) {
    return function () {
      try {
        return Promise.resolve(fn.apply(this, arguments)).catch(function (e) { return { ok: false, error: msg(e) }; });
      } catch (e) { return Promise.resolve({ ok: false, error: msg(e) }); }
    };
  }

  /*
   * §7.7: accept a 64-character head window when the fence starts a line
   * (at most 3 spaces of indent), the info string is alone on it, and the
   * body opens with {"v": (CRLF and spaced JSON allowed).
   */
  var HEAD_RE = /(^|\n) {0,3}```synapse-gantt[ \t]*\r?\n\s*\{\s*"v"\s*:/;
  H.isChartHead = function (head) { return typeof head === 'string' && HEAD_RE.test(head); };

  /*
   * The Space filter of api doc 746-765: every Space tag ANDed, with the
   * all-spaces OR around the Space group only. '1=1' outside a Space.
   */
  function existsTag(tag) {
    return 'EXISTS (SELECT 1 FROM note_tags nt JOIN tags tg ON tg.id = nt.tagId WHERE nt.noteId = n.id AND tg.name = ' + sqlStr(tag) + ')';
  }
  function spaceTags(space) {
    return isObj(space) && Array.isArray(space.tags) ? space.tags.filter(function (t) { return typeof t === 'string' && t; }) : [];
  }
  H.spaceClause = function (space) {
    var tags = spaceTags(space);
    if (!tags.length) return '1=1';
    return '((' + tags.map(existsTag).join(' AND ') + ') OR ' + existsTag('all-spaces') + ')';
  };

  /*
   * SQL builders, one per query of §7. Ids must already be valid (sqlId);
   * needles already escaped (md.sqlNeedle doubles quotes).
   */
  var SQL = (H.sql = {
    select1: function () { return 'SELECT 1'; },
    meta: function (ids) {                                                       // §7.1
      return 'SELECT id, title, type, status, scheduledAt, completeBy, updatedAt, isArchived, length(content) AS clen' +
        ' FROM notes WHERE id IN (' + inList(ids) + ') ORDER BY id LIMIT 100';
    },
    subnotes: function (ids) {                                                   // §7.2
      return "SELECT noteId, COUNT(*) AS total, SUM(isCompleted) AS done, group_concat(isCompleted, '') AS bits" +
        ' FROM (SELECT noteId, isCompleted FROM subnotes WHERE noteId IN (' + inList(ids) + ') ORDER BY noteId, createdAt, rowid)' +
        ' GROUP BY noteId LIMIT 100';
    },
    children: function (ids) {                                                   // §7.3
      return "SELECT noteId, COUNT(*) AS total, SUM(d) AS done, group_concat(d, '') AS bits" +
        " FROM (SELECT r.fromNoteId AS noteId, CASE WHEN n.status = 'complete' THEN 1 ELSE 0 END AS d" +
        ' FROM relationships r JOIN notes n ON n.id = r.toNoteId' +
        " WHERE r.type = 'subnote' AND n.type = 'task' AND r.fromNoteId IN (" + inList(ids) + ')' +
        ' ORDER BY r.fromNoteId, r.createdAt, r.rowid) GROUP BY noteId LIMIT 100';
    },
    windows: function (ids, needle) {                                            // §7.4
      var at = "max(1, instr(content, '" + needle + "') - " + H.WIN_BACK + ')';
      return 'SELECT id, length(content) AS clen,' +
        ' CASE WHEN length(content) <= ' + H.WIN + ' THEN content ELSE substr(content, ' + at + ', ' + H.WIN + ') END AS win,' +
        ' CASE WHEN length(content) <= ' + H.WIN + ' THEN 1 ELSE ' + at + ' END AS off' +
        ' FROM notes WHERE id IN (' + inList(ids) + ') LIMIT 100';
    },
    range: function (id, off, size) {                                            // §7.4 paged
      return 'SELECT length(content) AS clen, substr(content, ' + off + ', ' + size + ') AS page' +
        " FROM notes WHERE id = '" + id + "' LIMIT 1";
    },
    note: function (id) {                                                        // §7.6
      return "SELECT content, length(content) AS clen, updatedAt FROM notes WHERE id = '" + id + "' LIMIT 1";
    },
    charts: function (space, limit, offset, counted) {                           // §7.7 home
      return 'SELECT n.id, n.title, n.updatedAt, ' +
        (counted ? "(length(n.content) - length(replace(n.content, '\"note\":\"', ''))) / 8 AS tasks, " : '') +
        "substr(n.content, max(1, instr(n.content, '" + FENCE + "') - " + H.HEAD_BACK + '), ' + H.HEAD_LEN + ') AS head' +
        " FROM notes n WHERE instr(n.content, '" + FENCE + "') > 0 AND n.isArchived = 0 AND " + H.spaceClause(space) +
        ' ORDER BY n.updatedAt DESC LIMIT ' + limit + ' OFFSET ' + offset;
    },
    referencing: function (noteId, space) {                                      // §7.7 chooser
      return 'SELECT n.id, n.title, n.updatedAt, ' +
        "substr(n.content, max(1, instr(n.content, '" + FENCE + "') - " + H.HEAD_BACK + '), ' + H.HEAD_LEN + ') AS head' +
        " FROM notes n WHERE instr(n.content, '" + FENCE + "') > 0" +
        " AND instr(substr(n.content, instr(n.content, '" + FENCE + "')), '" + noteId + "') > 0" +
        ' AND n.isArchived = 0 AND ' + H.spaceClause(space) +
        ' ORDER BY n.updatedAt DESC LIMIT ' + H.REF_LIMIT;
    },
    subnoteDone: function (noteId, subId, done) {                                // §8
      return 'UPDATE subnotes SET isCompleted = ' + (done ? 1 : 0) +
        " WHERE id = '" + subId + "' AND noteId = '" + noteId + "'";
    },
    // M7 (additive): the task sheet's completion list, one note at a time
    // (§7.8). rowid breaks createdAt ties (subnotes saved in one call share
    // a millisecond), the same order as 7.2 / 7.3, so bits and rows agree.
    subnoteItems: function (noteId) {                                            // §7.8
      return "SELECT id, name, isCompleted FROM subnotes WHERE noteId = '" + noteId + "' ORDER BY createdAt, rowid LIMIT 100";
    },
    childItems: function (noteId) {                                              // §7.8
      return 'SELECT n.id, n.title, n.status FROM relationships r JOIN notes n ON n.id = r.toNoteId' +
        " WHERE r.type = 'subnote' AND n.type = 'task' AND r.fromNoteId = '" + noteId + "' ORDER BY r.createdAt, r.rowid LIMIT 100";
    }
  });

  function isReadOnly(sql) { return /^\s*(select|with)\b/i.test(String(sql)); }

  /*
   * §10.1 launch matrix over a launch() result, as a pure function.
   * -> {kind: 'embed'|'chart'|'home'|'chooser'|'multi'|'resolve', noteId?, noteIds?, read?, needsRead?}
   * `read` is block.read of Notes[0].content when that is the whole note, so
   * the first paint needs no bridge call. A block-scoped launch (not embed)
   * is 'resolve': read parentNoteId, then 'chart' if it holds a block, else
   * 'chooser'.
   */
  function truthy(v) { return v === true || (typeof v === 'string' && v !== '' && v !== 'false' && v !== '0') || (typeof v === 'number' && v !== 0); }
  H.route = function (l) {
    try { return route(l); } catch (e) { return { kind: 'home' }; }
  };
  function route(l) {
    l = isObj(l) ? l : {};
    var params = isObj(l.params) ? l.params : {};
    var notes = (Array.isArray(l.notes) ? l.notes : []).filter(isObj);
    var first = notes[0] || null;
    var B = GT.block;
    if (params.mode === 'embed') {
      var eid = sqlId(params.chart) || (first ? first.id : null);
      var own = !!first && eid === first.id && !first.blockScope;
      return { kind: 'embed', noteId: eid, needsRead: !own, read: own && B ? B.read(str(first.content)) : null };
    }
    if (sqlId(params.chart)) return { kind: 'chart', noteId: params.chart, needsRead: true };
    if (truthy(params.standalone) || !notes.length) return { kind: 'home' };
    if (notes.length > 1) return { kind: 'multi', noteIds: notes.map(function (n) { return n.id; }) };
    // A selected block is only part of the note: whether the parent is a
    // chart is decided after reading it (store/app contract, M3a build log).
    if (first.blockScope) return { kind: 'resolve', noteId: first.id, read: null, needsRead: true };
    var fr = B ? B.read(str(first.content)) : null;
    var isChart = !!fr && fr.status !== 'none';
    return { kind: isChart ? 'chart' : 'chooser', noteId: first.id, read: isChart ? fr : null, needsRead: false };
  }

  /* ------------------------------------------------------ host instances */

  function nowDefault() {
    var p = global.performance;
    return p && typeof p.now === 'function' ? p.now() : Date.now();
  }

  /*
   * makeHost(getSynapse, env) builds the host API bound to one Synapse
   * object. GT.host itself is bound to global.Synapse, looked up at call
   * time. env: {now, target, doc, setInterval, clearInterval} for timing and
   * the §7.6 resume triggers; defaults are the page's own.
   */
  function makeHost(getS, env) {
    env = env || {};
    var h = {};
    h.lastRoundTripMs = null;   // the last saveRegion updateNotes round trip
    h.baselineMs = null;        // fastest timed round trip this launch (§9.1.3)

    function S() { try { return getS() || null; } catch (e) { return null; } }
    function now() { return env.now ? env.now() : nowDefault(); }
    function target() { return env.target || (typeof global.addEventListener === 'function' ? global : null); }
    function doc() { return env.doc || global.document || null; }
    function note(ms) { if (typeof ms === 'number' && ms >= 0 && (h.baselineMs === null || ms < h.baselineMs)) h.baselineMs = ms; }
    h.noteRoundTrip = note;

    // One raw bridge call. Resolves the host's answer, or {success:false,error}.
    function raw(name, args) {
      var s = S();
      if (!s || typeof s[name] !== 'function') return Promise.resolve({ success: false, error: 'no host' });
      var p;
      try { p = s[name].apply(s, args || []); } catch (e) { return Promise.resolve({ success: false, error: msg(e) }); }
      return Promise.resolve(p).then(function (r) { return r; }, function (e) { return { success: false, error: msg(e) }; });
    }
    function timed(name, args) {
      var t0 = now();
      return raw(name, args).then(function (r) { return { r: r, ms: now() - t0 }; });
    }

    /* ---- reads ---- */

    // runQuery. Read-only queries are timed into baselineMs (§9.1.3).
    h.query = safe(function (sql) {
      var ro = isReadOnly(sql);
      return timed('runQuery', [String(sql)]).then(function (t) {
        var r = t.r;
        if (ro && r && r.success === true) note(t.ms);
        if (!r || r.success !== true) return { ok: false, rows: [], error: (r && r.error) || 'the query failed', denied: !!r && r.error === H.SQL_DENIED, ms: t.ms };
        return {
          ok: true, rows: Array.isArray(r.data) ? r.data : [], ms: t.ms,
          truncated: r.truncated === true, totalRows: typeof r.totalRows === 'number' ? r.totalRows : null
        };
      });
    });

    // Seeds baselineMs at boot with the cheapest possible round trip.
    h.seedBaseline = safe(function () {
      return h.query(SQL.select1()).then(function (r) { return { ok: r.ok, ms: r.ms, baselineMs: h.baselineMs, error: r.error }; });
    });

    function metaRow(r) {
      return {
        id: str(r.id), title: str(r.title), type: r.type === 'task' ? 'task' : 'note',
        status: typeof r.status === 'string' && r.status ? r.status : null,
        scheduledAt: typeof r.scheduledAt === 'string' && r.scheduledAt ? r.scheduledAt : null,
        completeBy: typeof r.completeBy === 'string' && r.completeBy ? r.completeBy : null,
        updatedAt: num(r.updatedAt), isArchived: num(r.isArchived) ? true : r.isArchived === true,
        clen: num(r.clen)
      };
    }

    /*
     * §7.1 meta in chunks of 99. -> {ok, rows:{id: row}, missing:[id], failed:[id]}
     * Ids absent from a successful chunk are missing; a failed chunk resolves
     * nothing (its ids are in `failed`, never in `missing`). An id that is not
     * [A-Za-z0-9_-]+ cannot be a note id and is missing without a query.
     */
    h.meta = safe(function (ids) {
      var c = cleanIds(ids), rows = {}, missing = c.bad.slice(), failed = [];
      var parts = chunks(c.good, H.META_CHUNK);
      return parts.reduce(function (p, part) {
        return p.then(function () {
          return h.query(SQL.meta(part)).then(function (r) {
            if (!r.ok || r.truncated) { failed = failed.concat(part); return; }
            var got = Object.create(null);
            r.rows.forEach(function (row) {
              var m = metaRow(row);
              if (m.id && part.indexOf(m.id) >= 0) { rows[m.id] = m; got[m.id] = 1; }
            });
            part.forEach(function (id) { if (!got[id]) missing.push(id); });
          });
        });
      }, Promise.resolve()).then(function () {
        return { ok: failed.length === 0, rows: rows, missing: missing, failed: failed, calls: parts.length };
      });
    });

    function bitsOf(v) {
      var s = v === null || v === undefined ? '' : String(v);
      return /^[01]*$/.test(s) ? s : '';
    }
    function counts(build) {
      return safe(function (ids) {
        var c = cleanIds(ids), out = {}, failed = [];
        var parts = chunks(c.good, H.AGG_CHUNK);
        return parts.reduce(function (p, part) {
          return p.then(function () {
            return h.query(build(part)).then(function (r) {
              if (!r.ok || r.truncated) { failed = failed.concat(part); return; }
              part.forEach(function (id) { out[id] = { done: 0, total: 0, bits: '' }; });
              r.rows.forEach(function (row) {
                var id = str(row.noteId);
                if (!has(out, id) || part.indexOf(id) < 0) return;
                out[id] = { done: num(row.done) || 0, total: num(row.total) || 0, bits: bitsOf(row.bits) };
              });
            });
          });
        }, Promise.resolve()).then(function () {
          return { ok: failed.length === 0, counts: out, failed: failed, calls: parts.length };
        });
      });
    }
    // §7.2 -> {ok, counts:{id:{done,total,bits}}, failed}
    h.subnoteCounts = counts(SQL.subnotes);
    // §7.3 -> {ok, counts:{id:{done,total,bits}}, failed}
    h.childCounts = counts(SQL.children);

    /*
     * M7 (additive): the rows of one note's completion list, in createdAt
     * order. -> {ok, items:[{id, name, done}]} and {ok, items:[{id, title,
     * status}]}. A truncated answer counts as failed.
     */
    h.subnoteItems = safe(function (noteId) {
      if (!sqlId(noteId)) return { ok: false, items: [], error: 'bad id' };
      return h.query(SQL.subnoteItems(noteId)).then(function (r) {
        if (!r.ok || r.truncated) return { ok: false, items: [], error: r.error || 'truncated' };
        return { ok: true, items: r.rows.filter(function (x) { return sqlId(str(x.id)); }).map(function (x) {
          return { id: str(x.id), name: str(x.name), done: !!num(x.isCompleted) };
        }) };
      });
    });
    h.childItems = safe(function (noteId) {
      if (!sqlId(noteId)) return { ok: false, items: [], error: 'bad id' };
      return h.query(SQL.childItems(noteId)).then(function (r) {
        if (!r.ok || r.truncated) return { ok: false, items: [], error: r.error || 'truncated' };
        return { ok: true, items: r.rows.filter(function (x) { return sqlId(str(x.id)); }).map(function (x) {
          return { id: str(x.id), title: str(x.title), status: typeof x.status === 'string' && x.status ? x.status : 'todo' };
        }) };
      });
    });

    /*
     * §7.4 checklist windows in chunks of 20, for the section as the chart
     * stores it (md.sqlNeedle makes the needle). -> {ok, windows:{id:{clen,
     * win, off, whole}}, missing, failed}. `whole` means the window is the
     * entire note. A window shorter than min(16000, clen - off + 1) counts as
     * a failed read (length guard, §7.4); the comparison is one-sided because
     * JS counts UTF-16 units and SQLite characters.
     */
    h.checklistWindows = safe(function (ids, section) {
      var MD = GT.md;
      var needle = MD ? MD.sqlNeedle(section == null ? '' : section) : String(section || '').replace(/'/g, "''");
      var c = cleanIds(ids), windows = {}, missing = c.bad.slice(), failed = [];
      var parts = chunks(c.good, H.WIN_CHUNK);
      return parts.reduce(function (p, part) {
        return p.then(function () {
          return h.query(SQL.windows(part, needle)).then(function (r) {
            if (!r.ok || r.truncated) { failed = failed.concat(part); return; }
            var got = Object.create(null);
            r.rows.forEach(function (row) {
              var id = str(row.id);
              if (part.indexOf(id) < 0) return;
              got[id] = 1;
              var clen = num(row.clen), off = num(row.off), win = typeof row.win === 'string' ? row.win : null;
              if (clen === null || off === null || win === null || win.length < Math.min(H.WIN, Math.max(0, clen - off + 1))) {
                failed.push(id);
                return;
              }
              windows[id] = { clen: clen, win: win, off: off, whole: off === 1 && clen <= H.WIN };
            });
            part.forEach(function (id) { if (!got[id]) missing.push(id); });
          });
        });
      }, Promise.resolve()).then(function () {
        return { ok: failed.length === 0, windows: windows, missing: missing, failed: failed, calls: parts.length };
      });
    });

    /*
     * One guarded page: substr(content, off, size). -> {ok, text, off, clen, chars}
     * `chars` is the number of SQLite characters in the page (code points),
     * so the next page starts at off + chars.
     */
    h.readRange = safe(function (id, off, size) {
      if (!sqlId(id)) return { ok: false, error: 'bad id' };
      off = Math.max(1, Math.floor(num(off) || 1));
      size = Math.max(1, Math.floor(num(size) || H.PAGE_SIZE));
      return h.query(SQL.range(id, off, size)).then(function (r) {
        if (!r.ok) return { ok: false, error: r.error };
        if (!r.rows.length) return { ok: false, missing: true, error: 'not-found' };
        var clen = num(r.rows[0].clen), text = r.rows[0].page;
        if (clen === null || typeof text !== 'string') return { ok: false, error: 'bad row' };
        if (text.length < Math.min(size, Math.max(0, clen - off + 1))) return { ok: false, truncated: true, error: 'truncated' };
        return { ok: true, text: text, off: off, clen: clen, chars: Array.from(text).length };
      });
    });

    /*
     * Paged fallback of §7.4: 64 KB pages from `from` until the note ends or
     * 256 KB were read. -> {ok, text, off, clen, complete, pages}
     */
    h.readPaged = safe(function (id, from, opts) {
      opts = opts || {};
      var size = opts.size || H.PAGE_SIZE, cap = opts.cap || H.PAGE_CAP;
      var off = Math.max(1, Math.floor(num(from) || 1)), text = '', read = 0, pages = 0, clen = null;
      function step() {
        return h.readRange(id, off + read, Math.min(size, cap - read)).then(function (r) {
          if (!r.ok) return { ok: false, error: r.error, truncated: !!r.truncated, missing: !!r.missing, pages: pages };
          pages++;
          clen = r.clen;
          text += r.text;
          read += r.chars;
          var atEnd = off + read > clen || r.chars === 0;
          if (atEnd) return { ok: true, text: text, off: off, clen: clen, complete: true, pages: pages };
          if (read >= cap) return { ok: true, text: text, off: off, clen: clen, complete: false, pages: pages };
          return step();
        });
      }
      return step();
    });

    /*
     * §7.6 / §9.2 guarded read of a whole note.
     * -> {ok:true, content, clen, updatedAt}
     *  | {ok:false, missing:true}      no such note (never read as an empty note)
     *  | {ok:false, truncated:true}    content.length < clen (one-sided guard)
     *  | {ok:false, error}
     */
    h.readNote = safe(function (id) {
      if (!sqlId(id)) return { ok: false, error: 'bad id' };
      return h.query(SQL.note(id)).then(function (r) {
        if (!r.ok) return { ok: false, error: r.error };
        if (!r.rows.length) return { ok: false, missing: true, error: 'not-found' };
        var row = r.rows[0], content = row.content, clen = num(row.clen);
        if (typeof content !== 'string') content = content === null || content === undefined ? '' : null;
        if (content === null || clen === null) return { ok: false, error: 'bad row' };
        if (content.length < clen) return { ok: false, truncated: true, error: 'the note came back truncated (' + content.length + ' of ' + clen + ')' };
        return { ok: true, content: content, clen: clen, updatedAt: num(row.updatedAt) };
      });
    });

    function chartRow(r, counted) {
      return {
        id: str(r.id), title: str(r.title), updatedAt: num(r.updatedAt),
        tasks: counted ? num(r.tasks) : null, head: typeof r.head === 'string' ? r.head : ''
      };
    }

    /*
     * §7.7 home list. -> {ok, charts:[{id,title,updatedAt,tasks}], more, next, counted}
     * Asks for 26 rows to learn whether more exist; `next` is the offset of
     * the next page. Hits whose head is not a chart head are dropped. If the
     * counted query fails, the plain one runs and `tasks` is null.
     */
    h.findCharts = safe(function (opts) {
      opts = opts || {};
      var offset = Math.max(0, Math.floor(num(opts.offset) || 0));
      var space = has(opts, 'space') ? opts.space : h.space();
      function shape(rows, counted) {
        var page = rows.slice(0, H.HOME_PAGE).map(function (r) { return chartRow(r, counted); });
        return {
          ok: true, counted: counted, more: rows.length > H.HOME_PAGE, next: offset + H.HOME_PAGE,
          charts: page.filter(function (c) { return c.id && H.isChartHead(c.head); }).map(function (c) {
            return { id: c.id, title: c.title, updatedAt: c.updatedAt, tasks: c.tasks };
          })
        };
      }
      return h.query(SQL.charts(space, H.HOME_PAGE + 1, offset, true)).then(function (r) {
        if (r.ok) return shape(r.rows, true);
        return h.query(SQL.charts(space, H.HOME_PAGE + 1, offset, false)).then(function (p) {
          if (!p.ok) return { ok: false, charts: [], more: false, next: offset, counted: false, error: p.error };
          return shape(p.rows, false);
        });
      });
    });

    // §7.7 chooser: charts in the Space that reference noteId after their fence.
    h.chartsReferencing = safe(function (noteId, opts) {
      opts = opts || {};
      if (!sqlId(noteId)) return { ok: true, charts: [] };
      var space = has(opts, 'space') ? opts.space : h.space();
      return h.query(SQL.referencing(noteId, space)).then(function (r) {
        if (!r.ok) return { ok: false, charts: [], error: r.error };
        return {
          ok: true,
          charts: r.rows.map(function (x) { return chartRow(x, false); })
            .filter(function (c) { return c.id && c.id !== noteId && H.isChartHead(c.head); })
            .map(function (c) { return { id: c.id, title: c.title, updatedAt: c.updatedAt }; })
        };
      });
    });

    /* ---- appState ---- */

    // loadAppState, read through r.data (bridge 818). -> {ok, data}
    h.loadState = safe(function () {
      return raw('loadAppState').then(function (r) {
        if (!r || r.success !== true) return { ok: false, error: (r && r.error) || 'load failed' };
        return { ok: true, data: isObj(r.data) ? r.data : {} };
      });
    });
    // storeAppState: the whole blob. -> {ok}
    h.storeState = safe(function (state) {
      return raw('storeAppState', [isObj(state) ? state : {}]).then(function (r) {
        if (!r || r.success !== true) return { ok: false, error: (r && r.error) || 'store failed' };
        return { ok: true };
      });
    });

    /* ---- writes (only store.js calls these) ---- */

    function errorsOf(r) {
      var e = r && Array.isArray(r.errors) ? r.errors.map(String) : [];
      if (!e.length && r && typeof r.error === 'string' && r.success === true) e = [r.error];
      return e;
    }
    // One updateNotes call. -> {ok, success, denied, updatedCount, errors, error, ms}
    function update(list) {
      return timed('updateNotes', [list]).then(function (t) {
        var r = t.r;
        if (!r || r.success !== true) {
          var err = (r && r.error) || 'the write was declined';
          return { ok: false, success: false, denied: err === H.DENIED, updatedCount: 0, errors: [], error: err, ms: t.ms };
        }
        var errors = errorsOf(r), n = num(r.updatedCount) || 0;
        return { ok: n >= list.length && !errors.length, success: true, denied: false, updatedCount: n, errors: errors, error: errors[0] || null, ms: t.ms };
      });
    }
    function single(entry) {
      return update([entry]).then(function (u) {
        return { ok: u.ok, denied: u.denied, error: u.ok ? null : (u.error || 'not updated'), updatedCount: u.updatedCount };
      });
    }

    /*
     * §9.2: the chart region and any syncDates entries in ONE updateNotes
     * array, so one save raises one approval dialog at most (bridge
     * 2049-2105). The chart entry is a replace_text of the exact region with
     * no section: the region holds the fence with note ids, so it is unique.
     * The chart entry succeeded when no error names the chart id and nothing
     * is unaccounted for. Only this round trip sets lastRoundTripMs.
     * -> {ok, denied, updatedCount, errors, failedDates:[entry], roundTripMs, error}
     */
    h.saveRegion = safe(function (chartId, old, next, dateEntries) {
      if (!sqlId(chartId)) return { ok: false, denied: false, failedDates: [], error: 'bad id' };
      if (typeof old !== 'string' || !old.length || typeof next !== 'string') return { ok: false, denied: false, failedDates: [], error: 'bad region' };
      var dates = (Array.isArray(dateEntries) ? dateEntries : []).filter(function (d) { return isObj(d) && sqlId(d.id) && d.id !== chartId; })
        .map(function (d) {
          // Only strings: the host keeps the old value for null
          // (_mergeNoteData -> Note.copyWith `??`, note.dart:97-98).
          var e = { id: d.id };
          if (typeof d.scheduledAt === 'string') e.scheduledAt = d.scheduledAt;
          if (typeof d.completeBy === 'string') e.completeBy = d.completeBy;
          return e;
        }).filter(function (e) { return has(e, 'scheduledAt') || has(e, 'completeBy'); });
      var list = [{ id: chartId, modification: { content: { action: 'replace_text', old_text: old, new_text: next } } }].concat(dates);
      return update(list).then(function (u) {
        h.lastRoundTripMs = u.ms;
        note(u.ms);
        if (!u.success) return { ok: false, denied: u.denied, updatedCount: 0, errors: [], failedDates: dates, roundTripMs: u.ms, error: u.error };
        // An error names the note it starts with ("Updating note <id>
        // failed. ..." before M10, "... failed: <message>" since, where the
        // message may quote other text); another form is searched whole.
        function about(e, id) { return e.indexOf('Updating note ') === 0 ? e.indexOf('Updating note ' + id + ' failed') === 0 : e.indexOf(id) >= 0; }
        function names(id) { return u.errors.some(function (e) { return about(e, id); }); }
        var failedDates = dates.filter(function (d) { return names(d.id); });
        var chartNamed = names(chartId);
        var unexplained = u.updatedCount < list.length - failedDates.length - (chartNamed ? 1 : 0);
        var ok = !chartNamed && !unexplained;
        return {
          ok: ok, denied: false, updatedCount: u.updatedCount, errors: u.errors,
          failedDates: ok ? failedDates : dates, roundTripMs: u.ms,
          error: ok ? null : (u.errors.filter(function (e) { return about(e, chartId); })[0] || u.error || 'the chart was not written')
        };
      });
    });

    // replace_text of one exact occurrence (toggleItem, D17). `section` is the
    // full heading line or omitted. -> {ok, denied, error}
    h.replaceText = safe(function (id, oldText, newText, section) {
      if (!sqlId(id)) return { ok: false, denied: false, error: 'bad id' };
      if (typeof oldText !== 'string' || !oldText.length || typeof newText !== 'string') return { ok: false, denied: false, error: 'bad text' };
      var c = { action: 'replace_text', old_text: oldText, new_text: newText };
      if (typeof section === 'string' && section.length) c.section = section;
      return single({ id: id, modification: { content: c } });
    });

    // Append (the host joins with '\n', note_modification_service.dart:626-628).
    h.appendContent = safe(function (id, text) {
      if (!sqlId(id)) return { ok: false, denied: false, error: 'bad id' };
      if (typeof text !== 'string' || !text.length) return { ok: false, denied: false, error: 'empty append' };
      return single({ id: id, modification: { content: { action: 'append', text: text } } });
    });

    /*
     * Export image: one file added to a note's attachments, as the base64
     * object form of `attachments.added` (api doc "ATTACHMENT FORMATS"; the
     * bridge turns it into a file with processAttachment before the update,
     * bridge 3281-3292). Content is untouched. -> {ok, denied, error}
     */
    h.attachFile = safe(function (id, dataUrl, fileName) {
      if (!sqlId(id)) return { ok: false, denied: false, error: 'bad id' };
      if (typeof dataUrl !== 'string' || !/^data:[\w.+-]+\/[\w.+-]+;base64,/.test(dataUrl)) return { ok: false, denied: false, error: 'bad data' };
      if (typeof fileName !== 'string' || !fileName.trim()) return { ok: false, denied: false, error: 'bad file name' };
      // fileName before data: the approval dialog prints the entry cut at
      // 20000 characters (approval_dialog.dart 733-738, 807-810), so the name
      // has to come before the base64 to be seen.
      return single({ id: id, modification: { attachments: { added: [{ type: 'base64', fileName: fileName, data: dataUrl }] } } });
    });

    // Rename a note (the chart). -> {ok, denied, error}
    h.rename = safe(function (id, title) {
      if (!sqlId(id)) return { ok: false, denied: false, error: 'bad id' };
      if (typeof title !== 'string' || !title.trim()) return { ok: false, denied: false, error: 'empty title' };
      return single({ id: id, modification: { title: { new_title: title } } });
    });

    /*
     * Task fields through the full-replacement path, which changes only the
     * keys present (bridge 3415-3530). Only scheduledAt, completeBy and status
     * are ever sent; an unknown status is refused here because the host would
     * store it as 'todo'. A null date is not sent: the host would keep the old
     * value (note.dart:97-98), so it cannot clear a date. -> {ok, denied, error}
     */
    h.setTaskFields = safe(function (id, fields) {
      if (!sqlId(id) || !isObj(fields)) return { ok: false, denied: false, error: 'bad arguments' };
      var e = { id: id }, any = false;
      ['scheduledAt', 'completeBy'].forEach(function (k) {
        if (has(fields, k) && typeof fields[k] === 'string') { e[k] = fields[k]; any = true; }
      });
      if (has(fields, 'status')) {
        if (H.STATUSES.indexOf(fields.status) < 0) return { ok: false, denied: false, error: 'bad status' };
        e.status = fields.status; any = true;
      }
      if (!any) return { ok: false, denied: false, error: 'nothing to write' };
      return single(e);
    });

    /*
     * G3: a subnote toggle is an SQL UPDATE with its own approval (bridge
     * 703-727). ok means the statement ran, not that a row matched (the host
     * reports no row count): callers confirm with a 7.2 re-query.
     * -> {ok, denied, error}
     */
    h.setSubnoteDone = safe(function (noteId, subId, done) {
      if (!sqlId(noteId) || !sqlId(subId)) return { ok: false, denied: false, error: 'bad id' };
      return h.query(SQL.subnoteDone(noteId, subId, !!done)).then(function (r) {
        return { ok: r.ok, denied: !!r.denied, error: r.ok ? null : r.error };
      });
    });

    /*
     * One note per saveNotes call (§8, verification c): the host skips a note
     * that fails to build, so an empty savedNoteIds is the failure signal.
     * -> {ok, id, error}
     */
    h.createNote = safe(function (spec) {
      if (!isObj(spec)) return { ok: false, error: 'bad note' };
      var n = {};
      ['title', 'content', 'type', 'status', 'scheduledAt', 'completeBy'].forEach(function (k) {
        if (typeof spec[k] === 'string') n[k] = spec[k];
      });
      if (Array.isArray(spec.subNotes)) {
        n.subNotes = spec.subNotes.filter(isObj).map(function (s) { return { name: str(s.name), content: str(s.content) }; });
      }
      return raw('saveNotes', [[n]]).then(function (r) {
        if (!r || r.success !== true) return { ok: false, error: (r && r.error) || 'the note could not be created' };
        var ids = Array.isArray(r.savedNoteIds) ? r.savedNoteIds : [];
        if (!ids.length || typeof ids[0] !== 'string' || !ids[0]) return { ok: false, error: 'the note was not created' };
        return { ok: true, id: ids[0] };
      });
    });

    // The native picker (references only). -> {ok, notes, cancelled, reason, error}
    h.pickNotes = safe(function (options) {
      return raw('pickNotes', [isObj(options) ? options : {}]).then(function (r) {
        if (!r || r.success !== true) {
          var why = (r && r.error) || 'the note picker could not be opened';
          return { ok: false, notes: [], cancelled: false, reason: why === 'no_ui' ? 'no_ui' : '', error: why };
        }
        var notes = (Array.isArray(r.notes) ? r.notes : []).map(function (n) {
          return { id: str(n && n.id), title: str(n && n.title) };
        }).filter(function (n) { return sqlId(n.id); });
        if (r.cancelled === true || !notes.length) return { ok: true, cancelled: true, notes: [] };
        return { ok: true, cancelled: false, notes: notes };
      });
    });

    // Opens a note; resolves once the route is pushed. Arms the first-pointer
    // resume trigger (§7.6), since the WebView can stay "visible" under it.
    h.openNote = safe(function (id, replaceWindow) {
      if (!sqlId(id)) return { ok: false, error: 'bad id' };
      return raw('openNote', [id, replaceWindow === true]).then(function (r) {
        if (!r || r.success === false) return { ok: false, error: (r && r.error) || 'could not open the note' };
        h.armResume();
        return { ok: true };
      });
    });

    /* ---- launch context ---- */

    // Synchronous context reads never throw; a broken host reads as defaults.
    function sync(fn, dflt) { return function () { try { return fn.apply(this, arguments); } catch (e) { return typeof dflt === 'function' ? dflt() : dflt; } }; }
    h.locale = sync(function () {
      var s = S();
      var l = s && typeof s.locale === 'string' && s.locale ? s.locale : '';
      if (!l && global.navigator && typeof global.navigator.language === 'string') l = global.navigator.language;
      return l || 'en-US';
    }, 'en-US');
    // 'light' | 'dark' | null. Only a future host publishes it (M10, G1).
    h.theme = sync(function () {
      var s = S();
      return s && (s.theme === 'light' || s.theme === 'dark') ? s.theme : null;
    }, null);
    h.space = sync(function () {
      var s = S(), sp = s ? s.space : null;
      if (!isObj(sp)) return null;
      return { id: str(sp.id), name: str(sp.name), tags: spaceTags(sp) };
    }, null);
    // Notes, Params, locale and Space as launched (§10.1). A block-scoped note
    // resolves to parentNoteId; the transient id is kept apart and never stored.
    h.launch = sync(function () {
      var s = S() || {};
      var notes = (Array.isArray(s.Notes) ? s.Notes : []).filter(isObj).map(function (n) {
        var block = n.isBlockScope === true && sqlId(n.parentNoteId);
        return {
          id: block ? n.parentNoteId : str(n.id), title: str(n.title), content: str(n.content),
          blockScope: !!block, transientId: block ? str(n.id) : null
        };
      }).filter(function (n) { return !!n.id; });
      var params = {};
      if (isObj(s.Params)) Object.keys(s.Params).forEach(function (k) { params[k] = s.Params[k]; });
      return { notes: notes, params: params, locale: h.locale(), space: h.space(), theme: h.theme(), embed: params.mode === 'embed' };
    }, function () { return { notes: [], params: {}, locale: h.locale(), space: h.space(), theme: h.theme(), embed: false }; });

    // on('localechanged' | 'spacechanged' | 'themechanged', cb(detail)) -> off()
    h.on = function (name, cb) {
      var t = target();
      if (!t || typeof cb !== 'function' || !/^(localechanged|spacechanged|themechanged)$/.test(name)) return function () {};
      var fn = function (e) { try { cb(e ? e.detail : undefined); } catch (err) { /* a listener bug is not the host's */ } };
      t.addEventListener('synapse:' + name, fn);
      return function () { t.removeEventListener('synapse:' + name, fn); };
    };

    /* ---- §7.6 resume triggers ---- */

    var resumeCbs = [], wired = null, armed = false, lastFire = null, lastResumed = null, timer = null;
    h.visible = function () { var d = doc(); return !d || d.visibilityState !== 'hidden'; };
    function fire(reason, force) {
      var t = now();
      if (!force && lastFire !== null && t - lastFire < H.COALESCE_MS) return Promise.resolve([]);
      lastFire = t;
      return Promise.all(resumeCbs.slice().map(function (cb) {
        try { return Promise.resolve(cb(reason)).catch(function () { return undefined; }); } catch (e) { return Promise.resolve(undefined); }
      }));
    }
    h._fireResume = fire;
    function wire() {
      if (wired) return;
      var t = target(), d = doc(), cap = { capture: true, passive: true };
      var on = {
        focus: function () { fire('focus'); },
        pageshow: function () { fire('pageshow'); },
        // Disarmed even when coalesced: a trigger in the last 250 ms already refreshed.
        pointer: function () { if (armed) { armed = false; fire('pointer'); } },
        vis: function () { if (d.visibilityState !== 'hidden') fire('visible'); },
        // M9: the host's own route-return signal (M10, G2) where it exists.
        // It is never dropped behind another trigger (an interval tick just
        // before it would otherwise hide the return for up to 30 s); triggers
        // after it coalesce with it, a second resumed within 250 ms is one.
        // It disarms the first-pointer heuristic (no second refresh).
        resumed: function () {
          armed = false;
          var t = now();
          if (lastResumed !== null && t - lastResumed < H.COALESCE_MS) return;
          lastResumed = t;
          fire('resumed', true);
        }
      };
      if (t) {
        t.addEventListener('focus', on.focus);
        t.addEventListener('pageshow', on.pageshow);
        t.addEventListener('pointerdown', on.pointer, cap);
        t.addEventListener('synapse:resumed', on.resumed);
      }
      if (d && typeof d.addEventListener === 'function') d.addEventListener('visibilitychange', on.vis);
      var si = env.setInterval || global.setInterval;
      if (typeof si === 'function') timer = si(function () { if (h.visible()) fire('interval'); }, H.RESUME_MS);
      wired = function () {
        if (t) {
          t.removeEventListener('focus', on.focus);
          t.removeEventListener('pageshow', on.pageshow);
          t.removeEventListener('pointerdown', on.pointer, cap);
          t.removeEventListener('synapse:resumed', on.resumed);
        }
        if (d && typeof d.removeEventListener === 'function') d.removeEventListener('visibilitychange', on.vis);
        var ci = env.clearInterval || global.clearInterval;
        if (timer !== null && typeof ci === 'function') ci(timer);
        timer = null;
      };
      var s = S();
      if (s && s.__mock && typeof s.__mock._bind === 'function') s.__mock._bind(h);
    }
    h.armResume = function () { armed = true; };
    // onResume(cb) -> off(). cb(reason) may return a promise.
    h.onResume = function (cb) {
      if (typeof cb !== 'function') return function () {};
      resumeCbs.push(cb);
      wire();
      return function () {
        var i = resumeCbs.indexOf(cb);
        if (i >= 0) resumeCbs.splice(i, 1);
        if (!resumeCbs.length && wired) { wired(); wired = null; }
      };
    };

    return h;
  }

  var main = makeHost(function () { return global.Synapse; }, {});
  Object.keys(main).forEach(function (k) { H[k] = main[k]; });
  Object.defineProperty(H, 'lastRoundTripMs', { get: function () { return main.lastRoundTripMs; }, enumerable: true });
  Object.defineProperty(H, 'baselineMs', { get: function () { return main.baselineMs; }, enumerable: true });
  // A host bound to one Synapse object (the mock, or a second instance).
  H.create = function (synapse, env) { return makeHost(function () { return synapse; }, env); };

  /* ================================================================ mock */

  /*
   * A faithful port of the host's replace_text (the oracle for md.toggleEdit
   * and the mock's write path). Source: lib/services/note_modification_service.dart
   * (read 2026-09-26): _applyReplaceTextModification 555-613,
   * _sharedAffixLength 643-656, _sliceSection 660-683, _headingLevel 721-724.
   * Errors are thrown as in Dart. Dart's allMatches does not count overlaps,
   * and replaceFirst with a String pattern replaces the first occurrence literally.
   */
  var PORT = (H.port = (function () {
    var WS = '[\\t\\n\\v\\f\\r \\u0085\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff]';
    var TRIM = new RegExp('^' + WS + '+|' + WS + '+$', 'g');
    function trim(s) { return s.replace(TRIM, ''); }                      // Dart String.trim()
    // A PluginFacingException: since M10 its text reaches the plugin.
    function facing(msg) { var e = new Error(msg); e.pluginFacing = true; return e; }
    function headingLevel(line) {                                         // 721-724
      var m = /^(#+)\s+/.exec(line);
      return m ? m[1].length : null;
    }
    function sliceSection(content, section) {                             // 660-683
      var lines = content.split('\n');
      var headingIndex = -1;
      for (var i = 0; i < lines.length; i++) if (trim(lines[i]) === section) { headingIndex = i; break; }
      if (headingIndex === -1) throw facing('Section not found: ' + section);
      var hl = headingLevel(section), sectionEnd = lines.length;
      for (i = headingIndex + 1; i < lines.length; i++) {
        var level = headingLevel(trim(lines[i]));
        if (level !== null && hl !== null && level <= hl) { sectionEnd = i; break; }
      }
      return { before: lines.slice(0, headingIndex + 1), body: lines.slice(headingIndex + 1, sectionEnd), after: lines.slice(sectionEnd) };
    }
    function sharedAffixLength(a, b) {                                    // 643-656
      var maxShared = a.length < b.length ? a.length : b.length, prefix = 0, suffix = 0;
      while (prefix < maxShared && a[prefix] === b[prefix]) prefix++;
      while (suffix < maxShared - prefix && a[a.length - 1 - suffix] === b[b.length - 1 - suffix]) suffix++;
      return prefix + suffix;
    }
    function allMatches(hay, needle) {
      var n = 0, i = hay.indexOf(needle);
      while (i >= 0) { n++; i = hay.indexOf(needle, i + needle.length); }
      return n;
    }
    function replaceText(content, oldText, newText, section) {           // 555-613
      if (typeof oldText !== 'string' || oldText.length === 0) throw new Error('replace_text requires a non-empty "old_text" string.');
      if (typeof newText !== 'string') throw new Error('replace_text requires a "new_text" string.');
      var scope = (section !== null && section !== undefined && section.length) ? sliceSection(content, section) : null;
      var target = scope === null ? content : scope.body.join('\n');
      var matches = allMatches(target, oldText);
      // M10 texts (note_modification_service.dart 657-668), plugin-facing.
      var scopeLabel = scope === null ? 'the note' : 'section "' + section + '"';
      if (matches === 0) {
        if (newText.length && allMatches(target, newText) === 1 && sharedAffixLength(oldText, newText) * 2 >= newText.length) return content;
        throw facing('replace_text: "old_text" was not found in ' + scopeLabel + '; no changes were made. Read the note and copy the text to replace exactly. If you already applied this edit, no further action is needed.');
      }
      if (matches > 1) throw facing('replace_text: "old_text" matched ' + matches + ' places in ' + scopeLabel + '; no changes were made. Provide a longer, unique old_text or add "section" to disambiguate.');
      var at = target.indexOf(oldText);
      var updated = target.slice(0, at) + newText + target.slice(at + oldText.length);
      if (scope === null) return updated;
      return scope.before.concat(updated.split('\n'), scope.after).join('\n');
    }
    // _applyContentModification (note_modification_service.dart:470-530) and
    // applyWholeContentAction (619-633). Section edits other than
    // replace_text are not used by Gantt and are not modelled.
    function contentModification(current, mod) {
      var inferred = has(mod, 'old_text') && has(mod, 'new_text') ? 'replace_text' : 'no-op';
      var action = typeof mod.action === 'string' ? mod.action : inferred;
      var text = typeof mod.text === 'string' ? mod.text : '';
      var section = typeof mod.section === 'string' ? mod.section : null;
      if (action === 'replace_text') return replaceText(current, mod.old_text, mod.new_text, section);
      if (action === 'no-op' || (text === '' && action !== 'replace')) return current;
      if (section !== null && section.length) throw new Error('mock: section edits are not modelled');
      if (action === 'append') return current + '\n' + text;
      if (action === 'prepend') return text + '\n' + current;
      if (action === 'replace') return text;
      return current;
    }
    return { replaceText: replaceText, sliceSection: sliceSection, sharedAffixLength: sharedAffixLength, trim: trim, contentModification: contentModification };
  })());

  /* ---- SQL functions with SQLite's character semantics ---- */

  // length(): characters before the first NUL.
  function sLength(s) {
    if (typeof s !== 'string') return null;
    var i = s.indexOf('\u0000');
    return Array.from(i >= 0 ? s.slice(0, i) : s).length;
  }
  // instr(): 1-based character index of the first occurrence, 0 if none.
  function sInstr(s, n) {
    if (typeof s !== 'string') return null;
    if (n === '') return 1;
    var i = s.indexOf(n);
    return i < 0 ? 0 : Array.from(s.slice(0, i)).length + 1;
  }
  // substr(X, Y, Z) with Y >= 1. Like length() it stops at U+0000
  // (sqlite func.c substrFunc walks the text to its terminator).
  function sSubstr(s, y, z) {
    if (typeof s !== 'string') return null;
    var i = s.indexOf('\u0000');
    return Array.from(i >= 0 ? s.slice(0, i) : s).slice(y - 1, y - 1 + z).join('');
  }
  H.sqlite = { length: sLength, instr: sInstr, substr: sSubstr };

  // A query shape: literal text with {IDS} {STR} {INT} {ID} {ANY} holes.
  function tpl(s) {
    var HOLES = { IDS: "((?:'[A-Za-z0-9_-]+',\\s?)*'[A-Za-z0-9_-]+')", STR: "'((?:[^']|'')*)'", INT: '(\\d+)', ID: "'([A-Za-z0-9_-]+)'", ANY: '(.+?)' };
    var re = s.split(/\{(IDS|STR|INT|ID|ANY)\}/).map(function (part, i) {
      return i % 2 ? HOLES[part] : part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    }).join('');
    return new RegExp('^' + re + '$', 'i');
  }
  function ids(listText) { return listText.split(',').map(function (x) { return x.trim().replace(/^'|'$/g, ''); }); }
  function unq(s) { return s.replace(/''/g, "'"); }

  var Q = {
    select1: tpl('SELECT 1'),
    list: tpl('SELECT id, title FROM notes ORDER BY id LIMIT {INT} OFFSET {INT}'),
    meta: tpl('SELECT id, title, type, status, scheduledAt, completeBy, updatedAt, isArchived, length(content) AS clen FROM notes WHERE id IN ({IDS}) ORDER BY id LIMIT {INT}'),
    subnotes: tpl("SELECT noteId, COUNT(*) AS total, SUM(isCompleted) AS done, group_concat(isCompleted, '') AS bits FROM (SELECT noteId, isCompleted FROM subnotes WHERE noteId IN ({IDS}) ORDER BY noteId, createdAt, rowid) GROUP BY noteId LIMIT {INT}"),
    children: tpl("SELECT noteId, COUNT(*) AS total, SUM(d) AS done, group_concat(d, '') AS bits FROM (SELECT r.fromNoteId AS noteId, CASE WHEN n.status = 'complete' THEN 1 ELSE 0 END AS d FROM relationships r JOIN notes n ON n.id = r.toNoteId WHERE r.type = 'subnote' AND n.type = 'task' AND r.fromNoteId IN ({IDS}) ORDER BY r.fromNoteId, r.createdAt, r.rowid) GROUP BY noteId LIMIT {INT}"),
    windows: tpl('SELECT id, length(content) AS clen, CASE WHEN length(content) <= {INT} THEN content ELSE substr(content, max(1, instr(content, {STR}) - {INT}), {INT}) END AS win, CASE WHEN length(content) <= {INT} THEN 1 ELSE max(1, instr(content, {STR}) - {INT}) END AS off FROM notes WHERE id IN ({IDS}) LIMIT {INT}'),
    range: tpl('SELECT length(content) AS clen, substr(content, {INT}, {INT}) AS page FROM notes WHERE id = {ID} LIMIT {INT}'),
    note: tpl('SELECT content, length(content) AS clen, updatedAt FROM notes WHERE id = {ID} LIMIT {INT}'),
    chartsCounted: tpl("SELECT n.id, n.title, n.updatedAt, (length(n.content) - length(replace(n.content, {STR}, ''))) / {INT} AS tasks, substr(n.content, max(1, instr(n.content, {STR}) - {INT}), {INT}) AS head FROM notes n WHERE instr(n.content, {STR}) > 0 AND n.isArchived = 0 AND {ANY} ORDER BY n.updatedAt DESC LIMIT {INT} OFFSET {INT}"),
    charts: tpl('SELECT n.id, n.title, n.updatedAt, substr(n.content, max(1, instr(n.content, {STR}) - {INT}), {INT}) AS head FROM notes n WHERE instr(n.content, {STR}) > 0 AND n.isArchived = 0 AND {ANY} ORDER BY n.updatedAt DESC LIMIT {INT} OFFSET {INT}'),
    referencing: tpl('SELECT n.id, n.title, n.updatedAt, substr(n.content, max(1, instr(n.content, {STR}) - {INT}), {INT}) AS head FROM notes n WHERE instr(n.content, {STR}) > 0 AND instr(substr(n.content, instr(n.content, {STR})), {STR}) > 0 AND n.isArchived = 0 AND {ANY} ORDER BY n.updatedAt DESC LIMIT {INT}'),
    subnoteDone: tpl('UPDATE subnotes SET isCompleted = {INT} WHERE id = {ID} AND noteId = {ID}'),
    subnoteItems: tpl('SELECT id, name, isCompleted FROM subnotes WHERE noteId = {ID} ORDER BY createdAt, rowid LIMIT {INT}'),
    childItems: tpl("SELECT n.id, n.title, n.status FROM relationships r JOIN notes n ON n.id = r.toNoteId WHERE r.type = 'subnote' AND n.type = 'task' AND r.fromNoteId = {ID} ORDER BY r.createdAt, r.rowid LIMIT {INT}")
  };

  var SPACE_ALL = "EXISTS (SELECT 1 FROM note_tags nt JOIN tags tg ON tg.id = nt.tagId WHERE nt.noteId = n.id AND tg.name = 'all-spaces')";
  // Evaluates H.spaceClause's shape against a note's tags; null if unknown.
  function spaceTest(clause) {
    var c = clause.trim();
    if (c === '1=1') return function () { return true; };
    var head = '((', tail = ') OR ' + SPACE_ALL + ')';
    if (c.indexOf(head) !== 0 || c.slice(-tail.length) !== tail) return null;
    var inner = c.slice(head.length, c.length - tail.length);
    var one = /^EXISTS \(SELECT 1 FROM note_tags nt JOIN tags tg ON tg\.id = nt\.tagId WHERE nt\.noteId = n\.id AND tg\.name = '((?:[^']|'')*)'\)( AND |$)/;
    var names = [], m;
    while (inner.length) {
      m = one.exec(inner);
      if (!m) return null;
      names.push(unq(m[1]));
      inner = inner.slice(m[0].length);
    }
    return function (tags) {
      return tags.indexOf('all-spaces') >= 0 || names.every(function (t) { return tags.indexOf(t) >= 0; });
    };
  }

  function defaultStorage() {
    try { if (global.sessionStorage && typeof global.sessionStorage.getItem === 'function') return global.sessionStorage; } catch (e) { /* blocked */ }
    return typeof Map === 'function' ? new Map() : null;
  }
  function storageAdapter(st) {
    if (st && typeof st.getItem === 'function') return { get: function (k) { return st.getItem(k); }, set: function (k, v) { st.setItem(k, v); } };
    if (st && typeof st.get === 'function') return { get: function (k) { return st.has(k) ? st.get(k) : null; }, set: function (k, v) { st.set(k, v); } };
    var m = {};
    return { get: function (k) { return has(m, k) ? m[k] : null; }, set: function (k, v) { m[k] = v; } };
  }

  // A minimal event target for node.
  function emitter() {
    var ls = {};
    return {
      visibilityState: 'visible',
      addEventListener: function (t, fn) { (ls[t] = ls[t] || []).push(fn); },
      removeEventListener: function (t, fn) { var a = ls[t] || [], i = a.indexOf(fn); if (i >= 0) a.splice(i, 1); },
      dispatchEvent: function (ev) { (ls[ev.type] || []).slice().forEach(function (fn) { fn(ev); }); return true; },
      count: function (t) { return (ls[t] || []).length; }
    };
  }

  /*
   * The notes database the mock serves. Shared by passing `{db: other.db}`
   * to a second installMock (two instances over one set of notes).
   * seed: [note] or {notes:[note], relationships:[row]}; a note may carry
   * `subnotes: [{id?, name, isCompleted, createdAt?}]` and `tags: [name]`.
   */
  function newDb(seed) {
    var db = { notes: {}, order: [], subnotes: [], relationships: [], clock: 1790000000000, seq: 0 };
    db.tick = function () { db.clock += 1000; return db.clock; };
    db.put = function (n) {
      n = n || {};
      var id = typeof n.id === 'string' && n.id ? n.id : null;
      while (!id || db.notes[id]) id = 'mock-' + (++db.seq).toString(36) + '-0000-4000-8000-' + ('000000000000' + db.seq).slice(-12);
      var rec = {
        id: id, title: typeof n.title === 'string' ? n.title : 'Untitled',
        content: typeof n.content === 'string' ? n.content : '',
        type: n.type === 'task' ? 'task' : 'note',
        status: typeof n.status === 'string' ? n.status : (n.type === 'task' ? 'todo' : null),
        scheduledAt: typeof n.scheduledAt === 'string' ? n.scheduledAt : null,
        completeBy: typeof n.completeBy === 'string' ? n.completeBy : null,
        updatedAt: typeof n.updatedAt === 'number' ? n.updatedAt : db.tick(),
        isArchived: n.isArchived ? 1 : 0,
        tags: Array.isArray(n.tags) ? n.tags.filter(function (t) { return typeof t === 'string'; }) : []
      };
      if (!db.notes[id]) db.order.push(id);
      db.notes[id] = rec;
      (Array.isArray(n.subnotes) ? n.subnotes : []).forEach(function (s) { db.addSubnote(id, s); });
      return rec;
    };
    db.addSubnote = function (noteId, s) {
      s = s || {};
      var row = {
        id: typeof s.id === 'string' ? s.id : 'sub-' + (++db.seq),
        noteId: noteId, name: typeof s.name === 'string' ? s.name : '', content: typeof s.content === 'string' ? s.content : '',
        createdAt: typeof s.createdAt === 'number' ? s.createdAt : db.tick(),
        isCompleted: s.isCompleted ? 1 : 0
      };
      db.subnotes.push(row);
      return row;
    };
    db.link = function (from, to, type, createdAt) {
      var row = { fromNoteId: from, toNoteId: to, type: type || 'subnote', createdAt: typeof createdAt === 'number' ? createdAt : db.tick() };
      db.relationships.push(row);
      return row;
    };
    db.all = function () { return db.order.filter(function (id) { return !!db.notes[id]; }).map(function (id) { return db.notes[id]; }); };
    var list = Array.isArray(seed) ? seed : (isObj(seed) && Array.isArray(seed.notes) ? seed.notes : []);
    list.forEach(db.put);
    if (isObj(seed) && Array.isArray(seed.relationships)) {
      seed.relationships.forEach(function (r) { db.link(r.fromNoteId, r.toNoteId, r.type, r.createdAt); });
    }
    return db;
  }
  H.mockDb = newDb;

  /*
   * installMock(seed, opts) -> mock handle, and (unless opts.global === false)
   * global.Synapse. opts:
   *   storage     Map or Storage for appState (default sessionStorage in a
   *               browser, a Map in node), key 'gt-mock-appstate:<appId>'
   *   appId       default 'gantt-mock'
   *   db          another mock's db, to share its notes
   *   latency     {<bridge call>: ms} or fn(name, args) -> ms
   *   approve     default dialog answer 'session' | 'once' | 'deny' (default 'session')
   *   approvalMs  how long the dialog stays up (default 0)
   *   sqlApprove  the same for SQL writes (default 'session')
   *   sessionApproved, sqlSessionApproved   start approved
   *   Notes, Params, locale, space, theme   the launch context
   *   target, doc  event targets (default window/document when global, else fakes)
   *   errors      'redacted' (default, 'Updating note <id> failed. See the app
   *               log for details.') or 'verbatim' (the M10 bridge: 'Updating
   *               note <id> failed: <message>' for the replace_text and
   *               section failures, other errors still redacted); saveRegion
   *               reads only the id
   * See the hook list at the end of this function.
   */
  H.installMock = function (seed, opts) {
    opts = opts || {};
    var db = opts.db || newDb(seed);
    var appId = typeof opts.appId === 'string' && opts.appId ? opts.appId : 'gantt-mock';
    var rawStorage = opts.storage || defaultStorage();
    var storage = storageAdapter(rawStorage);
    var KEY = 'gt-mock-appstate:' + appId;
    var install = opts.global !== false;
    var dom = install && typeof global.addEventListener === 'function' && !!global.document;
    var mock = {
      db: db, storage: rawStorage, appId: appId, key: KEY,
      calls: {}, events: [], updates: [], saves: [], queries: [], picks: [], opened: [],
      latency: opts.latency || {},
      approve: opts.approve || 'session', approvalMs: opts.approvalMs || 0, approvals: [],
      sqlApprove: opts.sqlApprove || 'session', sqlApprovalMs: opts.sqlApprovalMs || 0, sqlApprovals: [],
      sessionApproved: opts.sessionApproved === true, sqlSessionApproved: opts.sqlSessionApproved === true,
      dialogs: 0, sqlDialogs: 0,
      unmounted: false, halted: false, trap: null, rowCap: H.ROW_CAP,
      win: opts.target || (dom ? global : emitter()),
      doc: opts.doc || (dom ? global.document : emitter()),
      hosts: [], intervals: [],
      errors: opts.errors === 'verbatim' ? 'verbatim' : 'redacted'
    };
    var seq = 0, loadFails = 0, storeFails = 0, holdNext = 0, parked = [], inflight = [], edits = [], truncs = [], refused = {}, scripts = {};
    function NEVER() { return new Promise(function () {}); }
    function log(method, phase, extra) {
      var e = { seq: ++seq, method: method, phase: phase };
      if (extra !== undefined) e.arg = extra;
      mock.events.push(e);
      return e;
    }
    function latencyOf(name, args) {
      var l = mock.latency;
      var ms = typeof l === 'function' ? l(name, args) : (isObj(l) ? l[name] : 0);
      return typeof ms === 'number' && ms > 0 ? ms : 0;
    }
    function wait(ms) { return ms > 0 ? new Promise(function (r) { setTimeout(r, ms); }) : Promise.resolve(); }
    function deliver(method, v) {
      if (mock.halted) return NEVER();
      log(method, 'resolve');
      return v;
    }
    function scripted(name, arg) {
      var s = scripts[name];
      if (typeof s === 'function') return s(arg);
      if (Array.isArray(s) && s.length) return s.shift();
      return undefined;
    }
    function enter(name, args) {
      mock.calls[name] = (mock.calls[name] || 0) + 1;
      log(name, 'call', args && args.length ? clone(args[0]) : undefined);
    }
    // The common path: enter, wait, apply, deliver. `apply` runs once the
    // latency has passed, even if the page died meanwhile (the host still
    // ran it); the answer is never delivered after a halt.
    function call(name, args, apply) {
      if (mock.halted) { enter(name, args); return NEVER(); }
      enter(name, args);
      return wait(latencyOf(name, args)).then(function () {
        var canned = scripted(name, args ? args[0] : undefined);
        var v = canned !== undefined && canned !== null ? canned : apply();
        return Promise.resolve(v).then(function (r) { return deliver(name, r); });
      });
    }

    /* ---- note helpers and hooks ---- */
    mock.note = function (id) { return db.notes[id] || null; };
    mock.content = function (id) { return db.notes[id] ? db.notes[id].content : null; };
    mock.put = function (n) { return db.put(n); };
    // An external edit at this moment (bumps updatedAt).
    mock.setNote = function (id, content) {
      var n = db.notes[id];
      if (!n) return null;
      n.content = String(content == null ? '' : content);
      n.updatedAt = db.tick();
      return n;
    };
    mock.addSubnote = function (noteId, s) { return db.addSubnote(noteId, s); };
    mock.link = function (from, to, type, createdAt) { return db.link(from, to, type, createdAt); };
    // fn(mock) runs just before the next write applies ('beforeWrite', the
    // default: between the save's read and its write) or before the next
    // runQuery ('beforeRead').
    mock.outsideEdit = function (fn, when) { edits.push({ fn: fn, when: when === 'beforeRead' ? 'beforeRead' : 'beforeWrite' }); };
    function runEdits(when) {
      var keep = [];
      edits.forEach(function (e) { if (e.when === when) e.fn(mock); else keep.push(e); });
      edits = keep;
    }
    // Every string column of the next `times` queries (default: until
    // cleared with truncateReads(null)) is cut to n UTF-16 units: a
    // CursorWindow-style truncation. length() still reports the real length.
    mock.truncateReads = function (n, times) { truncs = n === null ? [] : [{ n: n, times: typeof times === 'number' ? times : Infinity }]; };
    mock.failLoads = function (n) { loadFails = Math.max(0, n | 0); };
    mock.failStores = function (n) { storeFails = Math.max(0, n | 0); };
    // Updates to this note throw inside the host (an immutable binding), so
    // they come back redacted.
    mock.refuse = function (id, on) { if (on === false) delete refused[id]; else refused[id] = 1; };
    // Canned answers for a bridge call: fn(arg) or an array consumed in order;
    // undefined falls through to the mock.
    mock.script = function (name, s) { scripts[name] = s; };
    mock.state = function () { var t = storage.get(KEY); return t === null || t === undefined ? null : JSON.parse(t); };
    mock.setState = function (st) { storage.set(KEY, JSON.stringify(st)); };
    mock.count = function (name) { return mock.calls[name] || 0; };
    mock.resetCounts = function () { mock.calls = {}; mock.events.length = 0; mock.updates.length = 0; mock.queries.length = 0; mock.saves.length = 0; };
    // updateNotes entries that would replace a whole note body.
    mock.wholeReplaces = function () {
      var out = [];
      mock.updates.forEach(function (list) {
        (Array.isArray(list) ? list : []).forEach(function (e) {
          if (!isObj(e)) return;
          if (has(e, 'content')) out.push(e);
          var c = isObj(e.modification) && isObj(e.modification.content) ? e.modification.content : null;
          if (c && c.action === 'replace') out.push(e);
        });
      });
      return out;
    };

    /*
     * Crash simulation (§9.1.5 walkthroughs). 'beforeUpdateNotes': the
     * in-flight updateNotes that has not applied yet (or the next one) never
     * applies; 'updateNotes': it applies and its answer never arrives. From
     * that point every bridge call of this mock never resolves.
     */
    mock.haltAfter = function (point) {
      if (point === 'beforeUpdateNotes') {
        var live = inflight.filter(function (r) { return !r.applied; });
        if (live.length) {
          live.forEach(function (r) {
            r.killed = true;
            var i = parked.indexOf(r);
            if (i >= 0) parked.splice(i, 1);
            if (r.open) { var o = r.open; r.open = null; o(); }
          });
          mock.halt();
        } else mock.trap = point;
      } else if (point === 'updateNotes') {
        var pending = inflight.filter(function (r) { return !r.applied; });
        if (!pending.length && inflight.some(function (r) { return r.applied && !r.delivered; })) mock.halt();
        else mock.trap = point;
      }
    };
    mock.halt = function () { mock.halted = true; mock.trap = null; };
    // Parks the next updateNotes before the host applies it.
    mock.holdUpdateNotes = function () { holdNext++; };
    /*
     * release('apply'): the oldest parked call applies and its answer stays
     * parked. release(): it applies if it has not, and its answer is handed
     * back. Resolves when that has happened (never waits on a halted page).
     */
    mock.release = function (stage) {
      var r = parked[0];
      if (!r) return Promise.resolve(false);
      return new Promise(function (resolve) {
        if (stage === 'apply') {
          r.holdAnswer = true;
          r.onApplied = function () { resolve(true); };
        } else {
          parked.shift();
          r.holdAnswer = false;
          r.onDone = function () { resolve(true); };
          if (r.answerGate) r.answerGate();
        }
        if (r.open) { var o = r.open; r.open = null; o(); }
      });
    };
    mock.parked = function () { return parked.length; };
    // Fires every onResume callback of the hosts bound to this mock (§7.6).
    mock.resume = function () {
      return Promise.all(mock.hosts.map(function (h) { return h._fireResume('mock', true); }));
    };
    mock._bind = function (h) { if (mock.hosts.indexOf(h) < 0) mock.hosts.push(h); };
    function event(name, detail) {
      var CE = global.CustomEvent;
      return mock.win === global && typeof CE === 'function' ? new CE(name, { detail: detail }) : { type: name, detail: detail };
    }
    // A host context change: 'localechanged', 'spacechanged' or 'themechanged'.
    mock.emit = function (name, detail) {
      if (name === 'localechanged') syn.locale = detail;
      if (name === 'spacechanged') syn.space = detail;
      if (name === 'themechanged') syn.theme = detail;
      mock.win.dispatchEvent(event('synapse:' + name, detail));
    };
    // Node only: flip visibility and dispatch visibilitychange; dispatch a
    // plain window event ('focus', 'pageshow', 'pointerdown').
    mock.setVisible = function (v) {
      mock.doc.visibilityState = v ? 'visible' : 'hidden';
      mock.doc.dispatchEvent({ type: 'visibilitychange' });
    };
    mock.dispatch = function (type) { mock.win.dispatchEvent(mock.win === global && typeof global.Event === 'function' ? new global.Event(type) : { type: type }); };
    // Fires the fake 30 s interval (node).
    mock.tickInterval = function () { mock.intervals.slice().forEach(function (f) { f(); }); };

    /* ---- SQL ---- */

    function runSelect(sql) {
      var m, all = db.all();
      if ((m = Q.select1.exec(sql))) return [{ '1': 1 }];
      if ((m = Q.list.exec(sql))) {
        var sorted = all.slice().sort(function (a, b) { return a.id < b.id ? -1 : a.id > b.id ? 1 : 0; });
        return sorted.slice(+m[2], +m[2] + +m[1]).map(function (n) { return { id: n.id, title: n.title }; });
      }
      if ((m = Q.meta.exec(sql))) {
        var want = ids(m[1]);
        return all.filter(function (n) { return want.indexOf(n.id) >= 0; })
          .sort(function (a, b) { return a.id < b.id ? -1 : a.id > b.id ? 1 : 0; })
          .slice(0, +m[2]).map(function (n) {
            return { id: n.id, title: n.title, type: n.type, status: n.status, scheduledAt: n.scheduledAt, completeBy: n.completeBy, updatedAt: n.updatedAt, isArchived: n.isArchived, clen: sLength(n.content) };
          });
      }
      if ((m = Q.subnotes.exec(sql))) {
        var sw = ids(m[1]);
        var subs = db.subnotes.filter(function (s) { return sw.indexOf(s.noteId) >= 0; })
          .sort(function (a, b) { return a.noteId < b.noteId ? -1 : a.noteId > b.noteId ? 1 : a.createdAt - b.createdAt; });
        return aggregate(subs.map(function (s) { return { noteId: s.noteId, d: s.isCompleted }; })).slice(0, +m[2]);
      }
      if ((m = Q.children.exec(sql))) {
        var cw = ids(m[1]);
        var rels = db.relationships.filter(function (r) {
          var child = db.notes[r.toNoteId];
          return r.type === 'subnote' && child && child.type === 'task' && cw.indexOf(r.fromNoteId) >= 0;
        }).sort(function (a, b) { return a.fromNoteId < b.fromNoteId ? -1 : a.fromNoteId > b.fromNoteId ? 1 : a.createdAt - b.createdAt; });
        return aggregate(rels.map(function (r) { return { noteId: r.fromNoteId, d: db.notes[r.toNoteId].status === 'complete' ? 1 : 0 }; })).slice(0, +m[2]);
      }
      if ((m = Q.subnoteItems.exec(sql))) {
        return db.subnotes.filter(function (s) { return s.noteId === m[1]; })
          .sort(function (a, b) { return a.createdAt - b.createdAt; }).slice(0, +m[2])
          .map(function (s) { return { id: s.id, name: s.name, isCompleted: s.isCompleted }; });
      }
      if ((m = Q.childItems.exec(sql))) {
        return db.relationships.filter(function (r) {
          var child = db.notes[r.toNoteId];
          return r.type === 'subnote' && child && child.type === 'task' && r.fromNoteId === m[1];
        }).sort(function (a, b) { return a.createdAt - b.createdAt; }).slice(0, +m[2]).map(function (r) {
          var n = db.notes[r.toNoteId];
          return { id: n.id, title: n.title, status: n.status };
        });
      }
      if ((m = Q.windows.exec(sql))) {
        // holes: 1 len, 2 needle, 3 back, 4 size, 5 len, 6 needle, 7 back, 8 ids, 9 limit
        if (m[1] !== m[5] || m[2] !== m[6] || m[3] !== m[7]) throw new Error('mock: inconsistent window query');
        var len = +m[1], needle = unq(m[2]), back = +m[3], size = +m[4], ww = ids(m[8]);
        return all.filter(function (n) { return ww.indexOf(n.id) >= 0; }).slice(0, +m[9]).map(function (n) {
          var clen = sLength(n.content);
          var at = Math.max(1, sInstr(n.content, needle) - back);
          return { id: n.id, clen: clen, win: clen <= len ? n.content : sSubstr(n.content, at, size), off: clen <= len ? 1 : at };
        });
      }
      if ((m = Q.range.exec(sql))) {
        var rn = db.notes[m[3]];
        return rn ? [{ clen: sLength(rn.content), page: sSubstr(rn.content, Math.max(1, +m[1]), +m[2]) }].slice(0, +m[4]) : [];
      }
      if ((m = Q.note.exec(sql))) {
        var nn = db.notes[m[1]];
        return nn ? [{ content: nn.content, clen: sLength(nn.content), updatedAt: nn.updatedAt }].slice(0, +m[2]) : [];
      }
      var counted = Q.chartsCounted.exec(sql), plain = counted ? null : Q.charts.exec(sql);
      if (counted || plain) {
        var c = counted || plain, o = counted ? 2 : 0;
        // counted holes: 1 lit, 2 div, 3 fence, 4 back, 5 len, 6 fence, 7 space, 8 limit, 9 offset
        // plain holes:   1 fence, 2 back, 3 len, 4 fence, 5 space, 6 limit, 7 offset
        var fence = unq(c[1 + o]), fence2 = unq(c[4 + o]), test = spaceTest(c[5 + o]);
        if (fence !== fence2 || !test) throw new Error('mock: unsupported chart query');
        var rows = all.filter(function (n) { return sInstr(n.content, fence) > 0 && !n.isArchived && test(n.tags); })
          .sort(function (a, b) { return b.updatedAt - a.updatedAt; });
        rows = rows.slice(+c[7 + o], +c[7 + o] + +c[6 + o]);
        return rows.map(function (n) {
          var r = { id: n.id, title: n.title, updatedAt: n.updatedAt };
          if (counted) {
            var lit = unq(counted[1]);
            r.tasks = Math.trunc((sLength(n.content) - sLength(n.content.split(lit).join(''))) / +counted[2]);
          }
          r.head = sSubstr(n.content, Math.max(1, sInstr(n.content, fence) - +c[2 + o]), +c[3 + o]);
          return r;
        });
      }
      if ((m = Q.referencing.exec(sql))) {
        // holes: 1 fence, 2 back, 3 len, 4 fence, 5 fence, 6 noteId, 7 space, 8 limit
        var f = unq(m[1]), noteId = unq(m[6]), st = spaceTest(m[7]);
        if (f !== unq(m[4]) || f !== unq(m[5]) || !st) throw new Error('mock: unsupported chooser query');
        return all.filter(function (n) {
          var at = sInstr(n.content, f);
          return at > 0 && sInstr(sSubstr(n.content, at, Infinity), noteId) > 0 && !n.isArchived && st(n.tags);
        }).sort(function (a, b) { return b.updatedAt - a.updatedAt; }).slice(0, +m[8]).map(function (n) {
          return { id: n.id, title: n.title, updatedAt: n.updatedAt, head: sSubstr(n.content, Math.max(1, sInstr(n.content, f) - +m[2]), +m[3]) };
        });
      }
      return null;
    }
    // GROUP BY noteId over rows already in (noteId, createdAt) order.
    function aggregate(list) {
      var out = [], by = {};
      list.forEach(function (x) {
        var g = by[x.noteId];
        if (!g) { g = by[x.noteId] = { noteId: x.noteId, total: 0, done: 0, bits: '' }; out.push(g); }
        g.total++; g.done += x.d; g.bits += String(x.d);
      });
      return out;
    }
    function cut(rows) {
      if (!truncs.length) return rows;
      var t = truncs[0];
      t.times--;
      if (t.times <= 0) truncs = [];
      return rows.map(function (r) {
        var o = {};
        Object.keys(r).forEach(function (k) { o[k] = typeof r[k] === 'string' && r[k].length > t.n ? r[k].slice(0, t.n) : r[k]; });
        return o;
      });
    }
    function sqlApproval() {
      if (mock.sqlSessionApproved) return Promise.resolve(true);
      mock.sqlDialogs++;
      if (mock.unmounted) return Promise.resolve(false);
      var ans = mock.sqlApprovals.length ? mock.sqlApprovals.shift() : mock.sqlApprove;
      return wait(mock.sqlApprovalMs).then(function () {
        if (ans === 'session') mock.sqlSessionApproved = true;
        return ans !== 'deny';
      });
    }

    var syn = {
      Notes: [], Params: {}, locale: typeof opts.locale === 'string' ? opts.locale : 'en-US',
      space: isObj(opts.space) ? opts.space : null,
      __mock: mock,
      runQuery: function (sql) {
        var text = String(sql);
        mock.queries.push(text);
        return call('runQuery', [text], function () {
          runEdits('beforeRead');
          var q = text.replace(/\s+/g, ' ').trim();
          if (!isReadOnly(q)) {
            return sqlApproval().then(function (yes) {
              if (!yes) return { success: false, error: H.SQL_DENIED };
              var m = Q.subnoteDone.exec(q);
              if (!m) return { success: false, error: 'mock: unsupported write' };
              db.subnotes.forEach(function (s) { if (s.id === m[2] && s.noteId === m[3]) s.isCompleted = +m[1] ? 1 : 0; });
              return { success: true, data: [] };
            });
          }
          var rows;
          try { rows = runSelect(q); } catch (e) { return { success: false, error: msg(e) }; }
          if (rows === null) return { success: false, error: 'mock: unsupported query: ' + q.slice(0, 120) };
          rows = cut(rows);
          var total = rows.length, out = { success: true, data: rows.slice(0, mock.rowCap) };
          if (total > mock.rowCap) { out.truncated = true; out.totalRows = total; }
          return out;
        });
      },
      updateNotes: function (list) {
        return updateNotes(list);
      },
      saveNotes: function (list) {
        mock.saves.push(clone(list || []));
        return call('saveNotes', [list], function () {
          var saved = [];
          (Array.isArray(list) ? list : []).forEach(function (n) {
            if (!isObj(n)) return;
            // buildNote: trims title and content (note_modification_service.dart:278-359);
            // addNote stamps the active Space's tags (app_provider.dart:352-357).
            var title = typeof n.title === 'string' ? n.title.trim() : 'Untitled Note';
            var type = n.type === 'task' ? 'task' : 'note';
            var tags = (Array.isArray(n.tags) ? n.tags.map(String) : []).concat(syn.space && Array.isArray(syn.space.tags) ? syn.space.tags : []);
            var rec = db.put({
              title: title, content: typeof n.content === 'string' ? n.content.trim() : '', type: type,
              status: type === 'task' ? (H.STATUSES.indexOf(n.status) >= 0 ? n.status : 'todo') : null,
              scheduledAt: type === 'task' && n.scheduledAt != null ? String(n.scheduledAt) : null,
              completeBy: type === 'task' && n.completeBy != null ? String(n.completeBy) : null,
              tags: tags
            });
            // One saveNotes stamps its subnotes in the same millisecond on the
            // host, so only rowid (insertion order here) orders them.
            var at = db.tick();
            (Array.isArray(n.subNotes) ? n.subNotes : []).forEach(function (s) {
              if (isObj(s)) db.addSubnote(rec.id, { name: String(s.name || s.title || 'Untitled Task').trim(), content: String(s.content || '').trim(), isCompleted: s.isCompleted === true, createdAt: at });
            });
            saved.push(rec.id);
          });
          return { success: true, savedCount: saved.length, savedNoteIds: saved };
        });
      },
      pickNotes: function (options) {
        mock.picks.push(clone(options || {}));
        return call('pickNotes', [options], function () {
          // Like the host (user_app_web_view.dart:346-373, note_selection_dialog.dart:78-88
          // and 412): the dialog starts with preselectedIds ticked and returns
          // the whole selection, so they come back with the user's picks,
          // unless untick (mock.pickUntick) removed them. null is a cancel.
          var a = mock.pickAnswer;
          if (a === 'no_ui') return { success: false, error: 'no_ui' };
          if (!Array.isArray(a)) return { success: true, cancelled: true, notes: [] };
          var o = isObj(options) ? options : {}, untick = Array.isArray(mock.pickUntick) ? mock.pickUntick : [];
          var pre = (Array.isArray(o.preselectedIds) ? o.preselectedIds : []).map(String).filter(function (id) { return !!db.notes[id] && untick.indexOf(id) < 0; });
          var out = [];
          pre.concat(a).forEach(function (id) { if (db.notes[id] && out.indexOf(id) < 0) out.push(id); });
          if (o.multiSelect === false) out = out.slice(-1);
          return { success: true, notes: out.map(function (id) { return { id: id, title: db.notes[id].title }; }) };
        });
      },
      openNote: function (id, replaceWindow) {
        mock.opened.push({ id: id, replaceWindow: replaceWindow === true });
        return call('openNote', [id], function () {
          return db.notes[id] ? { success: true } : { success: false, error: 'Note not found: ' + id };
        });
      },
      loadAppState: function () {
        return call('loadAppState', [], function () {
          if (loadFails > 0) { loadFails--; return { success: false, error: 'mock: loadAppState failed' }; }
          return { success: true, data: mock.state() };
        });
      },
      storeAppState: function (state) {
        var copy = clone(state === undefined || state === null ? {} : state);
        return call('storeAppState', [copy], function () {
          if (storeFails > 0) { storeFails--; return { success: false, error: 'mock: storeAppState failed' }; }
          if (!isObj(copy)) return { success: false, error: 'state must be an object' };
          mock.setState(copy);
          return { success: true };
        });
      }
    };
    if (typeof opts.theme === 'string') syn.theme = opts.theme;
    if (isObj(opts.Params)) syn.Params = clone(opts.Params);
    if (Array.isArray(opts.Notes)) {
      syn.Notes = opts.Notes.map(function (n) {
        if (typeof n === 'string') {
          var r = db.notes[n];
          return r ? { id: r.id, title: r.title, content: r.content, tags: r.tags.slice() } : null;
        }
        return isObj(n) ? clone(n) : null;
      }).filter(Boolean);
    }

    /*
     * updateNotes: enter, latency, park (holdUpdateNotes), approval dialog,
     * outside edits, apply, parked answer, answer.
     */
    function approval() {
      if (mock.sessionApproved) return Promise.resolve(true);
      mock.dialogs++;
      // An unmounted view answers false at once (user_app_web_view.dart:220).
      if (mock.unmounted) return Promise.resolve(false);
      var ans = mock.approvals.length ? mock.approvals.shift() : mock.approve;
      return wait(mock.approvalMs).then(function () {
        if (ans === 'session') mock.sessionApproved = true;
        return ans !== 'deny';
      });
    }
    function applyList(list) {
      var updated = 0, errors = [];
      (Array.isArray(list) ? list : []).forEach(function (e) {
        if (!isObj(e)) return;
        var id = e.id == null ? '' : String(e.id);
        if (!id) { errors.push('An update was skipped because it had no note id.'); return; }
        var n = db.notes[id];
        if (!n) { errors.push('Note not found: ' + id); return; }
        try {
          if (refused[id]) throw new Error('immutable binding');
          if (isObj(e.modification)) {
            var mod = e.modification;
            var known = ['content', 'title', 'tags', 'link', 'attachments', 'subnote'].some(function (k) { return has(mod, k); });
            if (known) {
              var content = n.content, title = n.title;
              if (has(mod, 'content')) {
                if (!isObj(mod.content)) throw new Error('bad content modification');
                content = PORT.contentModification(content, mod.content);
              }
              if (isObj(mod.title) && typeof mod.title.new_title === 'string' && mod.title.new_title.length) title = mod.title.new_title;
              // attachments.added: a path or a {type:'base64', data, fileName}
              // object (processAttachment); anything else fails the entry.
              var added = isObj(mod.attachments) && Array.isArray(mod.attachments.added) ? mod.attachments.added : [];
              var files = added.map(function (a) {
                if (typeof a === 'string' && a) return { path: a };
                if (isObj(a) && a.type === 'base64' && typeof a.data === 'string' && a.data && typeof a.fileName === 'string' && a.fileName) {
                  var mm = /^data:([^;,]+);base64,/.exec(a.data), dot = a.fileName.lastIndexOf('.');
                  // The host stores it as <stem>_<uuid>.<ext> (FileUtils.generateUniqueFileName, file_utils.dart 119-133).
                  var stem = dot > 0 ? a.fileName.slice(0, dot) : a.fileName, ext = dot > 0 ? a.fileName.slice(dot) : '';
                  var uuid = '00000000-0000-4000-8000-' + ('000000000000' + (++db.seq)).slice(-12);
                  return { path: 'attachments/' + stem + '_' + uuid + ext, fileName: a.fileName, mimeType: mm ? mm[1] : null, bytes: Math.floor(a.data.replace(/^[^,]*,/, '').length * 3 / 4) };
                }
                throw new Error('Invalid attachment format');
              });
              if (files.length) n.attachments = (n.attachments || []).concat(files);
              n.content = content;
              n.title = title;
              n.updatedAt = db.tick();
            }
            updated++;
            return;
          }
          // Full replacement: only the keys present change (bridge 3415-3530).
          if (has(e, 'title')) { var t = e.title == null ? '' : String(e.title).trim(); if (t) n.title = t; }
          if (has(e, 'content')) n.content = e.content == null ? n.content : String(e.content).trim();
          if (has(e, 'type')) n.type = String(e.type).toLowerCase() === 'task' ? 'task' : 'note';
          // null keeps the old value (Note.copyWith `??`, note.dart:97-98).
          if (has(e, 'scheduledAt') && e.scheduledAt != null) n.scheduledAt = String(e.scheduledAt);
          if (has(e, 'completeBy') && e.completeBy != null) n.completeBy = String(e.completeBy);
          if (has(e, 'status')) { var s = String(e.status).toLowerCase(); n.status = H.STATUSES.indexOf(s) >= 0 ? s : 'todo'; }
          n.updatedAt = db.tick();
          updated++;
        } catch (err) {
          // M10 passes a PluginFacingException through; others stay redacted.
          errors.push(mock.errors === 'verbatim' && err && err.pluginFacing ? 'Updating note ' + id + ' failed: ' + err.message
            : 'Updating note ' + id + ' failed. See the app log for details.');
        }
      });
      var res = { success: true, updatedCount: updated };
      if (errors.length) { res.errors = errors; res.error = errors[0]; }
      return res;
    }
    function updateNotes(list) {
      var copy = clone(Array.isArray(list) ? list : []);
      mock.updates.push(copy);
      enter('updateNotes', [copy]);
      if (mock.halted) return NEVER();
      if (mock.trap === 'beforeUpdateNotes') { mock.halt(); return NEVER(); }
      var rec = { applied: false, delivered: false, killed: false, open: null, holdAnswer: false, answerGate: null };
      inflight.push(rec);
      function done() { var i = inflight.indexOf(rec); if (i >= 0) inflight.splice(i, 1); }
      return wait(latencyOf('updateNotes', [copy])).then(function () {
        if (holdNext > 0 && !rec.killed) {
          holdNext--;
          parked.push(rec);
          log('updateNotes', 'parked');
          return new Promise(function (r) { rec.open = r; });
        }
      }).then(function () {
        if (rec.killed) return 'killed';
        var canned = scripted('updateNotes', copy);
        if (canned !== undefined && canned !== null) return { canned: canned };
        return approval().then(function (yes) {
          if (rec.killed) return 'killed';
          if (!yes) return { answer: { success: false, error: H.DENIED } };
          runEdits('beforeWrite');
          var res = applyList(copy);
          rec.applied = true;
          log('updateNotes', 'apply');
          return { answer: res };
        });
      }).then(function (out) {
        if (out === 'killed') { done(); return NEVER(); }
        var answer = out.canned || out.answer;
        rec.applied = true;
        if (rec.onApplied) rec.onApplied();
        if (mock.trap === 'updateNotes') { mock.halt(); done(); if (rec.onDone) rec.onDone(); return NEVER(); }
        var gate = rec.holdAnswer ? new Promise(function (r) { rec.answerGate = r; }) : null;
        return Promise.resolve(gate).then(function () {
          var i = parked.indexOf(rec);
          if (i >= 0) parked.splice(i, 1);
          done();
          rec.delivered = true;
          var v = deliver('updateNotes', answer);
          if (rec.onDone) rec.onDone();
          return v;
        });
      });
    }

    /*
     * Hook list. State: db, calls (per bridge method), events ({seq, method,
     * phase: call|parked|apply|resolve}), updates, saves, queries, picks,
     * opened, dialogs, sqlDialogs, sessionApproved, sqlSessionApproved.
     * Knobs: latency, approve, approvalMs, approvals[] (next dialog answers),
     * sqlApprove, sqlApprovalMs, sqlApprovals[], unmounted (hidden denial),
     * pickAnswer ([ids] the user ticks | 'no_ui' | null for cancel; the
     * answer also holds options.preselectedIds, as the host's does),
     * pickUntick ([ids] of preselected notes the user unticks), rowCap.
     * Calls: haltAfter, halt, holdUpdateNotes, release, parked, resume,
     * setNote, outsideEdit, truncateReads, failLoads, failStores, refuse,
     * script, emit, setVisible, dispatch, tickInterval, note, content, put,
     * addSubnote, link, state, setState, count, resetCounts, wholeReplaces,
     * newHost. `host` is a GT.host bound to this mock; `synapse` its Synapse.
     */
    mock.synapse = syn;
    if (install) global.Synapse = syn;
    var envHost = {
      target: mock.win, doc: mock.doc,
      setInterval: opts.setInterval || (dom ? undefined : function (fn) { mock.intervals.push(fn); return mock.intervals.length; }),
      clearInterval: opts.clearInterval || (dom ? undefined : function (i) { mock.intervals[i - 1] = function () {}; }),
      now: opts.now
    };
    mock.host = H.create(syn, envHost);
    mock.newHost = function (env) { return H.create(syn, Object.assign({}, envHost, env || {})); };
    return mock;
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = GT;
})(typeof window !== 'undefined' ? window : globalThis);
