# frozen_string_literal: true

# Configuration for the /test analyzer.
#
# Deliberate split: SECRETS go in encrypted credentials, KNOBS go here in plain sight. A spend cap
# and a model name are not secrets, and burying them in an encrypted blob makes them hard to review
# and easy to forget.
module AnalyzerConfig
  # Hard ceiling on model spend per signed-in user, enforced against RubyLLM's reported per-message
  # cost rather than an estimate. Reaching it blocks further probes for that user, it does not
  # silently degrade the results.
  BUDGET_CENTS_PER_USER = Integer(ENV.fetch("BUDGET_CENTS_PER_USER", 500))   # $5.00

  # Anonymous visitors get this many LIVE analyses per browser session before signing in. Cached
  # re-runs are free and never consume the allowance: making someone burn a slot to re-view a result
  # they already paid for would punish exactly the behaviour the demo is trying to teach.
  FREE_ANALYSES_PER_SESSION = Integer(ENV.fetch("FREE_ANALYSES_PER_SESSION", 5))

  # Bot defence. An analysis is expensive (~5c of model calls), so the limits are deliberately
  # tighter than a normal web form's: a scripted loop is the one thing that could actually drain the
  # account. Cached repeats are cheap and are not what these limits are aimed at.
  RATE_LIMIT_PER_IP = { count: Integer(ENV.fetch("RATE_LIMIT_IP_COUNT", 10)), within: 5.minutes }.freeze
  RATE_LIMIT_PER_IP_DAILY = { count: Integer(ENV.fetch("RATE_LIMIT_IP_DAILY", 60)), within: 1.day }.freeze

  # 3 spans x 3 models. The cap is a spend guard, but set it too low and it silently costs accuracy
  # instead of money: at 6 calls the third model squeezed out the third span, and a page that scores
  # a 91-word verbatim run from its repo source came back "partial" at 10. Spans are where the
  # signal is, so the cap must leave room for all of them.
  MAX_MODEL_CALLS_PER_ANALYSIS = Integer(ENV.fetch("MAX_MODEL_CALLS_PER_ANALYSIS", 9))

  # Wall-clock ceiling for the whole memorization step. The call cap bounds SPEND; this bounds TIME,
  # which the call cap cannot — per-call timeouts multiply, and a run that looks healthy per-probe
  # can still take half an hour in aggregate. A healthy 9-probe run finishes in 60-140s, so 180s
  # leaves room for one slow provider without letting a stuck one hold the page open.
  MEMORIZATION_DEADLINE = Integer(ENV.fetch("MEMORIZATION_DEADLINE", 180)).seconds

  # The FineWeb-Edu scorer. Still its own Fly app (ruby-quality-api) because it carries the ONNX
  # model; /test calls it over HTTP.
  QUALITY_API = ENV.fetch("QUALITY_API", "https://ruby-quality-api.fly.dev/api/check")

  # The side-by-side baseline: docs that ARE demonstrably in training data, so a "no recall" result
  # on your own page has something to be measured against.
  #
  # This exact passage is verified, not assumed. In the 168-repo study it fired on BOTH model
  # families, and re-measured here Claude reproduced 91 consecutive words of it verbatim. Picking a
  # famous product and hoping is how a demo dies: the Supabase auth guide, an obvious choice, does
  # not fire on the span you would naively pick.
  #
  # It also quietly makes the study's point: this repo has 137 stars and no license, and is more
  # memorized than repos with a thousand times the stars.
  BASELINE = {
    label: "Tailwind CSS docs (mask-image)",
    repo: "tailwindlabs/tailwindcss.com",
    path: "src/docs/mask-image.mdx",
    url: "https://tailwindcss.com/docs/mask-image"
  }.freeze

  # Warmed by `bin/rails analyzer:warm` before the demo, so the on-stage run replays from cache
  # instead of waiting on Common Crawl's cold index. Run the SAME links live.
  # Content pages, not hub pages. A docs landing page is mostly links: workos.com/docs/authkit
  # yields 39 words even via its markdown twin, so the probe correctly refuses to test it. Pick
  # pages with real prose or the demo's best moment never runs.
  # Deliberately NOT the baseline page.
  #
  # tailwindcss.com/docs/mask-image is the reference, and running it as a target too produces two
  # different numbers for the same page on one screen: 11 words from the rendered HTML, 91 from the
  # repo markdown the baseline measures. Both are correct — the rendered page carries less prose
  # than its source — but shown side by side it reads as a bug, and "why do those disagree?" is not
  # the question you want from the audience.
  DEMO_TARGETS = [
    "https://workos.com/docs/authkit/sessions",             # MIT, yet never collected by SWH
    "https://docs.anycable.io/anycable-go/reliable_streams" # our own, the honest self-critique
  ].freeze

  # Optional GitHub token. Unauthenticated the API allows 60 requests/hour, which one busy demo can
  # exhaust; with a token it is 5000.
  def self.github_token
    Rails.application.credentials.dig(:github, :api_token) || ENV["GITHUB_TOKEN"]
  end

  KEY_READERS = { anthropic: :anthropic_api_key, openai: :openai_api_key, gemini: :gemini_api_key }.freeze

  def self.key_for?(provider)
    reader = KEY_READERS[provider] or return false
    RubyLLM.config.public_send(reader).present?
  end

  def self.anthropic_key? = key_for?(:anthropic)
  def self.openai_key?    = key_for?(:openai)
  def self.gemini_key?    = key_for?(:gemini)
  def self.any_model_key? = KEY_READERS.keys.any? { |p| key_for?(p) }
end
