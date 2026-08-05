# frozen_string_literal: true

namespace :analyzer do
  desc "Pre-warm the cache for demo targets. Usage: bin/rails 'analyzer:warm[https://workos.com/docs/authkit]'"
  task :warm, [:target] => :environment do |_t, args|
    targets = Array(args[:target].presence || AnalyzerConfig::DEMO_TARGETS)
    targets += args.extras

    targets.each do |input|
      puts "\n=== warming #{input}"
      run = Analyzer::Run.new(input, refresh: true)
      unless run.valid?
        warn "  invalid: #{run.target.error}"
        next
      end

      run.call do |step, payload|
        status = payload[:error] || payload.dig(:result, :error)
        took = payload[:took_ms] ? "#{payload[:took_ms]}ms" : "-"
        puts format("  %-14s %-8s %s", step, took, status ? "ERROR: #{status}" : "ok")
      end
    end

    puts "\nCache warm. The same inputs will now return from cache."
    puts "On stage, run the SAME link: cached checks are instant and labelled 'cached'."
  end

  desc "Show which checks are already cached for a target"
  task :status, [:target] => :environment do |_t, args|
    target = args[:target] or abort "usage: bin/rails 'analyzer:status[https://...]'"
    run = Analyzer::Run.new(target)
    puts "#{target}:"
    run.cache_status.each { |k, warm| puts format("  %-14s %s", k, warm ? "WARM" : "cold") }
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
