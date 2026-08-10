#!/usr/bin/env ruby
# frozen_string_literal: true

# The "Rails products" table: full open-source applications built on Rails (products, as opposed
# to the gems and docs sites the main scorecard tracks). For each, two groups of facts:
#
# Code corpus -- the same code-path evidence as the main table: the license GitHub reports,
# whether Software Heritage has collected the repo (the Stack v2 collection path; the v2 checker
# space exposes no API, so SWH is the closest observable), and OBSERVED membership in The Stack
# v3 train set via the official Am-I-in-The-Stack index (same flow as stack_check.rb).
#
# RL harvest -- the mechanical filters the SWE-bench-family pipelines apply when they turn a repo
# into agentic RL training tasks (SWE-bench: issue-closing PRs that contribute tests; SWE-bench
# Multilingual: top-starred repos whose build/test commands are derivable from CI config, ~30%
# discarded for unbuildable or slow tests; Multi-SWE-bench/Multi-SWE-RL: Dockerfile-reproducible
# environments). Measured here per repo: CI workflows present, median duration of recent runs of
# the busiest workflow, a container recipe in the repo, and -- the yield proxy -- how many of the
# last 50 merged PRs close an issue AND touch a test file.
#
# Everything is observed via the GitHub API (gh, authenticated), the SWH origin API, and the
# Am-I-in-The-Stack space. On any API failure the previous answer is kept; unknown stays null,
# never a fabricated no. Writes data/products.json.

require "json"
require "open3"
require "time"

ROOT = File.expand_path("..", __dir__)
PATH = File.join(ROOT, "data", "products.json")
prev = File.exist?(PATH) ? JSON.parse(File.read(PATH)) : {}

# name, repo slug, what the product is. Rails applications only; mirrors are included and say so,
# because a mirror is exactly what the harvest pipelines see when they look at GitHub.
PRODUCTS = [
  [ "Maybe", "maybe-finance/maybe", "personal finance app" ],
  [ "Mastodon", "mastodon/mastodon", "federated social network" ],
  [ "Huginn", "huginn/huginn", "self-hosted automation agents" ],
  [ "Discourse", "discourse/discourse", "community forum" ],
  [ "Metasploit", "rapid7/metasploit-framework", "penetration-testing framework" ],
  [ "Chatwoot", "chatwoot/chatwoot", "customer support platform" ],
  [ "GitLab", "gitlabhq/gitlabhq", "DevOps platform (GitHub mirror; development on gitlab.com)" ],
  [ "Forem", "forem/forem", "community platform behind dev.to" ],
  [ "DocuSeal", "docusealco/docuseal", "document signing" ],
  [ "Postal", "postalserver/postal", "mail delivery platform" ],
  [ "OpenProject", "opf/openproject", "project management" ],
  [ "Diaspora", "diaspora/diaspora", "federated social network" ],
  [ "Fizzy", "basecamp/fizzy", "kanban board by 37signals" ],
  [ "Canvas LMS", "instructure/canvas-lms", "learning management system" ],
  [ "Redmine", "redmine/redmine", "project management (SVN mirror; patches via redmine.org)" ],
  [ "Zammad", "zammad/zammad", "helpdesk and ticketing" ],
  [ "Lago", "getlago/lago-api", "usage-based billing (the Rails API behind getlago/lago)" ]
].freeze

SPACE   = "https://huggingfacecode-in-the-stack.hf.space"
DATASET = "the-stack-v3-train"
CUTOFF  = "2025-08-07"
UA      = "ruby-scorecard/1.0 (research; https://ruby.evilmartians.com)"
TEST_RE = %r{(^|/)(test|tests|spec|specs)/|_test\.rb|_spec\.rb|\.test\.|\.spec\.}

def gh(*args)
  o, _e, st = Open3.capture3("gh", *args)
  st.success? ? o : nil
end

def gh_json(path)
  o = gh("api", path)
  o && JSON.parse(o)
rescue JSON::ParserError
  nil
end

def curl(*args)
  o, _e, st = Open3.capture3("curl", "-s", "--max-time", "90", "-A", UA, *args)
  st.success? ? o : nil
end

# --- SWH: has the archive collected this origin? (same semantics as swh_check.rb) ---
def swh_archived(slug)
  code, _e, _st = Open3.capture3("curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                                 "--max-time", "20", "-A", UA,
                                 "https://archive.softwareheritage.org/api/1/origin/https://github.com/#{slug}/get/")
  case code.strip
  when "200" then true
  when "404" then false
  end
