#!/bin/bash
# Builds NotebookLM_Manager.yaml (an installable Note Synapse user app) from
# notebooklm_manager.html. Run after editing the HTML.
set -euo pipefail
cd "$(dirname "$0")"

# tr -d '\n': GNU base64 wraps lines by default; the yaml needs one line.
CODE=$(base64 < notebooklm_manager.html | tr -d '\n')

cat > NotebookLM_Manager.yaml <<EOF
name: NotebookLM Manager
uuid: a80d7d5b-0ce5-48bd-8641-9eb357a7e020
app_type: ai_tool
description: Sync notes to Google NotebookLM as sources, ask questions, and generate podcasts/slides. Exposes AI tools and an interactive UI. Requires a NotebookLM (Google) login, established in-app.
author: Note Synapse
license: MIT
code: $CODE
EOF

echo "Wrote NotebookLM_Manager.yaml"
