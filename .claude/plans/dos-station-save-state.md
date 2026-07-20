# DOS Station — persistent game saves (local state)

Goal: let DOS games played in the dos-station plugin keep their state across
sessions — the canonical case is an RPG whose in-game "Save Game" writes
`SAVE*.SAV` files to the C: drive. Today the C: drive is Emscripten MEMFS,
rebuilt from the note's game zip on every boot, so anything the game writes is
lost when the plugin closes.

Constraint (from project rules): plugins are pure HTML/JS using only the
generic Synapse API — no integration-specific Dart may be added.

## Verified building blocks

- The pinned js-dos 6.22.60 glue exports `Module["FS"] = FS` (checked against
  the sha256-pinned CDN file), so the plugin can walk and read the guest
  filesystem: `FS.readdir`, `FS.stat`, `FS.lookupPath(p).node.contents`.
- `Synapse.updateNotes` granular modification supports
  `attachments: {added: [{type:'base64', data, fileName}], removed: [path]}`
  (`NoteModificationService.applyModifications`), so an attachment can be
  replaced atomically in one call.
- The plugin already embeds fflate, which can build zips (`zipSync`), not just
  extract them.
- The original bytes of every mounted file are already kept in memory
  (`state.files`), giving a free baseline to diff against.

## Options considered

### A. File-level save diff → note attachment (RECOMMENDED, implemented)

On save, walk the guest `/dos` tree, diff it against the mounted baseline
(game zip + previously restored saves), zip only the new/changed files plus a
small manifest (which also records deletions), and attach it to the game note
as `dos-saves-<zipslug>-<stamp>.zip`, removing the previous saves attachment
in the same `updateNotes` call. On boot, the newest matching saves attachment
is unzipped on top of the game files before DOSBox starts.

- Pros: saves travel **with the note** (sync, backup, share, visible to the
  user as a normal attachment); tiny payloads (RPG saves are KBs); per-zip
  slug keeps multi-disk notes safe; no Dart changes; works offline.
- Cons: each save mutates the note (acceptable: change-detection means writes
  only happen when the game actually wrote something).

Save triggers: manual 💾 HUD button, periodic autosave (60 s, only when bytes
actually changed), and a best-effort save on Eject.

### B. Saves in app state (`Synapse.storeAppState`) — rejected

App state is a single JSON blob per app that already carries the ~2.7 MB
base64 engine cache and is rewritten wholesale on every `storeAppState`; every
autosave would rewrite the engine too. Saves would also be app-global instead
of living with the note, wouldn't sync with it, and die if app state is
cleared. Used only for a small pointer (`saves[noteId] → attachment path`) to
speed up discovery.

### C. Full machine-state snapshots (emulator save-states) — deferred

True "save anywhere" (RAM + device state) is not supported by the js-dos
6.22 wdosbox build (no serialization hooks). It would require migrating to
emulators.js (js-dos 7/8), a different engine API with a larger download, and
snapshots are tens of MB — poor fit for note attachments. File-level saves
cover the stated RPG use case (games persist through their own save files).
Revisit only if a game with no disk-save mechanism matters.

### D. WebView-local storage (IndexedDB/localStorage inside the plugin) — rejected

Invisible to the user, not synced or backed up with the note, and WebView
storage for user apps can be cleared at any time. Violates the
"state lives in notes" model.

## Implementation notes (option A)

- `zipAttachments()` must exclude `dos-saves-*` attachments so a saves zip is
  never offered as a bootable game disk.
- Diff: size-first compare, then byte compare against MEMFS node contents
  (`node.contents.subarray(0, node.usedBytes)` with `FS.readFile` fallback) —
  no copies for unchanged files.
- Manifest `__dos_station__/meta.json` inside the saves zip records
  `{v, game, savedAt, deleted[]}`; restore applies deletions and skips the
  meta dir. Saves are matched to the current game zip via the filename slug.
- After upload the stored (renamed) attachment path is rediscovered via
  `exportNotes` (same pattern the frame-capture flow uses) and cached in app
  state.
- Baseline is updated after every successful save so later diffs are relative
  to the last save.
- Size guard: autosave skips payloads over 8 MB (manual save still allowed,
  with a warning toast).
- Dev harness stub gains persistent fake attachments (localStorage) plus
  `removed` support so the save→reload→restore round-trip can be tested in a
  desktop browser.
