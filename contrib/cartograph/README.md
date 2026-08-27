# Cartograph

An editable mind map for the note you are reading. **No AI.** The note's
markdown is parsed directly, and every change you make on the map is written
straight back into that markdown.

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

## How markdown maps to the map

| Markdown | Becomes |
|---|---|
| the note title, or a lone `# Heading` | the centre of the map |
| `#` … `######` | a branch, nested by heading level |
| `-` `*` `+` `1.` list items | a branch, nested by list indent |
| `- [ ]` / `- [x]` | a node with a checkbox |
| paragraphs, code fences, tables, quotes, images | the **body** of the nearest node, shown behind a `¶` / `⟨⟩` / `▦` chip |
| `[Title](synapseresource://note/<id>)` | an attached-note card hanging off that node |
| `[label](#some-heading)` | a dashed cross-link to that node |
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
  src/host.js       # the Synapse bridge (plus an in-memory mock for the browser)
  src/app.js        # state, rendering, gestures, sheets
  build.sh          # inlines src/*.js into the installable Cartograph.yaml
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
`?md=<urlencoded markdown>` seeds it with your own note.

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
