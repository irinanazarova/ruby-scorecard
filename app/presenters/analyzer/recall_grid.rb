# frozen_string_literal: true

module Analyzer
  # The recall chart: the models down the side, your text across the top.
  #
  #                                  your paragraph   your docs   your repo
  #   Claude Opus  claude-opus-4-8         41             0           28
  #   GPT-5.5      gpt-5.5                 41             0            2
  #   Gemini 2.5 Pro  gemini-2.5-pro       41             0            0
  #
  # Every number came from the same probe: the opening words in, longest exact continuation out.
  #
  # The grid used to carry two more column groups and no longer does. Reference pages (Tailwind,
  # Rails, Supabase) were three columns of somebody else's numbers sitting between the visitor's
  # result and the calibration pair, all making one point, and each one inviting "why am I looking
  # at Supabase". The controls were two more.
  #
  # THE CONTROLS ARE STILL PROBED. Only their columns are gone. They are what makes a null row
  # readable: the MIT licence text must fire on every model and the invented passage must fire on
  # none, and when they misbehave nothing here is interpretable. That verdict is now one sentence
  # under the grid instead of two columns inside it, so the guarantee survives without costing the
  # table a third of its width. `controls_ok?` is what the view reads for it.
  class RecallGrid < Presenter
    Column = Struct.new(:key, :label, :sublabel, :kind, :href, keyword_init: true)
    # state: :measured | :waiting | :missing (never asked, which is not the same as zero)
    Cell = Struct.new(:run, :verdict, :state, :matched, keyword_init: true)
    # model_id is the exact string sent to the provider. The label alone ("Claude Opus") does not
    # say which snapshot answered, and a result that cannot name the model it came from is not
    # reproducible six months from now when the label points at different weights.
    Row = Struct.new(:model, :model_id, :cells, keyword_init: true)

    # Never scale to less than this. A grid whose widest bar is 3 words would draw that 3 as a full
    # bar and read as a hit.
    MIN_SCALE = Memorization::STRONG_RUN * 2

    # What a healthy run takes, for the progress bar shown while waiting. Measured rather than
    # guessed: 9 to 12 model calls land in 60 to 140 seconds, so this is the middle of that. It is
    # deliberately NOT the deadline (AnalyzerConfig.memorization_deadline, 180s): filling a bar
    # against the give-up time would show a normal run as a third complete and read as slow.
    EXPECTED_SECONDS = 90

    # Which models this run WILL probe, for the waiting state. Read from the configured models
    # rather than from results, because while waiting there are no results to read: the point is to
    # say what is being waited on.
    def expected_models
      Memorization::MODELS.values_at(*Memorization.available_models).compact
    end

    def ready? = memorization.present?

    def threshold = Memorization::STRONG_RUN

    # The raw probe payload, for the "show exactly what we tested" panel. Exposed here rather than
    # letting the view dig through payloads, so the one place that knows the stored shape stays the
    # one place. Returns nil until the probe answers.
    def evidence = memorization

    def columns
      @columns ||= own_columns
    end

    def rows
      models.map do |model|
        Row.new(model: model, model_id: model_id_for(model),
                cells: columns.to_h { |c| [ c.key, own_cell(model, c.key) ] })
      end
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

    # Every model that produced a number, taken from the union of the matrix and the controls rather
    # than from MODELS, so a run made without a Gemini key shows two rows instead of an empty third.
    # The controls are still counted here: they are the reason a model with an all-zero row is
    # listed at all, which is the difference between "it answered and found nothing" and "it never
    # ran".
    def models
      seen = matrix.map { |m| m[:model] } + controls.map { |c| c[:provider] }
      Memorization::MODELS.values.map { |spec| spec[:label] }.select { |label| seen.include?(label) }
    end

    def model_id_for(label)
      Memorization::MODELS.values.find { |spec| spec[:label] == label }&.dig(:model)
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
  end
end
