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

# Optional: per-page FineWeb-Edu quality scores (fetch/quality-on-fly.sh --details "<target>").
qd_path = File.join(ROOT, "data", "quality_details.json")
QUALITY = File.exist?(qd_path) ? JSON.parse(File.read(qd_path)) : nil

def quality_section(name, qd)
  return "" unless qd && qd["target"] == name
  f = qd.dig("buckets", "found") or return ""
  m = qd.dig("buckets", "not_crawled") or return ""
  pages = (f["pages"] || []) + (m["pages"] || [])
  keepers = pages.select { |p| p["edu"] && p["edu"] >= 3 }.sort_by { |p| -p["edu"] }
  near = pages.select { |p| p["edu"] && p["edu"] >= 2 && p["edu"] < 3 }.sort_by { |p| -p["edu"] }
  keep_line =
    if keepers.empty?
      "No page on the site clears the bar."
    else
      list = keepers.map { |p| "[`#{p["url"].sub(%r{^https?://[^/]+}, "")}`](#{p["url"]}) (#{p["edu"]}#{p["c4_curly"] ? ", but contains a `{` that C4 drops" : ""})" }.join("; ")
      "The only page that clears it is #{list}, a self-contained how-to with worked examples, " \
      "exactly the explanatory prose the classifier rewards. The next closest are explainer/tutorial " \
      "posts in the 2.4&ndash;2.7 band (#{near.first(3).map { |p| "`#{p["url"].sub(%r{^https?://[^/]+}, "").split("/").last}` #{p["edu"]}" }.join(", ")}), still short of 3."
    end
  <<~MD

    ## Second gate: would these pages survive the quality filter?

    Being in Common Crawl is the first gate; corpus builders then run a quality classifier before
    training. Scoring every page in both buckets with the open
    [FineWeb-Edu classifier](https://huggingface.co/HuggingFaceFW/fineweb-edu-classifier) (0&ndash;5
    educational quality; FineWeb-Edu keeps documents scoring &ge; 3):

    | bucket | scored | avg | median | kept (&ge; 3) |
    | --- | ---: | ---: | ---: | ---: |
    | in Common Crawl | #{f["n_scored"]} | #{f["avg"]} | #{f["median"]} | #{f["keep_ge3"]} |
    | not in Common Crawl | #{m["n_scored"]} | #{m["avg"]} | #{m["median"]} | #{m["keep_ge3"]} |

    The crawled and the missing pages score the same (avg #{f["avg"]} vs #{m["avg"]}), so the gap is
    about crawl reach, not page quality: CC did not skip these pages for being low quality. Separately,
    across all #{f["n_scored"] + m["n_scored"]} pages only #{f["keep_ge3"] + m["keep_ge3"]} clears the
    &ge; 3 bar, so even the pages already in Common Crawl would be dropped at the quality gate. The
    classifier rewards educational prose and penalizes marketing copy, dense reference, and code, which
    is most of a consultancy site.

    #{keep_line}
  MD
end

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
  "AnyCable" => <<~MD,
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
  "evilmartians.com" => <<~MD
    ## Why the gap (and why it's different here)

    **Not blocked, not unlisted.** robots.txt allows AI crawlers (`Content-Signal: ai-train=yes`), and
    **367 of the missing pages are in the sitemap** (`/sitemap/sitemap-index.xml`, ~1,009 URLs total).
    llms.txt is present but irrelevant to Common Crawl: it's a runtime hint for agents, not a crawler
    directive, so it never affects what CC ingests.

    **Cause: Common Crawl's own crawl budget and URL selection.** CC samples a domain by link centrality
    and a per-site budget rather than fetching every sitemap URL, so roughly half of evilmartians.com, the
    deeper / newer / less-linked Chronicles articles, doesn't make the cut.

    **TODO** (the on-site basics are already correct, so these raise crawl priority rather than fix a blocker)
    - [ ] Strengthen internal linking to deeper Chronicles posts (link from high-traffic pages, cut click depth).
    - [ ] Earn external backlinks to raise domain authority and crawl budget.
    - [ ] Time: CC accumulates over monthly crawls; newer posts enter on later passes, re-check then.
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
    #{NOTES[name]}#{quality_section(name, QUALITY)}
  MD
  path = File.join(out_dir, "#{slug(name)}.md")
  File.write(path, md)
  warn "wrote #{path} (#{found.size} in CC, #{missing.size} missing)"
end