end

# --- Am-I-in-The-Stack, one query per owner (same flow as stack_check.rb) ---
def stack_repos(owner)
  post = curl("-X", "POST", "#{SPACE}/gradio_api/call/check_username",
              "-H", "Content-Type: application/json",
              "-d", JSON.generate({ data: [ owner ] }))
  event = post && JSON.parse(post)["event_id"] rescue nil
  return nil unless event

  stream = curl("-N", "#{SPACE}/gradio_api/call/check_username/#{event}")
  data = stream&.lines&.find { |l| l.start_with?("data:") }
  return nil unless data

  payload = JSON.parse(data.sub(/\Adata:\s*/, "")) rescue nil
  return nil unless payload.is_a?(Array) && payload.first.is_a?(String)

  payload.first.scan(%r{github\.com/([\w.-]+/[\w.-]+)\)}).flatten.map(&:downcase).uniq
end

# --- RL harvest signals ---
# CI: is there a workflow that runs the test suite, and what is the median wall-clock of its
# recent successful runs? SWE-bench Multilingual derives build/test commands from exactly these
# files and discards repos whose tests are unbuildable or too slow; the median minutes is that
# filter, measured. Utility workflows (lint, stale bots, CLA, releases) are excluded on purpose:
# a pipeline needs the suite, and "Close stale issues" passing in 40 seconds says nothing.
UTILITY_RE = /lint|stale|cla|rebase|label|docker|release|deploy|publish|backport|close|codeql|
              lock|triage|sync|translat|crowdin|changelog|preview|pages|nightly/xi
TEST_NAME_RE = /\b(ci|tests?|specs?|rspec|check)\b/i

def ci_signals(slug)
  wfs = gh_json("repos/#{slug}/actions/workflows")
  wfs = wfs && wfs["workflows"]
  return { "workflows" => 0 } unless wfs&.any?

  out = { "workflows" => wfs.size }
  active = wfs.select { |w| w["state"] == "active" && !UTILITY_RE.match?(w["name"]) }
  # Test-suite workflows only, best name first; a repo whose only workflows are utilities gets a
  # count and no minutes, because timing "Dependency Graph" would dress a non-answer as a fact.
  tiers = [ /tests?|specs?|rspec/i, /\bci\b/i, /\bchecks?\b/i ]
  candidates = tiers.flat_map do |re|
    active.select { |w| re.match?(w["name"]) || re.match?(File.basename(w["path"])) }
  end.uniq
  # Among the test-named workflows, report the longest median: a path-filtered workflow whose
  # "successful" runs are skips finishes in seconds, and the suite is the long one by definition.
  best = candidates.first(3).filter_map do |w|
    runs = gh_json("repos/#{slug}/actions/workflows/#{w["id"]}/runs?status=success&per_page=10")
    runs = runs && runs["workflow_runs"]
    next unless runs&.any?

    durations = runs.filter_map do |r|
      s = Time.parse(r["run_started_at"]) rescue nil
      e = Time.parse(r["updated_at"]) rescue nil
      (e - s) / 60.0 if s && e && e > s
    end.sort
    next if durations.empty?

    [ w["name"], durations[durations.size / 2].round, durations.size ]
  end.max_by { |_, median, _| median }
  if best
    out["ci_name"], out["ci_median_min"], out["ci_runs_sampled"] = best
  end
  out
end

# Container recipe: a Dockerfile / compose file / devcontainer anywhere a pipeline would look.
def container_signals(slug)
  root = gh_json("repos/#{slug}/contents") || []
  names = root.is_a?(Array) ? root.map { |f| f["name"] } : []
  found = names.grep(/\ADockerfile|\Adocker-compose|\Acompose\.ya?ml\z|\A\.devcontainer\z/i)
  { "container" => !found.empty?, "container_files" => found.first(4) }
end

