# frozen_string_literal: true

class AnalysesController < ApplicationController
  # Bot defence, in layers, because one analysis costs ~5c of model calls and a scripted loop is the
  # only realistic way to drain the account.
  #
  #   1. Rails' rate_limit, per IP, on the action that spends money. Two windows: a burst limit and
  #      a daily one, so a slow drip is capped too.
  #   2. A per-session free allowance before sign-in is required.
  #   3. A per-user spend cap for signed-in users.
  #
  # Deliberately NOT limiting #show: viewing a finished result is free, and throttling it would
  # punish someone refreshing a page rather than an abuser.
  rate_limit to: AnalyzerConfig::RATE_LIMIT_PER_IP[:count],
             within: AnalyzerConfig::RATE_LIMIT_PER_IP[:within],
             only: :create,
             by: -> { request.remote_ip },
             with: -> { too_many_requests("You are going a bit fast. Try again in a few minutes.") }

  rate_limit to: AnalyzerConfig::RATE_LIMIT_PER_IP_DAILY[:count],
             within: AnalyzerConfig::RATE_LIMIT_PER_IP_DAILY[:within],
             only: :create,
             by: -> { "daily:#{request.remote_ip}" },
             with: -> { too_many_requests("Daily limit reached for this network.") }

  def new
    @recent = Analysis.where(session_token: session_token).recent.limit(5)
    @demo_targets = AnalyzerConfig::DEMO_TARGETS
  end

  def create
    input = params[:input].to_s.strip
    target = Analyzer::Target.new(input)
    return redirect_to(test_path, alert: target.error) unless target.valid?

    # Cached runs are free: they cost nothing to serve, so they neither consume the anonymous
    # allowance nor require signing in. This is also the behaviour the demo wants to show off.
    cached = Analyzer::Run.new(input).cache_status.values.all?

    unless cached
      if !signed_in? && free_remaining <= 0
        return redirect_to(test_path, alert: "You have used your #{AnalyzerConfig::FREE_ANALYSES_PER_SESSION} free checks. Sign in with GitHub to continue.")
      end
      if signed_in? && current_user.budget_exhausted?
        return redirect_to(test_path, alert: "You have reached your $#{current_user.budget_dollars} budget.")
      end
    end

    analysis = Analysis.create!(
      user: current_user, session_token: session_token, input: input,
      kind: target.kind.to_s, status: "pending", ip_hash: ip_hash, from_cache: cached
    )
    AnalyzeJob.perform_later(analysis.id)
    redirect_to analysis
  end

  def show
    @analysis = Analysis.find(params[:id])
    return head :not_found unless owns?(@analysis)
  end

  private

  # Results are tied to whoever ran them, so a stranger cannot walk IDs and read other people's
  # inputs.
  #
  # The user_id comparison MUST be guarded against nil. Written as
  # `analysis.user_id == current_user&.id` it becomes `nil == nil` for an anonymous analysis viewed
  # by an anonymous visitor, which is true, and every result becomes world-readable by ID.
  def owns?(analysis)
    return true if analysis.session_token == session_token
    return true if analysis.user_id.present? && analysis.user_id == current_user&.id

    false
  end

  def too_many_requests(message)
    redirect_to test_path, alert: message
  end
end
