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

    # /guide was folded into /learn. The old URL is in the wild, so it has to keep resolving.
    get "/guide"
    assert_redirected_to "/learn"
    follow_redirect!
    assert_response :success
  end

  # Every result on /test deep-links into /learn by fragment, so a renamed id is a broken link that
  # nothing else would catch: the page still returns 200 and the reader lands at the top of it.
  #
  # The expected list is SCANNED from the source rather than restated here. A hardcoded copy would
  # be one more thing to keep in step, and it would pass while the real link rotted.
  test "/learn carries every anchor the analyzer links to" do
    get "/learn"
    assert_response :success

    # Three services hand out anchors now: the ranked next steps, the per-box fixes on the agent
    # experience slide, and the licence implications.
    from_code  = %w[actions.rb discoverability.rb license.rb funnel.rb].flat_map do |file|
      Rails.root.join("app/services/analyzer", file).read.scan(/(?:anchor|ANCHOR)\s*[:=]\s*"([^"]+)"/).flatten
    end
    from_terms = ApplicationHelper::LEARN_TERMS.map(&:last)
    anchors    = (from_code + from_terms).uniq

    assert_operator anchors.size, :>=, 15, "expected to find the anchors; the scan came up short"
    anchors.each do |anchor|
      assert_match(/id="#{Regexp.escape(anchor)}"/, response.body,
                   "/learn is missing ##{anchor}, which a result on /test links to")
    end
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

    # Warm every check for a new pair, so the controller sees a fully cached run.
    docs = "https://example.com/docs/warm"
    warm_every_check(docs, "acme/warm")

    post "/analyses", params: { docs_url: docs, repo: "acme/warm" }
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

  # The generated pages and the Rails pages carry two copies of the same bar (scripts/site_nav.rb
  # and the layout), so this asserts the published HTML really has it. A generator edited without a
  # rebuild leaves dist/ behind, and the only symptom is a page that quietly cannot reach /learn.
  test "every published page carries the main navigation" do
    %w[/ /guide /check /contributors /test /learn].each do |path|
      get path
      # /guide is a 301 to /learn now; the bar has to be on the page a visitor actually lands on.
      follow_redirect! if response.redirect?
      assert_response :success, "#{path} did not render"
      assert_match "/learn", response.body, "#{path} has no link to /learn"
      assert_match "/test", response.body, "#{path} has no link to /test"
    end
  end

  test "the learn page renders with the anchors results link into" do
    get "/learn"
    assert_response :success
    assert_match "How your content reaches a model", response.body

    %w[code-channel software-heritage licenses web-channel quality-filter crawlers reachable
       clean-text sitemap outcomes].each do |anchor|
      assert_match(/id="#{anchor}"/, response.body, "/learn lost the ##{anchor} target")
    end
  end

  # Results without next steps leave a visitor to invent their own plan, usually the wrong one.
  test "a result carries prioritised action items that link into the learn page" do
    post "/analyses", params: { docs_url: "https://example.com/docs/actionable", repo: "acme/docs" }
    analysis = Analysis.last

    analysis.update!(status: "done", results: {
      "retrieval" => { "result" => { "checks" => [
        { "name" => "Crawlers allowed", "pass" => true, "detail" => "" },
        { "name" => "Reachable by a crawler", "pass" => true, "detail" => "" },
        { "name" => "Sitemap", "pass" => false, "detail" => "" },
        { "name" => "Markdown twin (.md)", "pass" => false, "detail" => "" }
      ] } },
      "code_channel" => { "result" => { "present" => false, "reason" => "Repo not found or private: acme/docs" } }
    })

    get "/analyses/#{analysis.id}"
    assert_response :success
    assert_match "What to do next", response.body
    assert_match "Publish the docs source in a public repo", response.body
    assert_match "/learn#code-channel", response.body
    # Scoped to the ranked list. The same advice also appears inline next to its unticked box on the
    # agent-experience slide, which sits earlier in the document, so comparing positions across the
    # whole page measures slide order rather than ranking.
    ranked = response.body[/<section class="actions".*?<\/ol>/m]
    assert_operator ranked.index("Publish the docs source in a public repo"), :<,
                    ranked.index("Ship a sitemap.xml"),
                    "the repo item outranks crawl hygiene"
  end

  # The page answers the two questions a visitor arrived with, above the working. Reading four boxes
  # of checks and deriving the answer yourself is the job the page is supposed to do for you.
  test "a finished analysis states the answer above the evidence" do
    post "/analyses", params: { input: "https://example.com/docs/answered" }
    analysis = Analysis.last

    analysis.update!(status: "done", results: {
      "retrieval" => { "result" => { "checks" => [
        { "name" => "Crawlers allowed", "pass" => true, "detail" => "robots.txt permits AI crawlers" },
        { "name" => "Reachable by a crawler", "pass" => true, "detail" => "" },
        { "name" => "Markdown twin (.md)", "pass" => true, "detail" => "" }
      ] } },
      "code_channel" => { "result" => { "present" => true, "repo" => "acme/docs",
                                        "swh_archived" => true, "kept_by_stack" => true } },
      "web_channel" => { "result" => { "checks" => [
        { "name" => "In Common Crawl", "pass" => true, "detail" => "" },
        { "name" => "Passes the quality filter", "pass" => true, "score" => 3.2, "detail" => "" }
      ] } },
      "memorization" => { "result" => { "summary" => {
        "verdict" => "strong", "best_run" => 42, "models_fired" => ["Claude Opus"],
        "spans_tested" => 3, "probes" => 9
      } } }
    })

    get "/analyses/#{analysis.id}"
    assert_response :success
    assert_match "Is this text in the training data?", response.body
    assert_match "42 consecutive words", response.body
    assert_match "agents can read the source text", response.body
  end

  # A reload halfway through used to render four empty boxes: results were written once, at the end.
  # The answer has to be derivable from whatever has landed, or the fallback that rescues a missed
  # broadcast has nothing to show.
  test "an analysis still running renders the answer it can already support" do
    post "/analyses", params: { input: "https://example.com/docs/half-done" }
    analysis = Analysis.last

    analysis.update!(status: "running", results: {
      "code_channel" => { "result" => { "present" => true, "repo" => "acme/docs",
                                        "swh_archived" => true, "kept_by_stack" => true } }
    })

    get "/analyses/#{analysis.id}"
    assert_response :success
    assert_match "The code path is open", response.body
    assert_match "Still checking", response.body
    assert_match "analysis-sync", response.body, "an in-flight page needs the fallback controller"
  end

  # The listed examples are the tour: clicking all four must never cost a visitor their allowance
  # or trip the per-IP limit, however cold the cache is.
  test "listed examples never consume the free allowance" do
    AnalyzerConfig::FREE_ANALYSES_PER_SESSION.times do |i|
      post "/analyses", params: { input: "https://example.com/docs/spend-#{i}" }
    end
    assert_equal 0, Analysis.free_remaining(session_token_from_cookie), "allowance is spent"

    AnalyzerConfig::EXAMPLES.each do |example|
      post "/analyses", params: { docs_url: example[:docs], repo: example[:repo] }
      assert_redirected_to analysis_path(Analysis.last),
                           "#{example[:label]} must run even with no allowance left"
    end
  end

  test "a pair whose probe is already cached does not consume the allowance" do
    docs = "https://example.com/docs/already-probed"
    pair = Analyzer::Target.new(docs_url: docs, repo: "acme/probed")
    Analyzer::Cache.fetch(:memorization, pair.cache_key) { { summary: { verdict: "none" } } }

    AnalyzerConfig::FREE_ANALYSES_PER_SESSION.times do |i|
      post "/analyses", params: { input: "https://example.com/docs/burn-#{i}" }
    end
    assert_equal 0, Analysis.free_remaining(session_token_from_cookie)

    post "/analyses", params: { docs_url: docs, repo: "acme/probed" }
    assert_redirected_to analysis_path(Analysis.last), "a warm probe costs nothing, so it is free"
  end

  # Both halves are filled in for every listed example, which is the point of the pair: the demo
  # should never show the tool working one out from the other.
  test "every listed example fills in both fields and carries a note" do
    AnalyzerConfig::EXAMPLES.each do |example|
      target = Analyzer::Target.new(docs_url: example[:docs], repo: example[:repo])
      assert target.valid?, "#{example[:label]} does not parse: #{target.error}"
      assert_equal :both, target.kind, "#{example[:label]} is missing one half of the pair"
      assert example[:note].present?, "#{example[:label]} has no note"
      assert AnalyzerConfig.example?(example[:docs], example[:repo])
      assert AnalyzerConfig.example?("#{example[:docs]}/", example[:repo]),
             "trailing slash should still match"
    end
    assert_not AnalyzerConfig.example?("https://example.com/docs/not-listed", "acme/nope")
  end

  # The job used to recompute from_cache over EVERY step including `target`, which is the parsed
  # input echoed back and never has a cache entry, so `all?` could never be true and a fully warm
  # re-run still consumed an allowance slot.
  test "a fully cached run is recorded as cached and stays free" do
    docs = "https://example.com/docs/warm-rerun"
    warm_every_check(docs, "acme/rerun")

    post "/analyses", params: { docs_url: docs, repo: "acme/rerun" }
    analysis = Analysis.last
    perform_enqueued_jobs

    assert analysis.reload.from_cache, "a warm run must be recorded as cached, not billable"
    assert_equal AnalyzerConfig::FREE_ANALYSES_PER_SESSION,
                 Analysis.free_remaining(session_token_from_cookie),
                 "a cached run must not consume the allowance"
  end

  private

  # Each check caches under its OWN key: the two HTTP checks under the docs URL, the two GitHub
  # checks under the repo, and the probe under the pair. Warming them all under one key is what made
  # an earlier version of this test pass while cached re-runs still burned an allowance slot.
  def warm_every_check(docs, repo)
    Analyzer::Cache.fetch(:retrieval, docs) { { checks: [] } }
    Analyzer::Cache.fetch(:web_channel, docs) { { checks: [] } }
    Analyzer::Cache.fetch(:repo_signals, repo) { { present: true, checks: [] } }
    Analyzer::Cache.fetch(:code_channel, repo) { { present: true, checks: [] } }
    Analyzer::Cache.fetch(:memorization, Analyzer::Target.new(docs_url: docs, repo: repo).cache_key) do
      { summary: { verdict: "none" } }
    end
    Analyzer::Cache.fetch(:references, "-") { { items: [] } }
  end

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
