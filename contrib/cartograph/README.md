# Cartograph

An editable mind map for your notes. The note's markdown is parsed directly —
no AI needed to draw a map — and every change you make on the map is written
straight back into that markdown.

AI is optional and additive: it can *generate* a map into a companion note, and
*reshape* a branch behind a preview you approve. It is never in the loop for
reading, drawing or editing a map.

Headings and bullets become branches. Paragraphs, code fences, tables and
quotes ride along as the *body* of whichever node they sit under. Nothing in
the note is discarded, and nothing is invented.

## Why it is not another canvas

Obsidian's Canvas gives you an empty plane and asks you to place everything by
hand, in a file the rest of your vault cannot read. Cartograph starts from the
note you already wrote, lays it out for you, and keeps the note as the single
source of truth:

- **Auto-layout with manual override.** Branches arrange themselves as a
  balanced two-sided mind map. Drag any node to pin it where you want; unpin and
  it rejoins the flow.
- **Map ⇄ Outline.** One tap flips between the map and a plain indented
  outline of the same note. Both edit the same document, so they cannot drift.
- **Focus any branch.** Make a node the temporary centre and climb back out
  through the breadcrumb. Big notes stay navigable on a phone.
- **Search, filter and dim.** Type to highlight matches and fade everything
  else; filter by tag, by task state, or by *has an attached note*.
- **Task rollup.** `- [ ]` items render as checkboxes and every branch above
  them shows its progress. Ticking one rewrites that one line of markdown.
- **Notes on the map.** Attach an existing note, create one in place, or
  promote a whole branch into its own note — all as ordinary markdown links.

## Two apps, one file

Cartograph ships twice, from the same HTML:

| | |
|---|---|
| **Cartograph** | A standalone app. Opens on a home screen listing your maps; can be pinned as a home tab. |
| **Cartograph: this note** | The note action. Maps the note you are reading, or just the block you selected. |

No build flag and no code fork separate them. A `normal` launch simply arrives
with no note (`Synapse.Notes` is empty), which *is* the home screen; a
`note_action` launch arrives with one, and maps it.

## Generating a map with AI

The ✦ button offers to build a map of the current note. `Synapse.chatAI` returns
plain text — there is no JSON or schema mode — so the answer's format is simply
a markdown outline, which the ordinary parser already consumes. Nothing the
model can say is unparseable; at worst it becomes a node with a long label.

- The model is told to **restructure, never invent**: group, order and surface
  what the note already says, preferring the note's own wording so every branch
  is traceable back to the text.
- Nothing is written until you have seen the map and pressed **Save**.
- Long notes are split on their own top-level headings, mapped section by
  section, and the results concatenated — a join, never a merge.
- The map is saved as an ordinary **companion note**, and the source note gains
  one link to it, marked `?via=cartograph`.
- **Regenerating replaces** that companion's contents. It never creates a second
  map or a second link.

Answers arrive wrapped in code fences, bookended with chat, missing a title or
carrying several — all of which are normalised before you see them. An answer
with no outline in it at all is refused rather than half-applied.

## Reshaping a branch with AI

Select several nodes (**More → Select several nodes**), then **Merge** or
**Group**; or reshape a whole branch with **Regroup** or **Tidy the labels**.

Only the affected branch is ever sent, and only its replacement is expected
back, so the rest of the note is not in the request and cannot be rewritten by
accident.

The proposal is never applied straight away. It is drawn on the map:

| | |
|---|---|
| dashed accent | a node the AI would add |
| amber | a label it would rewrite |
| green dashed | a node it would move |
| faded, struck through, **MERGED** / **REMOVED** | a node that would go, hanging off whatever absorbed it |

A summary line states the shape of the change — *"1 merged · 1 added · 1
renamed · 2 moved"*, plus a count of any body text that would be dropped — with
**Apply** and **Discard**. Applying is one splice and one undo step.

## Attached notes

**Note ▸ Attach an existing note** takes **as many notes as you pick** — each
becomes its own card hanging off the node, in one undo step.

A card is not a dead end. From its action bar you can **Open** or **Edit** the
note, **Move** the card to a different node, **Link** it to something, or
**Detach** it. Cards can also be selected alongside nodes.

Each card is one line in the note's body, and its own links ride on that line:

```markdown
- Colors

  [Interview script](synapseresource://note/abc) → [Design](#design)
  [Recruiting plan](synapseresource://note/def) → [Interview script](synapseresource://note/abc)
```

The rule is positional: **a body line whose first link is a note link belongs to
that card, and so does everything else on it.** The `→` is decoration. Because
the whole line travels together, moving a card carries its links, and detaching
one takes them with it rather than stranding them on the node.

A card may link to a node or to another card. When a card is one of a linked
pair it is always the source, since that is where its links can live. A
card-to-card link resolves to the **nearest** copy of that note, the same
distance rule used for repeated names.

