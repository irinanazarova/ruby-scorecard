#!/usr/bin/env ruby
# frozen_string_literal: true

# Per-resource Common Crawl detail: which exact documentation pages ARE in Common Crawl and
# which are NOT. These projects publish no sitemap, so the reference page set is enumerated by
# crawling the live docs host; we then diff it against the CC URL set for the same scope.
#
# Needs CC index access -> run from a Fly machine: fetch/details-on-fly.sh
# Usage:  ruby scripts/coverage_details.rb [--print] ["Resource Name" ...]   (default: Inertia Rails, AnyCable)

require "json"
require "uri"
require "open3"
require "set"

ROOT = File.expand_path("..", __dir__)
UA = "ruby-scorecard/1.0 (+https://ruby.evilmartians.com; coverage-details probe)"
CDX_HOST = "https://index.commoncrawl.org"
CC_CAP = 8000      # max CDX records per scope
CRAWL_CAP = 600    # max pages to enumerate per docs site
CDX_SLEEP = 2.0
SKIP_EXT = %w[.css .js .png .jpg .jpeg .svg .gif .pdf .zip .xml .ico .woff .woff2 .webp .json .txt].freeze

PRINT_ONLY = !ARGV.delete("--print").nil?
TARGETS = ARGV.empty? ? ["Inertia Rails", "AnyCable"] : ARGV.dup

def curl(url, timeout: 25)
  out, _err, st = Open3.capture3("curl", "-sSL", "-A", UA, "--max-time", timeout.to_s, url)
  [out, st.success?]
rescue StandardError
  ["", false]
end

# scheme/www/trailing-slash-insensitive key: host + path (no query/fragment)
def norm(url)
  u = URI.parse(url)
  return nil unless u.host

  host = u.host.downcase.sub(/\Awww\./, "")
  path = u.path.to_s.sub(%r{/\z}, "")
  path = "/" if path.empty?
  "#{host}#{path}"
rescue StandardError
  nil
end

# Same whole-host (path only for shared hosts) scope used by coverage.rb.
def cc_scope(docs_url)
  u = URI.parse(docs_url)
  segs = u.path.split("/").reject(&:empty?)
  if u.host == "github.com" && segs.size >= 2 then "#{u.host}/#{segs[0]}/#{segs[1]}"
  elsif u.host.end_with?(".github.io") && !segs.empty? then "#{u.host}/#{segs[0]}"
  else u.host
  end
end

def latest_index
  body, ok = curl("#{CDX_HOST}/collinfo.json", timeout: 20)
  ok && !body.empty? ? JSON.parse(body).first&.fetch("id", nil) : nil
rescue StandardError
  nil
end

def cc_urls(scope, index_id)
  body, ok = curl("#{CDX_HOST}/#{index_id}-index?url=#{scope}/*&output=json&fl=url&limit=#{CC_CAP}", timeout: 90)
  set = Set.new
  return set unless ok

  body.each_line do |line|
    line = line.strip
    next if line.empty?

    begin
      n = norm(JSON.parse(line)["url"])
      set << n if n
    rescue StandardError
      next
    end
  end
  set
end

# Enumerate live pages by following same-host links from the docs entry point.
def crawl(start_url)
  host_key = norm(start_url).split("/").first
  seen = Set.new
  queue = [start_url]
  pages = Set.new
  until queue.empty? || pages.size >= CRAWL_CAP
    url = queue.shift
    key = norm(url)
    next if key.nil? || seen.include?(key)

    seen << key
    html, ok = curl(url, timeout: 20)
    next unless ok

    pages << key
    html.scan(/href=["']([^"'#]+)["']/).flatten.each do |href|
      next if href.start_with?("mailto:", "javascript:", "tel:", "data:")

      full = begin
        URI.join(url, href).to_s
      rescue StandardError
        next
      end
      nk = norm(full)
      next unless nk && nk.split("/").first == host_key
      next if SKIP_EXT.any? { |e| nk.end_with?(e) }

      queue << full unless seen.include?(nk)
    end
  end
  pages
end

rows = JSON.parse(File.read(File.join(ROOT, "data", "scorecard.json")))["rows"]
index_id = latest_index
warn index_id ? "CC index up: #{index_id}" : "CC index unreachable - 'in CC' will be empty"

out = {}
TARGETS.each do |name|
  row = rows.find { |r| r["name"] == name }
  unless row
    warn "skip: no resource named #{name.inspect}"
    next
  end

  docs = row["docs"]
  scope = cc_scope(docs)
  warn "#{name}: crawling #{docs} ..."
  reference = crawl(docs)
  warn "#{name}: querying Common Crawl (#{scope}) ..."
  cc = index_id ? cc_urls(scope, index_id) : Set.new

  found = (reference & cc).sort
  not_crawled = (reference - cc).sort
  cc_only = (cc - reference).sort
  out[name] = {
    "docs" => docs, "scope" => scope, "index" => index_id,
    "pages_crawled" => reference.size, "pages_in_cc" => cc.size,
    "found_count" => found.size, "not_crawled_count" => not_crawled.size,
    "found" => found, "not_crawled" => not_crawled, "cc_only" => cc_only
  }
  warn "#{name}: live=#{reference.size} cc=#{cc.size} found=#{found.size} missing=#{not_crawled.size}"
  sleep CDX_SLEEP if index_id
end

if PRINT_ONLY
  puts JSON.pretty_generate(out)
else
  path = File.join(ROOT, "data", "coverage_details.json")
  File.write(path, JSON.pretty_generate(out))
  warn "wrote #{path}"
end
