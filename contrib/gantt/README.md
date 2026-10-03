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
- **Select and edit.** Tap a bar to select it and open its sheet: its name, dates, milestone, colour, group, the completion list, Open note, and Remove from chart (tap it twice). Long-press a bar to lift it, then drag sideways to move it or up and down to reorder it. A selected bar has handles at both ends to change its start or end. Long-press a name to reorder rows. Moves snap to days (weeks when zoomed far out) and skip non-working days.
- **Add.** The `+` button adds existing notes (the note picker), creates a task note (title, dates, steps as checklist items or sub-notes, and an optional link back to the chart), adds a milestone (a small sheet: title, date, group, and an optional note to link; an empty title is "Milestone"), or adds a group. Tasks with no dates sit in Unscheduled; tap their dashed bar to schedule them.
- **Names.** A milestone without a note has a Title field in its sheet; the name is saved when you leave the field, press Enter or close the sheet, and Esc puts the old one back. Link note… gives it a note (one already on the chart is refused), and from then on it carries the note's title. For a task with a note the field is "Note title": it renames the note itself, everywhere it appears, and is sent only when you press Enter or tap Rename, with one approval from Note Synapse. Leaving the field keeps what you typed; closing the sheet drops it. When the chart saves automatically, the task list line follows at once; otherwise it follows with your next save. Rename tasks in the sheet, not in the note's task list: link text there is written from the chart on every save.
- **Completion.** A bar fills with the share of its sub-items that are done: the note's sub-notes and linked child tasks (what the Calendar counts), or the checkboxes under one heading, or its status, set per chart. Tick sub-items right in the sheet. Bars are coloured by status (done, in progress, to do, overdue, dropped) and never by colour alone: the chip, "Overdue" and "Dropped" say it in words.
- **More.** Fit all, Expand all, Collapse all, Groups, Legend, Display (row height, weekend shading, week numbers), Chart settings, Appearance (Auto, Light, Dark), Rename chart, Open chart note, Export image, and Task list.
- **Task list.** Every task as a plain list with its dates, progress and status, grouped like the chart (collapsed groups too). It is the screen-reader friendly view of the chart; a row opens the task's sheet, and closing that sheet comes back to the list.
- **Undo.** Every edit can be undone, including ticks, renames, group changes and settings. View changes (zoom, scroll, collapse, theme) are not edits.

### Groups

- **Collapse and expand.** Tap a group header to fold or unfold it; the arrow on the header turns to show which. Expand all and Collapse all are in More. Which groups are folded is remembered per chart on this device only; it is never written to the note.
- **What a header shows.** Its name and how many tasks the group holds, dated or not. A group whose tasks include undated ones says "2 unscheduled" (those rows stay in Unscheduled at the bottom). An empty group says "Drag tasks here" when the chart can be edited; on a narrow name column the hint sits in the chart area of that row instead.
- **Drag a task to another group.** Long-press a bar or a name and drag it up or down. Dropped among the rows of an open group, it joins that group at that place; the bubble says where it goes ("→ Build"). To put it at the end of a folded or empty group, drop it on the lower half of that group's header: the header is outlined, its count goes up by one while you hover, and the group stays folded. While you drag on a chart where no dated task is ungrouped, a "No group" row appears at the top; drop there to take the task out of every group. Dragging near the top or bottom edge scrolls. When the task lands somewhere you cannot see (a folded group), the header flashes and a message says "Moved to Build" with Undo (or "Removed from its group" when it leaves every group). Tasks in Unscheduled keep their place there, but can change group the same way, by dropping on a folded or empty header or on "No group".
- **Group row in the task sheet.** Below Colour: No group, each group, and New group…. A tap moves the task to the end of that group and saves at once; New group… creates a group and moves the task into it as one step. This is also the way to regroup without dragging.
- **The group sheet.** Long-press a group header (or use More ▸ Groups) to open it: the name (a group needs one; a name equal to the task list heading is allowed, with a hint), the colour (Auto or a swatch), Move up and Move down, Collapse or Expand, and Delete group. Delete asks for a second tap; the tasks of a deleted group become ungrouped, and Undo brings the group back with its tasks. A chart you cannot edit shows the name and Collapse only.
- **More ▸ Groups** lists every group with its task count, Up and Down buttons to reorder, and Add group. A row opens that group's sheet, and closing it comes back to the list. This is the screen-reader route to every group action.
- **Add a group** from the `+` button or More ▸ Groups ▸ Add group. It goes after the selected task's group, or last, and the chart scrolls to it.

### Keyboard

With a hardware keyboard the name column is one tab stop.

