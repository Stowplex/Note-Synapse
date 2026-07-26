# Diagram Studio

A diagramming surface for the blocks in your notes. Four ways to author a
diagram, unified by one idea: **an editable text source plus a rendered image
stored next to it.**

| Tab | Source kept in the note | How you edit it |
|---|---|---|
| **Mermaid** | a ` ```mermaid ` fence | text editor with a live preview as you type |
| **Draw** | the exported SVG attachment *is* the source | freehand on a touch canvas (js-draw) |
| **ASCII** | the art itself, in whatever fence or paragraph it already lives in | character-grid editor with a live render |
| **AI** | an ` ```ai-diagram ` fence holding the prompt | describe it, then refine conversationally |

The rendered image is stored as SVG, PNG or JPG — your choice per save — and
placed above or below its source. Re-rendering replaces the previous image
rather than stacking a new one.

This app is bundled with Note Synapse as a starter app
(`assets/starter/apps/Diagram_Studio.yaml`). The copy here is its readable
source. It **replaces Mermaid Block Renderer**, which was Mermaid-only and
refused to run on anything but a block selection.

## How it is used

Run it as a Note Action app, either way round:

- **On a whole note** — the studio scans for diagram-like blocks and lists them
  with a tap to jump between them. Creating a new diagram lets you choose which
  existing block to insert before or after.
- **On a selected block** — long-press the edit (pencil) button in the note and
  drag it onto a block, then choose Diagram Studio from the block toolbar. The
  studio works on just that block.

An empty or non-diagram block is a fine starting point: pick a tab and type.

## Notes on the implementation

### Two write paths, deliberately

The launch modes look identical to the user but the host treats them very
differently, and getting this wrong corrupts notes.

**Block scope** embeds the `synapsetemp:///` URI straight into the block text
and does a single `updateNotes`. `BlockNoteScopeService` then promotes the temp
file to a permanent attachment on the parent note *and* prunes the render it
supersedes — so re-rendering twenty times leaves one attachment, not twenty.
`modification.attachments` is ignored for a block-scoped id, so note-level
changes must target `parentNoteId`.

**Whole note** cannot use that: ordinary content writes do not promote temp
URIs, and an embedded one would display until the OS clears its cache and then
break for good. So it attaches the bytes explicitly, re-reads the stored name
via `exportNotes` (the host appends a fresh uuid to every saved file), embeds
that bare filename, and removes its own superseded attachment — three calls,
and the pruning is ours.

### Reading a render back

Only the Draw tab needs this, because its SVG *is* its source. One lookup
serves both modes: `exportNotes` accepts a block-scoped id, resolves it to the
parent, and returns **absolute** paths — which is what `readAttachment`
requires. The relative entries in `Synapse.Notes[].attachmentPaths` will not
open. Block-scope renders are content-addressed by the host as
`<parentNoteId>_<sha256(uri)><ext>`, so the URI is hashed to find the file.

### Other things that bite

- **Never trust `exportNotes().markdown`** for reading content — it is a
  rendered ShareService export with section labels and localisation applied.
  The raw read is `runQuery("SELECT content FROM notes WHERE id = …")`, and a
  failed read **aborts the save** rather than writing back a stale snapshot.
- **`<foreignObject>` does not render** through `<img>`, which is how canvas
  rasterisation works. Mermaid uses it for HTML labels by default, so labels
  vanish from a PNG — raster targets are re-rendered with `htmlLabels: false`.
- **Mermaid SVGs have no intrinsic size** (`max-width` style, no width/height),
  so the canvas draws nothing until dimensions are pinned from the viewBox.
- **Render markers are typed** (`![diagram:mermaid](…)`), and the legacy
  `![mermaid](…)` written by the old app is still recognised — otherwise an
  upgraded note grows a second image on its first re-render. Stripping is
  scoped to an image immediately adjacent to the source, so a user's own image
  next to a fence is never absorbed.
- **No `​```ascii` fence is invented.** ASCII art arrives in ordinary fences and
  paragraphs (the "Claude gave me a box diagram" case) and is detected
  best-effort, with the tab always overridable.

### Vendored code

`vendor/js-draw-1.33.0.*` (MIT) is inlined at build time; see
`vendor/LICENSE.js-draw` for attribution and the sha256 pins the Dart test
enforces. It was audited for offline use — no `fetch`/XHR/Worker calls, no
`@font-face`. Mermaid is **not** vendored: it loads from the app's own bundled
asset via `synapse://mermaid.min.js`.

## Building

```bash
cd plugins
./build.sh
cp Diagram_Studio.yaml ../../../assets/starter/apps/
```

`build.sh` fails loudly if a local script does not inline — a plugin that
builds cleanly and then cannot load its library on a device is the failure mode
worth guarding.

## Testing

No device needed for most of it:

```bash
node dev/run_core_tests.mjs        # fence scanning, classification, markers, ASCII render
node dev/run_writeback_tests.mjs   # both write paths against a faithful host stub
node dev/run_ai_tests.mjs          # prompt building, refinement, persistence caps
node dev/run_ui_tests.mjs          # the real shell in headless Chrome, both launch modes
```

`dev/synapse_stub.js` models the host behaviours that are impossible to see
without a device: the block-scope splice/promote/prune cycle, the whole-note
uuid renaming, absolute-vs-relative path rules, and `updateNotes` returning
`success: true` with `updatedCount: 0`.

`dev/spike_jsdraw.html` is the round-trip spike kept for reference — it is what
established that `loadFromSVG(toSVG())` preserves stroke geometry and converges
after the first cycle rather than drifting on every save.

On the Flutter side, `test/contrib_diagram_studio_test.dart` fails if the YAML
drifts from the readable sources, if the starter copy is stale, if a vendored
file changes, or if the app gains a script source other than `synapse://`.

## Known limitation

Whether the AI tab's refinement is a true image-to-image edit depends on the
backend honouring an attached image alongside `model_hint: ['image_gen']`.
**This is unverified on device.** If it is not honoured, the accumulated
instruction history still makes each generation cumulative, and the tab says so
rather than implying an edit that did not happen.
