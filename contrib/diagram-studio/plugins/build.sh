#!/bin/bash
# Build the installable Note Synapse user-app YAML from the readable HTML
# source. The core logic modules and the vendored js-draw distribution are
# inlined; mermaid is NOT inlined — it loads from the bundled app asset via
# synapse://mermaid.min.js.
#
# test/contrib_diagram_studio_test.dart reconstructs this same inlining in
# Dart and fails if the YAML and the readable sources drift apart.
set -euo pipefail
cd "$(dirname "$0")"

SOURCE="diagram_studio.html"
OUTPUT="Diagram_Studio.yaml"
TMP_HTML="$(mktemp)"
trap 'rm -f "$TMP_HTML"' EXIT

inline_script() {
  printf '  <script>\n'
  # A literal </script> inside an inlined file would close the wrapper early.
  sed 's#</script>#<\\/script>#g' "$1"
  printf '\n  </script>\n'
}

# Tolerates any attribute order, so `<script type="..." src="...">` inlines too.
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ \<script[^\>]*src=\"((src|vendor)/[^\"]+)\"[^\>]*\>\</script\> ]]; then
    inline_script "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$line"
  fi
done < "$SOURCE" > "$TMP_HTML"

# Guard: a local script that failed to inline would produce a YAML that builds
# cleanly and then cannot load its library on a device. Fail loudly instead.
if grep -qE '<script[^>]*src="(src|vendor)/' "$TMP_HTML"; then
  echo "build.sh: a local script was not inlined:" >&2
  grep -oE '<script[^>]*src="(src|vendor)/[^"]+"' "$TMP_HTML" >&2
  exit 1
fi
# The app must boot with no network at all.
if grep -qE '<script[^>]*src="https?:' "$TMP_HTML"; then
  echo "build.sh: remote script reference found; the app must boot offline." >&2
  exit 1
fi

# GNU base64 wraps by default while macOS base64 does not.
CODE="$(base64 < "$TMP_HTML" | tr -d '\n')"

{
  printf '%s\n' \
    'name: Diagram Studio' \
    'uuid: b7c41e58-93a2-4d6f-8e15-0af3c962d7b4' \
    'app_type: note_action' \
    'description: A diagram studio for your notes - write Mermaid with a live preview, draw freehand, edit ASCII art on a character grid, or generate a diagram with AI and refine it, then store the result as SVG, PNG or JPG beside its editable source.' \
    'author: Note Synapse' \
    'license: Apache-2.0'
  printf 'code: %s\n' "$CODE"
} > "$OUTPUT"

echo "Wrote $OUTPUT ($(wc -c < "$OUTPUT" | tr -d ' ') bytes)"
