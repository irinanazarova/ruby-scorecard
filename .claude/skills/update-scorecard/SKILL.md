---
name: update-scorecard
description: Re-probe and rebuild the Ruby & Rails LLM discoverability scorecard. Use when adding or removing a resource, refreshing the indicators (robots/llms.txt/content negotiation/sitemap/.md), updating Common Crawl numbers, or updating the benchmark figures before deploying to ruby.evilmartians.com.
---

# Update the Ruby & Rails LLM discoverability scorecard

This project measures how discoverable Ruby/Rails ecosystem **documentation** is to LLMs and rebuilds a
deployable `dist/` (Evil Martians design system) for ruby.evilmartians.com.

Run everything **from the project root** (`~/Projects/ruby-scorecard`). The probe and renderer are **Ruby**
(stdlib + `curl`, no gems, no API keys). The front-end bundle needs **Node + npm** (esbuild bundles the
nanotags web components); `build.sh` runs `npm install` on first use.

The page is progressively enhanced: `build.rb` server-renders the full table and all prose (so it stays
crawlable with JS off); the components in `src/js/` only add the theme toggle, search/category filter,
column sort, and stat-counter animations.

## Common tasks

### Refresh the scorecard (re-probe everything, then rebuild)
```bash
./fetch/run-on-fly.sh         # BOTH probes from a disposable Fly machine, then rebuilds dist/
```
This is the way to refresh. It creates a throwaway Fly app, runs `probe.rb --print` and
`coverage.rb --print` there, captures each to `data/`, rebuilds, and destroys the app. Run it, review
the diff, then `fly deploy` from the repo root and commit.

Why not locally: a home connection that drops mid-run makes `probe.rb` record every remaining
resource as unreachable, and that does not read as "the probe failed". It reads as dozens of projects
having deleted their sitemap and llms.txt overnight, and as sites that block AI crawlers suddenly
allowing them, because an unfetched `robots.txt` defaults to "allow". That happened three times in
one afternoon and was caught by hand each time. Common Crawl's IP rate limit is the second reason.

Three safeguards, so a bad run cannot become a bad publish:
- a failed fetch is retried once (a dropped connection and a dead host look identical in one try);
- `probe.rb` aborts without writing if more than 15% of resources are unreachable;
- captures go to a temp file and only replace `data/` once the JSON validates, since redirecting
  straight into `data/*.json` truncates it before the probe has produced anything.

For coverage, counts the run could not measure are carried forward from the previous file. A null
means "we did not reach the index", never "this site left the corpus".

Local runs still work (`ruby scripts/probe.rb`, `ruby scripts/coverage.rb`) and honour the same abort
guard; use them for a quick look, not to publish.

`probe.rb` checks, per resource, against its **docs URL** (not the landing page):
robots-allows-AI, crawlable (fetches as a CCBot user-agent to catch Cloudflare/WAF blocks), sitemap,
llms.txt (at the docs host and the bare domain), content negotiation (`Accept: text/markdown`), `.md` routes.

If you only changed the data or the HTML template (not CSS/JS), `ruby scripts/build.rb` alone re-renders
`dist/scorecard.html`. Run `./build.sh` (or `npm run build:assets`) when the styles or components change.

### Add or remove a resource
Edit the `RESOURCES` list at the top of `scripts/probe.rb`. Each entry is an array:
```ruby
["Display Name", "category", "https://docs.example.com/docs/"]
```
Use the **documentation** URL, not the marketing landing page (e.g. `sorbet.org/docs/overview`, not
`sorbet.org`). Categories: `core`, `frontend & view`, `web frameworks`, `data`, `ai`,
`background, realtime & deploy`, `tooling & types`, `libraries`, `community & resources`. To add a new
category, also add it to `CAT_ORDER` / `CAT_LABEL` (and optionally `CHIP_LABEL`) in `scripts/build.rb`.
Then re-run probe + build.

