# How to get your documentation into LLM training data

Content has to pass two gates. It has to be **collected**, by a web crawler or from public code
hosting, and then it has to **survive the corpus builder's quality filter**. Being public and
crawlable clears the first gate only. Modern web pipelines discard around 90% of what they collect
([RefinedWeb](https://arxiv.org/abs/2306.01116)).

The biggest lever: **a library is learned mostly from its public code.** Code corpora take GitHub
files with no prose-quality filter at all, so the repo path skips the gate that stops most websites.

---

## Do this

**1. Put the docs source in a public GitHub repo.** Code datasets such as
[The Stack](https://huggingface.co/datasets/bigcode/the-stack-v2) ingest Markdown directly
([~254 GB of it](https://huggingface.co/datasets/bigcode/the-stack)) with no quality classifier.
This is the highest-value action on this page.

**2. Use a permissive license, or no license.** The Stack v2 and v3 keep files labeled `permissive`
and `no_license`, and drop only `non_permissive` (GPL and similar, "all rights reserved"). v1 dropped
unlicensed files; that rule is three dataset generations old.

**3. Check that Software Heritage has archived the repo.** The Stack v2 and v3 are built from the
[Software Heritage](https://archive.softwareheritage.org/) archive, and archival is a separate step
that is neither guaranteed nor automatic. `workos/authkit` (3.3k stars, MIT) is absent from it. A
permissive license on an unarchived repo buys nothing.

**4. Invest in the README and a runnable `examples/` directory.** The README is usually the
most-trained piece of text about a library.

**5. Make your canonical snippet the one people copy.** Being in a corpus and being reproducible from
memory are different things, and duplication is what separates them. Resend's quickstart is copied
into roughly 1,840 GitHub repositories, and models reproduce it verbatim.

**6. Lead blog posts with what the reader will learn, in plain sentences that define the terms.**
Only the first ~512 tokens (~380 words) are scored, so the opening decides the whole document.

**7. Earn links to deep pages.** Common Crawl ranks domains by
[harmonic centrality](https://www.mozillafoundation.org/en/research/library/generative-ai-training-data/common-crawl/),
gives higher-ranked domains a bigger crawl budget, and
[never copies any domain in full](https://dl.acm.org/doi/10.1145/3630106.3659033). New, deep, weakly
linked pages are the ones it misses.

**8. Fix crawl hygiene.** Ship a `sitemap.xml`, `301` moved URLs, expand thin pages, reduce
click-depth from the homepage.

**9. Measure instead of guessing.** Run any URL or repo through [/test](/test) for all four checks, or
[/check](/check) for the quality score alone.

## Skip this

**Blocking `CCBot`, `ClaudeBot`, or `GPTBot` in `robots.txt`,** if you want inclusion. This is the one
lever that is known to work on Anthropic's own crawler, in the direction of exclusion.

**Private repos and copyleft licenses.** Private content never enters code corpora, and
`non_permissive` files are dropped by name.

**Chasing stars.** Star count is not an inclusion filter in any version of The Stack. It decides only
whether a *fork* gets crawled (5 or more stars) and which copy survives deduplication.

**Mirroring your docs verbatim into other repos.** Near-duplicate detection (MinHash-LSH) collapses
copies into one representative and removed about 40% of permissively licensed files in The Stack v2.
Your sentences quoted inside someone else's different document survive as a distinct example.

**Stripping boilerplate to raise your quality score.** Measured below: it does not help and can hurt.

**Opening with war stories, benchmarks, or announcements.** Those genres score below the keep bar no
matter how they are edited.

**`llms.txt`.** [No major AI system uses it](https://www.seroundtable.com/google-does-not-endorse-llms-txt-40789.html)
for training or inference.

**Relying on the rendered docs site alone.** Reference and configuration pages fail the quality filter
almost without exception. Let the GitHub channel carry them.

---

## The four channels

| Channel | Feeds | Collected by | Quality gate |
| --- | --- | --- | --- |
| Code and docs in repos | Code corpora (The Stack) | Software Heritage, from public GitHub | **none**; license and dedup only |
| Blog posts | Web corpora | Common Crawl | rewards tutorial prose |
| Rendered documentation | Web corpora | Common Crawl | hostile to reference and code |
| Marketing site | Web corpora | Common Crawl | rewards almost nothing |

The web gate is the open
[FineWeb-Edu classifier](https://huggingface.co/HuggingFaceFW/fineweb-edu-classifier), which keeps a
document when its score rounds to 3 or higher (raw score ≥ 2.5). It was
[deliberately tuned toward school-level explanation and away from technical pages](https://arxiv.org/abs/2406.17557).

---

## What we measured

### Stars do not predict memorization

We probed **168 documentation repositories, 309 passages** (give a model 55 words of a page and
measure the longest exact continuation it produces, with a positive and a negative control). Nineteen
repos produced at least one hit.

| Predictor | Spearman ρ vs hit rate | p (permutation) |
| --- | ---: | ---: |
| Stars | +0.006 | 0.94 |
| Forks | +0.042 | 0.59 |
| Owner's top-repo stars | +0.012 | 0.88 |

`vercel/next.js` (141k stars) and `supabase/supabase` (107k stars) produced nothing.
`getsurfboard/manual` (115 stars) produced a 33-word exact run.

**Independent copies predict it instead.** In an earlier, denser study of 15 repositories
(38 passages), copy count correlated at **ρ = +0.70, p = 0.005**, while stars gave ρ = +0.28
(p = 0.31, not significant). `tailwindlabs/tailwindcss.com` has no license, about 140 stars and 68
independent copies, and was the most memorized repo in that sample. Stars measure how many people
liked a project. Copies measure how many times its sentences exist in the world, and a corpus counts
the second one. Re-running those passages against a frontier model from a different lab reproduces
the same ranking (**ρ = +0.68, p = 0.0065**), so this reflects what is on the internet and holds
across labs.

### A missing license does not suppress anything

| License class | Repos with a hit |
| --- | --- |
| No license | 11 / 57 (19%) |
| Permissive | 8 / 91 (9%) |
| Copyleft | 0 / 9 |
| Source-available | 0 / 2 |

Unlicensed repos were hit more often, at Fisher exact p = 0.079. We do not claim a missing license
helps: prominence is confounded with license here. The supportable reading is that there is no
evidence a missing license suppresses inclusion, which matches the documented v2/v3 policy. The
copyleft and source-available groups are too small to test.

### Rendered reference docs do not clear the quality bar

| Site | Pages scored | Clearing the 2.5 bar | Best page |
| --- | ---: | ---: | ---: |
| evilmartians.com | 598 | 5 | 3.12 |
| docs.anycable.io | 118 | 0 | 2.44 |

### Common Crawl reached about a third of two sites, and quality played no part

It held 37% of evilmartians.com (221 of 600 pages) and 27% of docs.anycable.io (34 of 125). Crawled
and missed pages scored the same on quality (1.52 vs 1.51, and 1.83 vs 1.83). The gap comes entirely
from how the crawler samples links.

### Rewriting the lead clears the bar; removing boilerplate does not

| Version | Blog post | Reference docs page |
| --- | ---: | ---: |
| As published | 2.43 | 2.44 |
| Boilerplate stripped | 2.48 | 2.11 |
| Lead rewritten to teach | **3.19** | 2.56 |
| Rewritten as a textbook section | 3.54 | 2.83 |

The blog post clears the bar once its opening explains what the reader will learn. The reference page
never clears it, even fully rewritten. Genre sets the ceiling.

### Failing the quality filter does not mean absent from training

| Page | Quality score | Filter keeps it? | Verbatim recall |
| --- | ---: | :--: | :--: |
| Supabase Auth guide | 1.43 | no | yes, 23-word run |
| Resend Node.js quickstart | 1.68 | no | yes, 15-word run |

Both pages reached training through the code channel. Supabase's docs live in
[`supabase/supabase`](https://github.com/supabase/supabase) under Apache-2.0, and Resend's quickstart
is the canonical snippet from its MIT-licensed [`resend-node`](https://github.com/resend/resend-node)
repo. Supabase's Row Level Security guide sits in the *same* repo and showed no verbatim recall,
because it is prose, and prose gets paraphrased instead of copied.

---

## Check your own pages

| Question | Tool |
| --- | --- |
| All four checks at once | [/test](/test) |
| Is it in Common Crawl? | [index.commoncrawl.org](https://index.commoncrawl.org/), CDX query `url=domain/*` |
| Would the filter keep it? | [/check](/check), or the [classifier](https://huggingface.co/HuggingFaceFW/fineweb-edu-classifier) directly |
| Is the repo collected? | [SWH API](https://archive.softwareheritage.org/api/1/origin/) `origin/https://github.com/<owner>/<repo>/visit/latest/` |
| Is the text memorized? | `scripts/repo_probe.rb` |
| Are crawlers allowed? | your `robots.txt` |

Score the page rather than judging it by eye. The people who built these classifiers report that
expert humans cannot predict them: in the [DCLM keynote](https://www.youtube.com/watch?v=IsNqSmTPiWQ)
Ludwig Schmidt found hand-labelers could not tell the best classifier variants apart, and Ari Morcos
[reports](https://www.youtube.com/watch?v=yXPPcBlcF8U) that NLP graduate students could not predict
DCLM's classifier above chance.

---

## Limits

- **These are open proxies, not any lab's filter.** FineWeb-Edu and Common Crawl are documented and
  public. Anthropic, OpenAI and Google do not disclose theirs.
- **Quality scores are single runs on the first ~512 tokens.** Differences under 0.3 are noise.
- **A negative memorization result is weak evidence.** Models memorize a fraction of what they read,
  so an absence proves little. A positive result is strong: text cannot be reproduced unless it was
  seen.
- **Copy counts come from GitHub code search,** which sees one slice of duplication. `rails/rails`
  shows 2 GitHub copies yet produced a 30-word run, because Rails Guides are duplicated across the web
  instead.
- **Rules are versioned.** C4's curly-brace rule is from 2019 and modern filters are softer. The Stack
  v1 excluded unlicensed repos and v2/v3 include them. Any claim about licenses has to name the
  corpus version.
- **Inclusion is not influence.** Trained-on content is still deduplicated and weighted.
- **Run memorization probes in an empty directory with tools off.** Our first cross-model run scored a
  perfect 1.0 overlap because the agent found the probe's own answer file on disk. The same passage
  from an empty directory scored 0.0.
- **There is no working public Stack-membership oracle.** The
  ["Am I in the Stack?"](https://huggingface.co/spaces/bigcode/in-the-stack) space answers "No" for
  every input, including `torvalds` and `rails`. Check collection and license separately instead.

---

## Sources

- Common Crawl: [Baack, FAccT'24](https://dl.acm.org/doi/10.1145/3630106.3659033) ·
  [Mozilla](https://www.mozillafoundation.org/en/research/library/generative-ai-training-data/common-crawl/) ·
  [CC index](https://index.commoncrawl.org/)
- Web filters: [C4 / T5](https://arxiv.org/abs/1910.10683) ·
  [Documenting C4](https://aclanthology.org/2021.naacl-main.41.pdf) ·
  [RefinedWeb](https://arxiv.org/abs/2306.01116) ·
  [FineWeb / FineWeb-Edu](https://arxiv.org/abs/2406.17557) ·
  [classifier](https://huggingface.co/HuggingFaceFW/fineweb-edu-classifier)
- Code corpora: [StarCoder2 / The Stack v2](https://arxiv.org/abs/2402.19173) ·
  [The Stack v1](https://huggingface.co/datasets/bigcode/the-stack) ·
  [v2](https://huggingface.co/datasets/bigcode/the-stack-v2) ·
  [stack-v3-train](https://huggingface.co/datasets/HuggingFaceCode/stack-v3-train) ·
  [Software Heritage API](https://archive.softwareheritage.org/api/1/)
- Crawler policy: [ClaudeBot](https://support.claude.com/en/articles/8896518-does-anthropic-crawl-data-from-the-web-and-how-can-site-owners-block-the-crawler) ·
  [Google on llms.txt](https://www.seroundtable.com/google-does-not-endorse-llms-txt-40789.html)
- Practitioners: [Penedo / FineWeb](https://www.youtube.com/watch?v=5mCjNAQPSLw) ·
  [Ben Allal / FineWeb-Edu](https://www.latent.space/p/2024-syndata-smolmodels) ·
  [Schmidt / DCLM](https://www.youtube.com/watch?v=IsNqSmTPiWQ) ·
  [Morcos / data curation](https://www.youtube.com/watch?v=yXPPcBlcF8U) ·
  [Scialom / Llama 3](https://www.latent.space/p/llama-3) ·
  [Karpathy](https://www.dwarkesh.com/p/andrej-karpathy)

_Last updated 2026-08-05. Every measured number here is reproducible from `scripts/` and `data/` in
[this repo](https://github.com/irinanazarova/ruby-scorecard)._
