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
  BOILER = /\b(min read|subscribe|newsletter|cookies?|skip to content|are you an llm|all rights reserved|sign up|log in)\b/i
  DEFINES = /\b(is a|is an|is the|refers to|means|stands for|you will learn|by the end|in this (post|tutorial|guide|article|lesson))\b/i

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
        return [text, "nokogiri"] if text.length >= 50
      rescue LoadError, StandardError
        # fall through to regex
      end
      [regex_text(html), "regex"]
    end

    def score_window(text)
      enc = tokenizer.encode(text)
      out = model.predict({ "input_ids" => [enc.ids], "attention_mask" => [enc.attention_mask],
                            "token_type_ids" => [enc.type_ids] })
      logit = out["logits"].flatten.first.to_f
      logit.clamp(0.0, 5.0)
    end

    def score_text(text)
      lead = score_window(text)
      chunks = text.split.each_slice(CHUNK_WORDS).first(MAX_CHUNKS).map { |w| w.join(" ") }
      doc = chunks.size > 1 ? chunks.sum { |c| score_window(c) } / chunks.size : lead
      { score: lead.round(2), doc_score: doc.round(2), int_score: lead.round, keep: lead >= 3 }
    end

    def features(text)
      words = text.split
      lead = words.first(380).join(" ")
      code_chars = lead.count("{};<>")
      stops = text.count(".!?")
      {
        words: words.size,
        curly: text.include?("{"),
        code_density: (code_chars.to_f / [lead.length, 1].max).round(4),
        defines_terms: !DEFINES.match(lead).nil?,
        boiler_in_lead: !BOILER.match(lead).nil?,
        avg_sentence_words: (words.size.to_f / [stops, 1].max).round(1)
      }
    end

    def feedback(score, feats)
      s = score[:score]
      verdict =
        if s >= 3 then "Likely kept. Clears the educational-quality bar (>= 3)."
        elsif s >= 2 then "Borderline. Below the >= 3 keep threshold, but within reach of a rewrite."
        else "Likely dropped. Well below the >= 3 keep threshold."
        end
      out = []
      out << "Too short. Pages under ~300 words score near zero. Expand into a fuller explanation." if feats[:words] < 300
      if feats[:boiler_in_lead]
        out << "The opening ~380 words (all the classifier reads) contain navigation or marketing " \
               "boilerplate. Lead with the article itself, not chrome."
      end
      unless feats[:defines_terms]
        out << "The opening does not read as teaching. State what the reader will learn and define key " \
               "terms in the first paragraph. This was the single biggest lever we measured (+0.7 to +1.1)."
      end
      if feats[:code_density] > 0.02
        out << "High code-to-prose ratio in the opening. Surround code with explanation. Note that the " \
               "C4 filter dropped any page containing a curly brace."
      elsif feats[:curly]
        out << "Contains a curly brace. The 2019 C4 filter dropped any page containing one. Modern filters " \
               "are softer, but keep prose dense around code."
      end
      if feats[:avg_sentence_words].positive? && feats[:avg_sentence_words] < 6
        out << "Many very short fragments (list or reference style). Full explanatory sentences score higher."
      end
      if s < 3 && out.empty?
        out << "Reads as marketing or reference rather than a lesson. The classifier caps such content below " \
               "3 regardless of edits. Route this into code repos (READMEs and examples) or a tutorial-style post."
      end
      out << "Keep the lead teaching-first if you edit it further; that is what carries the score." if s >= 3
      { verdict: verdict, suggestions: out }
    end

    def check(content, is_html: true)
      text, method = is_html ? extract_text(content) : [content, "raw"]
      return { ok: false, error: "No extractable text (client-rendered or blocked)." } if text.length < 50

      sc = score_text(text)
      fb = feedback(sc, features(text))
      { ok: true, score: sc[:score], doc_score: sc[:doc_score], int_score: sc[:int_score], keep: sc[:keep],
        verdict: fb[:verdict], suggestions: fb[:suggestions], extracted_words: text.split.size,
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
