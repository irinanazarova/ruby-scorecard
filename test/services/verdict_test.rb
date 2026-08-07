# frozen_string_literal: true

require "test_helper"

# The headline is the one thing every visitor reads, so its honesty rules get tests of their own.
# The four detail boxes can afford a caveat in small print; a wrong word at the top of the page
# cannot be walked back.
class VerdictTest < ActiveSupport::TestCase
  def verdict(payloads, status: "running")
    Analyzer::Verdict.new(payloads, status: status)
  end

  def step(result) = { result: result }

  def retrieval(allowed: true, reachable: true, md: false, negotiation: false, sitemap: true)
    step(checks: [
           { name: "Crawlers allowed", pass: allowed, detail: allowed ? "robots.txt permits AI crawlers" : "robots.txt blocks CCBot" },
           { name: "Reachable by a crawler", pass: reachable, detail: "" },
           { name: "Sitemap", pass: sitemap, detail: "" },
           { name: "Markdown content negotiation", pass: negotiation, detail: "" },
           { name: "Markdown twin (.md)", pass: md, detail: "" },
           { name: "llms.txt", pass: true, informational: true, detail: "" }
         ])
  end

  def web(crawled: true, quality: true, score: 3.1)
    step(checks: [
           { name: "In Common Crawl", pass: crawled, detail: "" },
           { name: "Passes the quality filter", pass: quality, score: score, detail: "" }
         ])
  end

  def code(present: true, swh: true, kept: true, repo: "acme/docs")
    step(present: present, repo: repo, swh_archived: swh, kept_by_stack: kept,
         license_class: kept == false ? :copyleft : :permissive, checks: [])
  end

  def memorized(verdict, best_run: 30, models: ["Claude Opus"])
    step(summary: { verdict: verdict, best_run: best_run, models_fired: models,
                    spans_tested: 3, probes: 9 })
  end

  # --- question 1 -------------------------------------------------------------------------------

  test "a blocked crawler is a no, whatever else the page does right" do
    a = verdict({"retrieval" => retrieval(allowed: false, md: true)}).retrieval_answer
    assert_equal :no, a.tone
    assert_match(/robots\.txt/, a.headline)
  end

  test "reachable without a markdown route is a qualified yes, not a clean one" do
    a = verdict({"retrieval" => retrieval}).retrieval_answer
    assert_equal :mixed, a.tone
    assert_match(/rendered HTML/, a.headline)
  end

  test "a markdown twin makes it a clean yes" do
    a = verdict({"retrieval" => retrieval(md: true)}).retrieval_answer
    assert_equal :yes, a.tone
    assert_equal :pass, a.cues.find { |c| c.label == "clean text for agents" }.status
  end

  # --- question 2: the honesty rules ------------------------------------------------------------

  test "no recall is never phrased as absence from the training data" do
    a = verdict({"code_channel" => code, "web_channel" => web(crawled: false),
                "memorization" => memorized("none")}).training_answer

    refute_match(/not in the training data/i, "#{a.headline} #{a.detail}")
    assert_match(/no model reproduced it/i, a.headline)
    assert_match(/the code path is open/i, a.headline, "the headline names the open route")
    assert_match(/weak evidence/i, a.caveat)
  end

  test "a closed door plus no recall is the only case that reads as a no" do
    a = verdict({"code_channel" => code(present: false), "web_channel" => web(crawled: false),
                "memorization" => memorized("none")}).training_answer
    assert_equal :no, a.tone
    assert_match(/unlikely/i, a.headline)
  end

  # The GitHub rate limit is a fact about our server. Reported as "no repo" it would turn a
  # perfectly eligible page into a confident negative on stage.
  test "a check that could not run keeps the answer unknown instead of hardening it into a no" do
    rate_limited = step(present: false, transient: true, reason: "GitHub rate limit reached")
    a = verdict({"code_channel" => rate_limited, "web_channel" => web(crawled: false),
                "memorization" => memorized("none")}).training_answer

    assert_equal :unknown, a.tone
    refute_match(/unlikely/i, a.headline)
  end

  test "verbatim reproduction is the one strong yes" do
    a = verdict({"code_channel" => code, "web_channel" => web,
                "memorization" => memorized("strong", best_run: 91)}).training_answer

    assert_equal :yes, a.tone
    assert_match(/91 consecutive words/, a.headline)
  end

  test "a short run is a maybe, not a yes" do
    a = verdict({"code_channel" => code, "web_channel" => web,
                "memorization" => memorized("partial", best_run: 9)}).training_answer

    assert_equal :mixed, a.tone
    assert_match(/maybe/i, a.headline)
  end

  # --- the progressive part ---------------------------------------------------------------------

  test "an empty run states the question rather than an answer" do
    a = verdict({}).training_answer
    assert_equal :pending, a.state
    assert_equal :waiting, a.cues.find { |c| c.label == "model recall" }.status
  end

  test "the answer sharpens as steps land and only settles once recall is measured" do
    partial = verdict({"code_channel" => code}).training_answer
    assert_equal :partial, partial.state
    assert_match(/code path is open/i, partial.headline)
    assert_match(/still checking/i, partial.detail)

    settled = verdict({"code_channel" => code, "web_channel" => web,
                      "memorization" => memorized("none")}).training_answer
    assert_equal :final, settled.state
  end

  test "an unarchived repo names Software Heritage as the gate that closed" do
    a = verdict({"code_channel" => code(swh: false)}).training_answer
    assert_match(/Software Heritage/, a.detail)
    assert_equal :fail, a.cues.find { |c| c.label == "code path" }.status
  end

  # The Stack v2/v3 keep unlicensed repos, and the study's headline case (140 stars, no licence,
  # reproduced by two frontier models) lives or dies on the page saying so.
  test "an unlicensed repo is called unlicensed, never permissive" do
    unlicensed = step(present: true, repo: "tailwindlabs/tailwindcss.com", swh_archived: true,
                      kept_by_stack: true, license_class: "no_license")
    a = verdict({ "code_channel" => unlicensed }).training_answer

    assert_match(/unlicensed/, a.detail)
    refute_match(/permissively licensed/, a.detail)
  end

  test "a repo target does not pretend to answer the retrieval question" do
    a = verdict({"target" => step(kind: "repo", repo: "acme/docs")}).retrieval_answer
    assert_equal :unknown, a.tone
    assert_match(/not checked/i, a.headline)
  end
end
