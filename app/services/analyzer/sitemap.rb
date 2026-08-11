# frozen_string_literal: true

module Analyzer
  # Finding a site's sitemap, and reading page URLs out of it.
  #
  # Two callers want different halves of this. Retrieval wants to know whether a sitemap EXISTS,
  # because a crawler follows it. The recall probe wants the URLs INSIDE it, so that a docs page
  # with no testable prose can fall back to another page on the same site instead of answering
  # "we could not test this".
  #
  # Discovery lives here rather than in each of them, because the rule is fiddly and worth having
  # once: a `Sitemap:` line in robots.txt is a global directive and takes priority over the
  # conventional paths, and a declared URL is fetched rather than trusted, since a line pointing at
  # a 404 is worse than no line.
  class Sitemap
    MAX_DECLARED = 3

    # How many <loc> entries to read. Sitemaps run to tens of thousands of URLs and we need a
    # handful, so the body is truncated rather than parsed whole.
    MAX_URLS = 200

    class << self
      # [kind, url] for each sitemap FILE we could actually retrieve, declared ones first.
      def locate(root, robots_body)
        declared = declared_in(robots_body).first(MAX_DECLARED)
                                           .select { |u| Http.probe(u, timeout: 8)[:ok] }
                                           .map { |u| [ :declared, u ] }
        return declared if declared.any?

        %w[sitemap.xml sitemap_index.xml]
          .map { |name| "#{root}/#{name}" }
          .select { |u| Http.probe(u, timeout: 8)[:ok] }
          .map { |u| [ :conventional, u ] }
      end

      # Page URLs from the first sitemap that yields any.
      #
      # Follows ONE level of sitemap index, because large docs sites almost always split by section
      # and the top-level file is then nothing but links to other sitemaps. One level, not a crawl:
      # this runs inside a request, and the point is a handful of candidates rather than coverage.
      def page_urls(root, robots_body, limit: MAX_URLS)
        locate(root, robots_body).flat_map { |(_kind, url)| urls_in(url, limit: limit) }
                                 .uniq
                                 .first(limit)
      end

      # Every `Sitemap:` line in robots.txt. A global directive: it applies to the whole file
      # regardless of which User-agent block it sits in, so it is parsed independently of the
      # Disallow rules rather than alongside them.
      def declared_in(robots_body)
        robots_body.to_s.each_line.filter_map do |line|
          m = line.sub(/#.*/, "").strip.match(/\Asitemap:\s*(\S+)\z/i)
          m && m[1]
        end.uniq
      end

      private

      def urls_in(sitemap_url, limit:, follow_index: true)
        body = Http.probe(sitemap_url, timeout: 10)[:body].to_s
        return [] if body.blank?

        locs = body.scan(%r{<loc>\s*([^<\s]+)\s*</loc>}i).flatten.first(limit)
        return locs unless follow_index && locs.all? { |u| u.match?(/\.xml(\.gz)?\z/i) } && locs.any?

        # A sitemap index: every entry is another sitemap. Read the first few rather than all of
        # them, since we only need enough URLs to find one probeable page.
        locs.first(3).flat_map { |child| urls_in(child, limit: limit, follow_index: false) }.first(limit)
      end
    end
  end
end
