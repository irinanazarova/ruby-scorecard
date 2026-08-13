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

    # Pasted text is held to a lower bar than a fetched page, on purpose.
    #
    # MIN_WORDS exists because a PAGE has to be long enough to take a mid-document span: the opening
    # of any docs page is boilerplate that would match for reasons unrelated to memory. A paragraph
    # someone pasted has no boilerplate to skip past, so the only real requirement is that it can be
    # split into something to show and something to compare against.
    #
    # 30 shown and 20 compared is the floor. Below that the comparison is too short to mean
    # anything: the longest possible run would sit under the 15-word bar for half the reasons, and a
    # probe that can only ever answer "no" is worse than refusing to run.
    MIN_SEED  = 30
    MIN_TRUTH = 20
    MIN_PASTED_WORDS = MIN_SEED + MIN_TRUTH

    # Above this much HTML, a page that still yields almost no prose is client-rendered rather than
    # genuinely short, and those two cases deserve different answers.
    CLIENT_RENDERED_BYTES = 10_000

    # Share of a span that must be plain words for it to count as prose. Real documentation sits
    # near 0.9; SVG path data and minified JS sit near 0.
    PROSE_RATIO = 0.65

    # `source` is :docs or :repo. The probe now runs against both halves of the input, and a chart
    # that shows one bar per model without saying WHICH text each bar came from is unreadable: a
    # page can be absent from every corpus while its repo is reproduced word for word.
    Result = Struct.new(:ok, :error, :prefix, :truth, :source_label, :total_words, :offset, :source,
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
    def self.candidates(text, label, count: 3, prose: true)
      words = text.split
      return [ build(text, label, prose:) ] if words.length < MIN_WORDS + 200

      span = SEED_WORDS + TRUTH_WORDS
      usable = words.length - span - 10
      taken = []

      results = count.times.filter_map do |i|
        wanted = (200 + (i * (usable - 200) / [ count, 1 ].max.to_f)).to_i
        offset = prose ? nearest_prose_offset(words, wanted, span, taken) : wanted
        next if offset.nil? || offset.negative? || offset + span > words.length

        taken << offset
        Result.new(ok: true, source_label: label, total_words: words.length, offset: offset,
                   prefix: words[offset, SEED_WORDS].join(" "),
                   truth: words[offset + SEED_WORDS, TRUTH_WORDS].join(" "))
      end

      return results if results.any?
      return [ build(text, label, prose:) ] unless prose

      [ Result.new(ok: false, source_label: label, total_words: words.length,
                  error: "No prose found to test. This source is mostly markup, code or data, and " \
                         "a span of that measures nothing about whether a model read it.") ]
    end

    # Walk outward from the span we wanted until we find one that reads like prose, so a page with
    # a block of SVG or a config table in the middle still gets tested on its actual sentences
    # instead of being scored on punctuation.
    def self.nearest_prose_offset(words, wanted, span, taken, step: 25, reach: 60)
      reach.times do |i|
        [ wanted + (i * step), wanted - (i * step) ].each do |offset|
          next if offset.negative? || offset + span > words.length
          next if taken.any? { |t| (t - offset).abs < span }
          return offset if prose?(words[offset, span])
        end
      end
      nil
    end

    # Text pasted straight into the form.
    #
    # Split from the START rather than from the middle, which is the opposite of what a page gets
    # and is right for the same reason: the visitor chose these words, so there is no navigation or
    # preamble to skip past, and moving the window would test something they did not ask about.
    #
    # A long paste is treated as a document and gets several spans; a short one is a single span
    # sized to whatever is there.
    def self.candidates_from_text(text, count: 2)
      words = text.to_s.split
      return [ Result.new(ok: false, source_label: "your paragraph", total_words: words.size,
                         error: "Only #{words.size} words; the probe needs #{MIN_PASTED_WORDS}.") ] if words.size < MIN_PASTED_WORDS

      return candidates(words.join(" "), "your paragraph", count: count) if words.size >= MIN_WORDS + 200

      seed  = [ SEED_WORDS, words.size - MIN_TRUTH ].min
      truth = [ words.size - seed, TRUTH_WORDS ].min

      [ Result.new(ok: true, source_label: "your paragraph", total_words: words.size, offset: 0,
                  prefix: words.first(seed).join(" "),
                  truth: words[seed, truth].join(" ")) ]
    end

    def self.candidates_from_url(url, count: 3)
      res = Http.probe(url, timeout: 15)
      return [ Result.new(ok: false, error: "Could not fetch the page (HTTP #{res[:status] || 'error'})") ] unless res[:ok]

      text = res[:type].to_s.include?("markdown") ? strip_markdown(res[:body]) : extract_html(res[:body])

      # Client-rendered docs (WorkOS, and most React docs sites) yield almost no text to a plain
      # fetch: the same 134 words a crawler would get. When the site publishes a markdown twin, use
      # it, because that is the text an agent actually reads.
      if text.split.length < MIN_WORDS && (md = markdown_twin(url))
        return candidates(md, "#{url} (markdown twin)", count:)
      end

      # A page can miss the prose threshold two very different ways, and calling both of them
      # "short" hides the one that matters. supabase.com/docs/reference/javascript/introduction
      # returns 25 KB of HTML that is almost entirely sidebar navigation: the reference text is
      # rendered in the browser and is absent from the source. CCBot receives that same 25 KB, so
      # this is not a limit of our probe. It is the finding: a crawler cannot read the page either,
      # and text a crawler never sees cannot reach a web corpus.
      # Measured against the PASTED floor, not against MIN_WORDS. A page carrying 150 words of real
      # sentences inside 74 KB of HTML is a short page, and calling it client-rendered told
      # lefthook.dev its text was absent from its own source when the text was right there.
      words = text.split.length
      if words < MIN_PASTED_WORDS && res[:body].to_s.bytesize >= CLIENT_RENDERED_BYTES
        return [ Result.new(ok: false, source_label: url, total_words: words,
                           error: "This page returned #{(res[:body].to_s.bytesize / 1024.0).round} KB " \
                                  "of HTML but only #{words} words of prose: the text is rendered in " \
                                  "the browser and is not in the page source. A crawler fetching this " \
                                  "URL gets the same thing, so the page cannot reach a web corpus " \
                                  "either. Publish a markdown twin, or point us at the docs source " \
                                  "in your repo.") ]
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

    # prose: false is the code path. Source files are not stripped as markdown (that would eat the
    # code) and skip the prose filter, because the whole point there is to test the code itself.
    def self.candidates_from_repo_file(repo, branch, path, count: 3, prose: true)
      res = Http.probe("https://raw.githubusercontent.com/#{repo}/#{branch}/#{path}", timeout: 15)
      return [ Result.new(ok: false, error: "Could not fetch #{path}") ] unless res[:ok]

      text = prose ? strip_markdown(res[:body]) : res[:body].to_s.gsub(/\s+/, " ").strip
      candidates(text, "#{repo}/#{path}", count:, prose:)
    end

    def self.build(text, label, prose: true)
      words = text.split
      if prose && words.length >= MIN_WORDS && !prose?(words[0, MIN_WORDS])
        return Result.new(ok: false, source_label: label, total_words: words.length,
                          error: "No prose found to test. This source is mostly markup, code or " \
                                 "data, and a span of that measures nothing about whether a model " \
                                 "read it.")
      end

      return short_span(words, label, prose:) if words.length < MIN_WORDS

      offset = [ 200, words.length - SEED_WORDS - TRUTH_WORDS - 10 ].min
      Result.new(ok: true, source_label: label, total_words: words.length, offset: offset,
                 prefix: words[offset, SEED_WORDS].join(" "),
                 truth: words[offset + SEED_WORDS, TRUTH_WORDS].join(" "))
    end

    # A page too short for a full 55/60 window, sized to what is actually there.
    #
    # Refusing these was a cliff, and pages land on the wrong side of it by a hair:
    # lefthook.dev/configuration/ carries 150 words of ordinary documentation prose against a
    # threshold of 155, and the answer to "is my page in the models" came back as "not asked". Five
    # words is not the difference between a testable page and an untestable one.
    #
    # The floor is the one the pasted-paragraph path already uses, 30 shown and 20 compared, and it
    # is a real floor rather than a softer version of the same cliff: below it the longest possible
    # run sits at the STRONG_RUN bar, so the probe could only ever answer "no".
    #
    # Centred rather than started at word 0, which is the short-page version of taking a
    # mid-document span. There is no room to skip 200 words, but there is room not to open on the
    # first line, which on a docs page is a heading that repeats the title.
    def self.short_span(words, label, prose: true)
      if words.length < MIN_PASTED_WORDS
        return Result.new(ok: false, source_label: label, total_words: words.length,
                          error: "Only #{words.length} words of prose here; the probe needs " \
                                 "#{MIN_PASTED_WORDS}. Short or code-heavy pages cannot be tested " \
                                 "this way.")
      end

      seed  = [ SEED_WORDS, words.length - MIN_TRUTH ].min
      truth = [ words.length - seed, TRUTH_WORDS ].min
      offset = [ (words.length - seed - truth) / 2, 0 ].max
      span = words[offset, seed + truth]

      if prose && !prose?(span)
        return Result.new(ok: false, source_label: label, total_words: words.length,
                          error: "No prose found to test. This source is mostly markup, code or " \
                                 "data, and a span of that measures nothing about whether a model " \
                                 "read it.")
      end

      Result.new(ok: true, source_label: label, total_words: words.length, offset: offset,
                 prefix: span.first(seed).join(" "), truth: span[seed, truth].join(" "))
    end

    def self.extract_html(html)
      doc = Nokogiri::HTML(html.to_s)
      doc.css("script, style, svg, nav, header, footer, aside, noscript, pre, code, table").remove
      main = doc.at("main") || doc.at("article") || doc.at('[role="main"]') || doc.at("body")
      main.to_s.then { |h| Nokogiri::HTML(h).text }.gsub(/\s+/, " ").strip
    end

    def self.strip_markdown(md)
      md.to_s
        .sub(/\A---\n.*?\n---\n/m, "")           # front matter
        .gsub(/```.*?```/m, " ")                 # fenced code
        .gsub(%r{<svg\b.*?</svg>}mi, " ")        # inline SVG, path data and all
        .gsub(%r{<(script|style)\b.*?</\1>}mi, " ")
        .gsub(/<[^>]{1,400}>/m, " ")             # remaining HTML and JSX tags
        .gsub(/^\s*[|>#!].*$/, " ")              # tables, quotes, headings, images
        .gsub(/\[([^\]]*)\]\([^)]*\)/, '\1')     # link text, drop URLs
        .gsub(/\s+/, " ").strip
    end

    # The words English prose cannot do without. A sentence needs articles, prepositions, pronouns
    # and auxiliaries to hold it together; a navigation menu, a keyword table and a list of function
    # names need none of them, which is what makes this the sharpest available signal.
    FUNCTION_WORDS = %w[
      the a an and or but of to in for on with at by from as is are was were be been being am
      it its this that these those which who whom whose you your we our us they their them he she
      not no nor if then than when where how why what while because so such all any each both few
      can could should would will shall may might must do does did done have has had having
      there here about into over under after before between through during without within
      i me my mine yours ours theirs his her him
    ].to_set.freeze

    # Calibrated against the spans that actually got through, not guessed. Measured on four false
    # positives (a W3Schools sidebar, a SQL keyword table, a list of function names, and the ad block
    # Baeldung repeats on every page) and five known-good passages including all three pinned
    # references:
    #
    #                      function words   max repeat   capitalised
    #   false positives      0.00 - 0.24    0.06 - 0.39   0.57 - 1.00
    #   real prose           0.35 - 0.45    0.04 - 0.10   0.09 - 0.14
    #
    # Every threshold sits in the gap, and every false positive is caught by at least two of them,
    # so no single borderline measurement decides the outcome.
    MIN_FUNCTION_RATIO = 0.22   # below this there are no sentences, only labels
    MAX_REPEAT_RATIO   = 0.25   # one token owning a quarter of the span is a menu
    MAX_CAPITAL_RATIO  = 0.40   # Title Case On Every Word is a navigation bar

    # Is this span actually prose, or markup and furniture that survived stripping?
    #
    # Three failure modes, all found in production:
    #
    #   1. Markup. Resend's docs are Mintlify and its markdown twin embeds inline SVG, so the probe
    #      happily tested `d="M15.145 19.8191..."`: 55 words of path coordinates, which measures
    #      nothing. A model continuing SVG numerals is doing arithmetic-shaped autocomplete.
    #   2. Navigation. w3schools.com/sql/sql_select.asp scored a 43-word "verbatim run" that was
    #      entirely its sidebar and an alphabetical list of SQL keywords. Every token is a word, so
    #      the wordlike ratio was 1.0 and the old check waved it through. Reproducing an alphabetical
    #      list is not evidence of anything.
    #   3. Site furniture. Baeldung repeats an eBook advert on every page; a model reproducing it has
    #      memorized the template, not the article.
    #
    # Checking the SPAN rather than only the source is what makes this hold: it catches SVG, base64,
    # minified JS, config tables, hashes, menus and adverts without needing a rule for each.
    def self.prose?(words)
      return false if words.blank?

      wordlike = words.count { |w| w.match?(/\A[A-Za-z][A-Za-z'’-]*[.,;:!?)]?\z/) }
      return false if wordlike.fdiv(words.length) < PROSE_RATIO

      normalized = words.map { |w| w.downcase.gsub(/[^a-z0-9'’-]/, "") }
      return false if normalized.count { |w| FUNCTION_WORDS.include?(w) }.fdiv(words.length) < MIN_FUNCTION_RATIO
      return false if normalized.tally.values.max.fdiv(words.length) > MAX_REPEAT_RATIO

      words.count { |w| w.match?(/\A[A-Z]/) }.fdiv(words.length) <= MAX_CAPITAL_RATIO
    end
  end
end
