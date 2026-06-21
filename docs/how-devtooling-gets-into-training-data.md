# How devtooling resources get into LLM training data

To be trained on, your content has to clear **two gates**: get collected (a web crawl or public code
hosting), then survive the corpus builder's quality filter. Crawlable does not mean trained on. Here is
what to do about it, then how it works.

---

## DO and DON'T

The biggest lever first: **a library is learned mostly from its public code, not its website.** Code
corpora skip the web quality filter entirely.

### DO

- **Put code and docs in a public, permissively-licensed (MIT/Apache) GitHub repo.** Code corpora
  ([The Stack](https://huggingface.co/datasets/bigcode/the-stack-v2)) ingest it directly, no quality filter.
- **Invest in the README and a runnable `examples/` directory.** The README is often the single
  most-trained piece of text about a library.
- **Keep docs *source* as full-prose Markdown in that public repo.** The Markdown itself is trained on,
  regardless of whether the rendered site is crawled.
- **Write tutorial / explanatory blog posts**, and **lead the first ~380 words** with what the reader will
  learn, defining key terms in plain sentences. Only the opening is scored, and this is the lever that
  clears the bar **(measured: 2.43 → 3.19)**.
- **Earn backlinks and internal links** (newsletters, aggregators, cross-posts) so Common Crawl actually
  reaches new and deep pages.
- **Fix crawl hygiene:** `sitemap.xml`, `301` redirects for moved URLs, expand thin pages, cut click-depth.
- **Verify** (see [How to check](#how-to-check)): is it in Common Crawl, does it score ≥ 3, are crawlers
  unblocked.

### DON'T

- **Don't rely on the rendered docs site alone.** Reference/API pages structurally fail the quality filter
  **(measured: ceiling ~2.8 even fully rewritten)**. Let the GitHub channel carry them.
- **Don't keep content in a private or unlicensed repo.** It will not enter code corpora.
- **Don't lead posts with war-stories, anecdotes, or marketing.** Benchmark and announcement genres cap
  below 3 **(measured: 1.5-1.9)** no matter how you edit them.
- **Don't bury the substance below the fold.** The classifier reads only the first ~512 tokens.
- **Don't expect `llms.txt` to help.** [No major AI system uses it](https://www.seroundtable.com/google-does-not-endorse-llms-txt-40789.html)
  for training or inference.
- **Don't just strip boilerplate** and expect a better score. It does not raise quality **(measured: it can
  lower it)**; rewrite the substance instead.
- **Don't block `CCBot`, `ClaudeBot`, `GPTBot`** in `robots.txt` if you want inclusion.

---

## How it works (the short version)

### Two gates

1. **Collection.** A [web crawl](https://commoncrawl.org/) (Common Crawl, or a lab's own crawler) or
   [public code hosting](https://huggingface.co/datasets/bigcode/the-stack-v2) (GitHub).
2. **Filtering.** Builders drop most of what they collect. Modern web pipelines keep on the order of 10% of
   raw crawl ([RefinedWeb removed ~90%](https://arxiv.org/abs/2306.01116)).

### Four channels

| Channel | Feeds | Collected by | Quality gate |
| --- | --- | --- | --- |
| Code + docs-in-repos | Code corpora (The Stack) | GitHub, **public + permissive only** | **none** (license + dedup) |
| Blog posts | Web corpora | Common Crawl | rewards tutorial prose |
| Documentation (rendered) | Web corpora | Common Crawl | hostile to reference/code |
| Content website | Web corpora | Common Crawl | rewards little (marketing) |

### Why most devtooling content struggles

- **Common Crawl is centrality-sampled, not complete.** It ranks domains by
  [harmonic centrality](https://www.mozillafoundation.org/en/research/library/generative-ai-training-data/common-crawl/)
  (how linked-to you are), gives higher-ranked domains a bigger crawl budget, and **never copies a domain
  in full** ([FAccT'24](https://dl.acm.org/doi/10.1145/3630106.3659033)). Hubs get in; deep, new, weakly
  linked pages mostly don't. **(measured: evilmartians.com 37%, docs.anycable.io 27%; crawled and missing
  pages scored identically, so the gap is reach, not quality.)**
- **The quality filter rewards educational prose and penalizes reference, code, and marketing.** The open
  [FineWeb-Edu classifier](https://huggingface.co/HuggingFaceFW/fineweb-edu-classifier) (keeps documents
  scoring ≥ 3 / 5) was [deliberately tuned toward school-level explanation and away from technical pages](https://arxiv.org/abs/2406.17557).
  Its ancestor [C4](https://arxiv.org/abs/1910.10683) was blunter still: it dropped *any whole page
  containing a curly brace* `{` (a 2019 rule; modern filters are softer). **(measured: 1 of 598
  evilmartians.com pages and 0 of 117 AnyCable docs pages cleared ≥ 3.)**
- **Code corpora skip that filter.** [The Stack](https://huggingface.co/datasets/bigcode/the-stack-v2) takes
  permissively-licensed GitHub files (including [~254 GB of Markdown](https://huggingface.co/datasets/bigcode/the-stack))
  with no prose-quality classifier, which is why the public-repo path is the strongest one.

And capability follows representation: models do well on high-resource languages and
[struggle on low-resource ones](https://arxiv.org/abs/2308.09895), though
[synthetic/fine-tuning data](https://arxiv.org/abs/2308.09895) can close gaps, so data share is not destiny.

---

## Key terms

- **Centrality (harmonic centrality):** a link-popularity score; the more pages link to you, directly or via
  short chains, the higher it is. Crawlers use it to decide what to fetch. *Raise it with backlinks.*
- **Crawl budget:** the capped number of URLs a crawler fetches from one domain; higher centrality buys more.
- **Recall (coverage):** the share of a site's real pages actually crawled (we measured 27-37%).
- **Corpus:** a curated dataset a model trains on (C4, FineWeb, The Stack).
- **Quality classifier:** a small model that scores "educational value" and drops low scorers (FineWeb-Edu
  keeps ≥ 3 / 5).
- **Token:** the unit a model reads, roughly ¾ of a word; only the first ~512 (~380 words) get scored.
- **Permissive vs. copyleft license:** permissive (MIT, Apache) is kept by code corpora; copyleft (GPL) is
  largely excluded.
- **The Stack:** a large public dataset of GitHub code and docs used to train code models; bypasses the web
  quality filter.
- **Pretraining vs. fine-tuning:** pretraining is where a model learns whether it "knows" Ruby; that is the
  target here. Fine-tuning shapes later behavior.
- **RAG / MCP / llms.txt:** inference-time retrieval, they affect what a model looks up at runtime, not what
  it was trained on.

---

## How to check

| Question | How | Tool |
| --- | --- | --- |
| Is it in Common Crawl? | CDX query `url=domain/*` per crawl | [index.commoncrawl.org](https://index.commoncrawl.org/), `scripts/coverage_details.rb` |
| Would the filter keep it? | Score with FineWeb-Edu (≥ 3); only ~512 tokens are read | [classifier](https://huggingface.co/HuggingFaceFW/fineweb-edu-classifier), `scripts/quality_core.py`, the `/check` page |
| Is the code in The Stack? | Repo public + permissive license? | ["Am I in the Stack?"](https://huggingface.co/spaces/bigcode/in-the-stack) |
| Are crawlers allowed? | `robots.txt` for `CCBot`/`ClaudeBot`/`GPTBot` | server logs, `robots.txt` |

---

## Caveats and what is contested

- **Proxies, not ground truth.** FineWeb-Edu and C4 are *open, documented* filters. Frontier labs
  (Anthropic, OpenAI, Google) do not disclose theirs, so our scores show what representative open pipelines
  do, not what Claude's filter does. The one lever you control for Anthropic is `robots.txt`
  ([blocking `ClaudeBot` excludes future content from training](https://www.searchengineland.com/anthropic-claude-bots-470171)).
- **Single-sample, lead-only.** Our quality numbers are single runs; differences within ±0.3 are noise, and
  only the first ~512 tokens are scored.
- **Era matters.** C4's curly-brace rule is from 2019; modern corpora filter differently.
- **Inclusion ≠ influence.** Trained-on content is still deduplicated and weighted; presence is not learning.

---

## Sources

- Common Crawl: [Baack, FAccT'24](https://dl.acm.org/doi/10.1145/3630106.3659033) ·
  [Mozilla](https://www.mozillafoundation.org/en/research/library/generative-ai-training-data/common-crawl/) ·
  [CC index](https://index.commoncrawl.org/)
- Web filters: [C4 / T5 (Raffel et al.)](https://arxiv.org/abs/1910.10683) ·
  [Documenting C4 (Dodge et al.)](https://aclanthology.org/2021.naacl-main.41.pdf) ·
  [RefinedWeb](https://arxiv.org/abs/2306.01116) ·
  [FineWeb / FineWeb-Edu](https://arxiv.org/abs/2406.17557) ·
  [classifier](https://huggingface.co/HuggingFaceFW/fineweb-edu-classifier)
- Code corpora: [StarCoder2 / The Stack v2](https://arxiv.org/abs/2402.19173) ·
  [The Stack v1](https://huggingface.co/datasets/bigcode/the-stack) ·
  [Am I in the Stack?](https://huggingface.co/spaces/bigcode/in-the-stack)
- Representation: [MultiPL-E](https://par.nsf.gov/biblio/10416465) ·
  [low-resource / MultiPL-T](https://arxiv.org/abs/2308.09895)
- Anthropic & llms.txt: [ClaudeBot docs](https://support.claude.com/en/articles/8896518-does-anthropic-crawl-data-from-the-web-and-how-can-site-owners-block-the-crawler) ·
  [Google on llms.txt](https://www.seroundtable.com/google-does-not-endorse-llms-txt-40789.html)

_Last updated 2026-06-20. Measured findings are reproducible via `scripts/quality_core.py` and
`scripts/coverage_details.rb` in this repo._
