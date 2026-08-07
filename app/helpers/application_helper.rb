# frozen_string_literal: true

module ApplicationHelper
  # Terms that a result mentions and a visitor has no reason to know. Each one links to the
  # paragraph on /learn that defines it, so "not archived by Software Heritage" stops being a
  # sentence you have to already understand to act on.
  #
  # Longest first: "The Stack v2/v3" has to match before "The Stack", or the tail of the phrase is
  # left dangling outside the link.
  LEARN_TERMS = [
    ["The Stack v2/v3", "the-stack"],
    ["The Stack v2 and v3", "the-stack"],
    ["The Stack", "the-stack"],
    ["Software Heritage", "swh"],
    ["Common Crawl", "common-crawl"],
    ["FineWeb-Edu", "fineweb-edu"],
    ["CCBot", "ccbot"]
  ].freeze

  # Links the first mention of each known term. The text is escaped BEFORE any markup is inserted,
  # so a check detail that contains a URL or an angle bracket cannot smuggle HTML into the page
  # through this helper.
  def with_learn_links(text)
    return "" if text.blank?

    html = ERB::Util.html_escape(text.to_s)

    LEARN_TERMS.each do |term, anchor|
      escaped = ERB::Util.html_escape(term)
      next unless html.include?(escaped)
      # Skip a term already sitting inside a link this method added on an earlier pass.
      next if html.match?(/<a [^>]*>[^<]*#{Regexp.escape(escaped)}/)

      html = html.sub(escaped, %(<a href="/learn##{anchor}" class="learn-term">#{escaped}</a>))
    end

    html.html_safe
  end
end
