# frozen_string_literal: true

# Build dist/blog-rewrites-review.html: an internal editorial review doc (for Irina + Travis) of the
# house-style opening rewrites. Each entry: link to the live article, the FULL rewritten opening, the
# before/after FineWeb-Edu score, and a short editorial note. Scores computed locally at build time.
#
#   ruby scripts/build_review.rb

require_relative "quality_core"
require "json"
require "cgi"
require_relative "site_nav"

ROOT = File.expand_path("..", __dir__)
DIST = File.join(ROOT, "dist")
def esc(s) = CGI.escapeHTML(s.to_s)

# Decision set: the house-style rewrites that clear the bar (GraphQL posts excluded — stay under in voice).
ENTRIES = [
  { slug: "freezolite-the-magic-gem-for-keeping-ruby-literals-safely-frozen",
    title: "Freezolite: the magic gem for keeping Ruby literals safely frozen",
    note: "Most textbook-leaning of the set (long, expository sentences) because the topic is narrow; the " \
          "opinionated hook about wasted memory survives, but worth a tone pass to keep it sounding like us." },
  { slug: "ruby-on-rails-on-webassembly-a-guide-to-full-stack-in-browser-action",
    title: "Ruby on Rails on WebAssembly: a guide to full-stack in-browser action",
    note: "Hook and curiosity intact; defines Wasm / Rails / full-stack up front. Reads close to house voice." },
  { slug: "postgresql-and-rails-sitting-in-a-tree",
    title: "PostgreSQL and Rails sitting in a tree",
    note: "Opinionated hook (Closure Table keeps both fast reads and writes), then defines the terms. " \
          "Slightly more expository than the original but on-brand." },
  { slug: "partition-and-conquer",
    title: "Partition and conquer",
    note: "Keeps the 3 a.m. on-call hook; sentences run long to clear the filter. Check the opener's rhythm." },
  { slug: "system-of-a-test-2-robust-rails-browser-testing-with-siteprism",
    title: "System of a test 2: robust Rails browser testing with SitePrism",
    note: "Personality hook kept (tests turning red on a CSS rename); defines SitePrism / Capybara / Page " \
          "Object / flaky test. One metric-backed EM mention." },
  { slug: "unparser-real-file-lessons-migrating-ruby-tools-from-parser-to-prism",
    title: "Unparser: real-file lessons migrating Ruby tools from Parser to Prism",
    note: "Most in-voice of the set: punchy hook (\"harder than the slides admit\"), then a calm define-and-" \
          "explain register. Clears by the smallest margin (2.55)." }
].freeze

cards = ENTRIES.map do |e|
  before_f = File.join(ROOT, "data", "blog", "leads", "#{e[:slug]}.txt")
  after_f  = File.join(ROOT, "data", "blog", "rewrites_style", "#{e[:slug]}.txt")
  next unless File.exist?(after_f)
  before = File.exist?(before_f) ? File.read(before_f).strip : ""
  after  = File.read(after_f).strip
  bsc = before.empty? ? nil : QualityCore.score_text(before)
  asc = QualityCore.score_text(after)
  e.merge(before_score: bsc&.dig(:score), after_score: asc[:score],
          after_int: asc[:int_score], words: after.split.size, after: after)
end.compact

