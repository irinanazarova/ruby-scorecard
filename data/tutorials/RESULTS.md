# Optimized-style AnyCable tutorials: quality-score experiment

Five "how to" tutorials written in the FineWeb-Edu-optimized style (concept-first opening, ~20+ word
sentences, definitions up front, prose around code), then scored with the local classifier
(`ruby scripts/score.rb text <file>`). The bar for a modern web corpus to keep a page is **score >= 3**.

## Final scores (full files, as written)

| Tutorial | Score | Keep (>=3) |
| --- | --- | --- |
| 03 Streaming from a language model | **3.16** | yes |
| 01 Live cursors | 2.55 | no |
| 04 Chat | 2.22 | no |
| 02 Presence | 2.04 | no |
| 05 Background-job realtime status | 1.97 | no |

## What the experiment showed

1. **Topic breadth is the ceiling, not writing quality.** Every opening uses the same optimized
   register (avg sentence 25-32 words, opens with a definition, no leading metadata). The one that
   clears 3 is the one whose underlying subject is broadly educational: how a language model emits
   tokens and how streaming delivers them. The four that cap are narrow product/UI features. This
   matches the earlier finding (`data/gepa/RESULTS.md`): product how-tos plateau ~2.0-2.8 regardless of
   edits; only broadly-taught subjects (authorization, LLM streaming) cross 3 on a lead rewrite.

2. **The `# How to X with AnyCable` headline is itself a penalty (~-0.5).** Live cursors scored 1.92
   with the product-how-to H1 and 2.51 with the same body under a conceptual title or none. A
   descriptive/conceptual title ("Streaming text from a language model, one token at a time") scores
   higher than a product-framed one ("...with AnyCable").

3. **Concept-first framing helps but cannot rescue a niche topic.** Leading with the general idea
   (ephemeral vs durable data, publish-subscribe, presence as set membership) and naming the tool
   lightly lifted every draft, yet only the LLM topic reached the bar. Framing moves a page within its
   topic band; it does not change the band.

4. **Keep code below a ~400-word prose lead.** Only the first ~512 tokens (~380 words) are scored. When
   a code block leaks into that window the score drops ~0.3 (streaming: 3.30 prose-only vs 2.98 when the
   first fence entered the window under a weaker title). Pad the educational lead so the whole scored
   window is prose.

## Recommendation (per /learn)

- **Streaming tutorial:** clears the open web-filter proxy. It is the one worth investing crawl reach in
  (backlinks, cross-posts, sitemap) so Common Crawl actually fetches it.
- **The other four:** cap below the web bar because the subject is niche infra/UI. Do not expect the
  rendered page to be kept by a web corpus. Carry them through the **code/GitHub channel** instead: a
  public, permissively-licensed repo with these as runnable `examples/` and full-prose Markdown docs.
  The Stack ingests that Markdown with no prose-quality filter, so the content is trained on regardless
  of its FineWeb-Edu score.

_Scored June 2026 with the local FineWeb-Edu ONNX proxy. Single-sample; differences within ~0.3 are
noise. This is the open proxy, not Claude/GPT/Gemini's undisclosed filter._
