#!/bin/bash

# Navigate to the doc directory where this script resides
cd "$(dirname "$0")"

echo "Building Note Synapse User Manual..."
node generate_manual.js
