# frozen_string_literal: true

# For each scorecard resource, find its GitHub repo and verify the license, so we can tell which
# resources reach code-training corpora (The Stack) via a permissive license, bypassing the web gates.
#
# Signals, in order: (1) docs/root host of the form <owner>.github.io/<repo>; (2) github.com/<owner>/<repo>
# links found in the docs+root HTML (most-linked wins); then `gh api repos/<owner>/<repo>` for the license.
# Writes data/repos.json. Run: ruby scripts/find_repos.rb   (needs `gh` authenticated)

require "json"
require "open-uri"
require "uri"
require "set"

ROOT = File.expand_path("..", __dir__)
rows = JSON.parse(File.read(File.join(ROOT, "data", "scorecard.json")))["rows"]

# The Stack keeps permissive + no-license only; copyleft is excluded. (SPDX ids.)
PERMISSIVE = %w[MIT MIT-0 Apache-2.0 BSD-2-Clause BSD-3-Clause BSD-3-Clause-Clear ISC 0BSD Unlicense
                Zlib MPL-2.0 Ruby BSL-1.0 Artistic-2.0 CC0-1.0 WTFPL].to_set
COPYLEFT = %w[GPL-2.0 GPL-3.0 GPL-2.0-only GPL-2.0-or-later GPL-3.0-only GPL-3.0-or-later
              LGPL-2.1 LGPL-3.0 AGPL-3.0 AGPL-3.0-only AGPL-3.0-or-later].to_set

GENERIC = %w[sponsors login join features about pricing topics collections trending marketplace
             apps site security customer-stories readme orgs settings notifications].to_set

def fetch(url)
  URI.parse(url).open("User-Agent" => "ruby-scorecard/1.0", read_timeout: 15, open_timeout: 8).read
rescue StandardError
  nil
end

def repo_from_host(url)
  u = URI.parse(url)
  if u.host&.end_with?(".github.io")
    owner = u.host.sub(".github.io", "")
    seg = u.path.split("/").reject(&:empty?).first
    return "#{owner}/#{seg}" if seg && !seg.empty? && owner != "github"
  end
  nil
rescue StandardError
  nil
end

def repos_from_html(html)
  return {} unless html
  tally = Hash.new(0)
  html.scan(%r{github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)}) do |owner, repo|
    repo = repo.sub(/\.git\z/, "").sub(/[#?].*\z/, "")
    next if GENERIC.include?(owner.downcase) || repo.empty? || repo.downcase == "readme"
    tally["#{owner}/#{repo}"] += 1
  end
  tally
end

def gh_license(slug)
  out = `gh api repos/#{slug} --jq '{full:.full_name,license:.license.spdx_id,archived:.archived,stars:.stargazers_count}' 2>/dev/null`
  return nil if out.strip.empty?
  JSON.parse(out)
rescue StandardError
  nil
end

out = {}
rows.each_with_index do |r, i|
  name = r["name"]
  cands = Hash.new(0)
  [repo_from_host(r["docs"]), repo_from_host(r["root"])].compact.each { |s| cands[s] += 5 }
  [r["docs"], r["root"]].compact.uniq.each do |u|
    repos_from_html(fetch(u)).each { |s, n| cands[s] += n }
  end
  picked = cands.max_by { |_, n| n }&.first
  info = picked ? gh_license(picked) : nil
  # If the picked repo 404s, try the next candidate.
  if picked && info.nil?
    cands.sort_by { |_, n| -n }.each do |s, _|
      next if s == picked
      info = gh_license(s)
      (picked = s; break) if info
    end
  end
  lic = info && info["license"]
  perm = lic && PERMISSIVE.include?(lic)
  cls = if info.nil? then "no_repo_found"
        elsif lic.nil? || lic == "NOASSERTION" then "unknown_license"
        elsif perm then "permissive"
        elsif COPYLEFT.include?(lic) then "copyleft"
        else "other_license"
        end
  out[name] = { "repo" => info && info["full"], "license" => lic, "class" => cls,
                "stars" => info && info["stars"], "archived" => info && info["archived"] }
  warn format("  [%2d/%d] %-22s %-26s %-14s %s", i + 1, rows.size, name[0, 22],
              out[name]["repo"] || "(no repo)", lic || "-", cls)
end

File.write(File.join(ROOT, "data", "repos.json"), JSON.pretty_generate(out))
counts = out.values.group_by { |v| v["class"] }.transform_values(&:size)
warn "\n#{out.size} resources. #{counts.inspect}"
warn "-> data/repos.json (review and correct edge cases before using)"
