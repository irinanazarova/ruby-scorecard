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

  # 2 spans x 2 sources x 3 models. The cap is a spend guard, but set it too low and it silently
  # costs accuracy instead of money: at 6 calls the third model squeezed out the third span, and a
  # page that scores a 91-word verbatim run from its repo source came back "partial" at 10. Spans
  # are where the signal is, so the cap must leave room for every one of them on BOTH sources.
  MAX_MODEL_CALLS_PER_ANALYSIS = Integer(ENV.fetch("MAX_MODEL_CALLS_PER_ANALYSIS", 12))

  # Wall-clock ceiling for the whole memorization step. The call cap bounds SPEND; this bounds TIME,
  # which the call cap cannot — per-call timeouts multiply, and a run that looks healthy per-probe
  # can still take half an hour in aggregate. A healthy 9-probe run finishes in 60-140s, so 180s
  # leaves room for one slow provider without letting a stuck one hold the page open.
  MEMORIZATION_DEADLINE = Integer(ENV.fetch("MEMORIZATION_DEADLINE", 180)).seconds

  # The FineWeb-Edu scorer. Still its own Fly app (ruby-quality-api) because it carries the ONNX
  # model; /test calls it over HTTP.
  QUALITY_API = ENV.fetch("QUALITY_API", "https://ruby-quality-api.fly.dev/api/check")

  # The scale on the recall chart: pages that ARE demonstrably in the training data, measured under
  # the identical probe, so a null result on your own page has something to be read against.
  #
  # All three are verified hits from our own 168-repo study, and they were chosen to disagree with
  # each other on everything except the outcome. One has no LICENSE file and 140 stars; one is MIT
  # with 59k; one is Apache-2.0 with 108k. Together they are the study's finding in three bars:
  # popularity and licence do not predict recall.
  #
  # The exact PASSAGE matters as much as the repo, which is why each one names a pinned span in
  # config/reference_passages.json rather than a file to re-sample. Recall is sparse: re-picking
  # spans from the live Rails i18n guide produced a 4-word run and "fired for nobody", which would
  # teach a visitor the opposite of the truth. Picking a famous product and hoping is the same
  # mistake one level up: the Supabase auth landing guide does not fire, and redirect-urls does.
  REFERENCES = [
    { label: "Tailwind CSS docs", repo: "tailwindlabs/tailwindcss.com",
      url: "https://tailwindcss.com/docs/upgrade-guide", passage: "tailwind-upgrade" },

    { label: "Rails guides", repo: "rails/rails",
      url: "https://guides.rubyonrails.org/i18n.html", passage: "rails-i18n" },

    { label: "Supabase docs", repo: "supabase/supabase",
      url: "https://supabase.com/docs/guides/auth/redirect-urls", passage: "supabase-redirect-urls" }
  ].freeze

  # Warmed by `bin/rails analyzer:warm` before the demo, so the on-stage run replays from cache
  # instead of waiting on Common Crawl's cold index. Run the SAME links live.
  #
  # Both fields are filled in, which is the point of the pair: the demo should never show the tool
  # guessing which repo belongs to a docs site, and each example is a real docs site next to the
  # real repo its team would name.
  #
  # Content pages, not hub pages. A docs landing page is mostly links: workos.com/docs/authkit
  # yields 39 words even via its markdown twin, so the probe correctly refuses to test it. Pick
  # pages with real prose or the demo's best moment never runs.
  #
  # Every note states a MEASURED result. They are ordered so the two flat outcomes come first and
  # the two surprises come last: a visitor clicking straight down the list sees "eligible but
  # absent" twice, then sees a gate nobody expects, then sees what a hit looks like.
  EXAMPLES = [
    { docs: "https://workos.com/docs/authkit/sessions",
      repo: "workos/authkit-nextjs",
      label: "WorkOS AuthKit",
      note: "MIT and archived, so the code path is open. Common Crawl still never fetched the docs " \
            "page, and no model reproduces either half." },

    { docs: "https://docs.anycable.io/anycable-go/reliable_streams",
      repo: "anycable/docs.anycable.io",
      label: "AnyCable docs",
      note: "Our own docs, included so this is not only other people's bad news. Same outcome: " \
            "eligible, uncrawled, unmemorized." },

    # Software Heritage as the gate people forget: the licence is fine and the repo is popular, and
    # none of that matters because the archive never collected it.
    { docs: "https://resend.com/docs/send-with-nodejs",
      repo: "resend/resend-node",
      label: "Resend",
      note: "MIT with 941 stars, and Software Heritage has still never archived it. A licence on " \
            "an uncollected repo buys nothing." },

    # The study's headline in one page: 140 stars, no licence at all, below the quality bar, and
    # still reproduced by two frontier models from different labs. Copies beat popularity.
    { docs: "https://tailwindcss.com/docs/hover-focus-and-other-states",
      repo: "tailwindlabs/tailwindcss.com",
      label: "Tailwind CSS",
      note: "No licence file and 140 stars. Scores below the quality bar, and frontier models from " \
            "two labs still reproduce it word for word." }
  ].freeze

  # Clicking a listed example must never cost a visitor an allowance slot or trip the per-IP limit,
  # however cold the cache happens to be. Compared ignoring a trailing slash, since that is the one
  # difference a hand-typed URL reliably picks up.
  def self.example?(docs_url, repo)
    d = docs_url.to_s.strip.chomp("/")
    r = repo.to_s.strip.chomp("/")
    EXAMPLES.any? { |e| e[:docs].to_s.chomp("/") == d && e[:repo].to_s.chomp("/") == r }
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
