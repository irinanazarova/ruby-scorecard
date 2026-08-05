# frozen_string_literal: true

module Analyzer
  # The side-by-side reference point.
  #
  # A memorization result means nothing on its own. "No model reproduced your docs" reads as a
  # verdict on your writing until you see that a page which IS in the training data looks visibly
  # different under the same probe. So every analysis is shown against a baseline that demonstrably
  # fires.
  #
  # The baseline passage is verified, not assumed. In a 168-repo study it fired on two model
  # families, and re-measured here Claude reproduced 91 consecutive words of it verbatim. Picking a
  # famous product and hoping is how this beat dies on stage: the obvious choice (Supabase's auth
  # guide) does NOT fire on the span you would naively pick.
  #
  # It also quietly makes the study's point — this repo has 137 stars and no license, and is more
  # memorized than repos with a thousand times the stars.
  class Baseline
    CACHE_TTL = 30.days

    class << self
      def config = AnalyzerConfig::BASELINE

      # Cached hard: the baseline is identical for every visitor, so paying for it per analysis
      # would be pure waste. Pre-warmed by `bin/rails analyzer:warm`.
      def summary(refresh: false)
        Cache.fetch(:baseline, config[:repo], ttl: CACHE_TTL, refresh: refresh) { measure }[:result]
      rescue StandardError => e
        Rails.logger.error("[baseline] #{e.class}: #{e.message}")
        nil
      end

      def warm? = Cache.warm?(:baseline, config[:repo])

      private

      def measure
        info = Http.json("https://api.github.com/repos/#{config[:repo]}", headers: Http.github_headers)
        return { error: "baseline repo unavailable" } unless info

        passages = Passage.candidates_from_repo_file(config[:repo], info["default_branch"], config[:path])
        ok = passages.select(&:ok)
        return { error: "baseline passage unavailable" } if ok.empty?

        probes = Memorization.new(ok, models: Memorization.available_models).call
        { label: config[:label], url: config[:url], repo: config[:repo],
          stars: info["stargazers_count"],
          license: (info.dig("license", "spdx_id") || "none"),
          summary: Memorization.summarize(probes),
          probes: probes }
      end
    end
  end
end
