/*
 * Big Bang - resolving cards to live notes: titles, excerpts, tombstones.
 *
 * A note card is a REFERENCE. The block on the board note holds an id and
 * nothing else that matters; the title and the two or three lines under it are
 * read live, so a note renamed or rewritten elsewhere is right the next time
 * the board opens. This file is the whole of that resolution, and four rules
 * shape it:
 *
 *   One read for the whole board. Not one per card: HOST.readExcerpts already
 *   chunks the ids, pages past the 100-row cap and truncates in SQL, so a board
 *   of thirty cards is one query and no card ever hauls a whole note across the
 *   bridge. The answer is cached for the session and only ids nobody has seen
 *   are asked for again.
 *
 *   A failed read is not a graveyard. `missing` means the row genuinely did not
 *   come back from a query that SUCCEEDED. A query that failed - the database
 *   was locked, the host went away - resolves nothing and tombstones nothing,
 *   because a board that turns every card into a tombstone the moment a read
 *   hiccups reads as "you lost all your notes".
 *
 *   The excerpt is a card FACE, not a rendering. It is markdown stripped down
 *   to the readable words: no headings, no bullets, no emphasis, no link
 *   syntax, and never the contents of a code fence - which is also how the
 *   board's own ```synapse-bigbang block stays off the front of its own card.
 *   Nothing here produces HTML: every string leaving this file is put into the
 *   document with textContent, and there is no path that is not.
 *
 *   A face carries everything the card draws, and the card draws nothing it did
 *   not get from here - the title, the excerpt, the tags, and whether the note
 *   is a task. Two of those cost a query and two do not: `type` and `status`
 *   ride along on the excerpt row, tags are a join two tables away and are read
 *   separately. A failed tag read is not a failed resolve; chips are decoration
 *   and a board draws perfectly well without them.
 *
 *   The last-seen title is refreshed on every successful read, and that is the
 *   only thing that keeps a tombstone meaningful - `t` is what a deleted note
 *   is labelled with. It is applied OUTSIDE the undo stack (see applyTitles):
 *   undoing your way past a rename you never made is not undo, it is noise.
 */
