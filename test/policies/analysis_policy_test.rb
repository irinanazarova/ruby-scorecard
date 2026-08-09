# frozen_string_literal: true

require "test_helper"

class AnalysisPolicyTest < ActiveSupport::TestCase
  setup do
    Analysis.delete_all
    User.delete_all
  end

  # --- read? --------------------------------------------------------------------------------

  test "the session that ran it can read it" do
    analysis = run_by(session: "abc")
    assert policy(session: "abc").read?(analysis)
  end

  test "a different session cannot read it" do
    analysis = run_by(session: "abc")
    refute policy(session: "xyz").read?(analysis)
  end

  # The bug this class exists to prevent. Written as `analysis.user_id == user&.id` the comparison
  # becomes nil == nil for an anonymous analysis viewed by an anonymous stranger, which is true, and
  # every result on the site becomes world-readable by walking IDs. Both sides are nil here on
  # purpose.
  test "an anonymous stranger cannot read an anonymous analysis" do
    analysis = run_by(session: "abc", user: nil)
    assert_nil analysis.user_id

    refute policy(session: "stranger", user: nil).read?(analysis),
           "anonymous user_ids must not match each other"
  end

  test "the signed-in owner can read it from a new session" do
    user = user_with(spent: 0)
    analysis = run_by(session: "old-session", user: user)

    assert policy(session: "new-session", user: user).read?(analysis)
  end

  test "a different signed-in user cannot read it" do
    owner = user_with(spent: 0, uid: "1")
    other = user_with(spent: 0, uid: "2")
    analysis = run_by(session: "abc", user: owner)

    refute policy(session: "xyz", user: other).read?(analysis)
  end

  # --- run ----------------------------------------------------------------------------------

  test "a free run is allowed even with the allowance spent" do
    AnalyzerConfig.free_analyses_per_session.times { |i| run_by(session: "abc", input: "u#{i}") }

    assert_nil policy(session: "abc").run(free: true),
               "a cached run costs nothing, so nothing needs protecting from it"
  end

  test "an anonymous visitor with allowance left may run" do
    assert_nil policy(session: "fresh").run(free: false)
  end

  test "an anonymous visitor is denied once the allowance is spent" do
    AnalyzerConfig.free_analyses_per_session.times { |i| run_by(session: "abc", input: "u#{i}") }

    denial = policy(session: "abc").run(free: false)
    assert_equal :free_allowance_exhausted, denial.reason
    assert_equal AnalyzerConfig.free_analyses_per_session, denial.limit
  end

  test "cached runs do not count against the allowance" do
    AnalyzerConfig.free_analyses_per_session.times do |i|
      run_by(session: "abc", input: "u#{i}", from_cache: true)
    end

    assert_nil policy(session: "abc").run(free: false),
               "from_cache runs are not billable, so they must not consume the allowance"
  end

  test "a signed-in user over budget is denied" do
    user = user_with(spent: AnalyzerConfig.budget_cents_per_user * 10)

    denial = policy(session: "abc", user: user).run(free: false)
    assert_equal :budget_exhausted, denial.reason
    assert_equal user.budget_dollars, denial.limit
  end

  test "signing in lifts the anonymous allowance" do
    AnalyzerConfig.free_analyses_per_session.times { |i| run_by(session: "abc", input: "u#{i}") }
    user = user_with(spent: 0)

    assert_nil policy(session: "abc", user: user).run(free: false)
  end

  # A denial is a symbol plus a number, never a sentence: the wording is the caller's, so the policy
  # never has to be edited to reword a flash message.
  test "denials carry no user-facing copy" do
    AnalyzerConfig.free_analyses_per_session.times { |i| run_by(session: "abc", input: "u#{i}") }

    denial = policy(session: "abc").run(free: false)
    assert_kind_of Symbol, denial.reason
    assert_not denial.to_h.values.any? { |v| v.is_a?(String) && v.include?(" ") }
  end

  private

  def policy(session:, user: nil) = AnalysisPolicy.new(user: user, session_token: session)

  def run_by(session:, user: nil, input: "https://example.com/docs", from_cache: false)
    Analysis.create!(input: input, session_token: session, user: user,
                     status: "done", from_cache: from_cache)
  end

  def user_with(spent:, uid: "u1")
    User.create!(github_uid: uid, login: "tester#{uid}", spent_millicents: spent)
  end
end
