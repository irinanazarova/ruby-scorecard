#!/usr/bin/env ruby
# frozen_string_literal: true

# For each resource whose docs live in a public repo (data/repos.json -> docs_repo), asks the
# Software Heritage archive whether it has collected that repo. The Stack v2/v3 are built from
# the SWH archive, so a permissive license only reaches the code corpus if SWH actually holds
# the repo. Writes data/swh.json (separate file, so probe.rb never clobbers it).
#
# Polite by construction: single serial thread, a sleep between calls, a descriptive User-Agent.
# The anonymous SWH API is rate-limited (~120 req/hour); one origin lookup per unique repo fits
# in a run. On a 429 or outage the script stops and preserves known answers; unknown values stay
# "not checked", never a fabricated no.

require "json"
require "open3"

ROOT = File.expand_path("..", __dir__)
repos = JSON.parse(File.read(File.join(ROOT, "data", "repos.json")))
path = File.join(ROOT, "data", "swh.json")
out = File.exist?(path) ? JSON.parse(File.read(path)) : {}

UA = "ruby-scorecard/1.0 (research; https://ruby.evilmartians.com)"

def swh_status(slug)
  url = "https://archive.softwareheritage.org/api/1/origin/https://github.com/#{slug}/get/"
  code, _err, _st = Open3.capture3("curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                                   "--max-time", "20", "-A", UA, url)
  code.strip
rescue StandardError
  "ERR"
end

# By default only fill in repos we have no answer for, so adding one resource costs one request
# instead of re-spending the whole hourly allowance and 429-ing before it reaches the new entry.
# Pass --refresh for the quarterly full re-check.
refresh = ARGV.include?("--refresh")

cache = {}
stamp = Time.now.strftime("%Y-%m")
i = 0
repos.each do |name, rp|
  slug = rp["docs_repo"]
  next unless slug
  next if !refresh && out.dig(name, "archived") != nil && out.dig(name, "repo") == slug

  i += 1
  unless cache.key?(slug)
    cache[slug] = swh_status(slug)
    sleep 1.2
  end
  code = cache[slug]
  case code
  when "200"
    out[name] = { "repo" => slug, "archived" => true, "checked" => stamp }
    note = "archived"
  when "404"
    out[name] = { "repo" => slug, "archived" => false, "checked" => stamp }
    note = "NOT archived"
  when "429"
    warn "rate limited at #{slug}; stopping here (known answers preserved)"
    break
  else
    note = "HTTP #{code} (kept previous answer)"
  end
  warn format("  [%2d] %-24s %-32s %s", i, name[0, 24], slug, note)
end

File.write(path, JSON.pretty_generate(out))
archived = out.values.count { |v| v["archived"] }
warn "\n#{out.size} resources checked; #{archived} archived, #{out.size - archived} missing -> data/swh.json"
