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

# Per-resource diagnosis + fixes, appended to each report (see the scorecard investigation).
NOTES = {
  "Inertia Rails" => <<~MD,
    ## Why the gap, and what to do

    **Cause: recently-added pages + no sitemap.** Every "found" URL is still live, so nothing is stale,
    the missing pages are simply newer than Common Crawl's last pass. The found pages have been stable
    since 2024 (e.g. `guide/authentication`, last changed 2024-10-30), while the missing ones come from
    the recent docs expansion (`guide/routing` 2025-11, `guide/optimistic-updates` 2026-03,
    `guide/forms` 2026-04). With no `sitemap.xml`, CC has no manifest of the new pages and its crawl
    frontier predates them. The site also sits behind Cloudflare (content-signals `robots.txt`), which
    can throttle CCBot.

    **TODO**
    - [ ] Publish a `sitemap.xml` (VitePress: set `sitemap: { hostname }`) so CC/search see every current page.
    - [ ] Confirm Cloudflare isn't challenging `CCBot`/`GPTBot`/`ClaudeBot` (bot-fight / AI-bot blocking off for docs).
    - [ ] Add internal links + a few external backlinks to the newer guide/cookbook pages to raise crawl priority.
    - [ ] Re-check coverage after the next monthly Common Crawl.
  MD
  "AnyCable" => <<~MD
    ## Why the gap, and what to do

    **Cause: a docs URL restructure with no redirects.** Many pages moved from flat paths into
    `/anycable-go/*` (and other reshuffles) **without 301s**. The old URLs Common Crawl indexed now
    return **404** (e.g. `/signed_streams`, `/rpc`, `/sse`, `/apollo`, `/broadcasting`), while the new
    URLs (`/anycable-go/signed_streams`, …) are live but **absent from CC**. So CC's coverage is partly
    dead links and the current layout is undiscovered. No `sitemap.xml` compounds it.

    **TODO**
    - [ ] Add **301 redirects** from the old flat paths to the new `/anycable-go/*` URLs (revives the links CC/Google/LLMs already know).
    - [ ] Publish a `sitemap.xml` (VitePress: set `sitemap: { hostname }`) listing the current pages.
    - [ ] Keep the `llms-full.txt` (already linked) in sync with the new structure.
    - [ ] Re-check coverage after the next monthly Common Crawl.
  MD
}.freeze

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
    #{NOTES[name]}
  MD
  path = File.join(out_dir, "#{slug(name)}.md")
  File.write(path, md)
  warn "wrote #{path} (#{found.size} in CC, #{missing.size} missing)"
end
