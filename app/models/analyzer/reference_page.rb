# frozen_string_literal: true

module Analyzer
  # The scale on the recall chart: pages that ARE demonstrably in the training data, measured under
  # the identical probe, so a null result on your own page has something to be read against.
  #
  # All three are verified hits from our own 168-repo study, and they were chosen to disagree with
  # each other on everything except the outcome. One has no LICENSE file and 140 stars; one is MIT
  # with 59k; one is Apache-2.0 with 108k. Together they are the study's finding in three bars:
  # popularity and licence do not predict recall.
  #
  # The exact PASSAGE matters as much as the repo, which is why each one names a pinned span in
  # config/reference_passages.json rather than a file to re-sample. Recall is sparse: re-picking
  # spans from the live Rails i18n guide produced a 4-word run and "fired for nobody", which would
  # teach a visitor the opposite of the truth. Picking a famous product and hoping is the same
  # mistake one level up: the Supabase auth landing guide does not fire, and redirect-urls does.
  class ReferencePage
    ALL = [
      { label: "Tailwind CSS docs", repo: "tailwindlabs/tailwindcss.com",
        url: "https://tailwindcss.com/docs/upgrade-guide", passage: "tailwind-upgrade" },

      { label: "Rails guides", repo: "rails/rails",
        url: "https://guides.rubyonrails.org/i18n.html", passage: "rails-i18n" },

      { label: "Supabase docs", repo: "supabase/supabase",
        url: "https://supabase.com/docs/guides/auth/redirect-urls", passage: "supabase-redirect-urls" }
    ].freeze

    def self.all = ALL
  end
end
