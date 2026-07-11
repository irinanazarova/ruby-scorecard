#!/usr/bin/env ruby
# frozen_string_literal: true

# Builds data/coverage.json : per-resource Common Crawl page counts vs total pages.
#
# Two independent numbers per resource:
#   total_pages  - pages the project publishes, counted from its sitemap (reachable any time).
#   cc_pages     - pages of that resource present in Common Crawl (the corpus most models train on).
#
# Common Crawl's CDX index has NO API key; access is IP rate-limited. We are polite by
# construction (https://commoncrawl.org/faq): a single serial thread, a sleep between calls,
# a descriptive RFC 9110 User-Agent, and a per-host cap. If the index is unreachable (it has
# frequent outages) or a host errors, we keep any previously known cc_pages instead of zeroing.
#
# Data lives in its own file (not scorecard.json) so re-running probe.rb never clobbers it;
# build.rb merges the two by resource name. Unknown values stay null = "not sampled", never 0.

require "json"
require "uri"
require "open3"
require "set"

ROOT = File.expand_path("..", __dir__)
COVERAGE_PATH = File.join(ROOT, "data", "coverage.json")

# Polite client identity + pacing.
UA = "ruby-scorecard/1.0 (+https://ruby.evilmartians.com; corpus-coverage probe)"
SLEEP_BETWEEN = 2.0   # seconds between CDX calls, per CC guidance
HOST_CAP = 5000       # max CDX records counted per host (keeps single queries bounded)
CDX_HOST = "https://index.commoncrawl.org"

# Trusted spot-checks (cc_pages, total_pages_override) carried from the published benchmark;
# total overrides matter where the figure is a crawl estimate rather than a sitemap count.
KNOWN_CC = {
  "Rails Guides" => [165, nil],
  "Inertia Rails" => [19, 71],
  "Turbo" => [6, 18],
  "RubyEvents" => [1, 15_775]
}.freeze

def curl(args, timeout: 30)
  out, _err, st = Open3.capture3("curl", "-sS", "-A", UA, "--max-time", timeout.to_s, *args)
  [out, st.success?]
rescue StandardError
  ["", false]
end

# ---- sitemap total (reachable now) ----
def sitemap_total(root)
  candidates = []
  body, = curl(["-L", "#{root}/robots.txt"], timeout: 10)
  body.each_line do |l|
    candidates << l.split(":", 2)[1].to_s.strip if l.strip.downcase.start_with?("sitemap:")
  end
  candidates += ["#{root}/sitemap.xml", "#{root}/sitemap_index.xml", "#{root}/sitemap-index.xml"]

  candidates.uniq.each do |sm|
    xml, ok = curl(["-L", sm], timeout: 25)
    next unless ok && xml.include?("<loc>")

    if xml.include?("<sitemapindex")
      children = xml.scan(%r{<loc>\s*([^<]+?)\s*</loc>}).flatten
      total = children.first(40).sum { |c| curl(["-L", c.strip], timeout: 25).first.scan("<loc>").size }
      return [total, "sitemap-index"]
    end
    return [xml.scan("<loc>").size, "sitemap"]
  end
  [nil, nil]
end

# ---- Common Crawl CDX count (polite; only when the index is up) ----
def latest_index
  body, ok = curl(["#{CDX_HOST}/collinfo.json"], timeout: 20)
  return nil unless ok && !body.empty?

  JSON.parse(body).first&.fetch("id", nil)
rescue StandardError
  nil
end

# Count CC pages for the whole docs host, so the numerator matches the (whole-host) sitemap
# denominator. Only genuinely shared hosts are path-scoped: github.com repos/wikis and
# *.github.io project pages (where the project lives in the path). Dedicated domains and
# project subdomains (roda.jeremyevans.net, test-prof.evilmartians.io) stay whole-host.
def cc_scope(docs_url)
  u = URI.parse(docs_url)
  host = u.host
  segs = u.path.split("/").reject(&:empty?)
  if host == "github.com" && segs.size >= 2
    "#{host}/#{segs[0]}/#{segs[1]}"
  elsif host.end_with?(".github.io") && !segs.empty?
    "#{host}/#{segs[0]}"
  else
    host
  end
