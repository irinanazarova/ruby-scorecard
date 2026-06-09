#!/usr/bin/env bash
# Run the Common Crawl coverage probe from a disposable Fly machine (a throwaway IP),
# capture the result to data/coverage.json, rebuild the page, then destroy the machine.
#
# Why: CC's CDX index is IP rate-limited. Running from Fly keeps our own IP safe and lets us
# retry from a fresh IP (re-run this script) if a run ever gets throttled. The probe itself is
# polite (single serial thread, sleeps, descriptive UA), so one pass should not trip a block.
#
# Usage:  ./fetch/run-on-fly.sh
# Then:   review data/coverage.json -> `fly deploy` (repo root) to publish -> commit.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${FETCH_APP:-ruby-scorecard-fetch}"
ORG="${FETCH_ORG:-personal}"

cleanup() {
  echo "Tearing down $APP ..." >&2
  flyctl apps destroy "$APP" -y >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Creating disposable Fly app $APP ..." >&2
flyctl apps create "$APP" -o "$ORG" 2>/dev/null || true

echo "Deploying the fetch image ..." >&2
# Build context = repo root (.) so COPY can reach scripts/ and data/; dockerfile path is repo-relative.
flyctl deploy . -a "$APP" -c fetch/fly.fetch.toml --dockerfile fetch/Dockerfile --ha=false

echo "Running coverage probe on Fly (clean JSON -> data/coverage.json) ..." >&2
flyctl ssh console -a "$APP" -C "ruby /app/scripts/coverage.rb --print" > data/coverage.json

# Fail loudly if we didn't get valid JSON back (e.g. index still down / capture glitch).
ruby -rjson -e 'c=JSON.parse(File.read("data/coverage.json")); s=c.count{|_,v| v["cc_pages"]}; warn "captured valid coverage.json (cc sampled #{s}/#{c.size})"' \
  || { echo "ERROR: data/coverage.json is not valid JSON; leaving it for inspection." >&2; exit 1; }

echo "Rebuilding dist/ ..." >&2
./build.sh

echo "Done. Next: review data/coverage.json, then \`fly deploy\` (repo root) and commit." >&2
