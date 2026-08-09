# frozen_string_literal: true

# Who may run an analysis, and who may read one back.
#
# A plain object rather than action_policy: there is one resource and three rules, and the gem's
# scoping, caching and lookup conventions would be more machinery than the rules justify. If
# authorization grows a second resource or per-role behaviour, this is the seam to swap.
#
# Denials come back as SYMBOLS, never as sentences. The wording belongs to whatever is telling the
# visitor, and a policy that returns copy is a policy that has to be edited to reword a flash
# message.
class AnalysisPolicy
  Denial = Struct.new(:reason, :limit, keyword_init: true)

  def initialize(user:, session_token:)
    @user = user
    @session_token = session_token
  end

  # Results are tied to whoever ran them, so a stranger cannot walk IDs and read other people's
  # inputs.
  #
  # The user_id comparison MUST be guarded against nil. Written as
  # `analysis.user_id == user&.id` it becomes `nil == nil` for an anonymous analysis viewed by an
  # anonymous visitor, which is true, and every result becomes world-readable by ID.
  def read?(analysis)
    return true if analysis.session_token == session_token
    return true if analysis.user_id.present? && analysis.user_id == user&.id

    false
  end

  # nil means allowed. A Denial means stop, and carries the number the message needs so the caller
  # does not have to reach back into config to write the sentence.
  #
  # A free run is allowed unconditionally: it costs nothing to serve, so neither the anonymous
  # allowance nor the spend cap has anything to protect against.
  def run(free:)
    return nil if free

    if user.nil?
      return nil if Analysis.free_remaining(session_token).positive?

      Denial.new(reason: :free_allowance_exhausted,
                 limit: AnalyzerConfig::FREE_ANALYSES_PER_SESSION)
    elsif user.budget_exhausted?
      Denial.new(reason: :budget_exhausted, limit: user.budget_dollars)
    end
  end

  private

  attr_reader :user, :session_token
end
