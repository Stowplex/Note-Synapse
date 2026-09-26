# Gantt

A Gantt chart user app for Note Synapse. Each bar is a task note, and the whole chart lives in one ordinary note. Works on Android and iOS phones and tablets, in English and Simplified Chinese.

Two apps are installed from one HTML file:

| File | Name | Type | What it does |
|---|---|---|---|
| `plugins/Gantt.yaml` | Gantt (甘特图) | normal | A home screen with New chart, Recents and the charts in the current Space. |
| `plugins/Gantt_This_Note.yaml` | Gantt: this note (甘特图：当前笔记) | note_action | Opens the note as a chart. On a plain note it offers Open in a chart, Add to a chart, Turn this note into a chart and New chart starting with this note. On several notes: a new chart with them, or add them to a chart. |

License: Apache-2.0. Author: Bruce Li.

## Using a chart

- **Look around.** Drag to pan, pinch to zoom (dates only; rows keep their height), double-tap to zoom in. D, W and M jump to day, week and month zoom; the buttons at the bottom right zoom in, zoom out and fit every task. Today puts today at the left third. Tap a date in the header to scroll there.
- **Select and edit.** Tap a bar to select it and open its sheet: dates, milestone, colour, the completion list, Open note, and Remove from chart (tap it twice). Long-press a bar to lift it, then drag sideways to move it or up and down to reorder it. A selected bar has handles at both ends to change its start or end. Long-press a name to reorder rows. Moves snap to days (weeks when zoomed far out) and skip non-working days.
- **Add.** The `+` button adds existing notes (the note picker), creates a task note (title, dates, steps as checklist items or sub-notes, and an optional link back to the chart), or adds a milestone. Tasks with no dates sit in Unscheduled; tap their dashed bar to schedule them.
- **Completion.** A bar fills with the share of its sub-items that are done: the note's sub-notes and linked child tasks (what the Calendar counts), or the checkboxes under one heading, or its status, set per chart. Tick sub-items right in the sheet. Bars are coloured by status (done, in progress, to do, overdue, dropped) and never by colour alone: the chip, "Overdue" and "Dropped" say it in words.
- **More.** Fit all, Expand all, Collapse all, Legend, Display (row height, weekend shading, week numbers), Chart settings, Appearance (Auto, Light, Dark), Rename chart, Open chart note, and Task list.
- **Task list.** Every task as a plain list with its dates, progress and status, grouped like the chart (collapsed groups too). It is the screen-reader friendly view of the chart; a row opens the task's sheet, and closing that sheet comes back to the list.
- **Undo.** Every edit can be undone, including ticks, renames and settings. View changes (zoom, scroll, collapse, theme) are not edits.

### Keyboard

With a hardware keyboard: the name column is one tab stop. Up and Down move between rows (a task row selects its task), Home and End go to the first and last row, Enter or Space opens a task's sheet or folds a group, Left and Right fold a group. On a selected task, Left and Right move it by one step, Shift+Left/Right move its end, Alt+Left/Right its start, Alt+Up/Down reorder it, Delete asks to remove it. Ctrl/Cmd+Z undoes, Shift+Ctrl/Cmd+Z redoes, `+` and `-` zoom, `t` goes to today, `d`, `w` and `m` pick a zoom. Esc closes the sheet. In menus and the Task list, Up, Down, Home and End move between rows.

### Accessibility

Bars and name rows are buttons named like "Sync engine, Oct 12 – Nov 6, 26 days, 6 of 10 done, overdue". Group headers say how many tasks they hold and whether they are expanded. Sheets are dialogs named by their title; focus moves into a sheet when it opens and back when it closes. The system's reduced-motion setting turns off every animation: zooming, lifting and flashing rows become instant or still.

### Languages

The app follows Note Synapse's language (English or Simplified Chinese) and switches live, keeping the selection, the view and an open sheet with whatever was typed in it. Dates follow the language too; the first day of the week and the weekend follow the region, unless the chart sets "Week starts on". Right-to-left languages are not supported.

