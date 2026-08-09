# frozen_string_literal: true

# Pure-Ruby quality scoring + feedback using the FineWeb-Edu classifier via ONNX.
# Reproduces the Python/torch scores exactly (verified parity). Shared by the CLI, the rule-mining
# experiments, and the /check service.
#
# Needs: onnxruntime + tokenizers gems, and vendor/fwedu/{model.onnx,tokenizer.json}
# (see scripts/fetch_model.rb). Extraction uses Nokogiri, falling back to a regex.

require "onnxruntime"
require "tokenizers"

module QualityCore
  ROOT = File.expand_path("..", __dir__)
  MODEL_PATH = ENV.fetch("FWEDU_ONNX", File.join(ROOT, "vendor", "fwedu", "model.onnx"))
  TOKENIZER_PATH = ENV.fetch("FWEDU_TOKENIZER", File.join(ROOT, "vendor", "fwedu", "tokenizer.json"))
  MAX_TOKENS = 512
  CHUNK_WORDS = 350
  MAX_CHUNKS = 8

  WARNING =
    "This is the open FineWeb-Edu classifier, the documented filter behind the FineWeb corpus, used here " \
    "as the best available open proxy. It is NOT the actual quality filter used by Claude, GPT, or Gemini, " \
    "those are undisclosed. Only the first ~512 tokens (~380 words) are scored, and extraction is " \
    "approximate. Treat scores as directional; differences within about 0.3 are noise."

  CHROME = %w[script style svg nav head header footer aside noscript form iframe].freeze
  # Rules below were mined from a GEPA-style rewrite experiment (scripts/gepa.rb, 12 EM pages): the model
  # rewrote each lead to raise the score (mean +0.85), and we kept the feature changes that drove the gains.
  BOILER = /\b(min read|subscribe|newsletter|cookies?|skip to content|are you an llm|all rights reserved|sign up|log in)\b/i
  # An opening that states what the thing is / what you'll learn (checked in the first ~2 sentences).
  OPENING_DEF = %r{\b(is|are) (a|an|the)\b|\b(this|the) (guide|post|article|tutorial|page|piece|chapter|document) (explains|covers|shows|describes|teaches|introduces|walks)\b|you (?:will|'ll) learn|by the end|in this (?:guide|post|article|tutorial|lesson)}i
  # Metadata/chrome that wastes the scored window (title+date+byline, nav, JS/LLM banners).
  LEADING_META = %r{\b(are you an llm|skip to content|enable javascript|min read|menu|return to top)\b|\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+\d{1,2},?\s*\d{4}\b}i

  class << self
    def tokenizer
      @tokenizer ||= begin
        t = Tokenizers.from_file(TOKENIZER_PATH)
        t.enable_truncation(MAX_TOKENS)
        t
      end
    end

    def model
      @model ||= OnnxRuntime::Model.new(MODEL_PATH)
    end

    def regex_text(html)
      t = html.gsub(%r{<(#{CHROME.join('|')})\b.*?</\1>}im, " ")
      t = t.gsub(/<[^>]+>/m, " ").gsub(/&[a-z#0-9]+;/i, " ")
      t.gsub(/\s+/, " ").strip
    end

    def extract_text(html)
      begin
        require "nokogiri"
        doc = Nokogiri::HTML(html)
        doc.css(CHROME.join(",")).remove
        main = doc.at_css("article, main, [role=main]") || doc.at_css("body") || doc
        text = main.text.gsub(/\s+/, " ").strip
        return [ text, "nokogiri" ] if text.length >= 50
      rescue LoadError, StandardError
        # fall through to regex
      end
      [ regex_text(html), "regex" ]
    end

    def score_window(text)
      enc = tokenizer.encode(text)
      out = model.predict({ "input_ids" => [ enc.ids ], "attention_mask" => [ enc.attention_mask ],
                            "token_type_ids" => [ enc.type_ids ] })
      logit = out["logits"].flatten.first.to_f
      logit.clamp(0.0, 5.0)
    end

    def score_text(text)
      lead = score_window(text)
      chunks = text.split.each_slice(CHUNK_WORDS).first(MAX_CHUNKS).map { |w| w.join(" ") }
      doc = chunks.size > 1 ? chunks.sum { |c| score_window(c) } / chunks.size : lead
      # FineWeb-Edu keeps documents with int_score >= 3 (the rounded label), i.e. raw score >= 2.5.
      { score: lead.round(2), doc_score: doc.round(2), int_score: lead.round, keep: lead.round >= 3 }
    end

    def features(text)
      words = text.split
      lead_words = words.first(380)
      lead = lead_words.join(" ")
      opening = words.first(45).join(" ")
      code_chars = lead.count("{};<>")
      stops = lead.count(".!?")
      {
        words: words.size,
        curly: text.include?("{"),
        code_density: (code_chars.to_f / [ lead.length, 1 ].max).round(4),
        opens_with_definition: !OPENING_DEF.match(opening).nil?,
        leading_meta: !LEADING_META.match(words.first(30).join(" ")).nil?,
        boiler_in_lead: !BOILER.match(lead).nil?,
        avg_sentence_words: (lead_words.size.to_f / [ stops, 1 ].max).round(1)
      }
    end

    # Feedback rules, ordered by the impact each lever had in the rewrite experiment (mean gain +0.85;
    # range +0.08 to +1.47; only content starting near ~2.2 cleared 3 on a lead rewrite alone).
    def feedback(score, feats)
      s = score[:score]
      # FineWeb-Edu keeps int_score >= 3 (rounded), i.e. raw score >= 2.5.
      verdict =
        if s >= 2.5 then "Likely kept. Rounds to int_score #{score[:int_score]} (FineWeb-Edu keeps int_score >= 3)."
        elsif s >= 1.6 then "Borderline. Just under the keep threshold (raw ~2.5 rounds to 3); a focused lead rewrite (avg +0.8) can clear it."
        else "Likely dropped. A lead rewrite adds ~0.8 on average, so starting here it usually will not reach the bar on its own. Lean on the code/repo channel too."
        end

      out = []
      out << "Too short. Pages under ~300 words score near zero. Expand into a fuller explanation." if feats[:words] < 300
      # #1 lever: sentence length. Choppy fragments/lists read as reference; long connected sentences teach.
      if feats[:avg_sentence_words].positive? && feats[:avg_sentence_words] < 15
        out << "Lengthen the sentences. The opening averages about #{feats[:avg_sentence_words]} words per " \
               "sentence; explanatory prose runs ~20+. Turning short, choppy fragments and bare lists into " \
               "connected sentences was the biggest single lever we measured (avg +0.85)."
      end
      # #2 lever: open with a definition / learning objective.
      unless feats[:opens_with_definition]
        out << "Open by saying what this teaches or what the thing is, and define the key term in the first " \
               "sentence (for example, \"X is a ...\" or \"This guide explains ...\"). Every strong rewrite started this way."
      end
      # #3 lever: don't spend the scored window on metadata/chrome.
      if feats[:leading_meta] || feats[:boiler_in_lead]
        out << "Strip metadata and banners from the opening (title, date, byline, navigation, " \
               "\"enable JavaScript\"/LLM hints). Only the first ~512 tokens are scored, so do not spend them on chrome."
      end
      # Secondary: code density.
      if feats[:code_density] > 0.02
        out << "High code-to-prose ratio in the opening. Surround code with explanation; the C4 filter dropped " \
               "any page containing a curly brace."
      end
      out << "Strong opening. Keep it teaching-first if you edit further; that is what carries the score." if s >= 2.5 && out.empty?
      { verdict: verdict, suggestions: out }
    end

    def check(content, is_html: true)
      text, method = is_html ? extract_text(content) : [ content, "raw" ]
      return { ok: false, error: "No extractable text (client-rendered or blocked)." } if text.length < 50

      sc = score_text(text)
      ft = features(text)
      fb = feedback(sc, ft)
      { ok: true, score: sc[:score], doc_score: sc[:doc_score], int_score: sc[:int_score], keep: sc[:keep],
        verdict: fb[:verdict], suggestions: fb[:suggestions], features: ft, extracted_words: text.split.size,
        extraction: method, warning: WARNING }
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  require "json"
  require "open-uri"
  url = ARGV[0] or abort "usage: ruby scripts/quality_core.rb <url|->"
  html = url == "-" ? $stdin.read : URI.parse(url).open("User-Agent" => "ruby-scorecard/1.0 quality-probe").read
  puts JSON.pretty_generate(QualityCore.check(html))
end
