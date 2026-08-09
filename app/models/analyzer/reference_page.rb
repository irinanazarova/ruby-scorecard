# frozen_string_literal: true

module Analyzer
  # The scale on the recall chart: a page that IS demonstrably in the training data, measured under
  # the identical probe, so a null result on your own page has something to be read against.
  #
  # ONE reference, not three. It was three, chosen to disagree with each other on everything except
  # the outcome, and on the grid that argument never landed: three extra columns of numbers between
  # the visitor's own result and the controls, all making the same point, and each one inviting the
  # question "why am I looking at Supabase". The controls already anchor every row (the MIT licence
  # text must fire, the invented passage must not), and the "why the models have this" panel now
  # carries the copies argument the extra references were standing in for.
  #
  # The exact PASSAGE matters as much as the repo, which is why it names a pinned span in
  # config/reference_passages.json rather than a file to re-sample. Recall is sparse: re-picking
  # spans from the live Rails i18n guide produced a 4-word run and "fired for nobody", which would
  # teach a visitor the opposite of the truth.
  #
  # Tailwind is the one kept because it is the study's finding on its own: no LICENSE file, 140
  # stars, and reproduced anyway.
  #
  # NOTE: RecallGrid drops a reference that IS the target's repo, to avoid two near-identical bars.
  # With a single reference that means the Tailwind example shows no reference column at all, which
  # is correct rather than broken: the controls still scale the grid.
  class ReferencePage
    ALL = [
      { label: "Tailwind CSS docs", repo: "tailwindlabs/tailwindcss.com",
        url: "https://tailwindcss.com/docs/upgrade-guide", passage: "tailwind-upgrade" }
    ].freeze

    def self.all = ALL
  end
end
