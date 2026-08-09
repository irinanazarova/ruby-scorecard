# Contributing

Thanks for helping. This repo publishes measurements, so the bar for a change is slightly unusual:
**a number goes on the site only if a stranger can reproduce it from `scripts/` and `data/`.**

## Setup

```bash
bundle install
bin/rails db:prepare
./build.sh          # generates dist/ and publishes it to public/ (needs Node for the JS bundle)
bin/rails server
```

`./build.sh` runs `npm install` on first use. The FineWeb-Edu ONNX model (`vendor/fwedu/`, 419 MB) is
gitignored and only `scripts/quality_core.rb` needs it; nothing else, including the test suite,
depends on it.

## Before you open a PR

```bash
bin/rails test
bundle exec rubocop
bundle exec brakeman
```

CI runs all three, plus a check that `dist/` still regenerates unchanged. If you touched a generator
in `scripts/`, run `./build.sh` and commit the regenerated `dist/`.

## The rules that are specific to this project

**Only publish what is publicly verifiable.** Every figure on the site has to be reproducible from
this repo. If you cannot point at the script and the data file that produced a number, it does not go
on the page.

**Never show a `0` you could not measure.** Common Crawl is IP rate-limited and its index has
frequent outages. An unmeasured value renders as "not sampled", never as zero. A run where most
resources are unreachable is a broken instrument, not a finding, and `scripts/probe.rb` aborts rather
than writing one.

**Probe politely.** The probes hit other people's servers. Keep them serial, keep the sleeps, keep the
descriptive User-Agent, and keep the per-host cap. Common Crawl's CDX index has no API key: a 503
means slow down, and a block clears after 24h.

**Probe against documentation, not landing pages.** `sorbet.org/docs/overview`, not `sorbet.org`.

**Name the corpus version in any claim about licences.** The Stack v1 excluded unlicensed code and
v2/v3 include it. A claim that does not say which version is not checkable.

**Read a licence before recording it.** `data/license_notes.json` is hand-curated and never written by
a script. GitHub reports `NOASSERTION` for every licence it cannot match, so the metadata cannot tell a
bespoke permissive licence from a source-available one. Open the file; do not infer from the name.

## Architecture

The app follows [layered Rails](https://github.com/palkan/layered-rails): presentation, application,
domain, infrastructure, with dependencies pointing downward only. Practically:

- `app/presenters/` shape results for the screen. They never fetch anything.
- `app/services/analyzer/` runs the probes and orchestrates a run.
- `app/models/` holds domain logic and persistence.
- Controllers do HTTP and nothing else.

Adding a probe means a service plus a presenter, not one object that does both.

## Refreshing the published data

Refreshing re-probes 94 third-party sites, so it is a deliberate act rather than part of a deploy:

```bash
./fetch/run-on-fly.sh    # both probes on one throwaway Fly machine, then rebuilds dist/
```

Re-run quarterly and record the deltas in `CHANGELOG.md` under a **Data** heading.

## Reporting a problem with a measurement

If a number here is wrong about your project, open an issue with the URL or repo and what you expect.
Being wrong in public about someone else's docs is the failure mode this project most wants to avoid,
so these get priority.
