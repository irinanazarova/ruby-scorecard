# frozen_string_literal: true

require "test_helper"

class AnalysesFlowTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    Analysis.delete_all
    User.delete_all
  end

  test "the static site still serves from Rails" do
    get "/"
    assert_response :success
    assert_match "scorecard", response.body.downcase

    get "/guide"
    assert_response :success
  end

  test "the test page renders with the free allowance shown" do
    get "/test"
    assert_response :success
    assert_match "free checks left", response.body
  end

  test "rejects input that is neither a URL nor a repo" do
    post "/analyses", params: { input: "not a url at all" }
    assert_redirected_to test_path
    assert_equal 0, Analysis.count
  end

  test "creates an analysis and enqueues the job" do
    assert_enqueued_with(job: AnalyzeJob) do
      post "/analyses", params: { input: "https://example.com/docs/thing" }
    end
    assert_equal 1, Analysis.count
    assert_redirected_to analysis_path(Analysis.last)
  end

  # The allowance is the thing that stops a stranger spending the account's money, so it needs a
  # test that actually exhausts it rather than trusting the counter.
  test "anonymous visitors are cut off after the free allowance" do
    AnalyzerConfig::FREE_ANALYSES_PER_SESSION.times do |i|
      post "/analyses", params: { input: "https://example.com/docs/#{i}" }
      assert_redirected_to analysis_path(Analysis.last)
    end

    post "/analyses", params: { input: "https://example.com/docs/one-too-many" }
    assert_redirected_to test_path
    assert_match(/free checks/i, flash[:alert])
    assert_equal AnalyzerConfig::FREE_ANALYSES_PER_SESSION, Analysis.count
  end

  # Cached runs cost nothing to serve, so charging an allowance slot for one would punish exactly
  # the behaviour we want to encourage (re-checking a link you already ran).
  test "cached re-runs do not consume the free allowance" do
    AnalyzerConfig::FREE_ANALYSES_PER_SESSION.times do |i|
      post "/analyses", params: { input: "https://example.com/docs/#{i}" }
    end
    assert_equal 0, Analysis.free_remaining(session_token_from_cookie)

    # Warm every check for a new target, so the controller sees a fully cached run.
    target = "https://example.com/docs/warm"
    %i[retrieval code_channel web_channel memorization].each do |kind|
      Analyzer::Cache.fetch(kind, target) { { checks: [] } }
    end

    post "/analyses", params: { input: target }
    assert_redirected_to analysis_path(Analysis.last), "a fully cached run must be allowed past the allowance"
    assert Analysis.last.from_cache
  end

  test "signed-in users are blocked once the budget is spent" do
    sign_in_via_github(spent_millicents: AnalyzerConfig::BUDGET_CENTS_PER_USER * 10)

    post "/analyses", params: { input: "https://example.com/docs/over-budget" }
    assert_redirected_to test_path
    assert_match(/budget/i, flash[:alert])
    assert_equal 0, Analysis.count
  end

  test "signing in carries anonymous runs over and lifts the allowance" do
    (AnalyzerConfig::FREE_ANALYSES_PER_SESSION + 1).times do |i|
      post "/analyses", params: { input: "https://example.com/docs/pre-#{i}" }
    end
    assert_equal AnalyzerConfig::FREE_ANALYSES_PER_SESSION, Analysis.count, "the last one is blocked"

    user = sign_in_via_github
    assert_equal AnalyzerConfig::FREE_ANALYSES_PER_SESSION, user.analyses.count,
                 "anonymous history should follow the visitor in"

    post "/analyses", params: { input: "https://example.com/docs/after-signin" }
    assert_redirected_to analysis_path(Analysis.last)
  end

  test "results are not readable by a different session" do
    post "/analyses", params: { input: "https://example.com/docs/private" }
    id = Analysis.last.id

    reset!   # new session, as if a different visitor
    get "/analyses/#{id}"
    assert_response :not_found
  end

  # The results live in the database; the page used to read them only off the Turbo broadcast, so
  # reloading a finished analysis (or opening it a second time before a demo) showed four empty
  # "waiting" boxes.
  test "a finished analysis renders its stored results on a plain reload" do
    post "/analyses", params: { input: "https://example.com/docs/reloaded" }
    analysis = Analysis.last

    analysis.update!(status: "done", results: {
      "retrieval" => { "result" => { "checks" => [
        { "name" => "Reachable by agents", "detail" => "200 OK", "pass" => true }
      ] }, "took_ms" => 900 },
      "web_channel" => { "result" => { "checks" => [
        { "name" => "In Common Crawl", "detail" => "no captures", "pass" => false }
      ] }, "cache_hit" => true, "cached_at" => 2.hours.ago }
    })

    get "/analyses/#{analysis.id}"
    assert_response :success
    assert_match "Reachable by agents", response.body
    assert_match "no captures", response.body
    assert_match "cached", response.body, "a cached step should say so on reload too"

    # Steps that never answered still show their placeholder and keep waiting for a broadcast.
    assert_match "the slow one", response.body
  end

  # The listed examples are the tour: clicking all four must never cost a visitor their allowance
  # or trip the per-IP limit, however cold the cache is.
  test "listed examples never consume the free allowance" do
    AnalyzerConfig::FREE_ANALYSES_PER_SESSION.times do |i|
      post "/analyses", params: { input: "https://example.com/docs/spend-#{i}" }
    end
    assert_equal 0, Analysis.free_remaining(session_token_from_cookie), "allowance is spent"

    AnalyzerConfig::EXAMPLES.each do |example|
      post "/analyses", params: { input: example[:url] }
      assert_redirected_to analysis_path(Analysis.last),
                           "#{example[:url]} must run even with no allowance left"
    end
  end

  test "a target whose probe is already cached does not consume the allowance" do
    target = "https://example.com/docs/already-probed"
    Analyzer::Cache.fetch(:memorization, target) { { summary: { verdict: "none" } } }

    AnalyzerConfig::FREE_ANALYSES_PER_SESSION.times do |i|
      post "/analyses", params: { input: "https://example.com/docs/burn-#{i}" }
    end
    assert_equal 0, Analysis.free_remaining(session_token_from_cookie)

    post "/analyses", params: { input: target }
    assert_redirected_to analysis_path(Analysis.last), "a warm probe costs nothing, so it is free"
  end

  test "every listed example is a valid target and carries a note" do
    AnalyzerConfig::EXAMPLES.each do |example|
      assert Analyzer::Target.new(example[:url]).valid?, "#{example[:url]} does not parse"
      assert example[:note].present?, "#{example[:url]} has no note"
      assert AnalyzerConfig.example?(example[:url])
      assert AnalyzerConfig.example?("#{example[:url]}/"), "trailing slash should still match"
    end
    assert_not AnalyzerConfig.example?("https://example.com/docs/not-listed")
  end

  # The job used to recompute from_cache over EVERY step including `target`, which is the parsed
  # input echoed back and never has a cache entry, so `all?` could never be true and a fully warm
  # re-run still consumed an allowance slot.
  test "a fully cached run is recorded as cached and stays free" do
    target = "https://example.com/docs/warm-rerun"
    %i[retrieval code_channel web_channel memorization].each do |kind|
      Analyzer::Cache.fetch(kind, target) { { checks: [] } }
    end

    post "/analyses", params: { input: target }
    analysis = Analysis.last
    perform_enqueued_jobs

    assert analysis.reload.from_cache, "a warm run must be recorded as cached, not billable"
    assert_equal AnalyzerConfig::FREE_ANALYSES_PER_SESSION,
                 Analysis.free_remaining(session_token_from_cookie),
                 "a cached run must not consume the allowance"
  end

  private

  def session_token_from_cookie
    Analysis.last&.session_token
  end

  # Drives the real OAuth callback through OmniAuth's test mode, so the sign-in path itself is
  # exercised rather than the session being hand-stuffed.
  def sign_in_via_github(login: "tester", uid: "12345", spent_millicents: 0)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github", uid: uid, info: { nickname: login, name: "Test User", image: nil }
    )
    get "/auth/github/callback"
    follow_redirect!
    User.find_by(github_uid: uid).tap { |u| u.update!(spent_millicents: spent_millicents) }
  ensure
    OmniAuth.config.test_mode = false
  end
end
