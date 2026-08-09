# frozen_string_literal: true

module Analyzer
  # The evidence boxes on a result page: which measurements the deck shows, in the order it argues
  # them, and the words on each.
  #
  # This lived on the Analysis model as Analysis::STEPS. Nothing about it is domain: the keys are
  # already Run::STEPS, and everything else is copy for a screen ("the slow one: both sources
  # against every model"). A model holding sentences is a model that has to be edited to reword a
  # heading, and it put the domain layer in the business of knowing what a box looks like.
  #
  # Run::STEPS stays the authority on what actually EXECUTES, and deliberately differs: it includes
  # `references`, which is the scale on the recall chart rather than evidence about this target, so
  # listing it here would invite reading it as one.
  #
  # Titled as measurements rather than as questions, because the slides above them ask the
  # questions. Two boxes headed "Can agents retrieve it today?" and "Can an agent read this page
  # today?" on one screen read as the same thing asked twice.
  class Steps
    Step = Struct.new(:key, :title, :hint, keyword_init: true)

    ALL = [
      [ "retrieval",    "What a crawler sees on your docs", "robots, crawlability, sitemap, markdown twins" ],
      [ "repo_signals", "What an agent finds in your repo", "README, description, licence, releases, activity" ],
      [ "code_channel", "The code funnel",                  "public repo, Software Heritage, licence" ],
      [ "web_channel",  "The web funnel",                   "Common Crawl, then the quality filter" ],
      [ "memorization", "The memorization probe",           "the slow one: both sources against every model" ]
    ].map { |key, title, hint| Step.new(key: key, title: title, hint: hint) }.freeze

    # Titles keyed by symbol, including `target`, which is not a measurement and has no box of its
    # own but does get a heading when a broadcast replaces it.
    #
    # Built once here rather than recomputed in the partial on every render. The partial had this as
    # an inline `to_h { ... }.merge(...)`, which is the same lookup rebuilt for each of the five
    # boxes on the page, and a second place to edit when a title changes.
    TITLES = ALL.to_h { |step| [ step.key.to_sym, step.title ] }.merge(target: "Target").freeze

    def self.title_for(key) = TITLES[key.to_sym] || key.to_s
  end
end
