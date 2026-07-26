#!/bin/bash
# Build Formula Studio's installable Note Action YAML from readable sources.
# MathLive, Compute Engine, and fonts remain host-bundled synapse:// assets;
# Formula Studio's small first-party modules are inlined.
set -euo pipefail
cd "$(dirname "$0")"

SOURCE="formula_studio.html"
OUTPUT="Formula_Studio.yaml"
STARTER="../../../assets/starter/apps/Formula_Studio.yaml"
TMP_HTML="$(mktemp)"
trap 'rm -f "$TMP_HTML"' EXIT

inline_script() {
  printf '  <script>\n'
  sed 's#</script>#<\\/script>#g' "$1"
  printf '\n  </script>\n'
}

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ \<script[^\>]*src=\"(src/[^\"]+)\"[^\>]*\>\</script\> ]]; then
    inline_script "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$line"
  fi
done < "$SOURCE" > "$TMP_HTML"

if grep -qE '<script[^>]*src="src/' "$TMP_HTML"; then
  echo "build.sh: a first-party module was not inlined" >&2
  exit 1
fi
if grep -qE '<(script|link)[^>]*(src|href)="https?:' "$TMP_HTML"; then
  echo "build.sh: Formula Studio executable resources must be local" >&2
  exit 1
fi
if ! grep -q "connect-src 'none'" "$TMP_HTML"; then
  echo "build.sh: the offline Content Security Policy is missing" >&2
  exit 1
fi
if grep -qE '(^|[^A-Za-z])(fetch|XMLHttpRequest|WebSocket|proxyFetch|originFetch)([^A-Za-z]|$)' src/*.js; then
  echo "build.sh: a forbidden first-party network primitive was found" >&2
  exit 1
fi
if ! grep -q 'synapse://mathlive/mathlive.min.js' "$TMP_HTML" ||
   ! grep -q 'synapse://compute-engine/compute-engine.min.js' "$TMP_HTML"; then
  echo "build.sh: required local math dependencies are missing" >&2
  exit 1
fi

CODE="$(base64 < "$TMP_HTML" | tr -d '\n')"

{
  printf '%s\n' \
    'name: Formula Studio' \
    'uuid: 7cbb556a-900b-4a74-b9bd-e95897c3480d' \
    'app_type: note_action' \
    'description: Visually compose, edit, and locally evaluate LaTeX formulas in notes with MathLive and Cortex Compute Engine. Fully offline.' \
    'author: Note Synapse' \
    'license: Apache-2.0'
  printf 'code: %s\n' "$CODE"
} > "$OUTPUT"

cp "$OUTPUT" "$STARTER"
echo "Wrote $OUTPUT and $STARTER"
