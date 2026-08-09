# frozen_string_literal: true

module Analyzer
  # "Could this text reach a model through the WEB, without being open source?"
  #
  # Two gates, and most developer documentation fails the second one:
  #
  #   1. COLLECTION. Common Crawl is centrality-sampled and never copies a domain in full, so being
  #      online is not the same as being crawled.
  #   2. QUALITY. Corpus builders discard most of what they collect. We score with FineWeb-Edu, the
  #      open classifier behind the FineWeb corpus, which keeps a document at int_score >= 3
  #      (raw >= 2.5). It was deliberately tuned toward school-level explanation and AWAY from
  #      technical reference, which is why good docs routinely score badly.
  #
  # Stated subjectivity, because the demo should be honest about it: FineWeb-Edu is a PROXY. It is
  # not the filter Claude, GPT or Gemini use, and those are undisclosed. Only the first ~512 tokens
  # are scored. Differences under ~0.3 are noise. This tells you how a representative open pipeline
  # would treat the page, not what any particular lab did.
  class WebChannel
    CDX = "https://index.commoncrawl.org"
    QUALITY_API = ENV.fetch("QUALITY_API", "https://ruby-quality-api.fly.dev/api/check")
    KEEP_BAR = 2.5

    def initialize(url) = @url = url

    def call
      { checks: [ common_crawl_check, quality_check ].compact }
    end

    # Is this exact URL in the latest crawl? Cheap and unambiguous, unlike a whole-host count.
    def common_crawl_check
      idx = latest_index
      return { name: "In Common Crawl", pass: nil, detail: "Common Crawl index unreachable right now",
               why: "The crawl index is rate-limited and occasionally down." } unless idx

      body = Http.get("#{CDX}/#{idx}-index?url=#{CGI.escape(@url)}&output=json", timeout: 45)
      found = body.is_a?(Net::HTTPSuccess) && body.body.to_s.include?("\"url\"")
      captures = body.respond_to?(:body) ? body.body.to_s.lines.count { |l| l.strip.start_with?("{") && l.include?("url") } : 0

      { name: "In Common Crawl", pass: found, index: idx,
        detail: found ? "captured #{captures}x in #{idx}" : "no captures of this URL in #{idx}",
        why: "Common Crawl seeds most open web corpora. A page it never fetched cannot reach them." }
    rescue StandardError => e
      { name: "In Common Crawl", pass: nil, detail: "check failed: #{e.message[0, 80]}", why: nil }
    end

    def quality_check
      res = Http.post_json(QUALITY_API, { url: @url }, timeout: 90)
      return { name: "Passes the quality filter", pass: nil,
               detail: "scorer unavailable", why: nil } unless res

      score = (res["score"] || res.dig("result", "score")).to_f
      keep = score >= KEEP_BAR
      { name: "Passes the quality filter", pass: keep, score: score.round(2),
        detail: "FineWeb-Edu #{score.round(2)} / 5 (keep bar #{KEEP_BAR})",
        why: "Below the bar, an open web pipeline discards the page even though it was crawled.",
        subjective: "Open proxy, not any lab's actual filter. Only the first ~512 tokens are scored; " \
                    "differences under 0.3 are noise.",
        suggestions: res["suggestions"] }
    end

    private

    def latest_index
      @latest_index ||= begin
        d = Http.json("#{CDX}/collinfo.json", timeout: 20)
        d.is_a?(Array) ? d.first["id"] : nil
      end
    end
  end
end
