#!/bin/bash
# Build the installable Note Synapse user-app YAML from the readable HTML
# source. The core logic modules, fflate and the pinned SheetJS
# distribution are inlined; the (much larger) Univer engine is NOT inlined
# — the app downloads it once at runtime, sha256-verified against the pins
# in src/univer_bridge.js, and caches it in app state.
set -euo pipefail
cd "$(dirname "$0")"

SOURCE="table_studio.html"
CORE="src/table_core.js"
BRIDGE="src/univer_bridge.js"
FFLATE="vendor/fflate-0.8.2.min.js"
VENDOR="vendor/xlsx-0.20.3.full.min.js"
OUTPUT="Table_Studio.yaml"
TMP_HTML="$(mktemp)"
trap 'rm -f "$TMP_HTML"' EXIT

inline_script() {
  printf '  <script>\n'
  sed 's#</script>#<\\/script>#g' "$1"
  printf '\n  </script>\n'
}

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" == *'<script src="src/table_core.js"></script>'* ]]; then
    inline_script "$CORE"
  elif [[ "$line" == *'<script src="src/univer_bridge.js"></script>'* ]]; then
    inline_script "$BRIDGE"
  elif [[ "$line" == *'<script src="vendor/fflate-0.8.2.min.js"></script>'* ]]; then
    inline_script "$FFLATE"
  elif [[ "$line" == *'<script src="vendor/xlsx-0.20.3.full.min.js"></script>'* ]]; then
    inline_script "$VENDOR"
  else
    printf '%s\n' "$line"
  fi
done < "$SOURCE" > "$TMP_HTML"

# GNU base64 wraps by default while macOS base64 does not.
CODE="$(base64 < "$TMP_HTML" | tr -d '\n')"

{
  printf '%s\n' \
    'name: Table Studio' \
    'uuid: 054e7289-7008-4be5-a865-a9fd8d77f09c' \
    'app_type: note_action' \
    'description: A real spreadsheet for the tables in your notes, powered by Univer - formulas, formatting, sort, filter, merges and multi-sheet editing for markdown pipe tables and CSV/TSV/XLSX/ODS attachments, with safe read-only handling of legacy Excel formats.' \
    'author: Note Synapse' \
    'license: Apache-2.0'
  printf 'code: %s\n' "$CODE"
} > "$OUTPUT"

echo "Wrote $OUTPUT"
