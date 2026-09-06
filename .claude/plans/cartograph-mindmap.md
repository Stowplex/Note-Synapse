# Cartograph — a deterministic, editable mind map for markdown notes

> **Status: built and shipping.** `contrib/cartograph/`, plus
> `assets/starter/apps/Cartograph.yaml` (uuid `96d13a4a-3c59-4e2c-9522-0dfee4101da0`).
> No Dart changed. 46/46 module assertions and 25/25 app-level assertions pass.
> See *What shipped* at the end for where the build diverged from this design.

A Note Action user app that turns the current note's markdown into a live,
editable mind map. **No AI.** The note's markdown stays the source of truth;
every map edit is a markdown edit.

Supersedes nothing: the existing AI/Mermaid `Mindmap` starter app keeps
shipping. Cartograph is a new app with a new uuid.

---

## 1. Identity & packaging

| | |
|---|---|
| Name | **Cartograph** |
| `app_type` | `note_action` |
| uuid | fresh v4 (not `7105800a-…`) |
| Author / License | Bruce Li / Apache-2.0 (bundled starter apps are Apache-2.0; confirm) |
| Libraries | **none** — hand-rolled SVG. `d3` is available via `synapse://d3.min.js` but is not needed and costs ~280KB in the yaml payload |

Layout:

```
contrib/cartograph/
  LICENSE
  README.md
  plugins/
    cartograph.html      # the whole app, self-contained
    cartograph.yaml      # installable user app (base64 of the HTML)
    build.sh             # regenerates the yaml from the HTML
  dev/
    harness.html         # mock Synapse bridge, drives the app in a browser
    auto_smoke.html      # headless-Chrome assertions (parse/round-trip/layout)
    fixtures/*.md
assets/starter/apps/Cartograph.yaml   # copy of the built yaml
```

Starter apps are discovered by scanning `assets/starter/apps/` (already in
`pubspec.yaml`), so dropping the yaml in is the whole registration step.

---

## 2. Surfaces

1. **Full screen** — the note action. Primary surface.
2. **Inline embed** — `@[100% x 420](synapseresource://app/<uuid>?note=current&mode=embed)`
   renders the map inside the note itself. `Synapse.Params.mode === 'embed'`
   switches on a read-mostly compact mode: pan/pinch/collapse/focus, tap-to-open
   for note cards, and an ⤢ button that hands off to the full screen app.
   No editing chrome, no bottom bar.
3. **Block scope** — falls out for free. When launched on a selection the host
   hands us a transient note whose `content` is just that range
   (`isBlockScope: true`); our writes splice back into that range. Only
   difference in our code: skip the external-change check (§10) since there is
   no database row to read.

---

## 3. Markdown → map

### 3.1 What becomes a node

| Markdown | Becomes |
|---|---|
| note title | root node |
| `#` … `######` | node, nested by heading level |
| `-` / `*` / `+` / `1.` list item | node, nested by list indent, child of enclosing heading |
| `- [ ]` / `- [x]` | node with a checkbox |
| paragraph, code fence, table, blockquote, image, raw HTML | **body** of the nearest node in scope |

Body attachment rules:

- A block in a heading's region *before* any list → body of the heading node.
- A block indented under a list item (continuation) → body of that item.
- A block *after* a list, back at heading level → body of the heading node,
  recorded with its order index so the round-trip puts it back where it was.

Body is shown as a small `¶` / `⟨⟩` / `▦` affordance on the card; tapping
expands the rendered body in a sheet.

### 3.2 Node model

```js
{
  id,          // session-stable, short; persisted only in the sidecar
  kind,        // 'root' | 'heading' | 'item'
  level,       // heading level 1-6, or list depth
  marker,      // '-', '*', '+', '1.' — preserved verbatim on rewrite
  text,        // inline markdown of the label
  checkbox,    // null | false | true
  body: [ {span, type} ],
  children: [],
  span: {start, end},   // byte range in the source markdown
  links: [],   // {type:'note'|'anchor'|'external', target, label}
}
```

### 3.3 Round-trip guarantee

Every node carries its **source span**. An edit rewrites only the spans it
touches and splices; untouched bytes come through byte-identical. We never
re-serialize the whole document. This is what makes "the note is the source of
truth" actually safe — reordering a bullet cannot silently reformat a code
fence three sections away.

