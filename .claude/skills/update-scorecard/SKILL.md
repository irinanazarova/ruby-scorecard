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
ruby scripts/probe.rb         # probes every resource over HTTP -> data/scorecard.json
./build.sh                    # bundles assets + renders dist/scorecard.html
```
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
