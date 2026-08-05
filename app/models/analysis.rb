# frozen_string_literal: true

class Analysis < ApplicationRecord
  belongs_to :user, optional: true   # anonymous runs are allowed, up to the free allowance

  validates :input, :session_token, presence: true

  scope :recent, -> { order(created_at: :desc) }

  # The listed examples are excluded by input rather than by faking from_cache on them, so
  # from_cache keeps meaning "this run cost nothing" and stays usable for cost reporting. Clicking
  # the examples is how a visitor learns what the tool does; charging an allowance slot for the
  # tour is the wrong trade even on the one cold run that genuinely spends money.
  scope :billable, -> { where(from_cache: false).where.not(input: AnalyzerConfig::DEMO_TARGETS) }

  # The four checks, in the order they are argued: can an agent read it, could it ever be trained
  # on, and did that actually happen.
  STEPS = [
    ["retrieval",     "Can agents retrieve it today?",        "robots, crawlability, sitemap, markdown twins"],
    ["code_channel",  "Could it reach a corpus through code?", "public repo, collection, license"],
    ["web_channel",   "Could it reach a corpus through the web?", "Common Crawl, then the quality filter"],
    ["memorization",  "Do models already reproduce it?",      "the slow one: several passages against every model"]
  ].freeze

  # Finished step payloads, keyed by step name, ready for the `analyses/step` partial.
  #
  # `results` is written through `as_json`, so it comes back with string keys and timestamps as
  # strings while the partial reads symbols. Without rehydrating it here, reloading a finished
  # analysis rendered every box as "waiting": the results were on disk, the page just never looked
  # at them and waited for a broadcast that had already happened.
  def step_payloads
    return {} unless results.is_a?(Hash)

    results.each_with_object({}) do |(step, payload), acc|
      next unless payload.is_a?(Hash)

      p = payload.deep_symbolize_keys
      p[:cached_at] = Time.zone.parse(p[:cached_at].to_s) rescue nil if p[:cached_at].present?
      acc[step.to_s] = p
    end
  end

  # Anonymous allowance is counted per browser session, and CACHED runs do not count.
  # Re-running the same link costs nothing and teaches the visitor how caching works, so charging
  # an allowance slot for it would be both unfair and confusing.
  def self.free_used(session_token)
    where(session_token: session_token, user_id: nil).billable.count
  end

  def self.free_remaining(session_token)
    [AnalyzerConfig::FREE_ANALYSES_PER_SESSION - free_used(session_token), 0].max
  end
end
