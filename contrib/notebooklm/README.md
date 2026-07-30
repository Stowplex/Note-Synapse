# NotebookLM Plugin

Connects Note Synapse to [Google NotebookLM](https://notebooklm.google.com).
Sync local notes into a NotebookLM notebook as sources, ask questions answered
from those sources (with citations), and generate podcasts (Audio Overviews)
and slide decks — either from the plugin's own UI or by just asking the AI
assistant ("add this note to notebook Papers", "according to notebook Papers,
what is X?", "make a podcast from notebook Papers").

## Contents

```
plugins/
  notebooklm_manager.html    # plugin source
  NotebookLM_Manager.yaml    # installable user app, generated from the HTML
  build.sh                   # regenerates the .yaml after editing the HTML
skills/
  NotebookLM_Assistant.md    # agent skill teaching the AI how to use the tools
```

## Install

1. Import `plugins/NotebookLM_Manager.yaml` in the User App screen.
2. Create an agent skill note in Note Synapse with the contents of
   `skills/NotebookLM_Assistant.md` (this step is optional but recommended —
   it lets the AI assistant drive the tools well).
3. Open the NotebookLM Manager app and tap **Connect NotebookLM** to sign in
   with your Google account. The login happens in an in-app browser session on
   your device.

## AI tools exposed

| Tool | Purpose |
|---|---|
| `notebooklm_list_notebooks` | List notebooks (collections), with purpose label and synced note count |
| `notebooklm_create_notebook` | Create a notebook, with a purpose label |
| `notebooklm_collection_info` | Describe a notebook: title, purpose, synced notes |
| `notebooklm_set_purpose` | Set/update a notebook's purpose label |
| `notebooklm_sync_notes` | Push local notes (by id or tag, or via a picker) into a notebook as sources |
| `notebooklm_query` | Ask a question grounded in a notebook's sources |
| `notebooklm_generate_podcast` | Start an Audio Overview (podcast) generation |
| `notebooklm_generate_slides` | Start a slide deck generation |
| `notebooklm_artifact_status` | Poll a podcast/slides generation and fetch the result |

Note content is sent from your device straight to NotebookLM during sync; it
is never routed through the AI conversation — the AI only ever handles note
*ids*.

## How it works

The plugin talks to NotebookLM's private `batchexecute` web endpoints — the
same requests the NotebookLM web app makes — authenticated by your in-app
browser session cookies. No API key is involved, and nothing is sent anywhere
except to Google. This approach is inspired by https://github.com/jacob-bd/gemini-notebook-mcp-cli.

Because these are **unofficial interfaces**, expect rough
edges:

- Google can change or break them at any time; if a tool starts failing with
  an `nlm_error_*` code, the plugin likely needs an update.
- The NotebookLM free tier is rate limited (roughly 50 queries/day).
- Sessions expire; reopen the app and reconnect when prompted.

This is also why the plugin lives in `contrib/` and is not bundled with
Note Synapse.

## Development

Edit `plugins/notebooklm_manager.html`, then run `plugins/build.sh` to
regenerate `NotebookLM_Manager.yaml`.

## License

MIT.