### What cards cannot do

Merge, Group and Split are withheld whenever a card is selected: they rewrite
markdown labels, and a card is a reference to another note, not text this note
owns. Move is withheld for a selection mixing nodes and cards — nodes move as
subtrees among a node's children, cards move as lines into a body, and doing
both at once would fail silently. You get a plain refusal instead.

## Linking two unrelated nodes

Two nodes anywhere in the map can be joined by a **dashed line**, independent of
the hierarchy. Create one from **More ▸ Link to…**, or by selecting exactly two
nodes and tapping **Link**.

It is written as an ordinary markdown anchor, on its own line under the source
node, so the node's label stays clean:

```markdown
- Colors

  [→ Type](#type)
- Type
```

**Tapping the link's handle selects both of its ends** — which is the point of
it: with two nodes selected, Merge, Group and Move are already there, and
**Unlink** appears in their place.

The handle exists because a 1.5px dashed curve is not a touch target. It sits at
the curve's midpoint and *counter-scales*, holding its size on screen however
far the map is zoomed out — as do the collapse chips. They are affordances, not
diagram content.

### Which node a link means

`#colors` cannot tell two nodes called "Colors" apart. The **nearest** one to
the link's source wins, counted in edges through their lowest common ancestor,
so a link written in one branch resolves within that branch. Creating a link to
a name that is not unique says so, rather than quietly guessing.

Renaming a node **inside Cartograph carries its links**: anchors that pointed at
it are repointed, and the generated `[→ Name]` label refreshed, in the same undo
step. A hand-written label is left alone — only its target is updated. If two
nodes shared the old name, nothing is rewritten, since the remaining twin still
answers to it.

Renames made in another editor still break the link; that is inherent to
text-addressed anchors, and the alternative (invisible ids in your markdown) was
rejected in v1. A link whose target has gone simply draws no edge and stays in
the note as an ordinary markdown link.

## Importing another note as a branch

**Note ▾ → Import a map here** brings another note's outline in under the
selected node — the exact inverse of *promote branch to a note*, reusing the
same transforms.

Headings stay headings while there is depth left. Once the target is a bullet,
or the level would pass `######`, everything from there down becomes bullets
nested by indent — clamping at `######` instead would silently flatten a deep
import into a row of siblings. Ordered markers and checkboxes survive.

You can **Link** instead of copying, which gives the transclusion card described
above.

The same reshaping is what lets a **section move under a bullet**: it becomes
bullets, nested as it was. A destination that would do this says *"becomes a
bullet"* on its row, since it changes how the note reads.

## How markdown maps to the map

| Markdown | Becomes |
|---|---|
| the note title, or a lone `# Heading` | the centre of the map |
| `#` … `######` | a branch, nested by heading level |
| `-` `*` `+` `1.` list items | a branch, nested by list indent |
| `- [ ]` / `- [x]` | a node with a checkbox |
| paragraphs, code fences, tables, quotes, images | the **body** of the nearest node, shown behind a `¶` / `⟨⟩` / `▦` chip |
| `[Title](synapseresource://note/<id>)` | an attached-note card hanging off that node |
| the same link with `?via=cartograph` | this note's generated map |
| `[label](#some-heading)` | a dashed link to that node, with a handle you can tap |
| `#tag` in a label | a filterable tag |

Every node remembers the exact byte range it came from. An edit is a splice
into the original text, never a re-serialization of the document — so renaming
one bullet cannot reformat a code fence three sections away.

## The sidecar block

Positions and collapse state are the only things markdown cannot express. When
you pin or collapse something, Cartograph appends one compact block:

````markdown
```synapse-cartograph
{"v":1,"n":{"n7":{"k":"i0:plan/design/colors","t":"colors","d":3,"p":[400,-150]}}}
```
````

It is written only when there is something to say, and removed again when there
is not — a map with no pins leaves the note completely clean. **The map lays
out correctly without it.** If the block is missing, stale or hand-mangled,
every node simply falls back to automatic layout; nothing breaks.

When the note is edited elsewhere, stored positions are re-attached by trying,
in descending order of confidence: the exact outline path, then exact label text
at the same depth, then exact label text anywhere, then a close-enough label
under the same parent. Anything that cannot be matched is dropped, and that
node auto-lays-out.

## Using it

Open a note, choose **Cartograph** from the note actions. It also runs on a
selected block, mapping just that section, and can be embedded live inside a
note:

```markdown
@[100% x 420](synapseresource://app/96d13a4a-3c59-4e2c-9522-0dfee4101da0?note=current&mode=embed)
```

`mode=embed` switches to a compact read-mostly view. `view=outline` opens on the
outline instead of the map.

### On the map

