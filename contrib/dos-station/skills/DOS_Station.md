---
name: DOS Station
skill_ref: dos-station
description: Use when the user wants to play, set up, or embed a DOS game stored in a note, tune its DOSBox configuration, or asks about DOS Station captures. Triggers on phrasing like "play this DOS game", "set up this game note", "add a dosbox config", "embed the DOS player in this note", "make this note playable".
enabled: true
---

The **DOS Station** user app runs DOS games inside Note Synapse. A *game note*
is an ordinary note with the game's `.zip` attached; DOS Station mounts the
zip as the DOS `C:` drive and boots a DOSBox emulator, configured by a fenced
` ```dosbox ` code block in the note body.

## Setting up a game note

1. The note needs a `.zip` attachment containing the game files. The user must
   attach it themselves (you cannot attach files).
2. Optionally add (or edit) one fenced ` ```dosbox ` block in the note body.
   Its contents are standard `dosbox.conf` sections. Example:

   ```dosbox
   [cpu]
   cycles=fixed 12000

   [autoexec]
   mount c /dos
   c:
   KEEN1.EXE
   ```

   Rules:
   - The zip is always mounted at `/dos`. If the `[autoexec]` block has no
     `mount` command, `mount c /dos` + `c:` are inserted automatically.
   - With **no** `[autoexec]` section, DOS Station scans the zip for
     `.exe`/`.com`/`.bat` programs and shows a launcher menu — this is the
     right default when you don't know the game's main executable.
   - Only add `[autoexec]` with a run command when the user tells you (or the
     note makes clear) which program starts the game.
   - Useful knobs: `[cpu] cycles=` (speed; `auto`, or `fixed <n>` for games
     that run too fast/slow), `[dosbox] machine=` (e.g. `cga`, `tandy`,
     `svga_s3`), `[mixer] rate=`.

3. To make the note itself playable inline, embed the player in the note body:

   ```
   @[640x480](synapseresource://app/282d85c5-82cd-4d0f-b03d-1bb99a84419b?note=current&autoboot=1)
   ```

   Embed params: `autoboot=1` boots without the launcher when possible;
   `exe=NAME.EXE` picks the program to run; `zip=file.zip` picks the
   attachment when the note has several zips.

## While playing

- DOS Station has an on-screen keyboard (with a quick-type bar) and a virtual
  gamepad; the user can also capture the current frame at any time. A capture
  appends a `🕹️ **DOS Station**` section to the note: the frame is added as a
  `dos-capture-*.png` attachment, embedded inline as an image, plus the user's
  optional comment. Don't treat those sections as user-written notes — they
  are session snapshots.
- The first run downloads the emulator engine (~2 MB); afterwards it works
  offline. If the user reports a hash/download error, they should retry on a
  network connection.

## What you should NOT do

- Don't put game binaries or base64 data in the note body — only the zip
  attachment matters.
- Don't create more than one ` ```dosbox ` block; only the first is used.
- Don't remove `dos-capture-*.png` attachments when editing a note unless the
  user asks — the inline images in capture sections reference them.
