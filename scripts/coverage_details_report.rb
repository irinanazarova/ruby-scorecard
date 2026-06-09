#!/usr/bin/env ruby
# frozen_string_literal: true

# Renders data/coverage_details.json into a shareable Markdown report per resource:
# data/coverage_details/<slug>.md  (pages in Common Crawl vs pages not yet in CC).

require "json"

ROOT = File.expand_path("..", __dir__)
src = File.join(ROOT, "data", "coverage_details.json")
abort "no #{src} (run fetch/details-on-fly.sh first)" unless File.exist?(src)

details = JSON.parse(File.read(src))
out_dir = File.join(ROOT, "data", "coverage_details")
Dir.mkdir(out_dir) unless Dir.exist?(out_dir)

JUNK = %r{/cdn-cgi/|email-protection|/feed\b|\.rss\b}

def slug(name) = name.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
def li(urls) = urls.map { |u| "- https://#{u}" }.join("\n")

details.each do |name, d|
  found = (d["found"] || []).reject { |u| u =~ JUNK }
  missing = (d["not_crawled"] || []).reject { |u| u =~ JUNK }
  total = found.size + missing.size
  pct = total.positive? ? (100.0 * found.size / total).round : 0
  md = <<~MD
    # #{name} — Common Crawl coverage

    Docs: #{d["docs"]} · scope `#{d["scope"]}` · Common Crawl index `#{d["index"]}`

    Of **#{total}** documentation pages found by crawling the live site, **#{found.size}**
    are present in Common Crawl (**#{pct}%**) and **#{missing.size}** are not.
    (#{d["cc_only"]&.size || 0} URLs are in Common Crawl but were not reached by the crawl,
    e.g. redirects, old paths, or orphan pages.)

    ## In Common Crawl (#{found.size})
    #{found.empty? ? "_none_" : li(found)}

    ## NOT in Common Crawl (#{missing.size})
    #{missing.empty? ? "_none_" : li(missing)}
  MD
  path = File.join(out_dir, "#{slug(name)}.md")
  File.write(path, md)
  warn "wrote #{path} (#{found.size} in CC, #{missing.size} missing)"
end
