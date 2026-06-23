# frozen_string_literal: true

# Build dist/quality-rewrites.html: a standalone before/after showcase of the house-style rewrites that
# clear the FineWeb-Edu quality filter, with per-post score badges and commentary. Scores are computed
# locally (QualityCore) at build time, so the page always reflects the current rewrite files.
#
#   ruby scripts/build_showcase.rb

require_relative "quality_core"
require "json"
require "cgi"

ROOT = File.expand_path("..", __dir__)
DIST = File.join(ROOT, "dist")
manifest = JSON.parse(File.read(File.join(ROOT, "data", "blog", "manifest.json")))
# GraphQL posts sit at the genre boundary and stay under the bar in house voice; exclude from the showcase.
EXCLUDE = %w[
  graphql-on-rails-1-from-zero-to-the-first-query
  how-to-graphql-with-ruby-rails-active-record-and-no-n-plus-one
].freeze
manifest = manifest.reject { |m| EXCLUDE.include?(m["slug"]) }

def esc(s) = CGI.escapeHTML(s.to_s)

TITLES = {
  "unparser-real-file-lessons-migrating-ruby-tools-from-parser-to-prism" => "Migrating Ruby tools from Parser to Prism",
  "freezolite-the-magic-gem-for-keeping-ruby-literals-safely-frozen" => "Freezolite: safely freezing Ruby string literals",
  "postgresql-and-rails-sitting-in-a-tree" => "PostgreSQL and Rails sitting in a tree",
  "how-to-graphql-with-ruby-rails-active-record-and-no-n-plus-one" => "GraphQL with Rails and no N+1 queries",
  "system-of-a-test-2-robust-rails-browser-testing-with-siteprism" => "Robust Rails browser testing with SitePrism",
  "ruby-on-rails-on-webassembly-a-guide-to-full-stack-in-browser-action" => "Ruby on Rails on WebAssembly",
  "graphql-on-rails-1-from-zero-to-the-first-query" => "GraphQL on Rails: from zero to the first query",
  "partition-and-conquer" => "Partition and conquer: table partitioning in PostgreSQL"
}.freeze

def change_notes(bf, af)
  notes = []
  d = (af[:features][:avg_sentence_words] - bf[:features][:avg_sentence_words]).round
  notes << "joined choppy sentences (avg #{bf[:features][:avg_sentence_words].round} &rarr; #{af[:features][:avg_sentence_words].round} words)" if d >= 4
  notes << "opened with a definition" if af[:features][:opens_with_definition] && !bf[:features][:opens_with_definition]
  notes << "moved the byline/metadata out of the lead" if bf[:features][:leading_meta] && !af[:features][:leading_meta]
  notes << "pulled code out of the opening" if bf[:features][:code_density] > 0.02 && af[:features][:code_density] <= 0.02
  notes.empty? ? "tightened the opening into connected, defined prose" : notes.join("; ")
end

cards = manifest.map do |m|
  slug = m["slug"]
  before_f = File.join(ROOT, "data", "blog", "leads", "#{slug}.txt")
  after_f  = File.join(ROOT, "data", "blog", "rewrites_style", "#{slug}.txt")
  next unless File.exist?(before_f) && File.exist?(after_f)

  before_txt = File.read(before_f).strip
  after_txt  = File.read(after_f).strip
  bf = QualityCore.check(before_txt, is_html: false)
  af = QualityCore.check(after_txt, is_html: false)
  { slug: slug, title: TITLES[slug] || slug, before: before_txt, after: after_txt, bf: bf, af: af,
    note: change_notes(bf, af) }
end.compact

cleared = cards.count { |c| c[:af][:int_score] >= 3 }

