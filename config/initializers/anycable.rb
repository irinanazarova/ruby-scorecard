# frozen_string_literal: true

# Hosted AnyCable (Plus), RPC-less. Two things have to line up for /test results to stream.
#
# 1. TURBO STREAM SIGNING KEY.
#    Turbo signs stream names with `Turbo.signed_stream_verifier_key`, which defaults to Rails'
#    secret_key_base — a value AnyCable has no way to know. So we sign with the AnyCable
#    application secret instead, per the AnyCable Hotwire guide. The alternative is pasting Rails'
#    secret_key_base into the AnyCable dashboard's "Turbo Streams secret" field, which spreads the
#    key that protects every other signed thing in the app across a third party. This direction
#    keeps that key at home.
#
# 2. CONNECTION AUTH.
#    Without RPC there is nobody for AnyCable to ask "is this visitor allowed in", so it rejects
#    every socket with `unauthorized`. The browser instead presents a JWT signed with the
#    application secret. AnyCable verifies it locally, no callback.
Rails.application.configure do
  ws_url = Rails.application.credentials.dig(:anycable, :websocket_url) || ENV["ANYCABLE_WS_URL"]
  config.action_cable.url = ws_url if ws_url.present?

  # Serve from one host; allow it explicitly rather than disabling origin checks.
  config.action_cable.allowed_request_origins = [
    %r{https://ruby\.evilmartians\.com},
    %r{https?://localhost:\d+},
    %r{https?://127\.0\.0\.1:\d+}
  ]

  # Set via `config.turbo`, not by assigning Turbo.signed_stream_verifier_key in an
  # after_initialize hook: turbo-rails applies its own default (secret_key_base) in its railtie
  # afterwards, quietly overwriting the assignment. Verified — the direct assignment left the
  # verifier key NOT equal to the AnyCable secret.
  secret = AnyCable.config.secret
  config.turbo.signed_stream_verifier_key = secret if secret.present?
end
