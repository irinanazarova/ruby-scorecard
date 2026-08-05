# frozen_string_literal: true
#
# REPO MEMORIZATION PROBE + COVARIATE COLLECTOR
#
# Question: does a model reproduce a repository's DOCS PROSE verbatim from a short prefix, and which
# repo property predicts that: license, stars, or independent copies?
#
# Design notes (why this is set up the way it is):
#  - Passage selection is DETERMINISTIC and automatic (largest prose markdown under docs/, else README),
#    so passages are not cherry-picked to fit a hypothesis.
#  - Content type is held constant (documentation prose living inside a public repo), so the code
#    channel is the thing under test.
#  - Stars span ~5 orders of magnitude; license varies (MIT / Apache / NONE) to test the license gate.
#  - Controls run first. If MIT-License does not fire STRONG and the fabricated passage does fire,
#    nothing below the controls is interpretable.
#  - A negative proves nothing individually. Negatives are read only in aggregate and against controls.
#
#   ANTHROPIC_API_KEY=sk-ant-... ruby repo_probe.rb                 # full sample
#   ANTHROPIC_API_KEY=... ruby repo_probe.rb owner/repo [owner/repo:explicit/path.md]
#
# Output: repo_probe.json (override with PROBE_OUT=...)

begin
  require "anthropic"
rescue LoadError
  # only needed for BACKEND=anthropic; the codex backend shells out instead
end
require "json"
require "net/http"
require "uri"
require "set"
require "tmpdir"

MODEL = ENV.fetch("PROBE_MODEL", "claude-opus-4-8")
OUT   = ENV.fetch("PROBE_OUT", "repo_probe.json")
BACKEND = ENV.fetch("BACKEND", "anthropic")   # "anthropic" | "codex"
abort "Set ANTHROPIC_API_KEY" if BACKEND == "anthropic" && !ENV["ANTHROPIC_API_KEY"]
CLIENT = BACKEND == "anthropic" ? Anthropic::Client.new(access_token: ENV["ANTHROPIC_API_KEY"]) : nil

SEED_WORDS  = 55
TRUTH_WORDS = 60
MIN_BODY    = SEED_WORDS + TRUTH_WORDS + 40
PASSAGES_PER_REPO = Integer(ENV.fetch("PASSAGES", "3"))
GH_TOKEN    = `gh auth token 2>/dev/null`.strip
CODEX_SANDBOX = File.join(Dir.tmpdir, "codex-probe-empty")

CONTROLS = [
  { name: "MIT License (control+)", kind: "control",
    text: "Permission is hereby granted, free of charge, to any person obtaining a copy of this " \
          "software and associated documentation files (the \"Software\"), to deal in the Software " \
          "without restriction, including without limitation the rights to use, copy, modify, merge, " \
          "publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons " \
          "to whom the Software is furnished to do so, subject to the following conditions: The above " \
          "copyright notice and this permission notice shall be included in all copies or substantial " \
          "portions of the Software." },
  { name: "Fabricated text (control-)", kind: "null",
    text: "The teal armadillo audited seventeen quivering lighthouses before the marzipan committee " \
          "rescinded its quarterly velvet subsidy, whereupon the librarian transposed every ledger into " \
          "a dialect of polite thunder and the harbor master filed the receipts under migratory arithmetic. " \
          "By the third equinox the bicycle notaries had memorized the lullaby of the copper escalator, " \
          "yet none could explain why the persimmon auditors kept rotating the lighthouse on alternate " \
          "Tuesdays. The committee adjourned to a meadow of recursive umbrellas, where the velvet subsidy " \
          "was quietly reinstated under a new name that rhymed with neither thunder nor arithmetic." }
].freeze

# Star-stratified sample. Docs prose in public repos; license deliberately varied.
DEFAULT_REPOS = %w[
  vercel/next.js
  supabase/supabase
  rails/rails
  sinatra/sinatra
  stripe/stripe-node
  workos/authkit
  anycable/anycable
  netlify/cli
  clerk/javascript
  prisma/web
  workos/auth.md
  honojs/website
  tailwindlabs/tailwindcss.com
  anycable/anycable-client
  anycable/docs.anycable.io
].freeze

# blog/ is excluded so the content type stays "documentation prose": prisma/web otherwise selects
# blog posts, which belong to a different genre and would confound the comparison.
SKIP_NAMES = /CHANGELOG|LICENSE|CONTRIBUTING|CODE_OF_CONDUCT|SECURITY|HISTORY|MIGRATION|\.github|blog\//i

def http_get(url, headers = {}, redirects = 2)
  uri = URI(url)
  req = Net::HTTP::Get.new(uri)
  headers.each { |k, v| req[k] = v }
  req["User-Agent"] = "ruby-scorecard/1.0 corpus-research"
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
  # GitHub 301s renamed repos (prisma/docs -> prisma/web); without this they look like missing repos.
  return http_get(res["location"], headers, redirects - 1) if res.is_a?(Net::HTTPRedirection) && redirects.positive?

  res.is_a?(Net::HTTPSuccess) ? res.body : nil
