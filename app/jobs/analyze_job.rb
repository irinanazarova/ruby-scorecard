# frozen_string_literal: true

# Runs one analysis and streams each check to the page as it lands.
#
# Streaming is the point: a cold run takes 40-110s because Common Crawl's index is slow, and a
# spinner for that long reads as broken. Retrieval answers in ~1s and renders immediately, so the
# page is filling while the slow checks are still working.
class AnalyzeJob < ApplicationJob
  queue_as :default

  def perform(analysis_id)
    analysis = Analysis.find(analysis_id)
    analysis.update!(status: "running")
    broadcast_status(analysis)

    run = Analyzer::Run.new(analysis.input, models: Analyzer::Memorization.available_models)
    results = {}
    spent = 0

    run.call do |step, payload|
      # repo_source is a property of the run, not of the step, so it has to be folded into what we
      # persist. Otherwise a reloaded page loses the "(found via ...)" note that says how we
      # guessed the repo for a docs URL.
      results[step] = payload.merge(repo_source: run.repo_source)
      spent += model_cost_millicents(payload)

      # Persist after every step, not only at the end. A reload halfway through a 110s run used to
      # render four empty boxes because the results column was still nil, and the page has no other
      # way to recover a broadcast it missed. Four extra UPDATEs per run buys a page that is correct
      # whenever it is loaded, whatever the stream did.
      analysis.update_columns(results: results.as_json, updated_at: Time.current)

      broadcast_step(analysis, step, payload, run)
      broadcast_verdict(analysis, results)
      broadcast_actions(analysis, results)
    end

    # Two corrections, both of which were charging visitors for runs that cost nothing:
    #
    #   - `target` is not a check. It is the parsed input, echoed back, and it never has a cache
    #     entry, so `all?` over every step could never be true and NO run was ever recorded as
    #     cached. A fully warm re-run still consumed an allowance slot.
    #   - A run the controller already judged free stays free. It decided before doing the work,
    #     and that is the decision the visitor was shown on the form.
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

  def broadcast_step(analysis, step, payload, run)
    Turbo::StreamsChannel.broadcast_replace_to(
      analysis, target: "step_#{step}",
      partial: "analyses/step",
      locals: { step: step, payload: payload, analysis: analysis, repo_source: run.repo_source }
    )
  end

  # The headline is recomputed from everything known SO FAR after every step, which is what makes it
  # sharpen instead of appearing at the end. Keys are stringified because Verdict reads the same
  # shape a reloaded page reads, and `results` here is still keyed by symbol.
  def broadcast_verdict(analysis, results)
    Turbo::StreamsChannel.broadcast_replace_to(
      analysis, target: "analysis_verdict",
      partial: "analyses/verdict",
      locals: { payloads: results.stringify_keys, status: analysis.status }
    )
  end

  # Advice follows the same rule as the headline: it is recomputed from everything known so far, so
  # the list grows as checks land instead of appearing all at once at the end.
  def broadcast_actions(analysis, results)
    Turbo::StreamsChannel.broadcast_replace_to(
      analysis, target: "analysis_actions",
      partial: "analyses/actions",
      locals: { payloads: results.stringify_keys }
    )
  end

  def broadcast_status(analysis)
    Turbo::StreamsChannel.broadcast_replace_to(
      analysis, target: "analysis_status",
      partial: "analyses/status", locals: { analysis: analysis }
    )
  end
end
