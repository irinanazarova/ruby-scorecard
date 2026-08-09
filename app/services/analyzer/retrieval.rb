# frozen_string_literal: true

module Analyzer
  # "Can an agent find and read this page RIGHT NOW?"
  #
  # This is a different question from training-data inclusion, and conflating the two is the most
  # common mistake teams make. Everything here affects retrieval today; none of it puts you in a
  # training corpus. llms.txt in particular is widely adopted and currently used by no major AI
  # system for training or inference, so it is reported as informational rather than as a win.
  class Retrieval
    AI_BOTS = %w[CCBot GPTBot ClaudeBot Google-Extended anthropic-ai].freeze

    def initialize(url) = @url = url

    def call
      root = root_of(@url)
      robots = Http.probe("#{root}/robots.txt", timeout: 8)
      rules = parse_robots(robots[:body].to_s)

      md_negotiation = negotiates_markdown?
      md_route = markdown_route?

      {
        checks: [
          bool_check("Crawlers allowed", allows_ai?(rules),
                     detail: blocked_list(rules).empty? ? "robots.txt permits AI crawlers" :
                             "robots.txt blocks #{blocked_list(rules).join(', ')}",
                     why: "A Disallow for CCBot or ClaudeBot removes you from future crawls entirely."),
          bool_check("Reachable by a crawler", crawlable?,
                     detail: crawlable? ? "fetches cleanly as CCBot" : "blocked or unreachable as CCBot",
                     why: "A WAF or bot rule can block crawlers even when robots.txt allows them."),
          bool_check("Sitemap", sitemap?(root),
                     detail: sitemap?(root) ? "sitemap.xml found" : "no sitemap.xml",
                     why: "Crawlers reach deep pages far less often without one."),
          bool_check("Markdown content negotiation", md_negotiation,
                     detail: md_negotiation ? "serves text/markdown on Accept" : "returns HTML only",
                     why: "The durable way to hand agents clean text instead of rendered HTML."),
          bool_check("Markdown twin (.md)", md_route,
                     detail: md_route ? "#{@url}.md serves markdown" : "no .md route",
                     why: "Lets an agent fetch the source text of a page directly."),
          bool_check("llms.txt", llms_txt?(root), informational: true,
                     detail: llms_txt?(root) ? "present" : "absent",
                     why: "Popular, but no major AI system currently uses it for training or inference.")
        ]
      }
    end

    private

    def bool_check(name, pass, detail:, why:, informational: false)
      { name:, pass:, detail:, why:, informational: }
    end

    def root_of(url)
      u = URI.parse(url)
      "#{u.scheme}://#{u.host}"
    rescue StandardError
      url
    end

    # Only the AI user-agents matter here; a Disallow under a different agent is irrelevant.
    def parse_robots(text)
      rules = Hash.new { |h, k| h[k] = [] }
      agents = []
      text.each_line do |line|
        line = line.sub(/#.*/, "").strip
        next if line.empty?

        if (m = line.match(/\Auser-agent:\s*(.+)\z/i))
          agents = [ m[1].strip ]
        elsif (m = line.match(/\Adisallow:\s*(.*)\z/i))
          agents.each { |a| rules[a] << m[1].strip }
        end
      end
      rules
    end

    def blocked_list(rules)
      AI_BOTS.select do |bot|
        key = rules.keys.find { |k| k.casecmp?(bot) }
        key && rules[key].include?("/")
      end
    end

    def allows_ai?(rules) = blocked_list(rules).empty?

    def crawlable?
      @crawlable ||= Http.probe(@url, headers: { "User-Agent" => Http::CCBOT }, timeout: 12)[:ok]
    end

    def sitemap?(root)
      @sitemap ||= Http.probe("#{root}/sitemap.xml", timeout: 8)[:ok] ||
                   Http.probe("#{root}/sitemap_index.xml", timeout: 8)[:ok]
    end

    def llms_txt?(root)
      @llms ||= Http.probe("#{root}/llms.txt", timeout: 8)[:ok]
    end

    def negotiates_markdown?
      r = Http.probe(@url, headers: { "Accept" => "text/markdown" }, timeout: 10)
      r[:ok] && r[:type].to_s.include?("markdown")
    end

    def markdown_route?
      r = Http.probe("#{@url.sub(%r{/\z}, '')}.md", timeout: 10)
      r[:ok] && (r[:type].to_s.include?("markdown") || r[:type].to_s.include?("text/plain"))
    end
  end
end
