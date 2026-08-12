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
      signal = ContentSignal.parse(robots[:body])

      {
        # Two lists of plain strings rather than the parsed hash. Payloads make a round trip through
        # as_json and come back deep-symbolized, which would turn "ai-train" into :"ai-train" and
        # leave every reader quoting a symbol. Array values survive that trip unchanged.
        content_signal: { declined: signal.declined, granted: signal.granted },
        checks: [
          bool_check("Crawlers allowed", allows_ai?(rules),
                     detail: crawlers_detail(rules, signal),
                     why: "A Disallow for CCBot or ClaudeBot removes you from future crawls entirely."),
          bool_check("Reachable by a crawler", crawlable?,
                     detail: crawlable? ? "fetches cleanly as CCBot" : "blocked or unreachable as CCBot",
                     why: "A WAF or bot rule can block crawlers even when robots.txt allows them."),
          bool_check("Sitemap", sitemap(root, robots[:body]).any?,
                     detail: sitemap_detail(root, robots[:body]),
                     why: "CCBot reads the sitemap declared in robots.txt, so a listed URL can be found " \
                          "without an inbound link. It does not decide what gets fetched: Common Crawl " \
                          "prioritises by harmonic centrality."),
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

    # Permission to FETCH and permission to USE, in one line, because robots.txt now carries both
    # and a site can grant the first while declining the second. The `pass` above stays keyed to the
    # fetch: a Content-Signal line blocks no request, so calling it a failed check would be wrong.
    def crawlers_detail(rules, signal)
      blocked = blocked_list(rules)
      return "robots.txt blocks #{blocked.join(', ')}" if blocked.any?
      return "robots.txt permits AI crawlers" unless signal.present?
      return "robots.txt permits the fetch, Content-Signal declines #{signal.declined.join(', ')}" if
        signal.declined.any?

      "robots.txt permits AI crawlers, Content-Signal grants #{signal.granted.join(', ')}"
    end

    def crawlable?
      @crawlable ||= Http.probe(@url, headers: { "User-Agent" => Http::CCBOT }, timeout: 12)[:ok]
    end

    # A sitemap DECLARED IN robots.txt counts, and counts first.
    #
    # `Sitemap:` is a global directive in the robots.txt standard, and it is the one CCBot follows,
    # so a site that declares its index anywhere is doing the thing that matters. Probing only
    # /sitemap.xml and /sitemap_index.xml failed anyone who files theirs elsewhere:
    # evilmartians.com declares `Sitemap: https://evilmartians.com/sitemap/sitemap-index.xml` and we
    # reported "no sitemap.xml" about a site with a perfectly good one.
    #
    # The declared URL is FETCHED rather than trusted. A line pointing at a 404 is worse than no
    # line, because it reads as done to anyone auditing the file by eye.
    # Discovery moved to Analyzer::Sitemap, because the recall probe needs the same rule to read
    # page URLs out of the file when a docs page yields no testable prose. Memoized here: this check
    # asks twice, once for the verdict and once for the detail line.
    def sitemap(root, robots_body)
      @sitemap ||= Sitemap.locate(root, robots_body)
    end

    def sitemap_detail(root, robots_body)
      found = sitemap(root, robots_body)
      kind, url = found.first
      return "declared in robots.txt: #{url}" if kind == :declared
      return "#{url.split('/').last} found" if kind == :conventional

      declared = Sitemap.declared_in(robots_body)
      return "robots.txt declares #{declared.first}, which does not fetch" if declared.any?

      "no sitemap.xml, and robots.txt declares none"
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
