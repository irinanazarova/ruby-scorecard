# frozen_string_literal: true

class Analysis < ApplicationRecord
  belongs_to :user, optional: true   # anonymous runs are allowed, up to the free allowance

  validates :input, :session_token, presence: true

  scope :recent, -> { order(created_at: :desc) }

  # `from_cache` is set when the analysis is CREATED, from the controller's free_run? decision, and
  # the job only ever widens it. So the listed examples and any already-warm re-run are already
  # excluded here and need no second clause: clicking the examples is how a visitor learns what the
  # tool does, and charging an allowance slot for the tour is the wrong trade.
  scope :billable, -> { where(from_cache: false) }

  # Rows created before the form had two fields carry everything in `input`. Splitting them here
  # rather than backfilling keeps old permalinks working without a migration that has to guess.
  def docs_url
    self[:docs_url].presence || legacy_target.url
  end

  def repo
    self[:repo].presence || legacy_target.repo
  end

  # Which slides the deck shows. A run that is only a pasted paragraph has no site to fetch and no
  # repo to read, so two of the four slides would be nothing but "nothing given to check".
  def passage_only? = passage.present? && docs_url.blank? && repo.blank?

  # The evidence boxes and their wording moved to Analyzer::Steps in app/presenters. They were
  # sentences for a screen, and a model should not have to be edited to reword a heading.
  # Analyzer::Run::STEPS remains the authority on what actually executes.

  # Finished step payloads, keyed by step name.
  #
  # This is rehydration, not presentation: it reads back what was written, in the shape it was
  # written. Which is why it stays on the model while the wording did not.
  #
  # `results` is written through `as_json`, so it comes back with string keys and timestamps as
  # strings while the partial reads symbols. Without rehydrating it here, reloading a finished
  # analysis rendered every box as "waiting": the results were on disk, the page just never looked
  # at them and waited for a broadcast that had already happened.
  def step_payloads
    stored = results.is_a?(Hash) ? results : {}

    payloads = stored.each_with_object({}) do |(step, payload), acc|
      next unless payload.is_a?(Hash)

      p = payload.deep_symbolize_keys
      p[:cached_at] = Time.zone.parse(p[:cached_at].to_s) rescue nil if p[:cached_at].present?
      acc[step.to_s] = p
    end

    # Every region on the page has to know which of the two boxes was filled in, because that is
    # what separates "this channel is closed" from "we never looked". The run emits a target step
    # first thing, so this only fills in for rows written before it did.
    payloads["target"] ||= { result: { docs_url: docs_url, repo: repo, passage: passage,
                                       label: input },
                             cache_hit: false, cached_at: nil }
    payloads
  end

  # Were the RESULTS replayed, rather than measured just now? That is a different question from
  # whether the run was free, and the status line was answering the wrong one: the listed examples
  # carry from_cache by policy however cold the cache is, so a run that had just spent $0.13 on live
  # model probes announced itself as "replayed from cache" directly above a step badge reading
  # "measured live in 3.4s".
  def replayed?
    steps = step_payloads.except("target")
    steps.any? && steps.values.all? { |payload| payload[:cache_hit] }
  end

  # Anonymous allowance is counted per browser session, and CACHED runs do not count.
  # Re-running the same link costs nothing and teaches the visitor how caching works, so charging
  # an allowance slot for it would be both unfair and confusing.
  def self.free_used(session_token)
    where(session_token: session_token, user_id: nil).billable.count
  end

  def self.free_remaining(session_token)
    [ AnalyzerConfig.free_analyses_per_session - free_used(session_token), 0 ].max
  end

  private

  def legacy_target
    @legacy_target ||= Analyzer::Target.from_input(input)
  end
end
