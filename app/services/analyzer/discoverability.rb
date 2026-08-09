# frozen_string_literal: true

module Analyzer
  # Agent experience, as two columns of boxes: your docs site and your repo.
  #
  # The question is whether an agent can DISCOVER your product, EVALUATE it, and SUGGEST it. It
  # stops there. Whether that agent can then install, configure, deploy, use or buy it is a separate
  # question and nothing here measures it, which the page says out loud rather than letting the
  # green ticks imply more than they cover.
  #
  # A box that is not ticked is never left as a bare negative. Every one carries the change to make
  # and a link to the part of /learn that explains why it matters, because "Sitemap: no" is a fact
  # and a fact is not advice.
  class Discoverability
    # status: :pass | :fail | :info | :unknown | :waiting
    Item = Struct.new(:label, :status, :detail, :action, :anchor, :anchor_label, keyword_init: true)
    # state: :ready | :waiting | :missing | :error
    Column = Struct.new(:key, :title, :subject, :state, :note, :items, keyword_init: true)

    # The one sentence that stops the ticks from being read as a bigger claim than they are.
    SCOPE = "Discover, evaluate and suggest. Whether an agent can then install, configure, deploy " \
            "or buy your product is a separate question, and nothing here measures it."

    def initialize(payloads)
      @payloads = payloads || {}
    end

    def columns = [ docs_column, repo_column ]

    # Every unticked box across both columns, so the deck can show a count before the detail.
    def open_items = columns.flat_map(&:items).select { |i| i.status == :fail }

    def ready? = columns.any? { |c| c.state == :ready }

    private

    # --- docs ------------------------------------------------------------------------------------

    def docs_column
      subject = target[:docs_url]
      return column(:docs, "Your documentation site", nil, :missing) if subject.blank?

      r = result("retrieval")
      return column(:docs, "Your documentation site", subject, :waiting) if r.nil?
      return column(:docs, "Your documentation site", subject, :error, note: r[:error]) if r[:error].present?

      column(:docs, "Your documentation site", subject, :ready, items: docs_items)
    end

    def docs_items
      [
        item("AI crawlers allowed", pass?("retrieval", "Crawlers allowed"),
             detail: detail("retrieval", "Crawlers allowed"),
             action: "Decide which crawlers you want, then allow those by name in robots.txt. Each " \
                     "lab runs separate agents for training, for search and for a user asking it to " \
                     "open your page.",
             anchor: "crawlers", anchor_label: "the crawlers and what each one feeds"),

        item("Fetches as a crawler", pass?("retrieval", "Reachable by a crawler"),
             detail: detail("retrieval", "Reachable by a crawler"),
             action: "Let crawler user agents through the edge. robots.txt permits them and the " \
                     "request still fails, which points at a WAF or bot rule.",
             anchor: "reachable", anchor_label: "why allowed and reachable differ"),

        item("Source text an agent can read", clean_text?,
             detail: clean_text_detail,
             action: "Serve the page source as markdown, either at a .md twin URL or through " \
                     "content negotiation. Without it an agent spends its budget parsing your theme.",
             anchor: "clean-text", anchor_label: "content negotiation and markdown twins"),

        item("Listed in sitemap.xml", pass?("retrieval", "Sitemap"),
             detail: detail("retrieval", "Sitemap"),
             action: "Ship a sitemap.xml. Without one, crawlers reach deep pages far less often, " \
                     "and the pages they miss are the new ones you most want read.",
             anchor: "sitemap", anchor_label: "crawl budget"),

        # Deliberately not a failure. It is widely adopted and currently used by no major AI system,
        # so scoring it would hand out an action item that buys nothing.
        Item.new(label: "llms.txt", status: :info,
                 detail: detail("retrieval", "llms.txt"),
                 anchor: "llms-txt", anchor_label: "what llms.txt is currently worth")
      ]
    end

    def clean_text?
      md = pass?("retrieval", "Markdown twin (.md)")
      neg = pass?("retrieval", "Markdown content negotiation")
      return true if md || neg
      return false if md == false && neg == false

      nil
    end

    def clean_text_detail
      return "#{target[:docs_url]}.md serves markdown" if pass?("retrieval", "Markdown twin (.md)")
      return "serves text/markdown on Accept" if pass?("retrieval", "Markdown content negotiation")

      "no .md twin and no content negotiation"
    end

    # --- repo ------------------------------------------------------------------------------------

    def repo_column
      subject = target[:repo]
      return column(:repo, "Your open source repo", nil, :missing) if subject.blank?

      r = result("repo_signals")
      return column(:repo, "Your open source repo", subject, :waiting) if r.nil?
      return column(:repo, "Your open source repo", subject, :error, note: r[:error]) if r[:error].present?
      return column(:repo, "Your open source repo", subject, :error, note: r[:reason]) unless r[:present]

      column(:repo, "Your open source repo", subject, :ready, items: repo_items)
    end

    ADVICE = {
      "Public on GitHub" =>
        [ "Make the repo public. A private repo is invisible to every agent and every corpus.",
         "code-channel", "what a public repo unlocks" ],
      "README explains the project" =>
        [ "Open the README with what the project does and who it is for, in prose. An agent quotes " \
         "the README when it recommends you, and a badge row gives it nothing to quote.",
         "repo-readme", "why the README carries the most weight" ],
      "Description and topics set" =>
        [ "Fill in the repo description and add topics. Those are the fields GitHub search matches " \
         "on, and search is how an agent finds you when it does not already know your name.",
         "repo-metadata", "the fields GitHub search reads" ],
      "Tagged releases" =>
        [ "Publish tagged releases. They give an agent a version to name instead of pointing someone " \
         "at whatever is on main today.",
         "repo-releases", "why a version number matters" ],
      nil => [ "Push something. Recency is weighed by agents and by the people reading their answers.",
              "repo-activity", "how recency is read" ]
    }.freeze

    def repo_items
      mapped = Array(result("repo_signals")&.dig(:checks)).map do |c|
        action, anchor, label = ADVICE[c[:name]] || ADVICE[nil]
        item(c[:name], c[:pass], detail: c[:detail], action: action, anchor: anchor, anchor_label: label)
      end

      mapped.insert(3, license_item)
    end

    # `no_license` is the class name, and printing it raw put "(no license)" next to a row headed
    # "Licence", which reads as a typo. LICENSE here is the FILENAME, so the spelling is right.
    LICENCE_NAMES = { "no_license" => "no LICENSE file", "permissive" => "permissive",
                      "copyleft" => "copyleft", "source_available" => "source-available",
                      "content" => "content licence", "unknown" => "unclassified" }.freeze

    # The licence read as an AGENT reads it, which is a different question from whether a corpus
    # keeps the files, and the two answers frequently disagree. A repo with no LICENSE file is kept
    # by The Stack v2/v3 and may be used by nobody; showing only the corpus answer would tell
    # someone their licence situation is fine when adoption is the thing it blocks.
    #
    # The classification comes from code_channel, which reads the actual LICENSE text rather than
    # GitHub's spdx_id. Reclassifying here would mean fetching and parsing the same file twice.
    def license_item
      code = result("code_channel")
      if code.nil? || (!code[:present] && code[:license_class].blank?)
        return Item.new(label: "Licence an agent can act on", status: :waiting,
                        detail: "reading the licence text", anchor: License::ANCHOR,
                        anchor_label: "what each licence means for an agent")
      end

      implication = License.for(code[:license_class])
      name = code[:license_label].presence || LICENCE_NAMES[code[:license_class].to_s] || "unclassified"

      Item.new(label: "Licence an agent can act on", status: implication.status,
               detail: "#{implication.headline} (#{name})",
               action: (implication.status == :pass ? nil : implication.detail),
               anchor: License::ANCHOR, anchor_label: "what each licence means for an agent")
    end

    # --- shared ----------------------------------------------------------------------------------

    def column(key, title, subject, state, items: [], note: nil)
      Column.new(key: key, title: title, subject: subject, state: state, note: note, items: items)
    end

    def item(label, pass, detail:, action:, anchor:, anchor_label:)
      status = case pass
      when true then :pass
      when false then :fail
      else :unknown
      end
      Item.new(label: label, status: status, detail: detail,
               action: (status == :pass ? nil : action), anchor: anchor, anchor_label: anchor_label)
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