end

def cc_count(scope, index_id)
  query = "url=#{scope}/*&output=json&fl=url&limit=#{HOST_CAP}"
  # Capture the HTTP status: a soft rate-limit (503) returns a non-empty HTML error page,
  # which must NOT be read as "zero records" or we publish a false exact 0.
  body, ok = curl(["-w", "\n__HTTP__%{http_code}", "#{CDX_HOST}/#{index_id}-index?#{query}"], timeout: 60)
  return [nil, false] unless ok

  code = body[/\n__HTTP__(\d+)\z/, 1]
  body = body.sub(/\n__HTTP__\d+\z/, "")

  # 404 with "No Captures found" is the CDX way of saying "reachable, genuinely zero records".
  return [0, true] if code == "404" && body.include?("No Captures")
  # Any other non-200 (503 rate-limit, 5xx outage) is "not sampled", never 0.
  return [nil, false] unless code == "200"
  # A truly empty 200 body is a real zero.
  return [0, true] if body.strip.empty?

  urls = Set.new
  parsed = false
  body.each_line do |line|
    line = line.strip
    next if line.empty?

    begin
      urls << JSON.parse(line)["url"]
      parsed = true
    rescue StandardError
      next
    end
  end
  # A non-empty 200 body that yielded no parseable JSON records is an error page, not a zero.
  return [nil, false] unless parsed

  capped = urls.size >= HOST_CAP
  [urls.size, !capped] # second value = "exact" (false when we hit the cap)
end

rows = JSON.parse(File.read(File.join(ROOT, "data", "scorecard.json")))["rows"]
existing = File.exist?(COVERAGE_PATH) ? JSON.parse(File.read(COVERAGE_PATH)) : {}

# --print emits the coverage JSON to STDOUT (progress goes to STDERR) so the run can be
# captured cleanly off a disposable Fly machine: `ruby scripts/coverage.rb --print > data/coverage.json`.
PRINT_ONLY = ARGV.include?("--print")

index_id = latest_index
if index_id
  warn "CC index up: #{index_id}"
else
  warn "CC index unreachable (outage or block) - keeping known cc_pages, filling sitemap totals only"
end

coverage = {}
rows.each do |r|
  name = r["name"]
  prev = existing[name] || {}
  entry = { "cc_pages" => prev["cc_pages"], "cc_exact" => prev["cc_exact"],
            "total_pages" => prev["total_pages"], "total_source" => prev["total_source"] }

  # total pages from the sitemap, where the resource publishes one
  if r["sitemap"]
    total, source = sitemap_total(r["root"])
    if total
      entry["total_pages"] = total
      entry["total_source"] = source
    end
  end

  # Common Crawl page count, politely, only when the index is up
  if index_id
    scope = r["cc_scope"] && !r["cc_scope"].empty? ? r["cc_scope"] : cc_scope(r["docs"])
    pages, exact = cc_count(scope, index_id)
    unless pages.nil?
      entry["cc_pages"] = pages
      entry["cc_exact"] = exact
    end
    sleep SLEEP_BETWEEN
  end

  # seed trusted spot-checks when we still have nothing
  if entry["cc_pages"].nil? && KNOWN_CC.key?(name)
    cc, total_override = KNOWN_CC[name]
    entry["cc_pages"] = cc
    entry["cc_exact"] = false
    entry["total_pages"] ||= total_override
    entry["total_source"] ||= "benchmark spot-check" if total_override
  end

  coverage[name] = entry
  pct = entry["cc_pages"] && entry["total_pages"] ? " (#{(100.0 * entry["cc_pages"] / entry["total_pages"]).round}%)" : ""
  warn format("%-24s cc=%-8s total=%-8s%s", name, entry["cc_pages"].inspect, entry["total_pages"].inspect, pct)
end

sampled = coverage.count { |_, e| e["cc_pages"] }
if PRINT_ONLY
  puts JSON.pretty_generate(coverage)
else
  File.write(COVERAGE_PATH, JSON.pretty_generate(coverage))
end
warn "DONE#{PRINT_ONLY ? " (stdout)" : " -> data/coverage.json"} | cc sampled #{sampled}/#{rows.size}"
