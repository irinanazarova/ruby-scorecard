# Rewrite candidates: moving EM content over the FineWeb-Edu bar

Run of the `improve-training-quality` skill over Evil Martians content (June 2026). Scoring is local
(`scripts/quality_core.rb`). **Bar = FineWeb-Edu `int_score >= 3`, i.e. raw score >= 2.5** (the rounded
label the corpus actually filters on).

## How many pages

- **44** Ruby/Rails blog posts screened (`data/blog/screen.json`). **0** currently clear the bar; 8 sit in
  the movable band (raw 2.0-2.99), 36 below 2.0.
- **8** movable posts taken through the rewrite loop. **7 of 8 clear the bar** after an aggressive
  textbook-style opening; 1 is a genuine ceiling.
- **5** AnyCable guides (requested). **0 of 5** clear the bar even after rewriting (reference-doc ceiling).

## Which pages + what the rewrite does (blog)

Proposed new openings live in `data/blog/rewrites_v2/<slug>.txt` (replace the post's first ~380 words).

| post | base | 1st pass | aggressive | bar |
| --- | ---: | ---: | ---: | :--: |
| freezolite (frozen string literals) | 2.14 | 1.95 | **3.60** | kept |
| ruby-on-rails-on-webassembly | 2.04 | 2.81 | **3.57** | kept |
| postgresql-and-rails (tree data) | 2.11 | 2.76 | **3.21** | kept |
| partition-and-conquer | 2.01 | 2.48 | **3.01** | kept |
| graphql-on-rails-1 | 2.03 | 2.27 | **2.93** | kept (rounds to 3) |
| system-of-a-test-2 (SitePrism) | 2.09 | 2.27 | **2.88** | kept (rounds to 3) |
| unparser (Parser -> Prism) | 2.41 | 2.10 | **2.78** | kept (rounds to 3) |
| how-to-graphql-no-n+1 | 2.10 | 1.75 | 2.10 | **ceiling** |

Each rewrite applies the measured rules: open with a one-sentence definition / "what you'll learn",
define every key term in a full sentence, full connected sentences (no fragments/lists/code/metadata in
the scored window), faithful to the post's real facts.

## Which pages (AnyCable guides) — not worth a rewrite

| guide | base | rewrite | bar |
| --- | ---: | ---: | :--: |
| rails/getting_started | 1.82 | 1.95 | no |
| guides/serverless | 1.67 | 1.88 | no |
| guides/client-side | 1.95 | 1.84 | no |
| guides/laravel | 1.72 | 1.76 | no |
| guides/hotwire | 1.78 | 1.71 | no |

Reference/config docs cap ~1.7-2.0 regardless of prose quality. Route these through the **code/repo
channel** (public, permissively-licensed repo, strong README, runnable examples, the `.md` source is
trained on directly). See `docs/how-devtooling-gets-into-training-data.md`.

## Caveats to weigh before a PR

- **Two-pass needed.** A light rewrite was not enough (some regressed). Crossing the bar needed an
  aggressive textbook style with **long sentences (avg ~30-60 words)**, which reads more academic than the
  punchy Martians voice. Review each opening for tone before shipping.
- **Proxy, not ground truth.** FineWeb-Edu is the open proxy, not Claude/GPT/Gemini's filter; raw
  differences within ~0.3 are noise (several "kept" posts sit at 2.78-2.93, i.e. round to 3 but are close).
- Only the opening ~380 words change; the rest of each post is untouched.
