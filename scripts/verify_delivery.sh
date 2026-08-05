#!/usr/bin/env bash
# Rungs 3-5: connect, authorize streams, deliver. Run from the Rails app root.
#
#   bash scripts/verify_delivery.sh
#
# Orchestration matters here. The probe runs in the FOREGROUND and the broadcast fires from a
# background subshell — not the other way round. Node buffers stdout when redirected to a file, so
# a backgrounded probe appears never to have connected even when it is working perfectly. That one
# detail costs more debugging time than any real misconfiguration.
set -uo pipefail
cd "$(dirname "$0")/.."

TOKENS="${TMPDIR:-/tmp}/anycable_verify.json"
DELAY="${BROADCAST_DELAY:-6}"

if [ ! -f "$TOKENS" ]; then
  echo "No $TOKENS — run rungs 1-2 first:"
  echo "  bin/rails runner scripts/anycable_check.rb"
  exit 1
fi

STREAM=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0]))["stream"]' "$TOKENS")
echo "Broadcasting to '$STREAM' in ${DELAY}s; probe listening in the foreground."
echo

# Background broadcast. CABLE_ADAPTER=any_cable forces the production path even in development,
# and the explicit shutdown drains the async queue before this short-lived process exits —
# without it nothing is ever actually sent.
(
  sleep "$DELAY"
  CABLE_ADAPTER=any_cable bin/rails runner "
    stream = '$STREAM'
    if defined?(Turbo)
      Turbo::StreamsChannel.broadcast_replace_to(stream.split(':'),
        target: 'anycable-probe', html: '<div>anycable delivery probe</div>')
    else
      AnyCable.broadcast(stream, '<div>anycable delivery probe</div>')
    end
    AnyCable.broadcast_adapter.shutdown
  " >/dev/null 2>&1
) &
BCAST=$!

node scripts/ws_probe.mjs "$TOKENS"
STATUS=$?

wait "$BCAST" 2>/dev/null
exit "$STATUS"