What the app writes into notes is never translated: the task list above the chart, the chart block and the checklist heading of a chart stay as they were written. A new chart's checklist heading is "Checklist" or "清单", picked from the language when the chart is created, and task notes created from that chart use the same heading.

## The chart note

A chart is an ordinary note. The plugin owns one region at the end of it: an optional embed line, a readable task list, then a fenced block:

````markdown
- **Build**
  - [Sync engine](synapseresource://note/77aa3c21-…?via=gantt) · 2026-10-12 → 2026-11-06 · 6/10

```synapse-gantt
{"v":1,
"groups":[
 {"id":"g2","title":"Build","color":"teal"}
],
"tasks":[
 {"id":"t3","note":"77aa3c21-…","title":"Sync engine","start":"2026-10-12","end":"2026-11-06","group":"g2"}
]}
```
````

- The block is the chart. The list above it is generated from the block on every save and gives you tappable links in the editor. Chart settings turn it off, or add the chart itself inside the note.
- Everything outside that region is yours and is never rewritten.
- If you edit a line of the list so that it no longer has the generated shape (for example you add text after the progress), that line and the ones above it become your text. They are kept, the next save writes a fresh list below them, and the chart says so once ("The task list above the chart was edited. It is kept as your text.").
- If you delete lines of the list in the editor, the chart asks: "Removed in the note: X, Y. Remove from chart?" **Remove** takes those tasks off the chart (the notes are kept; Undo brings them back). **Restore list** writes the list again. Nothing happens until you tap one. If you ignore it, the next save writes the full list again.
- Task notes are referenced by id, so renaming a task note never breaks the chart. Removing a task from the chart never deletes its note.

## How saving works

- A save never replaces the whole note. It replaces exactly the region it last read, with Note Synapse's `replace_text` edit. If the note changed in the meantime (you edited it elsewhere), the edit misses, the chart reads the note again, merges its changes with yours and writes the merged chart. Two changes to the same field of the same task open a sheet where you choose which to keep.
- Note Synapse asks before an app edits a note. The first time, the app explains: tick "Allow for this session", then Approve, so the chart saves as you work. Moves and resizes save when you let go; typing and settings save a moment later.
- If you approve without ticking the box, Note Synapse asks on every save, so the chart switches to "Unsaved changes. Tap to save": nothing is written until you tap. After a refusal it shows "Not saved. Tap to save".
- Unsaved changes are kept on the device (the app's own storage, which needs no approval) until they are saved. If the app closes before that, the next open offers them: "Unsaved changes from … [Restore] [Discard] [Copy chart JSON]".
- Ticking a sub-note writes to the database, which Note Synapse approves separately; the app explains this before the first one.
- Dates can also be written into the task notes themselves (Chart settings, "Write dates to task notes"), so they show in the Calendar. They ride in the same approval as the chart.

## Known limits

- **Dark mode.** Older Note Synapse builds do not tell apps whether they are dark. There the app follows the system theme, and More ▸ Appearance says so: if you run Note Synapse dark on a light system, pick Dark there. Builds that publish their theme to apps (`Synapse.theme`) are followed automatically in Auto.
- The chart list and "Open in …" find a chart by the first occurrence of ```` ```synapse-gantt ```` in a note. A note that mentions the fence inline before its real block is missing from those lists, but still opens with "Gantt: this note". A fence indented by 4 or more spaces is a code block, not a chart.
- The two apps keep separate settings and separate unsaved-edit journals: an edit left unsaved in one is offered only by that one.
- Dependencies (`after`) are kept in the block but not drawn.
- **Accepted exposure windows.** A few rare crash timings can still lose an edit; each needs a crash inside one round trip and is documented in `.claude/plans/2026-09-25-gantt-chart-user-app.md`, section 9.3 "Guarantees": (a) a crash between a change and the moment it is stored on the device (one frame plus two storage calls, well under 100 ms); (b) a crash right after a save lands, when during that save you changed a field back to its old value (only that field is lost); (c) two full copies of the app writing their unsaved-edit record within one storage round trip; (d) while a banner offers another copy's unsaved edits, your newer edits live only in memory until you answer it.

## Device checklist

The browser suites cover the logic. These need a real mid-range Android phone and an iPhone (iOS 16 or later) before a release; section 17.4 of the plan (`.claude/plans/2026-09-25-gantt-chart-user-app.md`) has the full wording:

1. Smooth pan on a big chart; pinch stays under the fingers; the page itself never zooms.
2. A quick swipe on a bar scrolls; a long press lifts it without the iOS callout; drags step and autoscroll.
3. Handles are reachable on one-day bars; milestones cannot resize.
4. Reorder across a group; undo and redo each step.
5. Sheet detents, native date pickers, the rename field above the keyboard.
6. Rotation keeps the date in view; side panel in landscape; notch and home-indicator insets.
7. A system theme change switches live; the Appearance choice wins.
8. Switching Note Synapse to Chinese relabels headers and weekdays in place; weeks start on Monday.
9. Five minutes in the background: the chart comes back intact and the today line is right.
10. Reduced motion: no animated zoom or lift.
11. TalkBack and VoiceOver read the bars and the Task list; checkboxes toggle.
12. Open and close a chart ten times on an older iPhone without canvas memory errors.
13. The approval notice and the three save modes, and the Restore banner after Android back.
14. A body edit made in the editor while the chart is open survives a bar move.

## Building

Only `plugins/build.sh` writes the YAMLs. After any change under `plugins/`:

```bash
bash contrib/gantt/plugins/build.sh && node contrib/gantt/dev/build_check.js
PATH="$HOME/Library/Android/sdk/cmake/4.1.2/bin:$PATH" flutter test test/contrib_gantt_test.dart
```

**Never edit the HTML or JS here with `sed -i` or `perl -pi`.** It has caused mojibake on non-ASCII text (the Chinese strings, `·`, `→`, `◆`). Use an editor.

The app uuids were generated once and must never change: `aac1665f-3f18-425c-a2f5-6e6001d75326` (Gantt; also `GT.APP_UUID` in `src/host.js`, which the embed line names) and `2d96f7fe-b846-4eda-9ab8-81a1b8735fe8` (Gantt: this note).

## Developing

- `node contrib/gantt/dev/run.js`: every test that needs no DOM (data model, block format, store and host against the mock, the i18n audit).
- `python3 -m http.server 8791 --directory contrib/gantt &`, then from `contrib/gantt`: `node dev/chrome.js dev/auto_smoke.html` (modules in a browser) and `node dev/chrome.js dev/app_smoke.html` (app flows over the mock host).
- `dev/harness.html`: the app over the mock host, by hand.
- `dev/shot.html?fixture=&theme=&today=&locale=&launch=&do=&w=&h=`: the real shell over a fixture, for screenshots (`w` and `h` put it in a frame of exactly that size, since headless Chrome will not make a window narrower than about 500 px). `dev/shell.js` lists every parameter.

Rules for builders:

- Only `src/host.js` touches `Synapse` or listens to `synapse:*` events (a test greps for it). The host events it follows are `synapse:localechanged`, `synapse:spacechanged`, and, where the host has them, `synapse:themechanged` and `synapse:resumed` (a route return, which joins the other resume triggers).
- Only `src/store.js` calls host writes. Saves are `replace_text` of the region last read; never a whole-note replace, never `deleteNotes`.
- Note text reaches the DOM through `textContent` only.
- Every UI string goes through `i18n.text` or `i18n.fmt` and has a zh-CN entry in the one `ZH` table (patterns with `{slots}` in `ZH_PATTERNS`); labels in `gantt.html` carry `data-i18n` or `data-i18n-label`. The audit in `dev/m9_spec.js` fails on any English string without an entry.
- Modules are an IIFE plus `module.exports` under the `GT` namespace; pure modules never touch `window` or `document` when loaded.

The design and its decisions are in `.claude/plans/2026-09-25-gantt-chart-user-app.md`.
