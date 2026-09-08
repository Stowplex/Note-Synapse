/*
 * Big Bang - the board block.
 *
 * A board lives in one ```synapse-bigbang fenced block on an ordinary note.
 * Everything in this file is about that block and nothing else: finding it,
 * reading it into a board, writing a board back out, and splicing it into a
 * note's text without touching a single byte of the body around it.
 *
 * Four rules hold the whole file up:
 *
 *   1. Reading never throws and never half-succeeds. A missing, mangled,
 *      truncated or future-version block yields an EMPTY board, and the caller
 *      is told which of those it was so it can refuse to overwrite something it
 *      does not understand.
 *   2. Splicing is byte-exact outside the block's own span. The ONE exception
 *      is spelled out on `splice` below: removing a block that ran to the end
 *      of the note also drops the single blank line an append would have put
 *      there. Nothing else in the user's whitespace is ever rewritten - not a
 *      tab, not a run of blank lines, not a CRLF.
 *   3. A board with nothing on it writes no block at all, so a note that was
 *      cleared is indistinguishable from one that never was a board.
 *   4. Nothing downstream re-derives what a value means. `find` decides where
 *      the block is; the coerce* helpers decide what a field is worth, for the
 *      read side and the write side alike (see model.js). When those two
 *      disagree a card that saved fine comes back deleted, so they are one
 *      implementation, used twice.
 *
 * The scanner is CRLF-tolerant throughout, and fence-aware: a synapse-bigbang
 * fence nested inside a wider code fence is somebody's documentation, not a
 * board.
 */
