# frozen_string_literal: true

module Analyzer
  # Why a model has this text: how many independent public repositories carry the same words.
  #
  # This is the mechanism the funnel names as its connector, measured rather than asserted. In our
  # own 168-repo study the number of COPIES of a passage predicted verbatim recall (Spearman
  # rho +0.70, permutation p=0.005) while stars did not (rho +0.28, p=0.31). So when the probe fires,
  # this is the first thing worth showing: not "a model memorized you" but "this text is in N places,
  # which is what memorization tracks".
  #
  # GitHub code search EXCLUDES forks, which is what makes the count meaningful: it counts
  # independent reuse, the kind corpus near-dedup does not collapse into one representative.
  #
  # WHAT IT DOES NOT MEASURE: duplication anywhere but public code. A page copied across a thousand
  # blogs scores zero here. So a zero is reported as "none found in public code", never as "this
  # text is unique" — the search covers one channel and the UI has to say which.
  class Copies
    CACHE_TTL = 7.days

    # count is nil when the search could not be run at all, which is a fact about our rate limit and
    # never about the text.
    # `transient` marks a search that could not run, so Cache drops it instead of storing "unknown"
    # for a week.
    Result = Struct.new(:count, :repos, :phrase, :kind, :search_url, :transient, keyword_init: true)

    # Only explain a run that actually means something. Below the weak bar there is no recall to
    # attribute, and the code-search endpoint allows ten requests a minute across the whole app.
    MIN_RUN = Memorization::PARTIAL_RUN

    class << self
      def for(text, refresh: false)
        phrase, kind = phrase_for(text)
        return nil if phrase.blank?

        Cache.fetch(:copies, Digest::SHA256.hexdigest(phrase)[0, 32], ttl: CACHE_TTL, refresh: refresh) do
          search(phrase, kind)
        end[:result]
      end

      # The phrase to search for, which has to differ by what kind of text this is.
      #
      # The study quoted the first fourteen words, and that works for prose. On CODE it returns zero
      # every time: a long string full of braces, dots and operators matches nothing, and the zero
      # reads as "nobody else has this" about a file vendored into a million node_modules. Measured
      # on one Express passage: the fourteen-word phrase scored 0, the error message inside it scored
      # 314, and a single line of it scored 972.
      def phrase_for(text)
        words = text.to_s.split
        return [ nil, nil ] if words.size < 8

        # Prose first, then code, and the SAME quality gate on both. Gating only the code branch was
        # not enough: a Ruby source file thick with doc comments passes the prose test, took the
        # fourteen-word branch, and produced "end def request(&block) @requestor.request(&block)" as
        # a query. A phrase we cannot vouch for is worse than none, because searching for a mangled
        # fragment returns zero and a zero next to a verbatim hit reads as "nobody else has this".
        if Passage.prose?(words.first(60))
          candidate = words.first(14).join(" ").delete('"')
          return [ candidate, :prose ] if clean_query?(candidate)
        end

        candidate = code_phrase(text)
        return [ nil, nil ] unless candidate && clean_query?(candidate)

        [ candidate, :code ]
      end

      # The query has to be mostly letters, digits and spaces to stand a chance in the code index.
      def clean_query?(phrase)
        phrase.count("A-Za-z0-9 ").fdiv(phrase.length) >= 0.9 && phrase.split.size >= 5
      end

      private

      # For code, the most distinctive short thing available: a string literal if the span has one,
      # since those are written once and copied verbatim wherever the file goes.
      #
      # Whatever comes out MUST be a literal substring of the text. The first version assembled the
      # first eight word-like tokens found anywhere in the span, which produced
      # "res.status function if 100 code throw new status" — a phrase that appears in no file on
      # earth, and duly returned zero copies for a file vendored into a million node_modules.
      def code_phrase(text)
        candidates = text.to_s.scan(/["'`]([^"'`\n]{20,140})["'`]/).flatten

        # Interpolation is written differently in every copy, so a phrase containing `${...}` or
        # `#{...}` matches nothing. Keep the longest stretch on either side of it instead.
        # Backticks delimit string literals in JavaScript and markdown code fences in Ruby comments,
        # and the scan cannot tell them apart. blank.rb yielded "ruby # false.blank? # => true #",
        # a fence fragment that matches nothing. Requiring the candidate to be mostly letters and
        # spaces keeps real sentences and drops fences, operators and punctuation soup.
        literal = candidates.flat_map { |s| s.split(/[$#]\{[^}]*\}/) }
                            .map(&:strip)
                            .select { |s| s.length >= 20 && s.split.size >= 4 && Passage.prose?(s.split) }
                            .max_by(&:length)
        return literal.delete('"') if literal

        # No literal: the longest unbroken stretch of ordinary words. Matched rather than split, so
        # apostrophes survive and the result is still a literal substring — splitting on punctuation
        # turned "An array is blank if it's empty" into "An array is blank if it s empty", which
        # appears in no file anywhere.
        run = text.to_s.scan(/[A-Za-z0-9'’ ]{25,}/).map(&:strip)
                  .select { |s| s.split.size >= 6 && Passage.prose?(s.split) }
                  .max_by { |s| s.split.size }
        run&.split&.first(12)&.join(" ")
      end

      def search(phrase, kind)
        res = Http.json("https://api.github.com/search/code?q=#{CGI.escape("\"#{phrase}\"")}&per_page=5",
                        headers: Http.github_headers)
        # A missing body means the search did not run: unauthenticated, rate limited, or down.
        # Reported as unknown, because a zero here would be read as a finding about the text.
        return Result.new(count: nil, repos: [], phrase: phrase, kind: kind,
                          search_url: search_url(phrase), transient: true).to_h unless res

        repos = Array(res["items"]).filter_map do |item|
          name = item.dig("repository", "full_name") or next

          { name: name, url: "https://github.com/#{name}" }
        end.uniq { |r| r[:name] }

        Result.new(count: res["total_count"], repos: repos, phrase: phrase, kind: kind,
                   search_url: search_url(phrase)).to_h
      rescue StandardError => e
        Rails.logger.warn("[copies] #{e.class}: #{e.message}")
        nil
      end

      def search_url(phrase)
        "https://github.com/search?type=code&q=#{CGI.escape("\"#{phrase}\"")}"
      end
    end
  end
end
