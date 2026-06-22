# frozen_string_literal: true

# Second gate, sampled: score up to N pages per scorecard resource (not just the docs landing page).
# For each resource we fetch the docs URL, follow same-site doc links to gather up to N distinct pages,
# score each with the local FineWeb-Edu scorer, and aggregate. Writes data/quality_sample.json.
#
#   ruby scripts/quality_sample.rb            # all resources, 5 pages each
#   ruby scripts/quality_sample.rb 5 Rails    # limit to resources whose name matches (debug)

require_relative "quality_core"
require "json"
require "open-uri"
require "uri"
require "nokogiri"

ROOT = File.expand_path("..", __dir__)
N = (ARGV[0] || "5").to_i
FILTER = ARGV[1]
UA = { "User-Agent" => "ruby-scorecard/1.0 quality-probe (+https://ruby.evilmartians.com)", read_timeout: 15, open_timeout: 8 }

def fetch(url)
  URI.parse(url).open(UA).read
rescue StandardError
  nil
end

# Categorize a doc URL by likely page type, so the sample spans landing/guide/reference/example
# rather than five sibling nav links of the same kind.
def page_type(url)
  u = url.downcase
  return "guide"     if u =~ /guide|tutorial|getting.?started|quick.?start|start|walkthrough|learn/
  return "example"   if u =~ /example|recipe|cookbook|how.?to|demo|sample|snippet/
  return "concept"   if u =~ /concept|overview|architecture|introduction|\bintro\b|why|design/
  return "reference" if u =~ /reference|\bapi\b|config|option|method|class|module|\bcli\b|command|setting/
  "other"
end

# From a landing page, pick up to (n-1) same-site doc links, spread across page types, to sample
# alongside the landing itself.
def sample_links(base_url, html, n)
  base = URI.parse(base_url)
  doc = Nokogiri::HTML(html)
  main = doc.at_css("article, main, [role=main], .content, .theme-default-content, nav, body") || doc
  seen = { base_url.sub(%r{/\z}, "") => true }
  buckets = Hash.new { |h, k| h[k] = [] }
  main.css("a[href]").each do |a|
    href = a["href"].to_s.strip
    next if href.empty? || href.start_with?("#", "mailto:", "javascript:")
    begin
      u = base.merge(href)
    rescue StandardError
      next
    end
    next unless %w[http https].include?(u.scheme)
    next unless u.host == base.host                       # same host only
    u.fragment = nil
    key = u.to_s.sub(%r{/\z}, "").sub(/[?#].*\z/, "")
    next if seen[key] || key =~ /\.(png|jpg|svg|pdf|zip|gz|css|js|txt|xml|json|atom|rss)$/i
    next if key =~ /llms[-.]|sitemap|\.well-known/
    seen[key] = true
    buckets[page_type(key)] << key
  end
  # Round-robin across types (guide, reference, example, concept, other) for a diverse spread.
  order = %w[guide reference example concept other]
  out = []
  loop do
    before = out.size
    order.each do |t|
      next if buckets[t].empty? || out.size >= n - 1
      out << buckets[t].shift
    end
    break if out.size >= n - 1 || out.size == before
  end
  out
end

rows = JSON.parse(File.read(File.join(ROOT, "data", "scorecard.json")))["rows"]
rows = rows.select { |r| r["name"].include?(FILTER) } if FILTER
out = {}

rows.each_with_index do |r, i|
  name = r["name"]
  landing = r["docs"]
  html = fetch(landing)
  unless html
    out[name] = { "ok" => false, "error" => "landing fetch failed", "pages" => [] }
    warn format("  [%2d/%d] %-22s landing fetch failed", i + 1, rows.size, name[0, 22])
    next
  end
  urls = [landing] + sample_links(landing, html, N)
  pages = []
  urls.first(N).each do |u|
    body = u == landing ? html : fetch(u)
    next unless body
    text, = QualityCore.extract_text(body)
    next if text.split.size < 40
    sc = QualityCore.score_text(text)
    pages << { "url" => u, "type" => (u == landing ? "landing" : page_type(u)), "score" => sc[:score],
               "int" => sc[:int_score], "keep" => sc[:int_score] >= 3, "curly" => text.include?("{"),
               "words" => text.split.size }
  end
  scores = pages.map { |p| p["score"] }
  out[name] = {
    "ok" => !pages.empty?,
    "n" => pages.size,
    "best" => scores.max,
    "mean" => scores.empty? ? nil : (scores.sum / scores.size).round(2),
    "any_keep" => pages.any? { |p| p["keep"] },
    "pages" => pages
  }
  s = out[name]
  warn format("  [%2d/%d] %-22s n=%d best=%s any_keep=%s", i + 1, rows.size, name[0, 22],
              s["n"], s["best"] ? format("%.2f", s["best"]) : "-", s["any_keep"])
end

File.write(File.join(ROOT, "data", "quality_sample.json"), JSON.pretty_generate(out))
ok = out.select { |_, v| v["ok"] }
keepers = ok.count { |_, v| v["any_keep"] }
warn "\n#{ok.size}/#{out.size} resources scored; #{keepers} have >=1 page that clears the bar " \
     "(#{out.sum { |_, v| v['n'].to_i }} pages scored total) -> data/quality_sample.json"
