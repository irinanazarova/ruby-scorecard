#!/usr/bin/env bash
# Build the scorecard into dist/ : pre-rendered HTML (build.py) + bundled assets (esbuild).
# Deploy = copy the whole dist/ folder to ruby.evilmartians.com.
set -euo pipefail
cd "$(dirname "$0")"

# Front-end assets: bundle nanotags components -> dist/assets/app.js, CSS + fonts -> dist/assets/.
if [ ! -d node_modules ]; then
  echo "Installing JS deps (first run)..."
  npm install
fi
npm run build:assets

# Server-rendered HTML from the probed data.
ruby scripts/build.rb

echo "Built dist/ -> deploy with: rsync -a dist/ <host>"
