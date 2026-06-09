#!/usr/bin/env bash
# Per-page Common Crawl detail from a disposable Fly machine: for each named resource, crawl the
# live docs site to enumerate its pages, query Common Crawl, and write which pages ARE / are NOT
# in CC. Captures data/coverage_details.json and renders data/coverage_details/<slug>.md, then
# destroys the machine.
#
# Usage:  ./fetch/details-on-fly.sh ["Inertia Rails" "AnyCable" ...]   (default: those two)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${FETCH_APP:-ruby-scorecard-fetch}"
ORG="${FETCH_ORG:-personal}"
TARGETS=( "$@" )
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=( "Inertia Rails" "AnyCable" )

cleanup() { echo "Tearing down $APP ..." >&2; flyctl apps destroy "$APP" -y >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "Creating disposable Fly app $APP ..." >&2
flyctl apps create "$APP" -o "$ORG" 2>/dev/null || true

echo "Deploying the fetch image ..." >&2
flyctl deploy . -a "$APP" -c fetch/fly.fetch.toml --dockerfile fetch/Dockerfile --ha=false

# Quote each target name for the remote shell command.
args=""; for t in "${TARGETS[@]}"; do args+=" \"$t\""; done
echo "Running detail probe on Fly for:${args} ..." >&2
flyctl ssh console -a "$APP" -C "ruby /app/scripts/coverage_details.rb --print${args}" > data/coverage_details.json

ruby -rjson -e 'JSON.parse(File.read("data/coverage_details.json")); warn "captured valid coverage_details.json"' \
  || { echo "ERROR: invalid JSON captured; leaving file for inspection." >&2; exit 1; }

ruby scripts/coverage_details_report.rb
echo "Done. Shareable reports in data/coverage_details/*.md" >&2
