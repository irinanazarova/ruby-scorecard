# frozen_string_literal: true

module Analyzer
  # Which third-party keys this process actually has.
  #
  # Infrastructure, not configuration: these are secrets, they live in encrypted credentials, and
  # every answer here is a question about the environment the process is running in rather than a
  # value anyone tunes. That is the split the old AnalyzerConfig blurred, holding a spend cap and an
  # API key on the same object.
  #
  # Nothing here hands a key to a caller except the GitHub token, which Http needs to build a
  # header. The model keys are only ever asked ABOUT, never returned, so a probe can decide whether
  # a provider is available without a secret passing through it.
  class ApiKeys
    # Optional. Unauthenticated the GitHub API allows 60 requests/hour PER IP, which one busy demo
    # can exhaust and which a Fly machine shares across every visitor; with a token it is 5,000.
    def self.github_token
      Rails.application.credentials.dig(:github, :api_token) || ENV["GITHUB_TOKEN"]
    end

    READERS = { anthropic: :anthropic_api_key, openai: :openai_api_key,
                gemini: :gemini_api_key }.freeze

    def self.for?(provider)
      reader = READERS[provider] or return false
      RubyLLM.config.public_send(reader).present?
    end

    def self.any? = READERS.keys.any? { |p| for?(p) }
  end
end
