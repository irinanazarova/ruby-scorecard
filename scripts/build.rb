#!/usr/bin/env ruby
# frozen_string_literal: true

# Renders data/scorecard.json -> dist/scorecard.html in the Evil Martians design system.
# The full table and all prose are server-rendered here; the nanotags components in
# dist/assets/app.js only enhance this markup (theme, filter, sort, counters), so the
# page is complete and crawlable with JavaScript disabled.

require "json"
require "cgi"
require "uri"
require "digest"

ROOT = File.expand_path("..", __dir__)
rows = JSON.parse(File.read(File.join(ROOT, "data", "scorecard.json")))["rows"]
cov_path = File.join(ROOT, "data", "coverage.json")
coverage = File.exist?(cov_path) ? JSON.parse(File.read(cov_path)) : {}
cg_path = File.join(ROOT, "data", "content_gap.json")
content_gap = File.exist?(cg_path) ? JSON.parse(File.read(cg_path)) : nil

OK  = '<span class="ok" title="yes">&#10003;</span>'
BAD = '<span class="bad" title="no">&#10007;</span>'

def esc(str) = CGI.escapeHTML(str.to_s)

# Cache-busting query from the built asset's content hash, so a deploy never serves stale CSS/JS.
def asset_q(rel)
  path = File.join(ROOT, "dist", rel)
  File.exist?(path) ? "?v=#{Digest::MD5.file(path).hexdigest[0, 8]}" : ""
end
def mark(val) = val ? OK : BAD
def slug(cat) = cat.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")

