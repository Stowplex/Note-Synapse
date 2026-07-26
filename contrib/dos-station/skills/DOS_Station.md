---
name: DOS Station
skill_ref: dos-station
description: Use when the user wants to play, set up, or embed a DOS game stored in a note, tune its DOSBox configuration, put a file (BASIC listing, batch file, config) from the note onto the DOS C: drive, or asks about DOS Station captures. Triggers on phrasing like "play this DOS game", "set up this game note", "add a dosbox config", "embed the DOS player in this note", "make this note playable", "run this .bat in DOS", "put this on the DOS drive".
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

## Putting a file from the note onto C:

Tag a fenced code block's info string with `dos-name` and DOS Station writes it
to the DOS drive every time it boots:

````markdown
```basic {dos-name="HELLO.BAS"}
10 PRINT "HELLO WORLD!"
20 GOTO 10
```
````

This is the right move whenever the user wants to *run* something they wrote in
the note — a BASIC listing, a batch file, a config file a game reads.

- The name must be DOS 8.3 and is uppercased: `hello.bas` → `C:\HELLO.BAS`.
  Subdirectories are allowed (`src/main.bas` → `C:\SRC\MAIN.BAS`). A stem longer
  than 8 characters, an extension longer than 3, a device name (`CON`, `NUL`,
  `LPT1`, …) or characters outside `A-Z 0-9 ! # $ % & ' ( ) - @ ^ _ { } ~` are
  rejected. (DOS also allows a backtick, but it cannot appear in a fence's info
  string, so DOS Station does not accept one either.)
- Add the attribute to the block the user already wrote rather than duplicating
  its contents into a new block.
- The block's text is stored on `C:` as code page 437 with CRLF line endings,
  so keep it plain — em dashes and smart quotes cannot be represented and
  become `?`.
- A note that has such a block but no `.zip` attachment still boots, to a bare
  `C:\>` prompt containing just those files. That is the fastest way to let the
  user try a `.bat` or a listing.
- ` ```dosbox ` and ` ```dos-files ` blocks are configuration, not files; never
  give them a `dos-name`.

Attachments are copied to `C:` only when the user picks them in the app's 📁
files panel, which records the choice in a ` ```dos-files ` block. Read that
block if you need to know what is on the drive; leave its `| v=…` options alone
(the app uses them to track saved-back versions).

## While playing

- DOS Station has an on-screen keyboard (with a quick-type bar) and a virtual
  gamepad; the user can also capture the current frame at any time. A capture
  appends a `🕹️ **DOS Station**` section to the note: the frame is added as a
  `dos-capture-*.png` attachment, embedded inline as an image, plus the user's
  optional comment and, if they used Ask AI, the AI's reply (prefixed 🤖).
  The comment box doubles as the Ask AI prompt. Don't treat those sections as
  user-written notes — they are session snapshots.
- The first run downloads the emulator engine (~2 MB); afterwards it works
  offline. If the user reports a hash/download error, they should retry on a
  network connection.
- Game progress persists: files the game writes to `C:` (RPG save games,
  configs, high scores) are stored on the note as a `dos-saves-*.zip`
  attachment (updated by the 💾 button, a 60-second autosave, and eject) and
  restored automatically on the next boot. Tell users of save-capable games
  to save inside the game as usual.

## What you should NOT do

- Don't put game binaries or base64 data in the note body — only the zip
  attachment matters.
- Don't create more than one ` ```dosbox ` block; only the first is used.
- Don't remove `dos-capture-*.png` attachments when editing a note unless the
  user asks — the inline images in capture sections reference them.
- Don't remove or rename `dos-saves-*.zip` attachments — they hold the user's
  game saves; deleting one erases their progress.
- Don't hand-edit the ` ```dos-files ` block's `| v=…` options, and don't delete
  the versioned attachments they name (`levels-1769472000.dat` and the like) —
  those are copies DOS Station saved back from the DOS drive.
- Don't change the body of a block that carries a `dos-name` unless the user
  asks: that text is a live file on their DOS drive.
