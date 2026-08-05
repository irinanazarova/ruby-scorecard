# frozen_string_literal: true

# Model access for /test.
#
# Secrets live in Rails encrypted credentials (config/credentials.yml.enc), so the only thing that
# has to exist in the deploy environment is RAILS_MASTER_KEY. ENV is kept as a fallback purely so a
# contributor can run the analyzer locally without the master key.
#
# Expected credentials shape (bin/rails credentials:edit):
#
#   anthropic:
#     api_key: sk-ant-...
#   openai:
#     api_key: sk-proj-...
#
Rails.application.configure do
  creds = Rails.application.credentials

  RubyLLM.configure do |config|
    config.anthropic_api_key = creds.dig(:anthropic, :api_key) || ENV["ANTHROPIC_API_KEY"]
    config.openai_api_key    = creds.dig(:openai, :api_key)    || ENV["OPENAI_API_KEY"]
    config.gemini_api_key    = creds.dig(:gemini, :api_key)    || ENV["GEMINI_API_KEY"]

    # RubyLLM ships 300s timeout x 3 retries, which is right for long generations and badly wrong
    # for these probes. A memorization probe asks for ~80 words and normally answers in 2-14s, but
    # the defaults allow 1200s PER CALL — 3 hours across a 9-probe analysis. One warm-up run took
    # 31 minutes on a single target, comfortably inside that budget and indistinguishable from a
    # hang. 45s is ~3x the slowest healthy probe observed (Gemini at ~14s); one retry covers a
    # blip without hiding a provider that is genuinely stuck.
    config.request_timeout = Integer(ENV.fetch("LLM_REQUEST_TIMEOUT", 45))
    config.max_retries = Integer(ENV.fetch("LLM_MAX_RETRIES", 1))
  end
end
