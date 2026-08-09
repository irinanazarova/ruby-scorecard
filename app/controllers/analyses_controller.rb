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

    if (denial = policy.run(free: free_run?))
      return redirect_to(test_path, alert: denial_message(denial))
    end

    analysis = Analyses::StartRun.call(target: target, free: free_run?, user: current_user,
                                       session_token: session_token, ip_hash: ip_hash)
    redirect_to analysis
  end

  def show
    @analysis = Analysis.find(params[:id])
    head :not_found unless policy.read?(@analysis)
  end

  private

  def policy
    @policy ||= AnalysisPolicy.new(user: current_user, session_token: session_token)
  end

  # The policy decides, the controller words it. A flash message is presentation, and a policy that
  # returns sentences is a policy you have to edit to reword one.
  def denial_message(denial)
    case denial.reason
    when :free_allowance_exhausted
      "You have used your #{denial.limit} free checks. Sign in with GitHub to continue."
    when :budget_exhausted
      "You have reached your $#{denial.limit} budget."
    end
  end

  # Memoized rather than recomputed: the rate-limit guard and #create both ask, and the second call
  # would otherwise hit the cache again. `defined?` rather than `||=` because the answer is a
  # boolean and `false ||= ...` recomputes forever.
  def free_run?
    return @free_run if defined?(@free_run)

    @free_run = Analyzer::RunCost.free?(build_target)
  end

  # Two named fields now, and the form still accepts a single `input` so an old bookmark or a linked
  # example keeps working. Memoized because both the rate-limit guard and #create ask for it, and
  # parsing twice let them disagree about what was being run.
  def build_target
    @build_target ||=
      if params[:input].present? && params[:docs_url].blank? && params[:repo].blank? &&
         params[:passage].blank?
        Analyzer::Target.from_input(params[:input])
      else
        Analyzer::Target.new(docs_url: params[:docs_url], repo: params[:repo],
                             passage: params[:passage])
      end
  end

  def too_many_requests(message)
    redirect_to test_path, alert: message
  end
end
