#!/bin/bash
# Build the installable Note Synapse user-app YAMLs from the readable HTML
# source (plan §17.3). The modules under src/ are inlined into one
# self-contained HTML file, because an installed app is one row in a table
# and has no directory to load a second file from.
#
# RULE: never edit contrib HTML or JS with `sed -i` or `perl -pi`; it has
# caused mojibake on non-ASCII text. Use an editor. (The sed below only
# writes this build's own temporary output.)
#
# What it emitted is asserted by `node ../dev/build_check.js` and by
# test/contrib_gantt_test.dart: the YAML parses, the base64 round-trips to the
# HTML these sources build right now, and the page loads nothing from outside.
set -euo pipefail
cd "$(dirname "$0")"

SOURCE="gantt.html"
# D18 load order, which is also the order the shell lists them in.
MODULES=(i18n dates model undo block md host store scale layout theme render gestures sheet app)
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

DESC='Gantt charts made of your task notes. A chart is an ordinary note: one fenced synapse-gantt block lists the task notes by link, with their dates, groups and colours, above a readable task list you can tap. Bars are coloured by status, and their fill shows how many sub-items are done, counted from subnotes and linked child tasks or from the checkboxes under one heading. Works in light and dark, on phones and tablets, in English and Simplified Chinese.'
ZH_DESC='用任务笔记组成的甘特图。图表本身是一条普通笔记：一个 synapse-gantt 代码块按链接列出任务笔记及其日期、分组和颜色，上方附有可点击的任务列表。任务条按状态着色，填充显示子项完成度，可来自子笔记和关联的子任务，或某个标题下的复选框。支持浅色和深色主题、手机和平板、英文和简体中文。'

# The same HTML ships twice: `normal` arrives with no note and shows the chart
# list; `note_action` arrives with the selected note and opens it as a chart,
# or offers the charts that contain it. Names and descriptions are emitted as
# double-quoted YAML scalars: "Gantt: this note" contains a colon.
yq() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

emit() {
  {
    printf 'name: "%s"\n' "$(yq "$1")"
    printf 'uuid: %s\n' "$2"
    printf 'app_type: %s\n' "$3"
    printf 'description: "%s"\n' "$(yq "$DESC")"
    printf 'i18n:\n'
    printf '  zh-CN:\n'
    printf '    name: "%s"\n' "$(yq "$5")"
    printf '    description: "%s"\n' "$(yq "$ZH_DESC")"
    printf '%s\n' 'author: Bruce Li' 'license: Apache-2.0'
    printf 'code: %s\n' "$CODE"
  } > "$4"
  echo "Wrote $4"
}

# Generated once in M4 with uuidgen; never change them. GT.APP_UUID in
# src/host.js is the `normal` one (the embed line names it).
emit 'Gantt'            'aac1665f-3f18-425c-a2f5-6e6001d75326' 'normal'      'Gantt.yaml'           '甘特图'
emit 'Gantt: this note' '2d96f7fe-b846-4eda-9ab8-81a1b8735fe8' 'note_action' 'Gantt_This_Note.yaml' '甘特图：当前笔记'

echo "($(wc -c < "$TMP_HTML" | tr -d ' ') bytes of HTML)"
