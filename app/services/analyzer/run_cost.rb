# frozen_string_literal: true

module Analyzer
  # Will this run cost anything?
  #
  # Only the memorization probe spends money: it calls models. Every other check is plain HTTP
  # against someone else's server. So a run is free when that probe is already cached, and the
  # listed examples are free by policy however cold the cache is, because clicking the examples is
  # how a visitor learns what the tool does and charging an allowance slot for the tour is the wrong
  # trade.
  #
  # This is asked twice per request, by the rate-limit guard and by the create path, and they have
  # to agree. When it lived in the controller as a memoized private method the two could and did
  # disagree: the guard asked cache_status for all four checks with the URL, while code_channel
  # caches under the REPO, so it never once returned true and cached re-runs kept consuming the
  # allowance they were meant to be exempt from. Keyed here the way Run keys it, in one place.
  class RunCost
    def self.free?(target)
      return false unless target&.valid?
      return true if AnalyzerConfig.example?(target.url, target.repo)

      Cache.warm?(:memorization, target.cache_key)
    end
  end
end
