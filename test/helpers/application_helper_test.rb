# frozen_string_literal: true

require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "links the first mention of a known term to its definition" do
    html = with_learn_links("The Stack v2/v3 are built from the Software Heritage archive.")

    assert_includes html, %(<a href="/learn#the-stack" class="learn-term">The Stack v2/v3</a>)
    assert_includes html, %(<a href="/learn#swh" class="learn-term">Software Heritage</a>)
  end

  # "The Stack" is a prefix of "The Stack v2/v3". Matching the short form first would link three
  # words and leave "v2/v3" hanging outside the link.
  test "the longest matching term wins" do
    html = with_learn_links("kept by The Stack v2/v3 anyway")
    assert_includes html, ">The Stack v2/v3</a>"
    refute_includes html, ">The Stack</a>"
  end

  test "only the first mention of a term is linked" do
    html = with_learn_links("Common Crawl seeds corpora. Common Crawl never copies a site in full.")
    assert_equal 1, html.scan("learn#common-crawl").size
  end

  # Check details carry URLs and licence text from third-party servers, so the escape has to happen
  # before any markup is inserted.
  test "text is escaped before links are added" do
    html = with_learn_links(%(<script>alert(1)</script> and Common Crawl))

    refute_includes html, "<script>"
    assert_includes html, "&lt;script&gt;"
    assert_includes html, "learn#common-crawl"
  end

  test "blank input renders nothing" do
    assert_equal "", with_learn_links(nil)
    assert_equal "", with_learn_links("")
  end
end