| Keys | On a task row or selected task | On a group header |
|---|---|---|
| Up, Down | Previous or next row (a task row selects its task) | Previous or next row |
| Home, End | First or last row | First or last row |
| Enter, Space | Open the task's sheet | Fold or unfold |
| Left, Right | Move the selected task by one step | Left folds, Right unfolds |
| Shift+Left/Right | Move the end | |
| Alt+Left/Right | Move the start | |
| Alt+Up/Down | Reorder the task, across group boundaries; into a folded group it says "Moved to …" and focus goes to that header | Move the group up or down |
| Shift+Enter, F2 | F2: open the sheet with the name field focused (Enter saves or renames, Esc restores); Shift+Enter acts as Enter | Open the group sheet |
| Delete, Backspace | Ask to remove the task (press again to remove) | Open the group sheet with Delete armed (press again to delete) |

Anywhere: Ctrl/Cmd+Z undoes, Shift+Ctrl/Cmd+Z redoes, `+` and `-` zoom, `t` goes to today, `d`, `w` and `m` pick a zoom, Esc closes the sheet. In menus, More ▸ Groups and the Task list, Up, Down, Home and End move between rows; in the Group row of the task sheet the arrow keys move between groups and Space or Enter picks one.

### Accessibility

Bars and name rows are buttons named like "Sync engine, Oct 12 – Nov 6, 26 days, 6 of 10 done, overdue". Group headers are buttons that say their name, how many tasks they hold (and how many are unscheduled) and whether they are expanded; they are 32 px tall (28 in compact rows), under the usual 44 px, with the full row as the target. Sheets are dialogs named by their title; focus moves into a sheet when it opens and back when it closes. The Group row is a radio group. The system's reduced-motion setting turns off every animation: zooming, lifting and flashing rows become instant or still.

### Languages

The app follows Note Synapse's language (English or Simplified Chinese) and switches live, keeping the selection, the view and an open sheet with whatever was typed in it. Dates follow the language too; the first day of the week and the weekend follow the region, unless the chart sets "Week starts on". Right-to-left languages are not supported.

What the app writes into notes is never translated: the task list above the chart and its heading, the chart block and the checklist heading of a chart stay as they were written. A new chart's checklist heading is "Checklist" or "清单" and its task list heading "Tasks" or "任务", picked from the language when the chart is created, and task notes created from that chart use the same checklist heading.

## The chart note

A chart is an ordinary note. The plugin owns one region at the end of it: the task list, which starts at a heading, then the chart block:

````markdown
Launch plan for the Q4 release.

## Tasks