Invariant enforced by `auto_smoke.html`: for every fixture,
`serialize(parse(md)) === md`.

---

## 4. The sidecar block

Minimal, optional, and **the map lays out correctly without it**.

````
```synapse-cartograph
{"v":1,"n":{"a3f":{"p":[420,-180],"k":"2:project/design","t":"design"},
            "b7c":{"c":1,"k":"3:project/design/colors","t":"colors"}}}
```
````

- Written as the last block of the note. Omitted entirely when empty.
- Only nodes that carry state appear: `p` = pinned `[x,y]` (rounded ints),
  `c` = collapsed. `k` = normalized path key, `t` = normalized text — both
  exist *only* to re-find the node, not to describe it.
- Cross-links are **not** in here. They are ordinary markdown links (§7).
- Colors are **not** in here. Branch tint is derived from branch index.

### 4.1 Re-matching ids after an outside edit

On load, parse markdown → tree → assign each node a path key. Then, in order,
each sidecar entry claims a node:

1. exact `k` match
2. exact `t` match among unclaimed nodes at the same depth (survives reorder)
3. exact `t` match anywhere (survives reparenting)
4. normalized edit-distance ≥ 0.8 on `t` within the same parent (survives rename)
5. otherwise dropped — garbage-collected on the next write

Nodes with no entry simply auto-layout. A stale, truncated, or hand-mangled
block degrades to "everything auto-lays-out", never to a broken map.

---

## 5. Layout — balanced two-sided

- **Tidy tree with variable node sizes** (Buchheim/Reingold–Tilford adapted):
  subtree extents computed bottom-up, children stacked, parent centred on its
  children's extent. Column x from depth, using the widest card per column
  per side.
- **Side assignment**: top-level branches walked in document order, each going
  to whichever side currently has less accumulated height. Deterministic, and
  keeps document order legible.
- **Pinned nodes** leave the flow. Their subtree lays out relative to the pin;
  the pinned bounding box becomes an obstacle, and flowed subtrees are pushed
  vertically to resolve overlap. Unpin → rejoins the flow.
- **Connectors**: cubic béziers, parent edge → child edge, stroke width
  tapering with depth, tinted by top-level branch.
- **Animation**: every relayout tweens (~220ms, ease-out). Nodes never jump.

Visual language is fixed — one tasteful theme, light and dark via
`prefers-color-scheme`, tokens in `:root` matching the house style used by
Table/Diagram Studio. No user-facing color pickers, no theme settings.

---

## 6. Touch interaction

- **Pan**: one-finger drag on empty canvas. **Zoom**: pinch. **Double-tap
  empty**: fit to screen.
- **Tap a node**: select. A contextual bottom bar rises:

  `+ Child` · `+ Sibling` · `Edit` · `Note ▾` · `Focus` · `⋯`

  `Note ▾` → attach existing note / create note here / promote branch to note /
  open note. `⋯` → collapse-subtree, toggle task, delete.
- **Edit**: `Edit` or double-tap → inline auto-sizing text field on the card.
  Enter commits and opens a sibling; the canvas pans to keep the field above
  the keyboard (`interactive-widget=resizes-content`).
- **Drag a node**: drags start on nodes only (pan starts on empty space, so the
  two never fight). Drop on another node → reparent that subtree, target
  highlights. Drop on empty space → pin there. Drop on the trash zone → delete.
- **Undo**: 50-deep stack of pre-write markdown snapshots, with an undo button
  always in the top bar. Non-negotiable given we write to real notes.

---

## 7. Notes on the map

All of it is expressed as ordinary markdown links, using the scheme the app
already renders and navigates:

| Markdown in the node | Renders as |
|---|---|
| `[Design specs](synapseresource://note/<id>)` | attached-note card hanging off that node |
| `[see Design](#design)` | dashed curved edge to the node whose slug matches |
| `[docs](https://…)` | link chip, opens externally |

- **Transclusion**: an attached-note card shows the note's title plus the first
  few rendered lines, visually distinct (tinted border, note glyph). Tap →
  sheet with the full note, editable, written back with `Synapse.updateNotes`.
  Content is fetched with `Synapse.runQuery`.
- **Attach existing**: `Synapse.pickNotes()` → inserts the link into the node's
  body.
