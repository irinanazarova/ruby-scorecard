#!/usr/bin/env ruby
# frozen_string_literal: true

# Probes every resource over HTTP (stdlib + curl, no gems) and writes data/scorecard.json.
# Checks, per resource against its DOCUMENTATION URL (not the landing page):
# robots-allows-AI, crawlable (fetch as CCBot to catch Cloudflare/WAF), sitemap,
# llms.txt (docs host + bare domain), content negotiation, .md route.

require "json"
require "uri"
require "open3"

ROOT = File.expand_path("..", __dir__)

# (name, category, docs_url) - docs_url points at the actual DOCUMENTATION, not the landing page.
RESOURCES = [
  ["Ruby (language)", "core", "https://docs.ruby-lang.org/en/master/"],
  ["Rails Guides", "core", "https://guides.rubyonrails.org/"],
  ["Rails API", "core", "https://api.rubyonrails.org/"],
  ["RubyGems Guides", "core", "https://guides.rubygems.org/"],
  ["Bundler", "core", "https://bundler.io/guides/"],
  ["RubyDoc.info", "core", "https://rubydoc.info/gems/rails"],
  ["Hotwire", "frontend & view", "https://hotwired.dev/"],
  ["Turbo", "frontend & view", "https://turbo.hotwired.dev/handbook/introduction"],
  ["Stimulus", "frontend & view", "https://stimulus.hotwired.dev/handbook/introduction"],
  ["ViewComponent", "frontend & view", "https://viewcomponent.org/guide/"],
  ["Phlex", "frontend & view", "https://www.phlex.fun/"],
  ["Ruby UI", "frontend & view", "https://rubyui.com/docs"],
  ["Inertia Rails", "frontend & view", "https://inertia-rails.dev/guide/"],
  ["Lookbook", "frontend & view", "https://lookbook.build/guide/"],
  ["Roda", "web frameworks", "https://roda.jeremyevans.net/documentation.html"],
  ["Sinatra", "web frameworks", "https://sinatrarb.com/intro.html"],
  ["Hanami", "web frameworks", "https://guides.hanamirb.org/"],
  ["Bridgetown", "web frameworks", "https://www.bridgetownrb.com/docs/"],
  ["Jekyll", "web frameworks", "https://jekyllrb.com/docs/"],
  ["Sequel", "data", "https://sequel.jeremyevans.net/documentation.html"],
  ["ROM", "data", "https://rom-rb.org/learn/"],
  ["dry-rb", "data", "https://dry-rb.org/gems/dry-validation/"],
  ["Sidekiq", "background, realtime & deploy", "https://github.com/sidekiq/sidekiq/wiki"],
  ["AnyCable", "background, realtime & deploy", "https://docs.anycable.io/"],
  ["Kamal", "background, realtime & deploy", "https://kamal-deploy.org/docs/installation/"],
  ["Sorbet", "tooling & types", "https://sorbet.org/docs/overview"],
  ["RuboCop", "tooling & types", "https://docs.rubocop.org/rubocop/"],
  ["RSpec", "tooling & types", "https://rspec.info/documentation/"],
  ["TestProf", "tooling & types", "https://test-prof.evilmartians.io/"],
  ["GraphQL Ruby", "libraries", "https://graphql-ruby.org/getting_started"],
  ["Rodauth", "libraries", "https://rodauth.jeremyevans.net/documentation.html"],
  ["Action Policy", "libraries", "https://actionpolicy.evilmartians.io/"],
  ["Shrine", "libraries", "https://shrinerb.com/docs/getting-started"],
  ["Avo", "libraries", "https://docs.avohq.io/"],
  ["ActiveAdmin", "libraries", "https://activeadmin.info/documentation.html"],
  ["Ransack", "libraries", "https://activerecord-hackery.github.io/ransack/"],
  ["Pagy", "libraries", "https://ddnexus.github.io/pagy/"],
  ["Nokogiri", "libraries", "https://nokogiri.org/tutorials/installing_nokogiri.html"],
  ["Faraday", "libraries", "https://lostisland.github.io/faraday/"],
  ["Capistrano", "libraries", "https://capistranorb.com/"],
  ["Pry", "tooling & types", "https://pry.github.io/"],
  ["Trailblazer", "libraries", "https://trailblazer.to/2.1/docs/"],
  ["Rage", "web frameworks", "https://rage-rb.dev/"],
  ["Falcon", "background, realtime & deploy", "https://socketry.github.io/falcon/guides/getting-started/index.html"],
  ["Karafka", "background, realtime & deploy", "https://karafka.io/docs/"],
  ["RubyLLM", "ai", "https://rubyllm.com/"],
  ["Brakeman", "tooling & types", "https://brakeman.org/"],
  ["imgproxy", "libraries", "https://docs.imgproxy.net/"],
  ["Vite Ruby", "frontend & view", "https://vite-ruby.netlify.app/"],
  ["Flipper", "libraries", "https://www.flippercloud.io/docs"],
  ["GoRails", "community & resources", "https://gorails.com/"],
  ["Drifting Ruby", "community & resources", "https://www.driftingruby.com/"],
  ["RubyEvents", "community & resources", "https://www.rubyevents.org/"],
  ["Rails at Scale (Shopify)", "community & resources", "https://railsatscale.com/"]
].freeze

