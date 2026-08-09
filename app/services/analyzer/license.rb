# frozen_string_literal: true

module Analyzer
  # What a licence means for an AGENT, which is a different question from what it means for a corpus.
  #
  # CodeChannel already classifies the licence text and answers the corpus question: The Stack v2
  # and v3 drop `non_permissive` files by name and keep everything else, including repos with no
  # LICENSE file at all. That is the training half.
  #
  # This is the other half. An agent that finds your repo and is about to recommend it, or paste a
  # snippet of it into someone's codebase, reads the licence for permission. Those two readings
  # routinely point in OPPOSITE directions, and the sharpest case is a repo with no licence:
  #
  #   no LICENSE file  ->  corpora keep it       (The Stack v2/v3 do not require one)
  #                    ->  nobody may use it     (default copyright, no permission granted)
  #
  # So a project can be in the training data and still be the thing a careful agent refuses to
  # recommend. Neither answer is worth showing without the other.
  #
  # Wording rule: describe what tools and policies DO, never what the reader should do legally.
  # This is not legal advice and the page says so.
  module License
    # status is the tick shown on the agent-experience slide:
    #   :pass    an agent can use and suggest this without a caveat
    #   :warn    usable, with an obligation or a restriction an agent has to carry
    #   :fail    no permission granted, so a careful agent will not paste it anywhere
    #   :unknown we could not classify the text
    Implication = Struct.new(:status, :headline, :detail, keyword_init: true)

    ANCHOR = "license-implications"

    MAP = {
      permissive: Implication.new(
        status: :pass,
        headline: "An agent can suggest this and paste from it",
        detail: "MIT, Apache-2.0, BSD and ISC grant use, modification and redistribution, including " \
                "commercially. An agent recommending you has nothing to warn its user about."
      ),

      no_license: Implication.new(
        status: :fail,
        headline: "No permission is granted to anyone",
        detail: "With no LICENSE file, default copyright applies: nobody may copy, modify or " \
                "redistribute the code, and publishing on GitHub grants only viewing and forking " \
                "there. An agent that respects licences will not paste this into a user's project. " \
                "The Stack v2/v3 keep unlicensed repos anyway, so this blocks adoption without " \
                "keeping you out of the training data."
      ),

      copyleft: Implication.new(
        status: :warn,
        headline: "Usable, with an obligation that spreads",
        detail: "GPL, LGPL, AGPL and MPL attach conditions to whatever includes the code. Plenty of " \
                "company policies block AGPL outright, so an agent following those policies will " \
                "flag or skip you. Corpora drop these files as non-permissive."
      ),

      source_available: Implication.new(
        status: :warn,
        headline: "Visible source, restricted use, and invisible to tooling",
        detail: "BUSL, SSPL, Elastic, FSL, Commons Clause and PolyForm publish the source and limit " \
                "how it may be used, usually against competing services. GitHub reports every one " \
                "of them as NOASSERTION, so any tool reading spdx_id cannot tell your licence from " \
                "no licence at all."
      ),

      content: Implication.new(
        status: :warn,
        headline: "Fine for prose, share-alike carries",
        detail: "CC-BY and CC-BY-SA suit documentation. Share-alike terms follow anything that " \
                "reuses the text, which is why corpora treat these case by case rather than by name."
      ),

      unknown: Implication.new(
        status: :unknown,
        headline: "We could not classify this licence",
        detail: "A LICENSE file is present and it does not match any pattern we recognise. An agent " \
                "reading it will reach its own conclusion, and so will a legal review."
      )
    }.freeze

    NOT_ADVICE = "This describes what tooling and company policies do with each licence. It is not " \
                 "legal advice."

    def self.for(license_class)
      MAP[license_class.to_s.presence&.to_sym] || MAP[:unknown]
    end
  end
end
