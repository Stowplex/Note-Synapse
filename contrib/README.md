# Contrib

This folder holds a selection of community contributed plugins and skills for
Note Synapse.

Most contrib plugins are **not bundled with Note Synapse**. They ship only from
this folder — you download one and install it into your own copy of the app
yourself.

Three of them — **Diagram Studio**, **Formula Studio** and **Table Studio** —
do ship with the app as starter apps in `assets/starter/apps/`. Their folders
here hold the readable source of those bundled builds. The list below says
which is which.

## Licensing

Contrib plugins are independent works. They run as standalone HTML/JS user apps
and communicate with Note Synapse only through its public Synapse plugin API. A
plugin that is distributed separately, and is not combined with Note Synapse at
build or distribution time, is **not required to conform to Note Synapse's
AGPL v3 / proprietary dual license**.

Each plugin carries its own license, declared by its author in the plugin's
metadata (the `license` field of its `.yaml` file), its README, or an
accompanying license file in its folder. The three bundled as starter apps are
Apache-2.0. Check the individual plugin before redistributing it.

## Structure

Each plugin lives in its own folder:

```
contrib/
  <plugin-name>/
    plugins/   # the plugin source (HTML) and the installable .yaml user app,
               # plus a build.sh that regenerates the .yaml from the HTML
    skills/    # optional skill files (Markdown) that teach the AI assistant
               # how to use the plugin's tools
```

## Installing

1. **Plugin**: open the `.yaml` file from the plugin's `plugins/` folder with
   Note Synapse (share/open it on your device) to import it as a user app.
2. **Skill** (if the plugin ships one): create a skill in Note Synapse with the
   contents of the `.md` file from the plugin's `skills/` folder.

The starter apps are already installed; there is nothing to import for those.

## Plugins

- **notebooklm** — sync notes to Google NotebookLM as sources, ask questions
  grounded in a notebook, and generate podcasts/slides. Uses NotebookLM's
  private web interfaces, which is why it is distributed here.
- **dos-station** — play DOS games stored in notes: mounts a note's `.zip`
  attachment as the C: drive of a DOSBox/WebAssembly emulator configured by a
  ` ```dosbox ` block in the note, with on-screen keyboard/gamepad overlays
  and one-tap frame capture appended back to the note. Downloads the js-dos
  engine (DOSBox, GPL-2.0) onto the user's device at runtime, which is why it
  is distributed here.
- **nes-arcade / Neon Cartridge** — play a `.nes` ROM attached to a selected
  note with phone-ready controls, rapid-fire/rapid-jump buttons, quick saves,
  and annotated screenshots saved back to the note.
- **yt-fetcher** — adds one AI tool, `fetch_youtube_data`, that pulls a YouTube
  video's transcript (English and Chinese) into a conversation.
- **cartograph** *(two bundled starter apps)* — turn a note into an editable
  mind map: headings and bullets become branches, and every change on the map is
  written straight back into the note's markdown. Drag nodes to re-nest or pin
  them, flip between map and outline, focus a branch, search and filter, roll up
  checkbox progress, link any two nodes with a dashed line, and attach several
  notes at once as cards you can move, link and select like anything else.
  Optionally generates a map with AI into a companion note, and reshapes
  branches with AI behind a preview you approve. Ships as **Cartograph**
  (standalone, with a home screen of your maps) and **Cartograph: this note**
  (the note action).
- **table-studio** *(bundled starter app)* — edit the tables in your notes with
  a fluid touch spreadsheet: markdown pipe tables in the note body as well as
  `.csv`/`.tsv`/`.xlsx`/`.ods` attachments, with undo, column alignment,
  multi-sheet tabs, and read-only safety for legacy `.xls`/`.xlsm` files.
- **formula-studio** *(bundled starter app)* — edit the LaTeX formulas in your
  notes in a visual math field, and run algebra and calculus on them (simplify,
  solve, factor, derivative, integral, limit) using the MathLive and Cortex
  Compute Engine builds bundled in the app. Works offline, on a whole note or a
  selected block.
- **diagram-studio** *(bundled starter app)* — author the diagrams in your notes
  four ways: Mermaid with a live preview, freehand drawing, ASCII art on a
  character grid, or an AI-generated image you refine by conversation. Each
  stores a rendered SVG/PNG/JPG beside its editable source, and works on a whole
  note or a single selected block. It replaces the earlier Mermaid Block
  Renderer.
