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
  # Every note below states a MEASURED result, not a guess. They are what these four actually
  # produced, and they are ordered so the two positives come last: a visitor who clicks straight
  # down the list sees "eligible but absent" twice, then sees what a hit looks like.
  EXAMPLES = [
    { url: "https://workos.com/docs/authkit/sessions",
      label: "workos.com/docs/authkit/sessions",
      note: "Permissive and archived, so the code path is open. Common Crawl still never fetched " \
            "the page, and no model reproduces it." },

    { url: "https://docs.anycable.io/anycable-go/reliable_streams",
      label: "docs.anycable.io/anycable-go/reliable_streams",
      note: "Our own docs, included so this is not only other people's bad news. Same outcome: " \
            "eligible, uncrawled, unmemorized." },

    # The study's headline in one page: 140 stars, no licence at all, below the quality bar, and
    # still reproduced by two frontier models from different labs. Copies beat popularity.
    { url: "https://tailwindcss.com/docs/hover-focus-and-other-states",
      label: "tailwindcss.com/docs/hover-focus-and-other-states",
      note: "No licence and 140 stars. Scores below the quality bar, yet Claude Opus and GPT-5.5 " \
            "each reproduce 30 consecutive words." },

    # Software Heritage as the gate people forget: the licence is fine and the repo is popular,
    # and none of that matters because the archive never collected it.
    { url: "https://resend.com/docs/send-with-nodejs",
      label: "resend.com/docs/send-with-nodejs",
      note: "Permissive and 187 stars, but Software Heritage never archived the linked repo. A " \
            "licence on an uncollected repo buys nothing." }
  ].freeze

  DEMO_TARGETS = EXAMPLES.map { |e| e[:url] }.freeze

  # Clicking a listed example must never cost a visitor an allowance slot or trip the per-IP limit,
  # however cold the cache happens to be. Compared ignoring a trailing slash, since that is the one
  # difference a hand-typed URL reliably picks up.
  def self.example?(url)
    key = url.to_s.strip.chomp("/")
    DEMO_TARGETS.any? { |t| t.chomp("/") == key }
  end

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
