#!/usr/bin/env ruby
# frozen_string_literal: true

# For each resource whose docs live in a public repo (data/repos.json -> docs_repo), asks the
# official "Am I in The Stack?" checker whether that repo is ACTUALLY in The Stack v3 train set
# (huggingface.co/spaces/HuggingFaceCode/in-the-stack). This replaces license-based guessing with
# an observed fact: the space queries the train set's own repo list, so file-level ScanCode
# decisions we cannot reproduce are already baked into the answer. karafka/wiki is the cautionary
# example: its LICENSE.md says "All Rights Reserved", yet the repo is in the train set.
#
# The Stack v3 is a direct GitHub crawl (GH Archive + the Software Heritage graph) with a cutoff
# of 2025-08-07, so SWH archival is no longer the collection gate it was for v2. A repo created
# after the cutoff is absent no matter what its license says; we record that reason separately
# so the page never blames a license for a timing gap.
#
# One query per unique repo OWNER (the space looks up by username and returns every repo of
# theirs in the set), so ~90 resources cost ~60 requests. Polite: serial, a sleep between calls.
# On an API failure the previous answer is kept; unknown stays "not checked", never a made-up no.
#
# Writes data/stack.json. Incremental by default; --refresh re-checks everything (quarterly).

require "json"
require "open3"

ROOT = File.expand_path("..", __dir__)
repos = JSON.parse(File.read(File.join(ROOT, "data", "repos.json")))
path = File.join(ROOT, "data", "stack.json")
out = File.exist?(path) ? JSON.parse(File.read(path)) : {}

SPACE   = "https://huggingfacecode-in-the-stack.hf.space"
DATASET = "the-stack-v3-train"
CUTOFF  = "2025-08-07"
UA      = "ruby-scorecard/1.0 (research; https://ruby.evilmartians.com)"

def curl(*args)
  o, _e, st = Open3.capture3("curl", "-s", "--max-time", "90", "-A", UA, *args)
  st.success? ? o : nil
end

# The space is a Gradio app: POST the username, then stream the result by event id. The reply is
# Markdown listing every repo of that owner in the train set; absence of the owner is a definite
# "no repos", but a transport/parse failure is unknown and must not be recorded as anything.
def repos_in_stack(owner)
  post = curl("-X", "POST", "#{SPACE}/gradio_api/call/check_username",
              "-H", "Content-Type: application/json",
              "-d", JSON.generate({ data: [ owner ] }))
  event = post && JSON.parse(post)["event_id"] rescue nil
  return nil unless event

  stream = curl("-N", "#{SPACE}/gradio_api/call/check_username/#{event}")
  return nil unless stream

  data = stream.lines.find { |l| l.start_with?("data:") }
  return nil unless data

  payload = JSON.parse(data.sub(/\Adata:\s*/, "")) rescue nil
  return nil unless payload.is_a?(Array) && payload.first.is_a?(String)

  md = payload.first
  # "**No**, ..." with no links is a real answer: none of this owner's repos are in the set.
  md.scan(%r{github\.com/([\w.-]+/[\w.-]+)\)}).flatten.map(&:downcase).uniq
end

# Only consulted for repos NOT in the set, to tell "created after the crawl cutoff" apart from
# "crawled and excluded". gh is authenticated locally (5,000 req/h); anonymous curl would burn
# the shared 60/h that the live checker also needs.
def repo_created(slug)
  o, _e, st = Open3.capture3("gh", "api", "repos/#{slug}", "--jq", ".created_at")
  st.success? ? o.strip[0, 10] : nil
rescue StandardError
  nil
end

refresh = ARGV.include?("--refresh")
stamp = Time.now.strftime("%Y-%m")

wanted = {}
repos.each do |name, rp|
  slug = rp["docs_repo"]&.downcase
  next unless slug
  next if !refresh && out.dig(name, "in_stack") != nil && out.dig(name, "repo") == rp["docs_repo"]

  wanted[name] = rp["docs_repo"]
end

owners = wanted.values.map { |s| s.downcase.split("/").first }.uniq
warn "#{wanted.size} resources to check across #{owners.size} owners"

listed = {}
owners.each_with_index do |owner, i|
  found = repos_in_stack(owner)
  if found.nil?
    warn format("  [%2d/%d] %-20s API failure (previous answers kept)", i + 1, owners.size, owner)
  else
    listed[owner] = found
    warn format("  [%2d/%d] %-20s %d repos in the set", i + 1, owners.size, owner, found.size)
  end
  sleep 1
end

wanted.each do |name, slug|
  owner = slug.downcase.split("/").first
  next unless listed.key?(owner) # API failure: keep whatever stack.json had

  hit = listed[owner].include?(slug.downcase)
  entry = { "repo" => slug, "in_stack" => hit, "dataset" => DATASET, "checked" => stamp }
  unless hit
    created = repo_created(slug)
    entry["created"] = created if created
    entry["post_cutoff"] = true if created && created > CUTOFF
  end
  out[name] = entry
end

out["_meta"] = { "dataset" => DATASET, "cutoff" => CUTOFF,
                 "source" => "#{SPACE} (official checker backed by the train set repo list)" }
File.write(path, JSON.pretty_generate(out))
answered = out.reject { |k, _| k.start_with?("_") }
hits = answered.values.count { |v| v["in_stack"] }
warn "\n#{answered.size} resources; #{hits} in #{DATASET}, #{answered.size - hits} not -> data/stack.json"