UA = "Mozilla/5.0 research"
BOTUA = "CCBot/2.0 (+http://commoncrawl.org/faq/)"
AIB = ["*", "ccbot", "gptbot", "claudebot", "google-extended", "perplexitybot", "anthropic-ai", "applebot-extended"].freeze

def curl(args, timeout: 20)
  out, _err, _st = Open3.capture3("curl", "-sL", "--max-time", timeout.to_s, *args)
  out
rescue StandardError
  ""
end

def status(url, ua: UA)
  out = curl(["-o", "/dev/null", "-w", "%{http_code}", "-A", ua, url])
  out.strip.empty? ? "ERR" : out.strip
end

# Returns [headers, body].
def head_body(url, accept: nil, ua: UA)
  args = ["-D", "-", "-o", "/tmp/_rsc_body", "-A", ua]
  args += ["-H", "Accept: #{accept}"] if accept
  args << url
  headers = curl(args)
  body = File.exist?("/tmp/_rsc_body") ? File.read("/tmp/_rsc_body", encoding: "UTF-8", invalid: :replace, undef: :replace) : ""
  [headers, body]
end

def parse_robots(text)
  groups = Hash.new { |h, k| h[k] = [] }
  current = []
  last_was_rule = false
  text.each_line do |raw|
    line = raw.split("#", 2).first.to_s.strip
    next if line.empty? || !line.include?(":")

    field, value = line.split(":", 2)
    field = field.strip.downcase
    value = value.to_s.strip
    case field
    when "user-agent"
      current = [] if last_was_rule
      current << value.downcase
      groups[value.downcase]
      last_was_rule = false
    when "disallow", "allow"
      current.each { |ua| groups[ua] << value } if field == "disallow"
      last_was_rule = true
    end
  end
  groups
end

def root_of(url)
  u = URI.parse(url)
  port = url.match?(%r{://[^/]+:\d}) ? ":#{u.port}" : ""
  "#{u.scheme}://#{u.host}#{port}"
end

def bare_of(url)
  u = URI.parse(url)
  host = u.host.to_s
  host = host.sub(/\Awww\./, "")
  labels = host.split(".")
  bare = labels.length >= 2 ? labels.last(2).join(".") : host
  "#{u.scheme}://#{bare}"
end

def robots_ai(root)
  return ["allow", "no robots.txt (allow all)"] if status("#{root}/robots.txt") == "404"

  _headers, body = head_body("#{root}/robots.txt")
  groups = parse_robots(body)
  blocked = AIB.select { |ua| groups[ua].include?("/") }
  return ["block", "blocks all (*)"] if blocked.include?("*")
  return ["block", "blocks #{blocked.join(", ")}"] unless blocked.empty?

  ["allow", "AI crawlers allowed"]
end

def bot_fetch(root)
  code = status(root, ua: BOTUA)
  return ["ok", code] if code == "200"
  return ["block", code] if %w[403 503 429 401].include?(code)

  ["warn", code]
end

def has?(url) = status(url) == "200"

def sitemap?(root)
  return true if has?("#{root}/sitemap.xml") || has?("#{root}/sitemap_index.xml")

  _headers, body = head_body("#{root}/robots.txt")
  body.each_line.any? { |l| l.strip.downcase.start_with?("sitemap:") }
end

def content_neg?(docs_url)
  headers, _body = head_body(docs_url, accept: "text/markdown, text/html;q=0.4")
  ct = ""
  headers.each_line do |l|
    ct = l.split(":", 2)[1].to_s.strip.downcase if l.downcase.start_with?("content-type:")
  end
  ct.start_with?("text/markdown")
end

out = []
RESOURCES.each do |name, cat, docs|
  root = root_of(docs)
  bare = bare_of(docs)
  ai, note = robots_ai(root)
  bot, code = bot_fetch(root)
  llms = has?("#{root}/llms.txt") || has?("#{bare}/llms.txt")
  md = has?("#{docs.sub(%r{/\z}, "")}.md")
  row = {
    "name" => name, "category" => cat, "docs" => docs, "root" => root,
    "robots_ai" => ai, "robots_note" => note, "bot_fetch" => bot, "bot_code" => code,
    "sitemap" => sitemap?(root), "llms_txt" => llms, "content_neg" => content_neg?(docs),
    "md_route" => md, "docs_ok" => status(docs)
  }
  out << row
  printf("%-24s docs=%-3s robots=%-5s bot=%-5s sitemap=%d llms=%d neg=%d md=%d\n",
         name, status(docs), ai, bot, row["sitemap"] ? 1 : 0, llms ? 1 : 0,
         row["content_neg"] ? 1 : 0, md ? 1 : 0)
end

File.write(File.join(ROOT, "data", "scorecard.json"), JSON.pretty_generate({ "rows" => out }))
puts "DONE #{out.size}"
