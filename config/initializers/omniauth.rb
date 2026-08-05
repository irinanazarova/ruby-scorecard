# frozen_string_literal: true

# GitHub sign-in. No scopes: we only need a stable identity to meter spend against, so the app asks
# for nothing beyond the public profile. Requesting repo scopes for a tool that reads public data
# would be both unnecessary and a reason for people not to sign in.
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :github,
           Rails.application.credentials.dig(:github, :client_id) || ENV["GITHUB_CLIENT_ID"],
           Rails.application.credentials.dig(:github, :client_secret) || ENV["GITHUB_CLIENT_SECRET"],
           scope: ""
end

# POST-only auth start, so a stray <img> or link cannot begin a sign-in flow.
OmniAuth.config.allowed_request_methods = %i[post]
OmniAuth.config.silence_get_warning = true
OmniAuth.config.on_failure = proc { |env| SessionsController.action(:failure).call(env) }