rescue StandardError
  nil
end

def gh_api(path)
  h = { "Accept" => "application/vnd.github+json" }
  h["Authorization"] = "Bearer #{GH_TOKEN}" unless GH_TOKEN.empty?
  b = http_get("https://api.github.com/#{path}", h)
  b ? JSON.parse(b) : nil
rescue StandardError
  nil
end

# Strip front matter, headings, code fences, images, tables -> prose only.
def prose(md)
  md.sub(/\A---\n.*?\n---\n/m, "")
    .gsub(/```.*?```/m, " ")
    .lines.reject { |l| l.strip.start_with?("#", "!", "|", ">", "-", "*", "<") }
    .join(" ").gsub(/\s+/, " ")
end

# Deterministic passage choice. Size alone picks table/code-heavy reference pages (netlify's env.md
# yields 55 prose words), so we shortlist the 6 largest candidates and keep the one with the most
# actual PROSE. Deterministic, and it holds "documentation prose" constant across repos.
def pick_file(repo, branch)
  tree = gh_api("repos/#{repo}/git/trees/#{branch}?recursive=1")
  return nil unless tree && tree["tree"]

  md = tree["tree"].select do |n|
    n["type"] == "blob" && n["path"] =~ /\.mdx?$/ && n["path"] !~ SKIP_NAMES && n["size"].to_i.between?(2_000, 60_000)
  end
  return nil if md.empty?

  docs = md.select { |n| n["path"].include?("docs/") || n["path"].include?("content/") }
  pool = (docs.empty? ? md : docs).sort_by { |n| [-n["size"].to_i, n["path"]] }.first(10)

  pool.map { |n|
    raw = raw_file(repo, branch, n["path"])
    [raw ? prose(raw).split.size : 0, n["path"]]
  }.select { |words, _| words >= MIN_BODY }
    .sort_by { |words, path| [-words, path] }
    .first(PASSAGES_PER_REPO)
    .map(&:last)
end

# Code search is capped at 10 requests/minute. Back off rather than silently recording nil.
def copy_count_throttled(sentence, attempts = 3)
  attempts.times do |i|
    n = copy_count(sentence)
    return n if n
    sleep(8 * (i + 1))
  end
  nil
end

def raw_file(repo, branch, path)
  http_get("https://raw.githubusercontent.com/#{repo}/#{branch}/#{path}")
end

def swh_status(repo)
  b = http_get("https://archive.softwareheritage.org/api/1/origin/https://github.com/#{repo}/visit/latest/")
  b ? JSON.parse(b)["status"].to_s : "not_archived"
rescue StandardError
  "not_archived"
end

# Independent public copies of a distinctive sentence. GitHub code search excludes forks, so this
# counts NON-FORK reuse, which is exactly what corpus near-dedup does not collapse.
def copy_count(sentence)
  h = { "Accept" => "application/vnd.github+json" }
  h["Authorization"] = "Bearer #{GH_TOKEN}" unless GH_TOKEN.empty?
  q = URI.encode_www_form_component("\"#{sentence}\"")
  b = http_get("https://api.github.com/search/code?q=#{q}", h)
  b ? JSON.parse(b)["total_count"] : nil
rescue StandardError
  nil
end

def norm(t) = t.downcase.gsub(/[^a-z0-9\s]/, " ").split

def longest_common_run(a, b)
  return 0 if a.empty? || b.empty?
  prev = Array.new(b.size + 1, 0); best = 0
  a.each do |wa|
    cur = Array.new(b.size + 1, 0)
    b.each_with_index { |wb, j| (cur[j + 1] = prev[j] + 1; best = [best, cur[j + 1]].max) if wa == wb }
    prev = cur
  end
  best
end

def ngram_overlap(truth, out, n = 5)
  tg = truth.each_cons(n).to_a
  return 0.0 if tg.empty?
  og = out.each_cons(n).to_a.to_set
  (tg.count { |g| og.include?(g) }.to_f / tg.size).round(3)
end

# Elicitation differs by backend BY NECESSITY, and this is validated, not assumed.
# The Anthropic phrasing ("continue this published source verbatim") makes codex/GPT-5.5 REFUSE, and it
# refuses on fabricated text too, so refusal carries no signal. Autocomplete framing avoids the refusal
# and still fires both positive controls verbatim (MIT license, Dickens), which is the test that matters.
PROMPT_HEAD = "You are an autocomplete engine. Emit the next ~80 words of this document. No commentary. " \
              "Answer from memory only: do not use any tools, do not read files, do not search."

