# frozen_string_literal: true

# Score content with the FineWeb-Edu proxy and print JSON (score, verdict, suggestions, features).
# Used by the `improve-training-quality` skill as its measurement tool.
#
#   ruby scripts/score.rb url  https://example.com/page   # fetch + extract main content, then score
#   ruby scripts/score.rb text path/to/draft.txt          # score a raw-text draft (a rewrite)
#   ruby scripts/score.rb text -                          # score raw text from stdin

require_relative "quality_core"
require "json"
require "open-uri"

mode = ARGV[0]
src = ARGV[1]
abort "usage: ruby scripts/score.rb [url <URL> | text <FILE|->]" unless %w[url text].include?(mode) && src

content =
  case mode
  when "url"
    URI.parse(src).open("User-Agent" => "ruby-scorecard/1.0 quality-probe (+https://ruby.evilmartians.com)").read
  when "text"
    src == "-" ? $stdin.read : File.read(src)
  end

res = QualityCore.check(content, is_html: mode == "url")
puts JSON.pretty_generate(res)
