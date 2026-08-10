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
require_relative "site_nav"

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
stack_path = File.join(ROOT, "data", "stack.json")
stack = File.exist?(stack_path) ? JSON.parse(File.read(stack_path)).reject { |k, _| k.start_with?("_") } : {}
sn_path = File.join(ROOT, "data", "stack_notes.json")
stack_notes = File.exist?(sn_path) ? JSON.parse(File.read(sn_path)).reject { |k, _| k.start_with?("_") } : {}

# Evil Martians favicon set (+ the martian used as the footer lurker), self-hosted at the site root.
DIST = File.join(ROOT, "dist")
FileUtils.mkdir_p(DIST)
%w[favicon.svg favicon.ico apple-touch-icon.png].each do |f|
  src = File.join(ROOT, "src", "assets", f)
  FileUtils.cp(src, File.join(DIST, f)) if File.exist?(src)
end

# The long-form guide used to be generated here into dist/guide.html. It was folded into /learn,
# which is rendered by Rails because every result on /test deep-links into its anchors. Nothing to
# copy: "read more" links below point at /learn, and routes.rb 301s the old /guide URL there.

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
# Code channel: is the docs repo actually in The Stack v3 train set? That is an OBSERVED fact, not
# an inference: scripts/stack_check.rb asks the official "Am I in The Stack?" index and records the
# answer in data/stack.json. v3 is a direct GitHub crawl (cutoff 2025-08-07), license-filtered per
# file: permissive (Blue Oak list) and unlicensed files are kept, non-permissive files are dropped.
# The per-file decisions are not reproducible from outside, and they surprise in both directions
# (karafka/wiki's all-rights-reserved text is in; karafka/karafka's LGPL is out; sidekiq's LGPL is
# in), which is exactly why the verdict must come from the observed list, with the license reading
# kept as the explanation and as the forecast for the next snapshot.
#
# The cell still shows the license string GitHub's API returns, verbatim, because that string is
# what most tooling reads and it is lossier than it looks: every license GitHub cannot identify
# comes back as `NOASSERTION` ("Other"). Where we opened the license file ourselves,
# data/license_notes.json carries the real terms; data/stack_notes.json carries hand-verified
# reasons for absences (opt-outs, private-until dates). A repo with no observed answer falls back
# to the license inference and says so in the tooltip.
GH_META = { nil => "(no license file)", "NOASSERTION" => "NOASSERTION" }.freeze
NOASSERT_TIP = "GitHub's API reports spdx_id NOASSERTION (name \"Other\") for every license it cannot " \
               "identify, so custom, proprietary, and source-available licenses all look the same here"
V3_TIP = "The Stack v3 train set (a direct GitHub crawl, cutoff 2025-08-07, license-filtered per " \
         "file), checked against the official Am-I-in-The-Stack index"

