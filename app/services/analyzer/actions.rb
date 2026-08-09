# frozen_string_literal: true

module Analyzer
  # What to do about the result, ordered by how much it changes.
  #
  # A finding is not advice. "In Common Crawl: no" tells a visitor nothing about whether that is
  # worth their afternoon, and the honest answer depends on the rest of the run: a page whose repo
  # is already collected does not need the web channel rescued, and a page whose robots.txt blocks
  # every crawler cannot be helped by a sitemap.
  #
  # So each item carries three things: the change to make, the outcome of NOT making it, and a link
  # into /learn where the mechanism is explained. Ranking is contextual, which is the part a static
  # checklist cannot do.
  #
  # Two rules keep this from turning into generic SEO advice:
  #
  #   1. Never invent an action for a check that did not complete. A GitHub rate limit is a fact
  #      about our server, and telling someone to publish a repo they already have would destroy
  #      the credibility of every other line.
  #   2. Never tell someone to open a gate they closed on purpose. A robots.txt that blocks AI
  #      crawlers is a decision; the item says so and states what it costs, rather than assuming.
  class Actions
    # impact: :high | :medium | :low, which is what the ordering and the tag render from.
    Item = Struct.new(:key, :title, :why, :impact, :anchor, :anchor_label, keyword_init: true)

    IMPACT_ORDER = { high: 0, medium: 1, low: 2 }.freeze

    def initialize(payloads)
      @payloads = payloads || {}
    end

    # Open items, most valuable first.
    #
    # A run that is only a pasted paragraph gets none. Every item here is advice about a site or a
    # repo, and someone who pasted a paragraph asked about neither: telling them to ship a sitemap
    # would be the page answering a question nobody put to it.
    def items
      return [] if passage_only?

      list = training_items + retrieval_items + repo_items
      list.compact.sort_by { |item| IMPACT_ORDER.fetch(item.impact, 3) }
    end

    # Things that are already true. Shown collapsed, because a visitor who did the work should see
    # it acknowledged rather than have it disappear into a green tick they have to hunt for.
    def settled
      return [] if passage_only?

      out = []
      out << "The docs source is in a public repo, archived and licensed for inclusion." if code_open?
      out << "Common Crawl has this URL." if pass?("web_channel", "In Common Crawl")
      out << "The page clears the FineWeb-Edu keep bar." if pass?("web_channel", "Passes the quality filter")
      out << "AI crawlers are allowed and the page fetches cleanly." if crawlable?
      out << "Agents can get the source text, not just rendered HTML." if clean_text?
      out << "A sitemap points crawlers at your pages." if pass?("retrieval", "Sitemap")
      out << "Models already reproduce this text verbatim." if memorized?
      out + settled_repo_signals
    end

    def settled_repo_signals
      Array(result("repo_signals")&.dig(:checks)).filter_map do |c|
        "#{c[:name]}: #{c[:detail]}." if c[:pass]
      end
    end

    private

    # --- training -------------------------------------------------------------------------------

    def training_items
      [ repo_item, archive_item, license_item, crawl_item, quality_item, canonical_item ]
    end

    # The highest-value change on the whole page: the code channel has no prose quality filter, so a
    # reference page that can never pass the web filter still reaches a corpus through the repo.
    #
    # Two different situations produce this item, and they need different wording. Nothing is
    # inferred any more, so "you left the repo box empty" is a fact about the FORM and must not be
    # reported as "you have no repo".
    def repo_item
      return no_repo_given_item if target[:repo].blank?

      code = result("code_channel")
      return nil if code.nil? || code[:error].present?
      return nil if code[:present] || code[:transient]

      Item.new(key: :repo, impact: :high,
               title: "Publish the docs source in a public repo",
               why: "#{code[:reason]} Code corpora take Markdown with no prose-quality filter, so " \
                    "this is the one route a reference page can take without being rewritten.",
               anchor: "code-channel", anchor_label: "how the code channel works")
    end

    def no_repo_given_item
      Item.new(key: :repo, impact: :high,
               title: "Give us a repo, or publish one",
               why: "You ran this with the repo box empty, so the entire code channel went " \
                    "unmeasured. That channel takes Markdown with no prose-quality filter, and it " \
                    "is the route most reference documentation can actually take.",
               anchor: "code-channel", anchor_label: "how the code channel works")
    end

    def archive_item
      code = result("code_channel")
      return nil unless code&.dig(:present)
      return nil if code[:swh_archived]
      # Observed membership in v3 already proves collection; nagging about SWH would be noise.
      return nil if code[:in_stack_v3] == true

      Item.new(key: :archive, impact: :high,
               title: "Get #{code[:repo]} archived by Software Heritage",
               why: "The Stack v2 was built from that archive and SWH-based corpora keep coming, " \
                    "and archival is a separate step from being public on GitHub. It is the one " \
                    "collection path a maintainer can trigger directly.",
               anchor: "software-heritage", anchor_label: "why archival is its own gate")
    end

    def license_item
      code = result("code_channel")
      return nil unless code&.dig(:present)
      return nil unless code[:kept_by_stack] == false

      Item.new(key: :license, impact: :high,
               title: "License the docs directory permissively",
               why: "#{code[:license_label].presence || 'This licence'} is dropped by name when " \
                    "corpora are built, so the repo is collected and the files are then discarded. " \
                    "Splitting the docs into a permissively licensed directory is usually easier " \
                    "than relicensing the product.",
               anchor: "licenses", anchor_label: "which licences corpora keep")
    end

    # Web-channel work is worth far less when the code channel already carries the same text, so the
    # impact is computed rather than fixed. Ranking a sitemap above a missing repo would be advice
    # that sounds thorough and wastes the visitor's week.
    def crawl_item
      return nil unless pass?("web_channel", "In Common Crawl") == false

      Item.new(key: :crawl, impact: code_open? ? :low : :medium,
               title: "Earn links to this page and list it in sitemap.xml",
               why: "Common Crawl never fetched this URL, so no corpus built from it can contain " \
                    "the page. It samples by domain centrality and never copies a site in full, so " \
                    "deep pages with few inbound links are the ones it skips." +
                    (code_open? ? " The code channel already carries this text, which is why this " \
                                  "is listed low." : ""),
               anchor: "web-channel", anchor_label: "how Common Crawl samples")
    end

    def quality_item
      check = check("web_channel", "Passes the quality filter")
      return nil unless check && check[:pass] == false

      Item.new(key: :quality, impact: code_open? ? :low : :medium,
               title: "Rewrite the opening so it teaches",
               why: "This page scores #{check[:score]} against FineWeb-Edu, under the 2.5 keep bar, " \
                    "so an open web pipeline discards it even after crawling. Only the first ~512 " \
                    "tokens are scored. Reference pages rarely clear the bar at all, which is the " \
                    "reason the code channel matters more than this one.",
               anchor: "quality-filter", anchor_label: "what the filter rewards")
    end

    # Nothing to fix, and the most useful thing to say to someone who is already in.
    def canonical_item
      return nil unless memorized?

      Item.new(key: :canonical, impact: :low,
               title: "Keep the reproduced snippet current",
               why: "Models reproduce this page today, which means the version they learned is the " \
                    "one users get when nobody looks anything up. Changing the canonical snippet " \
                    "now costs you years of drift, so keep the fetchable copy correct and let live " \
                    "retrieval carry corrections.",
               anchor: "outcomes", anchor_label: "what being in the training data costs")
    end

    # --- retrieval ------------------------------------------------------------------------------

    def retrieval_items
      [ robots_item, waf_item, clean_text_item, sitemap_item ]
    end

    def robots_item
      return nil unless pass?("retrieval", "Crawlers allowed") == false

      Item.new(key: :robots, impact: :high,
               title: "Decide which crawlers you actually want",
               why: "#{detail("retrieval", "Crawlers allowed")}. Each lab runs separate agents for " \
                    "training, for search and for a user asking it to open your page, and " \
                    "robots.txt treats them separately. If this block is deliberate, the training " \
                    "results below are moot and that is a legitimate choice.",
               anchor: "crawlers", anchor_label: "the crawlers and what each one feeds")
    end

    def waf_item
      return nil unless pass?("retrieval", "Reachable by a crawler") == false

      Item.new(key: :waf, impact: :high,
               title: "Let crawler user agents through the edge",
               why: "robots.txt permits crawlers and the page still fails to fetch as one, which " \
                    "points at a WAF or bot rule. An agent asked to read this page gets nothing.",
               anchor: "reachable", anchor_label: "why allowed and reachable differ")
    end

    def clean_text_item
      return nil if clean_text?
      return nil unless result("retrieval")

      Item.new(key: :clean_text, impact: :medium,
               title: "Serve the source text to agents",
               why: "There is no .md twin and no content negotiation, so an agent fetching this " \
                    "page spends its budget parsing your theme instead of reading your sentences. " \
                    "Either mechanism fixes it.",
               anchor: "clean-text", anchor_label: "content negotiation and markdown twins")
    end

    def sitemap_item
      return nil unless pass?("retrieval", "Sitemap") == false

      Item.new(key: :sitemap, impact: :medium,
               title: "Ship a sitemap.xml",
               why: "Without one, crawlers reach deep pages far less often, and the pages they " \
                    "miss are the new ones you most want read.",
               anchor: "sitemap", anchor_label: "crawl budget")
    end

    # --- the repo as an agent reads it -----------------------------------------------------------

    # These change what an agent can say about you TODAY, which is a faster payoff than anything in
    # the training list, and they are cheap. They rank below the corpus work because a README rewrite
    # does not put you in a corpus, and above nothing because a repo an agent cannot summarise will
    # not be recommended by one.
    # The detail is always a MEASURED clause and always leads, so every line opens with the finding
    # rather than with advice the reader has no reason to accept yet.
    REPO_ADVICE = {
      "README explains the project" =>
        [ :medium, "Open the README with what this does and who it is for",
         "An agent quotes the README when it recommends you, and a badge row gives it nothing to " \
         "quote.",
         "repo-readme", "why the README carries the most weight" ],
      "Description and topics set" =>
        [ :medium, "Fill in the repo description and topics",
         "Those are the fields GitHub search matches on, and search is how an agent finds you when " \
         "it does not already know your name.",
         "repo-metadata", "the fields GitHub search reads" ],
      "Tagged releases" =>
        [ :low, "Publish tagged releases",
         "A release gives an agent a version to name instead of pointing someone at whatever is on " \
         "main today.",
         "repo-releases", "why a version number matters" ],
      "Active in the last 12 months" =>
        [ :low, "Push something, or say in the README that the project is finished",
         "Recency is weighed by agents and by the people reading their answers, and a finished " \
         "project that says so answers the question directly.",
         "repo-activity", "how recency is read" ]
    }.freeze

    def repo_items
      signals = result("repo_signals")
      return [] unless signals&.dig(:present)

      Array(signals[:checks]).filter_map do |c|
        next unless c[:pass] == false

        advice = REPO_ADVICE[c[:name]]
        next unless advice

        impact, title, why, anchor, label = advice
        Item.new(key: :"repo_#{c[:name].parameterize(separator: '_')}", impact: impact, title: title,
                 why: "#{signals[:repo]}: #{c[:detail]}. #{why}", anchor: anchor, anchor_label: label)
      end
    end

    # --- shared ---------------------------------------------------------------------------------

    def target = result("target") || {}

    def passage_only?
      target[:passage].present? && target[:docs_url].blank? && target[:repo].blank?
    end

    def code_open?
      code = result("code_channel")
      return false unless code&.dig(:present)
      return true if code[:in_stack_v3] == true
      return false if code[:in_stack_v3] == false

      code[:swh_archived] && code[:kept_by_stack] == true
    end

    def memorized?
      summary = result("memorization")&.dig(:summary)
      summary && summary[:verdict] == "strong"
    end

    def crawlable?
      pass?("retrieval", "Crawlers allowed") && pass?("retrieval", "Reachable by a crawler")
    end

    def clean_text?
      pass?("retrieval", "Markdown twin (.md)") || pass?("retrieval", "Markdown content negotiation")
    end

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
