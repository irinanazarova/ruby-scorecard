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
  # Both limits exist to stop a scripted loop draining the account, so both skip runs that cannot
  # drain anything: the listed examples and anything whose probe is already cached. `rate_limit`
  # forwards extra options to before_action, which is what makes `unless:` work here. Without it a
  # visitor clicking the four examples in a row could be told to slow down for costing us nothing.
  rate_limit to: AnalyzerConfig::RATE_LIMIT_PER_IP[:count],
             within: AnalyzerConfig::RATE_LIMIT_PER_IP[:within],
             only: :create,
             unless: -> { free_run? },
             by: -> { request.remote_ip },
             with: -> { too_many_requests("You are going a bit fast. Try again in a few minutes.") }

  rate_limit to: AnalyzerConfig::RATE_LIMIT_PER_IP_DAILY[:count],
             within: AnalyzerConfig::RATE_LIMIT_PER_IP_DAILY[:within],
             only: :create,
             unless: -> { free_run? },
             by: -> { "daily:#{request.remote_ip}" },
             with: -> { too_many_requests("Daily limit reached for this network.") }

  def new
    @recent = Analysis.where(session_token: session_token).recent.limit(5)
    @examples = AnalyzerConfig::EXAMPLES
  end

  def create
    target = build_target
    return redirect_to(test_path, alert: target.error) unless target.valid?

    # Free runs cost nothing to serve, so they neither consume the anonymous allowance nor require
    # signing in. This is also the behaviour the demo wants to show off.
    cached = free_run?

    unless cached
      if !signed_in? && free_remaining <= 0
        return redirect_to(test_path, alert: "You have used your #{AnalyzerConfig::FREE_ANALYSES_PER_SESSION} free checks. Sign in with GitHub to continue.")
      end
      if signed_in? && current_user.budget_exhausted?
        return redirect_to(test_path, alert: "You have reached your $#{current_user.budget_dollars} budget.")
      end
    end

    analysis = Analysis.create!(
      user: current_user, session_token: session_token,
      input: target.label, docs_url: target.url, repo: target.repo,
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

  # What actually costs money is the memorization probe calling models; every other check is plain
  # HTTP against someone else's server. So a run is free when that probe is already cached, and the
  # listed examples are free by policy however cold the cache is.
  #
  # Keyed the way Run keys it (url or repo), because checking the wrong key silently reports every
  # run as billable. The previous version asked cache_status for all four checks, and code_channel
  # caches under the REPO while cache_status passed the URL, so it never once returned true and
  # cached re-runs kept consuming the allowance they were meant to be exempt from.
  def free_run?
    return @free_run unless @free_run.nil?

    target = build_target

    @free_run =
      if !target.valid? then false
      elsif AnalyzerConfig.example?(target.url, target.repo) then true
      else Analyzer::Cache.warm?(:memorization, target.cache_key)
      end
  end

  # Two named fields now, and the form still accepts a single `input` so an old bookmark or a linked
  # example keeps working. Memoized because both the rate-limit guard and #create ask for it, and
  # parsing twice let them disagree about what was being run.
  def build_target
    @build_target ||=
      if params[:input].present? && params[:docs_url].blank? && params[:repo].blank?
        Analyzer::Target.from_input(params[:input])
      else
        Analyzer::Target.new(docs_url: params[:docs_url], repo: params[:repo])
      end
  end

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
