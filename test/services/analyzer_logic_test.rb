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