(function (global) {
  'use strict';
  var BB = (global.BB = global.BB || {});
  var BOARD = BB.board;
  var N = (BB.notes = {});

  N.LINES = 3;          // how many stripped lines make a face
  N.CHARS = 220;        // and how much of them survives
  N.SEP = ' · ';

  N.UNTITLED = '(untitled)';
  N.DELETED = '(deleted note)';
  // What a card with no text of its own is called. It lives here, with every
  // other string a face carries, so the renderer never has to invent one.
  N.LABEL = { sticky: 'Sticky', annot: 'Annotation' };

  /* --------------------------------------------------------- markdown → text */

  /*
   * Inline syntax, removed rather than rendered. Order matters: images before
   * links (an image is a link with a bang), code spans before emphasis (so
   * `**` inside backticks is left alone), reference links before anything that
   * would eat their brackets.
   *
   * Underscore emphasis is deliberately fussy: snake_case_names are ordinary
   * words in a note, and a greedy rule turns them into snakecasenames.
   */
  function stripInline(s) {
    var out = String(s == null ? '' : s);
    out = out
      .replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1')
      .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
      .replace(/!\[([^\]]*)\]\[[^\]]*\]/g, '$1')
      .replace(/\[([^\]]*)\]\[[^\]]*\]/g, '$1')
      .replace(/<(https?:\/\/[^>\s]+)>/g, '$1')
      .replace(/<\/?[A-Za-z][^>\n]{0,120}>/g, ' ')
      .replace(/`+([^`\n]*)`+/g, '$1')
      .replace(/~~([^~\n]+)~~/g, '$1')
      .replace(/(\*\*\*|___)([^\s*_](?:[^*_\n]*[^\s*_])?)\1/g, '$2')
      .replace(/(\*\*|__)([^\s*_](?:[^*_\n]*[^\s*_])?)\1/g, '$2')
      .replace(/\*([^\s*](?:[^*\n]*[^\s*])?)\*/g, '$1')
      .replace(/(^|[^\w\\])_([^\s_](?:[^_\n]*[^\s_])?)_(?![\w])/g, '$1$2')
      .replace(/\|/g, ' ')
      .replace(/\s+/g, ' ');
    return out.trim();
  }

  var FENCE = /^(`{3,}|~{3,})/;
  var HR = /^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/;
  var TABLE_RULE = /^\s*\|?[\s:|-]*-[\s:|-]*\|?\s*$/;

  /*
   * excerpt(markdown, opts) -> a card face
   *   opts.title   the note's own title; a first line that only repeats it is
   *                dropped, because the card already shows it above.
   *   opts.lines   how many stripped lines to keep (default 3)
   *   opts.chars   how long the result may be (default 220)
   *
   * The input is normally the SQL-truncated first 400 characters, so it can end
   * mid-word and mid-fence. Neither is treated as an error.
   */
  N.excerpt = function (md, opts) {
    opts = opts || {};
    var want = opts.lines || N.LINES;
    var cap = opts.chars || N.CHARS;
    var title = stripInline(String(opts.title == null ? '' : opts.title)).toLowerCase();

    var src = String(md == null ? '' : md);
    var lines = src.split(/\r?\n/);
    var out = [], code = [], fence = null, i = 0;

    // YAML front matter is metadata, not the note.
    if (/^---\s*$/.test(lines[0] || '')) {
      for (i = 1; i < lines.length; i++) if (/^(?:---|\.\.\.)\s*$/.test(lines[i])) { i++; break; }
      if (i >= lines.length) i = 1;
    }

    for (; i < lines.length && out.length < want; i++) {
      var raw = lines[i];
      var t = raw.replace(/\s+$/, '');
      var f = FENCE.exec(t.replace(/^\s{0,3}/, ''));
      if (f) {
        // A closing fence is the same character, at least as long. Anything
        // else opening while one is open is content.
        if (fence && f[1].charAt(0) === fence.charAt(0) && f[1].length >= fence.length) fence = null;
        else if (!fence) fence = f[1];
        continue;
      }
      if (fence) { if (code.length < 2 && /\S/.test(t)) code.push(t.trim()); continue; }
      if (!/\S/.test(t)) continue;
      if (HR.test(t) || TABLE_RULE.test(t)) continue;
      if (/^\s*<!--/.test(t)) continue;

      var line = t
        .replace(/^\s{0,3}>+\s?/, '')
        .replace(/^\s{0,3}#{1,6}\s+/, '')
        .replace(/^\s*(?:[-*+]|\d{1,9}[.)])\s+/, '')
        .replace(/^\s*\[[ xX]\]\s*/, '');
      line = stripInline(line);
      if (!line) continue;
      if (!out.length && title && line.toLowerCase() === title) continue;
      out.push(line);
    }

    // A note that is nothing but code still deserves a face.
    if (!out.length && code.length) out = code;

    var text = out.join(N.SEP);
    // BOARD.cut rather than slice: an excerpt cut between the halves of a
    // surrogate pair carries half an emoji, which draws as a box on the card
    // and makes the export of the whole board throw on its way to a data URI.
    if (text.length > cap) text = BOARD.cut(text, cap - 1).replace(/\s+\S*$/, '') + '…';
    return text;
  };

  /* ----------------------------------------------------------- the cache */

  /*
   * One cache per session. It holds what came back (`live`) and what a
   * successful read did NOT return (`gone`), and keeps them apart on purpose:
   * "not looked up yet" is a third state, and drawing it as a tombstone would
   * make every card flash as deleted while the first query is in flight.
   */
  N.cache = function () {
    var live = Object.create(null);
    var gone = Object.create(null);
    var C = {
      reads: 0,
      get: function (id) { return BOARD.has(live, id) ? live[id] : null; },
      gone: function (id) { return BOARD.has(gone, id); },
      known: function (id) { return BOARD.has(live, id) || BOARD.has(gone, id); },
      put: function (row) {
        if (!row || typeof row.id !== 'string' || !row.id || row.id === '__proto__') return null;
        var prev = BOARD.has(live, row.id) ? live[row.id] : null;
        var rec = {
          id: row.id,
          title: typeof row.title === 'string' ? row.title : '',
          excerpt: N.excerpt(row.excerpt, { title: row.title }),
          // The notes table spells it 'note' or 'task'; anything else is a
          // note, because a card that guessed wrong would show a checkbox on
          // something that cannot be ticked.
          task: row.type === 'task',
          /*
           * The notes table spells a finished task 'complete'. Not
           * 'completed': TaskStatus's JsonValue is `complete`, database_service
           * reads and writes that string, and the host's own parser turns
           * anything it does not recognise into 'todo'. A card that tested for
           * 'completed' therefore drew every finished task as unticked - and,
           * once the box could be tapped, would have offered to complete a task
           * that already was.
           */
          done: row.status === 'complete',
          // Tags arrive from their own query, which may not have run yet or
          // may have failed. Whatever we last knew stays until it does.
          tags: prev ? prev.tags : []
        };
        live[row.id] = rec;
        delete gone[row.id];
        return rec;
      },

      /*
       * The tags for the ids we just asked about. Every id in `ids` is
       * rewritten, not only the ones that came back with rows: a tag removed
       * elsewhere shows up as a note with NO rows, and a merge would leave its
       * chip on the card for the rest of the session.
       */
      putTags: function (ids, rows) {
        var by = Object.create(null);
        (rows || []).forEach(function (r) {
          if (!r || typeof r.noteId !== 'string' || r.noteId === '__proto__') return;
          var name = typeof r.name === 'string' ? r.name : '';
          if (!name) return;
          if (!BOARD.has(by, r.noteId)) by[r.noteId] = [];
          by[r.noteId].push({ name: name, color: typeof r.color === 'string' ? r.color : '' });
        });
        (ids || []).forEach(function (id) {
          if (!BOARD.has(live, id)) return;
          live[id].tags = BOARD.has(by, id) ? by[id] : [];
        });
      },
      bury: function (id) {
        if (typeof id !== 'string' || !id || id === '__proto__') return;
        delete live[id];
        gone[id] = 1;
      },
      // A card removed and re-added, or a note that came back: forget what we
      // decided about it and let the next resolve ask again.
      forget: function (id) { delete live[id]; delete gone[id]; },
      clear: function () {
        Object.keys(live).forEach(function (k) { delete live[k]; });
        Object.keys(gone).forEach(function (k) { delete gone[k]; });
      },
      count: function () { return { live: Object.keys(live).length, gone: Object.keys(gone).length }; }
    };
    return C;
  };

  /* --------------------------------------------------------------- resolve */

  // Every distinct real note id the board points at, in a stable order.
  N.noteIds = function (board) {
    var seen = Object.create(null), out = [];
    if (!board) return out;
    Object.keys(board.items).forEach(function (id) {
      var it = board.items[id];
      if (it.k !== 'note' || typeof it.id !== 'string' || !it.id) return;
      if (BOARD.has(seen, it.id)) return;
      seen[it.id] = 1;
      out.push(it.id);
    });
    return out;
  };

  /*
   * resolve(cache, board, opts) -> Promise<{ ok, asked, found, missing, tags, error }>
   *
   * One query for the ids the cache has never seen (all of them, with
   * opts.force), and one more for their tags. `ok:false` leaves the cache
   * exactly as it was: nothing is buried on the strength of a read that failed.
   *
   * The tag read is the junior partner. It cannot fail the resolve, it cannot
   * bury a note and it cannot produce a tombstone - a board whose tags did not
   * come back is a board without chips, which is a board. `tags:false` says so
   * for a caller that wants to mention it.
   */
  N.resolve = function (cache, board, opts) {
    opts = opts || {};
    var HOST = BB.host;
    var ids = (opts.ids || N.noteIds(board)).filter(function (id) {
      return opts.force ? true : !cache.known(id);
    });
    if (!ids.length) return Promise.resolve({ ok: true, asked: 0, found: 0, missing: [], tags: true });
    if (!HOST || !HOST.readExcerpts) return Promise.resolve({ ok: false, asked: ids.length, found: 0, missing: [], error: 'no host' });

    return HOST.readExcerpts(ids).then(function (r) {
      if (!r || r.ok === false) {
        return { ok: false, asked: ids.length, found: 0, missing: [], error: (r && r.error) || 'the notes could not be read' };
      }
      cache.reads++;
      var found = 0;
      (r.rows || []).forEach(function (row) { if (cache.put(row)) found++; });
      var missing = r.missing || [];
      missing.forEach(function (id) { cache.bury(id); });
      var out = { ok: true, asked: ids.length, found: found, missing: missing.slice(), tags: true };
      if (!HOST.readTags) { out.tags = false; return out; }
      return HOST.readTags(ids).then(function (t) {
        if (!t || t.ok === false) { out.tags = false; return out; }
        cache.putTags(ids, t.rows || []);
        return out;
      }, function () { out.tags = false; return out; });
    });
  };

  /*
   * applyTitles(board, cache) -> how many cards were relabelled
   *
   * A card's `t` is the last title we saw for its note, and it exists for ONE
   * purpose: labelling the tombstone if that note is ever deleted. Refreshing
   * it is bookkeeping, not an edit the user made, so it runs OUTSIDE any
   * transaction - it must not become a step on the undo stack, and it must not
   * be swept into whatever step happens to be open. The caller marks the board
   * dirty when this returns non-zero, so a rename made elsewhere is eventually
   * written down; a board nobody renamed writes nothing at all.
   */
  N.applyTitles = function (board, cache) {
    if (!board) return 0;
    var n = 0;
    Object.keys(board.items).forEach(function (id) {
      var it = board.items[id];
      if (it.k !== 'note') return;
      var rec = cache.get(it.id);
      if (!rec || !rec.title) return;      // a missing note keeps the old label
      if (it.t === rec.title) return;
      it.t = rec.title;
      n++;
    });
    return n;
  };

  /*
   * face(board, itemId, cache) -> everything the card shows
   *   { kind, title, excerpt, tags, task, done, tomb, pending, noteId }
   *
   * `tomb` is a note that a successful read did not return. `pending` is one
   * nobody has asked about yet - drawn as an ordinary card with the last known
   * title, never as a tombstone. Neither carries tags or a task marker: a
   * tombstone's note is gone, and a pending one has not been read.
   *
   * A card with no text of its own gets its label from here rather than from
   * the renderer, so there is exactly one answer to what an empty sticky is
   * called and the bar and the card cannot disagree about it.
   */
  N.face = function (board, itemId, cache) {
    var it = board && BOARD.hasItem(board, itemId) ? board.items[itemId] : null;
    if (!it) return null;
    if (it.k !== 'note') {
      return {
        kind: it.k, title: it.t || N.LABEL[it.k] || '', excerpt: '',
        tags: [], task: false, done: false, tomb: false, pending: false, noteId: null
      };
    }
    var rec = cache && cache.get(it.id);
    if (rec) {
      return {
        kind: 'note', noteId: it.id,
        title: rec.title || N.UNTITLED,
        excerpt: rec.excerpt,
        tags: rec.tags || [],
        task: !!rec.task, done: !!rec.done,
        tomb: false, pending: false
      };
    }
    if (cache && cache.gone(it.id)) {
      return {
        kind: 'note', noteId: it.id,
        title: it.t || N.DELETED,
        excerpt: '', tags: [], task: false, done: false, tomb: true, pending: false
      };
    }
    return {
      kind: 'note', noteId: it.id,
      title: it.t || N.UNTITLED, excerpt: '',
      tags: [], task: false, done: false, tomb: false, pending: true
    };
  };

  // Which cards on the board are tombstones right now.
  N.tombstones = function (board, cache) {
    return Object.keys(board.items).filter(function (id) {
      var it = board.items[id];
      return it.k === 'note' && cache.gone(it.id);
    });
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = BB;
})(typeof window !== 'undefined' ? window : globalThis);
