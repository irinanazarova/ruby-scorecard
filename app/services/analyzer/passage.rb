# frozen_string_literal: true

require "nokogiri"

module Analyzer
  # Extracts the exact text we will test, and shows its work.
  #
  # Passage choice is the part everyone gets wrong. Three rules, each of which changes the answer:
  #
  #   1. Take a MID-document span, not the opening. Every docs page opens with boilerplate and nav,
  #      and an intro that reads like every other intro will "match" for reasons unrelated to memory.
  #   2. Strip code fences. Snippets are duplicated across thousands of repos, so a model reproducing
  #      `npm install foo` tells you nothing about whether it read YOUR page.
  #   3. Prefer prose. A table of config flags cannot be continued from memory by anyone.
  class Passage
    SEED_WORDS  = 55   # what the model sees
    TRUTH_WORDS = 60   # what we compare against, never shown to the model
    MIN_WORDS   = SEED_WORDS + TRUTH_WORDS + 40

    Result = Struct.new(:ok, :error, :prefix, :truth, :source_label, :total_words, :offset,
                        keyword_init: true)

    def self.from_url(url)
      res = Http.probe(url, timeout: 15)
      return Result.new(ok: false, error: "Could not fetch the page (HTTP #{res[:status] || 'error'})") unless res[:ok]

      text = res[:type].to_s.include?("markdown") ? strip_markdown(res[:body]) : extract_html(res[:body])
      build(text, url)
    end

    def self.from_repo_file(repo, branch, path)
      res = Http.probe("https://raw.githubusercontent.com/#{repo}/#{branch}/#{path}", timeout: 15)
      return Result.new(ok: false, error: "Could not fetch #{path}") unless res[:ok]

      build(strip_markdown(res[:body]), "#{repo}/#{path}")
    end

    # Several spans spread across the document, not one.
    #
    # Memorization is SPARSE: in our 168-repo study only about 1 passage in 3 fired even for repos
    # that are demonstrably in training data. Testing a single span therefore reports "not
    # memorized" for plenty of pages that are, which is the most misleading answer this tool could
    # give. Spreading the attempts is the difference between a coin flip and a fair test.
    def self.candidates(text, label, count: 3)
      words = text.split
      return [build(text, label)] if words.length < MIN_WORDS + 200

      span = SEED_WORDS + TRUTH_WORDS
      usable = words.length - span - 10
      count.times.filter_map do |i|
        offset = (200 + (i * (usable - 200) / [count, 1].max.to_f)).to_i
        next if offset.negative? || offset + span > words.length

        Result.new(ok: true, source_label: label, total_words: words.length, offset: offset,
                   prefix: words[offset, SEED_WORDS].join(" "),
                   truth: words[offset + SEED_WORDS, TRUTH_WORDS].join(" "))
      end.presence || [build(text, label)]
    end

    def self.candidates_from_url(url, count: 3)
      res = Http.probe(url, timeout: 15)
      return [Result.new(ok: false, error: "Could not fetch the page (HTTP #{res[:status] || 'error'})")] unless res[:ok]

      text = res[:type].to_s.include?("markdown") ? strip_markdown(res[:body]) : extract_html(res[:body])

      # Client-rendered docs (WorkOS, and most React docs sites) yield almost no text to a plain
      # fetch: the same 134 words a crawler would get. When the site publishes a markdown twin, use
      # it, because that is the text an agent actually reads.
      if text.split.length < MIN_WORDS && (md = markdown_twin(url))
        return candidates(md, "#{url} (markdown twin)", count:)
      end

      candidates(text, url, count:)
    end

    # Both conventions: Accept negotiation, then the .md route.
    def self.markdown_twin(url)
      neg = Http.probe(url, headers: { "Accept" => "text/markdown" }, timeout: 12)
      return strip_markdown(neg[:body]) if neg[:ok] && neg[:type].to_s.include?("markdown")

      route = Http.probe("#{url.sub(%r{/\z}, '')}.md", timeout: 12)
      return strip_markdown(route[:body]) if route[:ok] && route[:type].to_s.match?(/markdown|text\/plain/)

      nil
    end

    def self.candidates_from_repo_file(repo, branch, path, count: 3)
      res = Http.probe("https://raw.githubusercontent.com/#{repo}/#{branch}/#{path}", timeout: 15)
      return [Result.new(ok: false, error: "Could not fetch #{path}")] unless res[:ok]

      candidates(strip_markdown(res[:body]), "#{repo}/#{path}", count:)
    end

    def self.build(text, label)
      words = text.split
      if words.length < MIN_WORDS
        return Result.new(ok: false, source_label: label, total_words: words.length,
                          error: "Only #{words.length} words of prose here; the probe needs #{MIN_WORDS}. " \
                                 "Short or code-heavy pages cannot be tested this way.")
      end

      offset = [200, words.length - SEED_WORDS - TRUTH_WORDS - 10].min
      Result.new(ok: true, source_label: label, total_words: words.length, offset: offset,
                 prefix: words[offset, SEED_WORDS].join(" "),
                 truth: words[offset + SEED_WORDS, TRUTH_WORDS].join(" "))
    end

    def self.extract_html(html)
      doc = Nokogiri::HTML(html.to_s)
      doc.css("script, style, nav, header, footer, aside, noscript, pre, code, table").remove
      main = doc.at("main") || doc.at("article") || doc.at('[role="main"]') || doc.at("body")
      main.to_s.then { |h| Nokogiri::HTML(h).text }.gsub(/\s+/, " ").strip
    end

    def self.strip_markdown(md)
      md.to_s
        .sub(/\A---\n.*?\n---\n/m, "")          # front matter
        .gsub(/```.*?```/m, " ")                 # fenced code
        .gsub(/^\s*[|>#!].*$/, " ")              # tables, quotes, headings, images
        .gsub(/\[([^\]]*)\]\([^)]*\)/, '\1')     # link text, drop URLs
        .gsub(/\s+/, " ").strip
    end
  end
end
