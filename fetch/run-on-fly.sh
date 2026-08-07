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

# Registered BEFORE the app is created. If the deploy fails, the trap still fires and the
# throwaway app is destroyed; registering it later would leak an app on every early failure.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; cleanup' EXIT

echo "Creating disposable Fly app $APP ..." >&2
flyctl apps create "$APP" -o "$ORG" 2>/dev/null || true

echo "Deploying the fetch image ..." >&2
# Build context = repo root (.) so COPY can reach scripts/ and data/; dockerfile path is repo-relative.
flyctl deploy . -a "$APP" -c fetch/fly.fetch.toml --dockerfile fetch/Dockerfile --ha=false

# Capture to a temp file and only replace the real one once the JSON validates.
# Redirecting straight into data/*.json truncates it the instant the shell opens it, so a probe
# that fails or returns nothing destroys good data before it has produced any.
echo "Running indicator probe on Fly (clean JSON -> data/scorecard.json) ..." >&2
if flyctl ssh console -a "$APP" -C "ruby /app/scripts/probe.rb --print" > "$tmp/scorecard.json"; then
  if ruby -rjson -e 'r=JSON.parse(File.read(ARGV[0]))["rows"]; abort "no rows" unless r&.any?;
       u=r.count{|x| %w[000 ERR].include?(x["docs_ok"].to_s)};
       warn "captured #{r.size} rows (#{u} unreachable)"' "$tmp/scorecard.json"; then
    cp "$tmp/scorecard.json" data/scorecard.json
  else
    echo "WARNING: scorecard capture invalid; data/scorecard.json left untouched." >&2
  fi
else
  echo "WARNING: probe aborted on Fly (likely too many unreachable); data/scorecard.json left untouched." >&2
fi

echo "Running coverage probe on Fly (clean JSON -> data/coverage.json) ..." >&2
if flyctl ssh console -a "$APP" -C "ruby /app/scripts/coverage.rb --print" > "$tmp/coverage.json"; then
  if ruby -rjson -e 'c=JSON.parse(File.read(ARGV[0])); abort "empty" if c.empty?;
       s=c.count{|_,v| v["cc_pages"]}; warn "captured coverage (cc sampled #{s}/#{c.size})"' "$tmp/coverage.json"; then
    # Preserve counts this run could not measure. CC is flaky, and a null here is "we did not
    # reach the index", never "this site left the corpus"; blanking a third of the chart on a bad
    # afternoon is worse than carrying a known number forward.
    ruby -rjson -e '
      fresh = JSON.parse(File.read(ARGV[0])); old = JSON.parse(File.read(ARGV[1])) rescue {}
      kept = 0
      fresh.each { |k, v| next unless v["cc_pages"].nil? && old.dig(k, "cc_pages")
                          v["cc_pages"] = old[k]["cc_pages"]; v["cc_exact"] = old[k]["cc_exact"]; kept += 1 }
      File.write(ARGV[1], JSON.pretty_generate(fresh))
      warn "merged: #{kept} previously-known counts carried forward"
    ' "$tmp/coverage.json" data/coverage.json
  else
    echo "WARNING: coverage capture invalid; data/coverage.json left untouched." >&2
  fi
else
  echo "WARNING: coverage probe failed on Fly; data/coverage.json left untouched." >&2
fi

echo "Rebuilding dist/ ..." >&2
./build.sh

echo "Done. Next: review data/coverage.json, then \`fly deploy\` (repo root) and commit." >&2
