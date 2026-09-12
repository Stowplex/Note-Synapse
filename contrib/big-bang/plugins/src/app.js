/*
 * Big Bang - the app: state, wiring, selection, the bars.
 *
 * Everything below is policy. board.js says how a board is written down,
 * model.js what it means, host.js how it reaches the note, render.js how it
 * looks and gestures.js what the finger did; this file is the only place that
 * decides what any of that should DO.
 *
 * The decisions it holds:
 *
 *   A refusal is a state, not an error dialog. A board written by a newer Big
 *   Bang, a hand-damaged block, a note holding two of them - each opens
 *   read-only, says why in one line, and still pans, zooms and reads. Nothing
 *   is ever forced on the user's behalf; forcing takes a second, explicit yes.
 *
 *   One gesture is one undo step. The gesture layer moves elements; this file
 *   writes the model once, inside a single transaction, when the gesture ends.
 *   Dragging nine cards and undoing puts nine cards back.
 *
 *   The camera is not an edit. Panning and zooming are written into the board's
 *   `view` outside the undo stack, and undo re-applies the camera you are
 *   looking at rather than the one the step was recorded under: undo is for
 *   what you did to the board, not for where you were standing.
 *
 *   The title refresh is not an edit either - see notes.js. Nor is the camera
 *   fit a board gets when it opens with no view of its own. Both change the
 *   block, both have to be written down eventually, and NEITHER schedules a
 *   save of its own: they ride along with the next thing the user actually
 *   does. A board that writes its note the moment it is opened moves that note
 *   to the top of the recents list for having been LOOKED at, and raises a
 *   conflict against a second session in which nobody typed anything.
 *
 *   Forcing names its reason. The user is shown one refusal and agrees to one
 *   refusal; a yes to "overwrite the other session's board" is not a yes to
 *   "replace the damaged block", and each is asked separately.
 *
 *   Saving is debounced and serialised by host.js. There is exactly one save
 *   lock and it lives there; nothing here adds a second one. A conflict is
 *   shown, named in cards and links, and left to the user.
 *
 *   A refusal is SAID. A link needs two different cards; a group needs two
 *   members; two cards already joined are not joined twice. Every one of those
 *   answers in a line of text rather than by doing nothing, because a button
 *   that silently declines is indistinguishable from a tap that missed.
 *
 *   An empty sticky is never written. A box created by a long press exists
 *   only in memory until it has text in it: no undo step, nothing marked dirty,
 *   and - since a save on some other timer could still fire while it sits there
 *   - it is lifted back out of the board on the way to the note. Abandoning a
 *   stray tap has to leave the user's note byte for byte as it was.
 *
 *   A write to a note OTHER than the board's is stated before it is asked for.
 *   Everything up to this point wrote one note: the one the board lives in.
 *   Promoting a sticky, linking two notes, tagging a group and ticking a task
 *   write to the user's library, so each says what will be written and to which
 *   notes, and then the host asks its own question. Two of those are worth
 *   knowing: `saveNotes` has no approval dialog at all, so the sheet here is
 *   the ONLY consent a new note gets; and `updateNotes` asks once per session,
 *   so every write after the first would otherwise be silent.
 *
 *   And what came back is read, not assumed. `success:true` means the call
 *   ran. `updatedCount` says how much of it landed and `errors` says what did
 *   not, and both are reported - a batch that tagged four notes of five says
 *   four, and says why the fifth is missing.
 */
