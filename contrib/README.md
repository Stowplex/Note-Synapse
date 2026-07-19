# Contrib

This folder holds a selection of community contributed plugins and skills for
Note Synapse.

Contrib plugins are **not bundled with Note Synapse**. They are not part of the
app, are not shipped in any Note Synapse release or app store build, and are
not installed by default. Anyone who wants one downloads it from this folder
and installs it into their own copy of Note Synapse separately.

## Licensing

Contrib plugins are independent works, not part of the Note Synapse
application. They run as standalone HTML/JS user apps and communicate with
Note Synapse only through its public Synapse plugin API. Because they are
distributed separately and are not combined with Note Synapse at build or
distribution time, they are **not required to conform to Note Synapse's
AGPL v3 / proprietary dual license**.

Each plugin carries its own license, declared by its author in the plugin's
metadata (the `license` field of its `.yaml` file) or an accompanying license
file in its folder. Check the individual plugin before redistributing it.

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

## Plugins

- **notebooklm** — sync notes to Google NotebookLM as sources, ask questions
  grounded in a notebook, and generate podcasts/slides. Uses NotebookLM's
  private web interfaces, which is why it is distributed here rather than
  bundled with the app.
- **dos-station** — play DOS games stored in notes: mounts a note's `.zip`
  attachment as the C: drive of a DOSBox/WebAssembly emulator configured by a
  ` ```dosbox ` block in the note, with on-screen keyboard/gamepad overlays
  and one-tap frame capture appended back to the note. Downloads the js-dos
  engine (DOSBox, GPL-2.0) onto the user's device at runtime, which is why it
  is distributed here rather than bundled with the app.
