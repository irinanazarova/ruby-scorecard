# frozen_string_literal: true

# A third thing you can check: a paragraph, pasted directly.
#
# The two URL fields answer "is my documentation in the corpus". This answers a narrower and often
# more interesting question: is THIS EXACT TEXT already inside the models. It is the natural probe
# for boilerplate that gets copied across many repos, which is the case the study found most likely
# to be memorized.
#
# Stored as text rather than a digest because the results page shows what was tested. A probe you
# cannot see the input to is not evidence of anything.
class AddPassageToAnalyses < ActiveRecord::Migration[8.1]
  def change
    add_column :analyses, :passage, :text
  end
end
