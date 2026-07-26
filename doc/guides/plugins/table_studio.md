# Table Studio

Table Studio opens the tables a note carries in a real spreadsheet — formulas, cell formatting, sort, filter, merges, insert/delete/move of rows and columns, undo/redo, and multi-sheet workbooks.

Select one or more notes and launch **Table Studio** from the note actions menu.

## What It Can Open

-   **Markdown pipe tables** in the note body. They are parsed out of the note and written back in place, pretty-printed, with column alignment (`:---`, `:---:`, `---:`) carried through to the sheet and back. Tables inside code fences are left alone.
-   **Spreadsheet attachments**. `.csv`, `.tsv`, `.xlsx` and `.ods` open for editing. `.xls` and `.xlsm` open read-only so macros and legacy formatting cannot be damaged, with a one-tap **Save copy** as `.xlsx`.

On a phone or tablet the spreadsheet switches to a touch-first interface, with selection handles, context menus and a sheet bar sized for fingers.

## The First Launch

The spreadsheet engine is about 12 MB, too large to ship inside a plugin file. The first time you open an editor the app asks permission, downloads it, and checks each file against a pinned hash. After that it runs from cache, offline.

## How Saves Work

**Markdown tables, CSV and TSV** are read back as text. A number cell only becomes a real number when the conversion round-trips exactly, so `3.10` stays as written. These formats cannot hold formulas: if you used any while editing, saving flattens them to their computed values after you confirm. Before overwriting a markdown table the app re-reads the note and checks the original text is still there, so a note edited elsewhere in the meantime is not clobbered.

**XLSX and ODS** load with live formulas, merges and number formats. Untouched sheets are carried through byte-identical, and an edited sheet is patched cell by cell so untouched cells keep their formulas, types and formats. If you insert, delete or move rows or columns, or sort, that sheet is rewritten in full. Sheets you add, remove, rename or reorder flow through to the file.

## Known Limits

-   Attachments over 15 MB, sheets over roughly 200k cells or 512 columns, and non-UTF-8 text files are refused up front.
-   Colors, bold and other visual styling applied in the editor are not written to `.xlsx` or `.ods` files, and a structurally edited sheet loses styling it already had. Values, formulas, merges and number formats are kept. A styling-only change therefore saves as "No changes to save".
-   Conditional formatting, data validation and filters work while you edit but are not persisted into the saved file.
-   The ODS writer may drop formulas; `.xlsx` keeps them.
-   On multi-megabyte notes the pre-save read can hit Android's cursor limits. The save then aborts with an error.
