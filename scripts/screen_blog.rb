# frozen_string_literal: true

# Screen a list of blog URLs (data/blog/urls.txt) with the local scorer, to find which posts a lead
# rewrite could move past the FineWeb-Edu >= 3 bar. Writes data/blog/screen.json, ranked by score.

require_relative "quality_core"
require "json"
require "open-uri"

urls = File.readlines(File.join(__dir__, "..", "data", "blog", "urls.txt")).map(&:strip).reject(&:empty?)
out = []
urls.each_with_index do |u, i|
  begin
    html = URI.parse(u).open("User-Agent" => "ruby-scorecard/1.0 quality-probe", read_timeout: 20).read
    r = QualityCore.check(html)
    if r[:ok]
      f = r[:features]
      out << { url: u, score: r[:score], doc: r[:doc_score], words: r[:extracted_words],
               defines: f[:opens_with_definition], sent: f[:avg_sentence_words],
               meta: f[:leading_meta], code: f[:code_density], fixes: r[:suggestions].size }
    else
      out << { url: u, error: r[:error] }
    end
  rescue StandardError => e
    out << { url: u, error: e.message }
  end
  r = out.last
  printf("  [%2d/%d] %-58s %s\n", i + 1, urls.size, u.split("/").last[0, 56],
         r[:score] ? format("%.2f (sent %.0f, fixes %d)", r[:score], r[:sent], r[:fixes]) : "ERR")
end
File.write(File.join(__dir__, "..", "data", "blog", "screen.json"), JSON.pretty_generate(out))
ok = out.select { |r| r[:score] }
warn "\nscored #{ok.size}/#{out.size}. Bands: >=3 #{ok.count { |r| r[:score] >= 3 }} | " \
     "2.0-2.99 #{ok.count { |r| r[:score] >= 2 && r[:score] < 3 }} | <2.0 #{ok.count { |r| r[:score] < 2 }}"
