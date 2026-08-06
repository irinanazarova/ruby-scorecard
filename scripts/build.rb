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
require "fileutils"

ROOT = File.expand_path("..", __dir__)
rows = JSON.parse(File.read(File.join(ROOT, "data", "scorecard.json")))["rows"]
cov_path = File.join(ROOT, "data", "coverage.json")
coverage = File.exist?(cov_path) ? JSON.parse(File.read(cov_path)) : {}
cg_path = File.join(ROOT, "data", "content_gap.json")
content_gap = File.exist?(cg_path) ? JSON.parse(File.read(cg_path)) : nil
q_path = File.join(ROOT, "data", "quality.json")
quality = File.exist?(q_path) ? JSON.parse(File.read(q_path)) : {}
qs_path = File.join(ROOT, "data", "quality_sample.json")
quality_sample = File.exist?(qs_path) ? JSON.parse(File.read(qs_path)) : {}
repos_path = File.join(ROOT, "data", "repos.json")
repos = File.exist?(repos_path) ? JSON.parse(File.read(repos_path)) : {}
swh_path = File.join(ROOT, "data", "swh.json")
swh = File.exist?(swh_path) ? JSON.parse(File.read(swh_path)) : {}
ln_path = File.join(ROOT, "data", "license_notes.json")
license_notes = File.exist?(ln_path) ? JSON.parse(File.read(ln_path)).reject { |k, _| k.start_with?("_") } : {}

# Evil Martians favicon set (+ the martian used as the footer lurker), self-hosted at the site root.
DIST = File.join(ROOT, "dist")
FileUtils.mkdir_p(DIST)
%w[favicon.svg favicon.ico apple-touch-icon.png].each do |f|
  src = File.join(ROOT, "src", "assets", f)
  FileUtils.cp(src, File.join(DIST, f)) if File.exist?(src)
end

# Publish the long-form guide alongside the scorecard so "read more" links resolve at /guide.
guide_src = File.join(ROOT, "docs", "how-devtooling-gets-into-training-data.html")
FileUtils.cp(guide_src, File.join(DIST, "guide.html")) if File.exist?(guide_src)

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

# ---- Training-channel helpers ----
# Code channel: are the docs in a public repo whose license does not exclude them? That puts the
# Markdown in The Stack and bypasses the web quality filter. The Stack v2/v3 keep `permissive` AND
# `no_license` files and drop only `non_permissive` (copyleft, proprietary), so an absent license is
# not a disqualifier; v1 was stricter. The web gates (Common Crawl, quality) are then secondary and muted.
#
# The cell shows the license string GitHub's API actually returns, verbatim, because that string is
# what most tooling reads and it is lossier than it looks: every license GitHub cannot identify comes
# back as `NOASSERTION` ("Other"), so a bespoke permissive license and a source-available one that
# forbids commercial hosting are indistinguishable in the metadata. Where we opened the license file
# ourselves, data/license_notes.json carries the real terms and overrides the verdict.
GH_META = { nil => "(no license file)", "NOASSERTION" => "NOASSERTION" }.freeze
NOASSERT_TIP = "GitHub's API reports spdx_id NOASSERTION (name \"Other\") for every license it cannot " \
               "identify, so custom, proprietary, and source-available licenses all look the same here"

