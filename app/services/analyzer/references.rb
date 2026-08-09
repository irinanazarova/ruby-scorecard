# frozen_string_literal: true

module Analyzer
  # Pages that are demonstrably in the training data, measured under the identical probe.
  #
  # A recall result means nothing on its own. "No model reproduced your docs" reads as a verdict on
  # your writing until you can see, on the same chart and from the same prompt, what a page that IS
  # in the corpus looks like. That is the whole job of this class.
  #
  # The PASSAGE IS PINNED, not re-picked each time. Both matter and the pinning is the part that was
  # learned the hard way: re-selecting spans from the live file gave the Rails i18n guide a 4-word
  # run and "fired for nobody", because recall is sparse and the passage that fires is one specific
  # one. A reference that does not visibly fire is worse than no reference, since the chart then
  # teaches that nothing is ever memorized. So each reference is a fixed 55 words in and 60 words
  # compared against, taken from our own 168-repo study and re-measured live on every model.
  #
  # The three were chosen to disagree with each other on everything except the outcome:
  #
  #   tailwindlabs/tailwindcss.com   no LICENSE file at all, ~140 stars
  #   rails/rails                    MIT, ~59k stars
  #   supabase/supabase              Apache-2.0, ~108k stars
  #
  # That is the study's finding in three columns: neither popularity nor licence predicts recall.
  #
  # Cached for 30 days per reference, so an expiry on one never costs the other two. Warm them with
  # `bin/rails analyzer:references`.
  class References
    CACHE_TTL = 30.days
    PASSAGE_FILE = Rails.root.join("config/reference_passages.json")

    class << self
      def all(models: Memorization.available_models)
        AnalyzerConfig::REFERENCES.filter_map { |config| one(config, models: models) }
      end

      def one(config, models: Memorization.available_models, refresh: false)
        Cache.fetch(:reference, "#{config[:passage]}/#{models.sort.join('+')}",
                    ttl: CACHE_TTL, refresh: refresh) do
          measure(config, models)
        end[:result]
      rescue StandardError => e
        Rails.logger.error("[references] #{config[:label]}: #{e.class}: #{e.message}")
        nil
      end

      def warm?(config, models: Memorization.available_models)
        Cache.warm?(:reference, "#{config[:passage]}/#{models.sort.join('+')}")
      end

      def passages
        @passages ||= JSON.parse(PASSAGE_FILE.read).fetch("passages")
      end

      private

      def measure(config, models)
        pinned = passages[config[:passage]]
        return { label: config[:label], error: "no pinned passage for #{config[:passage]}" } unless pinned

        passage = Passage::Result.new(ok: true, source: :docs, source_label: config[:repo],
                                      prefix: pinned["prefix"], truth: pinned["truth"],
                                      offset: 0, total_words: pinned["prefix"].split.size)

        probes = Memorization.new([passage], models: models, max_calls: models.size).call
        summary = Memorization.summarize(probes)

        { label: config[:label], url: config[:url], repo: config[:repo],
          passage: config[:passage],
          stars: stars(config[:repo]), license: license(config[:repo]),
          best_run: summary[:best_run], verdict: summary[:verdict],
          models_fired: summary[:models_fired], probes: summary[:probes],
          by_model: Memorization.matrix(probes, sources: %w[docs]) }
      end

      # Stars and licence are decoration on the column header, so a GitHub hiccup must not lose the
      # measurement that cost real money to take. Memoized because two callers want one lookup.
      def repo_info(repo)
        (@repo_info ||= {})[repo] ||=
          Http.json("https://api.github.com/repos/#{repo}", headers: Http.github_headers) || {}
      end

      def stars(repo) = repo_info(repo)["stargazers_count"]

      def license(repo) = repo_info(repo).dig("license", "spdx_id").presence || "no licence"
    end
  end
end
