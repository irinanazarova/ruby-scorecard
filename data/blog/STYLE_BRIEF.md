# Rewrite brief: clear the quality filter while keeping Evil Martians house style

Rewrite the OPENING (~330-400 words, only the first ~512 tokens are scored) so it clears the FineWeb-Edu
educational-quality bar (keep = score rounds to >= 3, i.e. raw >= 2.5) **while staying in EM voice**.

## What the filter rewards (measured)
1. **Long, connected sentences** (avg ~22+ words; the single biggest lever). Turn fragments and bare lists
   into flowing prose.
2. **Open by defining the subject / saying what the reader will learn** ("X is a ...", "This guide shows ...").
3. **No leading metadata** (title, date, byline, nav, "enable JavaScript"/LLM banners) in the scored window.
4. **Explain code in prose**; keep raw code out of the opening.

## EM house style (keep where it does not fight the filter)
- **Voice:** a builder who ships, dense, direct, peer-to-peer, opinionated. Personality in the opening line.
- **Be opinionated**: state a position, not wallpaper. Show the scars (the hard part, the tradeoff).
- **Concrete and specific**: real numbers, real stack, named tools. "Explain HOW, not just WHAT."
- **Kill words:** simple, easy, seamless, leveraging, utilizing, solution, best-in-class, world-class,
  cutting-edge, industry-leading, deliver (say ship/build). No marketing cliches.
- **EM mentions:** at most two, each tied to a specific capability + outcome; full name "Evil Martians".

## Where they ALIGN (lean on this, it is the reconciliation)
The style guide's own LLM-discoverability rules already match the filter: **define terms on first use**
("LLMs parse defined terms better"), **explain HOW not just WHAT**, **every claim gets a number**. So a
strong, in-voice opening that defines its key term, explains the mechanism in real sentences, and stays
concrete will both read like EM and score well.

## Where they CONFLICT (the honest tension, note it)
- "If a sentence can be cut, cut it" / punchy density vs the filter's reward for long explanatory sentences.
- A pure "X is a ..." textbook opener vs an EM personality hook.
Resolution that works: **keep a short personality hook (1 line), then immediately define the subject and
explain why it matters in connected, specific prose.** Do not pad; lengthen by joining real ideas, not
filler. Stay faithful to the post's actual facts; never invent; never keyword-stuff.

## Self-score and iterate
Score with: `ruby scripts/score.rb text <yourfile>`. Read `score` and `features`
(`opens_with_definition`, `avg_sentence_words`, `leading_meta`, `code_density`). If raw < 2.5, revise
toward the levers above (usually: lengthen sentences, define the term in line 1-2) and re-score. Up to 4
passes; keep the best. If it plateaus below 2.5 with every lever applied, that is a genre ceiling, keep the
best in-voice version and say so.
