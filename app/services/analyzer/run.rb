# frozen_string_literal: true

module Analyzer
  # Orchestrates one analysis over the two things the visitor gave us: a documentation URL and a
  # GitHub repo. Either may be absent, and every step below skips cleanly when its half is missing.
  #
  # Ordering is chosen for the deck, not for tidiness. The reveal walks agent experience first, then
  # the two training funnels, then recall, so the checks are run in that order and each one yields
  # the moment it lands. The two that can stall (Common Crawl, the model probes) are last, which is
  # why the first slide is filled within a couple of seconds of a cold start.
  #
  # Nothing is inferred. An earlier version worked the repo out from the docs URL and, failing
  # everything else, fell back to the org's most-starred repo, which is a guess that renders exactly
  # like a measurement.
  #
  # Everything goes through Analyzer::Cache, so a run done before the demo replays instantly and is
  # labelled as cached rather than passed off as live.
  class Run
    STEPS = %i[target retrieval repo_signals code_channel web_channel memorization references].freeze

    # Spans per source. Two rather than three, because the probe now covers docs AND repo and the
    # call budget has to stretch across both. Memorization is sparse, so spans are where the signal
    # is: dropping to one span per source would turn a real hit into a coin flip.
    SPANS_PER_SOURCE = 2

    attr_reader :target, :results

    def initialize(target, refresh: false, models: Memorization::MODELS.keys)
      @target = target.is_a?(Target) ? target : Target.from_input(target)
      @refresh = refresh
      @models = models
      @results = {}
    end

    def valid? = @target.valid?

    def cache_status
      Cache.status(%i[retrieval repo_signals code_channel web_channel memorization], @target.cache_key)
    end

    # Yields [step, payload] as each completes. payload carries :result, :cached_at, :cache_hit.
    def call(&block)
      emit(:target, { result: @target.to_h, cache_hit: false, cached_at: nil }, &block)

      # 1. Agent experience, both halves. Pure HTTP, ~1-3s, so the first slide is filled almost
      #    immediately even on a cold run.
      if @target.url
        step(:retrieval, key: @target.url) { Retrieval.new(@target.url).call }.then { |p| block&.call(:retrieval, p) }
      end
      if @target.repo
        step(:repo_signals, key: @target.repo) { RepoSignals.new(@target.repo).call }
          .then { |p| block&.call(:repo_signals, p) }
      end

      # 2. The code funnel: GitHub, Software Heritage and the licence text, ~2-5s.
      if @target.repo
        step(:code_channel, key: @target.repo) { CodeChannel.new(@target.repo).call }
          .then { |p| block&.call(:code_channel, p) }
      end

      # 3. The web funnel: Common Crawl (the slow one) and the quality classifier.
      if @target.url
        step(:web_channel, key: @target.url) { WebChannel.new(@target.url).call }
          .then { |p| block&.call(:web_channel, p) }
      end

      # 4. Recall. Costs money, so it is last and strictly capped.
      step(:memorization) { memorization_payload }.then { |p| block&.call(:memorization, p) }

      # 5. Why, if anything fired: how widely the winning passage is duplicated in public code.
      #    Runs only when there is recall to explain, because the code-search endpoint allows ten
      #    requests a minute for the whole app and an unexplained null needs no explaining.
      step(:copies) { copies_payload }.then { |p| block&.call(:copies, p) }

      # 6. The pages that are known to be in the corpus, so the recall chart has a scale. Cached for
      #    30 days apiece, so this is free on all but one run a month.
      step(:references, key: "-") { { items: References.all(models: @models) } }
        .then { |p| block&.call(:references, p) }

      @results
    end

    private

    # One failing check must never take down the run. On stage, a Common Crawl timeout or a GitHub
    # rate limit should show as a single failed tile while everything else still renders.
    def step(name, key: nil, &block)
      payload = Cache.fetch(name, key || @target.cache_key, refresh: @refresh, &block)
      @results[name] = payload
      payload
    rescue StandardError => e
      Rails.logger.error("[analyzer] #{name} failed: #{e.class} #{e.message}")
      failed = { result: { error: "#{e.class}: #{e.message[0, 120]}" }, cache_hit: false, cached_at: nil }
      @results[name] = failed
      failed
    end

    def emit(name, payload)
      @results[name] = payload
      yield(name, payload) if block_given?
      payload
    end

    def memorization_payload
      passages = build_passages
      ok = passages.select(&:ok)
      return { error: passages.first&.error || "No testable prose found" } if ok.empty?

      unless Analyzer::ApiKeys.any?
        return { error: "No model API keys configured", passages: ok.map(&:to_h) }
      end

      probes = Memorization.new(ok, models: @models).call
      { passages: ok.map(&:to_h),
        probes: probes,
        summary: Memorization.summarize(probes),
        by_source: Memorization.by_source(probes),
        matrix: Memorization.matrix(probes),
        skipped: passages.reject(&:ok).map { |p| { source: p.source, error: p.error } },
        controls: controls }
    end

    # The passage that actually fired, run through the copy count, so the page can say WHY a model
    # has this rather than only that it does. Attributed to the winning probe specifically: a run
    # with three passages and one hit should explain the hit, not the average.
    def copies_payload
      mem = @results.dig(:memorization, :result)
      return { skipped: "the probe did not run" } unless mem.is_a?(Hash) && mem[:probes]

      best = Array(mem[:probes]).reject { |p| p[:error] }.max_by { |p| p[:run].to_i }
      return { skipped: "no recall to explain" } if best.nil? || best[:run].to_i < Copies::MIN_RUN

      found = Copies.for("#{best[:prefix]} #{best[:truth]}")
      return { skipped: "no distinctive phrase to search for" } if found.nil?

      found.merge(source: best[:source], source_label: best[:source_label], run: best[:run])
    end

    # Controls are byte-identical on every run, so paying for them per analysis is pure waste: they
    # were 2.01c of a 5.77c analysis, 35% of the bill, to re-learn that MIT still fires. Cached
    # globally per model set and refreshed daily, which is often enough to catch a provider change.
    def controls
      Cache.fetch(:controls, @models.sort.join("+"), ttl: 1.day) do
        Memorization.new([], models: @models).controls
      end[:result]
    end

    # Test both halves of what the visitor gave us, INTERLEAVED by span index.
    #
    # The order matters as much as the contents. Probing all of the docs spans and then all of the
    # repo spans means a call cap or the wall-clock deadline lands entirely on the repo, and the
    # chart then shows an empty repo column that looks like a negative result rather than an
    # unfinished one. Round-robin means whatever budget exists is spent evenly across both.
    def build_passages
      docs = @target.url ? tag(Passage.candidates_from_url(@target.url, count: SPANS_PER_SOURCE), :docs) : []
      repo = @target.repo ? tag(repo_passages, :repo) : []
      # The pasted paragraph goes FIRST and is never interleaved away. It is the one thing the
      # visitor typed out by hand, so it must not be the source the call budget runs out on.
      pasted = @target.passage ? tag(Passage.candidates_from_text(@target.passage, count: SPANS_PER_SOURCE), :passage) : []

      pasted + interleave(docs, repo)
    end

    def tag(passages, source)
      Array(passages).each { |p| p.source = source }
    end

    def interleave(a, b)
      [ a.length, b.length ].max.times.flat_map { |i| [ a[i], b[i] ] }.compact
    end

    # Prose first, because a docs repo should be judged on its docs. But plenty of repos are all
    # code: basecamp/fizzy has no prose file big enough to probe, and answering "no prose found" to
    # someone asking whether their CODE reached a corpus is refusing the actual question. Code is
    # what The Stack is mostly made of, so fall through and test it directly.
    #
    # Falling through on an UNUSABLE docs file matters as much as on a missing one. fizzy has docs/,
    # but the largest file there is API reference: endpoint tables and status codes, which the prose
    # filter rejects and nobody could continue from memory.
    def repo_passages
      info = Http.json("https://api.github.com/repos/#{@target.repo}", headers: gh_headers)
      return [] unless info

      branch = info["default_branch"]

      # A pinned file beats both pickers. The pickers answer "what is the largest hand-written file
      # here", which is a guess at the project's signature code; for the repos we demo we have
      # measured the answer instead, and a demo should not re-roll a question already settled.
      if (pinned = Example.pinned_file(@target.repo))
        spans = Passage.candidates_from_repo_file(@target.repo, branch, pinned,
                                                  count: SPANS_PER_SOURCE, prose: false)
        return spans if spans.any?(&:ok)
      end

      if (path = docs_file(branch))
        prose = Passage.candidates_from_repo_file(@target.repo, branch, path, count: SPANS_PER_SOURCE)
        return prose if prose.any?(&:ok)
      end

      if (path = code_file(branch))
        Passage.candidates_from_repo_file(@target.repo, branch, path, count: SPANS_PER_SOURCE, prose: false)
      else
        []
      end
    end

    def gh_headers = Http.github_headers

    CODE_EXT = /\.(rb|js|jsx|ts|tsx|py|go|rs|java|kt|swift|c|cc|cpp|h|hpp|cs|php|ex|exs|scala|sh|sql)\z/i

    # Vendored, generated and minified files are duplicated across thousands of repos, so a model
    # continuing one says nothing about THIS project. Fixtures and lockfiles are the same problem.
    #
    # TEST files belong on this list too, and their absence had a visible cost: asked for the file
    # stripe/stripe-node is known for, the picker returned test/stripe.spec.ts, and vitest-dev/vitest
    # returned test/browser/specs/trace.test.ts. A test suite is the largest thing in plenty of
    # well-tested repos and the last thing anyone would call the project's signature code.
    SKIP_PATH = %r{(^|/)(vendor|node_modules|dist|build|tmp|coverage|\.github|
                   tests?|spec|__tests__|e2e|benchmarks?|examples?)/|
                   fixtures?/|\.min\.|-lock\.|_pb\.|\.generated\.|
                   [._-](test|spec)\.[a-z]+\z}xi

    # The largest hand-written source file, which is the closest thing to "the file this project is
    # actually known for" that a tree listing can tell us.
    def code_file(branch)
      nodes = tree(branch) or return nil

      nodes.select do |n|
        n["type"] == "blob" && n["path"].match?(CODE_EXT) && !n["path"].match?(SKIP_PATH) &&
          n["size"].to_i.between?(2_000, 60_000)
      end.max_by { |n| n["size"].to_i }&.fetch("path", nil)
    end

    # Pick the most prose-heavy markdown under docs/, matching how the research probe chose passages:
    # size alone selects tables of config flags, which nobody could continue from memory.
    def docs_file(branch)
      nodes = tree(branch) or return nil

      md = nodes.select do |n|
        n["type"] == "blob" && n["path"] =~ /\.mdx?$/i &&
          n["path"] !~ /CHANGELOG|LICENSE|CONTRIBUTING|CODE_OF_CONDUCT/i &&
          n["size"].to_i.between?(2_000, 60_000)
      end
      docs = md.select { |n| n["path"].include?("docs/") || n["path"].include?("content/") }
      (docs.presence || md).max_by { |n| n["size"].to_i }&.fetch("path", nil)
    end

    # One tree listing serves both file pickers. Fetching it twice doubled the cost of the most
    # expensive GitHub call in the run, on repos where the recursive tree is megabytes.
    def tree(branch)
      return @tree if defined?(@tree)

      data = Http.json("https://api.github.com/repos/#{@target.repo}/git/trees/#{branch}?recursive=1",
                       headers: gh_headers)
      @tree = data && data["tree"]
    end
  end
end
