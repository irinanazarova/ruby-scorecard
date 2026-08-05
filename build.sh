#!/usr/bin/env bash
# Build the static half of ruby.evilmartians.com into dist/, then publish it into the Rails app's
# public/ so one server hosts both the generated pages and the live /test analyzer.
#
# The generators are unchanged: the scorecard, guide and contributors report are still fully
# server-rendered HTML that works with JavaScript off. Rails only hands the files back.
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
ruby scripts/build_contributors.rb

# Publish into public/. Copy rather than symlink so the Docker image is self-contained, and keep
# Rails' own public/ files (404.html, icons, robots.txt) by copying dist over the top instead of
# replacing the directory.
mkdir -p public
cp -R dist/. public/
echo "Built dist/ and published to public/ -> run: bin/rails server   (or fly deploy)"
