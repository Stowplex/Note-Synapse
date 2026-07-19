---
name: NotebookLM Assistant
skill_ref: notebooklm-assistant
description: Use when the user wants to add notes to a NotebookLM notebook/collection, ask questions grounded in a NotebookLM notebook, describe a collection, or generate a NotebookLM podcast or slide deck. Triggers on phrasing like "add this to NotebookLM", "add this to notebook X", "according to notebook X …", "what is notebook X about", "make a podcast from notebook X".
enabled: true
---

You can drive Google NotebookLM through the **NotebookLM Manager** tools. A
NotebookLM *notebook* is a **collection** of sources; the user syncs local Note
Synapse notes into it, then asks questions answered from that collection, or
generates a podcast / slide deck from it.

## Golden rules

- **Always resolve a notebook by id, never by title.** The user names a
  collection ("notebook Papers"); you must call `notebooklm_list_notebooks`
  first and match the title to its `id`. Every other tool takes a `notebook_id`.
- **Note content is private.** Syncing sends the note's content straight to
  NotebookLM — it never enters this conversation. You only pass note *ids*.
- **Don't invent ids.** If a named collection doesn't exist, create it (see
  below) or ask the user which existing collection they mean.
- If a tool returns an `error` about the session having expired / needing to
  reconnect, tell the user to open the NotebookLM Manager app and reconnect —
  you can't sign in for them.

## Which tool for which intent

| The user wants to… | Do this |
|---|---|
| See their collections | `notebooklm_list_notebooks` → list titles (+ purpose, note count) |
| Add note(s) to collection X | `notebooklm_list_notebooks` → find X's id (create it if missing) → `notebooklm_sync_notes` |
| Ask a question about collection X | `notebooklm_list_notebooks` → find id → `notebooklm_query` |
| Know what collection X is / contains | `notebooklm_list_notebooks` → find id → `notebooklm_collection_info` |
| A podcast from collection X | find id → `notebooklm_generate_podcast` → (later) `notebooklm_artifact_status` |
| Slides from collection X | find id → `notebooklm_generate_slides` → `notebooklm_artifact_status` |

## Adding notes ("add this to NotebookLM notebook X")

1. `notebooklm_list_notebooks`. Find the notebook whose title matches X.
2. If none matches, create it: `notebooklm_create_notebook({ title: "X",
   purpose: "<one line on what it's for>" })` and use the returned
   `notebook_id`. Setting a clear `purpose` is important — it's how the user
   tells collections apart later.
3. Identify the note(s) to add:
   - If the user says "this"/"this paper"/"this note", use the note currently
     in context (its id).
   - If they name notes or a topic, resolve ids with your note-search tools.
   - If you can't determine which notes, call `notebooklm_sync_notes` with only
     `notebook_id` (no `note_ids`/`tag`) — a picker opens for the user. (In a
     headless context that returns an error asking for `note_ids` or a `tag`;
     then ask the user, or use a tag.)
4. `notebooklm_sync_notes({ notebook_id, note_ids: [...] })` (or `{ tag: "…" }`
   to sync everything with a tag). Report the result (added / updated /
   unchanged / failed). Re-running is safe — unchanged notes are skipped and
   edited ones are re-pushed.

## Asking questions ("according to notebook X, what is Y about?")

1. `notebooklm_list_notebooks` → find X's id.
2. `notebooklm_query({ notebook_id, question: "What is Y about?" })`. Relay the
   `answer` (it's grounded in the collection's sources, with citations). If the
   collection has no synced notes yet, offer to add some first.

## Generating a podcast or slides

1. Find the notebook id.
2. `notebooklm_generate_podcast({ notebook_id, format })` (format: `deep_dive`
   default, `brief`, `critique`, `debate`) or `notebooklm_generate_slides({
   notebook_id })`. These return an `artifact_id` immediately with
   `status: "pending"` — generation takes a few minutes and continues in the
   background.
3. Tell the user it's generating and that a note linking to it will appear when
   ready. If they ask again later, call `notebooklm_artifact_status({
   notebook_id, artifact_id })`; when `status` is `complete` a note is saved.

## Examples

- User (reading a paper): *"Add this to my NotebookLM notebook RAG Papers."*
  → list notebooks; if "RAG Papers" exists use its id, else
  `notebooklm_create_notebook({title:"RAG Papers", purpose:"Papers on
  retrieval-augmented generation"})`; then
  `notebooklm_sync_notes({notebook_id, note_ids:[<this note>]})`.
- User: *"According to my RAG Papers notebook, what is re-ranking about?"*
  → list → id → `notebooklm_query({notebook_id, question:"What is re-ranking
  about?"})`.
- User: *"What's in my RAG Papers collection / what's it for?"*
  → list → id → `notebooklm_collection_info({notebook_id})`; summarise the
  purpose and the note titles.
- User: *"Make a podcast from RAG Papers."*
  → list → id → `notebooklm_generate_podcast({notebook_id})`; tell them it's
  generating.
