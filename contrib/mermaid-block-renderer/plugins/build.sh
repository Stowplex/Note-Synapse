#!/bin/bash
# Build the installable Note Synapse user-app YAML from the readable HTML
# source. Nothing is inlined: mermaid comes from the bundled
# synapse://mermaid.min.js asset at runtime.
#
# This app is also bundled as a starter app, so after regenerating the YAML
# copy it into assets/starter/apps/ (same uuid) to update the bundled copy:
#   cp Mermaid_Block_Renderer.yaml ../../../assets/starter/apps/
set -euo pipefail
cd "$(dirname "$0")"

SOURCE="mermaid_block_renderer.html"
OUTPUT="Mermaid_Block_Renderer.yaml"

# GNU base64 wraps by default while macOS base64 does not.
CODE="$(base64 < "$SOURCE" | tr -d '\n')"

{
  printf '%s\n' \
    'name: Mermaid Block Renderer' \
    'uuid: 6f3a9c21-0d4e-4b7a-9c58-2e1f7b83a4d6' \
    'app_type: note_action' \
    'description: Render the Mermaid diagram in a selected note block to an image and insert it above the code, keeping the diagram source editable.' \
    'author: Note Synapse' \
    'license: Apache-2.0'
  printf 'code: %s\n' "$CODE"
} > "$OUTPUT"

echo "Wrote $OUTPUT"
