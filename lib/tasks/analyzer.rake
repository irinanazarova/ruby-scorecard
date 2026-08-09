# frozen_string_literal: true

namespace :analyzer do
  desc "Pre-warm the cache for the listed examples, or for one pair: " \
       "bin/rails 'analyzer:warm[https://example.com/docs/page,owner/repo]'"
  task :warm, %i[docs repo] => :environment do |_t, args|
    targets =
      if args[:docs].present? || args[:repo].present?
        [ Analyzer::Target.new(docs_url: args[:docs], repo: args[:repo]) ]
      else
        Analyzer::Example.all.map { |e| Analyzer::Target.new(docs_url: e[:docs], repo: e[:repo]) }
      end

    targets.each do |target|
      puts "\n=== warming #{target.label}"
      unless target.valid?
        warn "  invalid: #{target.error}"
        next
      end

      Analyzer::Run.new(target, refresh: true).call do |step, payload|
        status = payload[:error] || payload.dig(:result, :error)
        took = payload[:took_ms] ? "#{payload[:took_ms]}ms" : "-"
        puts format("  %-14s %-8s %s", step, took, status ? "ERROR: #{status}" : "ok")
      end
    end

    puts "\nCache warm. The same pairs will now return from cache."
    puts "On stage, run the SAME pairs: cached checks are instant and labelled 'cached'."
  end

  desc "Measure the reference pages the recall chart is scaled against (cached 30 days)"
  task references: :environment do
    models = Analyzer::Memorization.available_models
    abort "no model API keys configured" if models.empty?

    Analyzer::ReferencePage.all.each do |config|
      result = Analyzer::References.one(config, models: models, refresh: true)
      if result.nil? || result[:error]
        warn format("  %-24s ERROR: %s", config[:label], result&.dig(:error) || "no result")
        next
      end

      puts format("  %-24s %2d words, fired for %s", result[:label], result[:best_run],
                  Array(result[:models_fired]).to_sentence.presence || "nobody")
    end
  end

  desc "Show which checks are already cached for a pair"
  task :status, %i[docs repo] => :environment do |_t, args|
    target = Analyzer::Target.new(docs_url: args[:docs], repo: args[:repo])
    abort "usage: bin/rails 'analyzer:status[https://...,owner/repo]'" unless target.valid?

    puts "#{target.label}:"
    Analyzer::Run.new(target).cache_status.each do |k, warm|
      puts format("  %-14s %s", k, warm ? "WARM" : "cold")
    end
  end

  desc "Clear all cached analyzer results"
  task clear: :environment do
    Rails.cache.delete_matched("#{Analyzer::Cache::NAMESPACE}/*")
    puts "analyzer cache cleared"
  rescue StandardError => e
    warn "delete_matched unsupported on this store (#{e.class}); clearing whole cache"
    Rails.cache.clear
  end
end
