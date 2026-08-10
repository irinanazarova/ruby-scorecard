# frozen_string_literal: true

source "https://rubygems.org"

# ---------------------------------------------------------------------------
# ruby.evilmartians.com
#
# One Rails app serving two things:
#   1. The existing scorecard, guide, contributors and rewrite pages. These stay STATIC: the
#      generators in scripts/ still render them into dist/ and Rails just serves the result, so
#      92 resources of hand-tuned HTML and the design system are untouched by this migration.
#   2. /test, the live analyzer: does this page or repo reach training data, and can agents
#      retrieve it.
# ---------------------------------------------------------------------------

gem "rails", "~> 8.1.3", ">= 8.1.3.1"
gem "propshaft"
gem "sqlite3", ">= 2.1"
gem "puma", ">= 5.0"
gem "importmap-rails"
gem "turbo-rails"       # results stream in per check, so nothing waits on Common Crawl
gem "stimulus-rails"
gem "tailwindcss-rails"
gem "tzinfo-data", platforms: %i[windows jruby]
gem "solid_cache"
gem "solid_queue"

# WebSockets via hosted AnyCable rather than Solid Cable.
#
# Solid Cable polls a database table for broadcasts, so on Fly it needs the DB and a volume, and
# the /test results stream is the one thing that must not be flaky during a live demo. Hosted
# AnyCable moves the connections off the Rails process entirely: Rails HTTP-POSTs a broadcast and
# the AnyCable server fans it out.
#
# Run it in SIGNED STREAMS mode (no RPC): Rails signs the stream name, the browser subscribes to
# AnyCable directly, and AnyCable never calls back into Rails. That removes the requirement for the
# app to be publicly reachable from AnyCable, which is what makes this work on localhost during
# rehearsal as well as in production.
gem "anycable-rails", "~> 1.6"
gem "bootsnap", require: false
gem "thruster", require: false

# --- the analyzer ---
gem "ruby_llm"                      # Claude + OpenAI behind one interface, with per-message cost
gem "omniauth-github"               # sign-in, so per-user spend can be capped
gem "omniauth-rails_csrf_protection"
gem "anyway_config", "~> 2.6"       # typed, source-agnostic settings instead of ENV.fetch + Integer()

# --- shared with the static generators in scripts/ ---
gem "nokogiri"                      # main-content extraction, used by the site build and by /test
gem "onnxruntime"                   # pure-Ruby FineWeb-Edu inference (vendor/fwedu/model.onnx)
gem "tokenizers"                    # the model's tokenizer.json

# The standalone Sinatra scorer in web/ stays deployable on its own (ruby-quality-api) while /test
# calls it over HTTP. Folding the ONNX model into this app is a separate, later step.
group :web do
  gem "sinatra"
  gem "rackup"
end

group :development, :test do
  gem "debug", platforms: %i[mri windows], require: "debug/prelude"
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
  # HTML-aware ERB parser, linter and formatter. Rubocop does not read .html.erb at all, so until
  # now nothing checked the half of this app that is views, and it is a lot of views.
  gem "herb", require: false
end

group :development do
  gem "web-console"
end
