#!/bin/bash
# Build the installable Note Synapse user-app YAML from the readable HTML
# source. Cartograph has no third-party dependencies - the modules under src/
# are inlined into a single self-contained HTML file.
set -euo pipefail
cd "$(dirname "$0")"

SOURCE="cartograph.html"
OUTPUT="Cartograph.yaml"
MODULES=(md edit sidecar layout view host app)
TMP_HTML="$(mktemp)"
trap 'rm -f "$TMP_HTML"' EXIT

inline_script() {
  printf '  <script>\n'
  sed 's#</script>#<\\/script>#g' "$1"
  printf '\n  </script>\n'
}

while IFS= read -r line || [[ -n "$line" ]]; do
  matched=""
  for m in "${MODULES[@]}"; do
    if [[ "$line" == *"<script src=\"src/$m.js\"></script>"* ]]; then
      inline_script "src/$m.js"
      matched="yes"
      break
    fi
  done
  [[ -n "$matched" ]] || printf '%s\n' "$line"
done < "$SOURCE" > "$TMP_HTML"

# GNU base64 wraps by default while macOS base64 does not.
CODE="$(base64 < "$TMP_HTML" | tr -d '\n')"

{
  printf '%s\n' \
    'name: Cartograph' \
    'uuid: 96d13a4a-3c59-4e2c-9522-0dfee4101da0' \
    'app_type: note_action' \
    'description: Turns the current note into an editable mind map, with no AI - headings and bullets become branches, and every change you make on the map is written straight back into the note markdown. Drag to re-nest or pin, flip between map and outline, focus a branch, search and filter, roll up checkbox progress, and attach, create or promote notes from any node.' \
    'author: Bruce Li' \
    'license: Apache-2.0'
  printf 'code: %s\n' "$CODE"
} > "$OUTPUT"

echo "Wrote $OUTPUT ($(wc -c < "$TMP_HTML" | tr -d ' ') bytes of HTML)"
