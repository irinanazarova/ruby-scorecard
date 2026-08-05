// Rungs 3-5 of the AnyCable verification ladder: connection auth, stream authorization, delivery.
//
//   node ws_probe.mjs /tmp/anycable_verify.json
//
// Requires Node 18+ (uses the global WebSocket; no dependencies).
//
// RUN THIS IN THE FOREGROUND. Node buffers stdout when redirected to a file, so a backgrounded
// probe looks like it never connected — nothing flushes until exit. Trigger the broadcast from a
// background subshell instead (verify_delivery.sh does this).

import { readFileSync } from "node:fs";

const t = JSON.parse(readFileSync(process.argv[2] ?? "/tmp/anycable_verify.json", "utf8"));
const WINDOW_MS = Number(process.env.PROBE_WINDOW_MS ?? 18000);
const MAX_DIALS = Number(process.env.PROBE_MAX_DIALS ?? 3);

const state = { opened: false, welcome: false, valid: null, forged: null, unsigned: null,
                delivered: 0, lastError: null };

const label = (id) =>
  id?.signed_stream_name === t.signed ? "valid"
  : id?.signed_stream_name === t.forged ? "forged"
  : id?.stream_name ? "unsigned" : null;

// Managed instances scale to zero and cold-start, so the first dial can fail at the TCP/TLS layer
// with no HTTP status at all. Retrying distinguishes "instance was asleep" from "config is wrong" —
// without it a cold start is indistinguishable from a broken setup.
function dial(attempt = 1) {
  const url = `${t.ws_url}?jid=${encodeURIComponent(t.jwt)}`;
  if (attempt === 1) console.log(`dialing ${t.ws_url}`);
  else console.log(`  redialing (attempt ${attempt}/${MAX_DIALS}) — instance may be cold`);

  const ws = new WebSocket(url);

  ws.onopen = () => { state.opened = true; console.log("  socket open"); };

  ws.onerror = (e) => { state.lastError = e.message ?? e.type ?? "unknown"; };

  ws.onclose = (e) => {
    if (state.welcome) return; // finished normally
    if (attempt < MAX_DIALS && !state.opened) {
      setTimeout(() => dial(attempt + 1), 3000 * attempt);
    } else if (!state.opened) {
      console.log(`  socket never opened: ${state.lastError ?? `code=${e.code}`}`);
    }
  };

  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.type === "ping") return;

    if (m.type === "disconnect") {
      console.log(`  RUNG 3 FAIL — disconnected: ${m.reason}`);
      if (m.reason === "unauthorized") {
        console.log("      No valid JWT. Check the jid query param, and that jwt_secret matches");
        console.log("      the application secret on both sides.");
      }
      return;
    }

    if (m.type === "welcome") {
      state.welcome = true;
      console.log("  RUNG 3 PASS — welcome (JWT accepted)");
      const sub = (identifier) =>
        ws.send(JSON.stringify({ command: "subscribe", identifier: JSON.stringify(identifier) }));
      sub({ channel: "$pubsub", signed_stream_name: t.signed });
      sub({ channel: "$pubsub", signed_stream_name: t.forged });
      sub({ channel: "$pubsub", stream_name: t.stream });
      return;
    }

    const id = m.identifier ? JSON.parse(m.identifier) : null;
    const which = label(id);

    if (m.type === "confirm_subscription" || m.type === "reject_subscription") {
      if (which) state[which] = m.type === "confirm_subscription" ? "confirmed" : "rejected";
      return;
    }

    if (m.message !== undefined && which === "valid") {
      state.delivered += 1;
      const body = typeof m.message === "string" ? m.message : JSON.stringify(m.message);
      console.log(`  RUNG 5 — delivered: ${body.slice(0, 120)}`);
    }
  };
}

dial();

setTimeout(() => {
  // Never report a transport failure as a secrets problem — that sends you to re-check
  // credentials that were fine. Rungs 4-5 are only meaningful once a socket actually opened.
  if (!state.opened) {
    console.log("\nRUNGS 4-5 — SKIPPED, no socket");
    console.log(`  The WebSocket never opened (${state.lastError ?? "no response"}).`);
    console.log("  This is a transport problem, NOT an auth or signing problem:");
    console.log("    - managed instance asleep or restarting (retry in a moment)");
    console.log("    - wrong host in action_cable.url");
    console.log("    - egress/proxy blocking wss://");
    console.log("  Do not change any secret on the strength of this result.");
    process.exit(1);
  }

  if (!state.welcome) {
    console.log("\nRUNGS 4-5 — SKIPPED, connection refused by the server (see rung 3 above)");
    process.exit(1);
  }

  console.log("\nRUNG 4 — stream authorization");
  const expect = (name, got, want) => {
    const ok = got === want;
    console.log(`  ${name.padEnd(22)} ${String(got ?? "no reply").padEnd(10)} expected ${want}  ${ok ? "OK" : "FAIL"}`);
    return ok;
  };
  const a = expect("valid signed name", state.valid, "confirmed");
  const b = expect("forged signature", state.forged, "rejected");
  const c = expect("unsigned name", state.unsigned, "rejected");

  if (state.valid === "rejected") {
    console.log("      Rails and the server disagree on the signing secret. Compare");
    console.log("      Digest::SHA256.hexdigest(secret)[0,12] on both sides — don't paste secrets.");
  }
  if (state.forged === "confirmed") {
    console.log("      Server is NOT verifying signatures — anyone can subscribe to any stream.");
  }
  if (state.unsigned === "confirmed") {
    console.log("      Public streams are enabled; usually not what you want in production.");
  }

  console.log("\nRUNG 5 — delivery");
  if (state.delivered > 0) {
    console.log(`  ${state.delivered} message(s) received  OK`);
  } else if (a) {
    console.log("  no messages received  FAIL");
    console.log("      Subscription is fine, so suspect the BROADCASTER, not the server:");
    console.log("      - AnyCable.broadcast is async; a short-lived process exits before it flushes.");
    console.log("        Add AnyCable.broadcast_adapter.shutdown after broadcasting.");
    console.log("      - Confirm the broadcast used the UNSIGNED stream name.");
    console.log("      - Confirm the broadcast ran with the any_cable adapter, not async/test.");
  } else {
    console.log("  skipped — subscription never confirmed");
  }

  const pass = a && b && c && state.delivered > 0;
  console.log(`\n${pass ? "rungs 3-5 PASS" : "rungs 3-5 INCOMPLETE"}`);
  process.exit(pass ? 0 : 1);
}, WINDOW_MS);