### Refresh the Common Crawl coverage chart
```bash
ruby scripts/coverage.rb      # sitemap totals + CC page counts -> data/coverage.json
./build.sh                    # renders the "Corpus coverage" bars
```
Per resource this records `total_pages` (from the sitemap, reachable any time) and `cc_pages` (pages in
Common Crawl). It is **polite by construction** (single serial thread, a sleep between calls, a descriptive
User-Agent, a per-host cap), because CC's CDX index has **no API key** and is **IP rate-limited**
(<https://commoncrawl.org/faq>): a 503 means slow down, a temporary block clears after 24h.

`index.commoncrawl.org` has frequent outages. A connection-refused is an **outage, not a ban** (a ban
returns 503). When CC is down, `coverage.rb` still fills sitemap totals and preserves known CC numbers;
unknown values stay **"not sampled"**, never 0. Data lives in `data/coverage.json` (separate from
`scorecard.json` so `probe.rb` never clobbers it); `build.rb` merges by resource name. For all 54 at once,
CC recommends the columnar index via Amazon Athena (needs AWS; not wired up here).

`scripts/site_size.rb` remains for ad-hoc sitemap/crawl denominator spot checks. The benchmark figures
(`0/210`, `0/30` Opus 4.8, `4.2/5`) are **constants in `scripts/build.rb`** ("What we cannot find" and the
"final boss" callout); update them there when the source benchmark is re-run.

### Refresh the "in The Stack v3" column (observed membership)
```bash
ruby scripts/stack_check.rb   # official Am-I-in-The-Stack index -> data/stack.json
ruby scripts/build.rb         # re-render (no asset rebuild needed)
```
This is the code-corpus verdict, and it is **observed, not inferred**: the official checker
(huggingface.co/spaces/HuggingFaceCode/in-the-stack) is queried once per unique docs-repo OWNER and
returns every repo of theirs in The Stack v3 train set. v3 is a **direct GitHub crawl** (GH Archive +
the SWH graph, cutoff **2025-08-07**), license-filtered per file, and its per-file calls are not
reproducible from outside; they surprise in both directions (karafka/wiki's all-rights-reserved text is
in; karafka/karafka's LGPL is out; sidekiq/sidekiq's LGPL is in). Never override an observed answer
with a license argument. Incremental by default, `--refresh` for the quarterly re-check; an API failure
keeps previous answers, never fabricates a "no".

For repos absent from the set, the script records `created` and flags `post_cutoff` automatically, but
`created_at` cannot see private-until dates (basecamp/fizzy was created 2024, public 2025-12-02).
Reasons that took human digging go in **`data/stack_notes.json`** (hand-curated, never script-written),
keyed by repo slug: opt-outs with the issue URL (rspec #985, bridgetownrb #3734), private-until dates,
or `"reason": "unexplained"` (ruby/ruby). An absence with no note renders as "reason not established".

### Refresh the Software Heritage column
```bash
ruby scripts/swh_check.rb     # SWH origin lookups per docs repo -> data/swh.json
ruby scripts/build.rb         # re-render (no asset rebuild needed)
```
For each resource with a `docs_repo` in `data/repos.json`, this asks the Software Heritage archive
whether the repo is collected. SWH was the source **The Stack v2** was built from and stays on the page
as collection evidence and the one archival step a maintainer can trigger; for v3 it is no longer the
gate (v3 crawls GitHub directly), so the observed-membership column above is the verdict. Serial,
~1.2s between calls, one lookup per unique repo; the anonymous API allows ~120 requests/hour, so the
full run fits. On a 429 it stops and keeps known answers; unknown values render as "not checked".

### Record what a license really says
The code-corpus column prints GitHub's `license.spdx_id` **verbatim**, because that string is what
tooling reads and it is lossy: every license GitHub cannot match becomes `NOASSERTION` ("Other"), so a
bespoke permissive license and a source-available one look identical. `basecamp/fizzy` is the worked
example: `NOASSERTION` in the metadata, O'Saasy License Agreement in `LICENSE.md`, non-compete clause
and all.

When you open a license file yourself, record it in `data/license_notes.json`, keyed by repo slug:
```json
{"owner/repo": {"actual": "...", "class": "source-available", "file": "LICENSE.md",
                "note": "...", "stack_eligible": false, "read": "2026-08"}}
```
With observed membership in `data/stack.json`, a reading **explains** a verdict rather than deciding
it; `stack_eligible` remains the forecast for the next snapshot and the fallback verdict for repos the
index has no answer for. Do not restate the observed outcome in `note` (the page appends it). The file
is curated by hand and never written by a script. Read the text before adding an entry; do not infer
terms from the name.

### Update the benchmark figures
The model benchmark and capability numbers come from the `whichlang` project. When it is re-run on new
models, update the constants in `scripts/build.rb` (search for `4.2`, `0/210`, `0/30`, and the CC sample
block) and rebuild.

## Deploy
`dist/` is self-contained (HTML + `assets/` styles, bundled JS, and self-hosted fonts). Copy the whole
folder to the ruby.evilmartians.com host (e.g. `rsync -a dist/ <host>`). The detailed per-lever reference
lives in the `whichlang` project and links here.

## Guidelines
- Probe against docs, not landing pages.
- Never show a `0` you could not measure; mark it "not sampled" (CC is rate-limited).
- Keep claims measured and current; re-run quarterly and track the deltas.
