# Table Studio

A note action plugin for Note Synapse that opens every table a note carries
in a **real spreadsheet** — [Univer](https://github.com/dream-num/univer),
the open-source Google-Sheets-class engine — with formulas, cell
formatting, sort, filter, merges, insert/delete/move of rows and columns,
undo/redo and multi-sheet workbooks.

- **Markdown pipe tables** in the note body — parsed straight out of the
  note's GitHub-flavored markdown (code fences are respected, so tables
  inside ``` blocks are never touched) and written back in place,
  pretty-printed, with per-column alignment (`:---`, `:---:`, `---:`)
  mapped to the sheet's horizontal alignment and preserved on save.
- **Spreadsheet attachments** — `.csv`, `.tsv`, `.xlsx`, and `.ods` open
  for editing; `.xls` and `.xlsm` open read-only (so macros and legacy
  formatting can never be damaged) with a one-tap "Save copy" as .xlsx.

## The Univer engine

Univer's UMD bundles are ~12 MB — far too large to embed in an installable
user-app YAML. Instead the app follows the DOS Station pattern:

1. The first time an editor is opened, the app asks for consent and then
   downloads the engine (react 18.3.1, react-dom, rxjs 7.8.2,
   `@univerjs/presets` 0.25.1 and the sheets-core / sort / filter /
   hyper-link / data-validation / conditional-formatting presets) from
   jsdelivr, falling back to unpkg. Nothing is downloaded before the user
   taps "Download", and Back cancels a download in progress (already
   fetched files are kept so a retry resumes).
2. Every file is verified against a **pinned sha256** (see
   `plugins/src/univer_bridge.js`) before it is allowed to execute; a
   mismatch skips the mirror, and an unverifiable download is refused.
3. The verified bundle is gzipped (vendored fflate 0.8.2) and cached in
   the app's state, so every later launch — including offline — boots
   from the local cache.

SheetJS CE 0.20.3 (xlsx/ods I/O) and fflate stay vendored inside the YAML
as before.

On touch devices the app swaps Univer's desktop UI plugins for its
dedicated mobile UI (`UniverMobileUIPlugin` / `UniverSheetsMobileUIPlugin`,
shipped inside the same pinned bundle), so the spreadsheet gets
touch-first selection handles, context menus and sheet bar.

To upgrade the engine: `node dev/regen_engine_pins.mjs <new-version>`
prints fresh ready-to-paste manifest entries (paths, sizes, sha256) for
`plugins/src/univer_bridge.js`; bump `ENGINE.version`, re-run
`dev/fetch_univer_mirror.sh`, the harnesses, and `plugins/build.sh`.

## How saves work

- **Markdown tables / CSV / TSV**: the sheet is read back as text. Number
  cells only ever become real numbers when the conversion is round-trip
  stable ("3.10" stays text), so untouched cells never change spelling.
  Formulas can be used while editing; saving flattens them to their
  computed values after an explicit confirmation (these formats cannot
  hold formulas). CSV round-tripping preserves the original delimiter,
  quoting, line endings, BOM, trailing newline and ragged-row shapes.
  Before overwriting a markdown table the app re-reads the note and
  verifies the original table text is still present, so a note edited
  elsewhere in the meantime is never clobbered.
- **XLSX / ODS**: sheets are loaded with live formulas, merges and number
  formats. On save, untouched sheets are carried through byte-identical.
  An edited sheet is cell-diff patched against its load baseline
  (untouched cells keep their formulas, types and formats); once a
  structural edit (insert/delete/move rows or columns, sort) has touched
  a sheet it is rewritten wholesale from the spreadsheet — values,
  formulas, merges and number formats included. Sheets added, removed,
  renamed or reordered in the editor flow through to the file.

## Known limits

- The first launch needs a network connection for the one-time engine
  download (~12 MB, ~3 MB cached); after that the app works offline.
- Attachments over 15 MB, sheets over ~200k cells / 512 columns, and
  non-UTF-8 text files are refused up front rather than opened lossily.
- SheetJS CE cannot write visual styling: colors/bold/etc. applied in the
  editor are not persisted to xlsx/ods files, and a rewritten (structurally
  edited) sheet loses pre-existing visual styling. Number formats, merges,
  values and formulas are persisted. Styling-only changes therefore save
  as "No changes to save".
- Conditional formatting, data validation and filters work while editing
  but are not persisted into the saved files.
- ODS output is limited by SheetJS's ODS writer (formulas may be dropped
  there; xlsx keeps them).
- On very large notes (multi-megabyte bodies) the pre-save fresh-content
  read can fail on Android's cursor limits; the save then aborts with an
  error instead of risking a stale overwrite.

## Install

Open `plugins/Table_Studio.yaml` with Note Synapse (share/open it on your
device) to import the app, then select one or more notes and launch
**Table Studio** from the note actions menu. (It also ships as a starter
app: `assets/starter/apps/Table_Studio.yaml`, same build.)

## Layout

```
plugins/
  table_studio.html    # readable source (UI + Synapse integration + loader)
  src/table_core.js    # pure markdown/CSV parsing & serialization logic
  src/univer_bridge.js # engine manifest (sha256 pins) + snapshot conversion
  vendor/              # pinned SheetJS CE 0.20.3 + fflate 0.8.2
  build.sh             # inlines src+vendor and regenerates Table_Studio.yaml
  Table_Studio.yaml    # the installable app (base64 of the built HTML)
dev/
  run_core_tests.mjs      # offline unit tests for both src modules (node)
  harness.html            # browser harness with a stubbed Synapse API
  auto_smoke.html         # end-to-end UI checks (headless Chrome friendly)
  synapse_stub.js         # the stub used by both harnesses
  fetch_univer_mirror.sh  # local engine mirror so dev runs skip the CDN
  regen_engine_pins.mjs   # prints fresh manifest pins for engine upgrades
```

## Development

- Edit `plugins/table_studio.html` / `plugins/src/*.js`, then run
  `plugins/build.sh` to regenerate the YAML (copy it to
  `assets/starter/apps/` too — a repo test checks they match).
- `node dev/run_core_tests.mjs` runs the pure-logic unit tests.
- `dev/fetch_univer_mirror.sh` populates `dev/univer-mirror/` (gitignored)
  so the harnesses serve the engine locally; without it the stub falls
  back to the real CDN.
- `python3 -m http.server` from this folder, then open
  `http://localhost:8000/dev/harness.html` for the interactive harness or
  `.../dev/auto_smoke.html` for the scripted end-to-end checks (also runs
  under `chrome --headless=new --virtual-time-budget=180000 --dump-dom`).
- `flutter test test/contrib_table_studio_test.dart` (repo root) checks the
  packaged YAML, the vendor pins and the capability surface.

## License

Apache-2.0 (see `LICENSE`). Vendored: SheetJS Community Edition
(Apache-2.0, `plugins/vendor/LICENSE.sheetjs`), fflate (MIT,
`plugins/vendor/LICENSE.fflate`). Downloaded at runtime: Univer
(Apache-2.0), React (MIT), RxJS (Apache-2.0).
