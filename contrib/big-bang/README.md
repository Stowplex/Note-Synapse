# Big Bang

A canvas you throw notes onto. Notes become cards you can place, link,
annotate, group and merge — spatial thinking over the notes you already have,
with the board itself stored as an ordinary note.

Nothing here rewrites a note's body. The board's geometry lives in one fenced
```synapse-bigbang block appended to whichever note you opened as a canvas; the
prose above it reads exactly as it did before, and a board you empty removes
its own block again.

## Why it is not a mind map

Cartograph, the other spatial app that ships with Note Synapse, turns *one*
note into a map of its own headings and bullets: the markdown is the map, and
editing the map edits the markdown. Big Bang is the other axis — *many* notes
on one plane, with a structure that exists **between** notes and belongs to
neither of them.

| | Cartograph | Big Bang |
|---|---|---|
| subject | one note's outline | many notes' relationships |
| source of truth | the note's markdown | the board note's fenced block |
| a node / card is | a heading or a bullet | a whole note, or a sticky |
| layout | automatic, pinnable | entirely manual |
| edits notes? | constantly, that is the point | only when you ask it to |

That difference decides most of the rest:

- **A card is a reference, not a rendering.** It shows the note's live title, a
  two-or-three-line excerpt stripped of markdown syntax, its tag chips, and a
  checkbox if the note is a task. Rename the note elsewhere and the card is
  right the next time the board opens.
- **Drawing a link costs nothing.** No approval dialog, no write to a note — a
  line between two cards is board decoration. Promoting it into a real note
  relationship is a separate, deliberate act with its own button.
- **Nothing disappears on its own.** A card whose note has been deleted becomes
  a tombstone — dashed outline, a **MISSING** chip, the last title anybody saw
  struck through — with *Remove from board* on its bar. Its links stay exactly
  as they were until the card goes.

## The two apps

One HTML file, emitted twice by `plugins/build.sh` and told apart at runtime by
whether `Synapse.Notes` is empty. No build flag, no code fork.

| | |
|---|---|
| **Big Bang** (`normal`) | Opens on the board home: recent boards, *New board*, *Open another note as a board*. Can be put in the main screen's multi-function slot. |
| **Big Bang: this note** (`note_action`) | One note selected → that note **is** the canvas. Several selected → a new board holding all of them, laid out on a grid. |

The note action is what "throw notes into the board" means from outside:
`notes_screen.dart` already hands a note-action app the whole multi-selection,
so N notes arrive with no host change.

Query parameters the host passes through as `Synapse.Params`:

| parameter | effect |
|---|---|
| `?board=<noteId>` | open that note as the board |
| `?mode=embed` | the read-mostly inline embed |
| `?standalone=1` | force the home, even with a note in hand |

The embed is what
`@[100% x 480](synapseresource://app/<uuid>?note=current&mode=embed)` renders: a
board inside its own note, with pan, zoom and *tap a card to open its note*.
Every bar is gone, and every edit is refused in the app rather than merely
hidden.

## The board note

### The block

Appended to the note, written on one line, removed again when the board is
emptied. A note that has never been a board is indistinguishable from one that
was and got cleared.

````markdown
# Sprint planning

We agreed to cut scope on…

```synapse-bigbang
{"v":1,"view":{"p":[0,0],"z":1},
 "items":{
   "n7":{"k":"note","id":"a1b2…","p":[120,-40],"w":220,"c":"blue"},
   "s2":{"k":"sticky","t":"call the vendor","p":[300,80],"w":180,"c":"amber"},
   "a5":{"k":"annot","t":"needs a source","p":[24,-56],"at":[{"i":"n7"}],"q":[144,-96]}},
 "links":[{"i":"l1","a":"n7","b":"s2","h":"arrow","d":"solid","c":"amber","t":"feeds","real":true}],
 "groups":[{"i":"g1","t":"Pricing","m":["n7","s2"],"c":"green"}]}
```
````

| field | meaning |
|---|---|
| `v` | schema version. A higher one is refused loudly rather than half-read. |
| `view` | last pan and zoom, so reopening lands where you left it. |
| `items` | everything on the plane, keyed by a board-local id. `k` is `note`, `sticky` or `annot`. |
| `items[].id` | for `k:"note"`, the real note id. Title and excerpt are resolved **live**; `t` is only the last title anybody saw, and a live read always wins. It is what labels a card before the first read comes back, and what labels a tombstone after the note is gone. |
| `items[].at` | for `k:"annot"`, what it points at: `{i:<itemId>}` or `{l:<linkId>}`, several allowed. `p` is an offset from the first anchor; `q` is the last absolute spot, so it holds position if that anchor disappears. |
| `links` | `a`/`b` endpoints (any two items), `h` head, `d` dash, `c` colour, `t` label, `real` whether a note relationship backs it. |
| `groups` | `m` members, `t` name, `c` colour. Frames are not items and cannot be link endpoints. |

Ids are board-local and stable. They are what links, groups and annotations
name, which is why renaming or moving a card breaks nothing.

### Writing it safely

Big Bang holds a note you may also be editing in the real editor, so **every
save re-reads the note first** and splices only its own block into the *fresh*
text. An outside edit to the body survives untouched and is never mentioned:
the two edits do not overlap.

Six things are refused rather than written over. Three of them offer a second,
explicit yes on a button you press; the other three have no safe thing to
offer, so the board stays read-only until the note is sorted out elsewhere:

| refusal | what it means | way out |
|---|---|---|
| `conflict` | the note now holds a **different** board block — another Big Bang session saved in the meantime. The question names card and link counts, never JSON. | *Keep mine* |
| `malformed` | a hand-damaged block, or one whose closing fence is gone. Its span is a guess, and a save that replaced a guess is how the prose under a half-deleted fence disappears — so an unterminated block claims only as far as the first blank line. | *Replace the damaged block* |
| `extra` | the note holds more than one board block. Only the first is ever read, so saving would drop the others. | *Keep only the first block* |
| `read-only` | the block was written by a **newer version** of Big Bang. Its fields are never interpreted, so there is nothing to write back that would not lose them. | none |
| — | the note **ends inside somebody else's unclosed code fence**. A block appended there would be part of that fence, invisible to the next open, which would then append another beside it. | none |
| — | the note **documents the board format inside a wider fence** and has no board of its own. What looks like this note's board is not the block that would be written, and adding one beside the example is confusing rather than helpful. | none |

A failed read **aborts the save**. There is no fallback to a remembered copy,
because the write is a whole-body replace and one written from a stale snapshot
would destroy whatever you typed in the real editor meanwhile.

## On the canvas

### Cards

- **Note card** — title, excerpt, tag chips, and a task checkbox when the note
  is a task. Tap selects; tap again opens the action bar. Cards are
  width-resizable by the grip on their right edge.

  The checkbox is a control as well as a marker: tapping it asks, through the
  ordinary approval banner, and then writes the note's `status`. It is the only
  card-face element that writes anything, and nothing about the *board* is
  marked unsaved by it — what changed is the note, and the card re-reads it.
- **Sticky card** — a text box that lives only in the board. Long-press the
  background to leave one and type straight into it. Its bar offers **Make it a
  note**, which creates a real note and swaps the sticky for a note card in one
  undo step.
- **Annotation** — a light text box joined to what it points at by a thin
  dotted straight line, deliberately unlike a link's bowed curve. It can point
  at a card, a link, or several at once. Left unattached it just floats.

### Links

Drag from a card's bottom-centre port onto another card, or select exactly two
cards and tap **Link**. Either end may be any item kind, so a sticky can
annotate the relationship between two notes.

A link's midpoint carries a counter-scaling 44px handle — a 1.7px curve is not
a touch target — and tapping it selects both ends. Its bar carries the four
style axes (**Ends**, **Line**, **Colour**, **Label**) and:

- **Also link the notes** — writes a real note relationship and marks the line
  with a solid dot. Only offered when both ends are note cards.
- **Unlink the notes** — removes that relationship and leaves the drawn line
  alone. It removes the relationship in **both directions**, which is what the
  host's own delete does, so it takes out a link the merge screen wrote as
  readily as one Big Bang did; the question says so.
- **Unlink** — deletes the board line. If a real relationship stands behind it,
  the banner asks first and defaults to *Remove the line only*: the note link
  outlives the drawing. *Remove both* is beside it.

### Groups

Select several cards and tap **Group**, or drag a card onto another **by the
group handle** at its top edge. That handle is what tells the two card-on-card
gestures apart: dragging the card body onto another note is a *merge*, dragging
this distinct 44px target onto any card makes a *group*. There is no modifier
key on a phone, so the choice lives in the thing under your thumb.

A group is a named, coloured frame. Dragging its tab moves every member. The
frame itself takes no pointer events — a frame is mostly empty canvas, and one
that swallowed taps would make the space inside it the one place a sticky could
not be long-pressed into being.

**Tag these notes** applies a tag of the group's name to every note member,
through the ordinary approval dialog. It is a one-shot action, not a binding:
renaming the group afterwards does not rename the tag, and ungrouping never
removes it.

### Merging

Dropping one note card onto another opens the app's **real merge screen**
(`Synapse.openMerge`), not a copy of it. So does **Merge** on a multi-selection
of note cards.

When it comes back with a merged note, the board removes the source cards and
places one card for the result, repointing every link, anchor and group
membership at it. One undo step. The merge screen's *Replace note A* mode hands
back one of the ids that went in, so the board treats the answer as an
**upsert**: if the merged id is already on the board, that card keeps its place
and only the *other* sources go.

Refusals are stated rather than silently ignored. A selection containing a
sticky, an annotation or a tombstone cannot merge, because those are not notes.
But **dropping** a card onto a sticky or an annotation is an ordinary move: a
card dropped on a canvas object has landed on the canvas, not been offered for
merging. Dropping onto a tombstone is refused out loud, because that one really
is a note card and the reason it cannot merge is not visible from the drop.

A merge cannot be un-merged, so if the board has gone read-only in the meantime
the substitution is applied in memory anyway, the badge says *not recorded*, and
the banner says the notes really are merged, why the board could not follow, and
keeps the escape hatch that would write it.

### Gestures

| gesture | effect |
|---|---|
| drag background | pan |
| pinch | zoom |
| double-tap background | fit the whole board |
| tap card | select; tap again opens its bar (a sticky or annotation opens for typing) |
| long-press card | start a multi-selection |
| drag card | move it, or the whole selection |
| drag card **onto another note card** | merge |
| tap the **group handle** | says what it is for |
| drag the **group handle** onto another card | group the two |
| drag the **link port** onto another card | draw a link |
| drag the **width grip** | resize the card |
| drag a group's tab | move every member |
| long-press background | leave a sticky here |
| drag to the bin | remove from the board (the note is never deleted) |
| tap a task checkbox | ask, then write the note's status |

## Search, focus, undo

- **Search** highlights matching cards, links and groups and dims the rest —
  by opacity alone, on every kind of object, so a dimmed card is still there,
  still draggable and still openable. It is a way of *looking* at a board, not
  a filter that removes half of it. Nothing about a search touches the note.
- **Focus** on a card brings its immediate neighbourhood into view and dims
  everything not connected to it: every link touching the card and whatever is
  at the other end, plus the annotations pointing at any of them. A group's
  *other* members are deliberately not lit — the frame already says where they
  are, and lighting them would make focus on a big group mean nothing.
- **Undo/redo**, 50 steps, over board edits only. A multi-card drag, an applied
  set of AI suggestions and a merge substitution are each *one* step. Note
  writes — real relationships, tagging, promote-to-note, ticking a task — are
  not undoable from here, and the app says so rather than pretending.

## Suggesting links with AI

**Suggest links** is the only AI feature there is. With cards selected it
considers only those; with nothing selected, every note card on the board, up
to a cap of 40 — a request is one request whatever the board's size. At most
12 pairs are ever previewed at once, however many come back: a board covered in
dashed lines is not a preview, it is a second board.

The request carries each card's title and a bounded excerpt — the same
excerpts the cards already show, truncated again — plus the links that already
exist, and asks for pairs that are related with a short relationship label.
`chatAI` answers with plain text; there is no JSON mode and no schema mode, so
the expected form is one line per pair and **lines that do not parse are
dropped rather than failing the batch**.

Nothing is drawn as fact. Proposals appear as **dashed accent lines with their
labels**, with a summary (*"4 links suggested"*) and **Apply** / **Discard**.
Tapping one drops it. Apply is one undo step. Pairs that are already linked,
pairs naming a card that is not on the board, pairs repeated in either
direction and pairs of a card with itself are all discarded before anything is
drawn.

A suggestion is **not board state**: it does not mark the note unsaved, it is
never written to the block, there is nothing to undo, and discarding leaves no
trace.

**The board is fully usable with AI switched off.** A host with no `chatAI`, a
refusal, a timeout and an answer containing no usable line all end the same
way — a stated *"Nothing to suggest: …"* with the reason — and never a broken
board.

Everything a note says reaches the model wrapped in the host's own
`<DATA_ONLY_DOCUMENT>` markers, with that marker's name stripped out of the
text first so a note cannot close it early and start giving instructions. The
one thing in a request that is *not* fenced is a card's board id — it has to
be, because it is the one thing the model is meant to read as an instruction —
so an id that is not plainly an id (a hand-written block may name an item
anything at all) leaves its card out of the request, and the refusal says how
many were left out.

## Exporting the board as an image

**Export** on the board bar opens a list of the formats there are. Today that
is **PNG**; the list is built from a registry, so another writer slots in
without touching anything around it.

- **The whole board, always.** Every card, link, annotation and group — focus
  lifted, search ignored, nothing dimmed. The scene is built from the board's
  own coordinates and never looks at the camera, so exporting a focused or
  searched board still exports all of it.
- **Always light and opaque**, whatever the phone's theme, so the picture reads
  in a chat, in a document or on paper.
- **Attached, not inserted.** The file lands on the board note as
  `<Title> — board.png`, through the same approval as any other write.
  **Exporting again replaces** the previous file in the same call rather than
  piling up.
- **Rendered on the phone.** Drawn as SVG made of nothing an `<img>` cannot
  render — rects, paths and wrapped text; no `foreignObject`, no CSS, no fonts
  to load — and rasterised on a canvas at 2×, **capped** so a very large board
  is scaled to fit the WebView's canvas ceiling rather than coming out blank.
  The toast says so when it scales.
- **Offered on a read-only board**, and refused while AI suggestions are
  standing. Read-only is about the *block*, and a picture is a write to the
  note's attachments rather than to it — a board you cannot save is exactly
  when a picture of it matters. A suggestion, on the other hand, is not part of
  the board, so it is applied or discarded first rather than quietly left out
  of the picture.

Three layers, so a new format is one function and a new destination is another:
a pure **scene** (`BB.export.scene`), a **writer** per format
(`BB.export.register({ id, label, ext, mime, write })`), and one **sink** that
attaches.

Two things worth knowing if you touch the sink.

The host **renames every file it saves** to `<stem>_<uuid><ext>` — so what is
actually stored on the note is `<Title> — board_<uuid>.png`. The file is
therefore always *sent* under its original name. Echoing the stored name back
grows a second uuid on every save, and a name that grows a uuid per export is a
name no later export recognises.

And a previous export is recognised by the **suffix**, `<anything> — board`,
never by this board's current stem. The stem is built from the note's title and
a note can be renamed: matched on the title, the old picture is orphaned, a
second lands beside it, and every later rename adds another. The same window
opens for a moment on a `?board=<id>` launch, where the title is not known
until a query returns. What the test must never become is a prefix match on the
stem, which would sweep up — and then delete — a user's own file that happened
to begin with the note's name.

### What the picture is not checked for

The rasterised PNG is asserted on its signature and its size; the LAYOUT is
asserted on `BB.export.svg`, which is a plain string built with no DOM (line
breaks, `dy` per line, wrapped lines measured against their box, the clamp's
ellipsis, chip rows, a dot per real link, and the label's centre against the
curve at t = 0.5). Nothing in the suite can look at the rendered image, and two
things follow from that which are stated here rather than pretended about:

- **Right-to-left text rasterises but is not laid out for.** Every line is
  anchored left with no `direction` or `text-anchor` flip, so an Arabic or
  Hebrew card draws its text in the correct glyph order and the wrong place in
  its box.
- **A clamped CJK line overflows its box by the width of the ellipsis.** The
  clamp retreats to a space before appending `…` (`export.js`, `EX.block`); a
  run of CJK has no spaces to retreat to, so the line — already wrapped to
  exactly the box — keeps its last character and the ellipsis goes on the end.
  In a note card's 196px of text the wrapped line measures 196.0 and the
  clamped one 203.7 under the node estimate, ~198.6 with a real font. It
  overhangs the card rather than wrapping.

Both need eyes on a rendered picture. Neither is asserted, and neither should
be pretended to be.

## Safety

- The note's **body is never touched**. Only the app's own fenced block is
  spliced, into text re-read immediately before the write.
- **Every write to somebody else's note is asked for first**, in words, naming
  the notes — promoting a sticky, writing a relationship, tagging a group,
  ticking a task. `saveNotes` has no approval gate at all and `updateNotes`
  asks once per session and then stops, so the app puts the question itself.
- **What the host actually did is read back.** `success: true` only means the
  call ran; `updatedCount` says how much of it landed and `errors` says what did
  not. A batch that tagged four notes of five says four, and says why the fifth
  is missing.
- **A card leaving the board never deletes a note.** The app does not use
  `deleteNotes`, and does not reach the network at all.
- **Every string from a note or a model reaches the document as text.** Titles,
  excerpts, sticky text, tag names, link labels and AI labels are all set with
  `textContent`. Exactly two values reach CSS: a board colour, as a *name*
  stripped to letters (so `red;background:url(x)` becomes a class that names no
  rule), and a tag's colour, only when it parses as a plain hex. In the export,
  every string is escaped on its way into the SVG and a colour that is not one
  of the eight names becomes no colour at all.

## What it does not do

Stated rather than left to be discovered:

- **No image or attachment cards.** A card is a note, a sticky or an
  annotation.
- **Tag chips are drawn but not searched.** Search looks at titles, excerpts,
  sticky and annotation text, link labels and group names.
- **No virtualisation.** Every card on a board is an element. There is no cap
  on board size, and a board of several hundred cards has not been tuned for.
- **A promoted sticky's note carries no back-link** to the board it came from.
  It would be a write to a note nobody asked for.
- **PNG is the only export format**, and the only export destination is an
  attachment on the board note.
- **One AI feature.** No clustering, no board generation, no summarising.
- **The board home finds boards with `content LIKE '%synapse-bigbang%'`**, so a
  note that merely quotes the format in prose is listed as a board; its card
  count is derived the same way and is an estimate in one direction.
- **A save is debounced** — 900ms after an edit, 2600ms after a pan or zoom.
  A WebView torn down inside that window loses those edits. `visibilitychange`
  flushes what it can, but neither platform will wait for an asynchronous
  bridge call, and there is no synchronous write to fall back to.

## Development

```
plugins/
  big-bang.html     # shell: design tokens, DOM, module tags
  src/board.js      # the fenced block: scan, parse, serialise, splice, migrate
  src/model.js      # items, links, groups; ids; search; the undo stack
  src/host.js       # the Synapse bridge, and an in-memory mock for the browser
  src/notes.js      # resolving cards to live notes, excerpts, tombstones
  src/render.js     # canvas rendering, hit-testing, counter-scaled handles
  src/gestures.js   # pan/zoom/drag/multi-select, drop targets
  src/ai.js         # the link-suggestion prompt, answer parsing, proposals
  src/export.js     # scene → writers (the attach sink is in app.js)
  src/app.js        # state, bars, banners, the home screen
  build.sh          # inlines src/*.js into BOTH installable yamls
dev/
  harness.html      # drive the real app in a desktop browser
  auto_smoke.html   # module assertions in the browser
  app_smoke.html    # boots the app in iframes and asserts the written block
  run.js            # the same module assertions under node
  build_check.js    # asserts the two installable YAMLs
  spec.js           # shared assertions
  fixtures/*.md
```

`build.sh` inlines the modules in load order — `board` first, because every
other module reads its coercions at load time — and both YAMLs carry the same
base64. `test/contrib_big_bang_test.dart` pins that round-trip, so a source
change without a rebuild fails the Dart test.

### The mock

With no Flutter bridge present, `host.js` installs an in-memory note store, so
`plugins/big-bang.html` opens and works in an ordinary browser. It is
deliberately unfriendly in the places the real host is: `runQuery` returns at
most 100 rows and says so, an empty content `replace` clears a note, the
attachment store renames what it is given, an attachment path the store does
not know is refused, and a task status it does not recognise becomes `todo`.

It is **not** faithful about one column: it stores `notes.updatedAt` as an ISO
string, where the real schema has it as an INTEGER of milliseconds. So the board
home shows "2 hours ago" under each board in the harness and nothing at all on a
phone. The ordering is right either way; only the subtitle is missing.

| parameter | effect |
|---|---|
| `?board=<urlencoded markdown>` | seed the mock note (`mock-note-1`) with that markdown |
| `?seed=[{id,title,content}]` | the *other* notes in the store — the ones a board's cards point at |
| `?boardId=<noteId>` | reaches the app as `Params.board`: open that note as the board |
| `?notes=a,b,c` | arrive as a note-action launch on a multi-selection |
| `?standalone=1` | drop the note, which is how a `normal` launch arrives |
| `?mode=embed` | the read-mostly embed |

`board` is the one name the two interfaces disagree about: on the URL it is the
harness's own control (the markdown to seed), and to the app it is a note id.
So the harness spells the app's one `?boardId=`.

Everything the host would answer with a screen is **scripted, not simulated** —
canned answers, so a *bad* one can be asserted on.

Five of the six hooks read the same way: **a function** (called with the
arguments) **or an array** (consumed one answer at a time, falling through to
the mock's own behaviour when it runs out). A bare object assigned to one of
those is silently ignored — wrap it: `window.__BB_UPDATE__ = [{…}]`.
`__BB_AI__` is the exception, and takes a bare value as well.

| hook | scripts |
|---|---|
| `window.__BB_AI__` | `chatAI`. A bare string is the response and stands for every call; an object is the whole reply (`{success:false,error}`); an array is consumed one answer at a time; a promise is an answer that has not arrived, which is how a timeout is driven. |
| `window.__BB_PICK__` | `pickNotes`. The answer is a list of ids, a list of `{id,title}`, or one of the host's own replies (`{cancelled:true}`, `{success:false,error:'no_ui'}`) — and may be a promise, so the picker stays open until the test says otherwise. |
| `window.__BB_MERGE__` | `openMerge`, including a cancel, an error, and **the id of a source** — the case a board gets wrong by adding a second card for a note it already draws. |
| `window.__BB_UPDATE__` | `updateNotes`, so `{success:true, updatedCount:0}` can be asserted on. |
| `window.__BB_SAVE__` | `saveNotes`, including an answer with no `savedNoteIds`. |
| `window.__BB_QUERY__` | `runQuery`, for a read that fails mid-suite. |

`mock.outsideEdit(fn)` runs just before the next read, which is how a test puts
a concurrent editor between a load and a save.

### Running the suites

```bash
node dev/run.js                              # module assertions, no browser
node dev/build_check.js                      # the two installable YAMLs
./plugins/build.sh                           # regenerate both YAMLs
python3 -m http.server 8781 --directory .    # then open dev/harness.html
node dev/chrome.js dev/app_smoke.html        # the app, in headless Chrome
node dev/chrome.js dev/auto_smoke.html
```

`dev/chrome.js` exists because an ad-hoc `chrome --dump-dom` lies, in four ways
this build actually walked into:

- **A dump is not a result.** The pages ship with `<div id="sum">running…</div>`
  in their markup, so a run that never finished still has a summary div, still
  has no failure rows and still exits 0. So the summary has to parse as a real
  `N/N` count, the count has to be non-zero, and it has to reach a **per-page
  floor** — a run cut off two thirds of the way through is a failure, not a
  smaller pass. Raise `FLOORS` when a page really grows; never lower it to make
  a run go green.
- **Chrome writes the dump when `--virtual-time-budget` expires and then never
  exits.** A runner that waits for the process is killed by a timeout with an
  empty file. So the dump is polled until its size stops changing, and only then
  is the browser killed.
- **A reused `--user-data-dir` serves the plugin's own source out of the HTTP
  cache**, so a change to `src/*.js` may not be in the run at all — which makes
  a mutation look killed when nothing tested it. Every run gets a fresh profile
  directory.
- **The real-time ceiling must not track the virtual budget.** A page holding an
  outstanding fetch pauses virtual time indefinitely, so the budget never
  expires and the dump is never written; `BB_MAX` is real milliseconds.

Two more headless caveats shape how the browser suites are written:

- **CSS transitions never advance under a virtual time budget**, so a painted
  rectangle would sit frozen at the start of a transform that has already been
  applied. Assertions about where something ended up therefore use the app's own
  geometry — `BB.app.itemScreenRect(id)`, `BB.render`'s boxes — never
  `getBoundingClientRect()`. This app's stylesheet declares **no transitions at
  all**, partly for that reason: a drop target that is mid-animation is a drop
  target that misses. The few places the suites do measure the DOM — the bin,
  a link handle — are ones that are positioned outright rather than animated
  into place.
- **A script-assigned `iframe.src` deadlocks**: virtual time pauses for the
  navigation and the navigation waits for virtual time. `app_smoke.html` writes
  every frame with `document.write` during parse instead.

Env: `BB_PORT`, `BB_BUDGET`, `BB_MAX`, `BB_MIN` (override the floor for one
run — for bisecting, not for CI), `CHROME`.

### Host additions this app needed

Two, both generic; nothing in Dart knows what a board is.

- `Synapse.openMerge(noteIds)` — opens the existing merge screen and reports
  what came back: `{success, mergedNoteId}` or `{success, cancelled:true}`.
  Fewer than two resolvable notes is refused before a screen opens.
- `Synapse.saveNotes` returns `savedNoteIds`, so a card created on the canvas
  can become a real note in one call.

Both are documented in `assets/prompts/user_app/api_documentation.md`.

## Licence

Apache-2.0.

Big Bang does **not** ship with Note Synapse. It is not in
`assets/starter/apps/`, and this line used to say it was — copied from
Cartograph's README, where it is true. Install it the way any contributed app
is installed: run `plugins/build.sh` and import the two YAMLs it writes, or
import the ones already committed under `plugins/`.
