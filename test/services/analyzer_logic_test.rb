# frozen_string_literal: true

require "test_helper"

# Pure-logic tests: no network, no model calls, fast.
#
# Every case here is a bug that actually shipped and was caught by hand. They exist so the same
# mistakes fail loudly next time instead of quietly producing a wrong verdict on stage.
class AnalyzerLogicTest < ActiveSupport::TestCase
  # --- license classification -------------------------------------------------------------------
  # GitHub reports NOASSERTION for every source-available licence, so classification has to read the
  # text. And the O'Saasy licence quotes the MIT grant verbatim before restricting it, which means
  # pattern ORDER is load-bearing: test permissive first and Fizzy reads as MIT.

  def classify(text) = Analyzer::CodeChannel.new("x/y").send(:classify, text)

  test "MIT text classifies as permissive" do
    assert_equal :permissive, classify("Permission is hereby granted, free of charge, to any person")
  end

  test "Apache text classifies as permissive" do
    assert_equal :permissive, classify("Apache License Version 2.0, January 2004")
  end

  test "O'Saasy classifies as source_available even though it embeds the MIT grant" do
    osaasy = "# O'Saasy License Agreement\nCopyright 2025, 37signals LLC.\n" \
             "Permission is hereby granted, free of charge, to any person obtaining a copy"
    assert_equal :source_available, classify(osaasy)
  end

  test "FSL, BUSL and SSPL classify as source_available" do
    assert_equal :source_available, classify("Functional Source License, Version 1.1, Apache 2.0 Future License")
    assert_equal :source_available, classify("Business Source License 1.1 Parameters Licensor: IBM")
    assert_equal :source_available, classify("Server Side Public License VERSION 1")
  end

  test "GPL and AGPL classify as copyleft" do
    assert_equal :copyleft, classify("GNU GENERAL PUBLIC LICENSE Version 3")
    assert_equal :copyleft, classify("GNU AFFERO GENERAL PUBLIC LICENSE Version 3")
  end

  test "a missing licence file is no_license, not unknown" do
    assert_equal :no_license, classify(nil)
  end

  test "The Stack keeps permissive AND unlicensed, drops copyleft and source-available" do
    keep = Analyzer::CodeChannel::KEPT_BY_STACK
    assert_equal true,  keep[:permissive]
    assert_equal true,  keep[:no_license], "v2/v3 keep no_license; only v1 dropped it"
    assert_equal false, keep[:copyleft]
    assert_equal false, keep[:source_available]
  end

  # --- passage selection ------------------------------------------------------------------------
  # Single-span probing produced a false negative on Tailwind for GPT-5.5, which fired on only one
  # of three spans. Sparsity is the whole reason multiple spans exist.

  test "produces several spans spread across a long document" do
    spans = Analyzer::Passage.candidates(prose_text, "t", count: 3)
    assert_equal 3, spans.size
    assert spans.all?(&:ok)
    assert_equal spans.map(&:offset), spans.map(&:offset).uniq, "spans must not overlap identically"
    assert spans.map(&:offset).each_cons(2).all? { |a, b| b > a }, "spans should advance"
  end

  test "prefix and truth do not overlap" do
    s = Analyzer::Passage.candidates(prose_text, "t", count: 1).first
    assert_equal Analyzer::Passage::SEED_WORDS, s.prefix.split.size
    assert_equal Analyzer::Passage::TRUTH_WORDS, s.truth.split.size
    # Disjoint SPANS, which is the actual property. Comparing word sets only worked on a fixture of
    # 2000 unique tokens; in real prose the same words recur in both halves without the model ever
    # having been shown the answer.
    words = prose_text.split
    assert_equal words[s.offset, Analyzer::Passage::SEED_WORDS].join(" "), s.prefix
    assert_equal words[s.offset + Analyzer::Passage::SEED_WORDS, Analyzer::Passage::TRUTH_WORDS].join(" "),
                 s.truth, "truth must start exactly where the prefix ends"
  end

  test "refuses a page with too little prose instead of guessing" do
    s = Analyzer::Passage.candidates("only a handful of words here", "t").first
    refute s.ok
    assert_match(/needs \d+/, s.error)
  end

  # --- what counts as prose ---------------------------------------------------------------------
  #
  # These four are the spans that actually got through the old wordlike-ratio check and produced
  # numbers we nearly put on a slide. Every token in a navigation bar is a word, so the ratio was
  # 1.0 and the probe happily scored a model for reproducing an alphabetical list of SQL keywords.

  NOT_PROSE = {
    "a navigation sidebar" =>
      "DB SQL Backup DB SQL Create Table SQL Drop Table SQL Alter Table SQL Constraints SQL Not " \
      "Null SQL Unique SQL Primary Key SQL Foreign Key SQL Check SQL Default SQL Create Index",
    "a keyword table" =>
      "SQL Data Types SQL Keywords ADD ADD CONSTRAINT ALL ALTER ALTER COLUMN ALTER TABLE ALTER " \
      "VIEW AND ANY AS ASC BACKUP DATABASE BETWEEN CASE CHECK COLUMN CONSTRAINT CREATE",
    "a list of function names" =>
      "LOG10 MAX MIN PI POWER RADIANS RAND ROUND SIGN SIN SQRT SQUARE SUM TAN Date Functions " \
      "CURRENT_TIMESTAMP DATEADD DATEDIFF DATEFROMPARTS DATENAME DATEPART DAY GETDATE ISDATE",
    "site-wide advertising" =>
      "Join Pro and download the eBook eBook Jackson NPI EA cat=Jackson Do JSON right with " \
      "Jackson Download the E-book eBook HTTP Client NPI EA cat=Http Client-Side Get the most"
  }.freeze

  test "furniture that is made of words is still not prose" do
    NOT_PROSE.each do |what, text|
      refute Analyzer::Passage.prose?(text.split), "#{what} was accepted as prose"
    end
  end

  # The pinned-reference half of this test went with the reference columns: there are no pinned
  # passages left to keep selectable.
  test "real prose survives the stricter test" do
    prose = "In this tutorial we will first take a look at how to enable autowiring and the " \
            "various ways to autowire beans, as well as the exceptions you can expect."
    assert Analyzer::Passage.prose?(prose.split)
  end

  # A test suite is the largest thing in plenty of well-tested repos and the last thing anyone would
  # call the project's signature code. Asked for the file stripe/stripe-node is known for, the picker
  # returned test/stripe.spec.ts.
  test "the source-file picker skips tests, fixtures and vendored code" do
    %w[test/stripe.spec.ts spec/models/user_spec.rb src/foo.test.ts __tests__/a.js
       e2e/checkout.ts vendor/jquery.js node_modules/lodash/index.js examples/demo.rb].each do |path|
      assert_match Analyzer::Run::SKIP_PATH, path, "#{path} should not be probed"
    end

    %w[lib/response.js activesupport/lib/active_support/core_ext/object/blank.rb
       src/index.ts app/services/thing.rb].each do |path|
      refute_match Analyzer::Run::SKIP_PATH, path, "#{path} is ordinary source and should be probed"
    end
  end

  # --- why a model has the text -----------------------------------------------------------------
  #
  # The count is only meaningful if the phrase we search for is a real substring of the passage. The
  # first version assembled the first eight word-like tokens found anywhere in the span, producing
  # "res.status function if 100 code throw new status": a string in no file on earth, which returned
  # zero copies for a file vendored into a million node_modules.

  # --- sitemaps ----------------------------------------------------------------------------------
  #
  # `Sitemap:` is a global directive, and it is the line CCBot follows, so the file does not have to
  # sit at /sitemap.xml. Probing only the conventional paths reported "no sitemap.xml" about
  # evilmartians.com, which declares its index at /sitemap/sitemap-index.xml, and about expressjs.com.

  def declared(robots)
    Analyzer::Retrieval.new("https://example.com/docs").send(:declared_sitemaps, robots)
  end

  test "a sitemap declared anywhere in robots.txt is found" do
    robots = <<~ROBOTS
      User-agent: *
      Disallow: /admin

      Sitemap: https://evilmartians.com/sitemap/sitemap-index.xml
    ROBOTS
    assert_equal [ "https://evilmartians.com/sitemap/sitemap-index.xml" ], declared(robots)
  end

  test "declarations are read regardless of which agent block they sit in, and comments ignored" do
    robots = <<~ROBOTS
      Sitemap: https://a.example/one.xml  # the main one
      User-agent: CCBot
      Disallow:
      sitemap: https://a.example/two.xml
      # Sitemap: https://a.example/commented-out.xml
      Sitemap: https://a.example/one.xml
    ROBOTS
    assert_equal [ "https://a.example/one.xml", "https://a.example/two.xml" ], declared(robots)
  end

  test "a robots.txt with no Sitemap line declares nothing" do
    assert_empty declared("User-agent: *\nDisallow: /private\n")
    assert_empty declared("")
  end

  test "the searched phrase is always a literal substring of the passage" do
    [ "res.status = function status(code) { if (code < 100) { throw new RangeError(\'Status code must be an integer.\') } }",
      "class Array # An array is blank if it\'s empty: # # @return [true, false] alias_method :blank?, :empty?",
      "We as members, contributors, and leaders pledge to make participation in our community a " \
      "harassment-free experience for everyone, regardless of age or body size" ].each do |text|
      phrase, = Analyzer::Copies.phrase_for(text)
      next if phrase.nil?

      assert text.include?(phrase.sub(/\A\. /, "")),
             "#{phrase.inspect} is not in the passage, so any count for it is meaningless"
    end
  end

  # A phrase we cannot vouch for is worse than none: a mangled query returns zero, and a zero beside
  # a verbatim hit reads as "nobody else has this" rather than "we could not form a query".
  test "an unsearchable passage yields no phrase rather than a misleading zero" do
    phrase, kind = Analyzer::Copies.phrase_for("}); }; ok(); => {} @x.y(&z) ||= [1,2] #=> nil ~~~ %w[]")
    assert_nil phrase
    assert_nil kind
  end

  test "prose is searched by its opening sentence and code by its most distinctive string" do
    prose = "The i18n API is primarily intended for translating user facing text within the " \
            "application, and you should use it for that purpose wherever you can."
    assert_equal :prose, Analyzer::Copies.phrase_for(prose).last

    code = "if (code < 100 || code > 999) { throw new RangeError(\'Status code must be an integer.\') }"
    assert_equal :code, Analyzer::Copies.phrase_for(code).last
  end

  test "a pinned example file wins over the picker" do
    assert_equal "lib/response.js", Analyzer::Example.pinned_file("expressjs/express")
    assert_nil Analyzer::Example.pinned_file("some/unmeasured-repo")
  end

  test "strips code fences so shared snippets cannot fake a match" do
    md = "Some prose here.\n```ruby\nputs 'npm install foo'\n```\nMore prose."
    refute_includes Analyzer::Passage.strip_markdown(md), "npm install"
  end

  # --- scoring ----------------------------------------------------------------------------------

  def mem = Analyzer::Memorization.new([])

  test "identical text scores a long run, unrelated text scores near zero" do
    a = "the quick brown fox jumps over the lazy dog and keeps on running"
    b = "completely different words about databases and networking entirely"
    assert_operator mem.send(:longest_run, mem.send(:normalize, a), mem.send(:normalize, a)), :>=, 12
    assert_operator mem.send(:longest_run, mem.send(:normalize, a), mem.send(:normalize, b)), :<=, 2
  end

  test "matched span reports the literal recalled words" do
    truth = "the quick brown fox jumps over the lazy dog"
    out   = "prefix noise the quick brown fox jumps over suffix"
    assert_equal "the quick brown fox jumps over", mem.send(:matched_span, truth, out)
  end

  test "summarize treats any firing span as a hit and counts what was tried" do
    probes = [ { run: 2, verdict: "none", offset: 0, provider: "A", cost_cents: 1.0 },
              { run: 30, verdict: "strong", offset: 500, provider: "B", cost_cents: 1.0 } ]
    s = Analyzer::Memorization.summarize(probes)
    assert_equal "strong", s[:verdict]
    assert_equal 30, s[:best_run]
    assert_equal 2, s[:spans_tested]
    assert_equal [ "B" ], s[:models_fired]
  end

  # --- target parsing ---------------------------------------------------------------------------

  test "takes the two fields separately and never fills one in from the other" do
    t = Analyzer::Target.new(docs_url: "example.com/docs", repo: "rails/rails")
    assert_equal "https://example.com/docs", t.url
    assert_equal "rails/rails", t.repo
    assert_equal :both, t.kind

    assert_equal :url, Analyzer::Target.new(docs_url: "https://example.com/docs").kind
    assert_nil Analyzer::Target.new(docs_url: "https://example.com/docs").repo,
               "a docs URL must never produce a repo"
    assert_equal :repo, Analyzer::Target.new(repo: "https://github.com/rails/rails").kind
  end

  test "names which field is wrong instead of rejecting the pair" do
    refute Analyzer::Target.new(docs_url: "not a url").valid?
    assert_match(/not a url/, Analyzer::Target.new(docs_url: "not a url").error)
    assert_match(/owner\/repo/, Analyzer::Target.new(repo: "not a slug").error)
    assert_match(/at least|Enter/i, Analyzer::Target.new.error)
  end

  # A github.com link pasted into the docs box is a misfiled repo, and running it as a web target
  # would report "not in Common Crawl" about a page that was never a page.
  test "a github link in the docs box is treated as the repo" do
    t = Analyzer::Target.new(docs_url: "https://github.com/rails/rails")
    assert_equal "rails/rails", t.repo
    assert_nil t.url
  end

  # A browser address bar hides the scheme, so the thing people actually paste is
  # `github.com/owner/repo`. That used to be rejected with "not an owner/repo slug or a github.com
  # link", which is a confusing thing to be told about a github.com link.
  test "a github link is accepted without the scheme, and with the noise around it" do
    {
      "github.com/rails/rails" => "rails/rails",
      "www.github.com/rails/rails" => "rails/rails",
      "github.com/rails/rails/" => "rails/rails",
      "github.com/rails/rails.git" => "rails/rails",
      "github.com/rails/rails/tree/main/activesupport" => "rails/rails",
      "https://github.com/rails/rails" => "rails/rails",
      "rails/rails" => "rails/rails",
      "  rails/rails  " => "rails/rails"
    }.each do |given, expected|
      t = Analyzer::Target.new(repo: given)
      assert t.valid?, "#{given.inspect} should parse: #{t.error}"
      assert_equal expected, t.repo, given.inspect
    end
  end

  # The scheme being optional must not turn every dotted string into a repo: a docs host is still a
  # docs host, and the owner side of a slug still cannot contain dots (or "example.com/docs" would
  # parse as the repo "docs" owned by "example.com").
  test "making the scheme optional does not swallow docs hosts" do
    t = Analyzer::Target.new(docs_url: "docs.example.com/page")
    assert_equal "https://docs.example.com/page", t.url
    assert_nil t.repo

    refute Analyzer::Target.new(repo: "example.com/docs").valid?
  end

  # --- a pasted paragraph -----------------------------------------------------------------------

  def paragraph(words) = (1..words).map { |i| "word#{i}" }.join(" ")

  test "a pasted paragraph is a target on its own" do
    t = Analyzer::Target.new(passage: paragraph(80))
    assert t.valid?
    assert t.passage_only?
    assert_equal :passage, t.kind
    assert_match(/80-word paragraph/, t.label)
  end

  # Below the floor the longest possible run sits under the 15-word bar, so the probe could only
  # ever answer "no". Refusing is more honest than running it.
  test "a paragraph too short to split is refused with the count" do
    t = Analyzer::Target.new(passage: paragraph(20))
    refute t.valid?
    assert_match(/20 words/, t.error)
    assert_match(/at least #{Analyzer::Passage::MIN_PASTED_WORDS}/, t.error)
  end

  # The cache key travels through logs and cache backends, so it carries a digest rather than
  # whatever the visitor pasted.
  test "the cache key digests the paragraph instead of carrying it" do
    text = paragraph(80)
    key = Analyzer::Target.new(passage: text).cache_key
    refute_includes key, "word5"
    assert_equal key, Analyzer::Target.new(passage: text).cache_key
    refute_equal key, Analyzer::Target.new(passage: paragraph(81)).cache_key
  end

  test "pasted text is split from the start, not from the middle" do
    words = (1..90).map { |i| "word#{i}" }
    span = Analyzer::Passage.candidates_from_text(words.join(" ")).first

    assert span.ok
    assert_equal 0, span.offset
    assert_equal "word1", span.prefix.split.first
    assert_equal Analyzer::Passage::SEED_WORDS, span.prefix.split.size
    assert_equal "word#{Analyzer::Passage::SEED_WORDS + 1}", span.truth.split.first,
                 "the comparison must start exactly where the prefix ends"
  end

  # A short paste still has to leave something to compare against, so the seed shrinks rather than
  # the truth vanishing.
  test "a short paragraph shrinks the seed rather than the comparison" do
    span = Analyzer::Passage.candidates_from_text(paragraph(55)).first

    assert span.ok
    assert_equal 35, span.prefix.split.size
    assert_equal Analyzer::Passage::MIN_TRUTH, span.truth.split.size
  end

  test "one box, split, still works for an old permalink" do
    assert_equal "rails/rails", Analyzer::Target.from_input("rails/rails").repo
    assert_equal "https://example.com/docs", Analyzer::Target.from_input("example.com/docs").url
  end

  # --- cache ------------------------------------------------------------------------------------

  test "cache reports hits and preserves the value" do
    Rails.cache.clear
    calls = 0
    block = -> { calls += 1; { v: 42 } }
    a = Analyzer::Cache.fetch(:unit_test, "k", &block)
    b = Analyzer::Cache.fetch(:unit_test, "k", &block)
    assert_equal 1, calls, "second call must be served from cache"
    refute a[:cache_hit]
    assert b[:cache_hit]
    assert_equal({ v: 42 }, b[:result])
    assert b[:cached_at].present?, "cached results must carry a timestamp so the UI can label them"
  end

  test "refresh bypasses the cache" do
    Rails.cache.clear
    calls = 0
    block = -> { calls += 1; { v: calls } }
    Analyzer::Cache.fetch(:unit_test, "k2", &block)
    Analyzer::Cache.fetch(:unit_test, "k2", refresh: true, &block)
    assert_equal 2, calls
  end

  # --- GitHub failures must not lie about the repo ------------------------------------------------
  # Unauthenticated GitHub allows 60 requests/hour PER IP. One Fly machine shares that across every
  # visitor, so it is routinely exhausted, and the old code reported the resulting 403 as
  # "Repo not found or private" for repos that are public.
  def reason_for(status, body = "")
    Analyzer::CodeChannel.new("anycable/docs.anycable.io")
                         .send(:failure_reason, { status: status, body: body })
  end

  test "a rate-limited GitHub response does not claim the repo is missing" do
    reason = reason_for(403, '{"message":"API rate limit exceeded for 1.2.3.4."}')
    assert_match(/rate limit/i, reason)
    assert_no_match(/not found|private/i, reason)
  end

  test "a real 404 still says the repo is missing" do
    assert_match(/not found or private/i, reason_for(404))
  end

  test "an unreachable GitHub blames the network rather than the repo" do
    reason = reason_for(nil)
    assert_match(/could not reach github/i, reason)
    assert_no_match(/not found|private/i, reason)
  end

  # --- transient failures must not be cached ------------------------------------------------------
  test "a transient result is not kept in the cache, a normal one is" do
    Rails.cache.clear

    calls = 0
    2.times do
      Analyzer::Cache.fetch(:code_channel, "https://example.com/transient") do
        calls += 1
        { present: false, reason: "GitHub rate limit reached", transient: true }
      end
    end
    assert_equal 2, calls, "a transient failure must be re-run, never served from cache"

    solid = 0
    2.times do
      Analyzer::Cache.fetch(:code_channel, "https://example.com/solid") do
        solid += 1
        { present: false, reason: "Repo not found or private: a/b" }
      end
    end
    assert_equal 1, solid, "a settled answer should still cache"
  end

  # --- prose filtering --------------------------------------------------------------------------
  # Resend's markdown twin embeds inline SVG. Stripping missed it and the probe tested
  # `d="M15.145 19.8191..."` against a model: 55 words of path coordinates measure nothing.

  SVG_BLOB = ('<path d="M34.4522 33.2528C34.4522 33.2528 35.7597 34.2935 33.0122 35.0986C27.7878 ' \
              '36.6275 11.2676 37.0892 6.67835 35.1596Z" strokeWidth="0.2" strokeLinejoin="round" /> ' * 40)

  test "SVG path data is not prose" do
    assert_not Analyzer::Passage.prose?(SVG_BLOB.split)
    assert Analyzer::Passage.prose?(prose_text.split.first(120))
  end

  test "strip_markdown removes inline SVG and JSX tags" do
    md = "Real sentences here. #{SVG_BLOB} More real sentences follow."
    out = Analyzer::Passage.strip_markdown(md)
    assert_not out.include?("strokeWidth"), "SVG attributes survived stripping"
    assert out.include?("Real sentences here.")
  end

  test "a span lands on prose even when markup sits where we wanted to sample" do
    words = prose_text.split
    contaminated = (words.first(250) + SVG_BLOB.split + words.drop(250)).join(" ")
    span = Analyzer::Passage.candidates(contaminated, "t", count: 1).first
    assert span.ok, "should have found prose elsewhere rather than giving up"
    assert Analyzer::Passage.prose?(span.prefix.split), "picked a span that is not prose"
  end

  test "a source that is entirely markup is refused rather than scored" do
    span = Analyzer::Passage.candidates(SVG_BLOB * 4, "t").first
    assert_not span.ok
    assert_match(/no prose/i, span.error)
  end

  # Repo mode must be able to answer "is my CODE in the training set". Refusing because code is not
  # prose is refusing the question the user asked.
  test "code spans skip the prose filter" do
    code = (1..400).map { |i| "def method_#{i}(arg); @cache[arg] ||= compute(arg); end" }.join(" ")
    span = Analyzer::Passage.candidates(code, "repo/file.rb", count: 1, prose: false).first
    assert span.ok, "code should be testable when prose: false"
    assert_equal Analyzer::Passage::SEED_WORDS, span.prefix.split.size
  end

  private

  # Realistic prose: the filter exists precisely to reject synthetic token soup like "word1 word2",
  # so a fixture made of that would be refused, correctly.
  def prose_text
    sentence = "The crawler fetches a page and stores the response body for later analysis, " \
               "and the classifier then scores that text for educational value before any of it " \
               "reaches a training corpus at all."
    ([ sentence ] * 60).join(" ")
  end
end
