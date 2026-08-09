# frozen_string_literal: true

require "test_helper"

class AnalyzeJobTest < ActiveSupport::TestCase
  # The job rebuilds the target from the stored columns, which makes it the one place a new form
  # field can be silently dropped: every check downstream reads the target, not the record.
  #
  # Adding the pasted paragraph and forgetting this line produced a finished run that reported "No
  # testable prose found" about text the visitor had typed out in front of us, and nothing else in
  # the suite noticed.
  test "hands every field the form collected back to the run" do
    analysis = Analysis.create!(
      session_token: "t", input: "everything", status: "pending",
      docs_url: "https://acme.com/docs/page", repo: "acme/docs", passage: "a pasted paragraph"
    )

    target = AnalyzeJob.new.target_for(analysis)

    assert_equal "https://acme.com/docs/page", target.url
    assert_equal "acme/docs", target.repo
    assert_equal "a pasted paragraph", target.passage
  end

  test "a paragraph-only analysis produces a passage to probe" do
    text = (1..80).map { |i| "word#{i}" }.join(" ")
    analysis = Analysis.create!(session_token: "t", input: "para", status: "pending", passage: text)

    passages = Analyzer::Run.new(AnalyzeJob.new.target_for(analysis)).send(:build_passages)

    assert_equal 1, passages.size
    assert passages.first.ok, passages.first.error
    assert_equal :passage, passages.first.source
  end
end
