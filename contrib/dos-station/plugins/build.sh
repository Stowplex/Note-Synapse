#!/bin/bash
# Builds DOS_Station.yaml (an installable Note Synapse user app) from
# dos_station.html. Run after editing the HTML.
set -euo pipefail
cd "$(dirname "$0")"

# tr -d '\n': GNU base64 wraps lines by default; the yaml needs one line.
CODE=$(base64 < dos_station.html | tr -d '\n')

cat > DOS_Station.yaml <<EOF
name: DOS Station
uuid: 282d85c5-82cd-4d0f-b03d-1bb99a84419b
app_type: note_action
description: "Play DOS games stored in your notes. Mounts a .zip attachment as the C: drive of a DOSBox/WebAssembly emulator, configured by a dosbox code block in the note. On-screen keyboard and gamepad overlays, and one-tap frame capture appended back to the note. Downloads the js-dos engine (~2 MB) on first run."
author: Note Synapse
license: "MIT (plugin). Embeds fflate (MIT); downloads js-dos/DOSBox (GPL-2.0) at runtime."
code: $CODE
EOF

echo "Wrote DOS_Station.yaml"
