# frozen_string_literal: true

require "test_helper"

# The three slides that carry a picture rather than a paragraph: the agent-experience boxes, the two
# funnels, and the recall grid. Each one can turn a missing measurement into a confident negative if
# it is careless, which is the failure mode these tests exist to catch.
class SlidesTest < ActiveSupport::TestCase
  def step(result) = { result: result }

  def target(docs: "https://acme.com/docs/page", repo: "acme/docs")
    { "target" => step(docs_url: docs, repo: repo) }
  end

  def retrieval(allowed: true, reachable: true, md: true, sitemap: true, llms: false,
                declined: [], granted: [])
    step(content_signal: { declined: declined, granted: granted },
         checks: [
           { name: "Crawlers allowed", pass: allowed, detail: "robots.txt permits AI crawlers" },
           { name: "Reachable by a crawler", pass: reachable, detail: "fetches cleanly as CCBot" },
           { name: "Sitemap", pass: sitemap, detail: "sitemap.xml found" },
           { name: "Markdown content negotiation", pass: false, detail: "returns HTML only" },
           { name: "Markdown twin (.md)", pass: md, detail: ".md serves markdown" },
           { name: "llms.txt", pass: llms, informational: true, detail: llms ? "present" : "absent" }
         ])
  end

  def signals(readme: 400)
    step(present: true, repo: "acme/docs", checks: [
           { name: "Public on GitHub", pass: true, detail: "acme/docs, 12 stars" },
           { name: "README explains the project", pass: readme >= 80, detail: "#{readme} words of prose" },
           { name: "Description and topics set", pass: true, detail: "description and 3 topics" },
           { name: "Tagged releases", pass: true, detail: "5 published releases" },
           { name: "Active in the last 12 months", pass: true, detail: "last push 2 months ago" }
         ])
  end

  def code(license_class: :permissive, kept: true, swh: true, present: true)
    step(present: present, repo: "acme/docs", swh_archived: swh, kept_by_stack: kept,
         license_class: license_class, stars: 12,
         checks: [ { name: "License permits inclusion", pass: kept == true, detail: "MIT (LICENSE) - kept" } ])
  end

  # --- agent experience -------------------------------------------------------------------------

  test "an unticked box always carries the fix, and a ticked one never does" do
    d = Analyzer::Discoverability.new(target.merge("retrieval" => retrieval(sitemap: false),
                                                   "repo_signals" => signals, "code_channel" => code))
    docs = d.columns.first

    sitemap = docs.items.find { |i| i.label == "Sitemap a crawler can find" }
    assert_equal :fail, sitemap.status
    assert sitemap.action.present?, "an unticked box with no fix is a dead end"

    assert_nil docs.items.find { |i| i.label == "AI crawlers allowed" }.action
  end

  # An empty box is a fact about the FORM. Reporting it as a failure would mark someone down for
  # something we never looked at.
  test "an empty field reads as unmeasured rather than as a failure" do
    d = Analyzer::Discoverability.new(target(repo: nil).merge("retrieval" => retrieval))
    repo_column = d.columns.last

    assert_equal :missing, repo_column.state
    assert_empty repo_column.items
    assert_empty d.open_items.select { |i| i.label.include?("README") }
  end

  # llms.txt is used by no major AI system, so scoring it would hand out an action item that buys
  # the reader nothing.
  test "llms.txt is informational and never generates a fix" do
    d = Analyzer::Discoverability.new(target.merge("retrieval" => retrieval))
    item = d.columns.first.items.find { |i| i.label == "llms.txt" }

    assert_equal :info, item.status
    assert_nil item.action
    refute_includes d.open_items, item
  end

  # --- fetching and using are two permissions -----------------------------------------------------

  # The case that used to come back as a plain green tick. robots.txt lets the crawler in and
  # Content-Signal declines training, and reporting only the first tells someone their setting is
  # not there.
  test "a declined content signal warns instead of ticking" do
    d = Analyzer::Discoverability.new(
      target.merge("retrieval" => retrieval(declined: [ "ai-train" ], granted: [ "search" ]))
    )
    crawlers = d.columns.first.items.find { |i| i.label == "AI crawlers allowed" }

    assert_equal :warn, crawlers.status
    assert_match(/2019\/790/, crawlers.action, "the reservation is the whole meaning of the line")
    assert_equal "content-signal", crawlers.anchor
  end

  # A setting is not a defect, so it must not appear in the count of things to repair, and it must
  # not be handed the "allow crawlers by name" fix, which is advice for the opposite situation.
  test "a declined content signal is neither a fix nor a misconfiguration" do
    d = Analyzer::Discoverability.new(target.merge("retrieval" => retrieval(declined: [ "ai-train" ])))

    assert_empty d.open_items.select { |i| i.label == "AI crawlers allowed" }
    refute_match(/allow those by name/,
                 d.columns.first.items.find { |i| i.label == "AI crawlers allowed" }.action)
  end

  # A blocked crawler is still a real failure, whatever the signals say.
  test "a Disallow outranks a granted content signal" do
    d = Analyzer::Discoverability.new(
      target.merge("retrieval" => retrieval(allowed: false, granted: [ "ai-train" ]))
    )
    crawlers = d.columns.first.items.find { |i| i.label == "AI crawlers allowed" }

    assert_equal :fail, crawlers.status
    assert_match(/allow those by name/, crawlers.action)
  end

  test "no content signal leaves the box exactly as it was" do
    d = Analyzer::Discoverability.new(target.merge("retrieval" => retrieval))
    crawlers = d.columns.first.items.find { |i| i.label == "AI crawlers allowed" }

    assert_equal :pass, crawlers.status
    assert_nil crawlers.action
  end

  # --- the packaged fix -------------------------------------------------------------------------

  # The block offers a skill, so it may only claim the boxes that skill ships. A WAF rule is beyond
  # any skill and the sitemap is outside this one's stated scope, so listing either would send
  # someone to a tool that cannot help.
  test "the skill block claims only the boxes it can fix" do
    d = Analyzer::Discoverability.new(
      target.merge("retrieval" => retrieval(allowed: false, reachable: false, md: false, sitemap: false))
    )
    skill = d.skill

    assert_includes skill.covers, "AI crawlers allowed"
    assert_includes skill.covers, "Source text an agent can read"
    refute_includes skill.covers, "Fetches as a crawler"
    refute_includes skill.covers, "Sitemap a crawler can find"
  end

  # The skill ships an llms.txt and this page scores that box as information. Counting it as a fix
  # would put a number in this block that disagrees with the tally under the same column.
  test "an absent llms.txt never enters the fix count" do
    d = Analyzer::Discoverability.new(target.merge("retrieval" => retrieval(md: false, llms: false)))

    assert_equal [ "Source text an agent can read" ], d.skill.covers
    assert_equal d.skill.covers.size, d.columns.first.items.count { |i| i.status == :fail },
                 "the block's count and the column's own fix count must agree"
  end

  # A tool advertised under a column of ticks is an ad. The fixture has no llms.txt, which is the
  # sharp end of this: an absent llms.txt is not a fix, so on its own it never summons the block.
  test "no skill block when there is nothing here for it to fix" do
    d = Analyzer::Discoverability.new(target.merge("retrieval" => retrieval(llms: false)))

    assert_nil d.skill
  end

  # It belongs to the docs column. The repo column is a different set of problems.
  test "the repo column carries no skill block" do
    d = Analyzer::Discoverability.new(
      target.merge("retrieval" => retrieval, "repo_signals" => signals, "code_channel" => code)
    )

    assert_nil d.columns.last.skill
  end

  # --- the licence, read twice ------------------------------------------------------------------

  # The case people get backwards: The Stack v2/v3 keep unlicensed code, and nobody may use it. A
  # page that showed only the corpus answer would tell someone their licence is fine.
  test "an unlicensed repo is kept by the corpus and refused by an agent" do
    assert_equal true, Analyzer::CodeChannel::KEPT_BY_STACK[:no_license]
    assert_equal :fail, Analyzer::License.for(:no_license).status

    d = Analyzer::Discoverability.new(
      target.merge("repo_signals" => signals, "code_channel" => code(license_class: :no_license))
    )
    licence = d.columns.last.items.find { |i| i.label == "Licence an agent can act on" }

    assert_equal :fail, licence.status
    assert_match(/no permission/i, licence.detail)
    assert_match(/blocks adoption/i, licence.action)
  end

  test "a permissive licence needs no caveat and a source-available one does" do
    assert_equal :pass, Analyzer::License.for(:permissive).status
    assert_equal :warn, Analyzer::License.for(:source_available).status
    assert_match(/NOASSERTION/, Analyzer::License.for(:source_available).detail)
    assert_equal :warn, Analyzer::License.for(:copyleft).status
  end

  test "the licence box waits rather than guessing while the code check is still running" do
    d = Analyzer::Discoverability.new(target.merge("repo_signals" => signals))
    licence = d.columns.last.items.find { |i| i.label == "Licence an agent can act on" }

    assert_equal :waiting, licence.status
  end

  # --- the funnels ------------------------------------------------------------------------------

  test "a channel with no input is drawn as missing, never as blocked" do
    f = Analyzer::Funnel.new(target(repo: nil))
    code_channel = f.channels.last

    assert_equal %i[missing missing], code_channel.tiers.map(&:status)
    assert_nil code_channel.subject
  end

  # A GitHub rate limit is a fact about our server. Drawn as a closed gate it would report someone
  # else's public repo as disqualified.
  test "a rate-limited check draws as unresolved, not as a closed gate" do
    limited = step(present: false, transient: true, reason: "GitHub rate limit reached for this server")
    f = Analyzer::Funnel.new(target.merge("code_channel" => limited))

    assert_equal :unknown, f.channels.last.tiers.first.status
  end

  test "the apex reports recall and stays waiting until the probe answers" do
    assert_equal :waiting, Analyzer::Funnel.new(target).apex.status

    fired = step(summary: { verdict: "strong", best_run: 30 })
    apex = Analyzer::Funnel.new(target.merge("memorization" => fired)).apex
    assert_equal :pass, apex.status
    assert_match(/30 consecutive words/, apex.detail)
  end

  # --- the recall grid --------------------------------------------------------------------------

  def probes(docs_run:, repo_run:)
    [ { provider: "Claude Opus", source: "docs", run: docs_run, verdict: "none", offset: 200, matched: "" },
     { provider: "Claude Opus", source: "repo", run: repo_run, verdict: "strong", offset: 200, matched: "a b c" } ]
  end

  def memorization(docs_run: 2, repo_run: 30, controls: true)
    step(summary: Analyzer::Memorization.summarize(probes(docs_run:, repo_run:)),
         matrix: Analyzer::Memorization.matrix(probes(docs_run:, repo_run:)),
         controls: controls ? control_probes : [])
  end

  def control_probes
    [ { provider: "Claude Opus", kind: "control+", run: 31, verdict: "strong" },
     { provider: "Claude Opus", kind: "control-", run: 3, verdict: "none" } ]
  end

  test "the grid puts both halves of your input under each model" do
    grid = Analyzer::RecallGrid.new(target.merge("memorization" => memorization))
    row = grid.rows.first

    assert_equal "Claude Opus", row.model
    assert_equal 2, row.cells["docs"].run
    assert_equal 30, row.cells["repo"].run
  end

  # The grid is your text and nothing else. Reference pages and the control pair were five columns
  # of numbers that were not about the visitor, sitting between their result and the edge of the
  # table.
  test "the grid carries only your own columns" do
    grid = Analyzer::RecallGrid.new(target.merge("memorization" => memorization))

    assert_equal [ :yours ], grid.columns.map(&:kind).uniq
    assert_empty grid.columns.select { |c| c.label.match?(/MIT|Invented|Tailwind|Rails guides|Supabase/) },
                 "references and controls must not be columns"
  end

  # The controls STILL RUN; only their columns are gone. Without this verdict a zero could mean "not
  # memorized" or "the probe broke today" and there would be nothing to tell them apart.
  test "removing the control columns keeps the control verdict" do
    ok = Analyzer::RecallGrid.new(target.merge("memorization" => memorization))
    assert_equal true, ok.controls_ok?

    broken = [ { provider: "Claude Opus", kind: "control+", run: 1, verdict: "none" },
              { provider: "Claude Opus", kind: "control-", run: 3, verdict: "none" } ]
    p = probes(docs_run: 2, repo_run: 30)
    payload = step(summary: Analyzer::Memorization.summarize(p),
                   matrix: Analyzer::Memorization.matrix(p), controls: broken)
    assert_equal false, Analyzer::RecallGrid.new(target.merge("memorization" => payload)).controls_ok?
  end

  # --- falling back to another page --------------------------------------------------------------
  #
  # A docs URL with no testable prose is probed against another page on the same site. That must
  # never be silent: a grid headed with the URL you typed but built from a different page is a wrong
  # answer dressed as a helpful one.

  def probed_from(label, docs_url: "https://acme.dev/docs")
    probes = [ { provider: "Claude Opus", source: "docs", run: 4, verdict: "none", offset: 1,
                source_label: label } ]
    payloads = { "target" => step(docs_url: docs_url, repo: nil, passage: nil),
                "memorization" => step(summary: Analyzer::Memorization.summarize(probes),
                                       matrix: Analyzer::Memorization.matrix(probes),
                                       controls: control_probes) }
    Analyzer::RecallGrid.new(payloads)
  end

  test "probing the page that was asked for is not a substitution" do
    assert_nil probed_from("https://acme.dev/docs").substituted_page
  end

  test "a different page on the same site is reported as a substitution" do
    grid = probed_from("https://acme.dev/docs/guides/auth")

    assert_equal "https://acme.dev/docs/guides/auth", grid.substituted_page
    docs = grid.columns.find { |c| c.key == "docs" }
    assert_equal "https://acme.dev/docs/guides/auth", docs.href,
                 "the column must link to what was actually probed"
  end

  # The markdown twin of the SAME page is not a different page, and flagging it as one would put a
  # "we tested something else" warning on a run that tested exactly what was asked.
  test "a markdown twin of the same page is not a substitution" do
    assert_nil probed_from("https://acme.dev/docs (markdown twin)").substituted_page
  end

  # "Claude Opus" will point at different weights in six months, so a row that cannot name the
  # snapshot it came from is not reproducible.
  test "every row names the exact model it probed" do
    row = Analyzer::RecallGrid.new(target.merge("memorization" => memorization)).rows.first

    assert_equal "claude-opus-4-8", row.model_id
    assert_equal Analyzer::Memorization::MODELS["claude"][:model], row.model_id,
                 "the id shown must be the string actually sent to the provider"
  end

  # A source that was never probed is not a zero. Drawing it as one turns "not asked" into "not
  # memorized", which is the overclaim this whole tool exists to avoid.
  test "a source that was never probed reads as not asked, not as zero" do
    docs_only = [ { provider: "Claude Opus", source: "docs", run: 4, verdict: "none", offset: 1 } ]
    payload = step(summary: Analyzer::Memorization.summarize(docs_only),
                   matrix: Analyzer::Memorization.matrix(docs_only), controls: control_probes)

    cell = Analyzer::RecallGrid.new(target.merge("memorization" => payload)).rows.first.cells["repo"]
    assert_equal :missing, cell.state
    assert_nil cell.run
  end

  test "one scale across the grid, never one per row" do
    grid = Analyzer::RecallGrid.new(target.merge("memorization" => memorization))
    assert_equal 30, grid.scale, "the widest bar anywhere on the grid sets the scale"

    big = Analyzer::RecallGrid.new(target.merge("memorization" => memorization(repo_run: 55)))
    assert_equal 55, big.scale
  end

  # A grid whose widest bar is 3 words would draw that 3 as a full bar and read as a hit.
  test "a grid of small numbers is drawn against a floor, not against its own maximum" do
    quiet = [ { provider: "Claude Opus", source: "docs", run: 3, verdict: "none", offset: 1 } ]
    payload = step(summary: Analyzer::Memorization.summarize(quiet),
                   matrix: Analyzer::Memorization.matrix(quiet), controls: [])

    grid = Analyzer::RecallGrid.new(target.merge("memorization" => payload))
    assert_equal Analyzer::RecallGrid::MIN_SCALE, grid.scale
  end

  # GPT reproducing 54 words and Claude managing 7 was announced as "Claude Opus and GPT-5.5
  # reproduce 54 consecutive words", which hands one model another model's result.
  test "the headline credits only the models that cleared the strong bar" do
    mixed = [ { provider: "Claude Opus", source: "docs", run: 7, verdict: "partial", offset: 1 },
             { provider: "GPT-5.5", source: "docs", run: 54, verdict: "strong", offset: 1 } ]
    summary = Analyzer::Memorization.summarize(mixed)

    assert_equal [ "Claude Opus", "GPT-5.5" ], summary[:models_fired]
    assert_equal [ "GPT-5.5" ], summary[:models_strong]

    headline = Analyzer::Verdict.new(target.merge("memorization" => step(summary: summary)))
                                .training_answer.headline
    assert_match(/GPT-5\.5 reproduces 54 consecutive words/, headline)
    refute_match(/Claude Opus/, headline)
  end

  test "the controls are checked rather than assumed" do
    assert_equal true, Analyzer::RecallGrid.new(target.merge("memorization" => memorization)).controls_ok?

    broken = step(summary: {}, matrix: [],
                  controls: [ { provider: "Claude Opus", kind: "control+", run: 1, verdict: "none" } ])
    assert_equal false, Analyzer::RecallGrid.new(target.merge("memorization" => broken)).controls_ok?
  end

  # --- a pasted paragraph -----------------------------------------------------------------------

  def pasted(words: 80)
    { "target" => step(docs_url: nil, repo: nil, passage: (1..words).map { |i| "w#{i}" }.join(" ")) }
  end

  test "the paragraph leads the grid and carries its own length" do
    probes = [ { provider: "Claude Opus", source: "passage", run: 31, verdict: "strong", offset: 0 } ]
    payload = step(summary: Analyzer::Memorization.summarize(probes),
                   matrix: Analyzer::Memorization.matrix(probes), controls: [])

    grid = Analyzer::RecallGrid.new(pasted.merge("memorization" => payload))
    first = grid.columns.first

    assert_equal "Your paragraph", first.label
    assert_equal "80 words", first.sublabel
    assert_equal 31, grid.rows.first.cells["passage"].run
  end

  # A paragraph has no channels. Saying "one channel could not be checked" about a run that never
  # had one reads as a fault in the tool rather than as a finding.
  test "a paragraph-only run says nothing about channels" do
    quiet = step(summary: { verdict: "none", best_run: 2, spans_tested: 1, probes: 3 })
    answer = Analyzer::Verdict.new(pasted.merge("memorization" => quiet)).training_answer

    assert_equal "No model reproduced this paragraph.", answer.headline
    refute_match(/channel/i, answer.headline)
    assert_match(/weak evidence/i, answer.caveat)
  end

  test "a paragraph-only run is given no advice about sites or repos" do
    assert_empty Analyzer::Actions.new(pasted).items
    assert_empty Analyzer::Actions.new(pasted).settled
  end

  test "the retrieval slide refuses to answer for a paragraph" do
    answer = Analyzer::Verdict.new(pasted).retrieval_answer
    assert_match(/pasted a paragraph/i, answer.headline)
  end

  # Reference columns are gone: they restated one point three times between the visitor's own result
  # and the controls. What remains has to be only the visitor's own text, or the grid is comparing
  # things the caption does not explain.
  test "the grid draws your own text and nothing else" do
    grid = Analyzer::RecallGrid.new(target.merge("memorization" => memorization))

    assert_equal [ :yours ], grid.columns.map(&:kind).uniq
    assert_equal [ "Your docs", "Your repo" ], grid.columns.map(&:label)
  end
end