- **Create note here**: `Synapse.saveNotes` with title = node text and tags
  inherited from the host note, then inserts the link. The plain node becomes a
  note-backed node in place.
- **Promote branch to note**: new note whose content is the subtree markdown
  (dedented, heading levels normalized to start at `#`); the subtree is removed
  from the host note and the node body gets the link. Undoable.

---

## 8. Dual view — Map ⇄ Outline

Segmented control in the top bar. Both views render the same parsed tree, and
an edit in either goes through the same span-rewrite path, so they can never
disagree.

- **Outline**: indent-guided rows, checkbox, tap-to-edit, indent/outdent
  buttons, drag handles for reorder. This is the fast way to type on a phone.
- A `</>` button in the outline reveals the raw markdown for the current
  subtree, read-only, for when you want to see exactly what will be written.

---

## 9. Focus, search, task rollup

- **Focus**: `Focus` on the bottom bar makes the node the temporary root; a
  breadcrumb bar appears to climb back out. Focus state is view-only, never
  written to the note.
- **Search**: field in the top bar. Matches get a highlight ring, everything
  else dims to ~15%; paths to matches auto-expand; ‹ › step through matches,
  centering each. Filter chips for tag, task status, and *has attached note*.
- **Task rollup**: `- [ ]` / `- [x]` render as checkbox nodes; any ancestor
  with tasks beneath it shows a progress ring and `3/7`. Tapping a checkbox
  rewrites that one span in the markdown.

---

## 10. Writing back

- All writes go through
  `Synapse.updateNotes([{id, modification:{content:{action:'replace', text}}}])`.
  The `modification` form is required for block-scoped notes and works fine for
  ordinary ones, so there is a single code path.
- Debounced ~600ms, coalescing rapid edits into one write.
- **External-change check**: before writing, re-read the note with
  `Synapse.runQuery('SELECT content FROM note WHERE id = …')` and compare
  against the content we parsed. If it changed underneath, offer *reload* /
  *overwrite* rather than clobbering. Skipped for block scopes (no row).
- The sidecar block is rewritten as part of the same content write.

---

## 11. Testing

Following the established contrib workflow — a mock Synapse bridge plus
headless Chrome:

- `dev/harness.html` — stub `window.Synapse` over a fixture note, so the whole
  app is drivable in a desktop browser.
- `dev/auto_smoke.html` — assertions run in headless Chrome:
  - `serialize(parse(md)) === md` for every fixture (round-trip fidelity)
  - structural edits (add/rename/delete/reparent/check) produce exactly the
    expected markdown diff, and touch nothing else
  - id re-match survives rename / reorder / reparent / block-deleted
  - layout produces no overlapping node boxes, pinned or flowed
  - a corrupt or absent sidecar still yields a full valid layout

---

## 12. Risks

| Risk | Mitigation |
|---|---|
| Lossy round-trip corrupts a note | span-based splice, never full re-serialize; round-trip assertion in smoke tests; 50-deep undo; external-change check before every write |
| The sidecar block is visible clutter at the end of the note | single line, minimal keys, omitted entirely when there is no pin/collapse state |
| Big notes → slow layout | layout is O(n); render only what's in the viewport plus a margin; collapse-by-default below depth 4 on first open |
| Two mindmap apps in the list | different name and description; retire the AI one later if this proves out |
| Inline embed reuses full-screen chrome badly | `mode=embed` is a distinct, read-mostly render path, not the same UI shrunk |


---

## What shipped, and where it diverged

Everything in this design was built. The differences below are decisions taken
while building, not omissions.

### Found in the codebase, not assumed
- `saveNotes` generates its own uuid and returns only a count, so a new note's
  id cannot be read back. `host.createNote` writes a one-shot marker comment
  into the new note, finds it by that marker, then strips it. Two extra round
  trips, but deterministic — no "newest note wins" guessing.
- The notes table is `notes` (plural), keyed `id/title/content/updatedAt`.
- `runQuery` serves block-scoped ids from the parent row, so the
  read-before-write check works for a block selection too. Writes still go
  through `updateNotes`, which is why every write uses the `modification` form.

### Design decisions taken during the build
- **`displayRoot` hoist.** A note that opens with a single `# Title` would put
  the entire document on one side of the map. When the synthetic root has
  exactly one heading child, that heading becomes the visual centre. Hoisted
  one level only, so nothing is ever hidden.
