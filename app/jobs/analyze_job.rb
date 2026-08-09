# frozen_string_literal: true

# Runs one analysis and streams each slide to the page as its checks land.
#
# Streaming is the point: a cold run takes 40-110s because Common Crawl's index is slow, and a
# spinner for that long reads as broken. The agent-experience checks answer in ~1-3s and render
# immediately, so the visitor can be reading and clicking through the first slide while the slow
# checks are still working.
class AnalyzeJob < ApplicationJob
  queue_as :default

  # Every region of the results page that is recomputed from "everything known so far". Each one is
  # a partial whose root element carries the matching id, so a broadcast replaces it in place.
  #
  # They are recomputed after EVERY step rather than at the end, which is what makes the deck fill
  # in progressively instead of appearing all at once.
  LIVE_REGIONS = {
    "analysis_discoverability" => "analyses/discoverability",
    "analysis_funnel" => "analyses/funnel",
    "analysis_recall" => "analyses/recall",
    "analysis_actions" => "analyses/actions"
  }.freeze

  def perform(analysis_id)
    analysis = Analysis.find(analysis_id)
    analysis.update!(status: "running")
    broadcast_status(analysis)

    run = Analyzer::Run.new(target_for(analysis), models: Analyzer::Memorization.available_models)
    results = {}
    spent = 0

    run.call do |step, payload|
      results[step] = payload
      spent += model_cost_millicents(payload)

      # Persist after every step, not only at the end. A reload halfway through a 110s run used to
      # render an empty deck because the results column was still nil, and the page has no other way
      # to recover a broadcast it missed. A few extra UPDATEs per run buys a page that is correct
      # whenever it is loaded, whatever the stream did.
      analysis.update_columns(results: results.as_json, updated_at: Time.current)

      broadcast_step(analysis, step, payload)
      broadcast_regions(analysis, results)
    end

    # A run the controller already judged free stays free. It decided before doing the work, and
    # that is the decision the visitor was shown on the form. `target` is not a check and never has
    # a cache entry, so it is excluded before asking whether everything replayed.
    cached = analysis.from_cache || results.except(:target).values.all? { |p| p[:cache_hit] }

    analysis.update!(status: "done", results: results.as_json, cost_millicents: spent,
                     from_cache: cached)
    analysis.user&.spend!(spent)
    analysis.user&.increment!(:analyses_count)
    broadcast_status(analysis)
  rescue StandardError => e
    Rails.logger.error("[analyze_job] #{e.class}: #{e.message}")
    analysis&.update(status: "failed", results: { error: "#{e.class}: #{e.message[0, 200]}" })
    broadcast_status(analysis) if analysis
  end

  # Rebuilds what the visitor filled in. Public and named so it can be tested on its own: this is
  # the one place a new form field gets silently dropped, because every check downstream reads the
  # target rather than the record. Adding the pasted paragraph and forgetting it here produced a
  # finished run reporting "No testable prose found" about text typed out in front of us.
  def target_for(analysis)
    Analyzer::Target.new(docs_url: analysis.docs_url, repo: analysis.repo,
                         passage: analysis.passage)
  end

  private

  # Only cache MISSES cost anything, so a replayed run bills nothing.
  def model_cost_millicents(payload)
    return 0 if payload[:cache_hit]

    r = payload[:result]
    return 0 unless r.is_a?(Hash)

    cents = Array(r[:probes]).sum { |p| p[:cost_cents].to_f } +
            Array(r[:controls]).sum { |p| p[:cost_cents].to_f }
    (cents * 10).round
  end

  # References are the scale on the recall chart, not a measurement of this target, so they get no
  # evidence tile of their own.
  def broadcast_step(analysis, step, payload)
    return if step == :references

    Turbo::StreamsChannel.broadcast_replace_to(
      analysis, target: "step_#{step}",
      partial: "analyses/step",
      locals: { step: step, payload: payload, analysis: analysis }
    )
  end

  # Keys are stringified because every one of these partials reads the same shape a reloaded page
  # reads, and `results` here is still keyed by symbol.
  def broadcast_regions(analysis, results)
    payloads = results.stringify_keys
    LIVE_REGIONS.each do |target, partial|
      Turbo::StreamsChannel.broadcast_replace_to(
        analysis, target: target, partial: partial, locals: { payloads: payloads }
      )
    end
  end

  def broadcast_status(analysis)
    Turbo::StreamsChannel.broadcast_replace_to(
      analysis, target: "analysis_status",
      partial: "analyses/status", locals: { analysis: analysis }
    )
  end
end
