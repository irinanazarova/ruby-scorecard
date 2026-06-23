# frozen_string_literal: true

# Memorization probe: does a model reproduce a page's text verbatim from a short prefix?
# This is a DIRECTIONAL signal of training-data memorization, NOT proof of training-set membership.
# A strong positive (long verbatim run) means the text was almost certainly seen in training; a
# negative proves nothing (models memorize only a fraction). Confounders are controlled by design:
# tools are OFF (no live retrieval), passages are pre-cutoff and distinctive, and we run known-memorized
# positive controls + a fabricated negative control so a null result is interpretable.
#
#   ANTHROPIC_API_KEY=sk-... ruby scripts/memorization_probe.rb
#   PROBE_MODEL=claude-opus-4-8 ANTHROPIC_API_KEY=sk-... ruby scripts/memorization_probe.rb

require "anthropic"
require "json"
require "open-uri"
require_relative "quality_core"

MODEL = ENV.fetch("PROBE_MODEL", "claude-opus-4-8")
unless ENV["ANTHROPIC_API_KEY"]
  abort "Set your key:  ANTHROPIC_API_KEY=sk-ant-... ruby scripts/memorization_probe.rb\n" \
        "(the key is used only for this run; the script makes ~7 small calls to #{MODEL})"
end
CLIENT = Anthropic::Client.new(access_token: ENV["ANTHROPIC_API_KEY"])

SEED_WORDS = 55   # prefix given to the model
TRUTH_WORDS = 60  # true continuation we compare against (capped; short controls use what they have)
MIN_TRUTH = 15    # need at least this many continuation words to score a passage

# --- known-memorized positive controls (ubiquitous text; the probe SHOULD light up) ---
CONTROLS = [
  { name: "MIT License (control+)", kind: "control",
    text: "Permission is hereby granted, free of charge, to any person obtaining a copy of this " \
          "software and associated documentation files (the \"Software\"), to deal in the Software " \
          "without restriction, including without limitation the rights to use, copy, modify, merge, " \
          "publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons " \
          "to whom the Software is furnished to do so, subject to the following conditions: The above " \
          "copyright notice and this permission notice shall be included in all copies or substantial " \
          "portions of the Software." },
  { name: "Dickens opening (control+)", kind: "control",
    text: "It was the best of times, it was the worst of times, it was the age of wisdom, it was the " \
          "age of foolishness, it was the epoch of belief, it was the epoch of incredulity, it was the " \
          "season of Light, it was the season of Darkness, it was the spring of hope, it was the winter " \
          "of despair, we had everything before us, we had nothing before us." },
  # fabricated, never published -> the probe SHOULD NOT match (sanity-checks the metric against false positives)
  { name: "Fabricated text (control-)", kind: "null",
    text: "The teal armadillo audited seventeen quivering lighthouses before the marzipan committee " \
          "rescinded its quarterly velvet subsidy, whereupon the librarian transposed every ledger into " \
          "a dialect of polite thunder and the harbor master filed the receipts under migratory arithmetic. " \
          "By the third equinox the bicycle notaries had memorized the lullaby of the copper escalator, " \
          "yet none could explain why the persimmon auditors kept rotating the lighthouse on alternate " \
          "Tuesdays. The committee adjourned to a meadow of recursive umbrellas, where the velvet subsidy " \
          "was quietly reinstated under a new name that rhymed with neither thunder nor arithmetic, and the " \
          "librarian, satisfied, filed the entire affair under a heading that the harbor master would later " \
          "describe, without irony, as the politest catastrophe ever transcribed into migratory ledgers." }
].freeze

# --- real test pages (fetched live; we take a distinctive mid-article chunk, past the boilerplate lead) ---
TEST_URLS = [
  { name: "AnyCable docs / reliable_streams", url: "https://docs.anycable.io/anycable-go/reliable_streams" },
  { name: "EM: ruby-on-whales", url: "https://evilmartians.com/chronicles/ruby-on-whales-docker-for-ruby-rails-development" },
  { name: "EM: the-long-game", url: "https://evilmartians.com/chronicles/the-long-game-why-rails-survived-the-hype-cycle-and-what-it-means-for-your-startup" }
].freeze

def norm(text)
  text.downcase.gsub(/[^a-z0-9\s]/, " ").split
end

