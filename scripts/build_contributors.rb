#!/usr/bin/env ruby
# frozen_string_literal: true

# Renders data/contributors.json -> dist/contributors.html in the Evil Martians design system.
# A companion to the scorecard: the top Ruby open-source contributors (US + worldwide) and the
# actively-maintained top Ruby projects with their maintainers. Server-rendered; app.js only adds
# the theme toggle and stat counters. No personal emails are published (public profile data only).

require "json"
require "cgi"
require "digest"
require "fileutils"
require_relative "site_nav"

ROOT = File.expand_path("..", __dir__)
data = JSON.parse(File.read(File.join(ROOT, "data", "contributors.json")))
US = data["us"]
WORLD = data["worldwide"]
PROJECTS_ACT = data["projectsByActivity"]
PROJECTS_STAR = data["projectsByStars"]
POOL = data["pool"]
REPO_COUNT = data["repoCount"]
REPO_DESCS = data["repoDescriptions"] || {}

DIST = File.join(ROOT, "dist")
FileUtils.mkdir_p(DIST)
%w[favicon.svg favicon.ico apple-touch-icon.png].each do |f|
  src = File.join(ROOT, "src", "assets", f)
  FileUtils.cp(src, File.join(DIST, f)) if File.exist?(src)
end

def esc(str) = CGI.escapeHTML(str.to_s)
def commate(num) = num.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse

def asset_q(rel)
  path = File.join(ROOT, "dist", rel)
  File.exist?(path) ? "?v=#{Digest::MD5.file(path).hexdigest[0, 8]}" : ""
end

# Curated 2-4 word descriptions for the projects table (crisper than GitHub blurbs).
SHORT_DESC = {
  "rails/rails" => "Web app framework", "jekyll/jekyll" => "Static site generator",
  "mastodon/mastodon" => "Federated social network", "huginn/huginn" => "Automation agents",
  "hashicorp/vagrant" => "Dev environment manager", "Homebrew/brew" => "macOS package manager",
  "discourse/discourse" => "Community discussion forum", "fastlane/fastlane" => "Mobile release automation",
  "freeCodeCamp/devdocs" => "API docs browser", "rapid7/metasploit-framework" => "Penetration testing",
  "chatwoot/chatwoot" => "Customer support desk", "gitlabhq/gitlabhq" => "DevOps platform",
  "heartcombo/devise" => "Rails authentication", "ruby/ruby" => "The Ruby language",
  "forem/forem" => "Community platform", "docusealco/docuseal" => "Document e-signing",
  "postalserver/postal" => "Mail delivery platform", "spree/spree" => "eCommerce platform",
  "opf/openproject" => "Project management", "CocoaPods/CocoaPods" => "Cocoa dependency manager",
  "basecamp/kamal" => "Container deployment", "tmuxinator/tmuxinator" => "tmux session manager",
  "diaspora/diaspora" => "Distributed social network", "github-linguist/linguist" => "Repo language detection",
  "fluent/fluentd" => "Unified logging layer", "sidekiq/sidekiq" => "Background job processing",
  "capistrano/capistrano" => "Deployment automation", "rubocop/rubocop" => "Ruby linter & formatter",
  "sinatra/sinatra" => "Web microframework", "ubicloud/ubicloud" => "Open-source cloud",
  "Shopify/liquid" => "Template language", "faker-ruby/faker" => "Fake data generator",
  "jordansissel/fpm" => "Package builder", "teamcapybara/capybara" => "Acceptance testing",
  "ruby-grape/grape" => "REST API framework", "activeadmin/activeadmin" => "Rails admin framework",
  "wpscanteam/wpscan" => "WordPress security scanner", "Freika/dawarich" => "Location history tracker",
  "resque/resque" => "Background jobs", "antiwork/gumroad" => "Creator commerce platform",
  "we-promise/sure" => "Personal finance app", "ankane/pghero" => "Postgres performance dashboard",
  "javan/whenever" => "Cron in Ruby", "carrierwaveuploader/carrierwave" => "File uploads",
  "chef/chef" => "Infrastructure automation", "thoughtbot/factory_bot" => "Test data factories",
  "basecamp/fizzy" => "Kanban board", "realm/jazzy" => "Swift/ObjC docs",
  "puma/puma" => "Rack web server", "flyerhzm/bullet" => "N+1 query detector",
  "presidentbeef/brakeman" => "Rails security scanner", "paper-trail-gem/paper_trail" => "Model change tracking",
  "ankane/searchkick" => "Search made easy", "instructure/canvas-lms" => "Learning management system",
  "ankane/chartkick" => "One-line charts", "hanami/hanami" => "Ruby web framework",
  "norman/friendly_id" => "Pretty URL slugs", "midudev/autoskills" => "AI skill installer",
  "vcr/vcr" => "HTTP test recording", "github/markup" => "Markup rendering",
  "redmine/redmine" => "Project tracker", "lostisland/faraday" => "HTTP client library",
  "ruby-concurrency/concurrent-ruby" => "Concurrency toolkit", "zammad/zammad" => "Helpdesk & support",
  "CanCanCommunity/cancancan" => "Authorization gem", "danger/danger" => "Code-review automation",
  "dependabot/dependabot-core" => "Dependency update bot", "sferik/x-cli" => "Twitter/X CLI",
  "doorkeeper-gem/doorkeeper" => "OAuth 2 provider", "rmosolgo/graphql-ruby" => "GraphQL server",
  "slim-template/slim" => "Template language", "solidusio/solidus" => "eCommerce framework",
  "drapergem/draper" => "View decorators", "rspec/rspec-rails" => "Rails testing",
  "rails/thor" => "CLI toolkit", "aasm/aasm" => "State machines",
  "cucumber/cucumber-ruby" => "BDD testing", "asciidoctor/asciidoctor" => "Text processor",
  "shakacode/react_on_rails" => "React + Rails SSR", "rack/rack" => "Web server interface",
  "jeremyevans/sequel" => "Database toolkit", "mbleigh/acts-as-taggable-on" => "Rails tagging",
  "ddnexus/pagy" => "Pagination library", "opal/opal" => "Ruby-to-JavaScript compiler",
  "simplecov-ruby/simplecov" => "Code coverage", "prawnpdf/prawn" => "PDF generation",
  "lolcommits/lolcommits" => "Commit selfies", "ankane/blazer" => "SQL business intelligence",
  "red-data-tools/YouPlot" => "Terminal plotting", "lobsters/lobsters" => "Link aggregator",
  "SteveLTN/https-portal" => "Automated HTTPS proxy", "sferik/twitter-ruby" => "Twitter API client",
  "TheOdinProject/theodinproject" => "Coding curriculum", "octobox/octobox" => "GitHub notifications manager",
  "seyhunak/twitter-bootstrap-rails" => "Bootstrap for Rails", "ankane/ahoy" => "First-party analytics",
  "sparklemotion/mechanize" => "Web scraping", "ankane/strong_migrations" => "Safe DB migrations",
  "rails/jbuilder" => "JSON API builder", "basecamp/once-campfire" => "Group chat"
}.freeze