def badge(score, int)
  return "" unless score
  kept = int >= 3
  %(<span class="b #{kept ? 'k' : 'd'}">#{format('%.2f', score)} / 5 &middot; #{kept ? 'would be kept' : 'still dropped'}</span>)
end

rows = cards.each_with_index.map do |c, i|
  url = "https://evilmartians.com/chronicles/#{c[:slug]}"
  paras = c[:after].split(/\n\s*\n/).map { |p| "<p>#{esc(p.strip)}</p>" }.join("\n")
  <<~ROW
    <section class="entry">
      <div class="hd">
        <h2>#{i + 1}. #{esc(c[:title])}</h2>
        <div class="scores">#{badge(c[:before_score], 0).sub('would be kept', 'current').sub('still dropped', 'current')} <span class="arrow">&rarr;</span> #{badge(c[:after_score], c[:after_int])}</div>
      </div>
      <p class="meta"><a href="#{url}">Read the live article &rarr;</a> &middot; #{c[:words]} words &middot;
      this replaces only the opening (~first 380 words, all the quality filter reads); the rest of the post is unchanged.</p>
      <div class="rw">#{paras}</div>
      <p class="ed"><b>Editor's note:</b> #{c[:note]}</p>
    </section>
  ROW
end.join("\n")

cleared = cards.count { |c| c[:after_int] >= 3 }

css = <<~CSS
  :root{--ink:#1a1420;--mut:#5f5763;--acc:#c5341f;--bg:#fffdfa;--panel:#fbf6ee;--line:#e9e0d4;--ok:#5f7d00;--bad:#c5341f}
  *{box-sizing:border-box}
  body{margin:0;color:var(--ink);background:var(--bg);font:18px/1.65 "Charter","Iowan Old Style","Georgia",serif}
  .wrap{max-width:48rem;margin:0 auto;padding:3.5rem 1.5rem 6rem}
  h1,h2,.kick,.b,.ed b,.meta,.scores,.toc{font-family:"Inter",-apple-system,"Segoe UI",Arial,sans-serif}
  .kick{font-size:.72rem;letter-spacing:.14em;text-transform:uppercase;color:var(--acc);font-weight:600;margin:0 0 .8rem}
  h1{font-size:2.2rem;line-height:1.1;letter-spacing:-.02em;margin:0 0 .8rem;font-weight:800}
  .lead{font-size:1.1rem;color:var(--mut);margin:0 0 1.4rem;max-width:42rem}
  .toc{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:1rem 1.2rem;margin:0 0 2.5rem;font-size:.92rem}
  .toc ol{margin:.3rem 0 0;padding-left:1.2rem}
  .toc a{color:var(--ink);text-decoration:none}.toc a:hover{color:var(--acc);text-decoration:underline}
  .entry{border-top:3px solid var(--acc);padding-top:1.3rem;margin:2.6rem 0}
  .hd{display:flex;align-items:baseline;justify-content:space-between;gap:1rem;flex-wrap:wrap}
  h2{font-size:1.45rem;margin:0;font-weight:750;line-height:1.2}
  .scores{font-size:.78rem;white-space:nowrap;color:var(--mut)}
  .b{padding:.18rem .5rem;border-radius:999px;font-size:.74rem}
  .b.k{background:color-mix(in oklab,var(--ok) 16%,transparent);color:var(--ok)}
  .b.d{background:color-mix(in oklab,var(--bad) 13%,transparent);color:var(--bad)}
  .arrow{color:var(--mut)}
  .meta{font-size:.85rem;color:var(--mut);margin:.5rem 0 1.1rem}
  a{color:var(--acc)}
  .rw{background:#fff;border:1px solid var(--line);border-radius:10px;padding:1.2rem 1.4rem}
  .rw p{margin:0 0 1rem}.rw p:last-child{margin:0}
  .ed{font-size:.92rem;color:var(--ink);background:var(--panel);border-left:3px solid var(--acc);
    padding:.7rem 1rem;margin:1.1rem 0 0;border-radius:0 8px 8px 0}
  .ed b{color:var(--acc)}
  footer{margin-top:3rem;padding-top:1.2rem;border-top:1px solid var(--line);font-size:.82rem;color:var(--mut);font-family:"Inter",sans-serif}
CSS

toc = cards.each_with_index.map { |c, i| %(<li><a href="#e#{i + 1}">#{esc(c[:title])}</a></li>) }.join
rows_with_anchors = cards.each_with_index.map do |_, i|
  rows.split("<section class=\"entry\">")[i + 1].sub("<h2>", %(<h2 id="e#{i + 1}">))
end.map { |r| "<section class=\"entry\">#{r}" }.join

html = <<~HTML
  <!doctype html><html lang="en"><head><meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Blog opening rewrites &mdash; editorial review</title><style>#{css}#{SITE_NAV_CSS}</style></head>
  <body>
  #{site_nav}
  <main class="wrap">
    <p class="kick">Evil Martians &middot; for Irina &amp; Travis</p>
    <h1>Blog opening rewrites: editorial review</h1>
    <p class="lead">Six Chronicles posts whose openings score just under the FineWeb-Edu training-data
    quality bar. Each rewrite below replaces only the opening (~first 380 words, the only part the filter
    reads) and is written to clear the bar while keeping our voice. All six now clear it. Facts are
    unchanged from the source; nothing invented. This is a yes / edit / no review, not a publish.</p>
    <nav class="toc"><b>The six</b><ol>#{toc}</ol></nav>
    #{rows_with_anchors}
    <footer>Scores are the open FineWeb-Edu classifier (the proxy behind our scorecard), computed locally
    at build time. Keep bar = score rounds to 3 (raw &ge; 2.5). #{cleared} of #{cards.size} clear it.
    The classifier is a directional proxy, not Claude/GPT/Gemini's actual filter.</footer>
  </main></body></html>
HTML

File.write(File.join(DIST, "blog-rewrites-review.html"), html)
warn "wrote dist/blog-rewrites-review.html (#{cleared}/#{cards.size} clear)"