- **Opening zoom is readable, not exhaustive.** Fitting a wide map into a phone
  shrinks the labels to nothing. Below a readable scale the map centres on the
  root and the reader pans. The Fit button toggles: whole map, then back to
  readable. Inline embeds always fit the whole map, since the reader is not
  there to explore.
- **New nodes inherit their siblings' shape.** Adding an item to a checklist
  produces a checklist item, not a plain bullet.
- **An unlabelled node is deleted, not kept.** Abandoning a freshly created node
  (Escape, or tapping away) removes it rather than leaving an empty bullet in
  the note. Found by the app-level test, not by reading the code.
- **A heading cannot be dragged under a bullet.** The conversion is ambiguous,
  so the move is refused with a plain-language reason rather than guessed at.
- **Outline reordering uses buttons, not drag handles.** Indent / outdent / up /
  down on the action bar are far more reliable under a thumb than a drag handle
  in a scrolling list; the map is where dragging belongs.
- **`view=outline` URL parameter** added alongside `mode=embed`, so an inline
  embed can be pinned to either view.

### Bugs found and fixed by the tests
- Cards collapsed to one character per line: the stage is a zero-width transform
  container, so absolutely positioned cards shrink-to-fit to nothing. Fixed with
  `width: max-content`.
- Column x positions were off by one after the root column was prepended, which
  made parents overlap their own children.
- A line indented to exactly a list item's content column was treated as a body
  block instead of a paragraph continuation of that item.
- `move` refused any landing offset touching its own span, which wrongly blocked
  "nest under the bullet above me" — the case where only the indent changes.
- The sidecar fence was skipped when the note ended inside a list.
- A flex item without `min-width: 0` pushed the top-bar buttons off a 390px
  screen.

### Follow-up: the on-screen keyboard

Reported after the first build — the keyboard covered the node being edited, so
you could not see what you were typing. `beginEdit` centred the node *before*
the keyboard existed, using `clientHeight`, so it landed in the middle of the
full-height viewport and was then covered.

The viewport meta tag alone cannot fix this: `interactive-widget=resizes-content`
works on Android Chrome but iOS WKWebView ignores it entirely, so on iOS nothing
resizes and no event fires. All framing now goes through `visibleRect()`, built
from `visualViewport` — the one signal both platforms agree on — with the
floating action bar subtracted from it.

Three further bugs surfaced while fixing it:

- **Overshoot.** Corrections were measured with `getBoundingClientRect()`, so
  each follow-up call during the keyboard animation re-applied a correction
  already in flight and the map oscillated. Geometry now comes from
  `nodeScreenRect()` — the laid-out box plus the target transform, with only
  the element's *size* read live, since the card grows as text wraps.
- **A fixed follow-up schedule was wrong.** Android keyboard animations vary
  widely by OEM. Replaced with a loop that re-checks until the node has needed
  no correction for several ticks running.
- **A keyboard open re-fitted the whole map**, discarding the frame being typed
  into. The guard had tested viewport *height*, which cannot distinguish the
  two on Android because the layout viewport shrinks with the keyboard. A
  keyboard never changes the width, so that is the test now. A map the reader
  has panned or zoomed is never re-fitted behind their back either.

Also fixed: iOS scrolls the document to reveal a focused field even when there
is nothing to scroll, dragging the fixed layout off screen — now reset on scroll.

Six new assertions in `dev/app_smoke.html` cover it, including that the node
ends up inside the visible band, that the correction settles with nothing left
pending, and that the keyboard never re-fits the map.

### Testing
- `dev/run.js` — 46 module assertions under node, no browser needed.
- `dev/auto_smoke.html` — the same 46 in a browser.
- `dev/app_smoke.html` — 34 assertions that boot the real app in an iframe,
  drive it (add, rename via the live contenteditable, tick, indent, reorder,
  pin, focus, search, delete, undo) and assert on the markdown that comes out
  the other side, including that the host note actually received it, plus the
  on-screen-keyboard behaviour above.

  Headless caveat: Chrome under `--virtual-time-budget` never advances CSS
  transitions, so painted rects stay frozen at a transition's start. Assertions
  about final position use `CG.app.nodeScreenRect()`, not
  `getBoundingClientRect()`.