- **Tap** a node to select it; the action bar rises with Child, Sibling, Edit,
  Note, Focus and More. **Tap a selected node again** to rename it in place.
- **Enter** commits and opens a sibling; **Tab** / **Shift-Tab** nest and
  un-nest; **Escape** abandons. A node you never labelled is removed rather
  than left behind as an empty bullet.
- **Drag** a node onto another to re-nest that whole branch, onto empty space
  to pin it, or onto the bin to delete it.
- **More ▸ Move to…** reparents without dragging — needed whenever the
  destination is off screen, and the only way to reparent in the outline. Pick a
  destination from the note's outline; invalid ones (the node itself, anything
  inside it, the parent it already has) are not listed. In select mode, **Move**
  does the same for everything selected, in one step.
- **Drag the background** to pan, **pinch** to zoom, **double-tap** to fit.
  The Fit button toggles between the whole map and a readable zoom.
- Every write is undoable from the top bar, 50 steps deep.

### The on-screen keyboard

While you are typing, the map keeps the node you are editing above the
keyboard, and follows it as the card grows onto a second line.

This cannot be done with the viewport meta tag alone.
`interactive-widget=resizes-content` shrinks the layout viewport on Android
Chrome, but iOS WKWebView ignores it completely — there the layout viewport
keeps its full height and the keyboard simply covers the bottom of it.
`visualViewport` is the one signal both platforms agree on, so every framing
decision goes through `visibleRect()` rather than `clientHeight`, and the
floating action bar is subtracted from it too.

Two things that are easy to get wrong, and are guarded by tests:

- Corrections are computed from where the node *will be* once the transform
  lands, never from `getBoundingClientRect()`. Measuring mid-transition makes
  each follow-up call re-apply a correction already in flight, and the map
  overshoots and oscillates while the keyboard animates in.
- Keyboard animations vary widely between Android OEMs, so instead of a fixed
  schedule the app re-checks until the node has needed no correction for
  several ticks running.

A keyboard opening is also a resize. Re-fitting the map then would throw away
the frame you are typing into — and on Android the layout viewport shrinks, so
height alone cannot tell a keyboard from a rotation. A keyboard never changes
the **width**, so that is what a genuine resize is judged by.

### Safety

Cartograph writes to a real note, so it re-reads the note immediately before
each save. If something else changed it in the meantime you are asked which
version to keep, rather than having one silently overwrite the other.

## Development

```
plugins/
  cartograph.html   # shell: design tokens, DOM, module tags
  src/md.js         # markdown -> tree, with byte-exact spans
  src/edit.js       # structural edits as splices
  src/sidecar.js    # the sidecar block, and re-finding nodes after outside edits
  src/layout.js     # balanced two-sided tidy tree, pinned-node handling
  src/view.js       # view tree: note cards, focus, rollup, search
  src/diff.js       # what an AI proposal changed, for the ghost preview
  src/ai.js         # prompts, answer sanitising, long-note chunking
  src/host.js       # the Synapse bridge (plus an in-memory mock for the browser)
  src/app.js        # state, rendering, gestures, sheets
  build.sh          # inlines src/*.js into BOTH installable yamls
dev/
  harness.html      # drive the real app in a desktop browser
  auto_smoke.html   # module assertions in the browser
  app_smoke.html    # drives the booted app in an iframe and checks the markdown
  run.js            # the same module assertions under node
  spec.js           # shared assertions
  fixtures/*.md
```

With no Flutter bridge present, `host.js` installs an in-memory mock, so
`plugins/cartograph.html` opens and works in an ordinary browser.

| parameter | effect |
|---|---|
| `?md=<urlencoded markdown>` | seed the mock note with your own markdown |
| `?standalone=1` | drop the note, which is how a `normal` launch arrives |
| `?mode=embed` | the compact read-mostly embed view |
| `?view=outline` | open on the outline instead of the map |

The mock's `chatAI` is **scripted, not simulated**: push canned answers onto
`window.__CG_AI__` and assert on what the app does with them. `window.__CG_PICK__`
does the same for the note picker. That is how the AI flows are covered end to
end with no model and no network — including deliberately bad answers.

```bash
node dev/run.js          # module assertions, no browser needed
./plugins/build.sh       # regenerate Cartograph.yaml
python3 -m http.server 8731 --directory .   # then open dev/harness.html
```

The two browser suites are worth running before any release — `dev/app_smoke.html`
in particular boots the real app and asserts on the markdown it produces, which
is where regressions would actually hurt.

One caveat when running them headless: Chrome under `--virtual-time-budget`
never advances CSS transitions, so a painted rect stays frozen at the start of
a transition even though the transform has been set. Assertions about where
something ended up should use `CG.app.nodeScreenRect()` — the app's own
geometry — rather than `getBoundingClientRect()`.

## Licence

Apache-2.0. Ships with Note Synapse as a starter app.
