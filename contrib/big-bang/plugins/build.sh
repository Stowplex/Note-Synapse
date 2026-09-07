#!/bin/bash
# Build the installable Note Synapse user-app YAMLs from the readable HTML
# source. Big Bang has no third-party dependencies - the modules under src/ are
# inlined into a single self-contained HTML file, because an installed app is
# one row in a table and has no directory to load a second file from.
#
# What it emitted is asserted by `node dev/build_check.js`: the YAML parses,
# the base64 round-trips to the HTML these sources build right now, and the
# built page loads nothing from outside itself.
set -euo pipefail
cd "$(dirname "$0")"

SOURCE="big-bang.html"
# In load order, which is also the order the shell lists them in. board.js
# first: every other module reads its coercions at load time.
MODULES=(board model host notes render gestures ai export app)
TMP_HTML="$(mktemp)"
trap 'rm -f "$TMP_HTML"' EXIT

inline_script() {
  printf '  <script>\n'
  # A literal </script> inside a JS string would end the element it is being
  # inlined into, wherever in the file it appears.
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

# Every module has to have landed. A src= that nobody inlined ships an app that
# fetches a file the host does not have, and the failure is a blank screen on a
# phone rather than an error here.
for m in "${MODULES[@]}"; do
  if grep -q "src=\"src/$m.js\"" "$TMP_HTML"; then
    echo "build.sh: src/$m.js was never inlined - is its tag still in $SOURCE?" >&2
    exit 1
  fi
done
if grep -qiE '<script[^>]+\bsrc[[:space:]]*=' "$TMP_HTML"; then
  echo "build.sh: the built HTML still loads an external script." >&2
  exit 1
fi

# GNU base64 wraps by default while macOS base64 does not.
CODE="$(base64 < "$TMP_HTML" | tr -d '\n')"

DESC='A canvas you throw notes onto. Notes become cards you can place, link, annotate, group and merge - spatial thinking over the notes you already have, with the board itself stored as an ordinary note. Draw links and label them, leave stickies and promote them into real notes, frame cards into groups and tag them, drop one card onto another to open the app own merge screen, search and focus to find your way around a big board, and embed a board read-only inside its own note. Nothing rewrites a note body: the board lives in one fenced block appended to it.'

# The same HTML ships twice. A `normal` launch arrives with no note and shows
# the board home; a `note_action` launch arrives with one note and opens it as
# the canvas, or with several and makes a new board holding all of them. The
# app tells them apart at runtime, so there is no build flag and no code fork.
# Names and descriptions are emitted as double-quoted YAML scalars: "Big Bang:
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

emit 'Big Bang'            '9f6001dd-661d-4aa7-ba18-c54164b94338' 'normal'      'Big_Bang.yaml'
emit 'Big Bang: this note' '51c3806d-b1e4-4fd4-b1ac-bb58124afef7' 'note_action' 'Big_Bang_This_Note.yaml'

echo "($(wc -c < "$TMP_HTML" | tr -d ' ') bytes of HTML)"
