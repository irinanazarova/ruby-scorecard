# frozen_string_literal: true

module Analyzer
  # Per-check result cache.
  #
  # Two reasons this exists, and only one of them is the demo:
  #
  #   1. Common Crawl's index takes 3-45s depending on how cold it is, and it is the only check that
  #      can stall a run. Cached, the same URL returns instantly.
  #   2. Memorization probes cost real money. Re-running an identical probe against the same passage
  #      burns budget to learn nothing, since we ask at temperature 0.
  #
  # Caching is per CHECK, not per analysis, so a partial re-run reuses whatever is already warm and
  # only pays for what actually changed.
  #
  # Every cached result carries `cached_at`, and the UI always shows it. A cached result presented as
  # a live one would be a lie, especially on stage; a cached result presented as cached is just fast.
  class Cache
    DEFAULT_TTL = 7.days
    NAMESPACE = "analyzer/v1"

    class << self
      # Runs the block on a miss, returns { result:, cached_at:, cache_hit:, took_ms: }.
      def fetch(kind, target, ttl: DEFAULT_TTL, refresh: false, &block)
        key = key_for(kind, target)
        Rails.cache.delete(key) if refresh

        hit = true
        payload = Rails.cache.fetch(key, expires_in: ttl) do
          hit = false
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          value = block.call
          { result: value,
            cached_at: Time.current,
            took_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round }
        end

        payload.merge(cache_hit: hit, key: key)
      rescue StandardError => e
        # A cache backend problem must never take down a check: fall through to a live run.
        Rails.logger.warn("[analyzer] cache #{kind} failed: #{e.class} #{e.message}")
        { result: block.call, cached_at: Time.current, cache_hit: false, took_ms: nil, key: key }
      end

      def warm?(kind, target)
        Rails.cache.exist?(key_for(kind, target))
      end

      # What is already warm for a target, so the UI can show "this will be instant" before you run.
      def status(kinds, target)
        kinds.index_with { |k| warm?(k, target) }
      end

      def key_for(kind, target)
        "#{NAMESPACE}/#{kind}/#{Digest::SHA256.hexdigest(target.to_s)[0, 32]}"
      end
    end
  end
end
