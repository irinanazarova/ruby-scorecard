#!/usr/bin/env bash
# Run the training-data quality probe (FineWeb-Edu classifier) from a disposable Fly machine,
# scoring every resource's docs page, and capture data/quality.json. Then rebuild + deploy to publish.
#
# Usage:  ./fetch/quality-on-fly.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${QUALITY_APP:-ruby-scorecard-quality}"
ORG="${FETCH_ORG:-personal}"

cleanup() { echo "Tearing down $APP ..." >&2; flyctl apps destroy "$APP" -y >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "Creating disposable Fly app $APP ..." >&2
flyctl apps create "$APP" -o "$ORG" 2>/dev/null || true

echo "Building the quality image (torch + FineWeb-Edu classifier, this is slow) ..." >&2
flyctl deploy . -a "$APP" -c fetch/fly.quality.toml --dockerfile fetch/quality.Dockerfile --ha=false

echo "Scoring docs with the FineWeb-Edu classifier ..." >&2
flyctl ssh console -a "$APP" -C "python /app/scripts/quality.py --print" > data/quality.json

ruby -rjson -e 'q=JSON.parse(File.read("data/quality.json")); s=q.count{|_,v| v["edu"]}; warn "captured quality.json (scored #{s}/#{q.size})"' \
  || { echo "ERROR: data/quality.json is not valid JSON; leaving it for inspection." >&2; exit 1; }

echo "Done -> data/quality.json. Rebuild (./build.sh) and deploy to publish." >&2
