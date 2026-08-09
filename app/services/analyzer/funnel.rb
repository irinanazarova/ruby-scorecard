# frozen_string_literal: true

module Analyzer
  # Model recall drawn as two funnels that meet at one point.
  #
  # Text reaches a model through one of two pipelines, and each one throws most of its input away at
  # a stage people forget:
  #
  #   the web    Crawled by Common Crawl  ->  clears the quality filter  ->
  #   the code   Public on GitHub         ->  archived and licensed      ->
  #                                                                       -> repeated widely
  #                                                                       -> MODEL RECALL
  #
  # Drawing it as two wide bases narrowing to one small apex is the honest shape. Every tier below
  # the apex is a gate that removes most of what arrives at it, and the apex is small because
  # verbatim recall is rare even for text that cleared every gate.
  #
  # The connector between the top tier and the apex is not a check. It is the mechanism, and it is
  # the finding from our own 168-repo study: how many COPIES of a text exist predicts recall
  # (Spearman rho +0.70), while stars do not. Nothing here measures copies live, so it is labelled
  # as the mechanism rather than dressed up as a result.
  class Funnel
    # status: :pass | :fail | :unknown | :waiting | :missing
    # width is the drawn width as a percentage of the channel's base, which is what makes it read as
    # a funnel rather than a stack of equal boxes.
    Tier = Struct.new(:key, :label, :status, :detail, :width, :anchor, keyword_init: true)
    Channel = Struct.new(:key, :title, :subject, :tiers, keyword_init: true)

    CONNECTOR = "and it is repeated across many sources"
    CONNECTOR_ANCHOR = "copies"

    def initialize(payloads)
      @payloads = payloads || {}
    end

    def channels = [ web_channel, code_channel ]

    # The single block both funnels narrow into.
    def apex
      mem = summary
      return Tier.new(key: :recall, label: "Model recall", status: :waiting, width: 26,
                      detail: "asking the models", anchor: "memorization") if mem.nil?

      status, detail =
        case mem[:verdict]
        when "strong" then [ :pass, "#{mem[:best_run]} consecutive words reproduced" ]
        when "partial" then [ :unknown, "#{mem[:best_run]} words continued, below the #{Memorization::STRONG_RUN}-word bar" ]
        else [ :fail, "no model reproduced it" ]
        end

      Tier.new(key: :recall, label: "Model recall", status: status, detail: detail, width: 26,
               anchor: "memorization")
    end

    private

    def web_channel
      url = target[:docs_url]
      return Channel.new(key: :web, title: "The web", subject: nil,
                         tiers: missing_tiers(web_tier_labels)) if url.blank?

      r = result("web_channel")
      return Channel.new(key: :web, title: "The web", subject: url,
                         tiers: waiting_tiers(web_tier_labels)) if r.nil?

      crawled = pass?("web_channel", "In Common Crawl")
      quality = check("web_channel", "Passes the quality filter")

      Channel.new(key: :web, title: "The web", subject: url, tiers: [
        Tier.new(key: :crawled, label: "Crawled content", status: status_of(crawled), width: 100,
                 detail: detail("web_channel", "In Common Crawl") || "Common Crawl did not answer",
                 anchor: "web-channel"),
        Tier.new(key: :quality, label: "Quality filter", status: status_of(quality&.dig(:pass)), width: 62,
                 detail: quality&.dig(:detail) || "the scorer did not answer",
                 anchor: "quality-filter")
      ])
    end

    def code_channel
      repo = target[:repo]
      return Channel.new(key: :code, title: "The code", subject: nil,
                         tiers: missing_tiers(code_tier_labels)) if repo.blank?

      r = result("code_channel")
      return Channel.new(key: :code, title: "The code", subject: repo,
                         tiers: waiting_tiers(code_tier_labels)) if r.nil?

      Channel.new(key: :code, title: "The code", subject: repo, tiers: [
        Tier.new(key: :public, label: "Public repos", status: public_status(r), width: 100,
                 detail: public_detail(r), anchor: "code-channel"),
        Tier.new(key: :kept, label: "Archived and permissively licensed", status: kept_status(r), width: 62,
                 detail: kept_detail(r), anchor: "the-stack")
      ])
    end

    def web_tier_labels
      [ [ :crawled, "Crawled content", 100, "web-channel" ], [ :quality, "Quality filter", 62, "quality-filter" ] ]
    end

    def code_tier_labels
      [ [ :public, "Public repos", 100, "code-channel" ],
       [ :kept, "Archived and permissively licensed", 62, "the-stack" ] ]
    end

    def missing_tiers(labels)
      labels.map do |key, label, width, anchor|
        Tier.new(key: key, label: label, status: :missing, width: width, anchor: anchor,
                 detail: "nothing given to check")
      end
    end

    def waiting_tiers(labels)
      labels.map do |key, label, width, anchor|
        Tier.new(key: key, label: label, status: :waiting, width: width, anchor: anchor,
                 detail: "checking")
      end
    end

    def public_status(r)
      return :pass if r[:present]
      # A rate limit is a fact about this server, not about the repo, and must never draw as a
      # closed gate on someone else's project.
      return :unknown if r[:transient] || r[:error].present?

      :fail
    end

    def public_detail(r)
      return "#{r[:repo]}, #{r[:stars]} stars" if r[:present]

      r[:reason].presence || r[:error].presence || "no public repo"
    end

    # The observed answer from the Am-I-in-The-Stack index settles this tier on its own. Only when
    # the index was unreachable do the two inferred halves apply, and they are drawn together
    # because a corpus applies them together: archival without a usable licence and a usable
    # licence without archival both end the same way.
    def kept_status(r)
      return :waiting unless r[:present] || r[:error].present? || r[:reason].present?
      return :unknown unless r[:present]

      case r[:in_stack_v3]
      when true then return :pass
      when false then return :fail
      end

      return :fail unless r[:swh_archived]

      case r[:kept_by_stack]
      when true then :pass
      when false then :fail
      else :unknown
      end
    end

    def kept_detail(r)
      return "no repo to archive" unless r[:present]

      case r[:in_stack_v3]
      when true then return "observed in The Stack v3 train set"
      when false
        return "not in The Stack v3: newer than the crawl cutoff" if r[:post_cutoff]

        return "not in The Stack v3 train set"
      end

      return "Software Heritage has not archived #{r[:repo]}" unless r[:swh_archived]

      licence = Array(r[:checks]).find { |c| c[:name] == "License permits inclusion" }
      "archived; #{licence&.dig(:detail) || 'licence unresolved'}"
    end

    def status_of(flag)
      case flag
      when true then :pass
      when false then :fail
      else :unknown
      end
    end

    def summary
      r = result("memorization")
      return nil if r.nil? || r[:error].present?

      r[:summary].presence
    end

    def target = result("target") || {}

    def result(step)
      payload = @payloads[step.to_s]
      return nil unless payload.is_a?(Hash)

      payload[:result].is_a?(Hash) ? payload[:result] : nil
    end

    def check(step, name)
      Array(result(step)&.dig(:checks)).find { |c| c[:name] == name }
    end

    def pass?(step, name) = check(step, name)&.dig(:pass)

    def detail(step, name) = check(step, name)&.dig(:detail)
  end
end