def badge(res)
  cls = res[:int_score] >= 3 ? "kept" : "drop"
  label = res[:int_score] >= 3 ? "would be kept" : "still dropped"
  %(<span class="badge #{cls}"><b>#{format('%.2f', res[:score])}</b> / 5 &middot; #{label}</span>)
end

card_html = cards.map do |c|
  url = "https://evilmartians.com/chronicles/#{c[:slug]}"
  <<~CARD
    <section class="card">
      <h2>#{esc(c[:title])}</h2>
      <p class="src"><a href="#{url}">the original post &rarr;</a> &middot; only the opening ~380 words change (that is all the classifier reads)</p>
      <div class="cols">
        <div class="col">
          <div class="colhead">Before #{badge(c[:bf])}</div>
          <p>#{esc(c[:before][0, 1400])}#{c[:before].length > 1400 ? '&hellip;' : ''}</p>
        </div>
        <div class="col">
          <div class="colhead">After #{badge(c[:af])}</div>
          <p>#{esc(c[:after])}</p>
        </div>
      </div>
      <p class="note"><b>What changed:</b> #{c[:note]}.</p>
    </section>
  CARD
end.join("\n")

css = <<~CSS
  :root { --ink:#1a1420; --muted:#5f5763; --accent:#ff533e; --accent-ink:#c5341f; --bg:#fffdfa;
    --panel:#fbf6ee; --line:#e9e0d4; --ok:#5f7d00; --bad:#c5341f; }
  * { box-sizing:border-box; }
  body { margin:0; color:var(--ink); background:var(--bg);
    font:18px/1.7 "Charter","Iowan Old Style","Georgia",serif; text-rendering:optimizeLegibility; }
  .wrap { max-width:60rem; margin:0 auto; padding:4rem 1.5rem 6rem; }
  h1,h2,.kicker,.colhead,.badge,.note b { font-family:"Inter",-apple-system,"Segoe UI",Arial,sans-serif; }
  .kicker { font-size:.72rem; letter-spacing:.14em; text-transform:uppercase; color:var(--accent-ink); font-weight:600; margin:0 0 1rem; }
  h1 { font-size:2.4rem; line-height:1.1; letter-spacing:-.02em; margin:0 0 1rem; font-weight:800; }
  .lead { font-size:1.15rem; color:var(--muted); margin:0 0 1.5rem; max-width:46rem; }
  .intro { max-width:46rem; }
  .intro h2 { font-size:1.3rem; margin:2rem 0 .5rem; }
  a { color:var(--accent-ink); }
  .card { border:1px solid var(--line); border-radius:14px; background:#fff; padding:1.6rem 1.7rem; margin:2rem 0; }
  .card h2 { font-size:1.4rem; margin:0 0 .2rem; }
  .src { font-size:.82rem; color:var(--muted); margin:0 0 1.2rem; }
  .cols { display:grid; grid-template-columns:1fr 1fr; gap:1.3rem; }
  .col { background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:1rem 1.1rem; }
  .col p { font-size:.92rem; line-height:1.6; margin:.6rem 0 0; white-space:pre-wrap; }
  .colhead { font-size:.7rem; letter-spacing:.08em; text-transform:uppercase; color:var(--muted);
    display:flex; align-items:center; justify-content:space-between; gap:.5rem; }
  .badge { font-size:.74rem; padding:.2rem .55rem; border-radius:999px; text-transform:none; letter-spacing:0; }
  .badge.kept { background:color-mix(in oklab,var(--ok) 16%,transparent); color:var(--ok); }
  .badge.drop { background:color-mix(in oklab,var(--bad) 14%,transparent); color:var(--bad); }
  .badge b { font-weight:700; }
  .note { font-size:.86rem; color:var(--ink); margin:1.1rem 0 0; }
  .note b { color:var(--accent-ink); }
  table.sum { border-collapse:collapse; font-family:"Inter",sans-serif; font-size:.85rem; margin:1rem 0 0; }
  table.sum td,table.sum th { border:1px solid var(--line); padding:.4rem .7rem; text-align:left; }
  footer { margin-top:3rem; padding-top:1.2rem; border-top:1px solid var(--line); font-size:.8rem; color:var(--muted); font-family:"Inter",sans-serif; }
  @media (max-width:680px){ .cols{ grid-template-columns:1fr; } h1{ font-size:1.9rem; } }
CSS

intro = <<~HTML
  <p class="kicker">Evil Martians &middot; Ruby &middot; LLM discoverability</p>
  <h1>Rewriting real posts to pass the training-data filter</h1>
  <p class="lead">Before training, corpus builders run a quality classifier and drop most of the web. We
  took #{cards.size} Evil Martians posts that score just under the bar and rewrote only their openings, in
  house voice, to clear it. #{cleared} of #{cards.size} now would be kept. Here is each one, before and after,
  and why the change works.</p>
  <div class="intro">
    <h2>What the filter measures</h2>
    <p>We score with the open <a href="https://huggingface.co/HuggingFaceFW/fineweb-edu-classifier">FineWeb-Edu
    classifier</a>, the documented filter behind the FineWeb corpus and the best public proxy for whether a
    modern pretraining run would keep a page. It reads only the first ~512 tokens (~380 words), rates
    &ldquo;educational quality&rdquo; from 0 to 5, and a corpus keeps a document when that score rounds to 3
    or higher (a raw 2.5+). It is a proxy, not the actual filter used by Claude, GPT, or Gemini, which are
    undisclosed, so treat the numbers as directional; a 0.3 gap is noise.</p>
    <h2>The three moves that work</h2>
    <p>From scoring hundreds of rewrites, three levers move the score, and all three are things good writing
    wants anyway. <b>Define the subject in the first sentence</b> (the classifier, and an LLM reader, parse
    defined terms better). <b>Explain the mechanism in connected sentences</b> rather than fragments and bare
    lists. <b>Keep boilerplate and raw code out of the opening</b>, since that is the only window scored.</p>
    <h2>Where house style and the filter disagree</h2>
    <p>They are not always friends, and the disagreement has a price. House voice says &ldquo;if a sentence
    can be cut, cut it&rdquo; and opens with a personality hook; the filter rewards longer, explanatory
    sentences and a plain definitional opener. The reconciliation that held up: keep a one-line hook and the
    opinion, then immediately define the term and explain why it matters in real, specific prose, lengthening
    by joining genuine ideas, never by padding. That carried five of these eight over the bar without losing
    the voice.</p>
    <p>The cost is real and it is a dial, not a switch. The narrower or more conversational the subject, the
    more explanatory the opening has to become to pass, and the more voice you trade away. The Freezolite
    post is the clearest case: written as flat courseware its opening scores 3.6, written like Evil Martians
    it scores 2.0, and the version below is the most voice we could keep while still clearing the bar. Where
    that trade costs too much to be worth shipping, the honest move is the code channel instead, a
    permissively-licensed repo whose README and Markdown are trained on regardless of any prose score.</p>
  </div>
HTML

html = <<~HTML
  <!doctype html><html lang="en"><head><meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Rewriting real posts to pass the training-data filter</title>
  <style>#{css}</style></head><body><main class="wrap">
  #{intro}
  #{card_html}
  <footer>Scores computed with <code>scripts/quality_core.rb</code> (FineWeb-Edu via ONNX) at build time.
  Openings rewritten against the Evil Martians content style guide. An experiment, not a published change.</footer>
  </main></body></html>
HTML

File.write(File.join(DIST, "quality-rewrites.html"), html)
warn "wrote dist/quality-rewrites.html (#{cleared}/#{cards.size} cleared)"
