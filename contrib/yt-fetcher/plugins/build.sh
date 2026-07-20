#!/bin/bash
# Builds YTFetcher.yaml (an installable Note Synapse user app) from
# yt_fetcher.html. Run after editing the HTML.
set -euo pipefail
cd "$(dirname "$0")"

# tr -d '\n': GNU base64 wraps lines by default; the yaml needs one line.
CODE=$(base64 < yt_fetcher.html | tr -d '\n')

cat > YTFetcher.yaml <<EOF
name: YTFetcher
uuid: 327c5c2c-6a7d-482b-8085-eb04d522aded
app_type: ai_tool
description: AI tool to download YouTube transcript (for en and zh only).
author: Bruce Li
license: MIT
code: $CODE
EOF

echo "Wrote YTFetcher.yaml"