(function (global) {
  'use strict';
  var BB = (global.BB = global.BB || {});
  var BOARD = BB.board, M = BB.model, HOST = BB.host, N = BB.notes, RENDER = BB.render, GEST = BB.gestures;
  var AI = BB.ai, EX = BB.export;
  var I18n = BB.i18n;
  var A = (BB.app = {});

  function tr(text) { return I18n ? I18n.text(text) : String(text == null ? '' : text); }
  function applyStaticLanguage() {
    Array.prototype.forEach.call(document.querySelectorAll('[data-i18n]'), function (node) {
      node.textContent = tr(node.getAttribute('data-i18n'));
    });
    Array.prototype.forEach.call(document.querySelectorAll('[data-i18n-title]'), function (node) {
      node.title = tr(node.getAttribute('data-i18n-title'));
    });
    Array.prototype.forEach.call(document.querySelectorAll('[data-i18n-placeholder]'), function (node) {
      node.placeholder = tr(node.getAttribute('data-i18n-placeholder'));
    });
  }

  var EDIT_MS = 900;          // debounce after an edit
  var VIEW_MS = 2600;         // ... and after a pan or a zoom, which is cheaper
  var RETRY_MS = 5000;
  var PAD = 44;               // fit margin, board units
  // The bars live outside the stage, so the stage rectangle is already the
  // visible canvas. The BIN is the one thing that floats over it, so a fit
  // leaves its strip clear rather than tucking a card underneath it.
  var BIN_H = 72;

  var S = {
    booted: false,
    // 'board' or 'home'. One HTML, told apart at runtime by what it was
    // launched with (see A.boot) - there is no build flag and no code fork.
    mode: 'board',
    // The app arrived with no note, so there is a list of boards to go back
    // to. A note-action launch has none: that note IS the canvas, and a Home
    // button on it would offer to leave for somewhere it never came from.
    standalone: false,
    // The read-mostly embed. It is read-only as well, which is what makes the
    // refusals real rather than a matter of which buttons were drawn.
    embed: false,
    // { loading, boards, error, more, counts, limit } while the home is up.
    home: null,
    // The search box, and what it found. View state: never written to a note.
    searching: false,
    query: '',
    found: null,
    // The card being focused on, and the set of ids that stay bright for
    // either reason. `lit` null means the whole board is lit.
    focus: null,
    lit: null,
    // A note picker is open. Like the merge screen, it is a screen the user
    // drives, and two of them at once is two answers to one question.
    picking: false,
    // A board is being left or opened. Every path in and out of a board goes
    // through one function, and it must not be re-entered part way through.
    switching: false,
    /*
     * Which board this is, counted rather than identified.
     *
     * Everything that waits on a screen - the merge screen, a model, a
     * rasteriser - has to ask afterwards whether the board it was about is
     * still the board on the glass. `S.session` looked like the answer and is
     * not: adopting another session's board REPLACES the board's contents and
     * KEEPS the session object (it only rewrites its key), so an identity test
     * against it never fires for the one case that matters most. A counter
     * bumped wherever a board is closed or replaced wholesale is the honest
     * question, and it costs nothing.
     */
    gen: 0,
    store: null,
    session: null,
    cache: null,
    r: null,                  // the renderer
    gest: null,
    note: null,
    tx: 0, ty: 0, k: 1,
    sel: Object.create(null),
    selectMode: false,
    barOpen: false,
    // The one link, or the one group, whose bar is open. Never both: a bar
    // shows one thing, and a selection that meant two would have to choose.
    linkSel: null,
    groupSel: null,
    // Which second-level bar is showing - 'colour', 'align', 'head', 'dash'.
    barMode: '',
    // The id whose text has the caret in it, and the id of a box created by
    // this gesture that has never held any text.
    editing: null,
    // The ELEMENT that id was given the caret in. Held rather than looked up
    // again, because every reason `S.editing` gets cleared - an undo removed
    // the item, another session's board was adopted - is also a reason the
    // model can no longer say which element it was. See endEdit.
    field: null,
    fresh: null,
    link: null,               // a link being dragged out of a card's port
    toastT: null,
    hold: null,               // the banner a toast is standing in front of
    readOnly: false,
    why: '',
    banner: null,             // { text, tone, actions: [{label, fn}] }
    // A question is standing in the banner, and what stood there BEFORE it.
    // Cancel puts that back - which is never another question: a second `ask`
    // replaces the first, and re-arming an unanswered yes the user has not
    // looked at since is not an undo.
    asking: false,
    asked: null,
    dirty: false,
    // The board differs from the note, but not because of anything the user
    // did. It is written on the next real save and never schedules one.
    soft: false,
    saving: false,
    saveTimer: null,
    saves: 0,
    // The save that is OUT: a real bridge call with a real await in it. It is
    // held as a promise rather than only as the `saving` flag because leaving
    // a board has to WAIT for it - a leave that stepped around it swaps the
    // session before the answer lands, and the answer is then declined by the
    // guard in save(), taking the refusal and the edit with it.
    inflight: null,
    flushing: null,           // a save started by the app going away
    lastSaveError: '',
    drag: null,
    resolveError: '',
    tombstones: 0,
    noTags: false,
    /*
     * The AI's suggested links, and the request that is out for them.
     *
     * NOT board state. They are drawn - dashed, accented, labelled - and they
     * are not in the board, not in the undo stack, not in the note and not in
     * anything a save writes. Discarding them leaves no trace at all, and
     * applying them is one ordinary edit that draws real links.
     */
    proposals: null,
    suggesting: false,
    // A picture of the board is being drawn and attached. One at a time: two
    // exports of one board would attach two files and each would remove the
    // other's.
    exporting: false,
    // The merge screen is open. The host deliberately has no re-entrancy guard
    // of its own - it was left to the calling plugin - and two overlapping
    // merges of the same cards would make two merged notes.
    merging: false,
    // A write to somebody else's note is in flight. One at a time: they each
    // put a question on the screen, and two questions about two different
    // notes at once is how the wrong one gets answered.
    writing: false,
    // A note write landed and this board could not record it - the merge
    // screen was open while a refused save turned the board read-only. The
    // substitution is in the board and is not in the note, which is a thing
    // the user has to be told rather than left to find.
    stranded: false
  };
  A.S = S;
  /*
   * Every action the app can take, in one place, and declared HERE - before
   * the first of them is written down. It used to be initialised half way
   * through the file, which was fine until something above that line wanted to
   * add an action to it and had the whole object replaced underneath it.
   */
  A.ops = {};

  var el = {};
  function $(id) { return document.getElementById(id); }
  var clamp = GEST.clamp;
  function selIds() { return Object.keys(S.sel); }
  function selCount() { return selIds().length; }

  /* ==================================================================== */
  /* boot                                                                  */
  /* ==================================================================== */

  /*
   * ONE HTML, and what it opens on is decided here and nowhere else.
   *
   * | launched with            | what happens                                |
   * | no note                  | the board home: recents, New board, picker  |
   * | one note                 | that note IS the canvas                     |
   * | several notes            | a new board holding all of them             |
   * | ?board=<noteId>          | that board, whatever it was launched with   |
   * | ?standalone=1            | the home, even with a note in hand          |
   * | ?mode=embed              | the read-mostly embed of the note's board   |
   *
   * The parameters come from Synapse.Params, which is how the host delivers an
   * embed's query string; the note-action multi-selection arrives in
   * Synapse.Notes with no host change at all. An embed of a board inside its
   * own note is written in that note as
   *
   *   @[100% x 480](synapseresource://app/9f6001dd-661d-4aa7-ba18-c54164b94338?note=current&mode=embed)
   *
   * - the uuid of the `normal` app, which plugins/build.sh emits.
   */
  A.boot = function () {
    if (I18n) I18n.setLanguage((global.Synapse && global.Synapse.locale) || 'en-US');
    applyStaticLanguage();
    el.stage = $('stage'); el.scene = $('scene'); el.cards = $('cards'); el.edges = $('edges');
    el.groups = $('groups'); el.handles = $('handles');
    el.bin = $('bin'); el.bar = $('bottombar'); el.banner = $('banner'); el.hint = $('hint');
    el.title = $('title'); el.badge = $('badge');
    el.undo = $('btnUndo'); el.redo = $('btnRedo'); el.fit = $('btnFit');
    el.home = $('home'); el.homeBtn = $('btnHome'); el.searchBtn = $('btnSearch');
    el.searchbar = $('searchbar'); el.q = $('q'); el.qcount = $('qcount'); el.qdone = $('qdone');

    S.r = RENDER.make({
      scene: el.scene, cards: el.cards, edges: el.edges,
      groups: el.groups, handles: el.handles
    });
    S.cache = N.cache();
    S.store = M.store(BOARD.empty());

    el.undo.addEventListener('click', function () { A.ops.undo(); });
    el.redo.addEventListener('click', function () { A.ops.redo(); });
    el.fit.addEventListener('click', function () { A.ops.fit(); });
    if (el.homeBtn) el.homeBtn.addEventListener('click', function () { A.ops.goHome(); });
    if (el.searchBtn) el.searchBtn.addEventListener('click', function () { A.ops.toggleSearch(); });
    if (el.qdone) el.qdone.addEventListener('click', function () { A.ops.endSearch(); });
    if (el.q) {
      el.q.addEventListener('input', function () { A.ops.search(el.q.value); });
      el.q.addEventListener('keydown', function (e) {
        if (e.key === 'Escape') { e.preventDefault(); A.ops.endSearch(); }
      });
    }

    S.gest = GEST.attach({ viewport: el.stage, api: gestureApi() });

    var params = HOST.params();
    var notes = launchNotes();
    S.embed = String(params.mode || '') === 'embed';
    S.standalone = !S.embed && (isOn(params.standalone) || !notes.length);

    if (S.embed) {
      // An embed renders the board inside its OWN note, so the note it was
      // given is the board - `?board=` is honoured too, for an embed pointed
      // somewhere else on purpose.
      var target = params.board || (notes[0] && notes[0].id);
      if (!target) {
        S.booted = true;
        S.mode = 'board';
        applyMode();
        setReadOnly('There is no note here to draw a board from.');
        drawBars();
        return Promise.resolve(false);
      }
      return openBoard(target, { title: notes[0] && notes[0].title });
    }
    if (params.board) return openBoard(params.board);
    if (S.standalone) return A.ops.goHome();
    if (notes.length === 1) return openBoard(notes[0].id, { title: notes[0].title });
    return newBoardFor(notes);
  };

  /*
   * A flag on a query string, which is present far more often than it is
   * given a value: `?standalone` and `?standalone=1` both mean yes, and an
   * ABSENT parameter means no. The two are told apart before the string is
   * lowercased, because `String(undefined)` is a perfectly good string and
   * reading a missing flag as an empty one turned every launch into the home.
   */
  function isOn(v) {
    if (v === undefined || v === null) return false;
    var s = String(v).toLowerCase();
    return s === '' || s === '1' || s === 'true' || s === 'yes';
  }
  A.isOn = isOn;

  /*
   * The notes the app was launched with, as things a card can point at.
   *
   * A block-scope selection carries the id of a BLOCK, which has no row in the
   * notes table: a card holding one would resolve to nothing and draw as a
   * tombstone the moment the board opened. The parent note is what it is part
   * of, and is what a board should point at - and once several blocks of one
   * note collapse to that parent, so must the duplicates.
   */
  function launchNotes() {
    var seen = Object.create(null), out = [];
    HOST.notes().forEach(function (n) {
      var id = (n.isBlockScope && n.parentNoteId) ? n.parentNoteId : n.id;
      if (!id || BOARD.has(seen, id)) return;
      seen[id] = 1;
      out.push({ id: id, title: n.title || '' });
    });
    return out;
  }
  A.launchNotes = launchNotes;

  /*
   * Open a board. Every way in - the launch, the home list, the picker, a
   * board just created - lands here, so there is one load, one judgement and
   * one set of rules about what opening costs.
   *
   * And opening costs NOTHING. The fit and the first title stamp are marked
   * soft: they are in the board, they ride out with the next real edit, and
   * neither starts a save. The home list is ordered by `updatedAt`, so a board
   * that wrote its note for having been looked at would climb to the top of
   * that list every time somebody glanced at it.
   */
  function openBoard(noteId, opts) {
    opts = opts || {};
    /*
     * A board never inherits the last one's state.
     *
     * closeBoard is where that usually happens, and A.ops.open runs it - but
     * this is the function every way in lands on, and two of those ways in
     * (the new board from the home, and the launch) reach it without a
     * closeBoard anywhere. Today nothing leaks through them, because the home
     * has already closed whatever was open; that is an accident of who calls
     * what, and the flags below are the ones whose leak is a bug the user has
     * to find - a healthy board opening read-only, quoting the reason the
     * PREVIOUS board could not be saved, and refusing every edit.
     *
     * The generation is bumped HERE and not only in closeBoard, for the same
     * reason. An answer still out for the last board - a suggestion, a picture
     * being rasterised - is scoped by `S.gen`, and on the two ways in that
     * reach this function without a closeBoard it was only ever the call order
     * that made that safe.
     */
    S.gen++;
    S.readOnly = false;
    S.why = '';
    S.stranded = false;
    S.merging = false;
    S.writing = false;
    S.lastSaveError = '';
    clearSel();
    S.mode = 'board';
    S.home = null;
    applyMode();
    el.title.textContent = opts.title || tr('Big Bang');
    return HOST.loadBoard(noteId).then(function (r) {
      if (!r.ok) {
        S.booted = true;
        S.session = null;
        setReadOnly('The note could not be read: ' + r.error);
        drawBars();
        return false;
      }
      S.note = { id: noteId, title: opts.title || '' };
      S.session = r.session;
      S.store.reset(r.board);
      judge(r);
      if (S.embed) {
        // Read-mostly, and read-only underneath: every refusal in this file
        // already answers to that flag, so an embed cannot write by a route
        // somebody forgot to hide a button on.
        S.readOnly = true;
        // Whatever judge() already decided keeps its reason: a damaged block
        // is still a damaged block when it is being looked at through an
        // embed, and "this is an embed" is not why it opened empty.
        if (!S.why) S.why = 'This is an embedded view of the board.';
        banner(null);
      }
      applyView(r.board.view);
      sync();
      if (isDefaultView(r.board.view) && Object.keys(r.board.items).length) A.ops.fit(true);
      else applyCamera(false, true);
      S.booted = true;
      drawBars();
      global.__BB_LOADED__ = r;
      if (!opts.title) nameBoard(noteId);
      return resolveNotes(false, true).then(function () { return true; });
    }).catch(function (e) {
      S.booted = true;
      setReadOnly('Something went wrong opening this board: ' + String((e && e.message) || e));
      drawBars();
      return false;
    });
  }
  A.ops.openBoard = openBoard;

  /*
   * The board note's own title, when the launch did not hand it over - a
   * ?board= parameter names an id and nothing else. Its own small query rather
   * than a card excerpt: the board note is not a card, nothing is drawn from
   * its body, and asking for `substr(content, ...)` would read a note nobody
   * is showing.
   */
  function nameBoard(noteId) {
    return HOST.readTitle(noteId).then(function (t) {
      if (!t || !S.session || S.session.noteId !== noteId) return;
      S.note = { id: noteId, title: t };
      el.title.textContent = t;
    });
  }

  /* ==================================================================== */
  /* the home, and moving between boards                                   */
  /* ==================================================================== */

  /*
   * Which of the two screens is showing. The home REPLACES the canvas rather
   * than floating over it: a list drawn on top of a board that is still taking
   * gestures underneath is how a tap lands somewhere nobody meant.
   */
  function applyMode() {
    var body = document.body;
    if (!body) return;
    body.classList.toggle('home', S.mode === 'home');
    body.classList.toggle('embed', !!S.embed);
    if (el.home) el.home.hidden = S.mode !== 'home';
    // Home is offered only where there is a home to go to. A note-action
    // launch has none - that note IS the canvas - and a button that left it
    // would be offering to go somewhere the app never came from.
    if (el.homeBtn) el.homeBtn.hidden = !(S.standalone && S.mode === 'board');
    if (el.searchBtn) el.searchBtn.hidden = S.mode !== 'board';
    if (el.searchbar) el.searchbar.hidden = !(S.searching && S.mode === 'board');
  }
  A.applyMode = applyMode;

  /*
   * Leaving a board, which is the one thing in this app that can silently lose
   * an edit.
   *
   * A save is debounced. Swapping the session and the store out from under a
   * timer that has not fired yet means the timer wakes up, finds a board that
   * is no longer the one it was armed for, and writes THAT into the note it
   * now points at - dropping the edit the user made and, worse, putting one
   * board's contents into another board's note. So the debounce is settled
   * here, deliberately, before anything is swapped:
   *
   *   the caret is committed, because a box being typed into holds text the
   *   board does not have yet;
   *   an empty fresh box is dropped, because it must never reach a note;
   *   a save ALREADY OUT is waited for, because the debounce may have fired a
   *   moment before the tap;
   *   a dirty board is FLUSHED and waited for;
   *   and a save that came back refused keeps the board open, because the
   *   alternative is throwing the user's work away to satisfy a navigation.
   *
   * The wait on a save already in flight is the whole of what makes the last
   * of those true. `dirty` is cleared when the save STARTS, so a leave that
   * only looked at `dirty` took the fast path straight past a live save; the
   * session was swapped before the answer landed, save()'s own guard then
   * declined to touch the new board, and the refusal - a conflict banner, a
   * transient failure that would have retried - was thrown away in silence
   * along with the edit that provoked it.
   *
   * A board that is only `soft` - the opening fit, a title stamp - is left
   * unsaved on purpose. That is the whole of what soft means.
   */
  function leaveBoard() {
    if (S.editing) commitEdit();
    if (S.fresh) dropFresh();
    /*
     * The timer is not cleared here, and that is deliberate rather than an
     * omission: flush() clears it on the one path where it can be armed - a
     * dirty board - and closeBoard clears it on the way out for every other.
     * A third clear in the middle looked like the safety net and was
     * unfalsifiable: nothing could be written that would notice it missing.
     */
    var mine = S.session;
    var out = S.inflight;
    if (out) return out.then(settled, function () { return settled(null); });
    return settled();

    function settled(r) {
      // Something else already moved the board on. Nothing here is about the
      // board that is open now.
      if (S.session !== mine) return confirmLeave();
      // A save this leave waited on that came back NO leaves the edit
      // unwritten, and puts the way out of it - Keep mine, Open theirs, a
      // retry - in the banner that closing the board would wipe.
      if (r && r.ok === false) return refused();
      if (!S.session || !S.dirty || S.readOnly) return confirmLeave();
      return A.ops.flush().then(function (fr) {
        if (fr && fr.ok) return confirmLeave();
        if (fr && fr.ok === false) return refused();
        if (!S.dirty) return confirmLeave();
        return refused();
      });
    }

    function refused() {
      return { ok: false, why: S.lastSaveError || 'the board could not be saved' };
    }
  }

  /*
   * The one case where leaving is a question rather than a wait: the board
   * recorded a note write it could not save. The notes really were changed,
   * this board is the only account of it, and closing it loses that account -
   * so it is said, and the user decides.
   */
  function confirmLeave() {
    if (!S.stranded) return Promise.resolve({ ok: true });
    return new Promise(function (res) {
      ask('This board is holding a note change it could not save. Leaving it now loses the board\'s side of that; the notes themselves stay as they are.',
        'Leave it anyway', function () { res({ ok: true }); }, [], function () { res({ ok: false, why: 'stayed' }); });
    });
  }

  /*
   * The switching guard, released in ONE place per path and released even when
   * something threw on the way.
   *
   * leaveBoard runs commitEdit() and dropFresh() SYNCHRONOUSLY before it
   * returns a promise, so a throw in either escapes past a `.then(ok, err)`
   * pair entirely - and the flag is then stuck true for the life of the
   * session, with open, goHome and newBoard all silently answering false. It
   * is the same shape M5's merge guard was fixed into, and it is fixed the
   * same way: the call goes inside a promise executor, and the release is a
   * wrapper rather than a line repeated on every branch.
   */
  function switching(fn) {
    S.switching = true;
    var done = false;
    function release(v) { if (!done) { done = true; S.switching = false; } return v; }
    function rethrow(e) { release(); throw e; }
    return new Promise(function (res) { res(fn(release)); }).then(release, rethrow);
  }

  A.ops.goHome = function () {
    if (S.embed) return Promise.resolve(false);
    if (S.switching) return Promise.resolve(false);
    return switching(function (release) {
      return leaveBoard().then(function (r) {
        release();
        if (!r.ok) {
          if (r.why !== 'stayed') toast('This board could not be saved (' + r.why + '), so it is still open.');
          return false;
        }
        closeBoard();
        S.mode = 'home';
        S.booted = true;
        el.title.textContent = tr('Big Bang');
        applyMode();
        drawBars();
        return loadHome().then(function () { return true; });
      });
    }).catch(function (e) {
      toast('This board could not be closed (' + String((e && e.message) || e) + ').');
      return false;
    });
  };

  /*
   * Everything a board leaves behind. It is a long list because a board is a
   * long state, and every one of these outliving it is a bug somebody would
   * have to find: a selection naming another board's cards, a banner about a
   * conflict in a note nobody is looking at, an undo stack that would write
   * one board's cards into another board's note.
   */
  function closeBoard() {
    endEdit();
    S.fresh = null;
    clearSel();
    S.drag = null;
    S.link = null;
    S.session = null;
    S.note = null;
    S.dirty = false;
    S.soft = false;
    S.saving = false;
    // Whatever is still out belongs to the board that is leaving; save()'s own
    // session guard declines it when it lands, and nothing here is waiting for
    // it any more. Holding the promise would only make the NEXT leave wait on
    // a board nobody is looking at.
    S.inflight = null;
    S.saves = 0;
    S.stranded = false;
    S.readOnly = false;
    S.why = '';
    S.lastSaveError = '';
    S.tombstones = 0;
    S.noTags = false;
    S.resolveError = '';
    S.merging = false;
    S.writing = false;
    // A preview belongs to the board it was asked about. Carrying it to
    // another one would draw lines between ids that mean something else there.
    S.proposals = null;
    S.suggesting = false;
    S.exporting = false;
    // Nothing still in flight is about this board any more.
    S.gen++;
    if (S.saveTimer) { clearTimeout(S.saveTimer); S.saveTimer = null; }
    A.ops.endSearch(true);
    S.focus = null;
    S.lit = null;
    S.store.reset(BOARD.empty());
    banner(null);
    S.r.clearGhosts();
    S.r.clearRubber();
    sync();
  }

  /* --------------------------------------------------------- the home list */

  /*
   * Recent boards, which is to say: every note holding a board block, most
   * recently changed first. A board is a note, so there is nothing else to
   * look in - and nothing here offers to delete one, because deleting a board
   * would be deleting somebody's note.
   *
   * Show more APPENDS A PAGE; it does not re-ask for a bigger list.
   *
   * runQuery stops at 100 rows, and findBoards asks for one more row than it
   * shows so that `more` is honest without a second query - which caps a
   * single read at 99 boards however big the limit it is handed. A Show more
   * that only grew the limit therefore climbed 24, 48, 72, 96, 99, 99, 99…
   * and went on offering a button that could not reach the hundredth board.
   * findBoards takes an `offset`, so the page after the last row is the thing
   * to ask for, and the answer is added to what is already on screen.
   */
  function loadHome(opts) {
    opts = opts || {};
    var had = (S.home && S.home.boards) || [];
    // Appending only means anything when there is something to append to.
    var append = !!opts.append && had.length > 0;
    var boards = append ? had : [];
    S.home = {
      loading: true, boards: boards, error: '',
      more: append ? !!(S.home && S.home.more) : false,
      counts: append ? !!(S.home && S.home.counts) : true
    };
    drawHome();
    return HOST.findBoards({ limit: HOST.BOARDS, offset: boards.length }).then(function (r) {
      if (S.mode !== 'home') return false;
      S.home.loading = false;
      if (!r.ok) {
        // An append that failed keeps the boards it already had: they are
        // still on screen, still openable, and losing them to a failed read
        // of the NEXT page would be the read punishing the list for growing.
        S.home.error = r.error || 'the boards could not be listed';
      } else {
        // A board saved by another session between two pages shifts the
        // window, so the same row can arrive twice. One card per board.
        var seen = Object.create(null);
        S.home.boards = boards.concat(r.boards).filter(function (b) {
          if (BOARD.has(seen, b.id)) return false;
          seen[b.id] = 1;
          return true;
        });
        S.home.more = r.more;
        S.home.counts = r.counts;
      }
      drawHome();
      return r.ok;
    }, function (e) {
      if (S.mode !== 'home') return false;
      S.home.loading = false;
      S.home.error = String((e && e.message) || e);
      drawHome();
      return false;
    });
  }
  A.ops.loadHome = loadHome;

  var ICON = {
    board: '<svg viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M9 10v10"/></svg>',
    plus: '<svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>',
    note: '<svg viewBox="0 0 24 24"><path d="M6 3h8l5 5v13a1 1 0 01-1 1H6a1 1 0 01-1-1V4a1 1 0 011-1z"/><path d="M14 3v6h5"/></svg>',
    more: '<svg viewBox="0 0 24 24"><path d="M6 9l6 6 6-6"/></svg>'
  };

  /*
   * A row. The icon is a constant string of markup; everything from a NOTE -
   * a board's title, its date, its count - goes in with textContent, exactly
   * as it does on a card.
   */
  function homeRow(icon, title, sub, fn, cls) {
    var b = document.createElement('button');
    b.className = 'home-row' + (cls ? ' ' + cls : '');
    b.innerHTML = icon + '<span class="hr-text"><span class="hr-title"></span><span class="hr-sub"></span></span>';
    b.querySelector('.hr-title').textContent = title;
    var s = b.querySelector('.hr-sub');
    if (sub) s.textContent = sub; else s.hidden = true;
    b.addEventListener('click', fn);
    return b;
  }

  function homeHead(text) {
    var h = document.createElement('div');
    h.className = 'home-head';
    h.textContent = text;
    return h;
  }

  /*
   * How long ago, in the roughest unit that is still true. A date the host
   * wrote in a format nothing can parse simply says nothing, rather than
   * printing NaN at the user.
   *
   * Two shapes arrive, and the number is the one that matters: on a device
   * `notes.updatedAt` is an INTEGER of milliseconds since the epoch, which
   * Date.parse cannot read at all ('1757145600000' is not a date), while the
   * browser mock hands over an ISO string.
   */
  function ago(when, now) {
    var t = typeof when === 'number' && isFinite(when)
      ? when
      : Date.parse(String(when == null ? '' : when));
    if (!isFinite(t)) return '';
    var ms = (now || Date.now()) - t;
    if (ms < 0) ms = 0;
    var mins = Math.floor(ms / 60000);
    if (mins < 1) return tr('just now');
    if (mins < 60) return tr(mins + (mins === 1 ? ' minute ago' : ' minutes ago'));
    var hours = Math.floor(mins / 60);
    if (hours < 24) return tr(hours + (hours === 1 ? ' hour ago' : ' hours ago'));
    var days = Math.floor(hours / 24);
    if (days < 7) return tr(days + (days === 1 ? ' day ago' : ' days ago'));
    if (days < 30) { var w = Math.floor(days / 7); return tr(w + (w === 1 ? ' week ago' : ' weeks ago')); }
    if (days < 365) { var mo = Math.floor(days / 30); return tr(mo + (mo === 1 ? ' month ago' : ' months ago')); }
    var y = Math.floor(days / 365);
    return tr(y + (y === 1 ? ' year ago' : ' years ago'));
  }
  A.ago = ago;

  // What a row says under its title: when it was last changed, and how much is
  // on it. A count the query could not work out is left out rather than shown
  // as zero - "0 cards" about a board with eight of them is worse than silence.
  function boardSub(b) {
    var parts = [];
    var when = ago(b.updatedAt);
    if (when) parts.push(when);
    if (typeof b.cards === 'number') parts.push(tr(b.cards + (b.cards === 1 ? ' card' : ' cards')));
    return parts.join(' · ');
  }
  A.boardSub = boardSub;

  // The list, and then the bar under it: the bar says how many boards are
  // showing, so the two are drawn together and cannot disagree.
  function drawHome() {
    paintHome();
    drawBars();
  }

  function paintHome() {
    var e = el.home;
    if (!e) return;
    e.textContent = '';

    e.appendChild(homeRow(ICON.plus, tr('New board'), tr('An empty canvas, in a note of its own'),
      function () { A.ops.newBoard(); }, 'cta'));
    e.appendChild(homeRow(ICON.note, tr('Open another note as a board'),
      tr('Its text is never touched'), function () { A.ops.openPicked(); }));

    e.appendChild(homeHead(tr(S.home && S.home.loading ? 'Recent boards — looking…' : 'Recent boards')));

    var boards = (S.home && S.home.boards) || [];
    var failed = !!(S.home && S.home.error);

    // The boards go in first, whatever else happened: a page that could not
    // be read is a reason to say so UNDER the list, not to take the list away.
    boards.forEach(function (b) {
      e.appendChild(homeRow(ICON.board, b.title || '(untitled)', boardSub(b), function () {
        A.ops.open(b.id, b.title);
      }));
    });

    if (failed) {
      var bad = document.createElement('div');
      bad.className = 'home-empty bad';
      bad.textContent = tr(boards.length
        ? 'The next page of boards could not be read (' + S.home.error + ').'
        : 'The boards could not be listed (' + S.home.error + ').');
      e.appendChild(bad);
      e.appendChild(homeRow(ICON.more, tr('Try again'), null, function () {
        loadHome({ append: boards.length > 0 });
      }));
      return;
    }

    if (!boards.length) {
      if (S.home && S.home.loading) return;
      var none = document.createElement('div');
      none.className = 'home-empty';
      none.textContent = tr('No boards yet. Make one above, or open any note as a board - a board IS a note, and every note can be one.');
      e.appendChild(none);
      return;
    }

    if (S.home && S.home.more) {
      e.appendChild(homeRow(ICON.more, tr('Show more boards'), null, function () {
        loadHome({ append: true });
      }));
    }
  }
  A.drawHome = drawHome;

  // Open a board from the home. It is a board switch like any other, so it
  // goes out through leaveBoard even though the home holds no board: that is
  // what makes "home, then a different board" one path rather than two.
  //
  // An embed does not navigate. It is one board inside one note, and taking it
  // somewhere else would leave a stranger's board rendered in the middle of
  // somebody's writing.
  A.ops.open = function (noteId, title) {
    if (S.embed) return Promise.resolve(false);
    if (S.switching) return Promise.resolve(false);
    return switching(function (release) {
      return leaveBoard().then(function (r) {
        if (!r.ok) {
          release();
          if (r.why !== 'stayed') toast('This board could not be saved (' + r.why + '), so it is still open.');
          return false;
        }
        closeBoard();
        return openBoard(noteId, { title: title });
      });
    });
  };

  /* -------------------------------------------------------- a new board */

  /*
   * What a board made out of several notes is called: after them, as the plan
   * says. Three names and then a count, because a title is a label and not a
   * list, and the whole thing is capped like any other title.
   */
  A.BOARD_NAMES = 3;
  function boardTitleFor(titles) {
    var names = (titles || []).map(function (t) {
      return String(t == null ? '' : t).replace(/\s+/g, ' ').trim();
    }).filter(Boolean);
    if (!names.length) return tr('Big Bang board');
    var head = names.slice(0, A.BOARD_NAMES);
    var rest = names.length - head.length;
    var text;
    if (rest > 0) text = head.join(', ') + ' and ' + rest + ' more';
    else if (head.length === 1) text = head[0];
    else text = head.slice(0, -1).join(', ') + ' and ' + head[head.length - 1];
    return titleFor(text);
  }
  A.boardTitleFor = boardTitleFor;

  // Where a set of new cards goes: a grid, near enough square to fit on a
  // screen and wide enough that no card lands on another.
  A.GRID = { dx: 300, dy: 250, cols: 4 };
  function gridSpots(n, at) {
    var cols = Math.max(1, Math.min(A.GRID.cols, Math.ceil(Math.sqrt(n))));
    var rows = Math.ceil(n / cols);
    var x0 = at[0] - ((cols - 1) * A.GRID.dx) / 2;
    var y0 = at[1] - ((rows - 1) * A.GRID.dy) / 2;
    var out = [];
    for (var i = 0; i < n; i++) {
      out.push([Math.round(x0 + (i % cols) * A.GRID.dx), Math.round(y0 + Math.floor(i / cols) * A.GRID.dy)]);
    }
    return out;
  }

  function boardOf(notes, at) {
    var b = BOARD.empty();
    var spots = gridSpots(notes.length, at || [0, 0]);
    notes.forEach(function (n, i) {
      M.addItem(b, { k: 'note', id: n.id, p: spots[i], t: n.title || '' });
    });
    return b;
  }
  A.boardOf = boardOf;

  /*
   * A launch on several notes: one new note, holding a board that holds them
   * all. Creating it is the ACTION the user asked for - they chose the notes
   * and chose this app - so it is done rather than asked about, and then said
   * out loud, because a new note in the library is not a thing to discover
   * later.
   */
  function newBoardFor(notes) {
    var title = boardTitleFor(notes.map(function (n) { return n.title; }));
    var body = BOARD.splice('# ' + title + '\n', boardOf(notes, [0, 0]));
    S.mode = 'board';
    applyMode();
    el.title.textContent = title;
    return HOST.createNote(title, body).then(function (r) {
      if (!r.ok) {
        S.booted = true;
        setReadOnly('A board for those ' + notes.length + ' notes could not be created (' + saidNo(r) + ').');
        drawBars();
        return false;
      }
      return openBoard(r.id, { title: title }).then(function (out) {
        banner('A new note, ' + q(title) + ', now holds this board and its ' + notes.length + ' cards.', 'warn');
        return out;
      });
    }, function (e) {
      S.booted = true;
      setReadOnly('A board for those notes could not be created (' + String((e && e.message) || e) + ').');
      drawBars();
      return false;
    });
  }

  A.NEW_BOARD = 'Big Bang board';

  /*
   * New board, from the home. An empty board is not written down at all - a
   * board block is only worth having once there is something on it - so what
   * this creates is an ordinary note, and it becomes a board the moment a card
   * lands on it. Which is also why it does not appear in the recents list yet,
   * and why that is said rather than left to be noticed.
   */
  A.ops.newBoard = function () {
    // An embed CREATES A NOTE here - saveNotes, which has no approval dialog
    // of its own - and then navigates to it. It is not reachable from an
    // embed's chrome today, because an embed draws none; that is a reason to
    // state the refusal rather than to leave the only thing standing between a
    // read-only view and a new row in the library to CSS.
    if (S.embed) return Promise.resolve(false);
    if (S.picking || S.switching) return Promise.resolve(false);
    return switching(function (release) {
      return HOST.createNote(A.NEW_BOARD, '# ' + A.NEW_BOARD + '\n').then(function (r) {
        release();
        if (!r.ok) { toast('A new board could not be created (' + saidNo(r) + ').'); return false; }
        return openBoard(r.id, { title: A.NEW_BOARD }).then(function (out) {
          banner('A new note, ' + q(A.NEW_BOARD) + ', is holding this board. It joins the list of boards once something is on it.', 'warn');
          return out;
        });
      });
    }).catch(function (e) {
      toast('A new board could not be created (' + String((e && e.message) || e) + ').');
      return false;
    });
  };

  /* ------------------------------------------------------- the note picker */

  /*
   * The native multi-note picker, which is how notes arrive on a board. It
   * hands back references - ids and titles - so nothing anybody's note SAYS
   * passes through here.
   */
  function pick(options) {
    if (S.picking) { toast('The note picker is already open.'); return Promise.resolve(null); }
    S.picking = true;
    return HOST.pickNotes(options || {}).then(function (r) {
      S.picking = false;
      if (!r.ok) {
        toast(r.reason === 'no_ui'
          ? 'There is no screen here to show the note picker on.'
          : 'The note picker could not be opened (' + (r.error || 'it was declined') + ').');
        return null;
      }
      if (r.cancelled) return null;
      return r.notes;
    }, function (e) {
      S.picking = false;
      toast('The note picker could not be opened (' + String((e && e.message) || e) + ').');
      return null;
    });
  }

  // Open a note as a board, chosen from the picker. Nothing is written: the
  // note becomes a board by being opened as one, and stays exactly as it is
  // until something is put on it. An embed does not go anywhere, for the same
  // reason A.ops.open does not.
  A.ops.openPicked = function () {
    if (S.embed) return Promise.resolve(false);
    return pick({ multiSelect: false, title: 'Open a note as a board' }).then(function (notes) {
      if (!notes || !notes.length) return false;
      return A.ops.open(notes[0].id, notes[0].title);
    });
  };

  /*
   * Add notes to the board that is open. The chosen notes land as cards at
   * `at` - the middle of what the user is looking at when the bar's + is what
   * asked - in ONE transaction, so undo puts all of them back together.
   *
   * A note already on the board is not added twice. Two cards for one note
   * merge against themselves, read as two different notes at a glance, and are
   * the exact shape M5 spent its milestone getting rid of.
   *
   * The picker is a screen the user drives, and on the way back the board may
   * not be the board that asked - Home, then another board, while it is up.
   * `editable()` does not see that: the new board is perfectly editable, and
   * the cards chosen for one board would land on it and be written into its
   * note. So the SESSION is what the answer is checked against, exactly as a
   * save's answer is.
   */
  A.ops.addNotes = function (at) {
    if (!editable()) return Promise.resolve(false);
    /*
     * Which board asked, and `S.session` rather than `S.gen` on purpose - see
     * the long note on A.ops.merge. The picker is host-modal, and what comes
     * back is a list of NOTE ids that becomes brand new cards with brand new
     * board ids: adopting another session's board across this await changes
     * where the cards land, not what they are, so refusing them would be
     * refusing the user's own choice for no gain.
     */
    var mine = S.session;
    var spot = at && isFinite(at[0]) && isFinite(at[1]) ? [at[0], at[1]] : centreOfView();
    return pick({ multiSelect: true, title: 'Add notes to this board' }).then(function (notes) {
      if (!notes || !notes.length) return false;
      if (S.session !== mine) {
        toast('Those notes were not added: this is no longer the board that asked for them.');
        return false;
      }
      if (!editable()) return false;
      var board = S.store.board;
      var already = [], fresh = [], seen = Object.create(null);
      notes.forEach(function (n) {
        if (BOARD.has(seen, n.id)) return;
        seen[n.id] = 1;
        if (M.cardsForNote(board, n.id).length) already.push(n);
        else fresh.push(n);
      });
      if (!fresh.length) {
        toast(already.length === 1
          ? q(already[0].title || already[0].id) + ' is already on this board.'
          : 'All ' + already.length + ' of those are already on this board.');
        return false;
      }
      var spots = gridSpots(fresh.length, spot);
      var added = [];
      S.store.mutate('add ' + fresh.length + ' card' + (fresh.length === 1 ? '' : 's'), function (b) {
        fresh.forEach(function (n, i) {
          var id = M.addItem(b, { k: 'note', id: n.id, p: spots[i], t: n.title || '' });
          if (id) added.push(id);
        });
      });
      if (!added.length) { toast('Those notes could not be put on the board.'); return false; }
      clearSel();
      added.forEach(function (id) { S.sel[id] = true; });
      if (added.length > 1) S.selectMode = true;
      markDirty('edit');
      redraw();
      toast(added.length + (added.length === 1 ? ' note is' : ' notes are') + ' on the board' +
        (already.length ? ', and ' + already.length + ' already ' + (already.length === 1 ? 'was' : 'were') + '.' : '.'));
      return resolveNotes().then(function () { return true; });
    });
  };

  // The middle of what is on screen, in board units. Where a new card goes
  // when nothing more specific said where.
  function centreOfView() {
    var r = el.stage.getBoundingClientRect();
    var mid = toBoard(r.left + r.width / 2, r.top + r.height / 2);
    return [Math.round(mid.x), Math.round(mid.y)];
  }
  A.centreOfView = centreOfView;

  /* ==================================================================== */
  /* search and focus                                                      */
  /* ==================================================================== */

  /*
   * Both are ways of LOOKING at a board, and neither is part of it.
   *
   * Nothing here marks the board dirty, nothing here schedules a save, and
   * nothing here goes on the undo stack - a board that rewrote its note
   * because somebody typed in the search box would climb the recents list for
   * having been read. The one thing that does touch the board is the camera
   * focus moves, and that is marked SOFT for exactly the same reason the
   * opening fit is: the app moved the camera, not the user.
   *
   * They are also mutually exclusive. Searching inside a focus and focusing
   * inside a search are two dimming rules over one board, and the honest
   * answer to "which is dimmed" would be neither.
   */
  function faceOf(id) { return N.face(S.store.board, id, S.cache); }

  function relight() {
    if (S.searching && S.query) {
      S.found = M.search(S.store.board, S.query, faceOf);
      S.lit = S.found.lit;
    } else if (S.focus) {
      var n = M.neighbourhood(S.store.board, S.focus);
      if (!n.ok) { S.focus = null; S.lit = null; return; }
      S.lit = n.lit;
    } else {
      S.found = null;
      S.lit = null;
    }
  }
  A.relight = relight;

  A.ops.toggleSearch = function () {
    if (S.mode !== 'board') return false;
    if (S.searching) return A.ops.endSearch();
    if (S.editing) commitEdit();
    S.searching = true;
    S.focus = null;
    applyMode();
    if (el.q) { el.q.value = S.query || ''; try { el.q.focus(); } catch (e) { /* no focus here */ } }
    A.ops.search(S.query || '');
    return true;
  };

  A.ops.search = function (text) {
    S.query = String(text == null ? '' : text);
    S.searching = true;
    S.focus = null;
    applyMode();
    if (el.q && el.q.value !== S.query) el.q.value = S.query;
    relight();
    if (el.qcount) {
      el.qcount.textContent = !S.query ? ''
        : tr(S.found && S.found.count ? S.found.count + ' of ' + countable() : 'nothing');
    }
    redraw();
    return S.found;
  };

  // How many things a search could have matched, for the "3 of 12" the box
  // shows: items, links and groups, which is exactly what M.search looks at.
  function countable() {
    var b = S.store.board;
    return Object.keys(b.items).length + b.links.length + b.groups.length;
  }

  A.ops.endSearch = function (quiet) {
    var was = S.searching || S.query;
    S.searching = false;
    S.query = '';
    S.found = null;
    if (el.q) el.q.value = '';
    if (el.qcount) el.qcount.textContent = '';
    applyMode();
    if (quiet) { S.lit = S.focus ? S.lit : null; return !!was; }
    relight();
    redraw();
    return !!was;
  };

  /*
   * Focus: this card's neighbourhood brought into view, and everything not
   * connected to it dimmed. The camera move is a fit over the neighbourhood -
   * marked soft, like every camera the app moves on the user's behalf.
   */
  A.ops.focus = function (id) {
    var n = M.neighbourhood(S.store.board, id);
    if (!n.ok) { toast('That card is no longer on the board.'); return false; }
    if (S.searching) A.ops.endSearch(true);
    S.focus = id;
    S.lit = n.lit;
    fitTo(Object.keys(n.lit));
    redraw();
    toast(n.count
      ? 'Focused. ' + n.count + (n.count === 1 ? ' thing is' : ' things are') + ' connected to this card; the rest is dimmed.'
      : 'Focused. Nothing is connected to this card yet, so everything else is dimmed.');
    return true;
  };

  A.ops.unfocus = function () {
    if (!S.focus) return false;
    S.focus = null;
    relight();
    redraw();
    return true;
  };

  /*
   * Whether anything is dimmed right now, for the bar: search and focus are
   * two ways into one state, and the way OUT of it should be one button.
   */
  function dimming() { return !!S.lit; }

  /* ==================================================================== */

  /*
   * Whether this board may be written at all. Every one of these is a refusal
   * host.js would make anyway; making it a state up front means the user is
   * told once, at the top, instead of after each silent save failure.
   *
   * `shadowed` is the odd one out: a board fence inside a wider fence is
   * documentation, and a note that HAS a real board alongside one is perfectly
   * safe to save (splice leaves the example byte for byte). It only becomes a
   * refusal when there is no real block at all, because then the thing that
   * looks like this note's board is not the block we would write, and appending
   * a second one beside it is how a note ends up with two.
   */
  function judge(r) {
    // What the scan found came back with the load. Re-scanning here would be a
    // second full pass over note.content, one of the columns the project flags
    // as potentially huge, to learn something already in hand.
    if (r.status === 'future') return setReadOnly('This board was written by a newer version of Big Bang, so it opens read-only rather than being half-read and overwritten.');
    if (r.status === 'malformed') {
      return setReadOnly('The block in this note is damaged (' + r.reason + '). The board opens empty and read-only; replacing the damaged block takes an explicit yes.',
        offerForce('malformed', 'Replace the damaged block'));
    }
    if (r.extra) {
      return setReadOnly('This note holds ' + (r.extra + 1) + ' board blocks. Only the first was read, and saving would remove the ' + (r.extra === 1 ? 'other' : 'others') + '.',
        offerForce('extra', 'Keep only the first block'));
    }
    if (!r.span && r.openAtEnd) return setReadOnly('This note ends inside an unclosed code fence, so a board block added here would be part of it and invisible next time.');
    if (!r.span && r.shadowed) return setReadOnly('This note documents the board format inside another code fence. It has no board of its own, and adding one beside the example would be confusing rather than helpful.');
    if (r.dropped) {
      banner(r.dropped + ' entr' + (r.dropped === 1 ? 'y' : 'ies') + ' in this block could not be read and were left out.', 'warn');
    }
    return false;
  }

  function setReadOnly(why, actions) {
    S.readOnly = true;
    S.why = why;
    banner(why, 'warn', actions);
    return true;
  }

  function banner(text, tone, actions) {
    // A toast is standing in front of the banner; a real banner replaces both,
    // or the toast's timer would put the old one back over the top of it.
    if (S.toastT) { clearTimeout(S.toastT); S.toastT = null; S.hold = null; }
    // Any question that was standing here has been answered or overtaken, and
    // either way it is no longer the thing to put back. ask() raises this pair
    // again straight after calling in.
    S.asking = false;
    S.asked = null;
    S.banner = text ? { text: text, tone: tone || '', actions: actions || [] } : null;
    drawBanner();
  }

  /*
   * The escape hatch for a refusal, offered as the plan describes it: a second,
   * explicit yes. The first button says what would happen; it does not do it.
   * The confirmation that replaces it is the yes, and the force it sends names
   * this reason and no other - a note that turns out to be damaged AND to hold
   * a second board asks twice, because they are two different losses.
   */
  function offerForce(reason, label) {
    var what = {
      malformed: 'Replace the damaged block with this board? The prose around it is left exactly as it is.',
      extra: 'Keep only the first board block? The other blocks in this note are removed.',
      conflict: 'Write your board over the other session\'s? Theirs is not kept.'
    }[reason] || 'Write this board anyway?';
    return [{
      label: label,
      fn: function () {
        banner(what, 'bad', [
          { label: 'Yes, do it', fn: function () { forceSave(reason); } },
          { label: 'Cancel', fn: function () { banner(S.why, 'warn', offerForce(reason, label)); } }
        ]);
      }
    }];
  }

  function isDefaultView(v) {
    return v && v.p[0] === 0 && v.p[1] === 0 && v.z === 1;
  }

  /* ==================================================================== */
  /* the camera                                                            */
  /* ==================================================================== */

  /*
   * The view a block asks for, clamped to the range a finger can reach.
   *
   * board.js accepts any zoom from 0.1 to 10 - it is guarding the FORMAT, and a
   * board written by something else is entitled to its own numbers. The gesture
   * layer's range is narrower, and a board that opened at 0.1 could be zoomed
   * but never zoomed back out to where it started, with every affordance pinned
   * at the counter-scale cap. What cannot be reached by pinching is not offered
   * on opening either.
   */
  function applyView(v) {
    S.tx = v.p[0]; S.ty = v.p[1];
    var z = GEST.zoom(v.z);
    S.k = z === null ? 1 : z;
  }

  /*
   * Push the camera at the renderer, and - unless the gesture is still in
   * flight - into the board, so reopening lands where you left off. That write
   * is deliberately NOT a transaction: where you are standing is not an edit,
   * and an undo stack full of pans would bury the thing you actually want back.
   *
   * `soft` is the camera nobody moved: the fit a board gets for opening without
   * a view of its own. It belongs in the block, but not at the cost of a write.
   */
  function applyCamera(live, soft) {
    var zoomed = S.r.cam.k !== S.k;
    S.r.setCamera(S.tx, S.ty, S.k);
    /*
     * A pan is one transform and nothing else. A ZOOM is not: every stroke
     * width, dash length and arrowhead in the SVG is in board units scaled by
     * 1/zoom, because non-scaling-stroke cannot see a CSS transform on an HTML
     * ancestor (see render.js). Panning therefore costs nothing extra and
     * zooming redraws the lines - which is also why this asks whether the zoom
     * changed rather than redrawing on every camera call.
     */
    if (zoomed) S.r.deco(S.store.board, ctx());
    if (live) return;
    // setView answers whether anything CHANGED, so a gesture that settled back
    // where it started costs nothing - not a save, not the read that precedes
    // one.
    if (!M.setView(S.store.board, [S.tx, S.ty], S.k)) return;
    if (soft) markSoft(); else markDirty('view');
  }

  // Point the camera at a box of board, or at nothing when there is no box.
  // The one piece of camera arithmetic in the app; fit and focus share it so
  // that "brought into view" means the same thing in both.
  function frameBox(b, soft) {
    var r = el.stage.getBoundingClientRect();
    var vw = Math.max(80, r.width), vh = Math.max(80, r.height - BIN_H);
    if (!b) { S.tx = vw / 2; S.ty = vh / 2; S.k = 1; applyCamera(false, soft); return; }
    var bw = Math.max(1, b.x1 - b.x0 + PAD * 2), bh = Math.max(1, b.y1 - b.y0 + PAD * 2);
    var k = GEST.zoom(Math.min(vw / bw, vh / bh, 1.4));
    S.k = k === null ? 1 : k;
    S.tx = (vw - (b.x1 - b.x0) * S.k) / 2 - b.x0 * S.k;
    S.ty = (vh - (b.y1 - b.y0) * S.k) / 2 - b.y0 * S.k;
    applyCamera(false, soft);
  }

  A.ops.fit = function (soft) {
    frameBox(S.r.bounds(S.store.board), soft);
  };

  /*
   * Fit over SOME of the board: the neighbourhood a focus is about. Only ids
   * that are items have a box - a link is between two of them and a group is
   * around them, so both are already inside whatever their members bring - and
   * an empty answer leaves the camera exactly where it is rather than jumping
   * to the middle of an empty plane.
   */
  function fitTo(ids) {
    var board = S.store.board, out = null;
    (ids || []).forEach(function (id) {
      var b = S.r.box(board, id);
      if (!b) return;
      if (!out) { out = { x0: b.x, y0: b.y, x1: b.x + b.w, y1: b.y + b.h }; return; }
      out.x0 = Math.min(out.x0, b.x); out.y0 = Math.min(out.y0, b.y);
      out.x1 = Math.max(out.x1, b.x + b.w); out.y1 = Math.max(out.y1, b.y + b.h);
    });
    if (!out) return false;
    // Soft: the app moved the camera, not the user. Looking at a board is not
    // an edit to it, and a focus that marked the board dirty would rewrite the
    // note - and re-order the home list - for having been read.
    frameBox(out, true);
    return true;
  }
  A.fitTo = fitTo;

  /*
   * Where an item is ON SCREEN, from the app's own numbers.
   *
   * Not getBoundingClientRect(): under headless Chrome with a virtual time
   * budget CSS transitions never advance, so a painted rect can sit frozen at
   * the start of a transition that has already been applied. Position comes
   * from the model (or the drag in flight) and the camera; only the SIZE is
   * read from the element, because a card's height is whatever its text wrapped
   * to and offsetHeight is a laid-out value rather than a painted one.
   */
  A.itemScreenRect = function (id) {
    var it = M.item(S.store.board, id);
    var e = S.r.el(id);
    if (!it || !e) return null;
    // absOf, not it.p: an anchored annotation's `p` is an offset from whatever
    // it points at, and only the renderer knows where that is.
    var p = S.r.absOf(S.store.board, id) || it.p;
    var r = el.stage.getBoundingClientRect();
    var left = r.left + S.tx + p[0] * S.k;
    var top = r.top + S.ty + p[1] * S.k;
    var w = e.offsetWidth * S.k, h = e.offsetHeight * S.k;
    return { left: left, top: top, width: w, height: h, right: left + w, bottom: top + h };
  };

  /*
   * The same question for the things that are not items: a link's label and a
   * group's tab. They are counter-scaled, so their size on screen is their own
   * offset size multiplied by zoom AND by 1/zoom - which is to say, itself.
   * Only the keyboard-follow uses this, and it needs one answer for all three.
   */
  A.editScreenRect = function (id) {
    var b = S.store.board;
    var kind = M.kindOf(b, id);
    if (kind === 'note' || kind === 'sticky' || kind === 'annot') return A.itemScreenRect(id);
    var at = null, e = null;
    if (kind === 'link') {
      var g = S.r.geomOf(b, id);
      if (g) { at = [g.mid[0], g.mid[1]]; e = S.r.label(id); }
    } else if (kind === 'group') {
      var gr = S.r.rectOf(b, id);
      if (gr) { at = [gr.x + 10, gr.y + 6]; e = S.r.handle(id); }
    }
    if (!at || !e) return null;
    var r = el.stage.getBoundingClientRect();
    var w = e.offsetWidth, h = e.offsetHeight;
    var left = r.left + S.tx + at[0] * S.k - (kind === 'link' ? w / 2 : 0);
    var top = r.top + S.ty + at[1] * S.k - (kind === 'link' ? h * RENDER.LABEL_LIFT : 0);
    return { left: left, top: top, width: w, height: h, right: left + w, bottom: top + h };
  };

  // A point on the glass, in board coordinates. The formula is the gesture
  // layer's, applied to this file's camera: there is one inverse of the scene
  // transform and both sides of the app use it.
  function toBoard(cx, cy) {
    return GEST.toBoard(el.stage.getBoundingClientRect(), { tx: S.tx, ty: S.ty, k: S.k }, cx, cy);
  }
  A.toBoard = toBoard;

  /* ==================================================================== */
  /* notes                                                                 */
  /* ==================================================================== */

  /*
   * resolveNotes(force, opening)
   *
   * `opening` is the first resolve of the session, and it is the reason this
   * takes a flag at all. applyTitles counts every card whose `t` does not match
   * the note's title as renamed - which, on a board written by hand, by an
   * older build, or by anything that did not stamp `t`, is EVERY card. Marking
   * that dirty means opening a board rewrites the note it lives on before the
   * user has touched anything. The titles are still refreshed and still written
   * down; they simply wait for a save that has a reason of its own.
   */
  function resolveNotes(force, opening) {
    return N.resolve(S.cache, S.store.board, { force: force }).then(function (res) {
      if (!res.ok) {
        // A read that FAILED tombstones nothing. Cards keep their last known
        // titles and say, once, that the excerpts could not be read.
        S.resolveError = res.error || 'the notes could not be read';
        banner('The notes behind these cards could not be read (' + S.resolveError + '). Nothing was removed.', 'warn', [
          { label: 'Try again', fn: function () { banner(null); resolveNotes(true); } }
        ]);
        redraw();
        return res;
      }
      S.resolveError = '';
      // Tags are decoration; a tag read that did not come back is a board
      // without chips, not a board that failed to open.
      S.noTags = res.tags === false;
      var renamed = N.applyTitles(S.store.board, S.cache);
      if (renamed) { if (opening) markSoft(); else markDirty('edit'); }
      S.tombstones = N.tombstones(S.store.board, S.cache).length;
      // A note may have died under a card while a preview stands, and this is
      // the only place that finds out. prune() is what decides whether a
      // suggestion is still one.
      if (S.proposals) prune();
      redraw();
      return res;
    });
  }
  A.ops.resolve = resolveNotes;

  /* ==================================================================== */
  /* saving                                                                */
  /* ==================================================================== */

  /*
   * The board as it should go into the note - which is not always the board in
   * memory.
   *
   * A sticky or an annotation created by a long press exists before it has any
   * text, so that it can be drawn and typed into. Nothing about creating it
   * marks the board dirty, but a save already on the debounce from some earlier
   * edit does not know that, and would write the empty box out. Lifting it back
   * out on the way past is the only place that can be fixed without either
   * refusing a legitimate pending save or leaving the box undrawable.
   *
   * ALWAYS a copy, and that is the whole of it. host.js's save re-reads the
   * note before it splices, which is a real bridge call with a real await in
   * the middle of it, and the user goes on using the board across that window:
   * a long press that leaves an empty sticky, a card dragged, text typed. A
   * save handed the LIVE board serialises whatever the board has become by the
   * time the read comes back - including the empty sticky this function exists
   * to keep out, which then sits in the note for ever because nothing is dirty
   * and nothing rewrites it. A snapshot taken here is what the caller asked to
   * write, and it cannot change underneath them.
   */
  function boardToWrite() {
    var copy = M.clone(S.store.board);
    var id = S.fresh;
    if (!id) return copy;
    var it = M.item(copy, id);
    if (!it || (it.t && it.t.length)) return copy;
    M.removeItem(copy, id);
    return copy;
  }
  A.boardToWrite = boardToWrite;

  /*
   * A refusal, said and then got out of the way. It stands in front of whatever
   * the banner was showing - a read-only board's reason, most of the time - and
   * puts it back afterwards, because that reason did not stop being true while
   * the user was told a link needs two cards.
   */
  var TOAST_MS = 3600;
  function toast(text) {
    if (!S.toastT) S.hold = S.banner;
    else clearTimeout(S.toastT);
    S.banner = { text: text, tone: 'warn', actions: [] };
    drawBanner();
    S.toastT = setTimeout(function () {
      S.toastT = null;
      S.banner = S.hold;
      S.hold = null;
      drawBanner();
    }, TOAST_MS);
  }
  A.toast = toast;

  /*
   * Every edit begins here. One answer to "may I", said out loud - except when
   * the banner is ALREADY saying it, which on a read-only board it always is.
   * A toast repeating the refusal would cover the banner for three seconds,
   * and the banner is where the escape hatch lives.
   */
  function editable() {
    if (!S.readOnly) return true;
    // An embed refuses in silence. It is a picture of a board inside a note,
    // with no bars and no banner to put a refusal in - and a toast explaining
    // that an embed cannot be edited, every time a finger brushed it, would be
    // the only thing it ever said.
    if (S.embed) return false;
    if (!S.banner) toast(S.why || 'This board is read-only, so nothing on it can be changed.');
    return false;
  }

  function markDirty(kind) {
    if (S.readOnly || !S.session) return;
    S.dirty = true;
    if (S.saveTimer) clearTimeout(S.saveTimer);
    S.saveTimer = setTimeout(function () { S.saveTimer = null; A.ops.save(); }, kind === 'view' ? VIEW_MS : EDIT_MS);
    drawBadge();
  }

  /*
   * A change to the block that the user did not make: the opening fit, and the
   * first stamp of a title read live off a note. It is already in the board, so
   * the next save carries it; what it must not do is BE that save. Nothing here
   * touches the badge either - "unsaved" is a promise to the user about their
   * own work, and a board nobody has edited has none outstanding.
   */
  function markSoft() {
    if (S.readOnly || !S.session) return;
    S.soft = true;
  }

  /*
   * A board change that RECORDS something the LIBRARY has already done.
   *
   * markDirty is the ordinary edit path, and on a read-only board it returns
   * without a word - right for an edit the user can simply make again, wrong
   * for this. A merge has rewritten notes and cannot be taken back; a promoted
   * sticky is a note that now exists. The only thing still in question is the
   * board's account of it, and the window is real: the merge screen is open
   * for as long as the user is in it, and a debounced save landing on another
   * session's block turns the board read-only underneath them.
   *
   * A board that quietly dropped the account would go on listing both sources
   * for ever - two cards for one note, one of them stale - having just said
   * "Merged into one card". So the change stays in the board either way, and a
   * board that cannot save it says so in the banner, where the escape hatch
   * that WOULD save it (Keep mine, on a conflict) already stands. The board is
   * not forced on the user's behalf: forcing overwrites the other session's
   * board, which is the one thing this app only ever does from a button the
   * user pressed.
   *
   * -> true if the change will be saved.
   */
  function recordChange(news) {
    if (!S.readOnly) { markDirty('edit'); return true; }
    S.stranded = true;
    // Whatever the banner is saying is the reason this cannot be saved, and
    // its actions are the way out of it; both are kept.
    var prev = S.toastT ? S.hold : S.banner;
    if (S.toastT) { clearTimeout(S.toastT); S.toastT = null; S.hold = null; }
    S.asking = false;
    S.asked = null;
    S.banner = {
      text: news + ' The board has been changed to match, but it cannot be saved, because ' +
        lower(S.why || 'this board is read-only.') +
        ' Until that is settled the note still holds the board as it was, and closing it now loses the board\'s side of this.',
      tone: 'bad',
      actions: (prev && prev.actions) || []
    };
    drawBanner();
    drawBadge();
    return false;
  }

  // A sentence used as a clause. Only the first letter, and only when the word
  // is not one that is capitalised in its own right.
  function lower(s) {
    var t = String(s || '');
    return /^[A-Z][a-z]/.test(t) ? t.charAt(0).toLowerCase() + t.slice(1) : t;
  }

  A.ops.save = function () {
    if (S.saveTimer) { clearTimeout(S.saveTimer); S.saveTimer = null; }
    if (!S.dirty || S.readOnly || !S.session) return Promise.resolve(null);
    S.dirty = false;
    S.soft = false;
    S.saving = true;
    drawBadge();
    /*
     * Which board this save is FOR. A save is a real bridge call with a real
     * await in it, and the user can leave for another board across that
     * window; an answer that arrived afterwards would otherwise put one
     * board's conflict banner - and one board's read-only state - onto a
     * different board's note.
     */
    var mine = S.session;
    // host.js serialises saves per session. Nothing here queues a second time.
    var p = HOST.saveBoard(S.session, boardToWrite()).then(function (r) {
      if (S.inflight === p) S.inflight = null;
      if (S.session !== mine) return r;
      S.saving = false;
      if (r.ok) {
        S.saves++;
        S.lastSaveError = '';
        S.stranded = false;
        drawBadge();
        return r;
      }
      onSaveRefused(r);
      return r;
    }).catch(function (e) {
      if (S.inflight === p) S.inflight = null;
      /*
       * Scoped to the board that asked, exactly as the answer above is. A
       * throw belonging to a board the user has already left would otherwise
       * mark the NEW board dirty and hang the old board's error on it: a
       * false "unsaved" badge, and a write on the way out that bumps a note
       * nobody edited to the top of the recents list.
       */
      if (S.session !== mine) return null;
      S.saving = false;
      S.dirty = true;
      S.lastSaveError = String((e && e.message) || e);
      drawBadge();
      return null;
    });
    S.inflight = p;
    return p;
  };

  /*
   * A save that came back no. Two kinds:
   *
   *   Structural - another session's board, a damaged block, a second block.
   *   The board goes read-only and says so; nothing is forced on its behalf.
   *   A conflict names what changed in cards and links and hands the user the
   *   two honest choices.
   *
   *   Transient - the note could not be read or written just now. Stay dirty
   *   and try again; the edit is not lost and nothing was overwritten.
   */
  function onSaveRefused(r) {
    S.lastSaveError = r.error || r.reason;
    if (r.reason === 'conflict') {
      S.readOnly = true;
      S.why = 'Another Big Bang session saved this board while it was open.';
      var what = r.change && r.change.text ? r.change.text : 'different cards';
      banner('Another Big Bang session saved this board while it was open. Theirs has ' + what + ' compared with yours.', 'bad', [
        { label: 'Open theirs', fn: function () { adoptTheirs(r); } },
        // Keeping yours overwrites THEIR block and nothing else. If the note is
        // also damaged, or holds a second board, that refusal comes back on the
        // next attempt and asks its own question.
        { label: 'Keep mine', fn: function () { forceSave('conflict'); } }
      ]);
      drawBadge();
      return;
    }
    // A damaged block and a second board block are both somebody's data, and
    // both have the same escape hatch: say what would be lost, then ask.
    if (r.reason === 'malformed' || r.reason === 'extra') {
      setReadOnly(r.error || 'This board cannot be saved.',
        offerForce(r.reason, r.reason === 'extra' ? 'Keep only the first block' : 'Replace the damaged block'));
      drawBadge();
      return;
    }
    if (r.reason === 'read-only') {
      setReadOnly(r.error || 'This board cannot be saved.');
      drawBadge();
      return;
    }
    S.dirty = true;
    banner('The board could not be saved just now (' + S.lastSaveError + '). It will try again.', 'warn');
    if (S.saveTimer) clearTimeout(S.saveTimer);
    S.saveTimer = setTimeout(function () { S.saveTimer = null; A.ops.save(); }, RETRY_MS);
    drawBadge();
  }

  // Their board, adopted whole. History does not survive it - undoing across
  // somebody else's save would write your board back over theirs.
  function adoptTheirs(r) {
    // Before the reset, not after: their board is about to reuse this board's
    // ids, so the element the caret is in would be handed straight to one of
    // THEIR cards, still contentEditable and still swallowing every tap.
    endEdit();
    S.fresh = null;
    // A merge or a promotion landed while this board could not be saved, and
    // taking theirs is the choice that throws that record away. The notes are
    // merged either way, so it is said rather than assumed to be understood.
    var lost = S.stranded;
    S.stranded = false;
    /*
     * Their board reuses THIS board's ids for entirely different notes, so a
     * suggestion measured against ours is a dashed line between two cards
     * nobody asked about. Dropped outright rather than pruned: `n1` and `n2`
     * are perfectly good ids over there, and the prune would keep it.
     */
    S.proposals = null;
    /*
     * A different board under the same session object, so everything waiting
     * on an answer about OUR board has to be able to see that it is gone -
     * and the flags that say something is out have to be released HERE, since
     * the answer, when it arrives, will correctly decline to touch them.
     */
    S.gen++;
    S.suggesting = false;
    S.exporting = false;
    S.store.reset(r.theirs || BOARD.empty());
    S.session.key = r.key;
    S.readOnly = false;
    clearSel();
    banner(lost
      ? 'Opened the other session\'s board. Your version was not written, and nor was the note write this board had recorded but not saved - the notes themselves are unchanged by this.'
      : 'Opened the other session\'s board. Your version was not written.', 'warn');
    redraw();
    resolveNotes();
  }
  A.ops.adopt = adoptTheirs;

  /*
   * The second, explicit yes. Only ever from a button the user pressed, and the
   * force it sends names the ONE refusal that button described. A force that
   * named none would also silently overwrite a damaged block, a second board
   * and a newer format, none of which the banner mentioned.
   */
  function forceSave(reason) {
    // The one write that does not answer to S.readOnly - it clears it - so it
    // is the one write an embed could still reach. An embed has no banner and
    // therefore no button that leads here; that is not the same as a refusal,
    // and the read-only guarantee is worth more than the button being absent.
    if (S.embed) return Promise.resolve(null);
    var done = {
      conflict: 'Your board was written over the other session\'s.',
      malformed: 'The damaged block was replaced. The prose around it is untouched.',
      extra: 'The other board blocks were removed. This note holds one board.'
    }[reason] || 'The board was written.';
    S.readOnly = false;
    banner(null);
    S.saving = true;
    drawBadge();
    return HOST.saveBoard(S.session, boardToWrite(), { force: reason }).then(function (r) {
      S.saving = false;
      if (r.ok) { S.saves++; S.soft = false; S.why = ''; S.stranded = false; banner(done, 'warn'); }
      else onSaveRefused(r);
      drawBadge();
      return r;
    });
  }
  A.ops.force = forceSave;

  /* ==================================================================== */
  /* edits                                                                 */
  /* ==================================================================== */

  /*
   * A box that has never been written in is not part of history, and must not
   * be photographed INTO it.
   *
   * undoStep and redoStep each snapshot the board AS IT IS onto the opposite
   * stack. A fresh empty sticky caught in that snapshot comes back on redo -
   * and comes back owned by nobody, because prune() cleared S.fresh on the way
   * through, so it is an ordinary empty card from then on and gets written
   * into the note. Two taps reached it: recolour a card, long-press a sticky,
   * Undo, Redo.
   */
  function forgetFresh() {
    if (!S.fresh) return;
    if (S.editing === S.fresh) cancelEdit();
    else dropFresh();
  }

  A.ops.undo = function () {
    if (!S.store.canUndo()) return false;
    forgetFresh();
    S.store.undoStep();
    afterHistory();
    return true;
  };

  A.ops.redo = function () {
    if (!S.store.canRedo()) return false;
    forgetFresh();
    S.store.redoStep();
    afterHistory();
    return true;
  };

  function afterHistory() {
    // A step carries the whole board, view included. Re-assert the camera you
    // are actually looking at rather than teleporting to where the step was
    // recorded from.
    M.setView(S.store.board, [S.tx, S.ty], S.k);
    prune();
    sync();
    markDirty('edit');
    drawBars();
    resolveNotes();
  }

  /*
   * Selection is not part of the board, so it can outlive the things it names:
   * an undo, a removal, another session's board adopted whole. Everything that
   * can be selected is pruned here - items, the open link, the open group -
   * because a bar drawn for a link that is no longer there is a bar whose every
   * button silently does nothing.
   */
  function prune() {
    var b = S.store.board;
    Object.keys(S.sel).forEach(function (id) { if (!M.item(b, id)) delete S.sel[id]; });
    if (S.linkSel && !M.link(b, S.linkSel)) S.linkSel = null;
    if (S.groupSel && !M.group(b, S.groupSel)) S.groupSel = null;
    // endEdit, not a bare null: the element has to stop being contentEditable
    // or nothing taps that card again (see endEdit).
    if (S.editing && !M.any(b, S.editing)) endEdit();
    if (S.fresh && !M.item(b, S.fresh)) S.fresh = null;
    /*
     * A suggestion is about two cards and the gap between them, and both can
     * stop being true underneath it: a card removed, an undo, another
     * session's board adopted, or the very link it proposes drawn by hand.
     * A dashed line between two cards that are already joined is a preview of
     * nothing, and one hanging off a card that has gone is drawn from a box
     * that no longer exists.
     */
    if (S.proposals) {
      var kept = S.proposals.filter(function (p) {
        if (!M.item(b, p.a) || !M.item(b, p.b) || M.findLink(b, p.a, p.b)) return false;
        /*
         * And the way a proposal dies that the BOARD cannot show: the note
         * behind one of its cards deleted while the preview stands. The card
         * stays - as a tombstone - so every test above still passes, but a
         * tombstone was never offered to the model as a candidate (see
         * ai.js), and a relationship suggested between a note and one that is
         * gone is not a relationship. Dropped here rather than at Apply, so
         * the dashed line goes when the tombstone appears rather than
         * silently failing to be drawn later.
         */
        var fa = faceOf(p.a), fb = faceOf(p.b);
        return !(fa && fa.tomb) && !(fb && fb.tomb);
      });
      S.proposals = kept.length ? kept : null;
    }
    if (!selCount() && !S.linkSel && !S.groupSel) { S.selectMode = false; S.barOpen = false; S.barMode = ''; }
  }

  /*
   * Cards leave the board; the notes behind them are never touched. Everything
   * that pointed at one goes with it - its links, its place in a group, the
   * annotations hanging off it - through the model's one removal path, so the
   * whole sweep is a single undo step.
   *
   * A box that has never been written in is not part of that: it was never in
   * a transaction and removing it must not become one.
   */
  A.ops.remove = function (ids) {
    if (!ids || !ids.length) return false;
    if (!editable()) return false;
    if (S.editing && ids.indexOf(S.editing) >= 0) endEdit();
    /*
     * The fresh box comes OUT of the list rather than out of the transaction.
     * Guarding on "and it is the only one" left a multi-selection holding it
     * to go through M.removeItems inside a step, and undoing that step puts an
     * empty sticky back permanently - the one thing the whole fresh mechanism
     * exists to make impossible. Whatever else was selected is removed the
     * ordinary, undoable way.
     */
    if (S.fresh && ids.indexOf(S.fresh) >= 0) {
      var fresh = S.fresh;
      dropFresh();
      ids = ids.filter(function (id) { return id !== fresh; });
      if (!ids.length) { redraw(); return true; }
    }
    S.store.mutate('remove ' + ids.length + ' card' + (ids.length === 1 ? '' : 's'), function (b) {
      M.removeItems(b, ids);
    });
    ids.forEach(function (id) { delete S.sel[id]; });
    prune();
    sync();
    markDirty('edit');
    drawBars();
    return true;
  };

  A.ops.select = function (id, additive) {
    if (!additive) S.sel = Object.create(null);
    if (id) S.sel[id] = true;
    S.barOpen = false;
    S.linkSel = null;
    S.groupSel = null;
    S.barMode = '';
    redraw();
  };

  function clearSel() {
    S.sel = Object.create(null);
    S.selectMode = false;
    S.barOpen = false;
    S.linkSel = null;
    S.groupSel = null;
    S.barMode = '';
  }

  /* ==================================================================== */
  /* structure: links, groups, stickies, annotations                       */
  /* ==================================================================== */

  /*
   * Selecting a link selects BOTH ITS ENDS as well.
   *
   * That is what the handle is for. A link is a relationship between two
   * things, so the thing to look at when you tap it is the pair - and it means
   * the actions that need two cards (group them, annotate them, and in a later
   * milestone merge them) are already right there, with Unlink standing where
   * Link would be.
   */
  A.ops.selectLink = function (id) {
    var l = M.link(S.store.board, id);
    if (!l) return false;
    if (S.linkSel === id) { clearSel(); redraw(); return true; }
    clearSel();
    S.linkSel = id;
    S.sel[l.a] = true;
    S.sel[l.b] = true;
    redraw();
    return true;
  };

  A.ops.selectGroup = function (id) {
    var g = M.group(S.store.board, id);
    if (!g) return false;
    if (S.groupSel === id) { clearSel(); redraw(); return true; }
    clearSel();
    S.groupSel = id;
    redraw();
    return true;
  };

  /*
   * Drawing a link. Every way of asking for one - the port drag, and Link on a
   * selection of exactly two - arrives here, so there is one set of refusals
   * and one place they are worded.
   */
  A.ops.link = function (a, b, opts) {
    if (!editable()) return null;
    if (!a || !b || a === b) {
      toast('A link needs two different cards. Drop it on another one.');
      return null;
    }
    var board = S.store.board;
    if (!M.item(board, a) || !M.item(board, b)) {
      toast('One of those is no longer on the board.');
      return null;
    }
    var already = M.findLink(board, a, b);
    if (already) {
      // Not an error and not a no-op: show them the link they already have.
      // selectLink TOGGLES, so asking for one that is already open would shut
      // it - and the answer to "you already have this" would be a blank bar.
      toast('Those two are already linked.');
      if (S.linkSel !== already.i) A.ops.selectLink(already.i);
      return already;
    }
    var made = S.store.mutate('draw a link', function (bd) { return M.addLink(bd, a, b, opts || {}); });
    if (!made) { toast('That link could not be drawn.'); return null; }
    markDirty('edit');
    A.ops.selectLink(made.i);
    return made;
  };

  /*
   * Removing one.
   *
   * A line with no relationship behind it just goes. A line that a REAL note
   * relationship stands behind asks first, and the default is no: the drawing
   * is board decoration and the note link outlives it. The question is asked
   * rather than assumed because the two outcomes are a world apart - one is a
   * board edit, the other is a write to the user's library - and only the user
   * knows which they meant.
   *
   * opts.answered  the question above has been put and answered.
   * opts.quiet     the caller is saying what happened, so this does not.
   */
  A.ops.unlink = function (id, opts) {
    opts = opts || {};
    if (!editable()) return false;
    var l = M.link(S.store.board, id);
    if (!l) return false;
    var real = l.real === true;

    if (real && !opts.answered) {
      // One of the two answers to this question is a write to `relationships`,
      // so the question itself is only worth putting when a write may begin -
      // and canWrite() is the whole of that test, the merge screen included.
      // A merge screen open behind a "Remove both" is exactly what canWrite
      // exists to stop.
      if (!canWrite()) return false;
      var ends = noteEnds(l);
      var extra = ends ? [{ label: 'Remove both', fn: function () { unlinkBoth(id); } }] : [];
      ask('A note relationship stands behind this line. Removing the line leaves that relationship in your notes.' +
        (ends ? '' : ' (The cards it joined are no longer two notes, so the relationship cannot be removed from here.)'),
        'Remove the line only', function () { A.ops.unlink(id, { answered: true }); }, extra);
      return false;
    }

    var out = S.store.mutate('remove a link', function (b) { return M.removeLink(b, id); });
    if (!out || !out.removed) return false;
    if (S.linkSel === id) clearSel();
    prune();
    redraw();
    markDirty('edit');
    if (real && !opts.quiet) toast('The line is gone. The note link behind it was left alone.');
    return true;
  };

  /*
   * Both, in the order that cannot lie: the relationship first, the line
   * second. Once the write has been ATTEMPTED the line goes either way - the
   * user asked for that much - but what is SAID afterwards depends on whether
   * the write landed, so a relationship that was refused does not leave the
   * user believing it is gone.
   *
   * A write that may not begin at all is different: nothing is attempted and
   * nothing changes, and beginWrite has already said why. Removing the line on
   * the way out of a refusal would be doing half of what the user asked for
   * because the other half was not allowed.
   */
  function unlinkBoth(id) {
    var l = M.link(S.store.board, id);
    if (!l) return false;
    var ends = noteEnds(l);
    if (!ends) return A.ops.unlink(id, { answered: true });
    var t = endTitles(l, ends), at = t.a, bt = t.b;
    if (!beginWrite()) return false;
    return HOST.unlinkNotes(ends.a, ends.b).then(function (r) {
      S.writing = false;
      A.ops.unlink(id, { answered: true, quiet: true });
      toast(r.ok
        ? 'The line is gone, and ' + q(at) + ' and ' + q(bt) + ' are no longer linked in your notes.'
        : 'The line is gone. The relationship could not be removed (' + saidNo(r) + '), so it is still in your notes.');
      return r.ok;
    }, function (e) {
      S.writing = false;
      A.ops.unlink(id, { answered: true, quiet: true });
      toast('The line is gone. The relationship could not be removed (' + String((e && e.message) || e) + ').');
      return false;
    });
  }

  A.ops.group = function (ids, opts) {
    if (!editable()) return null;
    var board = S.store.board;
    var live = (ids || []).filter(function (id) { return !!M.item(board, id); });
    if (live.length < 2) {
      toast('A group needs at least two cards. Select some more.');
      return null;
    }
    var g = S.store.mutate('group ' + live.length + ' cards', function (b) {
      return M.addGroup(b, live, opts || {});
    });
    if (!g) { toast('That group could not be made.'); return null; }
    markDirty('edit');
    clearSel();
    S.groupSel = g.i;
    redraw();
    return g;
  };

  A.ops.ungroup = function (id) {
    if (!editable()) return false;
    if (!M.group(S.store.board, id)) return false;
    var gone = S.store.mutate('ungroup', function (b) { return M.removeGroup(b, id); });
    if (!gone) return false;
    if (S.groupSel === id) clearSel();
    redraw();
    markDirty('edit');
    return true;
  };

  // Put a group's members into an ordinary multi-selection, which is where
  // everything that acts on several cards at once lives.
  A.ops.selectMembers = function (id) {
    var g = M.group(S.store.board, id);
    if (!g) return false;
    clearSel();
    S.selectMode = true;
    g.m.forEach(function (m) { S.sel[m] = true; });
    redraw();
    return true;
  };

  /* ---------------------------------------------------- align a selection */

  /*
   * Four alignments and no more: the two that tidy an edge, and the two that
   * lay a selection out in a line. Everything is measured from where the cards
   * ACTUALLY are - anchors resolved, widths as laid out - and written back in
   * one transaction, so nine cards moved is one undo step.
   */
  A.ALIGN_GAP = { row: 36, column: 28 };

  A.ops.align = function (mode) {
    if (!editable()) return false;
    var board = S.store.board;
    var ids = selIds().filter(function (id) { return !!M.item(board, id); });
    if (ids.length < 2) { toast('Aligning needs at least two cards.'); return false; }
    var boxes = {};
    ids.forEach(function (id) { boxes[id] = S.r.box(board, id); });
    ids = ids.filter(function (id) { return !!boxes[id]; });
    if (ids.length < 2) { toast('Aligning needs at least two cards.'); return false; }

    var x0 = Math.min.apply(null, ids.map(function (id) { return boxes[id].x; }));
    var y0 = Math.min.apply(null, ids.map(function (id) { return boxes[id].y; }));
    var want = Object.create(null);

    if (mode === 'left') ids.forEach(function (id) { want[id] = [x0, boxes[id].y]; });
    else if (mode === 'top') ids.forEach(function (id) { want[id] = [boxes[id].x, y0]; });
    else if (mode === 'row') {
      var x = x0;
      ids.slice().sort(function (a, b) { return boxes[a].x - boxes[b].x; }).forEach(function (id) {
        want[id] = [x, y0];
        x += boxes[id].w + A.ALIGN_GAP.row;
      });
    } else if (mode === 'column') {
      var y = y0;
      ids.slice().sort(function (a, b) { return boxes[a].y - boxes[b].y; }).forEach(function (id) {
        want[id] = [x0, y];
        y += boxes[id].h + A.ALIGN_GAP.column;
      });
    } else return false;

    var moved = S.store.mutate('align ' + ids.length + ' cards', function (b) {
      var n = 0;
      ids.forEach(function (id) { if (placeAt(b, id, want[id])) n++; });
      return n;
    });
    S.barMode = '';
    redraw();
    if (moved) markDirty('edit');
    else toast('Those cards were already aligned.');
    return !!moved;
  };

  /*
   * Put an item at an ABSOLUTE spot.
   *
   * An anchored annotation has no absolute position to write: its `p` is an
   * offset from whatever it points at. Writing the absolute value there would
   * make it leap by its anchor's coordinates the next time it was drawn, so it
   * is converted first - and if the anchor cannot be resolved at all, the
   * annotation is not somewhere this can honestly put it, and it is left alone.
   */
  function placeAt(board, id, abs) {
    var it = M.item(board, id);
    if (!it) return false;
    if (it.k === 'annot' && it.at && it.at.length) {
      var o = S.r.anchorOrigin(board, id);
      if (!o) return false;
      return M.setAnnotOffset(board, id, [abs[0] - o[0], abs[1] - o[1]]);
    }
    return M.moveItem(board, id, abs);
  }

  /* -------------------------------------------------------- style, colour */

  A.ops.colour = function (id, c) {
    if (!editable()) return false;
    var changed = S.store.mutate('recolour', function (b) { return M.setColour(b, id, c); });
    redraw();
    if (changed) markDirty('edit');
    return changed;
  };

  A.ops.linkStyle = function (id, spec) {
    if (!editable()) return false;
    var changed = S.store.mutate('restyle a link', function (b) { return M.setLinkStyle(b, id, spec); });
    redraw();
    if (changed) markDirty('edit');
    return changed;
  };

  /* -------------------------------------------- stickies and annotations */

  /*
   * A box that exists but has never been written in.
   *
   * It goes STRAIGHT into the board rather than through the store: no
   * transaction, no undo step, nothing marked dirty. A tap that turns out to
   * have been a mistake has to leave no trace, and a step on the undo stack
   * for a box that was never filled in is a trace. The step is pushed when the
   * text is committed, by taking the box back out and adding it again inside a
   * transaction - which is the only way to make ONE step out of "it appeared
   * and it says this".
   */
  function freshItem(spec) {
    if (S.editing) commitEdit();
    if (S.fresh) dropFresh();
    var id = M.addItem(S.store.board, spec);
    if (!id) { toast('That could not be placed on the board.'); return null; }
    S.fresh = id;
    clearSel();
    S.sel[id] = true;
    redraw();
    // beginEdit arms the keyboard follow, which is what lifts a box created at
    // the bottom of the screen clear of the keyboard that is about to cover it.
    beginEdit(id);
    return id;
  }

  function dropFresh() {
    var id = S.fresh;
    S.fresh = null;
    if (!id || !M.item(S.store.board, id)) return false;
    // Straight out again, the same way it went in: no transaction, no step.
    M.removeItem(S.store.board, id);
    delete S.sel[id];
    prune();
    return true;
  }

  A.ops.newSticky = function (x, y) {
    if (!editable()) return null;
    var w = RENDER.W.sticky;
    return freshItem({ k: 'sticky', p: [Math.round(x - w / 2), Math.round(y - 24)] });
  };

  /*
   * An annotation. `anchors` is what it points at - any mixture of items and
   * links, or nothing at all, in which case it simply floats.
   *
   * Its `p` is an offset from the FIRST anchor, so it is placed relative to
   * that thing: up and to the right, clear of the card itself. With no anchor
   * there is nothing to be relative to, and it goes in the middle of what the
   * user is looking at.
   */
  A.ops.annotate = function (anchors) {
    if (!editable()) return null;
    anchors = (anchors || []).filter(Boolean);
    var board = S.store.board;
    var p;
    var first = anchors[0];
    var base = first && first.i ? S.r.box(board, first.i) : null;
    if (base) p = [Math.round(base.w / 2 + 30), Math.round(-base.h / 2 - 74)];
    else if (first && first.l && S.r.geomOf(board, first.l)) p = [30, -74];
    else if (anchors.length) p = [30, -74];
    else {
      var r = el.stage.getBoundingClientRect();
      var mid = toBoard(r.left + r.width / 2, r.top + r.height / 2);
      p = [Math.round(mid.x - RENDER.W.annot / 2), Math.round(mid.y - 24)];
    }
    var id = freshItem({ k: 'annot', p: p, at: anchors });
    if (id && anchors.length && !M.item(board, id).at.length) {
      // Every anchor named something that is not on the board. The annotation
      // is still an annotation; it just does not point at anything.
      toast('Nothing it was pointing at is on the board, so it floats free.');
    }
    return id;
  };

  // What the current selection can be annotated: the items, plus the link if
  // one is open. Ordered so the FIRST anchor - the one the offset is measured
  // from - is the thing the user most obviously meant.
  function anchorsForSelection() {
    var out = [];
    if (S.linkSel) out.push({ l: S.linkSel });
    selIds().forEach(function (id) { out.push({ i: id }); });
    return out;
  }

  /*
   * What an annotation points at, changed without moving it.
   *
   * Its `p` is an offset from the first anchor, so pointing it somewhere else
   * changes the meaning of every number in it. The absolute spot is taken
   * first and put back afterwards; the annotation stays exactly where the user
   * left it and only the dotted lines move.
   */
  A.ops.setAnchors = function (id, anchors) {
    if (!editable()) return false;
    var abs = S.r.absOf(S.store.board, id);
    if (!abs) return false;
    var changed = S.store.mutate('re-point an annotation', function (b) {
      if (!M.setAnchors(b, id, anchors)) return false;
      var it = M.item(b, id);
      if (!it.at.length) { delete it.reanchor; return M.moveItem(b, id, abs); }
      var o = S.r.anchorOrigin(b, id);
      if (!o) { it.reanchor = true; return M.moveItem(b, id, abs); }
      return M.setAnnotOffset(b, id, [abs[0] - o[0], abs[1] - o[1]]);
    });
    redraw();
    if (changed) markDirty('edit');
    return changed;
  };

  /* ==================================================================== */
  /* writes to other people's notes                                        */
  /* ==================================================================== */

  /*
   * Everything below leaves the board note and writes to the user's library.
   *
   * Four rules hold for every one of them, and they are the reason these are
   * not simply four more ops beside `colour` and `align`:
   *
   *   It is asked for first, in words, naming the notes. `ask` puts the
   *   question in the banner - the same place a refusal already lives - with
   *   the action, any second reading of it, and Cancel. Nothing here starts
   *   without that yes, because the host's own dialog cannot be relied on to
   *   be the one that stops it: `saveNotes` has no approval gate at all, and
   *   `updateNotes` asks once per session and then stops asking.
   *
   *   One write at a time. `S.writing` is not about the database; it is about
   *   the screen. Two questions about two different notes at once is how the
   *   wrong one gets answered.
   *
   *   The answer is read. `updatedCount`, not `success`, says what landed, and
   *   `errors` says what was refused - an immutable workflow tag, a note that
   *   has since gone. A partial batch says which part.
   *
   *   The board follows the write, never the other way round. The flag that
   *   says a line is backed by a real relationship, the card that replaces a
   *   sticky, the tick on a task: each is written only after the host has said
   *   it did the thing. A board that updated hopefully would be lying about
   *   the library.
   */

  function q(s) { return '“' + String(s == null ? '' : s) + '”'; }

  /*
   * The question, and its answer. It stands in front of whatever the banner
   * was showing and puts it back if the user says no - that reason did not
   * stop being true while they were asked something else.
   */
  /*
   * `onCancel` exists for the one caller that is WAITING on the answer rather
   * than acting on it - leaving a board asks a question whose No has to be
   * heard, or the navigation it belongs to hangs unresolved for ever.
   */
  function ask(text, label, fn, extra, onCancel) {
    /*
     * What Cancel puts back is never ANOTHER QUESTION.
     *
     * A second question replaces the first in the banner - there is one banner
     * - and the first is then unanswered and unseen. Restoring it on cancel
     *  would put a live, armed question back in front of a user who has not
     *  looked at it since they were asked something else, and who has just
     *  said no. What goes back is whatever stood before the FIRST of the
     *  stacked questions, which is usually a read-only reason and is never a
     *  yes waiting to be pressed.
     */
    var prev = S.asking ? S.asked : (S.toastT ? S.hold : S.banner);
    function restore() {
      if (S.toastT) { clearTimeout(S.toastT); S.toastT = null; }
      S.hold = null;
      S.asking = false;
      S.asked = null;
      S.banner = prev;
      drawBanner();
      if (onCancel) onCancel();
    }
    var actions = [{ label: label, fn: function () { banner(null); fn(); } }];
    (extra || []).forEach(function (a) {
      actions.push({ label: a.label, fn: function () { banner(null); a.fn(); } });
    });
    actions.push({ label: 'Cancel', fn: restore });
    // banner() clears the pair below, so the flag is raised after it, not
    // before: this question is now the one standing.
    banner(text, 'warn', actions);
    S.asking = true;
    S.asked = prev;
    return true;
  }
  A.ops.ask = ask;

  /*
   * A note card whose note still resolves: the only kind of card any of this
   * can write to. A tombstone is deliberately excluded - its note is gone, and
   * every one of these actions would be writing to nothing.
   */
  function liveNote(id) {
    var it = M.item(S.store.board, id);
    if (!it || it.k !== 'note') return null;
    var face = N.face(S.store.board, id, S.cache);
    if (!face || face.tomb) return null;
    return { id: id, noteId: it.id, title: face.title || N.UNTITLED, face: face };
  }
  A.liveNote = liveNote;

  // Both ends of a link as NOTE ids, whether or not they resolve. Removing a
  // relationship stays possible when one end has been deleted; writing a new
  // one does not, and refuses separately.
  function noteEnds(l) {
    var a = M.item(S.store.board, l.a), b = M.item(S.store.board, l.b);
    if (!a || !b || a.k !== 'note' || b.k !== 'note') return null;
    if (a.id === b.id) return null;
    return { a: a.id, b: b.id };
  }

  /*
   * Both ends of a link, named as well as they can be. The live note's title
   * first, then whatever the card itself is labelled with, then the note id -
   * which is not a title, but is at least the thing the user can go and find.
   *
   * Two callers had two different halves of this fallback until they were put
   * side by side: the question that asks about removing a relationship, and
   * the answer that removes it along with the line.
   */
  function endTitles(l, ends) {
    var a = M.item(S.store.board, l.a), b = M.item(S.store.board, l.b);
    return {
      a: (liveNote(l.a) || {}).title || (a && a.t) || ends.a,
      b: (liveNote(l.b) || {}).title || (b && b.t) || ends.b
    };
  }

  // A note write may begin. Said out loud when it may not.
  function canWrite() {
    if (!editable()) return false;
    if (S.merging) { toast('The merge screen is open. Finish that first.'); return false; }
    if (S.writing) { toast('One write at a time - the last one is still going.'); return false; }
    return true;
  }

  /*
   * The write itself begins. canWrite() was asked when the QUESTION was put,
   * and the board has been live ever since - the user can drop a card onto
   * another and open the merge screen, start a different write, or have a save
   * refused and go read-only, all while a banner waits for a yes. So the test
   * is put again here, where the write actually starts, and the answer given
   * some time ago is not treated as a licence.
   */
  function beginWrite() {
    if (!canWrite()) return false;
    S.writing = true;
    return true;
  }

  // Whatever the host refused, said in the caller's words.
  function saidNo(r) { return r && r.error ? r.error : 'the write was declined'; }

  // Notes whose text has changed under us: forget what was cached and read
  // them again, so the cards say what the notes now say.
  function refreshNotes(ids) {
    (ids || []).forEach(function (id) { if (id) S.cache.forget(id); });
    return resolveNotes();
  }
  A.ops.refreshNotes = refreshNotes;

  /* ------------------------------------------------- a sticky becomes a note */

  /*
   * A note's title, out of a sticky's text: its first line, and no more of it
   * than a title should be. The whole text is the body, first line included -
   * a note whose title is its opening line still reads properly, and dropping
   * that line would lose it if the title were later changed.
   */
  A.TITLE_MAX = 72;
  function titleFor(text) {
    var first = String(text || '').split('\n')[0].trim();
    if (!first) return 'Untitled';
    if (first.length <= A.TITLE_MAX) return first;
    return first.slice(0, A.TITLE_MAX - 1).replace(/\s+\S*$/, '') + '…';
  }
  A.titleFor = titleFor;

  /*
   * Promote a sticky. One note created, and one undo step that swaps the
   * sticky for a card pointing at it - links, group membership and everything
   * anchored to the sticky come across with it.
   *
   * The undo step covers the BOARD, and says so: undoing puts the sticky back
   * and leaves the note in the library, because nothing here can un-create it.
   */
  A.ops.promote = function (id) {
    id = id || (selCount() === 1 ? selIds()[0] : null);
    if (!id) { toast('Select a sticky first.'); return false; }
    if (!canWrite()) return false;
    var it = M.item(S.store.board, id);
    if (!it) return false;
    if (it.k !== 'sticky') {
      toast(it.k === 'note' ? 'That card is already a note.' : 'Only a sticky becomes a note.');
      return false;
    }
    // Whatever is in the box right now is what the note is made of.
    if (S.editing === id) commitEdit();
    it = M.item(S.store.board, id);
    if (!it) return false;                    // an empty box committed itself away
    var text = String(it.t || '').trim();
    if (!text) { toast('Write something in it first - an empty note is not worth making.'); return false; }
    var title = titleFor(text);
    return ask('Create a new note called ' + q(title) + ' in your notes? Its text is this sticky\'s, and the sticky ' +
      'becomes a card pointing at it.', 'Create the note', function () { doPromote(id, title, text); });
  };

  function doPromote(id, title, text) {
    if (!beginWrite()) return false;
    return HOST.createNote(title, text).then(function (r) {
      S.writing = false;
      if (!r.ok) {
        toast('That note could not be created (' + saidNo(r) + '). The sticky is exactly as it was.');
        return false;
      }
      var it = M.item(S.store.board, id);
      if (!it || it.k !== 'sticky') {
        // The note is real either way; what has gone is the thing to swap.
        toast(q(title) + ' was created, but the sticky is no longer on the board, so nothing was swapped.');
        refreshNotes([r.id]);
        return false;
      }
      var spec = { k: 'note', id: r.id, p: it.p.slice(), t: title };
      if (it.w != null) spec.w = it.w;
      if (it.c) spec.c = it.c;
      var out = substituteCard({
        label: 'make a sticky into a note',
        gone: [id],
        spec: function () { return spec; },
        bar: true,
        news: q(title) + ' really was created in your notes.'
      });
      if (!out) {
        toast(q(title) + ' was created, but a card for it could not be placed.');
        return false;
      }
      refreshNotes([r.id]);
      // A board that could not record it has said so in the banner; a toast
      // saying the sticky is a note now would cover that and then leave.
      if (out.saved) toast(q(title) + ' is a note now. Undo puts the sticky back; the note stays.');
      return true;
    }, function (e) {
      S.writing = false;
      toast('That note could not be created (' + String((e && e.message) || e) + ').');
      return false;
    });
  }

  /* ----------------------------------------------------- a real note link */

  /*
   * The relationship's type, which is the label the user gave the line when
   * there is one. A line labelled "feeds" says something the relationships
   * table can hold; an unlabelled one is 'related', which is the host's own
   * default and what the merge screen writes.
   */
  A.RELATION_MAX = 40;
  function relationOf(l) {
    var t = String((l && l.t) || '').replace(/\s+/g, ' ').trim();
    if (!t) return 'related';
    return t.length > A.RELATION_MAX ? t.slice(0, A.RELATION_MAX) : t;
  }

  A.ops.linkNotes = function (linkId) {
    var l = M.link(S.store.board, linkId);
    if (!l) return false;
    if (!canWrite()) return false;
    var ends = noteEnds(l);
    if (!ends) {
      toast('Both ends have to be cards for two different notes. A sticky is not a note.');
      return false;
    }
    var a = liveNote(l.a), b = liveNote(l.b);
    if (!a || !b) { toast('One of those notes is gone, so there is nothing to link.'); return false; }
    if (l.real === true) { toast('Those notes are already linked.'); return false; }
    var rel = relationOf(l);
    return ask('Link these notes in your library? A ' + q(rel) + ' relationship is written on ' + q(a.title) +
      ', pointing at ' + q(b.title) + '. It outlives the line on the board.',
      'Link the notes', function () { doLinkNotes(linkId, a, b, rel); });
  };

  function doLinkNotes(linkId, a, b, rel) {
    if (!beginWrite()) return false;
    return HOST.linkNotes(a.noteId, b.noteId, rel).then(function (r) {
      S.writing = false;
      if (!r.ok) {
        toast('The notes were not linked (' + saidNo(r) + '). The line on the board is unchanged.');
        return false;
      }
      var marked = S.store.mutate('mark a link as a note link', function (bd) {
        return M.setLinkReal(bd, linkId, true);
      });
      redraw();
      // The relationship is written. The dot on the line is the board's note
      // of that, and a board that has gone read-only across the await cannot
      // save it - which is said rather than dropped, exactly as a merge is.
      var saved = !marked || recordChange(q(a.title) + ' and ' + q(b.title) + ' really are linked in your notes.');
      if (saved) {
        toast(q(a.title) + ' and ' + q(b.title) + ' are linked in your notes.' +
          (r.errors && r.errors.length ? ' (' + r.errors[0] + ')' : ''));
      }
      return true;
    }, function (e) {
      S.writing = false;
      toast('The notes were not linked (' + String((e && e.message) || e) + ').');
      return false;
    });
  }

  A.ops.unlinkNotes = function (linkId) {
    var l = M.link(S.store.board, linkId);
    if (!l) return false;
    if (!canWrite()) return false;
    var ends = noteEnds(l);
    if (!ends) { toast('Both ends have to be note cards.'); return false; }
    if (l.real !== true) { toast('No note relationship is recorded behind this line.'); return false; }
    var t = endTitles(l, ends), at = t.a, bt = t.b;
    return ask('Remove the relationship between ' + q(at) + ' and ' + q(bt) + ' from your notes? Every ' +
      'relationship between those two notes goes, whichever way round it points; the line on the board stays.',
      'Remove the relationship', function () { doUnlinkNotes(linkId, ends, at, bt); });
  };

  function doUnlinkNotes(linkId, ends, at, bt) {
    if (!beginWrite()) return false;
    return HOST.unlinkNotes(ends.a, ends.b).then(function (r) {
      S.writing = false;
      if (!r.ok) {
        toast('The relationship was not removed (' + saidNo(r) + '). The line still says it is there.');
        return false;
      }
      var marked = S.store.mutate('unmark a note link', function (bd) {
        return M.setLinkReal(bd, linkId, false);
      });
      redraw();
      var saved = !marked || recordChange(q(at) + ' and ' + q(bt) + ' really are no longer linked in your notes.');
      if (saved) {
        toast(q(at) + ' and ' + q(bt) + ' are no longer linked in your notes. The line is still on the board.');
      }
      return true;
    }, function (e) {
      S.writing = false;
      toast('The relationship was not removed (' + String((e && e.message) || e) + ').');
      return false;
    });
  }

  /* --------------------------------------------------- a group's tag, once */

  A.ops.tagNotes = function (groupId) {
    var g = M.group(S.store.board, groupId);
    if (!g) return false;
    if (!canWrite()) return false;
    var name = String(g.t || '').replace(/\s+/g, ' ').trim();
    if (!name) { toast('Name the group first: the tag is the group\'s name.'); return false; }
    var ids = [], seen = Object.create(null), skipped = 0;
    g.m.forEach(function (m) {
      var n = liveNote(m);
      if (!n) { skipped++; return; }
      if (BOARD.has(seen, n.noteId)) return;
      seen[n.noteId] = 1;
      ids.push(n.noteId);
    });
    if (!ids.length) {
      toast('Nothing in this group is a note card that still resolves, so there is nothing to tag.');
      return false;
    }
    return ask('Add the tag ' + q(name) + ' to ' + ids.length + ' note' + (ids.length === 1 ? '' : 's') + '?' +
      (skipped ? ' ' + skipped + ' card' + (skipped === 1 ? '' : 's') + ' in the group ' +
        (skipped === 1 ? 'is not a note and is' : 'are not notes and are') + ' skipped.' : '') +
      ' It is written once: renaming the group later does not rename the tag, and ungrouping never removes it.',
      'Add the tag', function () { doTagNotes(ids, name); });
  };

  function doTagNotes(ids, name) {
    if (!beginWrite()) return false;
    return HOST.tagNotes(ids, name).then(function (r) {
      S.writing = false;
      if (!r.ok) { toast('Nothing was tagged (' + saidNo(r) + ').'); return false; }
      // Tagging changes no board object, so nothing is dirty and nothing is
      // saved: what changed is the notes, and the chips that show them.
      refreshNotes(ids);
      var n = r.updatedCount;
      toast(n >= ids.length
        ? q(name) + ' added to ' + n + ' note' + (n === 1 ? '' : 's') + '.'
        : q(name) + ' added to ' + n + ' of ' + ids.length + ' notes' +
          (r.errors && r.errors.length ? ': ' + r.errors[0] : '.'));
      return true;
    }, function (e) {
      S.writing = false;
      toast('Nothing was tagged (' + String((e && e.message) || e) + ').');
      return false;
    });
  }

  /* ------------------------------------------------------- ticking a task */

  /*
   * The checkbox on a task card is a marker AND a control, and the control
   * writes to the note rather than to the board - which is why it asks, and
   * why nothing about the board is marked dirty when it lands. The card
   * re-reads the note afterwards and draws whatever it now says.
   */
  A.ops.tick = function (id) {
    var n = liveNote(id);
    if (!n) { toast('That card\'s note is gone, so there is nothing to tick.'); return false; }
    if (!canWrite()) return false;
    if (!n.face.task) { toast('Only a task can be ticked, and this note is not one.'); return false; }
    var done = !n.face.done;
    return ask('Mark ' + q(n.title) + (done ? ' as done' : ' as not done') + ' in your notes? This writes to the ' +
      'note itself, not to the board.', done ? 'Mark it done' : 'Mark it not done',
      function () { doTick(n.noteId, n.title, done); });
  };

  function doTick(noteId, title, done) {
    if (!beginWrite()) return false;
    return HOST.setTaskStatus(noteId, done ? HOST.STATUS_DONE : HOST.STATUS_TODO).then(function (r) {
      S.writing = false;
      if (!r.ok) { toast(q(title) + ' was not changed (' + saidNo(r) + ').'); return false; }
      refreshNotes([noteId]);
      toast(q(title) + (done ? ' is done.' : ' is back on the list.'));
      return true;
    }, function (e) {
      S.writing = false;
      toast(q(title) + ' was not changed (' + String((e && e.message) || e) + ').');
      return false;
    });
  }

  /* ==================================================================== */
  /* merging                                                               */
  /* ==================================================================== */

  /*
   * Dropping one note card onto another, and Merge on a selection, both arrive
   * here. It opens the app's real merge screen and then puts the board back
   * together around whatever came out of it.
   *
   * The thing this function exists to get right is that the answer is an
   * UPSERT. The merge screen has two save modes, and replace mode rewrites the
   * first source in place and hands back that source's own id. A board that
   * treated every answer as a new card would end up with two cards for one
   * note - which the user would then merge with itself.
   *
   * The rest of it:
   *
   *   Refusals are stated. A sticky, an annotation and a tombstone are not
   *   notes, and two cards for one note are not two notes.
   *
   *   Re-entrancy is guarded HERE. The host has no guard of its own - that was
   *   left to the calling plugin on purpose - and two merges of the same cards
   *   would make two merged notes out of them. The guard is released in one
   *   place and on every exit path INCLUDING the two that used to escape it:
   *   a host that throws on the stack instead of rejecting, and a substitution
   *   that throws. See `release` below.
   *
   *   `cancelled` is never retried. It means no note came back, which is
   *   usually a back-out and is sometimes a merge that saved without saying
   *   so; a retry would make a second merged note out of the first one.
   *
   *   Cancelling changes nothing at all - including the dragged card's
   *   position, which is why the drag is abandoned before the screen opens
   *   rather than committed and undone afterwards.
   */
  A.ops.merge = function (ids, opts) {
    opts = opts || {};
    if (!editable()) return Promise.resolve(false);
    if (S.merging) { toast('The merge screen is already open.'); return Promise.resolve(false); }
    if (S.writing) { toast('One write at a time - the last one is still going.'); return Promise.resolve(false); }
    var board = S.store.board;
    var cards = (ids || []).filter(function (id) { return !!M.item(board, id); });

    var notNotes = cards.filter(function (id) { return M.item(board, id).k !== 'note'; });
    if (notNotes.length) {
      toast('Merging works on note cards. A sticky and an annotation live only on the board, so they cannot merge.');
      return Promise.resolve(false);
    }
    var tombs = cards.filter(function (id) { return !liveNote(id); });
    if (tombs.length) {
      toast('One of those cards has no note behind it any more, so there is nothing to merge.');
      return Promise.resolve(false);
    }
    var noteIds = [], seen = Object.create(null);
    cards.forEach(function (id) {
      var nid = M.item(board, id).id;
      if (BOARD.has(seen, nid)) return;
      seen[nid] = 1;
      noteIds.push(nid);
    });
    if (cards.length < 2) {
      toast('Merging needs two note cards. Drop one onto another, or select two and tap Merge.');
      return Promise.resolve(false);
    }
    if (noteIds.length < 2) {
      toast('Those cards are the same note, so there is nothing to merge.');
      return Promise.resolve(false);
    }

    S.merging = true;
    drawBadge();
    var at = opts.at && isFinite(opts.at[0]) && isFinite(opts.at[1]) ? [opts.at[0], opts.at[1]] : null;
    /*
     * Which board asked. applyMerge already refuses to touch cards whose NOTE
     * is not one of the sources, which is what defends it against Open theirs
     * installing another session's board under the same ids - but a board
     * SWITCH is a different thing entirely: the user goes Home and opens
     * another board while the merge screen is up, and that board may perfectly
     * well hold a card for one of the merged notes. The substitution would
     * then be applied, and written, to a board that had nothing to do with it.
     *
     * And it stays `S.session` rather than becoming `S.gen`, which suggest and
     * export both use. `S.gen` is the stricter test - it also sees Open theirs,
     * which keeps the session object and replaces every card under it - but
     * strictness is not free here and it is not needed:
     *
     *   this screen is HOST-MODAL. Nothing in the app runs while it is up on a
     *   phone; the browser mock is the only place the board is reachable at
     *   all, which is where the switch above is even possible;
     *
     *   the answer is about the same NOTE either way. applyMerge looks every
     *   id up again and refuses any card whose note is not one of the sources,
     *   so their board's `n1` - a different note - is not touched;
     *
     *   and there is a cost to the stricter test: adopting a board is a
     *   perfectly ordinary thing to do while the merge screen is up, and the
     *   notes really were merged. Refusing to record it on a board that DOES
     *   hold those notes' cards would strand a merge for nothing.
     *
     * A.ops.addNotes guards the same way, for the same reasons: cards added to
     * an adopted board get fresh ids and touch nothing that was already there.
     */
    var mine = S.session;

    /*
     * The guard is released in ONE place, and it is here: before anything is
     * decided about the answer, and before applyMerge is called. Two ways it
     * used to be able to stick, both of which leave canWrite() refusing every
     * note write for the life of the board, quoting a screen that is not open:
     *
     *   the host's openMerge throwing on the stack rather than rejecting - a
     *   `.then(ok, err)` pair never sees that one, which is why the call is
     *   wrapped in a promise executor rather than trusted to return one;
     *
     *   applyMerge throwing, with the release written after it.
     */
    function release(fn) {
      return function (v) {
        S.merging = false;
        drawBadge();
        return fn(v);
      };
    }

    return new Promise(function (res) { res(HOST.openMerge(noteIds)); }).then(release(function (r) {
      if (!r.ok) {
        toast('The merge screen could not be opened (' + saidNo(r) + '). The board is unchanged.');
        return false;
      }
      if (r.cancelled) {
        // NOT a retry signal: it means no note came back, which covers a merge
        // that saved and did not report it. Asking again could make a second.
        toast('Nothing came back from the merge, so the board is exactly as it was.');
        return false;
      }
      if (S.session !== mine) {
        // The notes really were merged, and the board that would have recorded
        // it is closed. Recording it HERE is the one thing that must not
        // happen, so what is left is to say so - the same posture as a board
        // that could not save the record: state it, change nothing.
        toast('Those notes were merged. This is not the board that asked, so nothing here was changed to match.');
        return false;
      }
      applyMerge(r.mergedNoteId, cards, noteIds, at);
      return true;
    }), release(function (e) {
      toast('The merge screen could not be opened (' + String((e && e.message) || e) + ').');
      return false;
    }));
  };

  /*
   * One card for the merged note, and no other card for it anywhere.
   *
   * The upsert: a card that already points at the merged note KEEPS ITS PLACE
   * and everything else collapses into it. Only when there is none does a new
   * card go in at the drop point.
   *
   * The board may have moved while the merge screen was up - it is a separate
   * screen the user drives, and in the browser it is not modal at all - so
   * every id is looked up again here rather than trusted from before the await.
   */
  function applyMerge(mergedId, cards, sourceNoteIds, at) {
    var board = S.store.board;
    /*
     * An id that still resolves is not the same card still being there.
     *
     * Board ids are short and reused, and the board can be REPLACED across the
     * await: Open theirs, on a conflict banner, resets the store to another
     * session's board, where `n1` and `n2` are perfectly good cards for two
     * unrelated notes. Filtering on "the id is still in the board" would then
     * delete those two, repoint their links, anchors and group membership onto
     * a card for a note nobody merged, and mark the result dirty.
     *
     * The sources were named by NOTE id when the screen opened, and a note id
     * is the thing that cannot quietly become something else. Any card whose
     * note is not one of them is not a card this merge has any business
     * touching.
     */
    var sources = Object.create(null);
    (sourceNoteIds || []).forEach(function (nid) { if (nid) sources[nid] = 1; });
    var live = cards.filter(function (id) {
      var it = M.item(board, id);
      return !!it && it.k === 'note' && BOARD.has(sources, it.id);
    });
    var existing = M.cardsForNote(board, mergedId);
    var out = substituteCard({
      label: 'merge ' + Math.max(2, live.length) + ' cards',
      gone: live,
      keep: existing.length ? existing[0] : null,
      // Only when there is no card for the merged note already: this is an
      // upsert, and replace mode hands back a source's own id.
      spec: function (b) {
        var first = live.length ? M.item(b, live[0]) : null;
        var s = { k: 'note', id: mergedId, p: at || (first ? first.p.slice() : [0, 0]) };
        if (first && first.w != null) s.w = first.w;
        if (first && first.c) s.c = first.c;
        return s;
      },
      // Every other card for this note goes too, not only the sources: one
      // note, one card, or the next merge is a note against itself.
      alsoGone: function (b, survivor) { return M.cardsForNote(b, mergedId); },
      news: 'Those notes really were merged in your library, and that cannot be undone.'
    });

    if (!out) {
      toast('The notes were merged, but no card could be placed for the result.');
      drawBadge();
      return;
    }
    // The merged note is new text, and the sources it was made from may have
    // been rewritten by the merge screen; nothing cached about any of them is
    // worth keeping.
    refreshNotes([mergedId].concat(sourceNoteIds || []));
    // A board that could not record this has already said so, in the banner,
    // where it stays. A toast congratulating the user on a merge the board did
    // not write down would cover exactly that sentence.
    if (!out.saved) return;
    toast(out.placed
      ? 'Merged into one card. Undo puts the cards back; the notes stay merged.'
      : 'Merged into the card that was already here. Undo puts the others back; the notes stay merged.');
  }

  /*
   * The board's account of a note write that has ALREADY happened: one card
   * survives, the cards it stands in for go, and every link, anchor and group
   * membership that pointed at any of them points at the survivor instead.
   *
   * Two callers with one shape. A promoted sticky replaces one card with a new
   * note card; a merge replaces two or more, and its survivor may be a card
   * that was already on the board. Sharing it is how they both get the
   * read-only re-check, which neither can do without: the note write has
   * landed by the time either is called, and markDirty on a board that has
   * gone read-only in the meantime returns without a word.
   *
   *   label      the undo step's name.
   *   gone       board ids this stands in for.
   *   keep       an existing board id to survive, when there is one.
   *   spec       fn(board) -> the card to add when there is not.
   *   alsoGone   fn(board, survivor) -> more ids to fold in, decided after the
   *              survivor exists.
   *   bar        open the survivor's action bar.
   *   news       what happened, for a board that cannot save it.
   *
   * -> { id, placed, saved } or null if no card could be placed.
   */
  function substituteCard(o) {
    var survivor = o.keep || null, placed = false;
    S.store.mutate(o.label, function (b) {
      if (!survivor) {
        survivor = M.addItem(b, o.spec(b));
        placed = !!survivor;
      }
      if (!survivor) return;
      var gone = o.gone.slice();
      (o.alsoGone ? o.alsoGone(b, survivor) : []).forEach(function (id) {
        if (id !== survivor && gone.indexOf(id) < 0) gone.push(id);
      });
      M.replaceItems(b, gone.filter(function (id) { return id !== survivor; }), survivor);
    });
    if (!survivor) return null;
    clearSel();
    S.sel[survivor] = true;
    if (o.bar) S.barOpen = true;
    prune();
    var saved = recordChange(o.news);
    redraw();
    return { id: survivor, placed: placed, saved: saved };
  }

  /* ==================================================================== */
  /* the AI: suggest links                                                 */
  /* ==================================================================== */

  /*
   * The only AI feature there is, and everything about it is arranged so that
   * a board with no model behind it is a board.
   *
   *   Nothing is drawn as fact. The answer becomes PROPOSALS - dashed accent
   *   lines with their labels, a count, and Apply or Discard. They are not in
   *   the board, so they cannot dirty the note, cannot be saved, cannot be
   *   undone (there is nothing to undo) and leave nothing behind when they go.
   *
   *   Every way of failing is the same sentence. No model, a refusal, a
   *   timeout, an answer with nothing parseable in it, an answer about cards
   *   that are not here: each is "nothing to suggest" with the reason, said in
   *   the toast the board says everything else in. None of them is a dialog,
   *   an error state or a thing the user has to dismiss.
   *
   *   Apply is ONE undo step, and it re-checks. The board is live across the
   *   request - it is a real await into a model - so a card may have gone and
   *   a link may have been drawn by hand in the meantime.
   */

  // The cards a request is about: the selection, or the whole board.
  function suggestPool() {
    var sel = selIds();
    return AI.cards(S.store.board, sel.length ? sel : null, faceOf);
  }

  function nothingToSuggest(why) {
    toast('Nothing to suggest: ' + why);
    return false;
  }

  A.ops.suggest = function () {
    if (!editable()) return Promise.resolve(false);
    if (S.suggesting) { toast('Still thinking about the last one.'); return Promise.resolve(false); }
    if (S.proposals) { toast('Apply or discard the suggestions already on the board first.'); return Promise.resolve(false); }
    if (S.editing) commitEdit();
    if (!HOST.hasAI()) return Promise.resolve(nothingToSuggest('this app cannot reach a model here.'));

    var pool = suggestPool();
    if (pool.cards.length < AI.MIN_CARDS) {
      // Said in terms of what was ASKED, not of what survived: "two of the
      // cards you selected are stickies" is the answer, and "there are fewer
      // than two note cards" is a restatement of the question.
      var aside = [];
      if (pool.skipped) aside.push(pool.skipped + (pool.skipped === 1 ? ' is not a note card' : ' are not note cards'));
      if (pool.gone) aside.push(pool.gone + (pool.gone === 1 ? ' has no note behind it' : ' have no notes behind them'));
      if (pool.unsafe) aside.push(pool.unsafe + (pool.unsafe === 1 ? ' has an id' : ' have ids') + ' this board cannot name in a request');
      return Promise.resolve(nothingToSuggest(
        'a suggestion needs at least two note cards' + (aside.length ? ' (' + aside.join(', ') + ').' : '.')));
    }

    var cards = pool.cards;
    var prompt = AI.prompt(cards, AI.existing(S.store.board, cards));
    /*
     * Which board asked. The user can go home and open another one - or take
     * another session's board on a conflict - while the model is thinking, and
     * a preview drawn onto THAT board would be lines between ids that mean
     * something else there. `S.gen`, not `S.session`: adopting a board keeps
     * the session object and replaces everything in it.
     */
    var gen = S.gen;
    S.suggesting = true;
    drawBadge();

    // And the FLAG belongs to that board too. Clearing it from here after the
    // board has moved on would clear the flag of whatever request is out for
    // the board that is open now.
    function done() {
      if (S.gen !== gen) return;
      S.suggesting = false;
      drawBadge();
    }

    return new Promise(function (res) { res(HOST.chatAI(prompt, {})); }).then(function (r) {
      done();
      if (S.gen !== gen) return false;
      if (!r.ok) return nothingToSuggest(lower(r.error || 'the model did not answer.') + '.');
      var read = AI.read(S.store.board, r.text, cards);
      if (!read.proposals.length) return nothingToSuggest(AI.nothing(read));
      S.proposals = read.proposals;
      // The preview takes the bar over, so a selection standing behind it
      // would be a second bar nobody can see.
      clearSel();
      redraw();
      toast(AI.summary(read.proposals.length) + '. Tap one to drop it, or Apply to draw them all.');
      return true;
    }, function (e) {
      done();
      if (S.gen !== gen) return false;
      return nothingToSuggest(String((e && e.message) || e) + '.');
    });
  };

  /*
   * Apply. One undo step for all of them, and re-checked against the board as
   * it is NOW rather than as it was when the model was asked.
   */
  A.ops.applySuggestions = function () {
    if (!S.proposals || !S.proposals.length) return false;
    if (!editable()) return false;
    /*
     * Re-checked at the moment a preview becomes real, and re-checked by
     * PRUNE rather than by a second copy of its predicate. This used to be a
     * filter written out again here; the two then had to be kept in step by
     * hand, and only one of them learned about tombstones.
     */
    prune();
    var live = S.proposals || [];
    if (!live.length) {
      S.proposals = null;
      redraw();
      toast('Those cards have changed since they were suggested, so there was nothing left to draw.');
      return false;
    }
    var made = 0;
    S.store.mutate('apply ' + live.length + ' suggested link' + (live.length === 1 ? '' : 's'), function (b) {
      live.forEach(function (p) { if (M.addLink(b, p.a, p.b, { t: p.t })) made++; });
    });
    S.proposals = null;
    if (!made) { redraw(); toast('None of those links could be drawn.'); return false; }
    markDirty('edit');
    prune();
    redraw();
    toast(made + ' link' + (made === 1 ? '' : 's') + ' drawn. Undo takes ' +
      (made === 1 ? 'it' : 'them all') + ' back at once.');
    return true;
  };

  // Discard. There is nothing to undo, because nothing was ever done.
  A.ops.discardSuggestions = function () {
    if (!S.proposals) return false;
    S.proposals = null;
    redraw();
    toast('The suggestions are gone. Nothing was drawn and nothing was saved.');
    return true;
  };

  /*
   * One proposal dismissed, before the rest are applied. -> whether the id was
   * one, which is also how tapItem decides that a tap was about a suggestion.
   */
  A.ops.dismissSuggestion = function (id) {
    if (!S.proposals || !id) return false;
    var next = S.proposals.filter(function (p) { return p.i !== id; });
    if (next.length === S.proposals.length) return false;
    S.proposals = next.length ? next : null;
    redraw();
    toast(S.proposals
      ? 'Dropped. ' + AI.summary(S.proposals.length) + ' still.'
      : 'That was the last one. Nothing was drawn.');
    return true;
  };

  /* ==================================================================== */
  /* export: a picture of the board                                        */
  /* ==================================================================== */

  /*
   * The WHOLE board, always: every card, link, annotation and group, with
   * focus lifted, search ignored and nothing dimmed. EX.scene builds its own
   * layout from the board's coordinates and never looks at the camera or the
   * DOM, so what comes out does not depend on what happens to be on screen.
   *
   * It lands as an attachment on the board note, and exporting again REPLACES
   * the previous file rather than piling up beside it. Which file that is,
   * is the part worth being careful about: the host renames everything it
   * saves to `<stem>_<uuid><ext>`, so the previous export is recognised by
   * that pattern and the new one is always sent under the original name. A
   * caller that echoed the stored name back would grow a uuid per export and
   * never recognise its own work again.
   */

  /*
   * What the file is named after: the board NOTE's title, and nothing else.
   *
   * `el.title.textContent` used to stand in behind it, which on a
   * `?board=<id>` launch is the string 'Big Bang' until the title query comes
   * back - so an export in that window was named after the app rather than
   * after the note. 'Board' is at least honest about knowing nothing.
   * EX.isPreviousExport does not read the title at all, so a picture written
   * under either name is still replaced by the next export.
   */
  function exportTitle() {
    return (S.note && S.note.title) || 'Board';
  }

  /*
   * The notes an export is out for, and why it is not on S.
   *
   * S.exporting is about the board that is OPEN - closeBoard clears it,
   * because a flag belonging to a board nobody is looking at would refuse
   * every export on the next one. But the file is written to a NOTE, and the
   * user can leave a board mid-rasterise and come straight back to it: two
   * exports of one note, each doing its own attachmentsOf then attachFile, and
   * the pair races either way round - the later read misses the earlier file
   * and both are kept, or the earlier write names a path the later has already
   * taken off the note.
   */
  var exportingNotes = Object.create(null);

  A.ops.exportBoard = function (formatId) {
    if (S.mode !== 'board' || !S.store || !S.session) {
      toast('There is no board here to export.');
      return Promise.resolve(false);
    }
    // An embed is a picture of a board inside its own note; making a second
    // one and attaching it to that note is not something an embed does.
    if (S.embed) return Promise.resolve(false);
    if (S.exporting) { toast('The last export is still going.'); return Promise.resolve(false); }
    if (S.proposals) { toast('Apply or discard the suggested links first - they are not part of the board.'); return Promise.resolve(false); }
    var f = EX.format(formatId || 'png');
    if (!f) { toast('That is not a format this board can write.'); return Promise.resolve(false); }
    if (S.editing) commitEdit();
    var board = S.store.board;
    if (BOARD.isEmpty(board) || !Object.keys(board.items).length) {
      toast('There is nothing on this board to draw yet.');
      return Promise.resolve(false);
    }

    var noteId = S.session.noteId;
    if (BOARD.has(exportingNotes, noteId)) {
      toast('A picture of this note is still being made.');
      return Promise.resolve(false);
    }
    var stem = EX.fileStem(exportTitle());
    var name = stem + f.ext;
    /*
     * Which board asked. Rendering and attaching are two real awaits, and the
     * board is live across both: the user can go home and open another one.
     * The FILE still goes where it was always going - `noteId` was taken
     * before the first await and the picture is of that board - but the toast
     * must not land on a board it is not about, saying a picture of it was
     * attached to its note.
     */
    var gen = S.gen;
    S.exporting = true;
    exportingNotes[noteId] = true;
    S.barMode = '';
    drawBars();

    // The flag and the toast both belong to the board that asked. Clearing the
    // flag from here after the board has moved on would clear the one an
    // export of the board that is open NOW is holding, and let a second start
    // beside it - two exports of one note, each removing the other's file.
    // The NOTE's entry is released either way: it is not about a board being
    // open, it is about a file being written, and that has finished.
    function stop(v) {
      delete exportingNotes[noteId];
      if (S.gen === gen) { S.exporting = false; drawBadge(); }
      return v;
    }
    function say(text) { if (S.gen === gen) toast(text); }

    var scene;
    try {
      scene = EX.scene(board, { faceOf: faceOf, measure: EX.canvasMeasure() });
    } catch (e) {
      stop(false);
      say('The board could not be drawn (' + String((e && e.message) || e) + ').');
      return Promise.resolve(false);
    }

    return Promise.resolve(f.write(scene, {})).then(function (out) {
      var data = out.base64 || '';
      if (!data) throw new Error('nothing was rendered');
      // What is already there, so the previous export can go in the SAME call
      // that adds this one - one write, one approval, and never a window in
      // which the note holds two of them.
      return HOST.attachmentsOf(noteId).then(function (a) {
        /*
         * A read that FAILED is not a note with no files on it. Treating it as
         * one turns "the database was busy" into a silent pile-up: the picture
         * lands, the previous one is never named for removal, and the note
         * grows another copy every time - which is precisely the thing this
         * call is here to prevent. So it is the export that fails, out loud.
         */
        if (!a.ok) throw new Error('the files already on this note could not be read' +
          (a.error ? ': ' + lower(String(a.error)) : ''));
        var old = a.files.filter(function (att) {
          return EX.isPreviousExport(att, f.ext);
        }).map(function (att) { return att.path; });
        return HOST.attachFile(noteId, { data: data, fileName: name, mimeType: f.mime }, old)
          .then(function (w) {
            stop(true);
            if (!w.ok) { say('The picture could not be attached (' + saidNo(w) + ').'); return false; }
            say((old.length ? 'Replaced ' : 'Attached ') + name +
              (out.width ? ' (' + out.width + '×' + out.height + ')' : '') +
              // Said out loud, because a picture drawn at less than the
              // resolution asked for is a thing the reader should know.
              (out.scaled ? ' · scaled down to fit what this device can draw' : '') + '.');
            return true;
          });
      });
    }).catch(function (e) {
      stop(false);
      say('The board could not be exported (' + String((e && e.message) || e) + ').');
      return false;
    });
  };

  /* ==================================================================== */
  /* typing into a box                                                     */
  /* ==================================================================== */

  /*
   * Three things can be typed into - a sticky, an annotation, a link's label -
   * and a group's name makes four. Every one of them is an ordinary element on
   * the canvas with contentEditable turned on for as long as the caret is in
   * it, rather than a dialog, because a dialog over a board hides the thing
   * being described.
   *
   * While a box is being edited the renderer does not write to it (ctx.editing;
   * see render.js paint), for the plainest of reasons: assigning textContent
   * under a live caret puts the caret back at the front and eats the character
   * that triggered the render.
   */
  function fieldOf(id) {
    var kind = M.kindOf(S.store.board, id);
    if (kind === 'sticky' || kind === 'annot') {
      var e = S.r.el(id);
      return e ? e.querySelector('.ct') : null;
    }
    if (kind === 'link') return S.r.label(id);
    if (kind === 'group') {
      var h = S.r.handle(id);
      return h ? h.firstChild : null;
    }
    return null;
  }

  function textOf(id) {
    var o = M.any(S.store.board, id);
    return (o && o.t) || '';
  }

  function beginEdit(id) {
    if (!editable()) return false;
    var kind = M.kindOf(S.store.board, id);
    if (kind !== 'sticky' && kind !== 'annot' && kind !== 'link' && kind !== 'group') return false;
    if (S.editing && S.editing !== id) commitEdit();
    S.editing = id;
    S.barMode = '';
    // Draw first: a link with no label has no label ELEMENT until something
    // asks for one, and this is what asks.
    redraw();
    var field = fieldOf(id);
    if (!field) { S.editing = null; redraw(); return false; }
    S.field = field;
    field.textContent = textOf(id);
    /*
     * plaintext-only, where the engine has it - which both target platforms
     * do. It is what stops rich HTML from the clipboard becoming real markup
     * inside a card: paint() only rewrites textContent when it DIFFERS from
     * the model's text, and `ab<b>cd</b>` reads back as the same text, so a
     * pasted <img> keeps its remote src for as long as the board is open.
     * The value is refused by older engines, which is why it is tried rather
     * than assigned, and why the paste handler below is a real fallback and
     * not a belt on a working brace.
     */
    try { field.contentEditable = 'plaintext-only'; } catch (e) { /* older webviews */ }
    if (field.contentEditable !== 'plaintext-only') field.contentEditable = 'true';
    field.spellcheck = false;
    field.onpaste = function (e) {
      var cd = e.clipboardData || global.clipboardData;
      if (!cd) return;
      e.preventDefault();
      insertText(String(cd.getData('text/plain') || '').replace(/\r\n?/g, '\n'));
      A.ops.keepVisible();
    };
    field.onkeydown = function (e) {
      // Enter commits; shift-Enter breaks a line, because a sticky is a note
      // to yourself and those run to more than one.
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); commitEdit(); }
      else if (e.key === 'Escape') { e.preventDefault(); cancelEdit(); }
    };
    field.oninput = function () { A.ops.keepVisible(); };
    field.onblur = function () { if (S.editing === id) commitEdit(); };
    focusAll(field);
    armKeyboardFollow();
    return true;
  }
  A.ops.edit = beginEdit;

  // Plain text, at the caret. execCommand is deprecated and is still the only
  // insertion the browser puts on the undo stack of the field itself, so a
  // paste can be undone with the keyboard the way typing can; the Range below
  // is what answers when it is not there.
  function insertText(t) {
    if (!t) return;
    try {
      if (document.execCommand && document.execCommand('insertText', false, t)) return;
    } catch (e) { /* older webviews */ }
    try {
      var sel = global.getSelection();
      if (!sel || !sel.rangeCount) return;
      var r = sel.getRangeAt(0);
      r.deleteContents();
      var node = document.createTextNode(t);
      r.insertNode(node);
      r.setStartAfter(node);
      r.collapse(true);
      sel.removeAllRanges();
      sel.addRange(r);
    } catch (e2) { /* nothing better to do than drop the paste */ }
  }

  function focusAll(node) {
    node.focus();
    try {
      var r = document.createRange();
      r.selectNodeContents(node);
      var sel = global.getSelection();
      sel.removeAllRanges();
      sel.addRange(r);
    } catch (e) { /* older webviews */ }
  }

  /*
   * Take the field back, and say what was in it. Null when the element has
   * gone - a redraw removed it, the item was deleted from elsewhere.
   *
   * The element comes from `S.field` first and only then from the model,
   * because the model is exactly what has stopped being able to answer by the
   * time this matters: an item removed by an undo, or a whole board replaced
   * by another session's, leaves fieldOf(id) with nothing to look up, and a
   * field never taken back is an element left contentEditable for ever.
   */
  function releaseField(id) {
    var field = S.field || fieldOf(id);
    S.field = null;
    if (!field) return null;
    var text = (field.innerText == null ? field.textContent : field.innerText);
    text = String(text || '')
      .replace(/\r\n?/g, '\n')
      .replace(/ /g, ' ')
      .replace(/[ \t]+\n/g, '\n')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
    field.contentEditable = 'false';
    field.onkeydown = null;
    field.oninput = null;
    field.onblur = null;
    field.onpaste = null;
    /*
     * Handed back as TEXT, always. Whatever got into the element while it was
     * live - a paste an engine without plaintext-only let through, a browser's
     * own rich-text command - is element nodes, and the renderer will not take
     * them out again: paint() rewrites textContent only when it DIFFERS from
     * the model's text, and `ab<b>cd</b>` reads back as exactly `abcd`. So a
     * pasted <img> with a remote src would sit in the card for the rest of the
     * session. One assignment ends that, and it is the last thing the field
     * does before it stops being a field.
     */
    if (field.firstChild || field.textContent !== text) field.textContent = text;
    return text;
  }

  /*
   * Let the field go, whatever the reason.
   *
   * `S.editing` nulled while the element is still contentEditable is the one
   * state that bricks a card: gestures.js hands every pointerdown inside live
   * text straight to the browser (which is right - a caret has to be placeable)
   * and the renderer, told nothing is being edited, writes textContent under a
   * live caret. Nothing taps that card again. The two therefore move together,
   * here, and nowhere else clears S.editing by hand.
   */
  function endEdit() {
    var id = S.editing;
    if (!id) return null;
    S.editing = null;
    stopKeyboardFollow();
    return releaseField(id);
  }

  var STEP = { sticky: 'add a sticky', annot: 'add an annotation' };

  function commitEdit() {
    var id = S.editing;
    if (!id) return false;
    var kind = M.kindOf(S.store.board, id);
    var text = endEdit();
    var fresh = S.fresh === id;
    if (text === null || !kind) { S.fresh = null; redraw(); return false; }

    if (!text) {
      /*
       * Nothing was written. A box that never held anything leaves NO trace -
       * no item, no undo step, nothing marked dirty - which is the whole
       * reason a fresh one is kept out of the store until now. One that used
       * to say something and has been emptied is a deletion, and deletions are
       * undoable. A label or a group name simply goes back to having none.
       */
      if (fresh) { dropFresh(); redraw(); return false; }
      if (kind === 'sticky' || kind === 'annot') return A.ops.remove([id]);
      var cleared = S.store.mutate('clear a label', function (b) { return M.setText(b, id, ''); });
      redraw();
      if (cleared) markDirty('edit');
      return cleared;
    }

    if (fresh) {
      S.fresh = null;
      commitFresh(id, text);
      return true;
    }
    var changed = S.store.mutate(kind === 'link' ? 'label a link' : 'edit text', function (b) {
      return M.setText(b, id, text);
    });
    redraw();
    if (changed) markDirty('edit');
    return changed;
  }
  A.ops.commitEdit = commitEdit;

  /*
   * The box appeared AND it says this: one undo step, not two, and not none.
   *
   * The item is already in the board but no transaction has ever seen it, so
   * committing in place would compare against a baseline that already contains
   * it and record nothing at all. Taking it out and putting it back inside a
   * transaction makes the step say exactly what happened: before, no box;
   * after, this box with this text.
   */
  function commitFresh(id, text) {
    var it = M.item(S.store.board, id);
    if (!it) { redraw(); return; }
    var spec = { k: it.k, i: id, p: it.p.slice(), t: text };
    if (it.w != null) spec.w = it.w;
    if (it.c) spec.c = it.c;
    if (it.at) spec.at = it.at.map(function (a) { return a.i ? { i: a.i } : { l: a.l }; });
    if (it.q) spec.q = it.q.slice();
    M.removeItem(S.store.board, id);
    S.store.mutate(STEP[it.k] || 'add a card', function (b) { M.addItem(b, spec); });
    clearSel();
    if (M.item(S.store.board, id)) S.sel[id] = true;
    /*
     * The bar opens with it. A sticky that has just been written into is the
     * one moment "make this a note" is the obvious next thing, and leaving it
     * behind an Actions tap makes creating a note on the canvas read as two
     * unrelated steps that happen to end up somewhere useful.
     */
    S.barOpen = true;
    redraw();
    markDirty('edit');
  }

  function cancelEdit() {
    var id = S.editing;
    if (!id) return false;
    endEdit();
    if (S.fresh === id) dropFresh();
    redraw();
    return true;
  }
  A.ops.cancelEdit = cancelEdit;

  /* ------------------------------------------------------- the keyboard */

  /*
   * The band of the stage the user can actually see.
   *
   * `interactive-widget=resizes-content` shrinks the layout viewport on Android
   * Chrome and is ignored outright by iOS WKWebView, where the layout viewport
   * keeps its full height and the keyboard simply covers the bottom of it.
   * visualViewport is the one signal both platforms agree on, so every piece of
   * framing goes through here rather than through clientHeight.
   */
  function visibleRect() {
    var r = el.stage.getBoundingClientRect();
    var top = r.top, bottom = r.bottom, left = r.left, right = r.right;
    var vv = global.visualViewport;
    if (vv) {
      top = Math.max(top, vv.offsetTop);
      bottom = Math.min(bottom, vv.offsetTop + vv.height);
      left = Math.max(left, vv.offsetLeft);
      right = Math.min(right, vv.offsetLeft + vv.width);
    }
    return {
      top: top, bottom: bottom, left: left, right: right,
      height: Math.max(48, bottom - top), width: Math.max(48, right - left)
    };
  }
  A.visibleRect = visibleRect;

  /*
   * Nudge the box being typed into back above the keyboard, by the smallest
   * amount that works.
   *
   * The rectangle comes from the app's own camera and the element's laid-out
   * size - never from getBoundingClientRect(). A rect read while the stage's
   * transform is still animating describes where the box WAS, so each follow-up
   * correction re-applies one already in flight and the board oscillates for as
   * long as the keyboard takes to arrive.
   */
  A.ops.keepVisible = function () {
    if (!S.editing) return false;
    var r = A.editScreenRect(S.editing);
    if (!r) return false;
    var vis = visibleRect();
    var m = 16, dx = 0, dy = 0;
    if (r.height + m * 2 >= vis.height) dy = (vis.top + m) - r.top;
    else if (r.bottom > vis.bottom - m) dy = (vis.bottom - m) - r.bottom;
    else if (r.top < vis.top + m) dy = (vis.top + m) - r.top;
    if (r.width + m * 2 >= vis.width) dx = (vis.left + m) - r.left;
    else if (r.right > vis.right - m) dx = (vis.right - m) - r.right;
    else if (r.left < vis.left + m) dx = (vis.left + m) - r.left;
    if (Math.abs(dx) < 1 && Math.abs(dy) < 1) return false;
    S.tx += dx;
    S.ty += dy;
    /*
     * Soft, like the opening fit and for the same reason: this is the app
     * moving the camera on the user's behalf, not the user moving it. A stray
     * long press that opens an empty sticky, gets the board nudged up by the
     * keyboard and is then abandoned must leave the note exactly as it was -
     * and a pan marked dirty would rewrite it for having been looked at.
     */
    applyCamera(false, true);
    return true;
  };

  /*
   * The keyboard animates in after focus, and not every WebView fires a
   * visualViewport event when it does; the animation itself varies wildly
   * between Android OEMs. Rather than guess a schedule, re-check until the box
   * has needed no correction for a few ticks running, then stop.
   */
  function armKeyboardFollow() {
    stopKeyboardFollow();
    var ticks = 0, stable = 0;
    A.ops.keepVisible();
    S.kbTimer = setInterval(function () {
      ticks++;
      if (!S.editing || ticks > 22) return stopKeyboardFollow();
      stable = A.ops.keepVisible() ? 0 : stable + 1;
      if (ticks >= 6 && stable >= 3) stopKeyboardFollow();
    }, 90);
  }

  function stopKeyboardFollow() {
    if (S.kbTimer) { clearInterval(S.kbTimer); S.kbTimer = null; }
  }

  /* ==================================================================== */
  /* gestures                                                              */
  /* ==================================================================== */

  function ctx() {
    return {
      cache: S.cache,
      sel: S.sel,
      selectMode: S.selectMode,
      dragging: S.drag ? S.drag.set : null,
      linkSel: S.linkSel,
      groupSel: S.groupSel,
      editing: S.editing,
      readOnly: S.readOnly,
      // What stays bright while a search or a focus is on. null is the whole
      // board; an EMPTY set dims all of it, which is what a search that found
      // nothing looks like.
      lit: S.lit,
      linkFrom: S.link ? S.link.from : null,
      linkOver: S.link ? S.link.over : null,
      // Lines the AI has proposed and nobody has accepted. They are drawn
      // over the board, never into it.
      proposals: S.proposals
    };
  }

  // Draw the scene. `redraw` is the whole of it - scene and bars - and is what
  // almost every caller wants; `sync` alone is for the middle of a gesture,
  // where the bars have not changed and rebuilding them would be work done
  // sixty times a second for nothing.
  function sync() { S.r.sync(S.store.board, ctx()); }
  /*
   * The dimming is recomputed here rather than only where it is switched on,
   * because the BOARD moves underneath it: a card added while a search is up
   * has to be judged against that search, and a focused card that has just
   * been removed has to stop being focused. It costs one pass over the board,
   * and only while something is actually dimmed.
   */
  function redraw() {
    if (S.lit || (S.searching && S.query) || S.focus) relight();
    sync();
    drawBars();
  }

  function binRect() {
    // The bin never moves and never transitions its transform: it fades in.
    // A drop target whose rect is mid-animation is a drop target that misses,
    // and under a virtual time budget it would never arrive at all.
    return el.bin.getBoundingClientRect();
  }

  /*
   * The card a one-card drag was dropped on.
   *
   * A body drag only asks this question for note-on-note merging. A drag from
   * the group handle asks it for every item kind: the handle is the explicit
   * choice that makes the otherwise identical card-on-card gesture a group.
   * Multi-card drags and frame drags are moves and have no single "onto".
   *
   * A merge drop on a card whose note has gone still counts, so that the
   * refusal can be SAID rather than silently becoming a move that leaves one
   * card sitting on top of another.
   *
   * The point tested is where the FINGER is, not where the card is: a dragged
   * card overlaps half the board, and what the user aimed at is under the
   * thumb.
   */
  function dropTarget(d, e) {
    if (!e || !d || d.group || d.ids.length !== 1) return null;
    var board = S.store.board;
    var dragged = d.ids[0];
    var it = M.item(board, dragged);
    if (!it || (!d.makeGroup && it.k !== 'note')) return null;
    var p = toBoard(e.clientX, e.clientY);
    var over = S.r.hitItem(board, p.x, p.y, dragged);
    if (!over) return null;
    var target = M.item(board, over);
    if (!target) return null;
    return d.makeGroup || target.k === 'note' ? over : null;
  }

  function overBin(e) {
    if (!e || !el.bin || el.bin.hidden) return false;
    var r = binRect();
    return e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom;
  }

  function gestureApi() {
    return {
      camera: function () { return { tx: S.tx, ty: S.ty, k: S.k }; },

      // One judgement of what a zoom is worth, and it is the gesture layer's:
      // finite, positive, inside the range a finger can reach. render.js keeps
      // its own guard because it is the last thing between a number and the
      // style property, and it must not depend on this file being right.
      setCamera: function (tx, ty, k, live) {
        var z = GEST.zoom(k);
        if (!isFinite(tx) || !isFinite(ty) || z === null) return;
        S.tx = tx; S.ty = ty; S.k = z;
        applyCamera(live);
      },

      /*
       * The id under the finger is a BOARD id, and a board id names an item, a
       * link or a group - the gesture layer does not know which and does not
       * need to. This is the one place that decides.
       */
      tapItem: function (id) {
        /*
         * A suggested link, before anything else. Its id is not a board id -
         * `M.kindOf` answers null for it and every branch below would fall
         * through - so it is routed here, where a tap means "not that one".
         * It is asked first because the answer is unambiguous: nothing on the
         * board can carry a proposal's id (AI.review checks) and nothing that
         * is not a proposal can be in the list.
         */
        if (S.proposals && A.ops.dismissSuggestion(id)) return;
        var kind = M.kindOf(S.store.board, id);
        if (S.editing && S.editing !== id) commitEdit();
        /*
         * In an embed a tap on a card OPENS ITS NOTE. There is no bar for a
         * second tap to reveal and nothing on that bar an embed would allow,
         * so selecting a card here would be a state with no exit and no
         * purpose - and going to the note is the one thing the plan says an
         * embedded board does.
         */
        if (S.embed) {
          if (kind !== 'note') return;
          var f = N.face(S.store.board, id, S.cache);
          if (!f || f.tomb || !f.noteId) return;
          return A.ops.openNote(f.noteId);
        }
        if (kind === 'link') return A.ops.selectLink(id);
        if (kind === 'group') return A.ops.selectGroup(id);
        if (!kind) return;

        if (S.selectMode) {
          if (S.sel[id]) delete S.sel[id]; else S.sel[id] = true;
          if (!selCount()) S.selectMode = false;
          S.barMode = '';
          redraw();
          return;
        }
        /*
         * Tap selects; tap again opens the action bar. A sticky or an
         * annotation goes one step further and opens for typing on that second
         * tap, because its bar's first action would be Edit and its text is
         * the whole of it - a card that IS its text should not need two taps
         * and a button to change it.
         */
        var was = S.sel[id] && selCount() === 1 && !S.linkSel && !S.groupSel;
        S.linkSel = null;
        S.groupSel = null;
        S.barMode = '';
        if (was) {
          if (kind === 'sticky' || kind === 'annot') { redraw(); beginEdit(id); return; }
          S.barOpen = !S.barOpen;
        } else {
          S.sel = Object.create(null);
          S.sel[id] = true;
          S.barOpen = false;
        }
        redraw();
      },

      /*
       * The checkbox on a task card. It is a control, not a marker, and what
       * it controls is the NOTE - so it never selects the card, never opens a
       * bar, and asks before it writes.
       */
      tapTick: function (id) {
        if (S.editing) commitEdit();
        A.ops.tick(id);
      },

      groupHint: function () {
        toast('Drag this group handle onto another card to put the two in a visual group.');
      },

      tapBackground: function () {
        if (S.editing) { commitEdit(); return; }
        if (!selCount() && !S.selectMode && !S.linkSel && !S.groupSel) return;
        clearSel();
        redraw();
      },

      doubleTap: function () { A.ops.fit(); },

      /*
       * A long press STARTS a multi-selection, so it starts with one card: the
       * one under the finger. Adding to whatever happened to be selected meant
       * "start a multi-selection" could begin with two cards in it, one of them
       * chosen by a tap the user made a minute ago for a different reason. A
       * long press made INSIDE the mode is an ordinary add.
       *
       * It is only ever a multi-selection of ITEMS - a link and a group are not
       * things a selection can hold, and a long press on either simply selects
       * it the way a tap would.
       */
      longPressItem: function (id) {
        if (S.editing) commitEdit();
        // Nothing to select for, in an embed: every action a selection leads
        // to is refused, and a bar it could open is not drawn.
        if (S.embed) return;
        var kind = M.kindOf(S.store.board, id);
        if (kind === 'link') return A.ops.selectLink(id);
        if (kind === 'group') return A.ops.selectGroup(id);
        if (!kind) return;
        if (!S.selectMode) S.sel = Object.create(null);
        S.selectMode = true;
        S.linkSel = null;
        S.groupSel = null;
        S.barMode = '';
        S.sel[id] = true;
        S.barOpen = false;
        redraw();
      },

      // A press on empty canvas leaves a sticky where the finger was, ready to
      // be typed into. Nothing is written down until it says something.
      longPressBackground: function (x, y) {
        if (S.editing) { commitEdit(); return; }
        A.ops.newSticky(x, y);
      },

      /*
       * A drag. The id may be a card or a GROUP's tab; dragging the tab moves
       * every member, which is what a frame is for. The base positions are
       * absolute - S.r.absOf, not it.p - because an anchored annotation's `p`
       * is an offset and dragging one by its own stored numbers would fling it
       * to wherever its anchor happens to be.
       */
      dragStart: function (id, opts) {
        if (!editable()) return null;
        if (S.editing) commitEdit();
        opts = opts || {};
        var board = S.store.board;
        var group = M.group(board, id);
        var makeGroup = opts.grouping === true && !!M.item(board, id) && !group;
        var ids = group ? group.m.slice() : (makeGroup ? [id] : ((S.sel[id] && selCount() > 1) ? selIds() : [id]));
        var base = Object.create(null), set = Object.create(null);
        ids.forEach(function (i) {
          var p = S.r.absOf(board, i);
          if (p) { base[i] = [p[0], p[1]]; set[i] = true; }
        });
        ids = Object.keys(set);
        if (!ids.length) return null;
        S.drag = {
          ids: ids, base: base, set: set, overBin: false,
          group: group ? group.i : null, makeGroup: makeGroup
        };
        /*
         * The bin is not offered while a frame is being dragged. Dropping a
         * group on it would have to mean either "remove the frame" or "remove
         * every card in it", and the two are a world apart; removing a group
         * is on its own bar, where it can say which one it is.
         */
        el.bin.hidden = !!S.drag.group || S.drag.makeGroup;
        el.bin.classList.remove('hot');
        sync();
        return ids;
      },

      dragMove: function (ids, dx, dy, e) {
        if (!S.drag) return;
        ids.forEach(function (i) {
          var b = S.drag.base[i];
          if (b) S.r.ghost(i, Math.round(b[0] + dx), Math.round(b[1] + dy));
        });
        // Links, leaders and frames all hang off where the cards are, so they
        // follow the ghosts rather than waiting for the drag to end. Only the
        // derived layer is redrawn: the cards themselves are being moved by
        // the ghosts and must not be re-synced under the finger.
        S.r.deco(S.store.board, ctx());
        if (S.drag.group || S.drag.makeGroup) return;
        var hot = overBin(e);
        if (hot !== S.drag.overBin) {
          S.drag.overBin = hot;
          el.bin.classList.toggle('hot', hot);
        }
      },

      dragEnd: function (ids, commit, e) {
        if (!S.drag) return;
        var d = S.drag;
        var hot = commit && (e ? overBin(e) : d.overBin);
        S.drag = null;
        el.bin.hidden = true;
        el.bin.classList.remove('hot');

        if (!commit) {
          S.r.clearGhosts();
          sync();
          return;
        }
        if (d.makeGroup) {
          var groupOnto = dropTarget(d, e);
          S.r.clearGhosts();
          sync();
          drawBars();
          if (!groupOnto) {
            toast('A group needs another card. The card is back where it started.');
            return;
          }
          A.ops.group([d.ids[0], groupOnto]);
          return;
        }
        if (hot) {
          S.r.clearGhosts();
          // Cards leave the board. The notes behind them are never touched.
          A.ops.remove(d.ids);
          return;
        }
        /*
         * Dropped ONTO another card: that is a merge, not a move.
         *
         * The drag is abandoned rather than committed - the ghosts go, the
         * card is back where it started - and only then does the merge screen
         * open. Cancelling it therefore leaves the board exactly as it was,
         * including the dragged card's position, with nothing to undo.
         */
        var onto = dropTarget(d, e);
        if (onto) {
          var spot = S.r.ghostOf(d.ids[0]);
          S.r.clearGhosts();
          sync();
          drawBars();
          A.ops.merge([onto, d.ids[0]], { at: spot ? [spot[0], spot[1]] : null });
          return;
        }
        /*
         * One transaction for the whole drag, however many cards it moved.
         *
         * The ghosts are still in place while this runs, which is what makes
         * an anchored annotation come out right: placeAt measures its offset
         * against wherever its anchor is NOW, and if that anchor was dragged
         * too, both moved by the same amount and the offset is unchanged.
         */
        var moved = 0;
        var label = d.group ? 'move a group' : (d.ids.length === 1 ? 'move a card' : 'move ' + d.ids.length + ' cards');
        S.store.mutate(label, function (b) {
          d.ids.forEach(function (i) {
            var g = S.r.ghostOf(i);
            if (g && placeAt(b, i, g)) moved++;
          });
        });
        S.r.clearGhosts();
        sync();
        if (moved) markDirty('edit');
        drawBars();
      },

      /* -------------------------------------------------- drawing a link */

      /*
       * A link dragged out of a card's port. The line follows the finger as a
       * straight accented dash rather than the curve it will become: what
       * matters mid-gesture is which two things it will join.
       */
      linkStart: function (id) {
        if (S.readOnly) return false;
        if (S.editing) commitEdit();
        var box = S.r.box(S.store.board, id);
        if (!box) return false;
        S.link = { from: id, at: [box.x + box.w / 2, box.y + box.h / 2], over: null };
        return true;
      },

      linkMove: function (id, cx, cy) {
        if (!S.link) return;
        var p = toBoard(cx, cy);
        S.r.rubber(S.link.at, p.x, p.y);
        var over = S.r.hitItem(S.store.board, p.x, p.y, id);
        if (over === S.link.over) return;
        // Only when it CHANGES: the highlight is a class on a card, and
        // repainting every card sixty times a second to set one that is
        // already set is work done for nothing.
        S.link.over = over;
        sync();
      },

      linkEnd: function (id, cx, cy, commit) {
        var st = S.link;
        S.link = null;
        S.r.clearRubber();
        if (!st) { redraw(); return; }
        if (!commit) { redraw(); return; }
        var p = toBoard(cx, cy);
        var target = S.r.hitItem(S.store.board, p.x, p.y, id);
        redraw();
        if (!target) {
          toast('A link needs somewhere to land. Drag it onto another card.');
          return;
        }
        A.ops.link(id, target);
      },

      resizeStart: function (id) {
        if (S.readOnly) return null;
        var it = M.item(S.store.board, id);
        return it ? RENDER.widthOf(it) : null;
      },

      resizeMove: function (id, w) {
        S.r.ghostWidth(id, clamp(Math.round(w), RENDER.MIN_W, RENDER.MAX_W));
      },

      /*
       * A finger came off the grip. `commit` is false when it never moved past
       * the slop - a stray tap on a 44px target - and false is the whole point:
       * committing would write the board, and for a card with no explicit width
       * it would ADD one, which is a real change to the JSON and a real undo
       * step for a card nobody resized.
       *
       * The width goes in through the model, which applies board.js's own rule
       * and answers whether anything actually changed. Writing it.w here by
       * hand was the read/write drift that lost cards to a NaN coordinate.
       */
      resizeEnd: function (id, w, commit) {
        var width = clamp(Math.round(w), RENDER.MIN_W, RENDER.MAX_W);
        S.r.clearGhosts();
        if (!commit) { sync(); return; }
        var changed = S.store.mutate('resize a card', function (b) {
          return M.setWidth(b, id, width);
        });
        sync();
        if (changed) markDirty('edit');
      }
    };
  }

  /* ==================================================================== */
  /* bars                                                                  */
  /* ==================================================================== */

  function button(label, fn, cls) {
    var b = document.createElement('button');
    b.className = 'bb ' + (cls || '');
    b.textContent = tr(label);
    b.addEventListener('click', fn);
    return b;
  }

  /*
   * The colours a board object can wear. They are names, not values: the block
   * stores the name and the stylesheet decides what it looks like, which is
   * what lets the same board be legible in a light theme and a dark one.
   */
  A.COLOURS = ['blue', 'sky', 'teal', 'green', 'amber', 'rose', 'pink', 'violet'];

  function swatch(name, current, fn) {
    var b = button('', fn, 'sw' + (current === name ? ' on' : ''));
    b.style.setProperty('--sw', 'var(--c-' + name + ')');
    b.title = tr(name);
    return b;
  }

  function blabel(bar, text, cls) {
    var t = document.createElement('span');
    t.className = cls || 'blabel';
    t.textContent = text;
    bar.appendChild(t);
    return t;
  }

  // The same thing, unattached: optionBar takes elements rather than a bar to
  // append to, and a second-level bar sometimes has a sentence on it.
  function noteSpan(text) {
    var t = document.createElement('span');
    t.className = 'bnote';
    t.textContent = tr(text);
    return t;
  }

  /*
   * A second-level bar: what it is about, the options, and its own Back.
   *
   * All four of them - Colour, Ends, Line, Align - are that same shape, and
   * written out four times they were four places for a Back to go missing or
   * for a bar class to disagree with the one the level above it set. Nothing
   * here ever navigates away from the thing being changed.
   */
  function optionBar(title, options, cls) {
    var bar = el.bar;
    blabel(bar, tr(title));
    options.forEach(function (o) { bar.appendChild(o); });
    bar.appendChild(button('Back', function () { S.barMode = ''; drawBars(); }));
    bar.className = cls || 'one open';
  }

  function drawBadge() {
    if (document.body) document.body.classList.toggle('ro', !!S.readOnly);
    if (S.mode === 'home') {
      if (el.hint) el.hint.hidden = true;
      if (el.undo) el.undo.disabled = true;
      if (el.redo) el.redo.disabled = true;
      if (el.badge) { el.badge.textContent = tr('boards'); el.badge.className = ''; }
      return;
    }
    if (el.hint) {
      var n = S.store ? Object.keys(S.store.board.items).length : 0;
      el.hint.hidden = n > 0 || !S.booted;
      if (!el.hint.hidden) {
        el.hint.textContent = S.readOnly
          ? tr('Nothing is drawn here.') + ' ' + tr(S.why || 'This board is read-only.')
          : tr('This board is empty. Add notes from the bar below, or press and hold anywhere to leave a sticky - its bar turns that sticky into a real note.');
      }
    }
    if (el.undo) el.undo.disabled = !S.store || !S.store.canUndo();
    if (el.redo) el.redo.disabled = !S.store || !S.store.canRedo();
    var b = el.badge;
    if (!b) return;
    // A note write landed and the board could not record it. That outranks
    // "read-only", which says only that nothing MORE can be changed; this says
    // something already has been, and is not written down.
    if (S.stranded) { b.textContent = tr('not recorded'); b.className = 'warn'; return; }
    if (S.readOnly) { b.textContent = tr('read-only'); b.className = 'warn'; return; }
    // The merge screen is up. It is the one state where the board is waiting
    // for something that is not on the board.
    if (S.merging) { b.textContent = tr('merging…'); b.className = ''; return; }
    // Two more waits on something that is not the board: a model that has been
    // asked a question, and a picture being drawn and attached.
    if (S.suggesting) { b.textContent = tr('thinking…'); b.className = ''; return; }
    if (S.exporting) { b.textContent = tr('exporting…'); b.className = ''; return; }
    if (S.saving) { b.textContent = tr('saving…'); b.className = ''; return; }
    if (S.dirty) { b.textContent = tr('unsaved'); b.className = ''; return; }
    b.textContent = tr(S.saves ? 'saved' : 'board');
    b.className = 'ok';
  }

  function drawBanner() {
    var e = el.banner;
    if (!e) return;
    e.textContent = '';
    if (!S.banner) { e.hidden = true; return; }
    e.hidden = false;
    e.className = S.banner.tone || '';
    var t = document.createElement('span');
    t.className = 'btext';
    t.textContent = tr(S.banner.text);
    e.appendChild(t);
    (S.banner.actions || []).forEach(function (a) {
      e.appendChild(button(a.label, a.fn, 'small'));
    });
  }

  /*
   * The bottom bar is the only place actions live, because it is the only place
   * a thumb reaches. It has three faces: what the board is, what one card is,
   * and what a multi-selection is.
   */
  function drawBars() {
    drawBadge();
    drawBanner();
    var bar = el.bar;
    if (!bar) return;
    bar.textContent = '';
    bar.className = '';

    /*
     * The home has no board to act on, so the bar says what the list is doing
     * and nothing else. Every action on that screen is a row in the list,
     * where a list's actions belong.
     */
    if (S.mode === 'home') {
      var n = (S.home && S.home.boards && S.home.boards.length) || 0;
      blabel(bar, tr(S.home && S.home.loading ? 'Looking for boards…'
        : (S.home && S.home.error ? 'The boards could not be listed.'
          : n + (n === 1 ? ' board' : ' boards') + (S.home && S.home.more ? ' shown' : ''))) +
          (HOST.isMock ? ' · ' + tr('mock host') : ''), 'bnote');
      return;
    }

    var board = S.store.board;
    var ids = selIds();
    var rw = !S.readOnly;

    /* ---- the AI's preview, which owns the bar while it stands ---- */

    /*
     * It is FIRST, above every other face of the bar, because it is the one
     * state with an outstanding question: four dashed lines are drawn over the
     * board and nothing about them is decided. A selection bar or a link bar
     * standing in front of that would leave Apply and Discard nowhere.
     */
    if (S.proposals && S.proposals.length) {
      /*
       * The count and the two answers, and nothing else. What the dashed lines
       * are and that tapping one drops it is said in the toast that arrives
       * with them - a bar on a 390px phone that also carried the explanation
       * pushed Discard off the end of itself.
       */
      blabel(bar, tr(AI.summary(S.proposals.length)));
      if (rw) bar.appendChild(button('Apply', function () { A.ops.applySuggestions(); }, 'on'));
      bar.appendChild(button('Discard', function () { A.ops.discardSuggestions(); }, 'danger'));
      bar.className = 'one open';
      return;
    }

    /* ---- a colour bar, wherever it was opened from ---- */

    var target = S.linkSel || S.groupSel || (ids.length === 1 ? ids[0] : null);
    if (S.barMode === 'colour' && target) {
      var obj = M.any(board, target);
      optionBar('Colour', A.COLOURS.map(function (c) {
        return swatch(c, obj && obj.c, function () { A.ops.colour(target, c); });
      }).concat([button('None', function () { A.ops.colour(target, null); })]));
      return;
    }

    /* ---- the link bar: four style axes, and the two ends already selected -- */

    if (S.linkSel) {
      var l = M.link(board, S.linkSel);
      if (l) {
        if (S.barMode === 'head' && rw) {
          optionBar('Ends', [['None', 'none'], ['Arrow', 'arrow'], ['Both ends', 'double']].map(function (o) {
            return button(o[0], function () { A.ops.linkStyle(l.i, { h: o[1] }); }, l.h === o[1] ? 'on' : '');
          }));
          return;
        }
        if (S.barMode === 'dash' && rw) {
          optionBar('Line', [['Solid', 'solid'], ['Dashed', 'dashed'], ['Dotted', 'dotted']].map(function (o) {
            return button(o[0], function () { A.ops.linkStyle(l.i, { d: o[1] }); }, l.d === o[1] ? 'on' : '');
          }));
          return;
        }
        blabel(bar, l.t || 'Link');
        if (rw) {
          bar.appendChild(button('Ends', function () { S.barMode = 'head'; drawBars(); }));
          bar.appendChild(button('Line', function () { S.barMode = 'dash'; drawBars(); }));
          bar.appendChild(button('Colour', function () { S.barMode = 'colour'; drawBars(); }));
          bar.appendChild(button('Label', function () { beginEdit(l.i); }));
          bar.appendChild(button('Annotate', function () { A.ops.annotate([{ l: l.i }]); }));
          if (ids.length === 2) {
            bar.appendChild(button('Group', function () { A.ops.group(selIds()); }));
          }
          /*
           * The one action on this bar that leaves the board. It is offered
           * only when both ends really are note cards, because a sticky has no
           * note for a relationship to be about; which of the two it is
           * depends on whether a relationship is already recorded.
           */
          if (noteEnds(l)) {
            if (l.real === true) bar.appendChild(button('Unlink the notes', function () { A.ops.unlinkNotes(l.i); }));
            else bar.appendChild(button('Also link the notes', function () { A.ops.linkNotes(l.i); }));
          }
          bar.appendChild(button('Unlink', function () { A.ops.unlink(l.i); }, 'danger'));
        }
        bar.appendChild(button('Done', function () { clearSel(); redraw(); }));
        bar.className = 'one open';
        return;
      }
    }

    /* ---- the group bar ---- */

    if (S.groupSel) {
      var g = M.group(board, S.groupSel);
      if (g) {
        blabel(bar, g.t || 'Group');
        blabel(bar, tr(g.m.length + ' card' + (g.m.length === 1 ? '' : 's')), 'bnote');
        if (rw) {
          bar.appendChild(button('Rename', function () { beginEdit(g.i); }));
          bar.appendChild(button('Colour', function () { S.barMode = 'colour'; drawBars(); }));
          bar.appendChild(button('Annotate', function () { A.ops.annotate(g.m.map(function (m) { return { i: m }; })); }));
          // One-shot, and it says so when it asks: the frame is a visual
          // convenience and must never quietly keep the library in step with
          // it.
          bar.appendChild(button('Tag these notes', function () { A.ops.tagNotes(g.i); }));
        }
        bar.appendChild(button('Select cards', function () { A.ops.selectMembers(g.i); }));
        if (rw) bar.appendChild(button('Ungroup', function () { A.ops.ungroup(g.i); }, 'danger'));
        bar.appendChild(button('Done', function () { clearSel(); redraw(); }));
        bar.className = 'one open';
        return;
      }
    }

    /* ---- a multi-selection ---- */

    if (S.selectMode || ids.length > 1) {
      if (S.barMode === 'align' && rw) {
        optionBar('Align', [['Left', 'left'], ['Top', 'top'], ['Row', 'row'], ['Column', 'column']].map(function (o) {
          return button(o[0], function () { A.ops.align(o[1]); });
        }), 'sel');
        return;
      }
      blabel(bar, tr(ids.length + ' selected'));
      if (rw && ids.length) {
        var two = ids.length === 2;
        var joined = two ? M.findLink(board, ids[0], ids[1]) : null;
        /*
         * Link and Unlink stand in the same place: with two cards selected the
         * question is always about the line between them, and which of the two
         * it is depends only on whether there is one. Both buttons are SHOWN
         * whatever the count, and pressing one with the wrong number selected
         * says why rather than doing nothing.
         */
        if (joined) bar.appendChild(button('Unlink', function () { A.ops.unlink(joined.i); }));
        else bar.appendChild(button('Link', function () {
          var s = selIds();
          if (s.length !== 2) { toast('Linking joins exactly two cards. ' + s.length + ' are selected.'); return; }
          A.ops.link(s[0], s[1]);
        }, two ? '' : 'off'));
        bar.appendChild(button('Group', function () { A.ops.group(selIds()); }, ids.length >= 2 ? '' : 'off'));
        // Shown whatever is selected, like Link and Group beside it: pressing
        // it with a sticky or a tombstone in the selection says why rather
        // than doing nothing.
        bar.appendChild(button('Merge', function () { A.ops.merge(selIds()); }, ids.length >= 2 ? '' : 'off'));
        bar.appendChild(button('Annotate', function () { A.ops.annotate(anchorsForSelection()); }));
        /*
         * The same one button as on the board bar, and it reads the selection
         * exactly as it does there: with cards selected it considers only
         * those. It is here rather than only on the board bar because a
         * selection is the whole of how "only these" is said, and the board
         * bar is not drawn while there is one.
         */
        bar.appendChild(button('Suggest links', function () { A.ops.suggest(); }, ids.length >= 2 ? '' : 'off'));
        bar.appendChild(button('Align', function () { S.barMode = 'align'; drawBars(); }, ids.length >= 2 ? '' : 'off'));
        bar.appendChild(button('Remove from board', function () { A.ops.remove(selIds()); }, 'danger'));
      }
      bar.appendChild(button('Done', function () { clearSel(); redraw(); }));
      bar.className = 'sel';
      return;
    }

    /* ---- one thing ---- */

    if (ids.length === 1) {
      var id = ids[0];
      var kind = M.kindOf(board, id);
      var face = N.face(board, id, S.cache);
      blabel(bar, face ? (face.title || '(untitled)') : '', 'blabel' + (face && face.tomb ? ' tomb' : ''));

      if (!S.barOpen) {
        bar.appendChild(button('Actions', function () {
          S.barOpen = true;
          drawBars();
        }));
        bar.className = 'one';
        return;
      }
      if (face && face.tomb) {
        blabel(bar, 'This note is gone. Its links stay until you remove the card.', 'bnote');
      } else if (kind === 'note') {
        bar.appendChild(button('Open note', function () { A.ops.openNote(face.noteId); }));
      }
      /*
       * Focus is a way of LOOKING at the board, so it is offered on a board
       * that may not be written to as well - a read-only board is exactly
       * where finding your way around one card matters most.
       */
      if (S.focus === id) bar.appendChild(button('Unfocus', function () { A.ops.unfocus(); }, 'on'));
      else bar.appendChild(button('Focus', function () { A.ops.focus(id); }));
      if (rw && (kind === 'sticky' || kind === 'annot')) {
        bar.appendChild(button('Edit text', function () { beginEdit(id); }));
      }
      /*
       * A sticky's way out of the board. The words are the plan's own - a long
       * press leaves a sticky whose bar offers to make it a note - and the bar
       * is already open when a sticky is first written, so "leave a note here"
       * is a press, some words and one button rather than a discovery.
       */
      if (rw && kind === 'sticky') {
        bar.appendChild(button('Make it a note', function () { A.ops.promote(id); }));
      }
      if (rw && kind === 'annot') {
        var it = M.item(board, id);
        if (it.at && it.at.length) {
          bar.appendChild(button('Detach', function () { A.ops.setAnchors(id, []); }));
        }
      }
      if (rw) {
        bar.appendChild(button('Annotate', function () { A.ops.annotate([{ i: id }]); }));
        bar.appendChild(button('Colour', function () { S.barMode = 'colour'; drawBars(); }));
        bar.appendChild(button('Remove from board', function () { A.ops.remove([id]); }, 'danger'));
      }
      bar.appendChild(button('Done', function () { S.barOpen = false; A.ops.select(null); }));
      bar.className = 'one open';
      return;
    }

    /* ---- the board itself ---- */

    /*
     * The formats there are, listed from the registry rather than written out
     * here: PNG is the only one in v1, and a second writer is one entry in
     * export.js and no change at all to this bar.
     */
    if (S.barMode === 'export') {
      optionBar('Export', EX.formats.map(function (f) {
        return button(f.label, function () { A.ops.exportBoard(f.id); });
      }).concat([noteSpan('The whole board, attached to this note. Exporting again replaces it.')]));
      return;
    }

    // The + the plan asks for: the native picker, and the chosen notes land in
    // the middle of what is being looked at.
    if (rw) bar.appendChild(button('+ Add notes', function () { A.ops.addNotes(); }));
    /*
     * One button, and it looks at the selection - which on this face of the
     * bar is empty, so it considers every note card on the board. It is shown
     * whether or not a model is reachable: pressing it with none says so, and
     * a button that vanished on some devices would be a feature the board
     * appeared to have lost.
     */
    if (rw) bar.appendChild(button('Suggest links', function () { A.ops.suggest(); }));
    /*
     * Export is offered on a read-only board too, and deliberately.
     *
     * Read-only means the BLOCK cannot be written - another session saved a
     * different one, the note holds two, the format is newer. A picture is a
     * read of the board and a write to the note's ATTACHMENTS, which none of
     * those refusals is about; and a board you cannot save is exactly when
     * having a picture of it matters most.
     */
    bar.appendChild(button('Export', function () { S.barMode = 'export'; drawBars(); }));
    // One way out of both kinds of dimming, wherever it came from.
    if (dimming()) {
      bar.appendChild(button('Show everything', function () {
        A.ops.endSearch(true);
        A.ops.unfocus();
        relight();
        redraw();
      }, 'on'));
    }

    var s = BOARD.summary(S.store.board);
    var summary = I18n && I18n.language === 'zh-CN'
      ? (s.notes + s.stickies) + ' 张卡片' +
        (s.links ? ' · ' + s.links + ' 条链接' : '') +
        (s.groups ? ' · ' + s.groups + ' 个分组' : '') +
        (s.annots ? ' · 边栏中 ' + s.annots + ' 条批注' : '') +
        (S.tombstones ? ' · ' + S.tombstones + ' 项缺失' : '') +
        (S.noTags ? ' · 标签不可用' : '') +
        (S.readOnly ? ' · 只读' : '') +
        (HOST.isMock ? ' · 模拟宿主' : '')
      : (s.notes + s.stickies) + ' card' + ((s.notes + s.stickies) === 1 ? '' : 's') +
        (s.links ? ' · ' + s.links + ' link' + (s.links === 1 ? '' : 's') : '') +
        (s.groups ? ' · ' + s.groups + ' group' + (s.groups === 1 ? '' : 's') : '') +
        (s.annots ? ' · ' + s.annots + ' note' + (s.annots === 1 ? '' : 's') + ' in the margin' : '') +
        (S.tombstones ? ' · ' + S.tombstones + ' missing' : '') +
        // Said once, quietly: the cards are right, their chips are missing.
        (S.noTags ? ' · tags unavailable' : '') +
        (S.readOnly ? ' · read-only' : '') +
        (HOST.isMock ? ' · mock host' : '');
    blabel(bar, summary, 'bnote');
  }

  // Opening a note is a host call, not a board edit: nothing is written, and
  // the board is exactly as it was when the user comes back. Every reach for
  // the Synapse object lives in host.js, including this one.
  A.ops.openNote = function (id) { return HOST.openNote(id); };

  /* ==================================================================== */

  /*
   * Leaving with an edit still inside the debounce window.
   *
   * What can honestly be done here: start the save now, and KEEP the promise.
   * Dropping it meant a refusal - a conflict, a damaged block - was discovered
   * and thrown away with nobody told; held, it still reaches onSaveRefused, and
   * a save that follows it queues behind it in host.js rather than racing it.
   *
   * What cannot: neither platform will WAIT. The write is an asynchronous
   * bridge call into Flutter, there is no sendBeacon equivalent for it and no
   * synchronous write of any kind, so a WebView that is torn down between the
   * call and its answer loses that edit. `visibilitychange: hidden` is the last
   * event both platforms deliver reliably - iOS often never fires `pagehide`
   * for an app going to the background at all - which is why the flush hangs
   * off it and `pagehide` is only a second chance at the same thing. The
   * exposure is the size of the debounce: up to 900ms of edits, 2600ms of
   * camera. It is not nothing, and it is not closable from in here; a shorter
   * debounce would trade it for a note rewritten on every dragged card.
   */
  A.ops.flush = function () {
    if (S.saveTimer) { clearTimeout(S.saveTimer); S.saveTimer = null; }
    if (!S.dirty || S.readOnly || !S.session) return Promise.resolve(null);
    var p = A.ops.save();
    S.flushing = p;
    return p.then(function (r) {
      if (S.flushing === p) S.flushing = null;
      return r;
    }, function (e) {
      if (S.flushing === p) S.flushing = null;
      S.lastSaveError = String((e && e.message) || e);
      return null;
    });
  };

  if (typeof global.addEventListener === 'function') {
    global.addEventListener('synapse:localechanged', function (event) {
      if (I18n) I18n.setLanguage((event && event.detail) || (global.Synapse && global.Synapse.locale));
      applyStaticLanguage();
      if (!S.booted) return;
      if (S.mode === 'home') {
        if (el.title) el.title.textContent = tr('Big Bang');
        drawHome();
      } else {
        redraw();
      }
    });
    global.addEventListener('visibilitychange', function () {
      if (!global.document || global.document.visibilityState !== 'hidden') return;
      // A box with the caret in it holds text that is not in the board yet.
      // Committing it first is what puts it INTO the flush rather than after
      // it, where the app going away would take it with it.
      if (S.editing) commitEdit();
      A.ops.flush();
    });
    global.addEventListener('pagehide', function () {
      if (S.editing) commitEdit();
      A.ops.flush();
    });

    /*
     * A resize has exactly one job here, and it is not redrawing.
     *
     * A keyboard appearing is reported as a resize on Android and as a
     * visualViewport change on iOS; a rotation is reported as a resize on both.
     * Neither is a reason to draw anything. The scene is ONE transform over a
     * plane of board coordinates, and deco() reads the zoom and those
     * coordinates and nothing else - not the viewport, not a rectangle - so a
     * window that changed shape has changed nothing deco could answer
     * differently. (It used to be called behind a width test, on the reasoning
     * that a keyboard never changes the width and a rotation does. The test was
     * true and the call it guarded was dead, and with lastWidth starting at 0
     * the first resize always claimed a change anyway.)
     *
     * What a resize genuinely changes is where the visible band IS, which
     * matters only while something is being typed into.
     */
    global.addEventListener('resize', function () {
      if (!S.booted || !el.stage) return;
      if (S.editing) A.ops.keepVisible();
    });

    var vv = global.visualViewport;
    if (vv && vv.addEventListener) {
      vv.addEventListener('resize', function () { if (S.editing) A.ops.keepVisible(); });
      vv.addEventListener('scroll', function () { if (S.editing) A.ops.keepVisible(); });
    }
  }

  if (typeof module !== 'undefined' && module.exports) module.exports = BB;
})(typeof window !== 'undefined' ? window : globalThis);
