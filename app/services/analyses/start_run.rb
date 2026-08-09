# frozen_string_literal: true

module Analyses
  # Start an analysis: record it, then hand it to the queue.
  #
  # Small on purpose. It exists so the sequence has one home rather than living in a controller
  # action, and so the two facts that have to travel together -- "this run was judged free" and "the
  # row says from_cache" -- are written in the same place. The controller decided free BEFORE doing
  # the work, and that is the decision the visitor was shown on the form; persisting it here is what
  # keeps AnalyzeJob from re-deciding it later and billing for a run it already promised was free.
  #
  # Returns the Analysis. Authorization is the caller's job: ask AnalysisPolicy first. Keeping the
  # two apart means this can be called from a rake task or a console without inventing a session.
  class StartRun
    def self.call(...) = new(...).call

    def initialize(target:, free:, session_token:, user: nil, ip_hash: nil)
      @target = target
      @free = free
      @session_token = session_token
      @user = user
      @ip_hash = ip_hash
    end

    def call
      analysis = Analysis.create!(
        user: user, session_token: session_token,
        input: target.label, docs_url: target.url, repo: target.repo, passage: target.passage,
        kind: target.kind.to_s, status: "pending", ip_hash: ip_hash, from_cache: free
      )
      AnalyzeJob.perform_later(analysis.id)
      analysis
    end

    private

    attr_reader :target, :free, :session_token, :user, :ip_hash
  end
end
