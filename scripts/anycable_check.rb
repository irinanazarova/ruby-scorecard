# frozen_string_literal: true

# Rungs 1-2 of the AnyCable verification ladder: config resolution and broadcast auth.
#
#   bin/rails runner scripts/anycable_check.rb
#
# Also emits the JWT and signed stream name that verify_delivery.sh needs for rungs 3-5, so the
# two scripts compose without you copying tokens by hand.
#
# Secrets are never printed. Where a value must be compared across systems, a short SHA-256 prefix
# is shown instead — paste that into the AnyCable dashboard side to compare, rather than moving the
# secret around.

require "net/http"
require "uri"
require "json"
require "digest"

FAIL = []
def check(label, ok, detail = nil, hint: nil)
  FAIL << label unless ok
  puts format("  %-38s %s%s", label, ok ? "OK" : "FAIL", detail ? "  (#{detail})" : "")
  puts "      hint: #{hint}" if !ok && hint
end

cfg = AnyCable.config

puts "\nRUNG 1 — config resolution"
check("application secret present", cfg.secret.present?,
      cfg.secret.present? ? "sha #{Digest::SHA256.hexdigest(cfg.secret)[0, 12]}" : nil,
      hint: "credentials anycable.application_secret -> config/anycable.yml `secret:`")

# streams_secret and jwt_secret FALL BACK to secret. If they differ, something set them explicitly
# to the wrong thing (most often the broadcast key).
check("streams_secret == application secret", cfg.streams_secret == cfg.secret,
      hint: "remove any explicit streams_secret; managed AnyCable does not issue one")
check("jwt_secret == application secret", cfg.jwt_secret == cfg.secret,
      hint: "remove any explicit jwt_secret; it falls back to the application secret")

check("broadcast_key present", cfg.broadcast_key.present?,
      cfg.broadcast_key.present? ? "sha #{Digest::SHA256.hexdigest(cfg.broadcast_key)[0, 12]}" : nil,
      hint: "set it EXPLICITLY — unset, the gem derives a different key and every broadcast 401s")
check("broadcast_key != application secret", cfg.broadcast_key != cfg.secret,
      hint: "these are two different dashboard values; one is probably pasted in the wrong slot")
check("broadcast_adapter is http", cfg.broadcast_adapter.to_s == "http")
check("http_broadcast_url set", cfg.http_broadcast_url.to_s.start_with?("http"),
      cfg.http_broadcast_url)

if defined?(Turbo)
  same = Turbo.signed_stream_verifier_key == cfg.secret
  check("turbo verifier == application secret", same,
        hint: "set via `config.turbo.signed_stream_verifier_key` — assigning " \
              "Turbo.signed_stream_verifier_key directly is overwritten by turbo-rails' railtie")

  # Prove the two libraries agree, not just that the strings match.
  name = Turbo::StreamsChannel.signed_stream_name(%w[anycable check])
  check("AnyCable verifies a Turbo-signed name", AnyCable::Streams.verified(name) == "anycable:check",
        hint: "signing keys disagree; subscriptions will be rejected with no error anywhere")
end

check("action_cable.url configured", Rails.application.config.action_cable.url.present?,
      Rails.application.config.action_cable.url,
      hint: "browser falls back to /cable, which managed AnyCable does not serve")

puts "\nRUNG 2 — broadcast auth (synchronous POST; bypasses the async queue on purpose)"
uri = URI(cfg.http_broadcast_url)
# Retry once: a managed instance that has scaled to zero cold-starts on the first request, and one
# transient timeout is not an auth verdict. Judge each probe independently — treating any error as
# "endpoint unreachable" sends you to check DNS when the secrets are the real question. Observed in
# practice: first call timed out, second returned 201 from the same host.
post = lambda do |auth|
  2.times do |attempt|
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req["Authorization"] = auth if auth
    req.body = { stream: "anycable:check", data: "probe" }.to_json
    return Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                           open_timeout: 15, read_timeout: 20) { |h| h.request(req) }.code
  rescue StandardError => e
    return "ERR #{e.class}" if attempt == 1

    sleep 3 # let a cold instance finish waking
  end
end

no_auth = post.call(nil)
with_auth = post.call("Bearer #{cfg.broadcast_key}")
net_err = ->(code) { code.to_s.start_with?("ERR") }

if net_err.call(no_auth) && net_err.call(with_auth)
  check("broadcast endpoint reachable", false, "#{no_auth} / #{with_auth}",
        hint: "both probes failed at the network layer — DNS/TLS/instance down. NOT an auth " \
              "failure; confirm the host is up before touching any secret.")
else
  if net_err.call(no_auth)
    puts "  #{'unauthenticated broadcast rejected'.ljust(38)} SKIP  (#{no_auth}, transient)"
  else
    check("unauthenticated broadcast rejected", no_auth == "401", "got #{no_auth}",
          hint: "endpoint accepted an unauthenticated broadcast — anyone who finds the URL can " \
                "push messages to your users. Check the instance config.")
  end

  check("authenticated broadcast accepted", %w[200 201 204].include?(with_auth), "got #{with_auth}",
        hint: "401 means broadcast_key does not match the dashboard's broadcast key")
end

# Tokens for rungs 3-5.
if FAIL.empty? && defined?(Turbo)
  tokens = {
    ws_url: Rails.application.config.action_cable.url,
    jwt: AnyCable::JWT.encode({ sid: "verify-#{Time.now.to_i}" }),
    signed: Turbo::StreamsChannel.signed_stream_name(%w[anycable check]),
    # Same payload, deliberately broken signature — rung 4 expects this to be REJECTED.
    forged: "#{Turbo::StreamsChannel.signed_stream_name(%w[anycable check]).split('--').first}--#{'0' * 64}",
    stream: "anycable:check"
  }
  path = File.join(Dir.tmpdir, "anycable_verify.json")
  File.write(path, JSON.pretty_generate(tokens))
  puts "\n  tokens for rungs 3-5 -> #{path}"
end

puts
if FAIL.empty?
  puts "rungs 1-2 PASS. Next: bash scripts/verify_delivery.sh"
else
  puts "FAILED: #{FAIL.join(', ')}"
  puts "Fix these before testing the socket — every later rung depends on them."
  exit 1
end