- [Kickoff](synapseresource://note/5d1e…?via=gantt) · 2026-09-30

### Discovery
- [Customer interviews](synapseresource://note/8f0c1e2a-…?via=gantt) · 2026-10-01 → 2026-10-09 · 3/5
  - Owner: Ana. Waiting on two more calls.
- [Competitive teardown](synapseresource://note/1b7d4e90-…?via=gantt) · 2026-10-05 → 2026-10-14 · 0/4

### Build
- [Sync engine](synapseresource://note/77aa3c21-…?via=gantt) · 2026-10-12 → 2026-11-06 · 6/10
- ◆ [Beta cut](synapseresource://note/c3e98a10-…?via=gantt) · 2026-11-09

Remember to book the launch room.

### Launch

```synapse-gantt
{"v":1,
"settings":{"listHeading":"Tasks",…},
"groups":[
 {"id":"g1","title":"Discovery"},
 {"id":"g2","title":"Build","color":"teal"},
 {"id":"g3","title":"Launch"}
],
"tasks":[…]}
```
````

`## Tasks` is the list heading. Tasks without a group come first (Kickoff), then each group under a `###` heading, empty groups too (Launch). The indented "Owner" line and the line "Remember to book the launch room." are yours: they stay under the task above them. Everything above `## Tasks` is yours and is never read or rewritten.

### The list and the block

- The list decides which group each task in it belongs to, the order of the tasks within a group, the order of the groups and their names. The block keeps everything else: dates, colours, milestones, dependencies, settings, and the group of a task the list does not show. Every save writes both. Chart settings turn the list off ("Task list above the chart"), change its heading and its level (the groups are always one level below), or add the chart itself inside the note.
- The heading is "Tasks", or "任务" for a chart created in Chinese, and the chart keeps it whatever the language later. It also recognises `## Tasks ##` and `### Build ##` (a closing `##`); the next save writes them without it.
- Text you add inside the list is kept where you put it: a line indented under a task, a paragraph, a code block or a heading of your own between groups, a line typed right above the block. It stays with the task or group line above it, so it moves when the chart moves that task, and it stays in the note when that task is removed. With the list turned off, those lines are kept above the block as ordinary text.
- Link text, dates and progress in the list are written from the chart, so edits to them are replaced on the next save. Rename a task from its sheet and a group from its group sheet or its `###` heading.
- With the list on, move tasks in the list or in the chart, not in the block's JSON: the list wins.
- Task notes are referenced by id, so renaming a task note never breaks the chart. Removing a task from the chart never deletes its note.

### Starting from your own headings

You can start from the note itself. Write headings and pick task notes with the editor's note-link button, right above a chart block:

```markdown
## Group 1
[Task note 1](synapseresource://note/…)
[Task note 2](synapseresource://note/…)

## Group 2
[Task note 3](synapseresource://note/…)
```

The next time the chart opens it asks "Use these headings as groups? The note lists 3 tasks in 2 groups above the chart." **Use as groups** makes a group for each heading and adds each linked note as a task (a note already on the chart just moves into the group), in one step, and the next save replaces those lines with the list: `## Tasks`, then `### Group 1` and `### Group 2` with the tasks under them. Undo takes the groups and tasks off the chart and puts your lines back as you wrote them. **Not now** hides the offer at once; your next change to the chart saves that choice in the block, so other devices stop asking too. It asks again only if those lines change. The offer also appears when a save has already put `## Tasks` below your lines, and for a section of your own made of headings and note links right above the list; Not now hides that until those lines change. Links with no heading above them are never offered.

### Editing the list in the note

What the chart picks up by itself, the next time it opens or you come back to it, with one message, "Updated from the note: Sync engine → Build" (three changes at most, then "and 2 more") and **Undo**:

- a task line moved under another `###` heading, or lines reordered within a group;
- `###` headings reordered (the groups follow) or renamed (same group, new name);
- a new `###` heading anywhere in the list (a new group, holding the task lines under it).

The message shows once per change on each device. Nothing is written to the note until you change the chart; that save then writes the list and the block together. When the chart has unsaved edits of its own, your note edits are merged into them by the next save, without the message.

What the chart asks about first (nothing changes until you tap):

- **Deleted lines.** A deleted task line or `###` heading gives "Removed in the note: Build (group), Sync engine. Remove from chart?" **Remove** takes them off the chart in one step (the notes are kept; Undo brings them back), and the tasks of a removed group go where the note now shows them. **Restore list** writes the list again. Ignored, the next save writes the full list again. The chart only asks about a list it wrote itself.
- **Links to other notes.** A link to a note that is not on the chart, on its own line in the list, gives "Added in the note: Vendor contract. Add to chart?" **Add** puts it on the chart where the link is. **Not now** hides it on this device until the link leaves the list and comes back. A link indented under a task, or under a heading of your own, is left alone.
- **A `##` heading typed inside the list** stays your text, and the chart offers "Make “Group 1” a group?". **Make groups** turns it into a group holding the tasks under it, and the lines between the heading and its first task go with it; the save writes it as `###`, and Undo brings the `##` line back. **Not now** hides the offer on this device. A `##` heading named like an existing group is not offered and stays your text.
- **A task listed twice** (a copied line, a second `###` heading with a group's name, or a link you put under another heading while the task's own line stays) keeps the group the block has, and the chart says "Listed more than once in the note: Sync engine. Delete one copy to let the chart update it."
- **An edited task line** (text added after its progress, or the line moved above `## Tasks`) is kept as your text: "The task list above the chart was edited. It is kept as your text." The next save writes the task's line again.

Add, Make groups and Use as groups work on the note as last read. If the note changed elsewhere while the chart has unsaved edits, these offers wait for the save that merges them.

### When the heading is missing

If the heading is deleted or mistyped, the chart cannot tell where its list starts, so it saves nothing and says "The “Tasks” heading above the task list is missing." Your edits are kept (the save pill reads "Restore the task list heading to save"), and nothing in the list is regrouped.

- **Restore heading** puts the heading back above the list in one edit and changes nothing else; then the edits save.
- **Use “Taks” as the list heading** appears when the list starts with one mistyped heading, and keeps yours.
- **Turn list off** leaves the list lines in the note as your text. Turning the list on again while those lines have no heading brings the banner back instead of writing a second list.

To find the list without its heading, the chart walks up from the block over task lines and `###` headings of this chart, and past headings of your own inside the list. It passes a stretch of your own sections only when the part above holds a `###` heading or at least two tasks it has not found yet, and it stops once it has found every task that has a line above the block. So a single stale task line or a lone `###` heading above your own sections stays outside and, after Restore heading, reads as edited (or as a removed group); nothing is lost. If it had to pass sections of your own and still finds fewer than half of the chart's tasks, the list counts as deleted, not headless, and the removal banner asks instead.

If another `## Tasks` heading of your own sits higher up in the note, it becomes the list heading: the region grows up to it, and your headings in between stay your text.

### Charts from earlier versions

- Charts made by earlier versions have a list of bold group names with indented tasks. They open as before, and their next save rewrites that list in the heading form; nothing else in the note changes. If you typed a line directly above the old list's first line before that save, the old list is kept above it as your text and a new list is written below it (once).
- An earlier chart whose task list is turned off gets its heading only when you turn the list on, and it then saves twice: the first save writes the old style, the second the heading form.
- **Repair** of a damaged block keeps its heading and level, and keeps the lines of its list above the new list as your text.
- Use the same version of the app on every device. An older version does not know the heading form: it writes a second, bold-style list inside the list. The chart then keeps the groups its block has for the tasks listed twice, adds no group, and says "Listed more than once"; delete the stale copy.

### Known limits of the list

- Typing the heading's own text (`## Tasks`) a second time inside the list makes the list start there: the part above it becomes your text, and the next save writes the tasks once more below it.
- After you change the heading level in Chart settings, a heading of your own inside the list that is now one level below the list heading reads as a group after the save (at the old level it was your text).
- If the app closes before list edits made by Add, Make groups or Use as groups are saved, Restore brings them back only if the task list and the chart block have not changed since; otherwise they are dropped without a message, and the lines stay in the note as your text (a promoted `##` heading next to its new `###` group, an added note's link as a plain line, a seed still offered).
- Lines added after the chart block, for example by a tool that inserts into the last group's section, are your text and are not read. Move a link above the block to add it.
- Renaming two empty groups at once in the note is read as those groups removed (the removal banner asks) and two new empty groups. A group with tasks keeps its identity through a rename, because its tasks stay under the heading.

## How saving works

- A save never replaces the whole note. It replaces exactly the region it last read, with Note Synapse's `replace_text` edit. If the note changed in the meantime (you edited it elsewhere), the edit misses, the chart reads the note again, merges its changes with yours and writes the merged chart. Two changes to the same field of the same task open a sheet where you choose which to keep; a task moved to different groups on two sides is such a change ("Group").
- Note Synapse asks before an app edits a note. The first time, the app explains: tick "Allow for this session", then Approve, so the chart saves as you work. Moves and resizes save when you let go; typing and settings save a moment later.
- If you approve without ticking the box, Note Synapse asks on every save, so the chart switches to "Unsaved changes. Tap to save": nothing is written until you tap. After a refusal it shows "Not saved. Tap to save".
- Unsaved changes are kept on the device (the app's own storage, which needs no approval) until they are saved. If the app closes before that, the next open offers them: "Unsaved changes from … [Restore] [Discard] [Copy chart JSON]".
- Ticking a sub-note writes to the database, which Note Synapse approves separately; the app explains this before the first one.
- Dates are written into the task notes themselves, so they show in the Calendar (Chart settings, "Write dates to task notes", on by default). They ride in the same approval as the chart. Plain notes (not tasks) keep their dates in the chart only. A date changed in a task note moves its bar the next time the chart reads it, with an "Updated from the note" toast and Undo. A chart whose task notes already hold other dates (from before this setting was on) shows a banner once: Update notes, Use note dates or Keep both. The task sheet shows a note's own dates under the date fields when they differ.

## Known limits

- **Dark mode.** Older Note Synapse builds do not tell apps whether they are dark. There the app follows the system theme, and More ▸ Appearance says so: if you run Note Synapse dark on a light system, pick Dark there. Builds that publish their theme to apps (`Synapse.theme`) are followed automatically in Auto.
- The chart list and "Open in …" find a chart by the first occurrence of ```` ```synapse-gantt ```` in a note. A note that mentions the fence inline before its real block is missing from those lists, but still opens with "Gantt: this note". A fence indented by 4 or more spaces is a code block, not a chart.
- The two apps keep separate settings and separate unsaved-edit journals: an edit left unsaved in one is offered only by that one.
- Dependencies (`after`) are kept in the block but not drawn.
- Groups are reordered from the group sheet, More ▸ Groups or Alt+Up/Down; a group header cannot be dragged.
- The task list's own limits are listed under "Known limits of the list" above.
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

Task groups and names (task-groups plan `.claude/plans/2026-09-26-gantt-task-groups.md`, §10.4 plus the rename check; each passes or fails):

15. Long-press a group header: the group sheet opens within 600 ms with no iOS callout or text selection, on Android and iOS; a tap still folds.
16. Drag a task onto a folded header and onto the "No group" row: it lands there (visible after expanding), with at most one approval dialog in manual saving; autoscroll reaches the last group of a 300-row chart without lifting the finger.
17. In the Note Synapse editor, drag a task link line under another `###` heading and come back: the message shows once, the bar sits in the new group, and the note's modified time did not change.
18. The chart note renders `## Tasks`, `###` headings, task links, an indented note line and a prose line as headings, links and indented text, in light and dark, and with `任务` in Chinese, matching `dev/shot.html?fixture=list-basic.md&launch=note&w=390&h=844` with `theme=light` or `theme=dark` (add `locale=zh-CN`, or use `list-cjk.md`, for Chinese).
19. TalkBack and VoiceOver announce a group header as a button with its name, count and expanded state, and reach every control of the group sheet, the task sheet's Group row and More ▸ Groups without touch-exploration tricks.
20. Type `## Group 1` under `## Tasks` in the editor and come back: the offer appears and Make groups creates the group. Type a line directly above the chart block and come back: nothing changes in the chart, and the line is still there after the next drag.
21. Rename a task with a note in manual saving with Enter: exactly one approval dialog, naming the task note, not the chart; dismissing the keyboard or tapping elsewhere sends nothing.

## Building

Only `plugins/build.sh` writes the YAMLs. After any change under `plugins/`:

```bash
bash contrib/gantt/plugins/build.sh && node contrib/gantt/dev/build_check.js
PATH="$HOME/Library/Android/sdk/cmake/4.1.2/bin:$PATH" flutter test test/contrib_gantt_test.dart
```

**Never edit the HTML or JS here with `sed -i` or `perl -pi`.** It has caused mojibake on non-ASCII text (the Chinese strings, `·`, `→`, `◆`). Use an editor.

The app uuids were generated once and must never change: `aac1665f-3f18-425c-a2f5-6e6001d75326` (Gantt; also `GT.APP_UUID` in `src/host.js`, which the embed line names) and `2d96f7fe-b846-4eda-9ab8-81a1b8735fe8` (Gantt: this note).

## Developing

- `node contrib/gantt/dev/run.js`: every test that needs no DOM (data model, block format, the task list's properties, store and host against the mock, the i18n audit). The property tests draw a seed from the clock; set `GT_SEED=<n>` to repeat a run.
- `python3 -m http.server 8791 --directory contrib/gantt &`, then from `contrib/gantt`: `node dev/chrome.js dev/auto_smoke.html` (modules in a browser) and `node dev/chrome.js dev/app_smoke.html` (app flows over the mock host). `GT_PORT` picks another port.
- `node contrib/gantt/dev/mutants/run.js [name …]`: the single-rule mutation check of the task-list reader, the fold, the drag layout and the store's banner gate and toast key; each mutant runs the node suite in a scratch copy (`GT_SEED` 7 by default) and must fail it.
- `dev/harness.html`: the app over the mock host, by hand.
- `dev/shot.html?fixture=&theme=&today=&locale=&launch=&do=&w=&h=`: the real shell over a fixture, for screenshots (`w` and `h` put it in a frame of exactly that size, since headless Chrome will not make a window narrower than about 500 px). `dev/shell.js` lists every parameter.

Rules for builders:

- Only `src/host.js` touches `Synapse` or listens to `synapse:*` events (a test greps for it). The host events it follows are `synapse:localechanged`, `synapse:spacechanged`, and, where the host has them, `synapse:themechanged` and `synapse:resumed` (a route return, which joins the other resume triggers).
- Only `src/store.js` calls host writes. Saves are `replace_text` of the region last read; never a whole-note replace, never `deleteNotes`.
- Note text reaches the DOM through `textContent` only.
- Every UI string goes through `i18n.text` or `i18n.fmt` and has a zh-CN entry in the one `ZH` table (patterns with `{slots}` in `ZH_PATTERNS`); labels in `gantt.html` carry `data-i18n` or `data-i18n-label`. The audit in `dev/m9_spec.js` fails on any English string without an entry.
- Modules are an IIFE plus `module.exports` under the `GT` namespace; pure modules never touch `window` or `document` when loaded.

The design and its decisions are in `.claude/plans/2026-09-25-gantt-chart-user-app.md`; the task list with groups, its two-way sync and the group UI in `.claude/plans/2026-09-26-gantt-task-groups.md`.
