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

  # --- repo inference from a hostname -----------------------------------------------------------
  # Taking the first label sent docs.anycable.io to a GitHub user called "docs".

  def org_label(host)
    Analyzer::Run.new("https://example.com").send(:org_label, host)
  end

  test "strips known doc subdomains" do
    assert_equal "anycable", org_label("docs.anycable.io")
    assert_equal "stripe",   org_label("api.stripe.com")
    assert_equal "workos",   org_label("workos.com")
    assert_equal "hoppscotch", org_label("www.hoppscotch.io")
  end

  test "handles two-part TLDs" do
    assert_equal "example", org_label("docs.example.co.uk")
  end

  # --- passage selection ------------------------------------------------------------------------
  # Single-span probing produced a false negative on Tailwind for GPT-5.5, which fired on only one
  # of three spans. Sparsity is the whole reason multiple spans exist.

  test "produces several spans spread across a long document" do
    text = (1..2000).map { |i| "word#{i}" }.join(" ")
    spans = Analyzer::Passage.candidates(text, "t", count: 3)
    assert_equal 3, spans.size
    assert spans.all?(&:ok)
    assert_equal spans.map(&:offset), spans.map(&:offset).uniq, "spans must not overlap identically"
    assert spans.map(&:offset).each_cons(2).all? { |a, b| b > a }, "spans should advance"
  end

  test "prefix and truth do not overlap" do
    text = (1..2000).map { |i| "word#{i}" }.join(" ")
    s = Analyzer::Passage.candidates(text, "t", count: 1).first
    assert_equal Analyzer::Passage::SEED_WORDS, s.prefix.split.size
    assert_equal Analyzer::Passage::TRUTH_WORDS, s.truth.split.size
    assert (s.prefix.split & s.truth.split).empty?, "the model must not be shown the answer"
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
    probes = [{ run: 2, verdict: "none", offset: 0, provider: "A", cost_cents: 1.0 },
              { run: 30, verdict: "strong", offset: 500, provider: "B", cost_cents: 1.0 }]
    s = Analyzer::Memorization.summarize(probes)
    assert_equal "strong", s[:verdict]
    assert_equal 30, s[:best_run]
    assert_equal 2, s[:spans_tested]
    assert_equal ["B"], s[:models_fired]
  end

  # --- target parsing ---------------------------------------------------------------------------

  test "accepts urls, github urls and owner/repo slugs" do
    assert_equal :repo, Analyzer::Target.new("https://github.com/rails/rails").kind
    assert_equal "rails/rails", Analyzer::Target.new("rails/rails").repo
    assert_equal :url, Analyzer::Target.new("https://example.com/docs").kind
    assert_equal "https://example.com/docs", Analyzer::Target.new("example.com/docs").url
    refute Analyzer::Target.new("not a url").valid?
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
end
