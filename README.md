# ruby-scorecard

A measured scorecard of how discoverable the Ruby & Rails ecosystem's **documentation** is to LLMs and
AI coding agents, and what the community can do about it. Builds a deployable `dist/` for
**ruby.evilmartians.com** in the Evil Martians design system.

## Why

Frontier models do not reach for Rails on product work (0 Rails in 210 product-task samples across 7
models; 0/30 on the newest model). It is a discoverability gap, not a capability one: forced to use Rails,
the same models write idiomatic Rails (~4.2/5). This project tracks the fixable, checkable signals.

## What it measures

Per resource, against its **documentation URL** (not the landing page):

| Indicator | Why it matters |
| --- | --- |
| robots allows AI | Are CCBot/GPTBot/ClaudeBot/Google-Extended permitted |
| crawlable (no WAF block) | Cloudflare/WAF can block bots even when robots allows |
| sitemap | Crawlers capture little without one |
| llms.txt | LLM-readable doc index |
| content negotiation | Serve Markdown on `Accept: text/markdown` (the durable, agent-used standard) |
| .md routes | Markdown twin of each doc page |

Plus a sampled Common Crawl page count (the corpus most models train on).

## Layout

```
data/scorecard.json        # probe output (the data the page is built from)
data/coverage.json         # per-resource Common Crawl pages vs sitemap totals (optional)
scripts/probe.rb           # gather indicators over HTTP -> data/scorecard.json
scripts/coverage.rb        # CC page counts + sitemap totals -> data/coverage.json
scripts/build.rb           # render dist/scorecard.html (+ benchmark constants)
scripts/site_size.rb       # ad-hoc Common Crawl coverage denominators (spot checks)
src/styles/                # design tokens, fonts (@font-face), base layout
src/js/                    # nanotags web components (theme, filter/sort, counters)
src/fonts/                 # self-hosted Martian Grotesk + Martian Mono (woff2)
build.sh                   # one-shot build: assets (esbuild) + HTML (build.rb) -> dist/
package.json               # esbuild (dev) + nanotags/nanostores
dist/                      # generated, deployable (HTML + assets/ + fonts/)
```

The page is **progressively enhanced**: `build.rb` server-renders the full table and all prose, so it is
complete and crawlable with JavaScript off. The nanotags components only enhance the existing DOM (theme
toggle, search/category filter, column sort, animated stat counters).

## Requirements

- **Ruby** (stdlib only, plus `curl`) for the probe and the HTML renderer.
- **Node + npm** for the front-end bundle (esbuild bundles nanotags into `dist/assets/app.js`).

## Build

From the project root:

```bash
./build.sh          # installs JS deps on first run, bundles assets, renders dist/scorecard.html
```

Or run the steps individually:

```bash
npm install         # first time only
npm run build:assets   # JS + CSS + fonts -> dist/assets/
ruby scripts/build.rb  # data/scorecard.json -> dist/scorecard.html
```

Preview locally:

```bash
ruby -run -e httpd dist -p 8911    # open http://localhost:8911/scorecard.html
```

## Update the data

```bash
ruby scripts/probe.rb       # re-probe every resource over HTTP -> data/scorecard.json
./build.sh                  # rebuild dist/
```

To add or remove a resource, edit the `RESOURCES` list at the top of `scripts/probe.rb` (use the **docs**
URL, not the marketing landing page), then re-probe and rebuild. Full instructions:
`.claude/skills/update-scorecard/SKILL.md`.

### Common Crawl coverage (optional)

```bash
ruby scripts/coverage.rb     # sitemap totals now + CC page counts -> data/coverage.json
./build.sh                   # renders the "Corpus coverage" chart from it
```

This fills the per-resource **pages-in-Common-Crawl vs sitemap-total** chart. Notes:

- **No API key exists.** Common Crawl's CDX index is unauthenticated and **IP rate-limited**. The script is
  polite by construction (single serial thread, a sleep between calls, a descriptive User-Agent, a per-host
  cap), per <https://commoncrawl.org/faq>. An HTTP **503** means slow down; a temporary IP block clears
  after **24h**.
- The index server (`index.commoncrawl.org`) has **frequent outages**. A `Couldn't connect` / connection
  refused is an outage, *not* a ban (a ban returns 503). When it is down, `coverage.rb` still fills sitemap
  totals and keeps known CC numbers; CC counts fill in on a later run.
- Unknown values stay **"not sampled"** (never shown as 0). `coverage.json` lives separately so re-running
  `probe.rb` never clobbers it; `build.rb` merges the two by resource name.
- For all 54 at once (instead of serial CDX), CC recommends the columnar URL index via **Amazon Athena**;
  that path needs an AWS account and is not wired up here.

## Deploy

`dist/` is self-contained. Copy the whole folder to the ruby.evilmartians.com host, e.g.
`rsync -a dist/ <host>`.

## Related

The detailed per-lever community reference ("what exists / does it work / who + how") lives in the
`whichlang` project and links to this scorecard.
