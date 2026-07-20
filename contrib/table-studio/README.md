# Table Studio

A note action plugin for Note Synapse that lets you edit every table a note
carries in a fluid, touch-first spreadsheet:

- **Markdown pipe tables** in the note body — parsed straight out of the
  note's GitHub-flavored markdown (code fences are respected, so tables inside
  ``` blocks are never touched) and written back in place, pretty-printed and
  with per-column alignment (`:---`, `:---:`, `---:`) preserved and editable.
- **Spreadsheet attachments** — `.csv`, `.tsv`, `.xlsx`, and `.ods` files open
  for editing; `.xls` and `.xlsm` open read-only (so macros and legacy
  formatting can never be damaged) with a one-tap "Save copy as .xlsx".

## Features

- Clean light/dark spreadsheet grid with sticky row/column headers, tap to
  select, tap again to edit, and Enter-to-advance data entry that grows the
  sheet as you type.
- Insert/delete rows and columns, per-column markdown alignment, undo/redo.
- Multi-sheet workbooks get sheet tabs; only sheets you actually edit are
  rewritten, the rest of the workbook is carried through untouched.
- CSV round-tripping preserves the original delimiter, quoting, line endings,
  BOM, and trailing newline. Cells containing pipes or line breaks survive the
  markdown round trip (`\|` and `<br>` handling).
- New tables can be appended to a note and new CSV attachments created from
  scratch.
- Before overwriting a markdown table it re-reads the note and verifies the
  original table text is still present, so a note edited elsewhere in the
  meantime is never clobbered.
- Workbooks with formulas show a warning before saving flattens them to
  values; oversized files are refused instead of half-loaded.

## Install

Open `plugins/Table_Studio.yaml` with Note Synapse (share/open it on your
device) to import the app, then select one or more notes and launch
**Table Studio** from the note actions menu.

## Layout

```
plugins/
  table_studio.html   # readable source (UI + Synapse integration)
  src/table_core.js   # pure table/CSV parsing & serialization logic
  vendor/             # pinned SheetJS CE 0.20.3 (Apache-2.0) for xlsx/ods
  build.sh            # inlines src+vendor and regenerates Table_Studio.yaml
  Table_Studio.yaml   # the installable app (base64 of the built HTML)
dev/
  run_core_tests.mjs  # offline unit tests for table_core.js (node)
  harness.html        # browser harness with a stubbed Synapse API
  synapse_stub.js     # the stub used by the harness
```

## Development

- Edit `plugins/table_studio.html` / `plugins/src/table_core.js`, then run
  `plugins/build.sh` to regenerate the YAML.
- `node dev/run_core_tests.mjs` runs the parser/serializer unit tests.
- `python3 -m http.server` from this folder, then open
  `http://localhost:8000/dev/harness.html` to drive the full UI in a desktop
  browser against a stubbed `window.Synapse` with sample data.
- `flutter test test/contrib_table_studio_test.dart` (repo root) checks the
  packaged YAML stays in sync with the source.

## License

Apache-2.0 (see `LICENSE`). The vendored SheetJS Community Edition is
Apache-2.0 (see `plugins/vendor/LICENSE.sheetjs`).
