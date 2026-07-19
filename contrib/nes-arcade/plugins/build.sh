#!/bin/bash
# Build the installable Note Synapse user-app YAML from the readable HTML
# source. The pinned jsnes browser distribution is inlined so the imported
# app remains fully functional without network access.
set -euo pipefail
cd "$(dirname "$0")"

SOURCE="nes_arcade.html"
VENDOR="vendor/jsnes-2.0.0.min.js"
OUTPUT="Neon_Cartridge.yaml"
TMP_HTML="$(mktemp)"
trap 'rm -f "$TMP_HTML"' EXIT

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" == *'<script src="vendor/jsnes-2.0.0.min.js"></script>'* ]]; then
    printf '  <script>\n'
    sed 's#</script>#<\\/script>#g' "$VENDOR"
    printf '\n  </script>\n'
  else
    printf '%s\n' "$line"
  fi
done < "$SOURCE" > "$TMP_HTML"

# GNU base64 wraps by default while macOS base64 does not.
CODE="$(base64 < "$TMP_HTML" | tr -d '\n')"

{
  printf '%s\n' \
    'name: Neon Cartridge' \
    'uuid: 62fc706a-a740-49b0-853f-d5c873994d60' \
    'app_type: note_action' \
    'description: Play a .nes ROM attached to a selected note with mobile controls, turbo buttons, quick saves, and annotated screenshots saved inline and as attachments.' \
    'author: Note Synapse' \
    'license: Apache-2.0'
  printf 'code: %s\n' "$CODE"
} > "$OUTPUT"

echo "Wrote $OUTPUT"
