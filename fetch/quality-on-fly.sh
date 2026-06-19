#!/usr/bin/env bash
# Run the training-data quality probe (FineWeb-Edu classifier) from a disposable Fly machine,
# scoring every resource's docs page, and capture data/quality.json. Then rebuild + deploy to publish.
#
# Usage:
#   ./fetch/quality-on-fly.sh                          # score each resource -> data/quality.json
#   ./fetch/quality-on-fly.sh --details "evilmartians.com"   # score found vs missing pages -> data/quality_details.json
set -euo pipefail
cd "$(dirname "$0")/.."

PROBE_ARGS=("$@")
OUT="data/quality.json"; VALIDATE='resource'
if [[ "${1:-}" == "--details" ]]; then
  VALIDATE='details'
  slug=$(echo "${2:-target}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')
  OUT="data/quality_details_${slug}.json"
fi

APP="${QUALITY_APP:-ruby-scorecard-quality}"
ORG="${FETCH_ORG:-personal}"

cleanup() { echo "Tearing down $APP ..." >&2; flyctl apps destroy "$APP" -y >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "Creating disposable Fly app $APP ..." >&2
flyctl apps create "$APP" -o "$ORG" 2>/dev/null || true

echo "Building the quality image (torch + FineWeb-Edu classifier, this is slow) ..." >&2
flyctl deploy . -a "$APP" -c fetch/fly.quality.toml --dockerfile fetch/quality.Dockerfile --ha=false

echo "Scoring docs with the FineWeb-Edu classifier ..." >&2
flyctl ssh console -a "$APP" -C "python /app/scripts/quality.py --print ${PROBE_ARGS[*]}" > "$OUT"

if [[ "$VALIDATE" == "details" ]]; then
  ruby -rjson -e 'q=JSON.parse(File.read(ARGV[0])); q["buckets"].each{|k,v| warn "#{k}: avg=#{v["avg"]} median=#{v["median"]} keep>=3=#{v["keep_ge3"]} scored=#{v["n_scored"]}/#{v["n_urls"]}"}' "$OUT" \
    || { echo "ERROR: $OUT is not valid JSON; leaving it for inspection." >&2; exit 1; }
else
  ruby -rjson -e 'q=JSON.parse(File.read(ARGV[0])); s=q.count{|_,v| v["edu"]}; warn "captured (scored #{s}/#{q.size})"' "$OUT" \
    || { echo "ERROR: $OUT is not valid JSON; leaving it for inspection." >&2; exit 1; }
fi

echo "Done -> $OUT." >&2