# The yield proxy: of the last 50 merged PRs, how many close an issue, and how many of those also
# touch a test file. An issue-closing, test-touching merged PR is the raw shape of one SWE-bench
# task instance (issue text -> patch -> fail-to-pass test). Mirrors take no PRs and score 0/0.
def pr_signals(slug)
  owner, name = slug.split("/")
  q = <<~GQL
    query { repository(owner: "#{owner}", name: "#{name}") {
      pullRequests(states: MERGED, last: 50) { nodes {
        mergedAt
        closingIssuesReferences(first: 1) { totalCount }
        files(first: 100) { nodes { path } }
      } } } }
  GQL
  o = gh("api", "graphql", "-f", "query=#{q}")
  return nil unless o

  nodes = JSON.parse(o).dig("data", "repository", "pullRequests", "nodes")
  return nil unless nodes

  closing = nodes.select { |n| n.dig("closingIssuesReferences", "totalCount").to_i.positive? }
  harvestable = closing.count do |n|
    (n.dig("files", "nodes") || []).any? { |f| TEST_RE.match?(f["path"]) }
  end
  merged = nodes.filter_map { |n| n["mergedAt"]&.slice(0, 10) }.sort
  { "prs_sampled" => nodes.size, "prs_closing_issue" => closing.size, "prs_harvestable" => harvestable,
    "prs_from" => merged.first, "prs_to" => merged.last }
rescue JSON::ParserError
  nil
end

stamp = Time.now.strftime("%Y-%m")
out = {}

# Phase 1: GitHub metadata + harvest signals, one product at a time.
PRODUCTS.each_with_index do |(name, slug, blurb), i|
  entry = (prev[slug] || {}).merge("name" => name, "repo" => slug, "blurb" => blurb)
  meta = gh_json("repos/#{slug}")
  if meta
    entry["stars"]       = meta["stargazers_count"]
    entry["license"]     = meta.dig("license", "spdx_id")
    entry["created"]     = meta["created_at"].to_s[0, 10]
    entry["pushed"]      = meta["pushed_at"].to_s[0, 10]
    entry["gh_archived"] = meta["archived"]
    entry["language"]    = meta["language"]
    entry["has_issues"]  = meta["has_issues"]
  end
  # Fresh signals replace the previous run's wholesale; a merge would let a stale ci_name survive
  # a run where no test workflow qualified.
  %w[ci_name ci_median_min ci_runs_sampled workflows].each { |k| entry.delete(k) }
  entry.merge!(ci_signals(slug))
  entry.merge!(container_signals(slug))
  if (pr = pr_signals(slug))
    entry.merge!(pr)
  end
  entry["checked"] = stamp
  out[slug] = entry
  warn format("  [%2d/%d] %-32s ok:%s ci:%s prs:%s", i + 1, PRODUCTS.size, slug,
              !meta.nil?, entry["ci_name"] || entry["workflows"], entry["prs_sampled"] || "-")
  sleep 0.5
end

# Phase 2: Software Heritage, one origin lookup per repo (anonymous API, ~120 req/h).
# Incremental: a known answer is kept unless --refresh, so a re-run costs only the new rows.
refresh = ARGV.include?("--refresh")
out.each_value do |entry|
  next if !refresh && !entry["swh_archived"].nil?

  archived = swh_archived(entry["repo"])
  entry["swh_archived"] = archived unless archived.nil?
  sleep 1.2
end

# Phase 3: The Stack v3 observed membership, one space query per unique owner.
owners = out.filter_map { |s, e| s.split("/").first.downcase if refresh || e["in_stack"].nil? }.uniq
listed = {}
owners.each do |owner|
  found = stack_repos(owner)
  if found.nil?
    warn "  stack check: #{owner} API failure (previous answer kept)"
  else
    listed[owner] = found
  end
  sleep 1
end
out.each do |slug, entry|
  owner = slug.split("/").first.downcase
  next unless listed.key?(owner)

  entry["in_stack"] = listed[owner].include?(slug.downcase)
  entry["stack_dataset"] = DATASET
  entry["post_cutoff"] = true if entry["in_stack"] == false && entry["created"].to_s > CUTOFF
end

out["_meta"] = { "dataset" => DATASET, "cutoff" => CUTOFF, "checked" => stamp,
                 "harvest" => "CI + container + PR linkage per the SWE-bench-family collection filters" }
File.write(PATH, JSON.pretty_generate(out))
rows = out.reject { |k, _| k.start_with?("_") }
warn "\n#{rows.size} products -> data/products.json " \
     "(#{rows.values.count { |v| v["in_stack"] }} in #{DATASET}, " \
     "#{rows.values.count { |v| v["swh_archived"] }} in SWH)"
