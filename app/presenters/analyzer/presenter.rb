# frozen_string_literal: true

module Analyzer
  # Base for everything in app/presenters: the objects that turn a run's stored results into
  # something a screen can render.
  #
  # THE LAYER RULE, and the reason this directory exists at all: a presenter reads. It never
  # fetches, never writes, never touches the cache or the network. Anything that measures belongs in
  # app/services/analyzer. That line is what separates Verdict (reads five payloads and writes a
  # sentence) from the probes in app/services, which hit real pages and real models and cost money.
  #
  # All five subclasses used to carry an identical copy of the payload-reading tail below, down to
  # the same `Array(...).find`. Five copies of the same accessor is how they drift: Verdict's copy
  # had already diverged, calling the last one `detail_of` instead of `detail`.
  #
  # The shape being read is what AnalyzeJob persists and what the Turbo broadcasts carry:
  #
  #   { "web_channel" => { result: { checks: [{ name:, pass:, detail: }, ...] },
  #                        cache_hit:, cached_at:, took_ms: }, ... }
  #
  # Keys arrive symbolized (Analysis#step_payloads rehydrates the as_json round-trip), while the
  # step names stay strings. Hence `@payloads[step.to_s]` with `dig(:checks)` inside it.
  class Presenter
    def initialize(payloads)
      @payloads = payloads || {}
    end

    private

    attr_reader :payloads

    # The parsed input, echoed back by the run as its first step. Not a measurement: it is how every
    # presenter knows whether a docs URL, a repo, both or only a pasted passage were given, which is
    # what separates "this channel is closed" from "we never looked".
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