# Longest contiguous run of words shared by both sequences (the strongest memorization signal).
def longest_common_run(a, b)
  return 0 if a.empty? || b.empty?
  prev = Array.new(b.size + 1, 0)
  best = 0
  a.each do |wa|
    cur = Array.new(b.size + 1, 0)
    b.each_with_index do |wb, j|
      if wa == wb
        cur[j + 1] = prev[j] + 1
        best = cur[j + 1] if cur[j + 1] > best
      end
    end
    prev = cur
  end
  best
end

def ngram_overlap(truth, out, n = 5)
  tg = truth.each_cons(n).to_a
  return 0.0 if tg.empty?
  og = out.each_cons(n).to_a.to_set
  (tg.count { |g| og.include?(g) }.to_f / tg.size).round(3)
end

def complete(prefix)
  resp = CLIENT.messages(parameters: {
    model: MODEL,
    max_tokens: 220,
    system: "You are completing a passage from its original published source. Output ONLY the verbatim " \
            "continuation of the text, with no preamble, quotation marks, or commentary. Do not use any " \
            "tools or search. If you recognize the source, reproduce the next sentences exactly as written.",
    messages: [{ role: "user", content: "Continue this text exactly as it appears in the original:\n\n#{prefix}" }]
  })
  blocks = resp["content"] || []
  text = blocks.map { |b| b["text"] }.compact.join(" ").strip
  [text, resp["stop_reason"]]
rescue StandardError => e
  ["[error: #{e.class}: #{e.message[0, 120]}]", "error"]
end

def passages
  list = CONTROLS.dup
  TEST_URLS.each do |t|
    begin
      html = URI.parse(t[:url]).open("User-Agent" => "ruby-scorecard/1.0", read_timeout: 20).read
      text, = QualityCore.extract_text(html)
      words = text.split
      need = SEED_WORDS + TRUTH_WORDS
      next warn("  skip #{t[:name]}: only #{words.size} words") if words.size < need + 20
      # distinctive mid-article span, past the lead/boilerplate; start earlier on short pages
      start = [380, words.size - need - 10].min
      list << { name: t[:name], kind: "test", text: words[start, need + 40].join(" ") }
    rescue StandardError => e
      warn "  skip #{t[:name]}: #{e.message[0, 80]}"
    end
  end
  list
end

puts "MEMORIZATION PROBE  (model: #{MODEL}, tools OFF)"
puts "Directional signal of memorization, NOT proof of training-set membership. See header in this file.\n\n"
printf("%-34s %-9s %-12s %-9s %s\n", "passage", "kind", "longest run", "5gram", "verdict")
puts "-" * 86

results = []
passages.each do |p|
  words = p[:text].split
  if words.size < SEED_WORDS + MIN_TRUTH
    warn "  skip #{p[:name]}: only #{words.size} words (need #{SEED_WORDS + MIN_TRUTH})"
    next
  end
  prefix = words.first(SEED_WORDS).join(" ")
  truth  = words.drop(SEED_WORDS).first(TRUTH_WORDS).join(" ") # short controls use what they have
  out, stop = complete(prefix)
  run = longest_common_run(norm(truth), norm(out))
  ov  = ngram_overlap(norm(truth), norm(out))
  verdict = if out.start_with?("[error")
              "API ERROR"
            elsif run >= 15 then "STRONG memorization"
            elsif run >= 6 then "partial echo"
            else "no verbatim recall"
            end
  results << p.merge(run: run, overlap: ov, verdict: verdict, out: out, truth: truth, stop: stop)
  printf("%-34s %-9s %-12s %-9s %s\n", p[:name][0, 33], p[:kind], "#{run} words", ov, verdict)
  sleep 0.5
end

File.write(File.join(__dir__, "..", "data", "memorization_probe.json"), JSON.pretty_generate(
  results.map { |r| r.slice(:name, :kind, :run, :overlap, :verdict, :stop, :truth, :out) }
))

puts "\nHow to read this:"
puts "  - Controls(+) should show STRONG memorization; the control(-) should show none. If not, the probe"
puts "    or the metric is off and the test-page results are not interpretable."
puts "  - A STRONG result on a test page = that text was almost certainly in training (can't reproduce the"
puts "    unseen). It does NOT prove your specific URL was crawled (the text may be duplicated elsewhere)."
puts "  - 'no verbatim recall' proves nothing: models memorize only a small fraction of what they train on."
puts "  - This is the open FineWeb-Edu-style proxy of the training question, not Anthropic's ground truth."
puts "\nFull outputs -> data/memorization_probe.json"
