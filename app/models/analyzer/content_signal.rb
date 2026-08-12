# frozen_string_literal: true

module Analyzer
  # The `Content-Signal:` line in robots.txt: what a site says may be DONE with a page, which is a
  # different question from who may fetch it.
  #
  # Cloudflare's Content Signals Policy, October 2025, with the vocabulary at the IETF as
  # draft-romm-aipref-contentsignals. Three signals, each `yes` or `no`:
  #
  #   Content-Signal: search=yes, ai-input=yes, ai-train=no
  #
  #   search    building a search index and returning links and short excerpts
  #   ai-input  feeding the page to a model at answer time (RAG, grounding)
  #   ai-train  training or fine-tuning a model
  #
  # An omitted signal is NOT a no. The policy text is explicit that for a use the operator did not
  # name, they "neither grant nor restrict permission via content signal", which is why this reads
  # back only what was written and never fills in a default.
  #
  # It reserves rights rather than controlling access. A `no` is an express reservation under
  # Article 4 of EU Directive 2019/790, and nothing enforces it at the HTTP layer: a page with
  # `ai-train=no` still fetches, and the crawler-allowed check still passes. Collapsing the two into
  # one green tick is the misreport this class exists to prevent.
  #
  # EVERY Content-Signal line in the file is read, and User-agent groups are not resolved. The
  # directive is absent from RFC 9309, so grouping semantics for it are undefined, and Cloudflare's
  # own two deployments disagree: developers.cloudflare.com puts the line inside `User-agent: *`,
  # while www.cloudflare.com trails it after the last group in the file. Picking a group for it
  # would be inventing a rule the spec does not have.
  class ContentSignal
    SIGNALS = %w[search ai-input ai-train].freeze
    VALUES = %w[yes no].freeze

    attr_reader :signals

    def self.parse(robots_body)
      new(robots_body.to_s.each_line.filter_map do |line|
        line.sub(/#.*/, "").strip.match(/\Acontent-signal:\s*(.+)\z/i)&.captures&.first
      end)
    end

    def initialize(declarations)
      @signals = Array(declarations).flat_map { |d| d.to_s.split(",") }.each_with_object({}) do |pair, acc|
        key, value = pair.split("=", 2).map { |part| part.to_s.strip.downcase }
        acc[key] = value if SIGNALS.include?(key) && VALUES.include?(value)
      end
    end

    def present? = signals.any?

    # Ordered as the policy lists them, so two sites with the same answer read the same way.
    def declined = ordered("no")
    def granted = ordered("yes")

    private

    def ordered(value) = SIGNALS.select { |name| signals[name] == value }
  end
end