def cell_robots(row)
  return OK if row["robots_ai"] == "allow"

  BAD + %(<span class="sub">#{esc(row["robots_note"])}</span>)
end

def cell_bot(row)
  case row["bot_fetch"]
  when "ok"    then OK
  when "block" then BAD + %(<span class="sub">WAF block</span>)
  else %(<span class="warn">#{esc(row["bot_code"])}</span>)
  end
end

# ---- Common Crawl coverage helpers ----
def commate(num) = num.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse

# sort the column by absolute pages-in-CC (works for all 54; not-sampled sinks to the bottom)
def cov_sortkey(c) = c && c["cc_pages"] ? c["cc_pages"] : -1

def cov_cell(c, scoped: false)
  return %(<span class="cc-na" title="not sampled">&mdash;</span>) unless c && c["cc_pages"]

  cc = c["cc_pages"]
  total = c["total_pages"]
  approx = c["cc_exact"] == false ? "~" : ""
  # Pair with the sitemap only when both cover the same scope and the sitemap bounds the count.
  # Scope-overridden entries count just the Ruby/Rails section, so the whole-host sitemap is not a
  # comparable denominator; show the bare count there (and where the sitemap is partial, cc > total).
  if !scoped && total&.positive? && cc <= total
    pct = 100.0 * cc / total
    tip = "#{pct < 1 ? "<1" : pct.round}% of sitemap pages found in Common Crawl"
    %(<span class="cc-val" title="#{tip}">#{approx}#{commate(cc)}<span class="cc-den">/#{commate(total)}</span></span>)
  else
    tip = scoped ? "#{commate(cc)} pages of the Ruby/Rails docs in Common Crawl" \
                 : (total ? "#{commate(cc)} in Common Crawl; sitemap lists only #{commate(total)} (partial)" \
                          : "#{commate(cc)} pages in Common Crawl; sitemap total n/a")
    %(<span class="cc-val" title="#{tip}">#{approx}#{commate(cc)}<span class="cc-den">/&mdash;</span></span>)
  end
end

# ---- goal graphics (progress meters + status pills) ----
# Colour by progress toward the goal: green when nearly there, amber partway, red barely started.
def meter(label, value, total, tone: nil)
  pct = total.positive? ? (100.0 * value / total).round : 0
  tone ||= pct >= 75 ? "good" : pct >= 30 ? "warn" : "bad"
  cls = " meter--#{tone}"
  %(<div class="meter#{cls}"><div class="meter__top"><span class="meter__label">#{label}</span><span class="meter__val">#{commate(value)}<span class="meter__den">/#{commate(total)}</span></span></div><div class="meter__track"><span class="meter__fill" style="width:#{pct}%"></span></div></div>)
end

def statuspill(key, state)
  %(<span class="status"><span class="status__k">#{key}</span><span class="status__v">#{state}</span></span>)
end

# Content-gap matrix cell (solid = current + task-specific + numbers; generic = framework-level only; missing = none).
# A found source (any cell with a url) gets a small superscript link, numbered via src_num.
def cg_cell(cell, src_num)
  state = cell["state"]
  tip = { "solid" => "current, task-specific, with real numbers",
          "generic" => "only framework-level pros/cons or boilerplate roundups",
          "missing" => "no credible comparison found" }[state]
  url = cell["url"]
  sup = url ? %(<sup class="cg-ref"><a href="#{esc(url)}" title="#{esc(url)}">#{src_num[url]}</a></sup>) : ""
  %(<td class="cg-#{state}"><span title="#{tip}">#{state}</span>#{sup}</td>)
end

CAT_ORDER = ["core", "frontend & view", "web frameworks", "data", "ai",
             "background, realtime & deploy", "tooling & types", "libraries",
             "community & resources"].freeze
CAT_LABEL = CAT_ORDER.to_h { |c| [c, c.split.map(&:capitalize).join(" ")] }
CAT_LABEL["core"] = "Core (Ruby Central / Rails Foundation / community-run)"
CAT_LABEL["data"] = "Data & ORM"
CAT_LABEL["ai"]   = "AI"
CHIP_LABEL = {
  "core" => "Core", "frontend & view" => "Frontend", "web frameworks" => "Frameworks",
  "data" => "Data & ORM", "ai" => "AI", "background, realtime & deploy" => "Background",
  "tooling & types" => "Tooling", "libraries" => "Libraries", "community & resources" => "Community"
}.freeze

# ---- aggregate stats ----
n           = rows.size
llms        = rows.count { |r| r["llms_txt"] }
neg         = rows.count { |r| r["content_neg"] }
md          = rows.count { |r| r["md_route"] }
sm          = rows.count { |r| r["sitemap"] }
blocked     = rows.select { |r| r["robots_ai"] == "block" || r["bot_fetch"] == "block" }.map { |r| r["name"] }

# ---- table rows ----
present_cats = CAT_ORDER.select { |c| rows.any? { |r| r["category"] == c } }
trows = []
present_cats.each do |cat|
  trows << %(<tr class="grp" data-grp="#{slug(cat)}"><td colspan="8">#{esc(CAT_LABEL[cat])}</td></tr>)
  rows.select { |r| r["category"] == cat }.each do |r|
    c = coverage[r["name"]]
    trows << %(<tr data-cat="#{slug(cat)}" data-name="#{esc(r["name"].downcase)}" data-cc="#{cov_sortkey(c)}">) \
      "<td class=\"res\"><a href=\"#{esc(r["docs"])}\">#{esc(r["name"])}</a></td>" \
      "<td>#{cell_robots(r)}</td><td>#{cell_bot(r)}</td>" \
      "<td>#{mark(r["sitemap"])}</td><td>#{mark(r["llms_txt"])}</td>" \
      "<td>#{mark(r["content_neg"])}</td><td>#{mark(r["md_route"])}</td>" \
      "<td class=\"cc\">#{cov_cell(c, scoped: !r["cc_scope"].to_s.empty?)}</td></tr>"
  end
end
TABLE = trows.join("\n")

# ---- category filter chips ----
chips = [%(<button class="chip" data-cat="all" aria-pressed="true">All</button>)]
present_cats.each do |c|
  chips << %(<button class="chip" data-cat="#{slug(c)}" aria-pressed="false">#{esc(CHIP_LABEL[c] || c)}</button>)
end
CHIPS = chips.join("\n      ")

# ---- per-layer goal graphics (live numbers from the scorecard) ----
unblocked = n - blocked.size
GOALS_L0 = meter("Crawlable, unblocked", unblocked, n) + meter("Sitemaps", sm, n)
GOALS_L1 = meter("Content negotiation", neg, n) + meter(".md routes", md, n) + meter("llms.txt", llms, n)
GOALS_L2 = statuspill("Shared gem/agent convention", "none yet") + statuspill("Agent Skills convention", "fragmented")
GOALS_L3 = statuspill(%(Ruby in <a href="https://github.com/multi-swe-bench/multi-swe-bench">Multi-SWE-bench</a>), "absent") +
           statuspill("Open idiomatic-Rails dataset", "none yet")
BOSS_METERS = meter("Ruby picks", 0, 1267) + meter("Models that default to Ruby", 0, 13)

# ---- content-gap matrix (the "Rails vs the field" comparison content that does/doesn't exist) ----
CONTENT_GAP = if content_gap
  cells = content_gap["tasks"].flat_map { |t| [t["js"], t["py"]] }
  solid = cells.count { |c| c["state"] == "solid" }
  # number the found sources in order of appearance
  src_urls = []
  cells.each { |c| u = c["url"]; src_urls << u if u && !src_urls.include?(u) }
  src_num = src_urls.each_with_index.to_h { |u, i| [u, i + 1] }
  sources = src_urls.empty? ? "" : %(<p class="note cg-srclist">Sources: ) +
    src_urls.map { |u| host = (URI.parse(u).host&.sub(/\Awww\./, "") || u); %(<sup>#{src_num[u]}</sup>&nbsp;<a href="#{esc(u)}">#{esc(host)}</a>) }.join(" &middot; ") + "</p>"
  heads = content_gap["stacks"].map { |s| %(<th>#{esc(s["label"])} <span class="cg-sub">#{esc(s["sub"])}</span></th>) }.join
  rows = content_gap["tasks"].map do |t|
    %(<tr><th scope="row">#{esc(t["task"])} <span class="cg-detail">#{esc(t["detail"])}</span></th>#{cg_cell(t["js"], src_num)}#{cg_cell(t["py"], src_num)}</tr>)
  end.join("\n      ")
  <<CG
<h4 class="cg-title">Publish the missing comparisons</h4>
<p class="cg-metric">Why: a model reaches for what the corpus argues for, and today almost nothing argues,
with numbers, that Rails is the better build for these product shapes. <strong>#{solid} of #{cells.size}</strong>
comparisons are <em>solid</em> (current, task-specific, with real numbers); the rest are generic framework
takes or absent.</p>
<div class="table-scroll">
<table class="cg-table">
  <thead><tr><th scope="col">Build &hellip; in Rails</th>#{heads}</tr></thead>
  <tbody>
      #{rows}
  </tbody>
</table>
</div>
#{sources}
<p class="note">Snapshot #{esc(content_gap["updated"])}, by web search per task &times; stack, then judged.
<span class="cg-k cg-solid">solid</span> current + task-specific + numbers &middot;
<span class="cg-k cg-generic">generic</span> framework pros/cons or boilerplates &middot;
<span class="cg-k cg-missing">missing</span> nothing credible. It's a web search, refreshed each pass.</p>
CG
else
  ""
end

PAGE = <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ruby &amp; Rails LLM Discoverability Scorecard</title>
<meta name="description" content="A measured scorecard of how discoverable Ruby, Rails, and the wider ecosystem's documentation is to LLMs and AI coding agents, and what the community can do to move the needle.">
<script>(function(){try{var t=localStorage.getItem('rsc-theme');if(t)document.documentElement.dataset.theme=t;}catch(e){}})();</script>
<link rel="stylesheet" href="assets/styles.css#{asset_q("assets/styles.css")}">
<script type="module" src="assets/app.js#{asset_q("assets/app.js")}"></script>
</head>
<body>
<header class="hero">
  <div class="wrap">
    <div class="hero__top">
      <p class="kicker label">Evil Martians &middot; Ruby</p>
      <theme-toggle>
        <button type="button" data-ref="button" class="theme-toggle" aria-pressed="false" aria-label="Toggle colour theme">
          <span class="theme-toggle__dot"></span><span class="theme-toggle__label">Light</span>
        </button>
      </theme-toggle>
    </div>
    <h1>Ruby &amp; Rails LLM discoverability scorecard</h1>
    <p class="lede"><strong>Ruby and Rails deliver superior productivity, for humans and AI agents
    alike.</strong> Yet the models rarely choose them on their own: in the open whichlang benchmark, 13
    models picked Ruby <strong>0 times across 1,267 generated solutions</strong>. It's a discoverability
    problem. This page measures the docs of #{n} ecosystem resources and shows what the community can fix.</p>
    <div class="stats">
      <stat-counter class="stat" value="#{llms}" total="#{n}"><b class="stat__num" data-ref="num">#{llms}/#{n}</b><span>ship an llms.txt</span></stat-counter>
      <stat-counter class="stat" value="#{neg}" total="#{n}"><b class="stat__num" data-ref="num">#{neg}/#{n}</b><span>do content negotiation</span></stat-counter>
      <stat-counter class="stat" value="#{md}" total="#{n}"><b class="stat__num" data-ref="num">#{md}/#{n}</b><span>serve .md docs</span></stat-counter>
      <stat-counter class="stat" value="#{sm}" total="#{n}"><b class="stat__num" data-ref="num">#{sm}/#{n}</b><span>have a sitemap</span></stat-counter>
      <stat-counter class="stat" value="#{blocked.size}" total="0"><b class="stat__num" data-ref="num">#{blocked.size}</b><span>block AI crawlers</span></stat-counter>
    </div>
  </div>
</header>

<main class="wrap">

<section>
<h2><span class="num">01</span>The scorecard</h2>
<p class="note">Measured over HTTP, June 2026, against each project's <strong>documentation page</strong>
(e.g. <code>sorbet.org/docs</code>, <code>docs.avohq.io</code>). Each column is a checkable signal of LLM
discoverability: <span class="ok">&#10003;</span> good, <span class="bad">&#10007;</span> missing.
&ldquo;Crawlable&rdquo; fetches as a Common Crawl bot to catch Cloudflare/WAF blocks. The last column shows
Common Crawl coverage as <em>pages found / sitemap total</em> (<span class="cc-na">&mdash;</span> = not
sampled). Click any heading to sort.</p>

<scorecard-table>
  <div class="controls">
    <input class="controls__search" data-ref="search" type="search" placeholder="Search resources&hellip;" aria-label="Search resources">
    <div class="controls__cats">
      #{CHIPS}
    </div>
    <span class="controls__count" data-ref="count">Showing #{n} of #{n}</span>
  </div>
  <div class="table-scroll">
  <table data-ref="table">
    <thead><tr>
      <th class="res sortable" data-col="0">Resource (docs) <span class="arrow">&#9650;</span></th>
      <th class="sortable" data-col="1">robots<br>allows AI <span class="arrow">&#9650;</span></th>
      <th class="sortable" data-col="2">crawlable<br>(no WAF) <span class="arrow">&#9650;</span></th>
      <th class="sortable" data-col="3">sitemap <span class="arrow">&#9650;</span></th>
      <th class="sortable" data-col="4">llms.txt <span class="arrow">&#9650;</span></th>
      <th class="sortable" data-col="5">content<br>negotiation <span class="arrow">&#9650;</span></th>
      <th class="sortable" data-col="6">.md<br>routes <span class="arrow">&#9650;</span></th>
      <th class="sortable" data-col="7">Common<br>Crawl <span class="arrow">&#9650;</span></th>
    </tr></thead>
    <tbody>
#{TABLE}
    </tbody>
  </table>
  </div>
</scorecard-table>
</section>

<section>
<h2><span class="num">02</span>What will move the needle</h2>
<p>Four levers, ordered by depth, each acting on the same number. Rails is plural by design (omakase
defaults and swappable adapters), so the job is to strengthen the default and agree on
shared conventions. Each layer shows its <strong>goal</strong> as a live gauge; together they feed the
<strong>final boss</strong> below.</p>

<div class="layer">
  <h3><span class="lname">Layer 0: get into the corpus at all</span> <span class="tag now">ship now</span></h3>
  <div class="goals">#{GOALS_L0}</div>
  <ul>
    <li>Unblock AI crawlers (CCBot, GPTBot, ClaudeBot, Google-Extended) in robots.txt and at the WAF.
      The RubyEvents one-line fix alone unlocks ~15,775 pages of talks.</li>
    <li>Add sitemaps, server-render, link internally, earn high-authority backlinks.</li>
    <li>CC-license and transcribe conference video; Google trains Gemini on YouTube transcripts and
      CC-licensed talks flow into open corpora.</li>
  </ul>
</div>
<div class="layer">
  <h3><span class="lname">Layer 1: win retrieval and publish comparisons (content)</span> <span class="tag now">ship now</span></h3>

  <h4 class="cg-title">Win retrieval</h4>
  <p class="note">Why: an agent fetching a Rails or gem doc at request time should get current Markdown it
    can read, instead of HTML it has to scrape.</p>
  <div class="goals">#{GOALS_L1}</div>
  <ul>
    <li>Serve Markdown via content negotiation and <code>.md</code> routes
      (<code>Mime::Type.register "text/markdown", :md</code>). A real HTTP standard agents already use,
      the durable bet. Ship llms.txt too, cheaply.</li>
    <li>Make <strong>rdoc</strong> emit Markdown + content negotiation by default; the keystone that lifts
      every gem at once.</li>
  </ul>

  #{CONTENT_GAP}
</div>
<div class="layer">
  <h3><span class="lname">Layer 2: make agents fluent in the gems (tools)</span> <span class="tag now">ship now</span></h3>
  <div class="goals">#{GOALS_L2}</div>
  <ul>
    <li>Agree a convention so any gem maintainer ships agent-discoverable tooling, an MCP endpoint or a
      skill, the way they already ship a README.</li>
    <li>Converge a Rails MCP server: let agents introspect the app (gems, versions, schema, routes) and
      pull current per-gem docs on demand.</li>
    <li>Agree a shared Agent Skills convention so skill packs interoperate.</li>
    <li>Copy <a href="https://github.com/laravel/boost">Laravel Boost</a> (official MCP, version-pinned
      guidelines, on-demand skills, tools). Rails has the parts
      (<a href="https://github.com/yjacquin/fast-mcp">fast-mcp</a>,
      <a href="https://tidewave.ai/">Tidewave</a>,
      <a href="https://github.com/maquina-app/rails-mcp-server">rails-mcp-server</a>) on the official Ruby
      <a href="https://github.com/modelcontextprotocol/ruby-sdk">MCP SDK</a>.</li>
  </ul>
  <p class="note">Why: standard Rails is in the training set; the gems, and anything past the cutoff, are
    where agents guess. A maintainer convention is what scales the fix across that long tail.</p>
</div>
<div class="layer">
  <h3><span class="lname">Layer 3: change the training default</span> <span class="tag slow">long game</span></h3>
  <div class="goals">#{GOALS_L3}</div>
  <ul>
    <li>Contribute real Rails repos to
      <a href="https://github.com/multi-swe-bench/multi-swe-bench">Multi-SWE-bench</a> (the repo-level
      agentic benchmark, which takes open contributions) and publish an open idiomatic-Rails eval. Ruby is
      in <a href="https://github.com/nuprl/MultiPL-E">MultiPL-E</a>'s HumanEval/MBPP puzzles but absent from
      the agentic benchmarks, where modern coding ability is measured; adding a language to an eval
      measurably improves models on it (<a href="https://github.com/nuprl/MultiPL-T">MultiPL-T</a>,
      <a href="https://arxiv.org/abs/2410.18957">Bridge-Coder</a>).</li>
    <li>Publish an open, idiomatic-Rails instruction dataset; contribute permissively-licensed Ruby
      content to open corpora like <a href="https://huggingface.co/datasets/PleIAs/common_corpus">Common
      Corpus</a>.</li>
    <li>Keep the public <a href="https://github.com/chad/whichlang">whichlang benchmark</a> as the
      scoreboard for the final boss below, and re-run it on each new model.</li>
  </ul>
</div>

<div class="panel target boss">
  <p class="label">&#9733; The final boss</p>
  <p><strong>Frontier models reach for Ruby on their own.</strong> The single metric every layer above
  serves, measured by the public <a href="https://github.com/chad/whichlang">whichlang benchmark</a>: given
  a free choice of language across 13 models, Ruby was picked <strong>0 times in 1,267 generated
  solutions</strong> (the defaults are Python, JavaScript, and Go). Win condition: that zero starts
  climbing, model after model.</p>
  <div class="goals goals--boss">#{BOSS_METERS}</div>
</div>
</section>

<section>
<h2><span class="num">03</span>Methodology</h2>
<p class="note">All indicators probed over HTTP, June 2026, against each project's documentation URL:
robots.txt parsed for AI user-agents (CCBot, GPTBot, ClaudeBot, Google-Extended) with
<code>Disallow: /</code>; crawlability tested by fetching as CCBot (to catch Cloudflare/WAF blocks); content
negotiation via <code>Accept: text/markdown</code>; <code>.md</code> routes and llms.txt checked for a 200.
The language-choice figure is from the open whichlang benchmark (13 models, 1,267 classified solutions, 0
Ruby; <a href="https://github.com/chad/whichlang">github.com/chad/whichlang</a>). That the same models write
Rails competently when instructed is our own informal observation.</p>
<p class="note"><strong>Why Common Crawl?</strong> It's the open web crawl that seeds most LLM pretraining
corpora (C4, RefinedWeb, FineWeb, behind GPT, Llama, and others) and feeds many retrieval indexes.
A project's CC coverage is a proxy for whether a model has seen its docs at all, a separate question from
whether the live site is crawlable today. It's the one column you cannot fix this quarter, since it reflects
crawls already taken, which is why getting in (sitemaps, unblocking bots, backlinks) is Layer 0. The usual
reason a page is absent is a <strong>missing sitemap</strong>: with no manifest to discover from, the crawler
never reaches it.</p>
</section>

<footer>
  <span class="label">Evil Martians</span>
  <p>Built by Evil Martians. A living scorecard, re-run the probes to update it. Background reading:
  <a href="https://evilmartians.com/chronicles/how-to-make-your-website-visible-to-llms">&ldquo;How to make
  your website visible to LLMs&rdquo;</a> and
  <a href="https://evilmartians.com/chronicles/3-rules-for-getting-ai-agents-to-find-use-and-not-exploit-your-devtool">&ldquo;3
  rules for getting AI agents to find, use, and not exploit your devtool&rdquo;</a> on the Evil Martians
  Chronicles.</p>
</footer>

</main>
</body>
</html>
HTML

out_dir = File.join(ROOT, "dist")
Dir.mkdir(out_dir) unless Dir.exist?(out_dir)
File.write(File.join(out_dir, "scorecard.html"), PAGE)
puts "wrote dist/scorecard.html | resources #{n} | llms #{llms} neg #{neg} md #{md} sitemaps #{sm} blocked #{blocked.inspect}"
