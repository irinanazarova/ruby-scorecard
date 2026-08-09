# frozen_string_literal: true

module Analyzer
  # The recall chart: three models down the side, five things across the top.
  #
  #                     your docs   your repo   Tailwind   Rails   MIT licence   invented text
  #   Claude Opus            0          28         30        30         31             0
  #   GPT-5.5                0           2         14         3         31             0
  #   Gemini 2.5 Pro         0           0          9         2         28             0
  #
  # Everything in one grid because every number in it came from the SAME probe: 55 words in, longest
  # exact continuation out. A bar chart of your page alone is unreadable, and a bar chart against a
  # reference with no controls is unfalsifiable. The two control columns are what make the middle
  # columns mean anything: the MIT licence text must fire on every model, and the invented passage
  # must fire on none. When those two misbehave, nothing else in the grid is interpretable.
  #
  # A reference is dropped when it is the target's own repo. Showing tailwindlabs/tailwindcss.com as
  # both "your repo" and "the reference" produces two nearly identical bars and invites the audience
  # to ask why they disagree, which is not the question you want from the room.
  class RecallGrid
    # kind drives the styling and the reading order: yours, then what a positive looks like, then
    # the calibration pair.
    Column = Struct.new(:key, :label, :sublabel, :kind, :href, keyword_init: true)
    # state: :measured | :waiting | :missing (never asked, which is not the same as zero)
    Cell = Struct.new(:run, :verdict, :state, :matched, keyword_init: true)
    Row = Struct.new(:model, :cells, keyword_init: true)

    # Never scale to less than this. A grid whose widest bar is 3 words would draw that 3 as a full
    # bar and read as a hit.
    MIN_SCALE = Memorization::STRONG_RUN * 2

    def initialize(payloads)
      @payloads = payloads || {}
    end

    def ready? = memorization.present? || references.any?

    def threshold = Memorization::STRONG_RUN

    def columns
      @columns ||= [ own_columns, reference_columns, control_columns ].flatten
    end

    def rows
      models.map { |model| Row.new(model: model, cells: columns.to_h { |c| [ c.key, cell(model, c) ] }) }
    end

    # The widest bar on the grid, so every row is drawn against one scale. Comparing a row against
    # its own maximum would make every model look equally memorized.
    def scale
      @scale ||= [ rows.flat_map { |r| r.cells.values.map { |c| c.run.to_i } }.max.to_i, MIN_SCALE ].max
    end

    # Did the controls do what they must? Reported rather than assumed, because a provider change
    # that breaks the prompt shows up here first and silently zeroes the whole grid.
    def controls_ok?
      positives = controls.select { |c| c[:kind] == "control+" }
      negatives = controls.select { |c| c[:kind] == "control-" }
      return nil if positives.empty?

      positives.all? { |c| c[:run].to_i >= Memorization::STRONG_RUN } &&
        negatives.none? { |c| c[:run].to_i >= Memorization::STRONG_RUN }
    end

    private

    def own_columns
      [
        # The pasted paragraph leads, because someone who typed one in came for that answer.
        (target[:passage].present? ? Column.new(key: "passage", label: "Your paragraph", kind: :yours,
                                                sublabel: "#{target[:passage].split.size} words") : nil),
        (target[:docs_url].present? ? Column.new(key: "docs", label: "Your docs", kind: :yours,
                                                 sublabel: host_of(target[:docs_url]),
                                                 href: target[:docs_url]) : nil),
        (target[:repo].present? ? Column.new(key: "repo", label: "Your repo", kind: :yours,
                                             sublabel: target[:repo],
                                             href: "https://github.com/#{target[:repo]}") : nil)
      ].compact
    end

    def reference_columns
      references.reject { |ref| ref[:repo].to_s == target[:repo].to_s }.map do |ref|
        Column.new(key: "ref:#{ref[:repo]}", label: ref[:label], kind: :reference,
                   sublabel: "#{ref[:stars]} stars, #{ref[:license]}", href: ref[:url])
      end
    end

    def control_columns
      return [] if controls.empty?

      [ Column.new(key: "control+", label: "MIT licence", sublabel: "must fire", kind: :control),
       Column.new(key: "control-", label: "Invented text", sublabel: "must not fire", kind: :control) ]
    end

    # Every model that produced a number anywhere on the grid. Taken from the union rather than from
    # MODELS, so a run made without a Gemini key shows two rows instead of an empty third.
    def models
      seen = matrix.map { |m| m[:model] } +
             references.flat_map { |r| Array(r[:by_model]).map { |m| m[:model] } } +
             controls.map { |c| c[:provider] }
      Memorization::MODELS.values.map { |spec| spec[:label] }.select { |label| seen.include?(label) }
    end

    def cell(model, column)
      case column.kind
      when :yours then own_cell(model, column.key)
      when :reference then reference_cell(model, column.key)
      else control_cell(model, column.key)
      end
    end

    def own_cell(model, source)
      return Cell.new(state: :waiting) if memorization.blank?

      row = matrix.find { |m| m[:model] == model }
      data = row && row[:cells][source.to_sym]
      # No cell for a source means it was never probed: the repo had no testable prose, or the call
      # budget ran out. Drawing that as a zero would turn "not asked" into "not memorized", which is
      # the exact overclaim this whole tool exists to avoid.
      return Cell.new(state: :missing) if data.nil?

      Cell.new(run: data[:run].to_i, verdict: data[:verdict], state: :measured, matched: data[:matched])
    end

    def reference_cell(model, key)
      ref = references.find { |r| "ref:#{r[:repo]}" == key }
      row = Array(ref&.dig(:by_model)).find { |m| m[:model] == model }
      data = row && row[:cells][:docs]
      return Cell.new(state: references_pending? ? :waiting : :missing) if data.nil?

      Cell.new(run: data[:run].to_i, verdict: data[:verdict], state: :measured, matched: data[:matched])
    end

    def control_cell(model, kind)
      c = controls.find { |x| x[:provider] == model && x[:kind] == kind }
      return Cell.new(state: :waiting) if c.nil?

      Cell.new(run: c[:run].to_i, verdict: c[:verdict], state: :measured, matched: c[:matched])
    end

    def references_pending? = result("references").nil?

    def references = Array(result("references")&.dig(:items)).compact.reject { |r| r[:error].present? }

    def controls = Array(memorization&.dig(:controls))

    def matrix = Array(memorization&.dig(:matrix))

    def memorization
      r = result("memorization")
      return nil if r.nil? || r[:error].present?

      r
    end

    def host_of(url)
      URI.parse(url.to_s).host.to_s.sub(/\Awww\./, "").presence || url
    rescue StandardError
      url
    end

    def target = result("target") || {}

    def result(step)
      payload = @payloads[step.to_s]
      return nil unless payload.is_a?(Hash)

      payload[:result].is_a?(Hash) ? payload[:result] : nil
    end
  end
end
