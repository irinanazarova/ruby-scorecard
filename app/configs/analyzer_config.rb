# frozen_string_literal: true

# Tunable settings for the /test analyzer.
#
# Deliberate split, unchanged: SECRETS go in encrypted credentials, KNOBS go here in plain sight. A
# spend cap and a call limit are not secrets, and burying them in an encrypted blob makes them hard
# to review and easy to forget.
#
# What changed is how they are read. Every value used to be `Integer(ENV.fetch("X", 5))` frozen into
# a constant at boot, which meant the type coercion was hand-written per line, a typo in an env var
# surfaced as an ArgumentError during boot with no indication of which setting caused it, and a
# test could not override a value without stubbing a constant. anyway_config gives typed defaults,
# one declaration per setting, and the same value reachable from an env var, config/analyzer.yml or
# credentials without any of the readers caring which.
#
# ENV NAMES ARE NOW PREFIXED: ANALYZER_FREE_ANALYSES_PER_SESSION, not FREE_ANALYSES_PER_SESSION.
# Safe to change because nothing sets them: production runs entirely on the defaults below, and the
# only env vars Fly carries are RAILS_ENV, HTTP_PORT, SOLID_QUEUE_IN_PUMA and DATABASE_DIR.
class AnalyzerConfig < Anyway::Config
  config_name :analyzer

  attr_config(
    # Hard ceiling on model spend per signed-in user, enforced against RubyLLM's reported
    # per-message cost rather than an estimate. Reaching it blocks further probes for that user; it
    # does not silently degrade the results.
    budget_cents_per_user: 500,

    # Anonymous visitors get this many LIVE analyses per browser session before signing in. Cached
    # re-runs are free and never consume the allowance: making someone burn a slot to re-view a
    # result they already paid for would punish exactly the behaviour the demo is trying to teach.
    free_analyses_per_session: 5,

    # Bot defence. An analysis is expensive (~5c of model calls), so the limits are deliberately
    # tighter than a normal web form's: a scripted loop is the one thing that could actually drain
    # the account. Cached repeats are cheap and are not what these limits are aimed at.
    rate_limit_ip_count: 10,
    rate_limit_ip_daily: 60,

    # 2 spans x up to 3 sources x 3 models. The cap is a spend guard, but set it too low and it
    # silently costs accuracy instead of money: at 6 calls the third model squeezed out the third
    # span, and a page that scores a 91-word verbatim run from its repo source came back "partial"
    # at 10. Spans are where the signal is, so the cap must leave room for every one of them on
    # every source the visitor actually filled in.
    max_model_calls_per_analysis: 15,

    # Wall-clock ceiling for the whole memorization step, in seconds. The call cap bounds SPEND;
    # this bounds TIME, which the call cap cannot: per-call timeouts multiply, and a run that looks
    # healthy per-probe can still take half an hour in aggregate. A healthy 9-probe run finishes in
    # 60-140s, so 180 leaves room for one slow provider without letting a stuck one hold the page
    # open.
    memorization_deadline: 180,

    # The FineWeb-Edu scorer. Still its own Fly app (ruby-quality-api) because it carries the ONNX
    # model; /test calls it over HTTP.
    quality_api: "https://ruby-quality-api.fly.dev/api/check"
  )

  coerce_types budget_cents_per_user: :integer,
               free_analyses_per_session: :integer,
               rate_limit_ip_count: :integer,
               rate_limit_ip_daily: :integer,
               max_model_calls_per_analysis: :integer,
               memorization_deadline: :integer,
               quality_api: :string

  class << self
    # One instance for the process. anyway_config objects are cheap, but the readers here are on hot
    # paths (every request asks the rate limiter, every probe asks the call cap) and a shared
    # instance means the settings are resolved once rather than per call.
    def instance = @instance ||= new

    # Let AnalyzerConfig.free_analyses_per_session keep working as a plain read, which is how all
    # fourteen call sites already spell it.
    def method_missing(name, ...) = instance.respond_to?(name) ? instance.public_send(name, ...) : super

    def respond_to_missing?(name, include_private = false) = instance.respond_to?(name) || super

    # Tests that need a different limit can set it and put it back, rather than stubbing a frozen
    # constant.
    def reset! = @instance = nil
  end

  # Durations and structured shapes are derived, not stored: the setting is the number, and the
  # window is a property of the limiter that reads it.
  def memorization_deadline_seconds = memorization_deadline.seconds
  def rate_limit_per_ip = { count: rate_limit_ip_count, within: 5.minutes }
  def rate_limit_per_ip_daily = { count: rate_limit_ip_daily, within: 1.day }
end
