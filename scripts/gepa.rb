# frozen_string_literal: true

# GEPA-style rule mining for the quality feedback engine.
#   ruby scripts/gepa.rb baseline   # fetch + score the corpus (data/gepa/urls.txt) -> baseline.json
#   ruby scripts/gepa.rb score      # re-score rewritten leads in data/gepa/rewrites.json -> deltas.json
#
# Scoring is local (quality_core). The "improve" step (rewriting leads) is done by the model between
# these two passes; this script measures the deltas and the feature changes so rules can be mined.

require_relative "quality_core"
require "json"
require "open-uri"
require "fileutils"

DIR = File.expand_path("../data/gepa", __dir__)
FileUtils.mkdir_p(DIR)
UA = { "User-Agent" => "ruby-scorecard/1.0 quality-probe (+https://ruby.evilmartians.com)" }

def fetch(url)
  URI.parse(url).open(UA.merge(read_timeout: 20)).read
rescue StandardError => e
  warn "  fetch error #{url}: #{e.message}"
  nil
end

case ARGV[0]
when "baseline"
  urls = File.readlines(File.join(DIR, "urls.txt")).map(&:strip).reject { |l| l.empty? || l.start_with?("#") }
  out = {}
  urls.each do |u|
    html = fetch(u)
    next (out[u] = { "ok" => false, "error" => "fetch failed" }) unless html
    text, method = QualityCore.extract_text(html)
    if text.length < 50
      out[u] = { "ok" => false, "error" => "no text (#{method})", "words" => text.split.size }
    else
      sc = QualityCore.score_text(text)
      ft = QualityCore.features(text)
      out[u] = { "ok" => true, "score" => sc[:score], "doc_score" => sc[:doc_score],
                 "words" => ft[:words], "features" => ft, "extraction" => method,
                 "lead" => text.split.first(480).join(" ") }
    end
    r = out[u]
    printf("  %-66s %s\n", u.sub(%r{^https?://}, "")[0, 64],
           r["ok"] ? format("words=%-5d score=%.2f", r["words"], r["score"]) : "SKIP (#{r['error']})")
  end
  File.write(File.join(DIR, "baseline.json"), JSON.pretty_generate(out))
  ok = out.count { |_, v| v["ok"] }
  warn "\nbaseline: #{ok}/#{out.size} usable -> data/gepa/baseline.json"

when "score"
  # rewrites.json: { url => rewritten_lead_text }. Score each, diff features vs baseline.
  base = JSON.parse(File.read(File.join(DIR, "baseline.json")))
  rewrites = JSON.parse(File.read(File.join(DIR, "rewrites.json")))
  rows = []
  rewrites.each do |url, lead|
    next unless base[url] && base[url]["ok"]
    b = base[url]
    sc = QualityCore.score_text(lead)
    ft = QualityCore.features(lead)
    rows << { "url" => url, "base_score" => b["score"], "new_score" => sc[:score],
              "delta" => (sc[:score] - b["score"]).round(2),
              "base_features" => b["features"], "new_features" => ft }
    printf("  %-50s %.2f -> %.2f  (Δ %+.2f)\n", url.sub(%r{^https?://}, "")[0, 48], b["score"], sc[:score],
           sc[:score] - b["score"])
  end
  File.write(File.join(DIR, "deltas.json"), JSON.pretty_generate(rows))
  warn "\nscored #{rows.size} rewrites -> data/gepa/deltas.json"

else
  abort "usage: ruby scripts/gepa.rb [baseline|score]"
end