(function (global) {
  'use strict';
  var BB = (global.BB = global.BB || {});
  var BOARD = (BB.board = {});

  BOARD.INFO = 'synapse-bigbang';
  BOARD.V = 1;

  function set(names) {
    var o = Object.create(null);
    names.forEach(function (n) { o[n] = 1; });
    return o;
  }

  // Object.create(null), not {}: `KINDS['constructor']` on a plain object is
  // truthy, which is all it takes for {"k":"constructor"} to read as a kind.
  var KINDS = set(['note', 'sticky', 'annot']);
  var HEADS = set(['none', 'arrow', 'double']);
  var DASHES = set(['solid', 'dashed', 'dotted']);
  BOARD.KINDS = KINDS;
  BOARD.HEADS = HEADS;
  BOARD.DASHES = DASHES;

  /* --------------------------------------------------------------- helpers */

  var hasOwn = Object.prototype.hasOwnProperty;

  // The only way anything in Big Bang asks "is this key in this map". A bare
  // `map[k]` answers yes for every name on Object.prototype.
  function has(o, k) {
    return !!o && typeof k === 'string' && hasOwn.call(o, k);
  }
  BOARD.has = has;
  BOARD.hasItem = function (board, id) { return !!board && has(board.items, id); };

  function isNum(x) { return typeof x === 'number' && isFinite(x); }
  function str(x) { return typeof x === 'string' ? x : ''; }
  function r0(n) { return Math.round(n); }

  /*
   * A board-local id. '__proto__' is refused everywhere an id can enter: as a
   * key in `items` it would set the prototype instead of storing the card, and
   * the board would read back empty - which the next save would write out as
   * "there is no board here", removing the block.
   */
  function okId(x) { return typeof x === 'string' && !!x && x !== '__proto__'; }
  BOARD.okId = okId;

  /* ------------------------------------------------------- text, by CHARACTER */

  /*
   * A JavaScript string is a sequence of UTF-16 code units, and an astral
   * character - an emoji, a CJK extension B ideograph - is TWO of them. Three
   * things in this app walk or cut a string, and every one of them used to do
   * it by code unit:
   *
   *   the excerpt's cap, the AI request's caps, and the export's word wrap.
   *
   * A cut between the two halves of a pair leaves a LONE SURROGATE, which is
   * not a character at all. It renders as a replacement box, `encodeURIComponent`
   * throws `URIError` on it, and the export builds its picture by putting the
   * SVG through exactly that call - so one emoji in one card's title, cut in
   * the wrong place, fails the export of the whole board with "URI malformed".
   *
   * These three helpers are here rather than in each caller because all three
   * callers need the same rule and the bug is invisible until it is not.
   */

  function isHigh(c) { return c >= 0xd800 && c <= 0xdbff; }
  function isLow(c) { return c >= 0xdc00 && c <= 0xdfff; }

  // The characters of a string, a surrogate pair counting as one.
  BOARD.chars = function (s) {
    var t = str(s == null ? '' : String(s)), out = [];
    for (var i = 0; i < t.length; i++) {
      var c = t.charCodeAt(i);
      if (isHigh(c) && i + 1 < t.length && isLow(t.charCodeAt(i + 1))) { out.push(t.slice(i, i + 2)); i++; }
      else out.push(t.charAt(i));
    }
    return out;
  };

  /*
   * The first `cap` code units, never ending between the halves of a pair.
   * Measured in code units on purpose: every caller's cap is about how much
   * text a box or a request can hold, and one character short of it is not a
   * difference anybody can see.
   */
  BOARD.cut = function (s, cap) {
    var t = String(s == null ? '' : s);
    var n = Math.max(0, cap | 0);
    if (t.length <= n) return t;
    if (n > 0 && isHigh(t.charCodeAt(n - 1))) n--;
    return t.slice(0, n);
  };

  /*
   * Text an XML parser will accept, which is not the same as text.
   *
   * XML 1.0 takes no C0 control but tab, newline and carriage return: a U+0001
   * arriving in a note through a paste or an import makes an SVG that does not
   * parse, and an <img> given it fires `error` with no reason attached. A lone
   * surrogate is worse still - `encodeURIComponent` throws on it outright.
   *
   * Either one is a single stray character in a single note's title, and
   * either one used to fail the export of the entire board. They are DROPPED
   * rather than escaped: `&#1;` is exactly as illegal as the character it
   * stands for, and there is nothing to show the reader anyway.
   */
  var UNSAFE_XML = /[\0-\x08\x0b\x0c\x0e-\x1f\ud800-\udfff\ufffe\uffff]/;
  BOARD.xmlText = function (s) {
    var t = String(s == null ? '' : s);
    // Almost every string is already fine, and this is called per line of
    // text per card. The scan below only runs when there is something to do -
    // and it runs for ordinary emoji too, which it then copies through whole.
    if (!UNSAFE_XML.test(t)) return t;
    var out = '';
    for (var i = 0; i < t.length; i++) {
      var c = t.charCodeAt(i);
      if (isHigh(c)) {
        if (i + 1 < t.length && isLow(t.charCodeAt(i + 1))) { out += t.slice(i, i + 2); i++; }
        continue;                              // a high half with no low: dropped
      }
      if (isLow(c)) continue;                  // a low half with no high
      if (c < 0x20 && c !== 9 && c !== 10 && c !== 13) continue;
      if (c === 0xfffe || c === 0xffff) continue;
      out += t.charAt(i);
    }
    return out;
  };

  /* ------------------------------------------------------------- coercions */

  /*
   * One implementation of every field rule, shared by the read side (a block
   * off a note) and the write side (model.js). Each returns null for "no", so
   * a caller can tell "absent" from "zero" without a second check.
   *
   * Non-finite numbers are rejected HERE, which is the only place that can
   * hold: Math.round(NaN) is NaN, JSON.stringify writes it as null, and a null
   * position on the way back in is an item with no position - dropped, along
   * with its links, its group membership and every annotation anchored to it.
   */
  function coercePoint(a) {
    return Array.isArray(a) && a.length === 2 && isNum(a[0]) && isNum(a[1]) ? [r0(a[0]), r0(a[1])] : null;
  }
  function coerceWidth(w) { return isNum(w) && w > 0 ? r0(w) : null; }
  function coerceZoom(z) {
    return isNum(z) && z > 0 ? Math.max(0.1, Math.min(10, Math.round(z * 1e4) / 1e4)) : null;
  }
  function coerceText(t) { return str(t); }
  function coerceColour(c) { return str(c) ? str(c) : null; }

  // Exported because model.js writes through them; the rest stay internal
  // until something outside this file needs one.
  BOARD.coercePoint = coercePoint;
  BOARD.coerceZoom = coerceZoom;
  BOARD.coerceWidth = coerceWidth;
  // M4 types into stickies, annotations, link labels and group names, and
  // paints all four. Every one of those writes goes through the rule the read
  // side applies, for the reason at the top of this file: a value the write
  // side accepts and the read side refuses comes back as a card with no text,
  // or - when the two disagreed about a position - as no card at all.
  BOARD.coerceText = coerceText;
  BOARD.coerceColour = coerceColour;

  /*
   * coerceItem(raw, opts) -> item | null
   *   opts.loosePos   a missing `p` becomes [0,0] instead of refusing the item.
   *                   A present-but-unusable `p` is refused either way.
   *   opts.anchorOk   predicate deciding whether an annotation anchor stands.
   *                   Absent means "any well-formed anchor"; the read path
   *                   filters again once every id on the board is known.
   */
  function coerceItem(raw, opts) {
    opts = opts || {};
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
    if (!has(KINDS, raw.k)) return null;

    var p;
    if (raw.p == null && opts.loosePos) p = [0, 0];
    else { p = coercePoint(raw.p); if (!p) return null; }

    var it = { k: raw.k, p: p };
    if (raw.k === 'note') {
      if (typeof raw.id !== 'string' || !raw.id) return null;
      it.id = raw.id;
      // The last title seen, so a deleted note can still be drawn as a
      // tombstone instead of a blank card. Never trusted over a live read.
      if (coerceText(raw.t)) it.t = coerceText(raw.t);
    } else {
      it.t = coerceText(raw.t);
    }
    var w = coerceWidth(raw.w);
    if (w !== null) it.w = w;
    var c = coerceColour(raw.c);
    if (c !== null) it.c = c;

    if (raw.k === 'annot') {
      var at = [], seen = Object.create(null);
      (Array.isArray(raw.at) ? raw.at : []).forEach(function (a) {
        if (!a || typeof a !== 'object') return;
        var one = okId(a.i) ? { i: a.i } : (okId(a.l) ? { l: a.l } : null);
        if (!one) return;
        var key = one.i ? 'i:' + one.i : 'l:' + one.l;
        if (seen[key]) return;
        if (opts.anchorOk && !opts.anchorOk(one)) return;
        seen[key] = 1;
        at.push(one);
      });
      it.at = at;
      var q = coercePoint(raw.q);
      if (q) it.q = q;
    }
    return it;
  }

  /*
   * coerceLink(raw, opts) -> link | null
   *   opts.itemOk  predicate deciding whether an endpoint id names an item.
   */
  function coerceLink(raw, opts) {
    opts = opts || {};
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
    if (!okId(raw.i) || !okId(raw.a) || !okId(raw.b)) return null;
    if (raw.a === raw.b) return null;
    if (opts.itemOk && (!opts.itemOk(raw.a) || !opts.itemOk(raw.b))) return null;
    var l = {
      i: raw.i, a: raw.a, b: raw.b,
      h: has(HEADS, raw.h) ? raw.h : 'none',
      d: has(DASHES, raw.d) ? raw.d : 'solid'
    };
    var c = coerceColour(raw.c);
    if (c !== null) l.c = c;
    if (coerceText(raw.t)) l.t = coerceText(raw.t);
    if (raw.real === true) l.real = true;
    return l;
  }

  /*
   * coerceGroup(raw, opts) -> group | null
   *   opts.itemOk  predicate deciding whether a member id names an item.
   * Members are deduped in order. A group with no members is not a group.
   */
  function coerceGroup(raw, opts) {
    opts = opts || {};
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
    if (!okId(raw.i)) return null;
    var seen = Object.create(null), m = [];
    (Array.isArray(raw.m) ? raw.m : []).forEach(function (x) {
      if (!okId(x) || seen[x]) return;
      if (opts.itemOk && !opts.itemOk(x)) return;
      seen[x] = 1;
      m.push(x);
    });
    if (!m.length) return null;
    var g = { i: raw.i, m: m };
    if (coerceText(raw.t)) g.t = coerceText(raw.t);
    var c = coerceColour(raw.c);
    if (c !== null) g.c = c;
    return g;
  }

  function coerceView(raw) {
    var v = { p: [0, 0], z: 1 };
    if (!raw || typeof raw !== 'object') return v;
    var p = coercePoint(raw.p);
    if (p) v.p = p;
    var z = coerceZoom(raw.z);
    if (z !== null) v.z = z;
    return v;
  }

  BOARD.coerceItem = coerceItem;
  BOARD.coerceLink = coerceLink;
  BOARD.coerceGroup = coerceGroup;

  /* ------------------------------------------------------------------ find */

  /*
   * Lines, with the line terminator left out of `end` and `\r` with it. A note
   * written on Windows is the ordinary case, not an edge case: a scanner that
   * leaves the \r on the line matches no fence, so a real board reads as no
   * board and the next save appends a SECOND one beside it.
   *
   *   start  first character of the line
   *   end    one past its last character, before \r and \n
   *   next   first character of the following line
   */
  function lines(src) {
    var out = [], i = 0, n = src.length;
    for (;;) {
      var j = src.indexOf('\n', i);
      var stop = j < 0 ? n : j;
      var end = (stop > i && src.charAt(stop - 1) === '\r') ? stop - 1 : stop;
      out.push({ start: i, end: end, next: j < 0 ? n : j + 1 });
      if (j < 0) break;
      i = j + 1;
    }
    return out;
  }

  var OPEN = /^(`{3,}|~{3,})[ \t]*([^\s`~]*)[ \t]*$/;

  // A closing fence: the same character, at least as many of them, nothing
  // after it but spaces and tabs. An info string never closes a fence.
  function closes(line, open) {
    var k = 0;
    while (k < line.length && line.charAt(k) === open.ch) k++;
    if (k < open.len) return false;
    for (var j = k; j < line.length; j++) {
      var c = line.charAt(j);
      if (c !== ' ' && c !== '\t') return false;
    }
    return true;
  }

  /*
   * How far an UNTERMINATED fence is allowed to claim: to the line before the
   * first blank one, or to the end of the note if there is none.
   *
   * The block is written on one line, so a blank line is never inside it. The
   * old rule - run to the end of the note - meant a note whose closing fence
   * had been deleted by hand had its whole remaining body inside the span, and
   * one save replaced the lot. saveBoard refuses a malformed block outright
   * now; this bound is the second half of that fix, so that even a forced save
   * replaces the damage and not the prose under it.
   */
  function boundUnclosed(src, ls, i) {
    for (var j = i + 1; j < ls.length; j++) {
      if (!/\S/.test(src.slice(ls[j].start, ls[j].end))) return j - 1;
    }
    return ls.length - 1;
  }

  function makeSpan(src, ls, i, j, closed) {
    var bodyStart = Math.min(src.length, ls[i].next);
    var bodyEnd = closed ? ls[j].start : ls[j].end;
    if (bodyEnd < bodyStart) bodyEnd = bodyStart;
    return {
      start: ls[i].start,
      end: ls[j].end,
      bodyStart: bodyStart,
      bodyEnd: bodyEnd,
      closed: closed,
      body: src.slice(bodyStart, bodyEnd),
      raw: src.slice(ls[i].start, ls[j].end)
    };
  }

  /*
   * Every top-level board block in the note, in document order.
   *
   * Fence state is tracked from the top of the document, so a synapse-bigbang
   * fence written INSIDE a wider ```` fence - the way anybody documents the
   * format - is text, not a board. Rejecting indented fences was never enough:
   * a nested example sits at column 0 like everything else in its container.
   */
  BOARD.scan = function (text) {
    var src = String(text == null ? '' : text);
    var ls = lines(src);
    var out = [], open = null, shadowed = 0;
    for (var i = 0; i < ls.length; i++) {
      var line = src.slice(ls[i].start, ls[i].end);
      if (open) {
        if (closes(line, open)) {
          if (open.board) out.push(makeSpan(src, ls, open.i, i, true));
          open = null;
        } else if (OPEN.test(line) && OPEN.exec(line)[2] === BOARD.INFO) {
          shadowed++;
        }
        continue;
      }
      var m = OPEN.exec(line);
      if (!m) continue;
      open = { ch: m[1].charAt(0), len: m[1].length, i: i, board: m[2] === BOARD.INFO };
    }
    if (open && open.board) out.push(makeSpan(src, ls, open.i, boundUnclosed(src, ls, open.i), false));
    return {
      spans: out,
      // Board fences inside another fence: documentation, not boards.
      shadowed: shadowed,
      // The note ends inside somebody's unterminated code fence. Anything
      // appended to it would be part of that fence, so a block written here
      // would never be found again - and the save after that would append
      // another one beside it.
      openAtEnd: !!open && !open.board
    };
  };

  BOARD.findAll = function (text) { return BOARD.scan(text).spans; };

  // The first one, which is the board. Extras are reported by read(); they are
  // never quietly adopted and never quietly deleted.
  BOARD.find = function (text) { return BOARD.findAll(text)[0] || null; };

  /*
   * The identity of the block as written. Whitespace OUTSIDE a JSON string is
   * insignificant and collapses; whitespace inside one is content and does not.
   *
   * Collapsing it everywhere made "call  the  vendor" and "call the vendor" the
   * same block, so a session that had only re-spaced a sticky looked like no
   * change at all and the other session's save went straight over it. A false
   * conflict is a dialog; a missed one is somebody's work.
   *
   * '' means "there is no block".
   */
  function bodyKey(body) {
    var s = String(body == null ? '' : body);
    var out = [], i = 0, n = s.length, inStr = false;
    while (i < n) {
      var c = s.charAt(i);
      if (inStr) {
        out.push(c);
        // A backslash escape takes its next character with it, so a \" does
        // not end the string and leave the rest of it looking like structure.
        if (c === '\\') { if (i + 1 < n) out.push(s.charAt(i + 1)); i += 2; continue; }
        if (c === '"') inStr = false;
        i++;
        continue;
      }
      if (c === ' ' || c === '\t' || c === '\n' || c === '\r' || c === '\f' || c === '\v') { i++; continue; }
      if (c === '"') inStr = true;
      out.push(c);
      i++;
    }
    return out.join('');
  }
  BOARD.blockKey = function (text) {
    var span = BOARD.find(text);
    return span ? bodyKey(span.body) : '';
  };

  /* ----------------------------------------------------------------- empty */

  BOARD.empty = function () {
    return { v: BOARD.V, view: { p: [0, 0], z: 1 }, items: {}, links: [], groups: [] };
  };

  BOARD.isEmpty = function (board) {
    if (!board) return true;
    return !Object.keys(board.items || {}).length &&
      !(board.links || []).length &&
      !(board.groups || []).length;
  };

  /* -------------------------------------------------------------- sanitise */

  /*
   * Turn parsed JSON into a board, dropping anything that does not hold up:
   * an item with no position, a link whose endpoint is not on the board, a
   * group with no surviving members, an annotation anchor pointing at nothing.
   * This is hygiene applied to a structurally valid block, not a partial read -
   * a block that fails to parse at all is handled one level up, and yields
   * nothing whatsoever.
   */
  function sanitise(data) {
    var board = BOARD.empty();
    var dropped = 0;
    board.view = coerceView(data.view);

    var rawItems = (data.items && typeof data.items === 'object' && !Array.isArray(data.items)) ? data.items : {};
    Object.keys(rawItems).forEach(function (id) {
      if (!okId(id)) { dropped++; return; }
      var it = coerceItem(rawItems[id]);
      if (!it) { dropped++; return; }
      board.items[id] = it;
    });

    var ids = Object.create(null), linkIds = Object.create(null), usedIds = Object.create(null);
    Object.keys(board.items).forEach(function (id) { ids[id] = 1; usedIds[id] = 1; });
    var itemOk = function (id) { return has(ids, id); };

    (Array.isArray(data.links) ? data.links : []).forEach(function (raw) {
      var l = coerceLink(raw, { itemOk: itemOk });
      if (!l || has(usedIds, l.i)) { dropped++; return; }
      usedIds[l.i] = 1;
      linkIds[l.i] = 1;
      board.links.push(l);
    });

    (Array.isArray(data.groups) ? data.groups : []).forEach(function (raw) {
      var g = coerceGroup(raw, { itemOk: itemOk });
      if (!g || has(usedIds, g.i)) { dropped++; return; }
      usedIds[g.i] = 1;
      board.groups.push(g);
    });

    // Anchors last: they can name items and links, so both had to settle first.
    // A dangling anchor is handled exactly as a live removal handles it
    // (model.js `detach`), down to the last board unit: losing the LAST anchor
    // promotes `q` to `p` and floats there, and losing the FIRST one promotes
    // `q` to `p` as well and flags `reanchor`, which means `p` is ABSOLUTE
    // until render.js `settle` re-measures it against the new first anchor.
    // A reload that flagged it WITHOUT converting `p` would put the annotation
    // somewhere the live path never puts it - and with no undo step to get it
    // back, which is what makes this the worse half of the same bug.
    Object.keys(board.items).forEach(function (id) {
      var it = board.items[id];
      if (it.k !== 'annot') return;
      var first = it.at[0];
      var kept = it.at.filter(function (a) {
        if (a.i) return has(ids, a.i) && a.i !== id;
        return has(linkIds, a.l);
      });
      if (kept.length === it.at.length) return;
      dropped += it.at.length - kept.length;
      it.at = kept;
      if (!kept.length) {
        if (it.q) { it.p = it.q; delete it.q; }
      } else if (kept[0] !== first) {
        // No `q` means the block never recorded where it was drawn; there is
        // no absolute spot to keep, so `p` stays the offset it is.
        if (it.q) { it.p = it.q.slice(); it.reanchor = true; }
      }
    });

    return { board: board, dropped: dropped };
  }

  /* ------------------------------------------------------------------ read */

  /*
   * read(noteText) -> {
   *   status: 'none' | 'ok' | 'malformed' | 'future',
   *   board,            always a valid board; empty unless status is 'ok'
   *   v,                the version found, when there was one
   *   span, raw, body,  where the block is, verbatim (null when there is none)
   *   spans,            every top-level board block found
   *   extra,            how many blocks BESIDES the one being used
   *   key,              the block's identity (see blockKey)
   *   dropped,          entries sanitise refused
   *   reason            why, for 'malformed' and 'future'
   * }
   *
   * Never throws. 'future' and 'malformed' are called out separately because
   * the app must refuse to overwrite either without being told to twice; so is
   * `extra`, because a second block is somebody's data too.
   */
  BOARD.read = function (text) {
    var found = BOARD.scan(text);
    var spans = found.spans;
    var span = spans[0] || null;
    var out = {
      status: 'none', board: BOARD.empty(), v: null,
      span: span, spans: spans, extra: spans.length > 1 ? spans.length - 1 : 0,
      shadowed: found.shadowed, openAtEnd: found.openAtEnd,
      raw: span ? span.raw : null, body: span ? span.body : null,
      key: span ? bodyKey(span.body) : '',
      dropped: 0, reason: ''
    };
    if (!span) return out;

    if (!span.closed) {
      out.status = 'malformed';
      out.reason = 'the block is not closed';
      return out;
    }
    var data = null;
    try { data = JSON.parse(span.body); } catch (e) { data = undefined; }
    if (data === undefined) {
      out.status = 'malformed';
      out.reason = 'the block is not valid JSON';
      return out;
    }
    if (!data || typeof data !== 'object' || Array.isArray(data)) {
      out.status = 'malformed';
      out.reason = 'the block is not an object';
      return out;
    }
    out.v = data.v;
    if (!isNum(data.v) || data.v < 1 || data.v !== Math.floor(data.v)) {
      out.status = 'malformed';
      out.reason = 'the block has no usable version';
      return out;
    }
    if (data.v > BOARD.V) {
      out.status = 'future';
      out.reason = 'the block was written by a newer version (v' + data.v + ')';
      return out;
    }
    var s = sanitise(data);
    out.status = 'ok';
    out.board = s.board;
    out.dropped = s.dropped;
    return out;
  };

  // The board, and only the board. Anything unreadable is an empty one.
  BOARD.parse = function (text) { return BOARD.read(text).board; };

  /* ------------------------------------------------------------- serialise */

  // Only what is not the default is written, so the block stays small and
  // parse -> serialise -> parse settles after one pass. Everything written
  // goes through the same coercions the read side uses, so nothing can be
  // written that would not survive being read back.
  BOARD.data = function (board) {
    var out = {
      v: BOARD.V,
      view: { p: coercePoint(board.view.p) || [0, 0], z: coerceZoom(board.view.z) === null ? 1 : coerceZoom(board.view.z) },
      items: {}
    };
    Object.keys(board.items).forEach(function (id) {
      if (!okId(id)) return;
      var it = board.items[id], o = { k: it.k };
      if (it.k === 'note') { o.id = it.id; if (coerceText(it.t)) o.t = it.t; }
      else if (coerceText(it.t)) o.t = it.t;
      o.p = coercePoint(it.p) || [0, 0];
      var w = coerceWidth(it.w);
      if (w !== null) o.w = w;
      var c = coerceColour(it.c);
      if (c !== null) o.c = c;
      if (it.k === 'annot') {
        if (it.at && it.at.length) o.at = it.at.map(function (a) { return a.i ? { i: a.i } : { l: a.l }; });
        if (it.q) { var q = coercePoint(it.q); if (q) o.q = q; }
      }
      out.items[id] = o;
    });
    if (board.links.length) {
      out.links = board.links.map(function (l) {
        var o = { i: l.i, a: l.a, b: l.b };
        if (l.h && l.h !== 'none') o.h = l.h;
        if (l.d && l.d !== 'solid') o.d = l.d;
        var c = coerceColour(l.c);
        if (c !== null) o.c = c;
        if (coerceText(l.t)) o.t = l.t;
        if (l.real === true) o.real = true;
        return o;
      });
    }
    if (board.groups.length) {
      out.groups = board.groups.map(function (g) {
        var o = { i: g.i, m: g.m.slice() };
        if (coerceText(g.t)) o.t = g.t;
        var c = coerceColour(g.c);
        if (c !== null) o.c = c;
        return o;
      });
    }
    return out;
  };

  // The block, on one line, or null when there is nothing worth saying.
  BOARD.serialize = function (board) {
    if (BOARD.isEmpty(board)) return null;
    return '```' + BOARD.INFO + '\n' + JSON.stringify(BOARD.data(board)) + '\n```';
  };

  /* ---------------------------------------------------------------- splice */

  // One line terminator immediately after `at`, if there is one. Removing a
  // block takes its own terminator with it and NOTHING else.
  function afterEol(src, at) {
    if (src.charAt(at) === '\r' && src.charAt(at + 1) === '\n') return at + 2;
    if (src.charAt(at) === '\n') return at + 1;
    return at;
  }

  /*
   * Put `board` into `text`: replace the first block in place, append one when
   * there is none, and remove every block when the board is empty. A note that
   * somehow holds more than one board block keeps the first and loses the rest,
   * so that the next open cannot adopt an orphan - saveBoard refuses to do this
   * without being asked twice.
   *
   * The whitespace contract, in full:
   *
   *   - Replacing touches only the bytes between the opening backticks and the
   *     end of the closing fence. Everything else is byte-identical, tabs,
   *     CRLFs, trailing spaces and runs of blank lines included.
   *   - Removing takes the span plus at most its own line terminator. The
   *     user's blank lines around it stay exactly as they were.
   *   - The one exception: a block removed from the END of the note also drops
   *     one trailing blank line, which is precisely the separator an append
   *     would have written. Clearing a board Big Bang appended therefore
   *     restores the note byte for byte.
   *   - A note left with nothing but whitespace becomes ''.
   *   - Appending adds a blank-line separator when the note does not already
   *     end in one, and terminates the block with a newline.
   */
  BOARD.splice = function (text, board) {
    var src = String(text == null ? '' : text);
    var block = BOARD.serialize(board);
    var spans = BOARD.findAll(src);

    if (!spans.length) {
      if (block === null) return src;
      var pad = '';
      if (src.length) pad = /\r?\n\r?\n$/.test(src) ? '' : (/\r?\n$/.test(src) ? '\n' : '\n\n');
      return src + pad + block + '\n';
    }

    var pieces = [], cursor = 0, removedTail = false;
    spans.forEach(function (sp, idx) {
      pieces.push(src.slice(cursor, sp.start));
      if (idx === 0 && block !== null) {
        pieces.push(block);
        cursor = sp.end;
        return;
      }
      cursor = afterEol(src, sp.end);
      if (cursor >= src.length) removedTail = true;
    });
    pieces.push(src.slice(cursor));
    var res = pieces.join('');

    if (removedTail) {
      if (/\r\n\r\n$/.test(res)) res = res.slice(0, -2);
      else if (/\n\n$/.test(res)) res = res.slice(0, -1);
    }
    // A note that was nothing but a board becomes genuinely empty rather than
    // a stray newline.
    if (block === null && !/\S/.test(res)) return '';
    return res;
  };

  /* --------------------------------------------------------------- summary */

  BOARD.summary = function (board) {
    var s = { items: 0, notes: 0, stickies: 0, annots: 0, links: 0, groups: 0 };
    if (!board) return s;
    Object.keys(board.items || {}).forEach(function (id) {
      var k = board.items[id].k;
      s.items++;
      if (k === 'note') s.notes++;
      else if (k === 'sticky') s.stickies++;
      else if (k === 'annot') s.annots++;
    });
    s.links = (board.links || []).length;
    s.groups = (board.groups || []).length;
    return s;
  };

  function plural(n, one, many) { return n + ' ' + (Math.abs(n) === 1 ? one : many); }

  /*
   * What changed between two boards, in cards and links rather than JSON. The
   * conflict dialog is meant to say "their board has 2 more cards and 1 fewer
   * link", never to show a diff of the block.
   */
  BOARD.describeChange = function (from, to) {
    var a = BOARD.summary(from), b = BOARD.summary(to);
    var d = {
      cards: (b.notes + b.stickies) - (a.notes + a.stickies),
      annots: b.annots - a.annots,
      links: b.links - a.links,
      groups: b.groups - a.groups
    };
    var parts = [];
    [['cards', 'card', 'cards'], ['annots', 'annotation', 'annotations'],
      ['links', 'link', 'links'], ['groups', 'group', 'groups']].forEach(function (f) {
      var n = d[f[0]];
      if (!n) return;
      parts.push(plural(Math.abs(n), f[1], f[2]) + (n > 0 ? ' more' : ' fewer'));
    });
    d.text = parts.length ? parts.join(', ') : 'the same cards and links, arranged differently';
    d.from = a;
    d.to = b;
    return d;
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = BB;
})(typeof window !== 'undefined' ? window : globalThis);