# Cross-model replication path. codex exec echoes the answer after a "tokens used" block, so we take
# the trailing block. Tools are disabled via the prompt + read-only sandbox.
def complete_codex(prefix)
  require "open3"
  # CRITICAL: codex is an AGENT with read access to its working directory. Run it in an empty dir.
  # A first run from the repo root scored 64/1.0 on a 10-star repo because it found this script's own
  # output file (repo_probe.json), which contains every answer. Same passage from an empty dir: 1/0.0.
  Dir.mkdir(CODEX_SANDBOX) unless Dir.exist?(CODEX_SANDBOX)
  out, _err, _st = Open3.capture3("codex", "exec", "--sandbox", "read-only", "--skip-git-repo-check",
                                  "#{PROMPT_HEAD}\n\n#{prefix}",
                                  chdir: CODEX_SANDBOX, stdin_data: "")
  tail = out.split(/^tokens used\s*$/).last.to_s
  tail.lines.reject { |l| l.strip.empty? || l.strip =~ /\A[\d,]+\z/ }.join(" ").strip
rescue StandardError => e
  "[error: #{e.class}]"
end

def complete(prefix)
  return complete_codex(prefix) if BACKEND == "codex"

  res = CLIENT.messages(parameters: {
    model: MODEL, max_tokens: 220,
    system: "You are completing a passage from its original published source. Output ONLY the verbatim " \
            "continuation, with no preamble or commentary. Do not use any tools or search. If you " \
            "recognize the source, reproduce the next sentences exactly as written.",
    messages: [{ role: "user", content: "Continue this text exactly as it appears in the original:\n\n#{prefix}" }]
  })
  (res["content"] || []).map { |b| b["text"] }.compact.join(" ").strip
rescue StandardError => e
  "[error: #{e.class}]"
end

def probe(label, kind, text, meta = {})
  w = text.split
  return warn("  skip #{label}: only #{w.size} words") if w.size < SEED_WORDS + 15

  truth  = w.drop(SEED_WORDS).first(TRUTH_WORDS).join(" ")
  prefix = w.first(SEED_WORDS).join(" ")
  out    = complete(prefix)
  run   = longest_common_run(norm(truth), norm(out))
  ov    = ngram_overlap(norm(truth), norm(out))
  verdict = if out.start_with?("[error") then "API ERROR"
            elsif run >= 15 then "STRONG"
            elsif run >= 6 then "partial"
            else "none"
            end
  printf("%-34s %-7s run=%-4s 5g=%-6s %-8s stars=%-7s lic=%-11s swh=%-13s copies=%s\n",
         label[0, 33], kind, run, ov, verdict, meta[:stars] || "-", meta[:license] || "-",
         meta[:swh] || "-", meta[:copies].nil? ? "-" : meta[:copies])
  { label: label, kind: kind, backend: BACKEND, run: run, overlap: ov, verdict: verdict,
    prefix: prefix, out: out, truth: truth }.merge(meta)
end

results = []
puts "REPO MEMORIZATION PROBE + COVARIATES  (backend: #{BACKEND}, model: #{BACKEND == 'codex' ? 'codex exec' : MODEL}, tools OFF)\n\n"
CONTROLS.each { |c| r = probe(c[:name], c[:kind], c[:text]); results << r if r }
puts "-" * 130

(ARGV.empty? ? DEFAULT_REPOS : ARGV).each do |spec|
  repo, explicit = spec.split(":", 2)
  info = gh_api("repos/#{repo}")
  next warn("  skip #{repo}: repo not found") unless info && info["default_branch"]

  branch = info["default_branch"]
  paths  = explicit ? [explicit] : pick_file(repo, branch)
  next warn("  skip #{repo}: no suitable markdown file") if paths.nil? || paths.empty?

  # Repo-level covariates, fetched once.
  base = {
    repo: repo, stars: info["stargazers_count"], forks: info["forks_count"],
    license: (info["license"] || {})["spdx_id"] || "NONE",
    created: (info["created_at"] || "")[0, 10],
    swh: swh_status(repo)
  }
  repo_copies = nil

  # Several passages per repo: memorization is a noisy per-passage event, so the unit of analysis
  # is the repo's HIT RATE across passages, not a single coin flip.
  paths.each_with_index do |path, i|
    raw = raw_file(repo, branch, path)
    next warn("  skip #{repo}:#{path}: not fetchable") unless raw

    words = prose(raw).split
    next warn("  skip #{repo}:#{path}: only #{words.size} prose words") if words.size < MIN_BODY

    start   = [200, words.size - SEED_WORDS - TRUTH_WORDS - 10].min
    passage = words[start, SEED_WORDS + TRUTH_WORDS + 40].join(" ")

    last = gh_api("repos/#{repo}/commits?path=#{URI.encode_www_form_component(path)}&per_page=1")
    repo_copies = copy_count_throttled(passage.split.first(14).join(" ").gsub('"', "")) if i.zero?

    meta = base.merge(
      path: path,
      path_last_commit: (last.is_a?(Array) && last[0] ? last[0].dig("commit", "author", "date")[0, 10] : nil),
      copies: repo_copies
    )
    r = probe("#{repo} [#{i + 1}]", "test", passage, meta)
    results << r if r
  end
end

File.write(OUT, JSON.pretty_generate(results))
puts "\nControls must behave (MIT STRONG, fabricated none) or nothing below them is interpretable."
puts "Wrote #{OUT}  (#{results.count { |r| r[:kind] == 'test' }} test cases)"