def cell_code(rp, note = nil, st = nil, snote = nil, sw = nil)
  return %(<span class="cc-na" title="no public docs repo found">&mdash;</span>) unless rp && rp["docs_repo"]

  raw = rp["docs_license"]
  label = GH_META.fetch(raw, raw)
  repo = esc(rp["docs_repo"])
  lic_html = note ? %(#{esc(label)} <em>= #{esc(note["actual"])}</em>) : esc(label)
  cls = note ? "sub lic lic--read" : (raw == "NOASSERTION" ? "sub lic lic--vague" : "sub lic")
  reading = note ? " Reading #{esc(note["file"])}: #{esc(note["actual"])} (#{esc(note["class"])}). #{esc(note["note"])}" : ""
  # The dedicated SWH column is gone; the fact survives here, on the rows where it still says
  # something (an absence): SWH was the v2 collection path and the one archival a maintainer can
  # trigger themselves.
  swh_bit = sw && sw["archived"] == false ? " Software Heritage has no record of it either; " \
            "request archival at archive.softwareheritage.org/save/." : ""

  case st && st["in_stack"]
  when true
    tip = "Observed: github.com/#{repo} is in #{V3_TIP}. GitHub metadata says #{esc(label)}.#{reading}"
    OK + %(<span class="#{cls}" title="#{tip}">#{lic_html}</span>)
  when false
    why, sub = absence_reason(st, snote)
    tip = "Observed: github.com/#{repo} is NOT in #{V3_TIP}. #{why}#{reading}#{swh_bit}"
    BAD + %(<span class="#{cls}" title="#{tip}">#{sub || lic_html}</span>)
  else
    # No observed answer yet: infer from the license and say so, never dressing a guess as a fact.
    verdict = code_in_stack?(rp, note)
    tip = if note
            "Not yet checked against the v3 index; inferred from the license text.#{reading}"
    elsif raw.nil?
            "Not yet checked against the v3 index. GitHub reports no license file for #{repo}; " \
            "The Stack keeps unlicensed files, so the docs would qualify once crawled"
    elsif raw == "NOASSERTION"
            "Not yet checked against the v3 index. #{NOASSERT_TIP}. We have not read #{repo}'s " \
            "license text, so its terms are unverified"
    else
            "Not yet checked against the v3 index; inferred from GitHub's reported license, #{esc(label)}"
    end
    (verdict ? OK : BAD) + %(<span class="#{cls}" title="#{tip}">#{lic_html}</span>)
  end
end

# Why is a repo not in the set? Hand-verified reasons (data/stack_notes.json) beat the automated
# created-after-cutoff flag, which itself beats silence; an absence with no established reason says
# so instead of blaming the license. Returns [tooltip sentence, optional cell label override].
def absence_reason(st, snote)
  if snote && snote["reason"] == "opt-out"
    [ %(#{esc(snote["note"])} (#{esc(snote["url"])})), "opted out" ]
  elsif snote && snote["reason"] == "post-cutoff"
    [ esc(snote["note"]), "after cutoff" ]
  elsif snote
    [ esc(snote["note"]), nil ]
  elsif st["post_cutoff"]
    [ "The repo was created #{esc(st["created"])}, after the crawl cutoff, so no license could have " \
     "put it in this snapshot.", %(after cutoff) ]
  else
    [ "The reason is not established; the license reading below is the best predictor.", nil ]
  end
end

# Fallback for repos with no observed answer: a verified reading of the license text beats
# GitHub's label, and the hand-curated docs_in_stack call is last.
def code_in_stack?(rp, note = nil)
  return note["stack_eligible"] unless note.nil? || note["stack_eligible"].nil?

  rp && rp["docs_in_stack"] == "yes"
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

CAT_ORDER = [ "core", "frontend & view", "web frameworks", "data", "ai",
             "background, realtime & deploy", "tooling & types", "libraries",
             "community & resources" ].freeze
CAT_LABEL = CAT_ORDER.to_h { |c| [ c, c.split.map(&:capitalize).join(" ") ] }
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
stk_checked = stack.values.count { |v| !v["in_stack"].nil? }
stk_in      = stack.values.count { |v| v["in_stack"] }

# ---- table rows ----
present_cats = CAT_ORDER.select { |c| rows.any? { |r| r["category"] == c } }
trows = []
present_cats.each do |cat|
  trows << %(<tr class="grp" data-grp="#{slug(cat)}"><td colspan="10">#{esc(CAT_LABEL[cat])}</td></tr>)
  rows.select { |r| r["category"] == cat }.each do |r|
    c = coverage[r["name"]]
    rp = repos[r["name"]]
    sw = swh[r["name"]]
    qs = quality_sample[r["name"]]
    note = rp && license_notes[rp["docs_repo"]]
    st = stack[r["name"]]
    snote = rp && stack_notes[rp["docs_repo"]&.downcase]
    # When code from the docs repo is observed in The Stack v3, the web gates are secondary: mute
    # them. Without an observed answer, fall back to the license inference, and let a verified SWH
    # absence keep the web gates live (an uncollected repo never reached the v2 corpus).
    in_code = if st && !st["in_stack"].nil?
                st["in_stack"]
    else
                code_in_stack?(rp, note) && !(sw && sw["archived"] == false)
    end
    mute = in_code ? " muted" : ""
    muted_tip = in_code ? %( title="code from this repo is in The Stack v3, so the web gates are secondary here") : ""
    trows << %(<tr data-cat="#{slug(cat)}" data-name="#{esc(r["name"].downcase)}" data-cc="#{cov_sortkey(c)}">) \
      "<td class=\"res\"><a href=\"#{esc(r["docs"])}\">#{esc(r["name"])}</a></td>" \
      "<td>#{cell_robots(r)}</td><td>#{cell_bot(r)}</td>" \
      "<td>#{mark(r["sitemap"])}</td><td>#{mark(r["llms_txt"])}</td>" \
      "<td>#{mark(r["content_neg"])}</td><td>#{mark(r["md_route"])}</td>" \
      "<td class=\"train train--code\">#{cell_code(rp, note, st, snote, sw)}</td>" \
      "<td class=\"train cc#{mute}\"#{muted_tip}>#{cov_cell(c, scoped: !r["cc_scope"].to_s.empty?)}</td>" \
      "<td class=\"train#{mute}\"#{muted_tip}>#{cell_quality(qs)}</td></tr>"
  end
end
TABLE = trows.join("\n")

# ---- category filter chips ----
chips = [ %(<button class="chip" data-cat="all" aria-pressed="true">All</button>) ]
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
  cells = content_gap["tasks"].flat_map { |t| [ t["js"], t["py"] ] }
  solid = cells.count { |c| c["state"] == "solid" }
  # number the found sources in order of appearance
  src_urls = []
  cells.each { |c| u = c["url"]; src_urls << u if u && !src_urls.include?(u) }
  src_num = src_urls.each_with_index.to_h { |u, i| [ u, i + 1 ] }
  sources = src_urls.empty? ? "" : %(<p class="note cg-srclist">Sources: ) +
    src_urls.map { |u| host = (URI.parse(u).host&.sub(/\Awww\./, "") || u); %(<sup>#{src_num[u]}</sup>&nbsp;<a href="#{esc(u)}">#{esc(host)}</a>) }.join(" &middot; ") + "</p>"
  heads = content_gap["stacks"].map { |s| %(<th>#{esc(s["label"])} <span class="cg-sub">#{esc(s["sub"])}</span></th>) }.join
  cg_rows = content_gap["tasks"].map do |t|
    %(<tr><th scope="row">#{esc(t["task"])} <span class="cg-detail">#{esc(t["detail"])}</span></th>#{cg_cell(t["js"], src_num)}#{cg_cell(t["py"], src_num)}</tr>)
  end.join("\n      ")
  <<CG
<h4 class="cg-title">Publish the missing comparisons</h4>
<p class="cg-metric">A model argues for what its corpus argues for, and almost nothing argues, with
numbers, that Rails is the better build for these products. <strong>#{solid} of #{cells.size}</strong>
comparisons are <em>solid</em>; the rest are generic takes or missing.</p>
<div class="table-scroll">
<table class="cg-table">
  <thead><tr><th scope="col">Build &hellip; in Rails</th>#{heads}</tr></thead>
  <tbody>
      #{cg_rows}
  </tbody>
</table>
</div>
#{sources}
<p class="note">Snapshot #{esc(content_gap["updated"])}: one web search per task and stack, then judged.
<span class="cg-k cg-solid">solid</span> current, task-specific, with numbers &middot;
<span class="cg-k cg-generic">generic</span> framework pros and cons &middot;
<span class="cg-k cg-missing">missing</span> nothing credible.</p>
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
<h3 class="cg-title">The second gate: a quality filter</h3>
<p class="note">Being crawled is the first gate. A classifier is the second. We scored up to five pages
per resource with the open
<a href="https://huggingface.co/HuggingFaceFW/fineweb-edu-classifier">FineWeb-Edu</a> filter, which keeps
score&nbsp;&ge;&nbsp;3. Counting each resource's <em>best</em> page, <strong>#{keep_res} of
#{total_res}</strong> clear the bar (top: #{top}); for <strong>#{best_below2}</strong> even the best of
five scores below&nbsp;2. The filter rewards tutorial prose and penalizes reference docs and code,
exactly what developers need most. Docs in a public repo skip this filter entirely; that is what the
"in The Stack v3" column measures. <a href="/learn#code-channel">Why the code channel decides this &rarr;</a></p>
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
  # The licence name is the final tiebreaker, and it has to be: five licences tie at one repo each,
  # and Ruby's sort_by is NOT stable, so without a total ordering their relative positions are
  # unspecified. The output was reproducible on one machine and different on a CI runner, which is
  # the worst version of this bug -- the committed page and a fresh build of the same data disagreed
  # for no reason anyone could see in the diff.
  tally = seen.group_by { |rp| rp["docs_license"] }.transform_values(&:size)
              .sort_by { |lic, cnt| [ lic.nil? ? 1 : 0, -cnt, lic.to_s ] }
  items = tally.map do |lic, cnt|
    label = GH_META.fetch(lic, lic)
    extra = lic == "NOASSERTION" ? %( <span class="lic-note">any custom or source-available terms</span>) : ""
    %(<li><code>#{esc(label)}</code> <span class="lic-n">#{cnt}</span>#{extra}</li>)
  end.join("\n    ")
  <<LIC
<h3 class="cg-title">Licenses, as GitHub reports them</h3>
<p class="note">The cell prints the license string GitHub's API returns, verbatim, because that string is
what tooling reads. It is lossy: every license GitHub cannot match becomes <code>NOASSERTION</code>
("Other"), so a bespoke permissive license and a source-available one look identical there. Across the
#{seen.size} resources with a public docs repo:</p>
<ul class="lic-tally">
    #{items}
</ul>
<p class="note"><strong>The reading predicts; the train set decides.</strong> The Stack v3 filters file
by file, and only the result is observable: <strong>#{stk_in} of #{stk_checked}</strong> docs repos are
in, including <code>karafka/wiki</code>, whose license file says "All Rights Reserved", while
<code>karafka/karafka</code> (LGPL) is out and <code>sidekiq/sidekiq</code> (also LGPL) is in. A missing
license is no barrier: The Stack keeps unlicensed files. <strong>Opting out works</strong>: the
<code>rspec</code> and <code>bridgetownrb</code> orgs
<a href="https://github.com/bigcode-project/opt-out-v2/issues/985">asked to be removed</a> and are absent
org-wide. Where we read a license file ourselves, that row's tooltip carries the terms.
<a href="/learn#licenses">The full license guide &rarr;</a></p>
LIC
end

# ---- Rails products: full applications, tested against the code corpus and the RL harvest filters ----
# data/products.json is written by scripts/products_check.rb. Two column groups: the code path the
# main table uses (license as GitHub reports it, SWH collection, observed Stack v3 membership), and
# the mechanical filters the SWE-bench-family pipelines run when they turn a repo into RL training
# tasks (a derivable test command, its runtime, a container recipe, issue-closing PRs that touch
# tests). Everything rendered is observed; absences carry their reason only when verified.
products_path = File.join(ROOT, "data", "products.json")
products = File.exist?(products_path) ? JSON.parse(File.read(products_path)).reject { |k, _| k.start_with?("_") } : {}

PRODUCTS_SECTION = if products.empty?
  ""
else
  prows = products.values.sort_by { |e| -e["stars"].to_i }
  v3_in       = prows.count { |e| e["in_stack"] }
  v3_answered = prows.count { |e| !e["in_stack"].nil? }
  linked      = prows.count { |e| e["prs_harvestable"].to_i.positive? }
  issues_off  = prows.count { |e| e["has_issues"] == false }

  cells = prows.map do |e|
    slug = e["repo"]
    note = license_notes[slug]
    snote = stack_notes[slug.downcase]

    sub = esc(e["blurb"])
    sub += "; archived #{esc(e["pushed"])}" if e["gh_archived"]
    prod = %(<td class="res"><a href="https://github.com/#{esc(slug)}">#{esc(e["name"])}</a><span class="sub">#{sub}</span></td>)

    stars = %(<td>#{commate(e["stars"])}</td>)

    raw = e["license"]
    label = GH_META.fetch(raw, raw)
    lic_html = note ? %(#{esc(label)} <em>= #{esc(note["actual"])}</em>) : esc(label)
    lic_tip = if note
                "Reading #{esc(note["file"])}: #{esc(note["actual"])} (#{esc(note["class"])}). #{esc(note["note"])}"
    elsif raw == "NOASSERTION"
                NOASSERT_TIP
    else
                "The license string GitHub's API reports for github.com/#{esc(slug)}"
    end
    lic_cls = note ? "sub lic lic--read" : (raw == "NOASSERTION" ? "sub lic lic--vague" : "sub lic")
    lic = %(<td class="train train--code"><span class="#{lic_cls}" title="#{lic_tip}">#{lic_html}</span></td>)

    swh_cell = if e["swh_archived"].nil?
                 %(<td class="train"><span class="cc-na" title="not checked">&mdash;</span></td>)
    elsif e["swh_archived"]
                 %(<td class="train" title="Software Heritage has collected github.com/#{esc(slug)}; SWH is the archive The Stack v2 was assembled from">#{OK}</td>)
    else
                 %(<td class="train" title="Software Heritage has no record of github.com/#{esc(slug)}; a maintainer can request archival at archive.softwareheritage.org/save/">#{BAD}</td>)
    end

    v3 = case e["in_stack"]
    when true
           %(<td class="train" title="Observed: github.com/#{esc(slug)} is in #{V3_TIP}">#{OK}</td>)
    when false
           why, subl = snote ? absence_reason({ "post_cutoff" => e["post_cutoff"] }, snote) :
                               absence_reason({ "post_cutoff" => e["post_cutoff"], "created" => e["created"] }, nil)
           why = why.sub("the license reading below", "the license in this row")
           %(<td class="train" title="Observed: github.com/#{esc(slug)} is NOT in #{V3_TIP}. #{why}">#{BAD}#{subl ? %(<span class="sub">#{subl}</span>) : ""}</td>)
    else
           %(<td class="train"><span class="cc-na" title="not checked">&mdash;</span></td>)
    end

    ci = if e["ci_name"]
           %(<td title="an active workflow under .github/workflows a pipeline can derive the test command from">#{OK}<span class="sub">#{esc(e["ci_name"])}</span></td>)
    elsif e["workflows"].to_i.positive?
           %(<td title="#{e["workflows"]} workflows exist, and none is an active test suite; mirrors run their CI elsewhere">#{BAD}<span class="sub">no test workflow</span></td>)
    else
           %(<td title="no workflows under .github/workflows">#{BAD}<span class="sub">no workflows</span></td>)
    end

    mins = if e["ci_median_min"]
             val = e["ci_median_min"].zero? ? "&lt;1" : commate(e["ci_median_min"])
             tip = "median of #{e["ci_runs_sampled"]} recent successful runs of &quot;#{esc(e["ci_name"])}&quot;; " \
                   "path-filtered workflows can complete as skips, so a short median can undercount the full suite"
             %(<td><span class="cc-val" title="#{tip}">#{val}<span class="cc-den"> min</span></span></td>)
    else
             %(<td><span class="cc-na" title="no timed runs">&mdash;</span></td>)
    end

    dock = if e["container"]
             %(<td title="#{esc((e["container_files"] || []).join(", "))} at the repo root">#{OK}</td>)
    else
             %(<td title="no Dockerfile, compose file, or .devcontainer at the repo root">#{BAD}</td>)
    end

    harvest = if e["prs_sampled"].to_i.zero?
                %(<td><span class="cc-na" title="no merged pull requests on GitHub">&mdash;</span></td>)
    else
                h = e["prs_harvestable"].to_i
                tip = "of the last #{e["prs_sampled"]} merged PRs (#{e["prs_from"]} to #{e["prs_to"]}), " \
                      "#{e["prs_closing_issue"]} close a GitHub issue and #{h} of those also modify tests; " \
                      "each such PR is the raw shape of one SWE-bench task"
                tip += ". GitHub issues are disabled on this repo, so no PR can close one" if e["has_issues"] == false
                %(<td><span class="#{h.positive? ? "ok" : "bad"}" title="#{tip}">#{h}/#{e["prs_sampled"]}</span></td>)
    end

    %(<tr>#{prod}#{stars}#{lic}#{swh_cell}#{v3}#{ci}#{mins}#{dock}#{harvest}</tr>)
  end.join("\n")

  <<PROD
<section>
<h2><span class="num">02</span>Rails products, tested against the harvest filters</h2>
<p class="note">The table above tracks documentation. Models also learn Rails from complete
applications, and agentic RL pipelines mine them mechanically. The
<a href="https://arxiv.org/abs/2310.06770">SWE-bench</a> family selects top-starred repos, derives
the test command from CI config, rebuilds the environment in a container, and turns each merged PR
that closes an issue and touches tests into one verifiable training task;
<a href="https://www.swebench.com/multilingual.html">SWE-bench Multilingual</a> discards about 30%
of candidate repos whose tests will not build or run too slowly. Below: the top-starred open-source
Rails products, measured against exactly those filters over the GitHub API.</p>
<div class="table-scroll">
<table class="products">
  <thead>
  <tr class="grouprow">
    <th class="res" rowspan="2">Product</th>
    <th rowspan="2">stars</th>
    <th class="grouphead grouphead--train" colspan="3">Code corpus <span class="grouphead__sub">would the code reach a pretraining set</span></th>
    <th class="grouphead" colspan="4">RL harvest <span class="grouphead__sub">could a SWE-bench-style pipeline mine it</span></th>
  </tr>
  <tr class="colrow">
    <th class="train">license<br><span class="th-sub">as GitHub reports it</span></th>
    <th class="train">SWH<br>archive</th>
    <th class="train">in The Stack v3<br><span class="th-sub">observed</span></th>
    <th>test CI</th>
    <th>median<br>run</th>
    <th>container<br>recipe</th>
    <th>issue-linked<br>PRs w/ tests<br><span class="th-sub">of last 50 merged</span></th>
  </tr>
  </thead>
  <tbody>
#{cells}
  </tbody>
</table>
</div>
<p class="note"><strong>Copyleft keeps the Rails flagships out of the permissive code corpus.</strong>
#{v3_in} of #{v3_answered} products are observed in The Stack v3 train set, and every AGPL- and
GPL-licensed product is absent, because v3 keeps permissively licensed and unlicensed files. All six
that are in report MIT or <code>NOASSERTION</code> terms.
<strong>Most products also fail the PR-to-issue linkage filter.</strong> #{linked} of #{prows.size}
merged at least one issue-closing, test-touching PR in the sampled window, and #{issues_off} of
#{prows.size} have GitHub issues disabled (Discourse and OpenProject triage on their own forums;
GitLab and Redmine are mirrors of development that happens elsewhere), so a pipeline mining GitHub
finds no harvestable instances there. The runtime filter bites too: Zammad's suite runs a 93-minute
median, the kind SWE-bench Multilingual discards. The direct workaround is
<a href="https://github.com/multi-swe-bench/multi-swe-bench">Multi-SWE-RL</a>: its task pipeline is
open, it accepts community contributions, and Ruby is absent from it today.</p>
</section>
PROD
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
#{site_nav(toggle: true)}
<header class="hero">
  <div class="wrap">
    <p class="kicker label">Evil Martians &middot; Ruby</p>
    <h1>Ruby &amp; Rails LLM discoverability scorecard</h1>
    <p class="lede"><strong>Ruby and Rails are a great default, for humans and AI agents alike.</strong>
    Yet given a free choice, 13 models picked Ruby <strong>0 times in 1,267 solutions</strong> (the open
    whichlang benchmark). Models reach for what they can see. So we score #{n} ecosystem resources on two
    questions: can an agent <strong>find</strong> the docs, and would they reach a model's
    <strong>training</strong> data? <a href="/learn">How docs get into training &rarr;</a></p>
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
(<span class="ok">&#10003;</span> good, <span class="bad">&#10007;</span> missing).
<strong>Retrieval</strong>: can an agent read the docs at request time?
<strong>Training</strong>: would they reach a model's corpus, through code or through the web?
The code column holds the corpus's own answer: every docs repo is checked against the official
<a href="https://huggingface.co/spaces/HuggingFaceCode/in-the-stack">Am I in The Stack?</a> index. A repo
already in The Stack skips the web filters, so its web cells
<span style="opacity:.45">dim</span>. Click any heading to sort;
<a href="/learn#glossary">what each column means &rarr;</a></p>

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
      <th class="grouphead grouphead--train" colspan="3">Training <span class="grouphead__sub">would it reach the corpus</span></th>
    </tr>
    <tr class="colrow">
      <th class="sortable" data-col="1">robots<br>allows AI <span class="arrow">&#9650;</span></th>
      <th class="sortable" data-col="2">crawlable<br>(no WAF) <span class="arrow">&#9650;</span></th>
      <th class="sortable" data-col="3">sitemap <span class="arrow">&#9650;</span></th>
      <th class="sortable" data-col="4">llms.txt <span class="arrow">&#9650;</span></th>
      <th class="sortable" data-col="5">content<br>negotiation <span class="arrow">&#9650;</span></th>
      <th class="sortable" data-col="6">.md<br>routes <span class="arrow">&#9650;</span></th>
      <th class="sortable train" data-col="7">in The Stack v3<br><span class="th-sub">observed; docs repo license</span> <span class="arrow">&#9650;</span></th>
      <th class="sortable train" data-col="8">Common<br>Crawl <span class="arrow">&#9650;</span></th>
      <th class="sortable train" data-col="9">quality<br><span class="th-sub">best of 5, &ge;3</span> <span class="arrow">&#9650;</span></th>
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

#{PRODUCTS_SECTION}
<section>
<h2><span class="num">03</span>What will move the needle</h2>
<p>Four levers, ordered by depth, all pushing the same number. Rails is plural by design, so the work
is shared defaults and shared conventions. Each layer shows its <strong>goal</strong> as a live gauge;
all of them feed the <strong>final boss</strong> below.</p>

<div class="layer">
  <h3><span class="lname">Layer 0: get into the corpus at all</span> <span class="tag now">ship now</span></h3>
  <div class="goals">#{GOALS_L0}</div>
  <ul>
    <li>Unblock AI crawlers (CCBot, GPTBot, ClaudeBot, Google-Extended) in robots.txt and at the WAF.
      One line at RubyEvents frees ~15,775 pages of talks.</li>
    <li>Add sitemaps, server-render, link internally, earn backlinks.</li>
    <li>CC-license conference video and publish transcripts: Gemini trains on YouTube, and CC-licensed
      talks flow into open corpora.</li>
  </ul>
</div>
<div class="layer">
  <h3><span class="lname">Layer 1: win retrieval and publish comparisons (content)</span> <span class="tag now">ship now</span></h3>

  <h4 class="cg-title">Win retrieval</h4>
  <p class="note">Why: an agent fetching a doc should get Markdown it can read. Today it gets HTML to
    scrape.</p>
  <div class="goals">#{GOALS_L1}</div>
  <ul>
    <li>Serve Markdown by content negotiation and <code>.md</code> routes
      (<code>Mime::Type.register "text/markdown", :md</code>). Plain HTTP, already used by agents, the
      durable bet. Ship llms.txt too; it is cheap.</li>
    <li>Teach <strong>rdoc</strong> to emit Markdown and content negotiation by default: one change that
      lifts every gem at once.</li>
  </ul>

  #{CONTENT_GAP}
</div>
<div class="layer">
  <h3><span class="lname">Layer 2: make agents fluent in the gems (tools)</span> <span class="tag now">ship now</span></h3>
  <div class="goals">#{GOALS_L2}</div>
  <ul>
    <li>Agree on a convention so a gem ships agent tooling (an MCP endpoint, a skill) the way it ships
      a README.</li>
    <li>Converge on one Rails MCP server: agents introspect the app (gems, versions, schema, routes)
      and pull current docs on demand.</li>
    <li>Agree on a shared Agent Skills convention so skill packs interoperate.</li>
    <li>Copy <a href="https://github.com/laravel/boost">Laravel Boost</a>: official MCP, version-pinned
      guidelines, on-demand skills. Rails has the parts
      (<a href="https://github.com/yjacquin/fast-mcp">fast-mcp</a>,
      <a href="https://tidewave.ai/">Tidewave</a>,
      <a href="https://github.com/maquina-app/rails-mcp-server">rails-mcp-server</a>, the official Ruby
      <a href="https://github.com/modelcontextprotocol/ruby-sdk">MCP SDK</a>), and a Boost-shaped bundle
      is emerging in
      <a href="https://github.com/Bakaface/rails-hyperdrive">rails-hyperdrive</a> <span class="tag new">new</span>.</li>
  </ul>
  <p class="note">Why: models know standard Rails. The gems, and anything past the training cutoff, are
    where agents guess. A convention scales the fix across that long tail.</p>
</div>
<div class="layer">
  <h3><span class="lname">Layer 3: change the training default</span> <span class="tag slow">long game</span></h3>
  <div class="goals">#{GOALS_L3}</div>
  <ul>
    <li>Contribute real Rails repos to
      <a href="https://github.com/multi-swe-bench/multi-swe-bench">Multi-SWE-bench</a> and publish an
      open idiomatic-Rails eval. Agentic benchmarks are where coding ability is now measured, Ruby is
      absent from them, and adding a language to an eval measurably lifts models on it
      (<a href="https://github.com/nuprl/MultiPL-T">MultiPL-T</a>,
      <a href="https://arxiv.org/abs/2410.18957">Bridge-Coder</a>).</li>
    <li>Grow Ruby's share of the corpus. In
      <a href="https://huggingface.co/datasets/bigcode/the-stack-v2">The Stack v2</a>, Ruby is
      ~6.8&nbsp;GB to Python's ~60, and capability tracks share. Publish an open idiomatic-Rails
      instruction dataset; contribute permissive Ruby to open corpora like
      <a href="https://huggingface.co/datasets/PleIAs/common_corpus">Common Corpus</a>.</li>
    <li>Re-run the public <a href="https://github.com/chad/whichlang">whichlang benchmark</a> on each
      new model; it is the scoreboard below.</li>
  </ul>
</div>

<div class="panel target boss">
  <p class="label">&#9733; The final boss</p>
  <p><strong>Frontier models reach for Ruby more often.</strong> One metric, fed by every layer above:
  given a free choice, 13 models picked Ruby <strong>0 times in 1,267 solutions</strong> (they default
  to Python, JavaScript, and Go). Win condition: the zero starts climbing, model after model.</p>
  <div class="goals goals--boss">#{BOSS_METERS}</div>
</div>
</section>

<section>
<h2><span class="num">04</span>Methodology</h2>
<p class="note">Probed over HTTP, June 2026, against each project's documentation URL: robots.txt parsed
for AI user-agents; crawlability fetched as CCBot, which catches WAF blocks; content negotiation asked
with <code>Accept: text/markdown</code>; <code>.md</code> routes and llms.txt checked for a 200.
The Stack v3 membership is read from the official
<a href="https://huggingface.co/spaces/HuggingFaceCode/in-the-stack">Am I in The Stack?</a> index, one
lookup per repo owner. An absence is attributed only when the reason is verified (an opt-out issue, a
repo public after the 2025-08-07 crawl cutoff) and says "not established" otherwise. The language-choice
figure is <a href="https://github.com/chad/whichlang">whichlang</a>'s: 13 models, 1,267 classified
solutions, 0 Ruby. The Rails-products table is measured in August 2026 over the GitHub API (stars,
license, workflows and their run durations, the last 50 merged PRs via GraphQL), the Software
Heritage origin API, and the same Am-I-in-The-Stack index.</p>
<p class="note"><strong>Why Common Crawl?</strong> It seeds most open web corpora (C4, FineWeb, behind
GPT and Llama), samples by domain centrality, and never copies a site in full, so coverage is a proxy for
whether a model saw the docs at all. It also reflects crawls already taken: the one column you cannot fix
this quarter, which is why Layer 0 exists. <a href="/learn#common-crawl">How it samples &rarr;</a></p>
</section>

<footer>
  <span class="label">Evil Martians</span>
  <p>Built by Evil Martians. A living scorecard: the probes re-run and the numbers move. Read more:
  <a href="/learn">how docs get into training data</a>, plus
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
