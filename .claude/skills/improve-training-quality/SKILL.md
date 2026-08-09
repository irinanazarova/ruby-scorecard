---
name: improve-training-quality
description: >
  Rewrite a page's content so it clears the FineWeb-Edu educational-quality bar (score >= 3 of 5), the
  open proxy for whether a modern training corpus would keep the page. Drives a rewrite<->score loop with
  a local Ruby scorer and reports honestly when a topic/genre ceiling makes >= 3 unreachable. Use when the
  user wants to improve a docs page, blog post, or URL's "trainability" / educational-quality score, or asks
  to push something past 3.
---

# Improve training quality (rewrite to clear FineWeb-Edu >= 3)

You iteratively rewrite the **opening** of a page and measure it with a local scorer until it clears the
bar or you prove it cannot. The model (you) does the rewriting; the deterministic scorer is the signal.

Trust the scorer over intuition. The researchers who built these classifiers report that people cannot
predict their verdicts by eye ([DCLM keynote](https://www.youtube.com/watch?v=IsNqSmTPiWQ); graduate
annotators "could not predict what the classifiers would say above chance"), which is exactly why this loop
measures every rewrite instead of guessing.

## Why only the opening

The classifier reads only the **first ~512 tokens (~380 words)**. Optimize that opening; do not waste
effort on the rest of the page. Keep the rewrite to ~330-400 words.

## The measured rules (what raises the score)

Mined from experiments in this repo (`data/gepa/RESULTS.md`), in priority order:

1. **Sentence length is the #1 lever.** Average ~20+ words per sentence. Turn fragments and bare lists into
   full, connected sentences. (Raising avg sentence length ~10 -> ~22 was the biggest gain, avg +0.85.)
2. **Open with a definition or learning objective.** The first sentence should say what the reader will
   learn or what the thing is: "X is a ...", "This guide explains ...".
3. **Strip leading metadata/chrome.** No title/date/byline, nav, "enable JavaScript" or LLM banners in the
   opening; they waste the scored window.
4. **Explain code, don't dump it.** Surround any code with prose; avoid raw code in the opening.
5. **Stay strictly faithful.** Never invent facts and never keyword-stuff "educational" phrasing. The goal
   is content that is genuinely clearer AND scores higher. A rewrite that games the proxy is a failure.

## Prerequisite

The scorer needs the model: if `vendor/fwedu/model.onnx` is missing, run `ruby scripts/fetch_model.rb`
once. The gems (`onnxruntime`, `tokenizers`, `nokogiri`) must be installed (`bundle install` or `gem install`).

## The loop

1. **Score the baseline.**
   - URL: `ruby scripts/score.rb url "<URL>"`
   - File or pasted text: save it to a scratch file and `ruby scripts/score.rb text <file>`
   Read the JSON: `score`, `features` (`opens_with_definition`, `avg_sentence_words`, `leading_meta`,
   `code_density`, `curly`, `words`), and `suggestions`.

2. **If `score >= 3`:** report it already clears the bar; stop (offer light tightening only if asked).

3. **Rewrite the opening** (~330-400 words) applying the rules above, addressing every item in
   `suggestions`. Save it to a scratch file (e.g. `/tmp/rewrite.txt`).

4. **Score the rewrite:** `ruby scripts/score.rb text /tmp/rewrite.txt`.

5. **Decide:**
   - `score >= 3` -> **success.** Output the rewrite, the baseline->final scores, and what changed. Stop.
   - improved by `>= 0.1` but `< 3` -> apply the still-firing `suggestions` and **repeat from step 3**
     (max **4** iterations total; keep the best version).
   - improved by `< 0.1` (**plateau**): inspect `features`. If `opens_with_definition` is true,
     `avg_sentence_words >= 20`, and `leading_meta` is false (every lever already applied) yet still `< 3`,
     do **one** aggressive "textbook" pass: add an explicit "What you will learn" line and define 2-3 key
     terms in full sentences. Score it. If it still does not cross 3, treat it as a **ceiling** (next step).

6. **On a ceiling, be honest.** Report the best version and its score, and explain that >= 3 is not
   reachable by rewriting because the classifier caps this kind of content: reference/API docs top out
   ~2.8, and benchmark/announcement/opinion posts lower. Recommend the **structural** fix instead:
   - For reference docs: rely on the **code/GitHub channel** (a public, permissively-licensed repo with a
     strong README and runnable examples; the Markdown source is trained on regardless of the prose score).
   - For non-tutorial posts: the genre caps low; a genuinely instructional companion piece is more trainable.
   Point to `app/views/pages/learn.html.erb` (published at /learn) for the full strategy.

## Output

- One status line: `baseline X.XX -> final Y.YY` and whether it cleared 3 (yes / no, ceiling at ~Y).
- The rewritten opening, ready to paste.
- A short bullet list of what changed (which rules were applied).
- If a ceiling: the honest verdict + the structural recommendation above.

## Guardrails

- Cap at 4 rewrite iterations; never loop indefinitely.
- Never fabricate facts or stuff filler to raise the score.
- This is the **open FineWeb-Edu proxy**, not the actual filter used by Claude, GPT, or Gemini (undisclosed).
  Differences within ~0.3 are noise; present scores as directional.
