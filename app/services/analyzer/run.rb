# frozen_string_literal: true

module Analyzer
  # Orchestrates one analysis.
  #
  # Ordering is chosen for the demo, not for tidiness: the checks that answer in ~1s run first and
  # the ones that can stall run last, so the screen fills immediately and Common Crawl's 40s worst
  # case never blocks anything else. Each step yields the moment it lands.
  #
  # Everything goes through Analyzer::Cache, so a run you did before the demo replays instantly and
  # is labelled as cached rather than passed off as live.
  class Run
    STEPS = %i[target retrieval code_channel web_channel memorization].freeze

    # repo_source explains HOW the repo was identified, so the UI can distinguish a near-certain
    # match from a guess instead of presenting both as fact.
    attr_reader :target, :results, :repo_source

    def initialize(input, refresh: false, models: Memorization::MODELS.keys)
      @target = Target.new(input)
      @refresh = refresh
      @models = models
      @results = {}
    end

    def valid? = @target.valid?

    def cache_status
      Cache.status(%i[retrieval code_channel web_channel memorization], cache_target)
    end

    # Yields [step, payload] as each completes. payload carries :result, :cached_at, :cache_hit.
    def call
      yield_step(:target, { result: @target.to_h, cache_hit: false, cached_at: nil }) { |s, p| yield(s, p) if block_given? }

      # 1. Retrieval: ~1-2s, pure HTTP. Fills the screen straight away.
      if @target.url
        step(:retrieval) { Retrieval.new(@target.url).call }.then { |p| yield(:retrieval, p) if block_given? }
      end

      # 2. Code channel: GitHub + Software Heritage + licence text, ~2-5s.
      repo = @target.repo || infer_repo
      step(:code_channel, key: repo.to_s) { CodeChannel.new(repo).call }
        .then { |p| yield(:code_channel, p) if block_given? }

      # 3. Web channel: Common Crawl (the slow one) + the quality classifier.
      if @target.url
        step(:web_channel) { WebChannel.new(@target.url).call }.then { |p| yield(:web_channel, p) if block_given? }
      end

      # 4. Memorization: costs money, so it is last and strictly capped.
      step(:memorization) { memorization_payload(repo) }.then { |p| yield(:memorization, p) if block_given? }

      @results
    end

    private

    def cache_target = @target.url || @target.repo

    # One failing check must never take down the run. On stage, a Common Crawl timeout or a GitHub
    # rate limit should show as a single failed row while everything else still renders.
    def step(name, key: nil, &block)
      payload = Cache.fetch(name, key || cache_target, refresh: @refresh, &block)
      @results[name] = payload
      payload
    rescue StandardError => e
      Rails.logger.error("[analyzer] #{name} failed: #{e.class} #{e.message}")
      failed = { result: { error: "#{e.class}: #{e.message[0, 120]}" }, cache_hit: false, cached_at: nil }
      @results[name] = failed
      failed
    end

    def yield_step(name, payload)
      @results[name] = payload
      yield(name, payload) if block_given?
      payload
    end

    # A docs URL usually has a repo behind it, and finding the RIGHT one is what makes the licence
    # and collection verdicts meaningful for someone who only pasted a documentation link.
    #
    # Owner first, then the repo inside it. Two failures drove this order:
    #   - Deriving the owner from the domain breaks when they differ. tailwindcss.com belongs to the
    #     `tailwindlabs` org, so "tailwindcss/tailwindcss.com" 404s.
    #   - Counting links returns the PRODUCT repo, because tailwindcss.com links
    #     tailwindlabs/tailwindcss far more than tailwindlabs/tailwindcss.com. A repo named after
    #     the site is unambiguous: someone deliberately named it that.
    #
    # Records HOW the repo was found. "Named after this site" is near-certain, "most-linked" is a
    # guess, and the UI must not present them as equally solid.
    def infer_repo
      return nil unless @target.url

      host = URI.parse(@target.url).host.to_s.downcase.sub(/\Awww\./, "")
      owner = link_owner || org_label(host)
      return nil if owner.blank?

      if (r = by_name(owner, host) || by_name(owner, host.sub(/\A[^.]+\./, "")))
        @repo_source = "repo named after this site"
        return r
      end
      if (r = %w[docs website site].lazy.filter_map { |n| by_name(owner, n) }.first)
        @repo_source = "the org's docs repo"
        return r
      end
      if (r = link_repo)
        @repo_source = "linked from the page"
        return r
      end

      @repo_source = "the org's most-starred repo (inferred, may not hold these docs)"
      most_starred(owner)
    end


    # The owner that appears most often in GitHub links on the page.
    def link_owner
      body = Http.probe(@target.url, timeout: 10)[:body].to_s
      owners = body.scan(%r{github\.com/([\w-]+)/[\w.-]+}i).flatten
                   .reject { |o| %w[sponsors orgs features about pricing login topics apps marketplace].include?(o.downcase) }
      owners.tally.max_by { |_, n| n }&.first
    end

    # Most docs sites link their own repo somewhere on the page. An "Edit this page" link is the
    # single most reliable signal there is, because it points at the file being rendered: it names
    # the DOCS repo rather than the product repo, which are frequently different
    # (docs.anycable.io lives in anycable/docs.anycable.io, not anycable/anycable).
    def link_repo
      body = Http.probe(@target.url, timeout: 10)[:body].to_s

      edit = body.scan(%r{github\.com/([\w-]+)/([\w.-]+?)/(?:edit|blob|tree)/}i)
                 .map { |o, r| "#{o}/#{r}" }
      return edit.tally.max_by { |_, n| n }&.first if edit.any?

      links = body.scan(%r{github\.com/([\w-]+)/([\w.-]+)}i)
                  .map { |o, r| "#{o}/#{r.sub(/\.git\z/, '').sub(/[)\]"'].*\z/, '')}" }
                  .reject { |s| s.match?(%r{/(sponsors|orgs|features|about|pricing|login|topics)\z}i) }
      links.empty? ? nil : links.tally.max_by { |_, n| n }&.first
    end

    # Client-rendered docs sites ship no links in their HTML, so scraping finds nothing. Fall back
    # to the domain name: workos.com -> the `workos` org, then its most-starred repo. Inferred, and
    # flagged as such, but it is what makes the licence and collection verdicts available at all for
    # a site that never mentions its own repo.
    # Multi-part TLDs mean you cannot just take the last-but-one label either (foo.co.uk).
    KNOWN_SUBDOMAINS = %w[docs doc www api developer developers help support learn guide guides
                          reference blog get try app dashboard].freeze
    TWO_PART_TLDS = %w[co.uk com.au co.nz com.br co.jp co.il org.uk ac.uk].freeze

    # Order matters, and "most starred repo in the org" must be LAST.
    #
    # Docs commonly live in a repo named after the site itself: anycable/docs.anycable.io,
    # tailwindlabs/tailwindcss.com. Jumping straight to the org's flagship reported AnyCable's
    # licence and collection status from anycable/anycable, a different repo with a different
    # history, while claiming to describe the docs.
    def by_name(owner, name)
      return nil if name.blank?

      info = Http.json("https://api.github.com/repos/#{owner}/#{name}", headers: gh_headers)
      info && info["full_name"] ? info["full_name"] : nil
    end

    def most_starred(label)
      found = Http.json("https://api.github.com/search/repositories?q=user:#{label}&sort=stars&order=desc&per_page=1",
                        headers: gh_headers)
      found&.dig("items", 0, "full_name")
    end

    # docs.anycable.io -> "anycable", not "docs". Taking the first label searched GitHub for a user
    # called "docs" (and "api" for api.stripe.com), which quietly returned a stranger's repo.
    def org_label(host)
      parts = host.to_s.downcase.split(".")
      parts.shift while parts.length > 2 && KNOWN_SUBDOMAINS.include?(parts.first)

      tld_len = TWO_PART_TLDS.include?(parts.last(2).join(".")) ? 2 : 1
      registrable = parts[-(tld_len + 1)]
      registrable if registrable.present? && !KNOWN_SUBDOMAINS.include?(registrable)
    end

    def gh_headers
      t = AnalyzerConfig.github_token.to_s
      t.empty? ? {} : { "Authorization" => "Bearer #{t}" }
    end

    def memorization_payload(repo)
      passages = build_passages(repo)
      ok = passages.select(&:ok)
      return { error: passages.first&.error || "No testable prose found" } if ok.empty?

      unless AnalyzerConfig.anthropic_key? || AnalyzerConfig.openai_key?
        return { error: "No model API keys configured", passages: ok.map(&:to_h) }
      end

      probe = Memorization.new(ok, models: @models)
      probes = probe.call
      { passages: ok.map(&:to_h), probes: probes,
        summary: Memorization.summarize(probes), controls: controls(probe) }
    end

    # Controls are byte-identical on every run, so paying for them per analysis is pure waste: they
    # were 2.01c of a 5.77c analysis, 35% of the bill, to re-learn that MIT still fires. Cached
    # globally per model set and refreshed daily, which is often enough to catch a provider change.
    def controls(probe)
      Cache.fetch(:controls, @models.sort.join("+"), ttl: 1.day) { probe.controls }[:result]
    end

    # Test the text the user actually asked about.
    #
    # If they pasted a URL, probe THAT page (falling back to its markdown twin when the HTML is
    # client-rendered). Preferring the repo here was wrong: for workos.com/docs/authkit it wandered
    # off to a README inside the login-box demo repo and reported on text nobody asked about.
    # Only when the input is a repo do we go looking for its docs prose.
    def build_passages(repo)
      return Passage.candidates_from_url(@target.url) if @target.url

      return [] unless repo && (info = Http.json("https://api.github.com/repos/#{repo}"))

      path = docs_file(repo, info["default_branch"])
      path ? Passage.candidates_from_repo_file(repo, info["default_branch"], path) : []
    end

    # Pick the most prose-heavy markdown under docs/, matching how the research probe chose passages:
    # size alone selects tables of config flags, which nobody could continue from memory.
    def docs_file(repo, branch)
      tree = Http.json("https://api.github.com/repos/#{repo}/git/trees/#{branch}?recursive=1")
      return nil unless tree && tree["tree"]

      md = tree["tree"].select do |n|
        n["type"] == "blob" && n["path"] =~ /\.mdx?$/i &&
          n["path"] !~ /CHANGELOG|LICENSE|CONTRIBUTING|CODE_OF_CONDUCT/i &&
          n["size"].to_i.between?(2_000, 60_000)
      end
      docs = md.select { |n| n["path"].include?("docs/") || n["path"].include?("content/") }
      (docs.presence || md).max_by { |n| n["size"].to_i }&.fetch("path", nil)
    end
  end
end
