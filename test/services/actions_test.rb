# frozen_string_literal: true

require "test_helper"

# Advice is the part of this page a visitor acts on, so the rules that keep it honest are tested:
# never invent work from a check that failed to run, never rank a sitemap above a missing repo, and
# never assume a deliberate robots.txt block was a mistake.
class ActionsTest < ActiveSupport::TestCase
  def actions(payloads) = Analyzer::Actions.new(payloads)

  def step(result) = { result: result }

  def retrieval(allowed: true, reachable: true, md: true, negotiation: false, sitemap: true)
    step(checks: [
           { name: "Crawlers allowed", pass: allowed,
             detail: allowed ? "robots.txt permits AI crawlers" : "robots.txt blocks CCBot, ClaudeBot" },
           { name: "Reachable by a crawler", pass: reachable, detail: "" },
           { name: "Sitemap", pass: sitemap, detail: "" },
           { name: "Markdown content negotiation", pass: negotiation, detail: "" },
           { name: "Markdown twin (.md)", pass: md, detail: "" }
         ])
  end

  def web(crawled: true, quality: true, score: 3.1)
    step(checks: [
           { name: "In Common Crawl", pass: crawled, detail: "" },
           { name: "Passes the quality filter", pass: quality, score: score, detail: "" }
         ])
  end

  def code(present: true, swh: true, kept: true, repo: "acme/docs", label: nil)
    step(present: present, repo: repo, swh_archived: swh, kept_by_stack: kept, license_label: label)
  end

  def keys(payloads) = actions(payloads).items.map(&:key)

  test "a missing repo is the top item, above any web-channel work" do
    items = actions({ "retrieval" => retrieval(sitemap: false),
                      "code_channel" => code(present: false),
                      "web_channel" => web(crawled: false, quality: false, score: 1.6) }).items

    assert_equal :repo, items.first.key
    assert_operator items.index { |i| i.key == :repo }, :<, items.index { |i| i.key == :sitemap }
  end

  # The rate limit is a fact about our server. Telling a team to publish a repo they already have
  # would discredit every other line on the page.
  test "a check that could not run produces no advice" do
    rate_limited = step(present: false, transient: true, reason: "GitHub rate limit reached")
    assert_equal [], keys({ "code_channel" => rate_limited })
  end

  test "an unarchived repo asks for archival rather than for a licence change" do
    items = actions({ "code_channel" => code(swh: false) }).items
    assert_equal [:archive], items.map(&:key)
    assert_match(/Software Heritage/, items.first.title)
    assert_equal "software-heritage", items.first.anchor
  end

  test "a dropped licence names the licence and offers the docs directory" do
    items = actions({ "code_channel" => code(kept: false, label: "FSL-1.1") }).items
    assert_equal [:license], items.map(&:key)
    assert_match(/FSL-1\.1/, items.first.why)
  end

  # An open code channel is the whole point of the study: web-channel work matters much less once
  # the text is already collected somewhere with no quality filter.
  test "web-channel work drops to low impact once the code channel is open" do
    open_code = { "code_channel" => code, "web_channel" => web(crawled: false, quality: false, score: 1.6) }
    closed_code = { "code_channel" => code(present: false),
                    "web_channel" => web(crawled: false, quality: false, score: 1.6) }

    assert_equal [:low, :low], actions(open_code).items.select { |i| %i[crawl quality].include?(i.key) }.map(&:impact)
    assert_equal [:medium, :medium], actions(closed_code).items.select { |i| %i[crawl quality].include?(i.key) }.map(&:impact)
  end

  test "a robots block is treated as a decision, not as a mistake" do
    item = actions({ "retrieval" => retrieval(allowed: false) }).items.find { |i| i.key == :robots }

    assert_match(/legitimate choice/, item.why)
    assert_match(/robots\.txt blocks CCBot, ClaudeBot/, item.why)
  end

  test "everything open produces no items and a full settled list" do
    payloads = { "retrieval" => retrieval, "code_channel" => code, "web_channel" => web }
    result = actions(payloads)

    assert_equal [], result.items.map(&:key)
    assert_includes result.settled, "Common Crawl has this URL."
    assert_includes result.settled, "The docs source is in a public repo, archived and licensed for inclusion."
  end

  test "a memorized page is told to keep the snippet current rather than to chase collection" do
    payloads = { "code_channel" => code, "web_channel" => web,
                 "memorization" => step(summary: { verdict: "strong", best_run: 34 }) }
    items = actions(payloads).items

    assert_equal [:canonical], items.map(&:key)
    assert_equal :low, items.first.impact
  end

  test "an empty run advises nothing" do
    assert_equal [], keys({})
    assert_equal [], actions({}).settled
  end

  test "every item points at an anchor that exists on /learn" do
    payloads = { "retrieval" => retrieval(allowed: false, reachable: false, md: false, sitemap: false),
                 "code_channel" => code(present: false),
                 "web_channel" => web(crawled: false, quality: false, score: 1.2) }
    page = Rails.root.join("app/views/pages/learn.html.erb").read

    actions(payloads).items.each do |item|
      assert_match(/id="#{item.anchor}"/, page, "/learn has no ##{item.anchor} for #{item.key}")
    end
  end
end
