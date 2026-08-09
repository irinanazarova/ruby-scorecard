# frozen_string_literal: true

module Analyzer
  # Does a frontier model reproduce this exact text from memory?
  #
  # Method, stated plainly because the demo is meant to teach it: give the model a 55-word prefix
  # from the middle of the page and ask it to continue. Compare its output against the 60 words that
  # actually follow, which it never sees. Score the LONGEST CONTIGUOUS run of matching words.
  #
  # What this does and does not prove:
  #   - A long exact run is strong evidence the text was in training. You cannot reproduce unseen text.
  #   - "No recall" proves very little on its own. Models memorize a small fraction of what they read.
  #     That asymmetry is why the controls below are mandatory rather than decorative.
  #
  # Two controls run alongside every probe:
  #   MIT license  -> ubiquitous, must fire. If it doesn't, the prompt or provider is broken.
  #   Fabricated   -> never published, must NOT fire. If it does, the metric is matching noise.
  #
  # Elicitation differs by provider on purpose. Asking GPT to "reproduce the published source
  # verbatim" makes it refuse, and it refuses on the fabricated control too, so a refusal carries no
  # signal and would masquerade as "not memorized". Autocomplete framing avoids that and still fires
  # both positive controls.
  class Memorization
    # The two bars every verdict is read against. They live INSIDE the class rather than on the
    # Analyzer module: a bare `Analyzer::STRONG_RUN` is not a name Zeitwerk can autoload, so any
    # class that reached for it before Memorization happened to be loaded raised NameError.
    STRONG_RUN  = 15
    PARTIAL_RUN = 6

    PROMPT = "You are an autocomplete engine. Emit the next ~80 words of this document. " \
             "No commentary. Answer from memory only: do not use any tools, do not search."

    MIT_CONTROL = "Permission is hereby granted, free of charge, to any person obtaining a copy of " \
                  "this software and associated documentation files (the \"Software\"), to deal in " \
                  "the Software without restriction, including without limitation the rights to use, " \
                  "copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the " \
                  "Software, and to permit persons to whom the Software is furnished to do so, " \
                  "subject to the following conditions: The above copyright notice and this " \
                  "permission notice shall be included in all copies or substantial portions."

    FAKE_CONTROL = "The teal armadillo audited seventeen quivering lighthouses before the marzipan " \
                   "committee rescinded its quarterly velvet subsidy, whereupon the librarian " \
                   "transposed every ledger into a dialect of polite thunder and the harbor master " \
                   "filed the receipts under migratory arithmetic. By the third equinox the bicycle " \
                   "notaries had memorized the lullaby of the copper escalator, yet none could " \
                   "explain why the persimmon auditors kept rotating the lighthouse."

    # Three independent labs, on purpose. Agreement across model families is the strongest evidence
    # available here: it distinguishes "this text is widely duplicated on the internet" from "one
    # lab's pipeline happened to scrape it". A hit on all three is close to conclusive; a hit on one
    # is a fact about that model.
    MODELS = {
      "claude" => { model: "claude-opus-4-8",   label: "Claude Opus", key: :anthropic },
      "gpt"    => { model: "gpt-5.5",           label: "GPT-5.5",     key: :openai },
      "gemini" => { model: "gemini-2.5-pro",    label: "Gemini 2.5 Pro", key: :gemini }
    }.freeze

    # Only probe providers we actually hold a key for, so a missing key degrades the panel instead
    # of erroring every probe.
    def self.available_models
      MODELS.select { |_k, spec| AnalyzerConfig.key_for?(spec[:key]) }.keys
    end

    def initialize(passages, models: MODELS.keys, max_calls: nil)
      @passages = Array(passages)
      @models = models
      @max_calls = max_calls || AnalyzerConfig::MAX_MODEL_CALLS_PER_ANALYSIS
    end

    # Probes every passage against every model, capped by BOTH a call budget and a wall-clock
    # deadline. The call cap bounds spend; the deadline bounds time, which the call cap cannot:
    # per-call timeouts multiply across probes, so nine well-behaved-looking calls can still add up
    # to half an hour. Whatever finished before the deadline is returned and reported honestly.
    #
    # Yields each result as it lands so the UI streams instead of waiting for the slowest model.
    def call
      results = []
      calls = 0
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AnalyzerConfig::MEMORIZATION_DEADLINE

      @passages.each do |passage|
        next unless passage&.ok

        MODELS.slice(*@models).each do |_key, spec|
          break if calls >= @max_calls

          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            Rails.logger.warn("[memorization] deadline hit after #{calls} probes; returning partial results")
            return results
          end

          calls += 1
          r = probe(spec, passage.prefix, passage.truth, kind: "test")
                .merge(offset: passage.offset, source_label: passage.source_label,
                       source: passage.source.to_s.presence || "docs")
          results << r
          yield r if block_given?
        end
      end
      results
    end

    # A page counts as memorized if ANY span fired: reproducing 15+ consecutive words even once is
    # something you cannot do without having seen the text. The reverse does not hold, which is why
    # the summary reports how many spans were tried.
    def self.summarize(results)
      tested = results.reject { |r| r[:error] }
      best = tested.max_by { |r| r[:run].to_i }
      { spans_tested: tested.map { |r| r[:offset] }.uniq.size,
        probes: tested.size,
        best_run: best&.dig(:run).to_i,
        verdict: best&.dig(:verdict) || "none",
        models_fired: tested.select { |r| r[:run].to_i >= PARTIAL_RUN }.map { |r| r[:provider] }.uniq,
        # Separate from models_fired, which counts anything past the weak bar. Written as one list,
        # a run where GPT reproduced 54 words and Claude managed 7 came out as "Claude Opus and
        # GPT-5.5 reproduce 54 consecutive words", which credits Claude with GPT's result.
        models_strong: tested.select { |r| r[:run].to_i >= STRONG_RUN }.map { |r| r[:provider] }.uniq,
        cost_cents: tested.sum { |r| r[:cost_cents].to_f }.round(3) }
    end

    # One row per model, one cell per source, so the chart can put "your docs" and "your repo" side
    # by side under each lab. Best run per cell, because a page counts as recalled if ANY span fired
    # and averaging across spans would bury the one hit that proves inclusion.
    #
    # `probes` per cell is carried too: a cell reading 0 after three attempts and a cell reading 0
    # because it was never asked are different answers, and only one of them is evidence.
    def self.matrix(results, sources: %w[passage docs repo])
      tested = results.reject { |r| r[:error] }
      MODELS.values.map { |spec| spec[:label] }.filter_map do |label|
        rows = tested.select { |r| r[:provider] == label }
        next if rows.empty?

        # Symbol keys on purpose. A live broadcast passes this hash straight to the view while a
        # reloaded page gets it back through `as_json` and `deep_symbolize_keys`, and string keys
        # here made those two paths disagree: the chart drew from the database and came up empty
        # against the socket.
        cells = sources.map(&:to_sym).index_with do |source|
          in_source = rows.select { |r| r[:source].to_s == source.to_s }
          next nil if in_source.empty?

          best = in_source.max_by { |r| r[:run].to_i }
          { run: best[:run].to_i, verdict: best[:verdict], probes: in_source.size,
            matched: best[:matched], source_label: best[:source_label] }
        end

        { model: label, cells: cells.compact }
      end
    end

    # Best run per source across every model, for the one-line answer above the chart.
    def self.by_source(results)
      results.reject { |r| r[:error] }.group_by { |r| r[:source].to_s.presence || "docs" }
             .transform_values { |rows| summarize(rows) }
    end

    def controls
      out = []
      MODELS.slice(*@models).each do |_key, spec|
        out << probe(spec, *split(MIT_CONTROL), kind: "control+", label: "MIT license (must fire)")
        out << probe(spec, *split(FAKE_CONTROL), kind: "control-", label: "Fabricated text (must not fire)")
      end
      out
    end

    private

    def split(text)
      w = text.split
      [ w.first(Passage::SEED_WORDS).join(" "),
       w.drop(Passage::SEED_WORDS).first(Passage::TRUTH_WORDS).join(" ") ]
    end

    def probe(spec, prefix, truth, kind:, label: nil)
      started = Time.now
      # No temperature setting: the current frontier models reject it as deprecated, and it is not
      # needed here. Repeat runs are served from Analyzer::Cache rather than re-sampled.
      chat = RubyLLM.chat(model: spec[:model])
      msg = chat.ask("#{PROMPT}\n\n#{prefix}")
      output = msg.content.to_s.strip
      run = longest_run(normalize(truth), normalize(output))

      { provider: spec[:label], model: spec[:model], kind:, label:,
        prefix:, truth:, output:,
        run:, overlap: ngram_overlap(normalize(truth), normalize(output)),
        verdict: verdict(run), matched: matched_span(truth, output),
        seconds: (Time.now - started).round(1),
        input_tokens: msg.input_tokens, output_tokens: msg.output_tokens,
        # RubyLLM returns a Cost object, not a number; .total is dollars. Budget is metered in cents
        # against this reported figure rather than a token estimate.
        cost_cents: ((msg.cost&.total || 0) * 100).round(4) }
    rescue StandardError => e
      { provider: spec[:label], model: spec[:model], kind:, label:, error: e.message[0, 200],
        verdict: "error", run: 0, overlap: 0.0 }
    end

    def verdict(run)
      return "strong" if run >= STRONG_RUN
      return "partial" if run >= PARTIAL_RUN

      "none"
    end

    def normalize(text) = text.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").split

    def longest_run(a, b)
      return 0 if a.empty? || b.empty?

      prev = Array.new(b.size + 1, 0)
      best = 0
      a.each do |wa|
        cur = Array.new(b.size + 1, 0)
        b.each_with_index do |wb, j|
          next unless wa == wb

          cur[j + 1] = prev[j] + 1
          best = cur[j + 1] if cur[j + 1] > best
        end
        prev = cur
      end
      best
    end

    def ngram_overlap(truth, out, n = 5)
      grams = truth.each_cons(n).to_a
      return 0.0 if grams.empty?

      seen = out.each_cons(n).to_set
      (grams.count { |g| seen.include?(g) }.to_f / grams.size).round(3)
    end

    # The literal overlapping words, so the UI can highlight what the model actually recalled
    # instead of asking the audience to trust a number.
    def matched_span(truth, output)
      a = normalize(truth)
      b = normalize(output)
      best = []
      a.each_index do |i|
        b.each_index do |j|
          k = 0
          k += 1 while a[i + k] && a[i + k] == b[j + k]
          best = a[i, k] if k > best.size
        end
      end
      best.join(" ")
    end
  end
end
