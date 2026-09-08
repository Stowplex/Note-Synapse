/*
 * Big Bang - the board model: items, links, groups, ids, and the undo stack.
 *
 * board.js knows how a board is written down; this file knows what a board
 * MEANS. Three things here are worth more than the rest of it:
 *
 *   Referential integrity. Removing an item takes its links with it, drops it
 *   from every group, and detaches every annotation anchored to it. A graph
 *   model rots at exactly this seam, so every removal goes through one
 *   function and reports what it swept up.
 *
 *   Transactions. Every edit runs inside begin/commit - mutate(fn) is the
 *   ordinary way to say that - and nested transactions join the outer one, so
 *   a multi-item change is ONE undo step by construction rather than by the
 *   caller remembering. Callers cannot create half a step: an abort at any
 *   depth rolls the WHOLE transaction back, because a nested transaction is
 *   not a transaction of its own to abort.
 *
 *   One set of field rules. Nothing here decides for itself what a position or
 *   a colour is worth: every value entering a board goes through board.js's
 *   coerce* helpers, the same ones that read a block off a note. When the two
 *   sides had their own rules the write side accepted a NaN coordinate that
 *   the read side then refused, and the card - with its links, its group
 *   membership and its annotations - was gone the next time the board opened.
 */
(function (global) {
  'use strict';
  var BB = (global.BB = global.BB || {});
  var BOARD = BB.board;
  var M = (BB.model = {});

  M.UNDO_LIMIT = 50;

  var PREFIX = { note: 'n', sticky: 's', annot: 'a' };

  function clone(x) { return JSON.parse(JSON.stringify(x)); }
  M.clone = clone;

  M.create = function () { return BOARD.empty(); };

  function itemOkIn(board) {
    return function (id) { return BOARD.hasItem(board, id); };
  }

  /* -------------------------------------------------------------------- ids */

  // Every id on a board - items, links and groups alike - is unique across all
  // three, so an id read out of a link or an anchor can never mean two things.
  M.idTaken = function (board, id) {
    if (BOARD.hasItem(board, id)) return true;
    var i;
    for (i = 0; i < board.links.length; i++) if (board.links[i].i === id) return true;
    for (i = 0; i < board.groups.length; i++) if (board.groups[i].i === id) return true;
    return false;
  };

  M.newId = function (board, prefix) {
    var re = new RegExp('^' + prefix + '(\\d+)$'), max = 0;
    var scan = function (id) {
      var m = re.exec(id);
      if (m) { var v = parseInt(m[1], 10); if (v > max) max = v; }
    };
    Object.keys(board.items).forEach(scan);
    board.links.forEach(function (l) { scan(l.i); });
    board.groups.forEach(function (g) { scan(g.i); });
    var n = max + 1, id = prefix + n;
    while (M.idTaken(board, id)) { n++; id = prefix + n; }
    return id;
  };

  /* ------------------------------------------------------------------ items */

  /*
   * addItem(board, spec) -> id | null
   *   spec.k     'note' | 'sticky' | 'annot'   (required)
   *   spec.id    the real note id, for k:'note' (required)
   *   spec.i     a board id to claim, when one is being restored
   *   spec.t     sticky/annotation text; for a note card, the last known title
   *   spec.p     [x, y] - board coordinates, or an offset from the first
   *              anchor for an anchored annotation. Absent means the origin;
   *              PRESENT and unusable (NaN, Infinity, one number, a string) is
   *              refused outright rather than rounded into a null on disk.
   *   spec.w     width  spec.c colour
   *   spec.at    annotation anchors: [{i:itemId} | {l:linkId}] - only those
   *              naming something on the board survive, deduped, in order
   *   spec.q     annotation's last absolute position
   */
  M.addItem = function (board, spec) {
    if (!spec) return null;
    var it = BOARD.coerceItem(spec, {
      loosePos: true,
      anchorOk: function (a) { return a.i ? BOARD.hasItem(board, a.i) : !!M.link(board, a.l); }
    });
    if (!it) return null;
    var id = (BOARD.okId(spec.i) && !M.idTaken(board, spec.i)) ? spec.i : M.newId(board, PREFIX[spec.k]);
    board.items[id] = it;
    return id;
  };

  M.item = function (board, id) { return BOARD.hasItem(board, id) ? board.items[id] : null; };

  M.itemsOfKind = function (board, k) {
    return Object.keys(board.items).filter(function (id) { return board.items[id].k === k; });
  };

  // Note cards for one real note id. More than one is a bug the merge path has
  // to avoid (see the plan), so it is asked about rather than assumed.
  M.cardsForNote = function (board, noteId) {
    return Object.keys(board.items).filter(function (id) {
      var it = board.items[id];
      return it.k === 'note' && it.id === noteId;
    });
  };

  M.moveItem = function (board, id, p) {
    var it = M.item(board, id);
    var next = BOARD.coercePoint(p);
    if (!it || !next) return false;
    it.p = next;
    return true;
  };

  /*
   * setWidth(board, id, w) -> did the stored width CHANGE
   *
   * Widths go through board.js's own rule, the same one the read side applies,
   * because a width written here that the read side would refuse comes back as
   * a card with no width at all - and, when the two sides disagreed about a
   * position, as no card at all. Answering "changed" rather than "accepted"
   * lets a caller tell a real resize from a finger that brushed the grip: a
   * width nobody moved leaves no undo step and marks nothing dirty.
   */
  M.setWidth = function (board, id, w) {
    var it = M.item(board, id);
    var next = BOARD.coerceWidth(w);
    if (!it || next === null) return false;
    if (it.w === next) return false;
    it.w = next;
    return true;
  };

  /*
   * The one removal path. Returns what it swept up:
   *   { removed, links: [linkId], groups: [groupId], detached: [annotId] }
   *
   * Groups: a member is dropped from `m`. A group left with no members is
   * removed too - a frame around nothing is not a frame, and leaving one behind
   * would resurrect as an invisible undeletable rectangle.
   *
   * Annotations: an anchor that named the removed item (or a link that went
   * with it) is dropped. An annotation whose LAST anchor goes away keeps its
   * last drawn position `q` and floats there. One that loses its FIRST anchor
   * but keeps others is put at that same last drawn position and flagged
   * `reanchor`, which means exactly one thing everywhere it appears: `p` is
   * ABSOLUTE until the renderer re-measures it against the new first anchor
   * (render.js `settle`). Leaving `p` as the offset it was and flagging it
   * anyway is how the annotation ends up a thousand board units away from the
   * thing it is about - the flag has to CONVERT, not just mark.
   */
  M.removeItem = function (board, id) {
    var out = { removed: false, links: [], groups: [], detached: [] };
    if (!BOARD.hasItem(board, id)) return out;
    delete board.items[id];
    out.removed = true;

    board.links = board.links.filter(function (l) {
      if (l.a !== id && l.b !== id) return true;
      out.links.push(l.i);
      return false;
    });

    board.groups = board.groups.filter(function (g) {
      var i = g.m.indexOf(id);
      if (i < 0) return true;
      g.m.splice(i, 1);
      if (g.m.length) return true;
      out.groups.push(g.i);
      return false;
    });

    var gone = { i: Object.create(null), l: Object.create(null) };
    gone.i[id] = 1;
    out.links.forEach(function (lid) { gone.l[lid] = 1; });
    detach(board, gone, out);

    // An annotation may itself be an endpoint or an anchor of another one.
    return out;
  };

  /*
   * An annotation's anchors have changed, and `p` may no longer mean what it
   * says. `p` is an OFFSET from the first anchor, so:
   *
   *   Nothing left to hang from. `q` - where the annotation was really drawn -
   *   becomes `p`, which is absolute from here on, and the flag goes with the
   *   offset it described.
   *
   *   A different anchor is first. `p` is an offset from one that has gone and
   *   means nothing; `q` is the absolute spot, so promoting it and setting
   *   `reanchor` tells the renderer that `p` is absolute. settle() turns it
   *   back into an offset from the NEW first anchor without the annotation
   *   moving on screen.
   *
   *   A different anchor is first and there is no `q`. The annotation has
   *   never been drawn, so there is no absolute spot to preserve and the flag
   *   would be a lie: `p` stays an offset and is read against the new first
   *   anchor instead. A `reanchor` left over from an earlier repair is cleared
   *   for exactly that reason - it would claim `p` is absolute when it is not.
   *
   * Two callers, removal and substitution, and they had this written out twice
   * until the copies disagreed about that last clause: one cleared the stale
   * flag and the other left it set, which is the contradiction between `p` and
   * `reanchor` that cost M4 its headline bug. One copy now.
   */
  function repairAnchor(it, firstChanged) {
    if (!it.at.length) {
      if (it.q) { it.p = it.q; delete it.q; }
      delete it.reanchor;
      return;
    }
    if (!firstChanged) return;
    if (it.q) { it.p = it.q.slice(); it.reanchor = true; }
    else delete it.reanchor;
  }
  M.repairAnchor = repairAnchor;

  function detach(board, gone, out) {
    Object.keys(board.items).forEach(function (aid) {
      var it = board.items[aid];
      if (it.k !== 'annot' || !it.at || !it.at.length) return;
      var first = it.at[0];
      var kept = it.at.filter(function (a) { return a.i ? !BOARD.has(gone.i, a.i) : !BOARD.has(gone.l, a.l); });
      if (kept.length === it.at.length) return;
      it.at = kept;
      out.detached.push(aid);
      // Anchor objects survive a filter, so identity is the whole test here.
      repairAnchor(it, kept[0] !== first);
    });
  }

  M.removeItems = function (board, ids) {
    var all = { removed: 0, links: [], groups: [], detached: [] };
    (ids || []).forEach(function (id) {
      var r = M.removeItem(board, id);
      if (!r.removed) return;
      all.removed++;
      all.links = all.links.concat(r.links);
      all.groups = all.groups.concat(r.groups);
      r.detached.forEach(function (d) { if (all.detached.indexOf(d) < 0) all.detached.push(d); });
    });
    return all;
  };

  /*
   * replaceItems(board, sources, survivorId) -> what it did
   *   { ok, removed: [id], links: {repointed, collapsed, dropped}, groups, annots }
   *
   * One card stands in for several: a merge substituting the merged note's
   * card for its sources, a sticky promoted to a note. Everything that pointed
   * at a source points at the survivor afterwards, and then the sources are
   * removed through the ordinary path.
   *
   * The three ways that can go wrong, all of them handled here rather than by
   * each caller:
   *
   *   A link whose OTHER end was also a source becomes a link from the
   *   survivor to itself. It is dropped: a card cannot be linked to itself,
   *   and a link the model refuses to make is not one it should keep.
   *
   *   Two links that repoint onto the same pair are the same line twice.
   *   Duplicates collapse to the first, and an annotation anchored to one that
   *   went is detached exactly as it would be if the link had been deleted.
   *
   *   `real` does not survive a repoint. It promises that a relationship
   *   between the two NOTES this line joins exists, and after a merge one of
   *   those notes is not the note it was - the relationship rows may have been
   *   rewritten, archived or left pointing at a source. A dot that lies about
   *   the library is worse than no dot.
   *
   * An annotation whose FIRST anchor changes identity is repaired the same way
   * a detached one is: `q`, the last spot it was really drawn at, becomes an
   * absolute `p` flagged `reanchor`, so the renderer re-measures the offset
   * without the annotation moving on screen.
   */
  M.replaceItems = function (board, sources, survivorId) {
    var out = { ok: false, removed: [], links: { repointed: 0, collapsed: 0, dropped: 0 }, groups: 0, annots: 0 };
    if (!BOARD.hasItem(board, survivorId)) return out;

    var gone = Object.create(null);
    (sources || []).forEach(function (id) {
      if (id !== survivorId && BOARD.hasItem(board, id)) gone[id] = 1;
    });
    out.ok = true;
    var ids = Object.keys(gone);
    if (!ids.length) return out;

    /* ---- links ---- */
    /*
     * Decide every winner before mutating a link. When an old line already
     * joins the final pair it wins over one that only arrived there by being
     * repointed, regardless of array order: its endpoints, style and `real`
     * flag still describe exactly the relationship it was drawn for.
     *
     * `alias` is equally important. A duplicate line disappears, but an
     * annotation attached to that relationship must follow the surviving
     * line rather than becoming a floating annotation merely because the two
     * source relationships collapsed into one.
     */
    var candidates = [], winners = Object.create(null), alias = Object.create(null), lost = Object.create(null);
    board.links.forEach(function (l) {
      var a = BOARD.has(gone, l.a) ? survivorId : l.a;
      var b = BOARD.has(gone, l.b) ? survivorId : l.b;
      var moved = a !== l.a || b !== l.b;
      if (a === b) { lost[l.i] = 1; out.links.dropped++; return; }
      var key = JSON.stringify(a < b ? [a, b] : [b, a]);
      var c = { link: l, a: a, b: b, moved: moved, key: key };
      var winner = winners[key];
      if (!winner) {
        winners[key] = c;
      } else if (winner.moved && !moved) {
        Object.keys(alias).forEach(function (id) {
          if (alias[id] === winner.link.i) alias[id] = l.i;
        });
        alias[winner.link.i] = l.i;
        lost[winner.link.i] = 1;
        winners[key] = c;
        out.links.collapsed++;
      } else {
        alias[l.i] = winner.link.i;
        lost[l.i] = 1;
        out.links.collapsed++;
      }
      candidates.push(c);
    });

    board.links = candidates.filter(function (c) { return winners[c.key] === c; }).map(function (c) {
      var l = c.link;
      if (c.moved) {
        l.a = c.a; l.b = c.b;
        delete l.real;
        out.links.repointed++;
      }
      return l;
    });

    /* ---- annotation anchors ---- */
    Object.keys(board.items).forEach(function (aid) {
      var it = board.items[aid];
      if (it.k !== 'annot' || !it.at || !it.at.length) return;
      var before = it.at[0];
      var seen = Object.create(null), next = [];
      it.at.forEach(function (a) {
        var to;
        if (a.i) {
          to = { i: BOARD.has(gone, a.i) ? survivorId : a.i };
        } else if (BOARD.has(alias, a.l)) {
          to = { l: alias[a.l] };
        } else if (BOARD.has(lost, a.l)) {
          return;
        } else {
          to = { l: a.l };
        }
        // An annotation cannot point at itself, and a substitution is the one
        // way it could come to.
        if (to.i === aid) return;
        var key = to.i ? 'i' + to.i : 'l' + to.l;
        if (BOARD.has(seen, key)) return;
        seen[key] = 1;
        next.push(to);
      });
      var same = next.length === it.at.length && next.every(function (a, i) {
        return a.i ? a.i === it.at[i].i : a.l === it.at[i].l;
      });
      if (same) return;
      it.at = next;
      out.annots++;
      // A substitution builds new anchor objects, so identity says nothing and
      // the comparison has to be on what they point at.
      var first = next[0];
      repairAnchor(it, !first || !before ||
        (first.i ? first.i !== before.i : first.l !== before.l));
    });

    /* ---- group membership ---- */
    board.groups.forEach(function (g) {
      var seen = Object.create(null), next = [];
      var touched = false;
      g.m.forEach(function (m) {
        var to = BOARD.has(gone, m) ? survivorId : m;
        if (to !== m) touched = true;
        if (BOARD.has(seen, to)) { touched = true; return; }
        seen[to] = 1;
        next.push(to);
      });
      if (!touched) return;
      g.m = next;
      out.groups++;
    });

    ids.forEach(function (id) {
      if (M.removeItem(board, id).removed) out.removed.push(id);
    });
    return out;
  };

  /* ------------------------------------------------------------------ links */

  M.link = function (board, id) {
    for (var i = 0; i < board.links.length; i++) if (board.links[i].i === id) return board.links[i];
    return null;
  };

  M.linksOf = function (board, itemId) {
    return board.links.filter(function (l) { return l.a === itemId || l.b === itemId; });
  };

  M.findLink = function (board, a, b) {
    for (var i = 0; i < board.links.length; i++) {
      var l = board.links[i];
      if ((l.a === a && l.b === b) || (l.a === b && l.b === a)) return l;
    }
    return null;
  };

  M.addLink = function (board, a, b, opts) {
    opts = opts || {};
    var l = BOARD.coerceLink(
      { i: M.newId(board, 'l'), a: a, b: b, h: opts.h, d: opts.d, c: opts.c, t: opts.t, real: opts.real },
      { itemOk: itemOkIn(board) }
    );
    if (!l) return null;
    board.links.push(l);
    return l;
  };

  M.removeLink = function (board, id) {
    var out = { removed: false, detached: [] };
    var before = board.links.length;
    board.links = board.links.filter(function (l) { return l.i !== id; });
    if (board.links.length === before) return out;
    out.removed = true;
    var gone = { i: Object.create(null), l: Object.create(null) };
    gone.l[id] = 1;
    detach(board, gone, out);
    return out;
  };

  /* ----------------------------------------------------------------- groups */

  M.group = function (board, id) {
    for (var i = 0; i < board.groups.length; i++) if (board.groups[i].i === id) return board.groups[i];
    return null;
  };

  M.groupsOf = function (board, itemId) {
    return board.groups.filter(function (g) { return g.m.indexOf(itemId) >= 0; });
  };

  M.addGroup = function (board, members, opts) {
    opts = opts || {};
    var g = BOARD.coerceGroup(
      { i: M.newId(board, 'g'), m: members, t: opts.t, c: opts.c },
      { itemOk: itemOkIn(board) }
    );
    if (!g) return null;
    board.groups.push(g);
    return g;
  };

  M.removeGroup = function (board, id) {
    var before = board.groups.length;
    board.groups = board.groups.filter(function (g) { return g.i !== id; });
    return board.groups.length !== before;
  };

  // Replacing every member with nothing that survives removes the group, for
  // the same reason removeItem does: a frame around nothing is not a frame.
  M.setGroupMembers = function (board, id, members) {
    var g = M.group(board, id);
    if (!g) return false;
    var next = BOARD.coerceGroup({ i: g.i, m: members }, { itemOk: itemOkIn(board) });
    if (!next) return M.removeGroup(board, id);
    g.m = next.m;
    return true;
  };

  /* ------------------------------------------------- text, colour, style */

  /*
   * Items, links and groups share ONE id space - `idTaken` guarantees it - so
   * an id names exactly one thing and a setter can find that thing without
   * being told which of the three it is. This is what lets the app hold a
   * single "what is selected" id and hand it to any of the setters below.
   */
  M.any = function (board, id) {
    return M.item(board, id) || M.link(board, id) || M.group(board, id);
  };

  /*
   * What an id IS: 'note' | 'sticky' | 'annot' | 'link' | 'group' | null.
   * The app draws a different bar for each and there is no other way to tell
   * them apart from an id alone.
   */
  M.kindOf = function (board, id) {
    if (BOARD.hasItem(board, id)) return board.items[id].k;
    if (M.link(board, id)) return 'link';
    if (M.group(board, id)) return 'group';
    return null;
  };

  /*
   * The text a user typed: a sticky's or an annotation's body, a link's label,
   * a group's name. All four are the `t` field, all four go through board.js's
   * rule, and all four answer "did it CHANGE" - a field re-typed identically is
   * not an undo step and not a reason to rewrite the note.
   *
   * A note card's `t` is refused outright. There it is the last title read off
   * the note, kept for one purpose (labelling a tombstone), and a user editing
   * it would be renaming a card in a way the next resolve silently undoes.
   */
  M.setText = function (board, id, t) {
    var o = M.any(board, id);
    if (!o) return false;
    if (BOARD.hasItem(board, id) && o.k === 'note') return false;
    /*
     * Only a string, and '' is one. coerceText turns anything that is not a
     * string into '' - which is the right answer when READING a block, where
     * a number where text should be is simply not text - but here it would
     * make setText(id, undefined) silently erase what the user had written.
     * Clearing a label is a real action; it just has to be asked for.
     */
    if (typeof t !== 'string') return false;
    var next = BOARD.coerceText(t);
    if ((o.t || '') === next) return false;
    if (next) o.t = next; else delete o.t;
    return true;
  };

  // A colour, or null to take it off again. Items, links and groups alike.
  M.setColour = function (board, id, c) {
    var o = M.any(board, id);
    if (!o) return false;
    var next = c == null ? null : BOARD.coerceColour(c);
    if ((o.c == null ? null : o.c) === next) return false;
    if (next === null) delete o.c; else o.c = next;
    return true;
  };

  /*
   * A link's head and dash. Anything that is not one of the three values the
   * format allows is ignored rather than stored: board.js would substitute the
   * default on the way back in, so writing it would make the drawn line and
   * the saved line disagree until the next reload.
   */
  M.setLinkStyle = function (board, id, spec) {
    var l = M.link(board, id);
    if (!l || !spec) return false;
    var changed = false;
    if (spec.h != null && BOARD.has(BOARD.HEADS, spec.h) && l.h !== spec.h) { l.h = spec.h; changed = true; }
    if (spec.d != null && BOARD.has(BOARD.DASHES, spec.d) && l.d !== spec.d) { l.d = spec.d; changed = true; }
    return changed;
  };

  /*
   * Whether a real note relationship stands behind a drawn line.
   *
   * It is written ONLY after the host has said it wrote (or removed) the
   * relationship - the flag is a claim about the user's library, not about the
   * board, and a board that set it hopefully would draw a dot for a
   * relationship that does not exist. Absent rather than false when there is
   * none, because that is how the block spells it.
   */
  M.setLinkReal = function (board, id, real) {
    var l = M.link(board, id);
    if (!l) return false;
    var want = real === true;
    if ((l.real === true) === want) return false;
    if (want) l.real = true; else delete l.real;
    return true;
  };

  /* --------------------------------------------------------- anchors / view */

  /*
   * An anchored annotation's `p` is an OFFSET from its first anchor, not a
   * place on the plane, which is why moving one cannot go through moveItem:
   * that writes an absolute position, and the annotation would leap by the
   * anchor's coordinates the next time it was drawn.
   *
   * Setting the offset also clears `reanchor`. That flag means "`p` is an
   * absolute spot measured against an anchor that has gone"; giving it a real
   * offset is precisely the repair the flag was asking for.
   */
  M.setAnnotOffset = function (board, id, p) {
    var it = M.item(board, id);
    var next = BOARD.coercePoint(p);
    if (!it || it.k !== 'annot' || !next) return false;
    var same = it.p[0] === next[0] && it.p[1] === next[1] && !it.reanchor;
    it.p = next;
    delete it.reanchor;
    return !same;
  };

  /*
   * `q` - where an anchored annotation was last actually drawn.
   *
   * It exists for the moments where an anchor disappears. Losing the LAST one
   * promotes `q` to `p` so the annotation stays where the user saw it instead
   * of jumping to an offset from nothing; losing the FIRST one promotes it too
   * and sets `reanchor`, so that `p` is an absolute spot the renderer can
   * convert into an offset from whichever anchor is first now. Either way the
   * annotation does not move on screen, and `q` is the only value that makes
   * that possible: it is the one absolute position anybody wrote down.
   *
   * It is a cache of the renderer's geometry, so it is refreshed whenever the
   * board is drawn and NOTHING marks the board dirty for it. See render.js
   * `settle`.
   */
  M.stampSpot = function (board, id, q) {
    var it = M.item(board, id);
    var next = BOARD.coercePoint(q);
    if (!it || it.k !== 'annot' || !next) return false;
    if (it.q && it.q[0] === next[0] && it.q[1] === next[1]) return false;
    it.q = next;
    return true;
  };

  M.setAnchors = function (board, annotId, anchors) {
    var it = M.item(board, annotId);
    if (!it || it.k !== 'annot') return false;
    var coerced = BOARD.coerceItem({ k: 'annot', p: it.p, at: anchors }, {
      anchorOk: function (a) {
        return a.i ? (BOARD.hasItem(board, a.i) && a.i !== annotId) : !!M.link(board, a.l);
      }
    });
    it.at = coerced ? coerced.at : [];
    return true;
  };

  /*
   * setView(board, p, z) -> did the stored view CHANGE
   *
   * A pan of NaN or a zoom of 0 (a gesture layer dividing by a zoom that had
   * not settled) is ignored rather than stored: the view is what the board is
   * reopened at, and a null in there loses the user their place.
   *
   * The answer is "changed", not "accepted". Every settled gesture calls this,
   * and the app marks the board dirty on the strength of it; a pan that ended
   * where it started, or a zoom that rounded to the four decimals already on
   * the board, is not a reason to re-read the note and write it back.
   */
  M.setView = function (board, p, z) {
    var changed = false;
    if (p != null) {
      var np = BOARD.coercePoint(p);
      if (np && (np[0] !== board.view.p[0] || np[1] !== board.view.p[1])) {
        board.view.p = np;
        changed = true;
      }
    }
    if (z != null) {
      var nz = BOARD.coerceZoom(z);
      if (nz !== null && nz !== board.view.z) {
        board.view.z = nz;
        changed = true;
      }
    }
    return changed;
  };

  /* ------------------------------------------------------ search and focus */

  /*
   * Both of the answers below are about what the user is LOOKING at, and
   * neither writes a thing. They live here because they are graph questions -
   * what matches, what is connected to what - and because a pure function is
   * the only kind that can be asserted on without a browser.
   *
   * Text, never markup. `faceOf` is handed in rather than reached for, so this
   * file stays ignorant of notes.js, and what comes back through it is the same
   * text the card draws with textContent: a note called `<img onerror=...>` is
   * searched for as those characters and nothing else can happen to it.
   */
  function norm(s) {
    return String(s == null ? '' : s).replace(/\s+/g, ' ').trim().toLowerCase();
  }
  M.normQuery = norm;

  /*
   * search(board, query, faceOf) -> { q, count, hit, lit }
   *
   *   hit  what actually matched: items, links and groups by id.
   *   lit  what stays undimmed, which is more than that: a link that matched
   *        brings its two ends, a group its members, and a link BETWEEN two lit
   *        cards stays lit too - a line drawn at half brightness between two
   *        bright cards reads as a fault rather than as an answer.
   *
   * An empty query matches nothing and lights nothing; the caller draws the
   * board normally rather than dimming all of it.
   */
  M.search = function (board, query, faceOf) {
    var q = norm(query);
    var out = { q: q, count: 0, hit: Object.create(null), lit: Object.create(null) };
    if (!board || !q) return out;

    function hit(id) {
      if (BOARD.has(out.hit, id)) return;
      out.hit[id] = 1;
      out.count++;
    }
    function matches(text) { return norm(text).indexOf(q) >= 0; }

    Object.keys(board.items).forEach(function (id) {
      var it = board.items[id];
      if (it.k === 'note') {
        var face = faceOf ? faceOf(id) : null;
        if (face && (matches(face.title) || matches(face.excerpt))) hit(id);
        else if (!face && matches(it.t)) hit(id);
        return;
      }
      if (matches(it.t)) hit(id);
    });
    board.links.forEach(function (l) { if (matches(l.t)) hit(l.i); });
    board.groups.forEach(function (g) { if (matches(g.t)) hit(g.i); });

    Object.keys(out.hit).forEach(function (id) { out.lit[id] = 1; });
    board.links.forEach(function (l) {
      if (!BOARD.has(out.hit, l.i)) return;
      out.lit[l.a] = 1;
      out.lit[l.b] = 1;
    });
    board.groups.forEach(function (g) {
      if (!BOARD.has(out.hit, g.i)) return;
      g.m.forEach(function (m) { out.lit[m] = 1; });
    });
    board.links.forEach(function (l) {
      if (BOARD.has(out.lit, l.a) && BOARD.has(out.lit, l.b)) out.lit[l.i] = 1;
    });
    return out;
  };

  /*
   * neighbourhood(board, id) -> { lit, count, ok }
   *
   * What "connected to this card" means, in full: the card itself, every link
   * touching it and whatever is at the other end, every annotation pointing at
   * the card or at one of those links, and the frame of any group it belongs
   * to. A group's other members are NOT lit - the frame says where they are,
   * and lighting a card because it shares a frame with the focus would make
   * focus on a big group mean nothing at all.
   */
  M.neighbourhood = function (board, id) {
    var out = { lit: Object.create(null), count: 0, ok: false };
    if (!board || !BOARD.hasItem(board, id)) return out;
    out.ok = true;
    out.lit[id] = 1;
    board.links.forEach(function (l) {
      if (l.a !== id && l.b !== id) return;
      out.lit[l.i] = 1;
      var other = l.a === id ? l.b : l.a;
      if (!BOARD.has(out.lit, other)) { out.lit[other] = 1; out.count++; }
    });
    /*
     * One pass, against a SNAPSHOT of what the links lit. Testing against the
     * live set instead would let an annotation anchored to another annotation
     * join the neighbourhood only when the two happened to be visited in the
     * right order - which is insertion order, and so an answer that depends on
     * which was drawn first.
     */
    var base = Object.create(null);
    Object.keys(out.lit).forEach(function (k) { base[k] = 1; });
    Object.keys(board.items).forEach(function (aid) {
      var it = board.items[aid];
      if (it.k !== 'annot' || !it.at || !it.at.length) return;
      var points = it.at.some(function (a) {
        return a.i ? BOARD.has(base, a.i) : BOARD.has(base, a.l);
      });
      if (points && !BOARD.has(out.lit, aid)) { out.lit[aid] = 1; out.count++; }
    });
    board.groups.forEach(function (g) {
      if (g.m.indexOf(id) >= 0) out.lit[g.i] = 1;
    });
    return out;
  };

  /* ------------------------------------------------------------ undo stack */

  /*
   * A store owns one board object for its whole life. Undo and redo restore
   * INTO that object rather than replacing it, so a reference taken once - by
   * the renderer, by a gesture in flight - never goes stale.
   *
   *   store.mutate('move cards', function (board) { ... })   one step
   *   store.begin('drag'); ...; store.commit()               the same thing
   *   store.abort()                                          roll back, no step
   *
   * Nested transactions join the outer one and commit with it, so a helper
   * that mutates cannot split its caller's step in two. For the same reason an
   * abort at ANY depth rolls back to where the OUTERMOST transaction began and
   * poisons the rest of it: half of an inner edit committed as part of its
   * caller's step is exactly the half-step this is here to prevent. A
   * transaction that changed nothing leaves no step behind. Any new edit clears
   * the redo stack: redo only ever means "the future I just undid", never a
   * branch.
   */
  function copyInto(target, src) {
    // Copying an object into itself is a no-op, not an emptying: the delete
    // pass below would otherwise clear both, since they are the same object.
    if (target === src) return target;
    Object.keys(target).forEach(function (k) { delete target[k]; });
    Object.keys(src).forEach(function (k) { target[k] = src[k]; });
    return target;
  }

  M.store = function (board) {
    var st = {
      board: board || BOARD.empty(),
      undo: [],
      redo: [],
      limit: M.UNDO_LIMIT,
      depth: 0,
      onChange: null
    };
    var baseJson = '', label = '', aborted = false;

    st.begin = function (name) {
      st.depth++;
      if (st.depth === 1) {
        baseJson = JSON.stringify(st.board);
        label = name || '';
        aborted = false;
      }
      return st;
    };

    function restore() { copyInto(st.board, JSON.parse(baseJson)); }

    st.commit = function () {
      if (!st.depth) return false;
      st.depth--;
      if (st.depth) return false;
      if (aborted) { restore(); aborted = false; return false; }
      var now = JSON.stringify(st.board);
      if (now === baseJson) return false;      // nothing happened; no step
      st.undo.push({ board: JSON.parse(baseJson), label: label });
      while (st.undo.length > st.limit) st.undo.shift();
      st.redo.length = 0;
      if (st.onChange) st.onChange('edit', label);
      return true;
    };

    st.abort = function () {
      if (!st.depth) return false;
      st.depth--;
      restore();
      if (st.depth) { aborted = true; return true; }
      aborted = false;
      return true;
    };

    st.mutate = function (name, fn) {
      if (typeof name === 'function') { fn = name; name = ''; }
      st.begin(name);
      var out;
      try {
        out = fn(st.board);
      } catch (e) {
        st.abort();
        throw e;
      }
      st.commit();
      return out;
    };

    st.canUndo = function () { return st.undo.length > 0; };
    st.canRedo = function () { return st.redo.length > 0; };

    st.undoStep = function () {
      if (st.depth || !st.undo.length) return null;
      var step = st.undo.pop();
      st.redo.push({ board: clone(st.board), label: step.label });
      copyInto(st.board, step.board);
      if (st.onChange) st.onChange('undo', step.label);
      return step.label || '';
    };

    st.redoStep = function () {
      if (st.depth || !st.redo.length) return null;
      var step = st.redo.pop();
      st.undo.push({ board: clone(st.board), label: step.label });
      while (st.undo.length > st.limit) st.undo.shift();
      copyInto(st.board, step.board);
      if (st.onChange) st.onChange('redo', step.label);
      return step.label || '';
    };

    // Load a board from elsewhere (a reload, a conflict resolved in their
    // favour). Deep-copied on the way in: the caller's object - a board parsed
    // out of THEIR note text, say - stays theirs, and no later edit here writes
    // through into it. History is not undo-able across a reset, so it is
    // dropped.
    st.reset = function (next) {
      copyInto(st.board, clone(next || BOARD.empty()));
      st.undo.length = 0;
      st.redo.length = 0;
      st.depth = 0;
      baseJson = '';
      aborted = false;
      return st.board;
    };

    return st;
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = BB;
})(typeof window !== 'undefined' ? window : globalThis);