def repo_short(full) = SHORT_DESC[full] || ""

# ---- searchable key for a contributor / project row (drives the client-side filter) ----
def csearch(c)
  [ c["name"], c["login"], c["location"], c["company"],
   c["repos"].map { |r| r["repo"] }.join(" ") ].compact.join(" ").downcase
end

def clinks(c)
  out = []
  out << %(<a href="#{esc(c["website"])}" rel="nofollow noopener">#{esc(url_host(c["website"]))}</a>) if c["website"]
  out << %(<a href="https://twitter.com/#{esc(c["twitter"])}" rel="nofollow noopener">@#{esc(c["twitter"])}</a>) if c["twitter"]
  out.empty? ? %(<span class="dim">&mdash;</span>) : out.join(%(<span class="dim"> &middot; </span>))
end

def url_host(url)
  url.to_s.sub(%r{\Ahttps?://}, "").sub(%r{\Awww\.}, "").sub(%r{/.*\z}, "")
end

def projects_cell(c)
  items = c["repos"].map do |r|
    d = REPO_DESCS[r["repo"]].to_s
    desc = d.empty? ? "" : %(<span class="pd" title="#{esc(d)}">#{esc(d)}</span>)
    %(<li><a class="pl-name" href="https://github.com/#{esc(r["repo"])}" rel="nofollow noopener">#{esc(r["repo"])}</a>#{desc}<span class="pc">#{commate(r["commits"])}</span></li>)
  end
  items << %(<li class="pl-more">+#{c["moreRepos"]} more</li>) if c["moreRepos"].to_i.positive?
  %(<ul class="plist">#{items.join}</ul>)
end

def contributor_row(c)
  total = c["commits"] > c["rubyCommits"] ? %(<span class="sub">#{commate(c["commits"])} total</span>) : ""
  <<~ROW
    <tr data-name="#{esc(csearch(c))}">
      <td class="rank">#{c["rank"]}</td>
      <td class="lft who"><a href="https://github.com/#{esc(c["login"])}" rel="nofollow noopener">#{esc(c["name"] || c["login"])}</a><span class="sub">@#{esc(c["login"])}</span></td>
      <td class="lft">#{esc(c["location"] || "—")}</td>
      <td class="lft">#{c["company"] ? esc(c["company"]) : %(<span class="dim">&mdash;</span>)}</td>
      <td class="commits">#{commate(c["rubyCommits"])}#{total}</td>
      <td class="lft">#{projects_cell(c)}</td>
      <td class="lft links">#{clinks(c)}</td>
    </tr>
  ROW
end

# Catch bot maintainers that the upstream filter missed (e.g. "jekyllbot", not just "[bot]").
BOT_RE = /(\[bot\]|bot$|-bot$|_bot$|^bot-|automation$|^ci-|-ci$|robot)/i

def maintainers_cell(p)
  maints = p["maintainers"].reject { |m| BOT_RE.match?(m["login"].to_s) }
  return %(<span class="dim">&mdash;</span>) if maints.empty?

  maints.map do |m|
    label = esc(m["name"] || m["login"])
    co = m["company"] ? %(<span class="dim"> &middot; #{esc(m["company"])}</span>) : ""
    %(<span class="maint"><a href="https://github.com/#{esc(m["login"])}" rel="nofollow noopener">#{label}</a>#{co}</span>)
  end.join
end

def project_row(p)
  key = [ p["full"], p["desc"], p["maintainers"].map { |m| "#{m["name"]} #{m["login"]} #{m["company"]}" }.join(" ") ].join(" ").downcase
  <<~ROW
    <tr data-name="#{esc(key)}">
      <td class="rank">#{p["rank"]}</td>
      <td class="lft who"><a href="https://github.com/#{esc(p["full"])}" rel="nofollow noopener">#{esc(p["full"])}</a><span class="sub">#{esc(p["desc"])}</span></td>
      <td class="commits">#{commate(p["commits2026"])}</td>
      <td class="commits">#{commate(p["stars"])}</td>
      <td class="lft maints">#{maintainers_cell(p)}</td>
    </tr>
  ROW
end

US_ROWS = US.map { |c| contributor_row(c) }.join
WORLD_ROWS = WORLD.map { |c| contributor_row(c) }.join
ACT_ROWS = PROJECTS_ACT.map { |p| project_row(p) }.join
STAR_ROWS = PROJECTS_STAR.map { |p| project_row(p) }.join

# A tab group: a bar of tabs + one shared search box, over N panels each holding a table.
# tabs = [[panel_id, label], ...]; panels = { panel_id => html }. The first tab is active.
def tab_group(group, tabs, count, panels)
  buttons = tabs.each_with_index.map do |(id, label), i|
    %(<button class="tab" role="tab" data-tab="#{id}" aria-selected="#{i.zero?}">#{label}</button>)
  end.join
  body = tabs.each_with_index.map do |(id, _), i|
    %(<div class="tabpanel" data-panel="#{id}"#{i.zero? ? "" : " hidden"}>#{panels[id]}</div>)
  end.join
  <<~TG
    <div class="tabwrap" data-tabgroup="#{group}">
      <div class="tabbar" role="tablist">
        #{buttons}
        <input class="controls__search tab-search" type="search" placeholder="Filter&hellip;" aria-label="Filter this table">
        <span class="controls__count tab-count">#{count} shown</span>
      </div>
      #{body}
    </div>
  TG
end

def people_table(id, rows)
  <<~TBL
    <div class="table-scroll">
    <table id="#{id}">
      <thead><tr>
        <th class="rank">#</th>
        <th class="lft">Contributor</th>
        <th class="lft">Location</th>
        <th class="lft">Company</th>
        <th class="commits">Ruby<br>commits</th>
        <th class="lft">Top projects (2026 commits)</th>
        <th class="lft">Links</th>
      </tr></thead>
      <tbody>#{rows}</tbody>
    </table>
    </div>
  TBL
end

def project_table(id, rows)
  <<~TBL
    <div class="table-scroll">
    <table id="#{id}">
      <thead><tr>
        <th class="rank">#</th>
        <th class="lft">Project</th>
        <th class="commits">2026<br>commits</th>
        <th class="commits">Stars</th>
        <th class="lft">Most active maintainers (12 mo) &middot; affiliation</th>
      </tr></thead>
      <tbody>#{rows}</tbody>
    </table>
    </div>
  TBL
end

PAGE = <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Top Ruby Open Source Contributors &amp; Projects, 2026</title>
<meta name="description" content="Who builds Ruby's open source: the top contributors (US and worldwide) ranked by 2026 Ruby-first commits, and the actively-maintained top Ruby projects with their maintainers. Built from the GitHub API by Evil Martians.">
<script>(function(){try{var t=localStorage.getItem('rsc-theme');if(t)document.documentElement.dataset.theme=t;}catch(e){}})();</script>
<link rel="icon" type="image/svg+xml" href="favicon.svg#{asset_q("favicon.svg")}">
<link rel="icon" sizes="32x32" href="favicon.ico">
<link rel="apple-touch-icon" href="apple-touch-icon.png">
<link rel="stylesheet" href="assets/styles.css#{asset_q("assets/styles.css")}">
<script type="module" src="assets/app.js#{asset_q("assets/app.js")}"></script>
<style>
  td.lft, th.lft { text-align: left; }
  td.rank, th.rank { text-align: right; font-family: var(--font-mono); color: var(--text-soft); font-size: .82em; width: 1%; white-space: nowrap; }
  td.commits, th.commits { text-align: right; font-family: var(--font-mono); font-weight: 700; white-space: nowrap; }
  th.commits { font-weight: 600; }
  .who a { font-weight: 600; text-decoration: none; color: var(--text); }
  .who a:hover { color: var(--link); text-decoration: underline; }
  .who .sub { text-transform: none; letter-spacing: 0; }
  .commits .sub { text-align: right; font-weight: 400; text-transform: none; letter-spacing: 0; }
  .dim { color: var(--text-soft); }
  .links a { font-family: var(--font-mono); font-size: .78em; }
  .plist { list-style: none; margin: 0; padding: 0; max-width: 380px; }
  .plist li { display: flex; align-items: baseline; gap: .5rem; line-height: 1.45; padding: .04rem 0; }
  .pl-name { font-family: var(--font-mono); font-size: .74rem; font-weight: 600; text-decoration: none; color: var(--text); white-space: nowrap; }
  .pl-name:hover { color: var(--accent); text-decoration: underline; }
  .pd { flex: 1 1 auto; min-width: 0; color: var(--text-soft); font-size: .78rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .pc { font-family: var(--font-mono); font-size: .72rem; font-weight: 700; color: var(--accent); margin-left: auto; }
  .pl-more { color: var(--text-soft); font-family: var(--font-mono); font-size: .68rem; }
  .maints .maint { display: block; font-size: .84em; line-height: 1.5; }
  .maints a { color: var(--text); text-decoration: none; font-weight: 600; }
  .maints a:hover { color: var(--link); text-decoration: underline; }
  .tabbar { display: flex; gap: .5rem; align-items: center; flex-wrap: wrap; margin: 1.4rem 0 .9rem; }
  .tab { font-family: var(--font-mono); font-size: .66rem; text-transform: uppercase; letter-spacing: .07em; font-weight: 600; color: var(--text-soft); background: var(--bg-warm); border: 1px solid var(--line-strong); border-radius: 100px; padding: .5em 1.1em; cursor: pointer; transition: all .15s; }
  .tab:hover { border-color: var(--accent); color: var(--text); }
  .tab[aria-selected="true"] { background: var(--accent); border-color: var(--accent); color: #fff; }
  .tab-search { flex: 1 1 220px; margin-left: .4rem; }
  .tab-count { font-family: var(--font-mono); font-size: .68rem; letter-spacing: .04em; color: var(--text-soft); white-space: nowrap; }
  .tabpanel[hidden] { display: none; }
  tr[hidden] { display: none; }
</style>
</head>
<body>
#{site_nav(toggle: true)}
<header class="hero">
  <div class="wrap">
    <p class="kicker label">Evil Martians &middot; Ruby</p>
    <h1>Ruby open source: who builds it</h1>
    <p class="lede"><strong>A snapshot of Ruby's open-source engine in 2026.</strong> We scanned
    #{commate(REPO_COUNT)} repositories where Ruby is the dominant language and ranked every 2026
    contributor by their <strong>Ruby-first commits</strong>, plus the top-starred, actively-maintained
    projects. A companion to the <a href="/">discoverability scorecard</a>.</p>
    <div class="stats">
      <stat-counter class="stat" value="#{REPO_COUNT}" total="0"><b class="stat__num" data-ref="num">#{commate(REPO_COUNT)}</b><span>Ruby-first repos scanned</span></stat-counter>
      <stat-counter class="stat" value="#{POOL}" total="0"><b class="stat__num" data-ref="num">#{commate(POOL)}</b><span>contributors ranked</span></stat-counter>
      <stat-counter class="stat" value="#{PROJECTS_ACT.size}" total="0"><b class="stat__num" data-ref="num">#{PROJECTS_ACT.size}</b><span>active projects tracked</span></stat-counter>
    </div>
  </div>
</header>

<main class="wrap">

<section id="contributors">
<h2><span class="num">01</span>Top contributors</h2>
<p class="note">Ranked by <strong>Ruby-first commits</strong> in 2026 (commits in repos where Ruby is the
dominant language by bytes). The <strong>US</strong> tab is filtered to self-reported US locations, ~40% of
profiles leave location blank, so it under-counts Americans who don't fill it in; <strong>Worldwide</strong>
is everyone. Where someone also has non-Ruby-first commits, the &ldquo;N&nbsp;total&rdquo; subline shows the
larger figure.</p>
#{tab_group("people", [ [ "t-us", "US-based" ], [ "t-world", "Worldwide" ] ], US.size,
            { "t-us" => people_table("t-us", US_ROWS), "t-world" => people_table("t-world", WORLD_ROWS) })}
</section>

<section id="projects">
<h2><span class="num">02</span>Top Ruby projects</h2>
<p class="note"><strong>By commits</strong> &mdash; top Ruby-first repos by number of commits in 2026.<br>
<strong>By stars</strong> &mdash; top Ruby-first repos by stars, with commits in the last 90 days.</p>
#{tab_group("projects", [ [ "t-proj-act", "By commits" ], [ "t-proj-star", "By stars" ] ], PROJECTS_ACT.size,
            { "t-proj-act" => project_table("t-proj-act", ACT_ROWS), "t-proj-star" => project_table("t-proj-star", STAR_ROWS) })}
</section>

</main>

<footer class="wrap">
  <span class="label">Evil Martians</span>
  <p>Built by Evil Martians from the public GitHub API, #{esc(data["generated"])}. A companion to the
  <a href="/">Ruby &amp; Rails LLM discoverability scorecard</a>.</p>
  <img class="lurker" src="favicon.svg#{asset_q("favicon.svg")}" alt="" aria-hidden="true" width="44" height="44">
</footer>

<script>
  // Tabbed tables with a shared filter (progressive enhancement: no JS = every panel visible).
  document.querySelectorAll('[data-tabgroup]').forEach(function (group) {
    var tabs = Array.prototype.slice.call(group.querySelectorAll('.tab'));
    var panels = Array.prototype.slice.call(group.querySelectorAll('.tabpanel'));
    var search = group.querySelector('.tab-search');
    var count = group.querySelector('.tab-count');
    var active = tabs[0].dataset.tab;
    function apply() {
      var table = document.getElementById(active);
      if (!table) return;
      var q = (search.value || '').trim().toLowerCase();
      var shown = 0;
      Array.prototype.forEach.call(table.tBodies[0].rows, function (tr) {
        var hit = !q || tr.dataset.name.indexOf(q) !== -1;
        tr.hidden = !hit;
        if (hit) shown++;
      });
      count.textContent = shown + ' shown';
    }
    tabs.forEach(function (t) {
      t.addEventListener('click', function () {
        active = t.dataset.tab;
        tabs.forEach(function (x) { x.setAttribute('aria-selected', x === t ? 'true' : 'false'); });
        panels.forEach(function (p) { p.hidden = (p.dataset.panel !== active); });
        apply();
      });
    });
    search.addEventListener('input', apply);
    apply();
  });
</script>
</body>
</html>
HTML

File.write(File.join(DIST, "contributors.html"), PAGE)
puts "wrote dist/contributors.html | us #{US.size} world #{WORLD.size} projects #{PROJECTS_ACT.size}/#{PROJECTS_STAR.size}"
