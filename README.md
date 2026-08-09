# ruby-scorecard

Measures how discoverable the Ruby and Rails ecosystem's **documentation** is to LLMs and AI coding
agents, and what maintainers can do about it. Runs at **[ruby.evilmartians.com](https://ruby.evilmartians.com)**.

Two halves, one repo:

- **The scorecard**, a generated page grading 94 ecosystem resources. Built by `scripts/` into
  `dist/`, server-rendered, crawlable with JavaScript off.
- **The analyzer**, a Rails app at [`/test`](https://ruby.evilmartians.com/test) that runs the same
  checks against any URL or repo you give it, live, and streams results as they land.

## Why

Given a free choice, 13 models picked Ruby **0 times in 1,267 classified solutions** on the open
[whichlang](https://github.com/chad/whichlang) benchmark. Models reach for what they can see. This
project measures the visible part and tracks whether it improves.

## What it measures

Two questions, asked separately, because they have different answers and different fixes.

**Retrieval: can an agent find and read it today?** Checked against the resource's *documentation*
URL, never its landing page.

| Indicator | Why it matters |
| --- | --- |
| robots allows AI | Whether CCBot, GPTBot, ClaudeBot and Google-Extended are permitted |
| crawlable, no WAF | A CDN or bot rule can block a crawler that `robots.txt` allows |
| sitemap | Crawlers reach deep pages far less often without one |
| `llms.txt` | Reported as informational: no major AI system uses it |
| content negotiation | Serves Markdown on `Accept: text/markdown` |
| `.md` routes | A Markdown twin of each docs page |

**Training: would it reach a corpus at all?**

| Indicator | Why it matters |
| --- | --- |
| in The Stack v3 | **Observed**, queried from the official Am-I-in-The-Stack index, never inferred from a licence |
| Common Crawl | Sampled page count against the sitemap total |
| quality | FineWeb-Edu score, best of 5, kept at ≥ 3 |

The reasoning behind all of it, with sources, is at
[/learn](https://ruby.evilmartians.com/learn).

## Architecture

The Rails app follows the layered architecture from Vladimir Dementyev's *Layered Design for Ruby on
Rails Applications* ([rules as a plugin](https://github.com/palkan/layered-rails-plugin)).
Dependencies point downward only.

| Directory | Holds | Rule |
| --- | --- | --- |
| `app/presenters` | Verdict, Actions, Funnel, RecallGrid, Discoverability, Steps | Reads a finished run and decides what it says. **Never fetches.** |
| `app/policies` | AnalysisPolicy | Who may run, who may read. Returns symbols, never sentences. |
| `app/services` | The probes, Run, StartRun, RunCost | Measures and orchestrates. May do I/O. |
| `app/models` | Analysis, User, Example, ReferencePage | Domain logic, persistence, curated data. |
| `app/infrastructure` | Http, Cache, ApiKeys | Talks to the outside world. |
| `app/configs` | AnalyzerConfig | Typed settings via `anyway_config`. |

The line that decides where code goes is **does it measure, or does it read?** `References` sits in
`app/services` despite rendering on the same screen as the presenters, because it probes real pages
against real models and costs money.

## Layout

```
app/                       # the Rails analyzer (see Architecture above)
config/                    # routes, initializers, credentials
data/scorecard.json        # probe output: the data the page is built from
data/coverage.json         # per-resource Common Crawl pages vs sitemap totals
data/stack.json            # observed The Stack v3 membership
data/license_notes.json    # hand-read licences, never script-written
data/content_gap.json      # "Rails vs the field" comparison matrix
scripts/probe.rb           # gather indicators over HTTP -> data/scorecard.json
scripts/coverage.rb        # CC page counts + sitemap totals -> data/coverage.json
scripts/stack_check.rb     # Am-I-in-The-Stack lookups -> data/stack.json
scripts/swh_check.rb       # Software Heritage archival -> data/swh.json
scripts/build.rb           # render dist/scorecard.html
src/                       # design tokens, fonts, nanotags web components
build.sh                   # assets (esbuild) + HTML (build.rb) -> dist/ -> public/
dist/                      # generated, committed, deployable
web/                       # standalone Sinatra FineWeb-Edu scorer (ruby-quality-api)
```

The generated page is **progressively enhanced**: `build.rb` server-renders the full table and all
prose; the components in `src/js/` only add the theme toggle, filter, sort and stat counters.

## Requirements

- **Ruby 3.4** and Bundler for the app, the probes and the renderer.
- **Node and npm** for the front-end bundle (esbuild bundles nanotags into `dist/assets/app.js`).
- **flyctl**, only to deploy or to run a probe from a disposable IP.

The FineWeb-Edu ONNX model (`vendor/fwedu/`, 419 MB) is gitignored. Only
`scripts/quality_core.rb` needs it; the app and the test suite do not.

## Run it

```bash
bundle install
bin/rails db:prepare
./build.sh                 # installs JS deps on first run, then assets + dist/ -> public/
bin/rails server           # http://localhost:3000
```

`/` serves the generated scorecard, `/test` is the live analyzer, `/learn` is the guide.

The analyzer works without model API keys; the memorization probe is the only step that needs them
and it reports honestly when they are absent.

## Tests and checks

```bash
bin/rails test             # 130 runs
bundle exec rubocop        # rubocop-rails-omakase
bundle exec brakeman
```

CI runs all three on every push and pull request, plus a fourth job asserting that `dist/`
regenerates unchanged from `data/` and `src/`. That last one catches a generator edited without a
rebuild, which nothing else would notice until the deployed pages disagreed with their source.

## Update the data

Refreshing re-probes 94 third-party sites, so it is a deliberate act rather than part of a deploy.

```bash
ruby scripts/probe.rb      # indicators -> data/scorecard.json
ruby scripts/coverage.rb   # CC counts + sitemap totals -> data/coverage.json
ruby scripts/stack_check.rb   # observed Stack v3 membership -> data/stack.json
./build.sh                 # rebuild dist/
```

Add or remove a resource in the `RESOURCES` list at the top of `scripts/probe.rb`, using the **docs**
URL. Full instructions live in `.claude/skills/update-scorecard/SKILL.md`.

### Run the probes from a disposable IP

Common Crawl's CDX index is IP rate-limited, so a throttled run can briefly block the IP it came
from. Running from a throwaway Fly machine keeps your own IP clean and makes retries free:

```bash
./fetch/run-on-fly.sh      # temp Fly app, both probes, captures JSON, rebuilds dist/, tears down
```

**Common Crawl notes, all learned the hard way:**

- **No API key exists.** The CDX index is unauthenticated and IP rate-limited, per
  [their FAQ](https://commoncrawl.org/faq). The scripts are polite by construction: serial, with a
  sleep between calls, a descriptive User-Agent and a per-host cap. A **503** means slow down; a
  temporary block clears after 24h.
- **A connection refused is an outage, not a ban.** `index.commoncrawl.org` goes down often. When it
  does, `coverage.rb` still fills sitemap totals and keeps known counts.
- **Never show a 0 you could not measure.** Unknown values render as "not sampled". `probe.rb`
  aborts rather than writing a run where more than 15% of resources were unreachable, because that
  is a broken instrument rather than a finding.
- For all 94 at once, Common Crawl recommends the columnar index via Amazon Athena. That needs an
  AWS account and is not wired up here.

### Per-page detail

Which exact documentation pages are in Common Crawl and which are missing:

```bash
./fetch/details-on-fly.sh "Inertia Rails" "AnyCable"
```

Writes `data/coverage_details.json` plus a shareable Markdown report per resource.

## Deploy

**Push to `main`.** CI runs RuboCop, Brakeman, the tests and the `dist/` freshness check, and the
Fly deploy runs only if all four pass. A red check stops the release.

For a redeploy that carries no commit (rollback, restart, or after a secret changes), run the
**Fly Deploy (manual)** workflow from the Actions tab.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The bar is slightly unusual for a repo that publishes
measurements: **a number goes on the site only if a stranger can reproduce it from `scripts/` and
`data/`.** Changes are recorded in [CHANGELOG.md](CHANGELOG.md), which separates code changes from
data refreshes so any figure quoted from the site can be traced to the run that produced it.

## License

[MIT](LICENSE). Permissive on purpose: this project's own guidance is that a permissive licence or
none is what keeps files in a code corpus, and it would be odd to publish that advice unlicensed.

---

<img src="https://cdn.evilmartians.com/badges/logo-no-label.svg" alt="" width="22" height="16" />  The Ruby &amp; Rails LLM discoverability scorecard is built by <b><a href="https://evilmartians.com/">Evil Martians</a></b>, an American design and engineering consultancy for <b>developer tools, AI, and cybersecurity startups</b>.

---
