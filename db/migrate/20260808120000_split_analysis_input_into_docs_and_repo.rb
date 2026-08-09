# frozen_string_literal: true

# The form used to take one box and work out the rest, which meant the repo behind a docs URL was
# INFERRED: named-after-the-site, then the org's docs repo, then the most-starred repo in the org.
# The last of those is a guess, and a guess is the wrong thing to build a licence verdict on.
#
# Asking for both fields separately removes the guess. Either may be blank, and which one is blank
# is itself part of the answer.
#
# `input` stays, still NOT NULL, as the display label for a run. Existing rows keep working: the
# model falls back to parsing it when these two columns are empty.
class SplitAnalysisInputIntoDocsAndRepo < ActiveRecord::Migration[8.1]
  def change
    add_column :analyses, :docs_url, :string
    add_column :analyses, :repo, :string
  end
end
