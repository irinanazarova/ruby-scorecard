# GEPA-style rule mining for the quality feedback engine

A reflective-optimization loop adapted to a deterministic ruleset (June 2026). Scoring is local Ruby
(`scripts/quality_core.rb`, FineWeb-Edu via ONNX); the "improve" step used model rewrites.

## Loop

1. **Corpus** (`urls.txt`): 12 usable EM pages, Action Policy docs, TestProf docs, AnyCable
   (getting-started + compare), 4 tutorial posts, 2 non-tutorial posts. Baseline scored (`baseline.json`).
2. **Improve:** 12 agents rewrote each lead to maximize the educational-quality score (`rewrites/`).
3. **Measure:** re-scored locally, recorded score deltas + feature changes (`deltas.json`).
4. **Mine:** kept the feature changes that drove the gains.
5. **Validate:** the refined rules fire on low-scoring bases and clear on improved leads.

## Result

Every page improved. Mean delta **+0.85** (range +0.08 to +1.47). Only 1 of 12 crossed 3 on a lead
rewrite alone (the page already starting at 2.21), confirming a topic/genre ceiling.

| lever | finding |
| --- | --- |
| **Sentence length** | The dominant signal. Average words/sentence rose ~10 → ~22 and tracked the delta tightly. Choppy fragments and bare lists read as reference; long connected sentences read as teaching. |
| **Opening definition** | Every strong rewrite opened with "X is a ..." or "This guide explains ...". |
| **Leading metadata** | Title/date/byline/nav and "Are you an LLM" banners waste the scored ~512 tokens. |
| Code density | Secondary here (these leads were not code-heavy after extraction). |
| De-boilerplating alone | Confirmed weak (matches the earlier experiment). |
| Topic/genre ceiling | Product install guides and reports plateau ~2.0-2.8 even fully rewritten. |

## Rules baked into `quality_core.rb`

- `avg_sentence_words < 15` → "lengthen the sentences (~20+); biggest lever, avg +0.85" (was `< 6`).
- `opens_with_definition` (first ~2 sentences) → "open with what this teaches / a definition".
- `leading_meta` / `boiler_in_lead` → "strip metadata and banners from the opening".
- Verdict calibrated: a lead rewrite adds ~0.8; below ~2.2 a rewrite alone usually will not reach 3.

Validation: across the 12 pages the rules fired **18** suggestions on the low-scoring bases vs **4** on the
high-scoring rewrites. Reproduce with `ruby scripts/gepa.rb baseline` then `ruby scripts/gepa.rb score`.
