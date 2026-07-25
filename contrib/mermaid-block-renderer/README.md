# Mermaid Block Renderer

Renders the Mermaid diagram in a **selected block** of a note into an image and
inserts it above the diagram source, leaving the ` ```mermaid ` fence intact so
the diagram stays editable.

Unlike the other plugins in `contrib/`, this one **is** bundled with Note
Synapse as a starter app (`assets/starter/apps/Mermaid_Block_Renderer.yaml`),
because it needs nothing beyond the `mermaid.min.js` that already ships with the
app. The copy here is the readable source of that bundled app.

## How it is used

1. In a note containing a ` ```mermaid ` block, long-press the edit (pencil)
   button in the app bar and drag it onto that block.
2. In the block toolbar that appears, tap the apps button
   ("Run Note Action App").
3. Pick **Mermaid Block Renderer**, then tap **Insert into note** and approve
   the modification.

The app is handed the selected block as a transient *block note*
(`Synapse.Notes[0].isBlockScope === true`) whose `content` is just that block.
Writing to it with `Synapse.updateNotes` splices the result back over exactly
that block in the parent note.

It runs **only** on a block selection, and refuses with an explanation if
launched on a whole note. That is deliberate: a whole-note write does not promote
the generated `synapsetemp:///` SVG to a permanent attachment, so the image would
display at first and then break for good once the OS clears its cache.

## Notes on the implementation

- The rendered SVG is stored with `Synapse.saveTemp`, and the host promotes that
  `synapsetemp:///` file to a permanent attachment on the **parent** note, so
  the image survives the temp cache being cleared.
- Writes use `content.action: 'replace'` with `image + original fence` rather
  than `prepend`, so re-rendering swaps the previous image instead of stacking a
  new one on every run.
- An SVG background rectangle is injected so the diagram is not rendered on
  white inside a dark note.

## Building

`plugins/build.sh` regenerates the installable YAML from the HTML source. The
bundled starter copy must be updated in the same change:

```bash
cd plugins
./build.sh
cp Mermaid_Block_Renderer.yaml ../../../assets/starter/apps/
```

`test/contrib_mermaid_block_renderer_test.dart` fails if the two YAML files
drift apart or if the YAML no longer matches the HTML source.
