# frozen_string_literal: true

module Analyzer
  # The two questions a visitor actually arrived with, answered from whatever has landed so far:
  #
  #   1. Can an agent read this page today?
  #   2. Is this text in the training data?
  #
  # The four detail boxes below the answers are evidence, and evidence is not an answer. Reading
  # six retrieval rows, three licence rows, a Common Crawl miss and nine model probes and then
  # working out what it all means is a job the page should do for the visitor, not hand to them.
  #
  # Answers are computed from a PARTIAL results hash on purpose. Each step broadcasts as it lands,
  # so the headline starts coarse ("the code path is open, still asking the models") and sharpens.
  # Every intermediate state has to be true on its own: a spinner that resolves into a verdict at
  # the end teaches nothing while it spins.
  #
  # Two honesty rules are enforced here rather than in the copy, because a headline travels further
  # than a footnote:
  #
  #   - A null memorization result is never phrased as "not in the training data". Models memorize
  #     a fraction of what they read, so absence of recall is absence of evidence.
  #   - A check that did not complete (GitHub rate limit, Common Crawl down) never hardens into a
  #     negative. An unknown gate makes the whole answer unknown, never a "no".
  class Verdict
    # state: :pending (nothing yet) | :partial (still filling) | :final
    # tone:  :yes | :no | :mixed | :unknown, which is what the card colours from
    Answer = Struct.new(:key, :question, :state, :tone, :headline, :detail, :caveat, :cues,
                        keyword_init: true)
    # status: :pass | :fail | :unknown | :waiting
    Cue = Struct.new(:label, :status, keyword_init: true)

    def initialize(payloads, status: nil)
      @payloads = payloads || {}
      @status = status.to_s
    end

    def answers = [retrieval_answer, training_answer]

    # --- question 1: retrieval -------------------------------------------------------------------

    def retrieval_answer
      return repo_retrieval_answer if repo_only?

      r = result("retrieval")
      return waiting_answer(:retrieval) if r.nil?
      return unknown_answer(:retrieval, r[:error]) if r[:error].present?

      allowed   = pass?("retrieval", "Crawlers allowed")
      reachable = pass?("retrieval", "Reachable by a crawler")
      clean     = pass?("retrieval", "Markdown twin (.md)") || pass?("retrieval", "Markdown content negotiation")

      cues = [
        Cue.new(label: "robots.txt", status: status_of(allowed)),
        Cue.new(label: "fetches as a crawler", status: status_of(reachable)),
        Cue.new(label: "clean text for agents", status: status_of(clean))
      ]

      answer(:retrieval, state: :final, cues: cues, **retrieval_wording(allowed, reachable, clean))
    end

    # --- question 2: training data ---------------------------------------------------------------

    def training_answer
      code = code_path
      web  = web_path
      mem  = memorization_summary

      cues = [
        Cue.new(label: "code path", status: path_status(code)),
        Cue.new(label: "web path", status: path_status(web)),
        Cue.new(label: "model recall", status: recall_status(mem))
      ]

      wording = mem ? settled_training_wording(mem, code, web) : filling_training_wording(code, web)
      answer(:training, state: mem ? :final : (code.first == :waiting ? :pending : :partial),
             cues: cues, **wording)
    end

    private

    # --- wording ---------------------------------------------------------------------------------

    def retrieval_wording(allowed, reachable, clean)
      if allowed == false
        { tone: :no, headline: "No. robots.txt turns AI crawlers away.",
          detail: "#{detail_of('retrieval', 'Crawlers allowed')}. A disallowed crawler skips the " \
                  "page entirely, so nothing downstream can happen." }
      elsif reachable == false
        { tone: :no, headline: "No. The page does not fetch as a crawler.",
          detail: "robots.txt permits AI crawlers, and the request still fails as CCBot. A WAF or " \
                  "bot rule usually explains the gap." }
      elsif clean
        { tone: :yes, headline: "Yes, and agents can read the source text.",
          detail: "#{clean_text_detail} Crawlers are allowed and the page fetches cleanly as CCBot." }
      else
        { tone: :mixed, headline: "Yes, but only as rendered HTML.",
          detail: "No markdown twin and no content negotiation, so an agent parses your markup " \
                  "instead of reading the source. #{sitemap_detail}" }
      end
    end

    def clean_text_detail
      if pass?("retrieval", "Markdown twin (.md)")
        "A .md twin serves the page source."
      else
        "The page serves text/markdown when an agent asks for it."
      end
    end

    def sitemap_detail
      pass?("retrieval", "Sitemap") ? "A sitemap does point crawlers at it." :
                                      "There is no sitemap pointing crawlers at it either."
    end

    # Memorization has answered, so the answer is as sharp as this tool can make it.
    def settled_training_wording(mem, code, web)
      case mem[:verdict]
      when "strong"
        { tone: :yes,
          headline: "Yes. #{models_fired(mem)} reproduce #{mem[:best_run]} consecutive words of it.",
          detail: "You cannot reproduce text you have never seen, so this page reached a training " \
                  "corpus. #{route_sentence(code, web)}",
          caveat: nil }
      when "partial"
        { tone: :mixed,
          headline: "Maybe. #{models_fired(mem)} continued it for #{mem[:best_run]} words.",
          detail: "A run that short is phrasing thousands of documents share, so it is a hint " \
                  "rather than a finding. #{route_sentence(code, web)}",
          caveat: probe_caveat(mem) }
      else
        null_recall_wording(mem, code, web)
      end
    end

    # No model recalled it. What that MEANS depends entirely on whether a path into a corpus is
    # even open, which is why the two channel checks exist.
    def null_recall_wording(mem, code, web)
      open_paths = [code, web].select { |state, _| state == :open }

      if open_paths.any?
        { tone: :mixed, headline: "No evidence yet, and the door is open.",
          detail: "Open route: #{clauses(open_paths)}. That is how this text could reach a corpus. " \
                  "Nothing came back verbatim under our probes.",
          caveat: probe_caveat(mem) }
      elsif [code, web].any? { |state, _| %i[unknown waiting].include?(state) }
        { tone: :unknown, headline: "No evidence, and one channel could not be checked.",
          detail: "Unresolved: #{clauses([code, web].select { |s, _| %i[unknown waiting].include?(s) })}. " \
                  "No model reproduced the text, which on its own settles nothing.",
          caveat: probe_caveat(mem) }
      else
        { tone: :no, headline: "Unlikely. Every path we can check is closed.",
          detail: "No open route: #{clauses([code, web])}. No model reproduced the text either.",
          caveat: probe_caveat(mem) }
      end
    end

    # Still running. Say what is known, name what is still outstanding, and never pre-announce the
    # part that has not happened.
    def filling_training_wording(code, web)
      pending = []
      pending << "the web path" if web.first == :waiting
      pending << "model recall" if memorization_summary.nil?
      tail = pending.empty? ? "" : " Still checking #{pending.to_sentence}."

      landed = [code, web].reject { |state, _| state == :waiting }

      case code.first
      when :waiting
        { tone: :unknown, headline: "Working out whether it could reach a corpus…",
          detail: "Checking the code path first: a public repo skips the web quality filter that " \
                  "most documentation fails." }
      when :open
        { tone: :mixed, headline: "The code path is open.",
          detail: "Open route: #{clauses(landed.select { |s, _| s == :open })}.#{tail}" }
      when :unknown
        # Covers both a check that could not run and a licence whose outcome is genuinely ambiguous,
        # which is why the headline says unresolved rather than "could not be checked".
        { tone: :unknown, headline: "The code path is unresolved.",
          detail: "Unresolved: #{clauses([code])}.#{tail}" }
      else
        { tone: :mixed, headline: web.first == :open ? "The web path is open." : "No open path so far.",
          detail: "#{web.first == :open ? 'Open route' : 'Blocked so far'}: #{clauses(landed)}.#{tail}" }
      end
    end

    # The reason clauses are lowercase fragments carrying repo names and URLs, so they are never
    # sentence-cased: `upcase_first` turned workos/authkit-remix into Workos/authkit-remix, which
    # reads as a typo in the one sentence a visitor is most likely to quote.
    def clauses(paths) = paths.map(&:last).compact.to_sentence

    def route_sentence(code, web)
      open_paths = [code, web].select { |state, _| state == :open }
      return "" if open_paths.empty?

      "The likely route: #{clauses(open_paths)}."
    end

    def probe_caveat(mem)
      "A null result is weak evidence: models memorize a fraction of what they read. " \
        "#{mem[:spans_tested]} passages, #{mem[:probes]} probes. The comparison below shows what a " \
        "positive looks like under the identical probe."
    end

    def models_fired(mem) = Array(mem[:models_fired]).to_sentence.presence || "Models"

    # --- the two channels ------------------------------------------------------------------------

    # [state, reason] where state is :open, :blocked, :absent, :unknown or :waiting. The reason is a
    # clause, lowercase and without a full stop, so the wording methods can compose sentences.
    def code_path
      r = result("code_channel")
      return [:waiting, nil] if r.nil?
      return [:unknown, "the GitHub check did not complete"] if r[:error].present?

      unless r[:present]
        # A rate limit is a fact about this server, not about the repo, and must never read as one.
        return [:unknown, "the code path could not be checked (#{r[:reason]})"] if r[:transient]

        return [:absent, "no public repo carries this text"]
      end

      return [:blocked, "#{r[:repo]} is not archived by Software Heritage, and The Stack is built " \
                        "from that archive"] unless r[:swh_archived]

      # `kept_by_stack` arrives as a symbol from a live run and as a string from the stored JSON, so
      # everything but true/false is compared as text.
      case r[:kept_by_stack]
      when true then [:open, "#{r[:repo]} is public, archived and #{open_license_clause(r)}"]
      when false then [:blocked, "#{r[:repo]} is licensed #{license_name(r)}, which corpora drop as " \
                                 "non-permissive"]
      else
        if r[:kept_by_stack].to_s == "depends"
          [:unknown, "#{r[:repo]} carries a content licence, and whether a corpus keeps it turns " \
                     "on the share-alike terms"]
        else
          [:unknown, "#{r[:repo]} carries a licence we could not classify"]
        end
      end
    end

    # A missing LICENCE is the finding people get backwards, so it is never folded into "permissive".
    # The Stack v2/v3 keep unlicensed repos, and calling tailwindlabs/tailwindcss.com "permissively
    # licensed" would quietly delete the most surprising result the tool produces.
    def open_license_clause(r)
      return "unlicensed, which The Stack v2/v3 keep anyway" if r[:license_class].to_s == "no_license"

      "permissively licensed"
    end

    def license_name(r)
      r[:license_label].presence || r[:license_class].to_s.tr("_", " ")
    end

    def web_path
      r = result("web_channel")
      return [:waiting, nil] if r.nil?
      return [:unknown, "the web checks did not complete"] if r[:error].present?

      crawled = pass?("web_channel", "In Common Crawl")
      quality = pass?("web_channel", "Passes the quality filter")

      return [:blocked, "Common Crawl never fetched this URL"] if crawled == false
      return [:blocked, "it scores #{quality_score} on the quality filter, under the " \
                        "#{Analyzer::WebChannel::KEEP_BAR} keep bar"] if quality == false
      return [:unknown, "the Common Crawl index did not answer"] if crawled.nil?
      return [:unknown, "the quality scorer did not answer"] if quality.nil?

      [:open, "it is in Common Crawl and clears the quality bar"]
    end

    def quality_score = check("web_channel", "Passes the quality filter")&.dig(:score)

    def memorization_summary
      r = result("memorization")
      return nil if r.nil? || r[:error].present?

      r[:summary].presence
    end

    # --- shared plumbing -------------------------------------------------------------------------

    def answer(key, state:, tone:, headline:, cues:, detail: nil, caveat: nil)
      Answer.new(key: key, question: QUESTIONS[key], state: state, tone: tone, headline: headline,
                 detail: detail, caveat: caveat, cues: cues)
    end

    QUESTIONS = { retrieval: "Can an agent read this page today?",
                  training: "Is this text in the training data?" }.freeze

    def waiting_answer(key)
      answer(key, state: :pending, tone: :unknown, headline: "Checking…", cues: [])
    end

    def unknown_answer(key, error)
      answer(key, state: :final, tone: :unknown, headline: "This check did not complete.",
             detail: error.to_s, cues: [])
    end

    def repo_retrieval_answer
      answer(:retrieval, state: :final, tone: :unknown,
             headline: "Not asked: you gave us a repo, not a page.",
             detail: "Retrieval is a property of a URL an agent can fetch. Paste a documentation " \
                     "link to have it checked.", cues: [])
    end

    def repo_only? = result("target") && result("target")[:kind].to_s == "repo"

    def result(step)
      payload = @payloads[step.to_s]
      return nil unless payload.is_a?(Hash)

      payload[:result].is_a?(Hash) ? payload[:result] : nil
    end

    def check(step, name)
      Array(result(step)&.dig(:checks)).find { |c| c[:name] == name }
    end

    def pass?(step, name) = check(step, name)&.dig(:pass)

    def detail_of(step, name) = check(step, name)&.dig(:detail)

    def status_of(flag)
      case flag
      when true then :pass
      when false then :fail
      else :unknown
      end
    end

    def path_status(path)
      case path.first
      when :open then :pass
      when :blocked, :absent then :fail
      when :waiting then :waiting
      else :unknown
      end
    end

    def recall_status(mem)
      return :waiting if mem.nil?

      case mem[:verdict]
      when "strong" then :pass
      when "partial" then :unknown
      else :fail
      end
    end
  end
end
