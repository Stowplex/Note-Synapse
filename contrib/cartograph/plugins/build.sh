#!/bin/bash
# Build the installable Note Synapse user-app YAML from the readable HTML
# source. Cartograph has no third-party dependencies - the modules under src/
# are inlined into a single self-contained HTML file.
set -euo pipefail
cd "$(dirname "$0")"

SOURCE="cartograph.html"
OUTPUT="Cartograph.yaml"
MODULES=(md edit sidecar layout view diff ai host app)
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

DESC='Turns a note into an editable mind map - headings and bullets become branches, and every change on the map is written straight back into the note markdown. Drag to re-nest or pin, flip between map and outline, focus a branch, search and filter, and roll up checkbox progress. Generates a map with AI into a companion note, imports another note as a branch, and reshapes branches with AI behind a preview you approve.'

# The same HTML ships twice. A `normal` launch arrives with no note and shows
# the standalone home; a `note_action` launch arrives with one and maps it. The
# app tells them apart at runtime, so there is no build flag and no code fork.
# Names and descriptions are emitted as double-quoted YAML scalars. "Cartograph:
# this note" contains a colon, which is a mapping indicator in a plain scalar
# and makes the whole file unparseable.
yq() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

emit() {
  {
    printf 'name: "%s"\n' "$(yq "$1")"
    printf 'uuid: %s\n' "$2"
    printf 'app_type: %s\n' "$3"
    printf 'description: "%s"\n' "$(yq "$DESC")"
    printf '%s\n' 'author: Bruce Li' 'license: Apache-2.0'
    printf 'code: %s\n' "$CODE"
  } > "$4"
  echo "Wrote $4"
}

emit 'Cartograph'            '00713e85-2847-4a4a-9d73-c1685136e0b6' 'normal'      'Cartograph.yaml'
emit 'Cartograph: this note' '96d13a4a-3c59-4e2c-9522-0dfee4101da0' 'note_action' 'Cartograph_This_Note.yaml'

echo "($(wc -c < "$TMP_HTML" | tr -d ' ') bytes of HTML)"