def cell_code(rp, note = nil)
  return %(<span class="cc-na" title="no public docs repo found">&mdash;</span>) unless rp && rp["docs_repo"]

  raw = rp["docs_license"]
  label = GH_META.fetch(raw, raw)
  repo = esc(rp["docs_repo"])
  in_stack = code_in_stack?(rp, note)

  if note
    # Verified by reading the license text: show what GitHub says, and what it really is.
    tip = "GitHub metadata says #{label}. Reading #{esc(note["file"])} in #{repo}: #{esc(note["actual"])} " \
          "(#{esc(note["class"])}). #{esc(note["note"])}"
    verdict = in_stack ? OK : BAD
    return verdict + %(<span class="sub lic lic--read" title="#{tip}">#{esc(label)} <em>= #{esc(note["actual"])}</em></span>)
  end

  tip = if raw.nil?
          "GitHub reports no license file for #{repo}; The Stack v2/v3 keep no_license files"
        elsif raw == "NOASSERTION"
          "#{NOASSERT_TIP}. We have not read #{repo}'s license text, so its terms are unverified"
        else
          "GitHub reports #{esc(label)} for #{repo}"
        end
  cls = raw == "NOASSERTION" ? "sub lic lic--vague" : "sub lic"
  (in_stack ? OK : BAD) + %(<span class="#{cls}" title="#{tip}">#{esc(label)}</span>)
end

# A verified reading of the license text beats GitHub's label: the corpus builders scan the text too.
def code_in_stack?(rp, note = nil)
  return note["stack_eligible"] unless note.nil? || note["stack_eligible"].nil?

  rp && rp["docs_in_stack"] == "yes"
end

# Code channel, collection step: The Stack is built from the Software Heritage archive, so a
# permissive docs repo only reaches the code corpus if SWH has actually collected it.
def cell_swh(sw, rp)
  return %(<span class="cc-na" title="no public docs repo found">&mdash;</span>) unless rp && rp["docs_repo"]
  return %(<span class="cc-na" title="not checked yet">&mdash;</span>) if sw.nil? || sw["archived"].nil?

  slug = esc(sw["repo"])
  if sw["archived"]
    %(<span class="ok" title="github.com/#{slug} is in the Software Heritage archive, the source The Stack is built from">&#10003;</span>)
  else
    %(<span class="bad" title="Software Heritage has no record of github.com/#{slug}; request archival at archive.softwareheritage.org/save/">&#10007;</span><span class="sub">not collected</span>)
  end
end

# Web channel, Gate 2: best of up to 5 sampled pages (FineWeb-Edu; keeps int_score >= 3, raw >= 2.5).
def cell_quality(qs)
  return %(<span class="cc-na" title="no extractable text">&mdash;</span>) unless qs && qs["ok"] && qs["best"]

  best = qs["best"]
  cls = qs["any_keep"] ? "ok" : (best >= 2.0 ? "warn" : "bad")
  glyph = qs["any_keep"] ? "&#10003;" : "&#10007;"
  %(<span class="#{cls}" title="best of #{qs["n"]} sampled pages: #{format('%.1f', best)}; FineWeb-Edu keeps int_score &ge; 3">#{glyph}<span class="sub">#{format('%.1f', best)}</span></span>)
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
  trows << %(<tr class="grp" data-grp="#{slug(cat)}"><td colspan="11">#{esc(CAT_LABEL[cat])}</td></tr>)
  rows.select { |r| r["category"] == cat }.each do |r|
    c = coverage[r["name"]]
    rp = repos[r["name"]]
    sw = swh[r["name"]]
    qs = quality_sample[r["name"]]
    note = rp && license_notes[rp["docs_repo"]]
    # When the docs already reach The Stack via a permissive repo, the web gates are secondary: mute
    # them. A repo Software Heritage has verifiably not collected is not in The Stack, so it keeps
    # the web gates live.
    in_code = code_in_stack?(rp, note) && !(sw && sw["archived"] == false)
    mute = in_code ? " muted" : ""
    muted_tip = in_code ? %( title="already eligible via the code corpus; the web gates are secondary here") : ""
    trows << %(<tr data-cat="#{slug(cat)}" data-name="#{esc(r["name"].downcase)}" data-cc="#{cov_sortkey(c)}">) \
      "<td class=\"res\"><a href=\"#{esc(r["docs"])}\">#{esc(r["name"])}</a></td>" \
      "<td>#{cell_robots(r)}</td><td>#{cell_bot(r)}</td>" \
      "<td>#{mark(r["sitemap"])}</td><td>#{mark(r["llms_txt"])}</td>" \
      "<td>#{mark(r["content_neg"])}</td><td>#{mark(r["md_route"])}</td>" \
      "<td class=\"train train--code\">#{cell_code(rp, note)}</td>" \
      "<td class=\"train\">#{cell_swh(sw, rp)}</td>" \
      "<td class=\"train cc#{mute}\"#{muted_tip}>#{cov_cell(c, scoped: !r["cc_scope"].to_s.empty?)}</td>" \
      "<td class=\"train#{mute}\"#{muted_tip}>#{cell_quality(qs)}</td></tr>"
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
BOSS_METERS = meter("Ruby picks", 0, 1267)

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
  cg_rows = content_gap["tasks"].map do |t|
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
      #{cg_rows}
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

# ---- "second gate" quality block (FineWeb-Edu classifier; up to 5 pages per resource, by type) ----
QUALITY = if quality_sample && !quality_sample.empty?
  total_res = quality_sample.size
  ok = quality_sample.select { |_, v| v["ok"] }
  pages_total = ok.sum { |_, v| v["n"].to_i }
  keep_res = ok.count { |_, v| v["any_keep"] }                 # >= 1 page rounds to int_score 3
  best_below2 = ok.count { |_, v| v["best"] && v["best"] < 2 }
  no_text = total_res - ok.size                                # client-rendered or blocked
  all_pages = ok.flat_map { |_, v| v["pages"] }
  curly = all_pages.count { |p| p["curly"] }
  top = ok.sort_by { |_, v| -v["best"] }.first(3)
        .map { |k, v| "#{esc(k)} #{format('%.1f', v['best'])}" }.join(", ")
  <<QUAL
<h3 class="cg-title">The second gate: would the docs survive the quality filter?</h3>
<p class="note">Being crawled is the first gate. The second is a quality classifier. We scored up to five
pages per resource with the open <a href="https://huggingface.co/HuggingFaceFW/fineweb-edu-classifier">FineWeb-Edu</a>
filter (kept at score&nbsp;&ge;&nbsp;3). Even counting each resource's <em>best</em> page, only
<strong>#{keep_res} of #{total_res}</strong> clear the bar (top: #{top}); for <strong>#{best_below2}</strong>
the best of five scores below&nbsp;2. The filter rewards educational prose and penalizes reference and code,
exactly the docs developers need.</p>
<p class="note">There is a way around it. Docs in a <strong>public repo</strong> reach
the code corpus (<a href="https://huggingface.co/datasets/bigcode/the-stack-v2">The Stack</a>) and
<strong>skip the quality filter entirely</strong>, the Training column shows which resources qualify. A
permissive license is the safe choice, and a <em>missing</em> one is no barrier: The Stack v2 and v3 keep
unlicensed files and drop only copyleft and proprietary ones. And
once a snippet is in public code and copied widely, models reproduce it verbatim: Supabase Auth and
Resend's quickstart both <em>fail</em> this filter yet Claude recites them from memory.
<a href="/guide">Read the full guide &rarr;</a></p>
QUAL
else
  ""
end

# ---- what GitHub's license metadata actually says (and where it hides the terms) ----
# The code-corpus verdict is usually read off GitHub's `license.spdx_id`. That field is coarser than
# the decision it is used for, so the distribution is worth showing: NOASSERTION is a single bucket
# holding every license GitHub could not identify.
LICENSES = begin
  seen = rows.filter_map { |r| repos[r["name"]] }.select { |rp| rp["docs_repo"] }
  tally = seen.group_by { |rp| rp["docs_license"] }.transform_values(&:size).sort_by { |lic, cnt| [lic.nil? ? 1 : 0, -cnt] }
  vague = tally.to_h["NOASSERTION"].to_i
  read = license_notes.map do |slug, nt|
    %(<li><code>#{esc(slug)}</code> reports <strong>NOASSERTION</strong>, and its #{esc(nt["file"])} is the
      <strong>#{esc(nt["actual"])}</strong>: #{esc(nt["note"])} That makes it
      <em>#{esc(nt["class"])}</em>, so the docs are #{nt["stack_eligible"] ? "still eligible for" : "<strong>not</strong> eligible for"}
      the code corpus, which GitHub's label alone would never tell you.</li>)
  end.join("\n    ")
  items = tally.map do |lic, cnt|
    label = GH_META.fetch(lic, lic)
    extra = lic == "NOASSERTION" ? %( <span class="lic-note">any custom or source-available terms</span>) : ""
    %(<li><code>#{esc(label)}</code> <span class="lic-n">#{cnt}</span>#{extra}</li>)
  end.join("\n    ")
  <<LIC
<h3 class="cg-title">What GitHub's license metadata actually says</h3>
<p class="note">The code-corpus column reports the license string GitHub's API returns, verbatim, because
that string is what tooling reads, and it is lossier than it looks. GitHub identifies a license by matching
the file against a known list; anything it cannot match becomes <code>spdx_id: NOASSERTION</code>
(<code>name: "Other"</code>). <strong>Every source-available license looks identical in that metadata</strong>,
and so does a bespoke permissive one. Across the #{seen.size} resources with a public docs repo:</p>
<ul class="lic-tally">
    #{items}
</ul>
<p class="note">#{vague} of them sit in that <code>NOASSERTION</code> bucket, where the terms can only be
established by opening the file. Where we have done so:</p>
<ul class="lic-read">
    #{read}
</ul>
<p class="note">This matters because the corpus builders read the license <em>text</em>, not GitHub's label:
a repo that looks merely "custom" in the metadata can be firmly excluded, or firmly fine. Treat
<code>NOASSERTION</code> as "unknown", never as "probably OK".</p>
LIC
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
<link rel="icon" type="image/svg+xml" href="favicon.svg#{asset_q("favicon.svg")}">
<link rel="icon" sizes="32x32" href="favicon.ico">
<link rel="apple-touch-icon" href="apple-touch-icon.png">
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
    <p class="lede"><strong>Ruby and Rails are a great default, for humans and AI agents alike.</strong>
    Yet models rarely reach for them: across the open whichlang benchmark, 13 models picked Ruby
    <strong>0 times in 1,267 solutions</strong>. That is a discoverability problem, and it starts with the
    docs. We score #{n} ecosystem resources on whether agents can <strong>find</strong> them and whether
    they would reach a model's <strong>training</strong> data. <a href="/guide">How docs get into training
    &rarr;</a></p>
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
(<span class="ok">&#10003;</span> good, <span class="bad">&#10007;</span> missing). Columns split into two
questions: <strong>Retrieval</strong>, can an agent find the docs at request time, and
<strong>Training</strong>, would they reach a model's corpus, either through the <strong>code corpus</strong>
(docs in a public repo whose license is not copyleft, <em>and</em> which
<a href="https://www.softwareheritage.org/">Software Heritage</a> has collected; The Stack is built from
that archive, skipping the web filters) or the <strong>web corpus</strong>
(Common Crawl coverage, then best-of-5 FineWeb-Edu quality). Where the code corpus already qualifies, the
web cells are <span style="opacity:.45">dimmed</span> as secondary. Click any heading to sort;
<a href="/guide">what each column means &rarr;</a></p>

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
    <thead>
    <tr class="grouprow">
      <th class="res sortable" rowspan="2" data-col="0">Resource (docs) <span class="arrow">&#9650;</span></th>
      <th class="grouphead" colspan="6">Retrieval <span class="grouphead__sub">can an agent find it at request time</span></th>
      <th class="grouphead grouphead--train" colspan="4">Training <span class="grouphead__sub">would it reach the corpus</span></th>
    </tr>
    <tr class="colrow">
      <th class="sortable" data-col="1">robots<br>allows AI <span class="arrow">&#9650;</span></th>
      <th class="sortable" data-col="2">crawlable<br>(no WAF) <span class="arrow">&#9650;</span></th>
      <th class="sortable" data-col="3">sitemap <span class="arrow">&#9650;</span></th>
      <th class="sortable" data-col="4">llms.txt <span class="arrow">&#9650;</span></th>
      <th class="sortable" data-col="5">content<br>negotiation <span class="arrow">&#9650;</span></th>
      <th class="sortable" data-col="6">.md<br>routes <span class="arrow">&#9650;</span></th>
      <th class="sortable train" data-col="7">code corpus<br><span class="th-sub">docs repo license</span> <span class="arrow">&#9650;</span></th>
      <th class="sortable train" data-col="8">Software<br>Heritage <span class="th-sub">repo collected</span> <span class="arrow">&#9650;</span></th>
      <th class="sortable train" data-col="9">Common<br>Crawl <span class="arrow">&#9650;</span></th>
      <th class="sortable train" data-col="10">quality<br><span class="th-sub">best of 5, &ge;3</span> <span class="arrow">&#9650;</span></th>
    </tr></thead>
    <tbody>
#{TABLE}
    </tbody>
  </table>
  </div>
</scorecard-table>

#{QUALITY}

#{LICENSES}
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
      <a href="https://github.com/modelcontextprotocol/ruby-sdk">MCP SDK</a>, and a Boost-shaped bundle of
      MCP + skills + guidelines is emerging in
      <a href="https://github.com/Bakaface/rails-hyperdrive">rails-hyperdrive</a> <span class="tag new">new</span>.</li>
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
    <li>Grow Ruby's share of the training corpus. Code models also learn from curated GitHub archives
      (Software Heritage &rarr; <a href="https://huggingface.co/datasets/bigcode/the-stack-v2">The Stack</a>),
      where Ruby is ~6.8&nbsp;GB against Python's ~60 and JavaScript's ~65, and capability tracks that share.
      Publish an open, idiomatic-Rails instruction dataset and contribute permissively-licensed Ruby to open
      corpora like <a href="https://huggingface.co/datasets/PleIAs/common_corpus">Common Corpus</a>;
      rebalancing a corpus toward under-represented languages measurably lifts them.</li>
    <li>Keep the public <a href="https://github.com/chad/whichlang">whichlang benchmark</a> as the
      scoreboard for the final boss below, and re-run it on each new model.</li>
  </ul>
</div>

<div class="panel target boss">
  <p class="label">&#9733; The final boss</p>
  <p><strong>Frontier models reach for Ruby more often.</strong> The single metric every layer above
  serves, measured by the public <a href="https://github.com/chad/whichlang">whichlang benchmark</a>: given
  a free choice of language across 13 models, Ruby was picked <strong>0 times in 1,267 generated
  solutions</strong> (the defaults are Python, JavaScript, and Go). Win condition: that zero starts climbing,
  model after model, as agents pick Ruby whenever it is the better fit.</p>
  <div class="goals goals--boss">#{BOSS_METERS}</div>
</div>
</section>

<section>
<h2><span class="num">03</span>Methodology</h2>
<p class="note">All indicators probed over HTTP, June 2026, against each project's documentation URL:
robots.txt parsed for AI user-agents (CCBot, GPTBot, ClaudeBot, Google-Extended) with
<code>Disallow: /</code>; crawlability tested by fetching as CCBot (to catch Cloudflare/WAF blocks); content
negotiation via <code>Accept: text/markdown</code>; <code>.md</code> routes and llms.txt checked for a 200.
Software Heritage collection checked per docs repo via the archive's public
<a href="https://archive.softwareheritage.org/api/">origin API</a>; a missing repo can be submitted at
<a href="https://archive.softwareheritage.org/save/">Save Code Now</a>.
The language-choice figure is from the open whichlang benchmark (13 models, 1,267 classified solutions, 0
Ruby; <a href="https://github.com/chad/whichlang">github.com/chad/whichlang</a>). That the same models write
Rails competently when instructed is our own informal observation.</p>
<p class="note"><strong>Why Common Crawl?</strong> It's the open web crawl that seeds most LLM pretraining
corpora (C4, RefinedWeb, FineWeb, behind GPT, Llama, and others). Common Crawl is a sampled, English-biased
slice of the web: it picks domains and pages by
<a href="https://facctconference.org/static/papers24/facct24-148.pdf">harmonic centrality under a fixed
budget</a>, so a project's CC coverage is a proxy for whether a model has seen its docs at all. Inclusion is
necessary but not sufficient: the corpora are built from heavily filtered, deduplicated derivatives, so a
crawled page must also clear a quality filter to reach training. It's the one column you cannot fix this
quarter (it reflects crawls already taken), which is why getting in, via sitemaps, internal links, backlinks,
and unblocking bots, is Layer 0.</p>
</section>

<footer>
  <span class="label">Evil Martians</span>
  <p>Built by Evil Martians. A living scorecard, re-run the probes to update it. Read more: our
  <a href="/guide">guide to how devtooling docs get into training data</a>, plus
  <a href="https://evilmartians.com/chronicles/how-to-make-your-website-visible-to-llms">&ldquo;How to make
  your website visible to LLMs&rdquo;</a> and
  <a href="https://evilmartians.com/chronicles/3-rules-for-getting-ai-agents-to-find-use-and-not-exploit-your-devtool">&ldquo;3
  rules for getting AI agents to find, use, and not exploit your devtool&rdquo;</a> on the Chronicles.</p>
  <img class="lurker" src="favicon.svg#{asset_q("favicon.svg")}" alt="" aria-hidden="true" width="44" height="44">
</footer>

</main>
</body>
</html>
HTML

out_dir = File.join(ROOT, "dist")
Dir.mkdir(out_dir) unless Dir.exist?(out_dir)
File.write(File.join(out_dir, "scorecard.html"), PAGE)
puts "wrote dist/scorecard.html | resources #{n} | llms #{llms} neg #{neg} md #{md} sitemaps #{sm} blocked #{blocked.inspect}"
