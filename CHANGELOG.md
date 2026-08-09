# Changelog

Notable changes to the scorecard and the `/test` analyzer. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Two kinds of entry appear here, and they mean different things:

- **Code** changes the tool.
- **Data** changes the published numbers. Every data entry names what was re-measured and when, so a
  figure quoted from this site can be traced to the run that produced it.

## [Unreleased]

### Changed

- **Settings env vars are now prefixed.** `FREE_ANALYSES_PER_SESSION` became
  `ANALYZER_FREE_ANALYSES_PER_SESSION`, and the same for `BUDGET_CENTS_PER_USER`,
  `RATE_LIMIT_IP_COUNT`, `RATE_LIMIT_IP_DAILY`, `MAX_MODEL_CALLS_PER_ANALYSIS`,
  `MEMORIZATION_DEADLINE` and `QUALITY_API`. They are typed through
  [anyway_config](https://github.com/palkan/anyway_config) and can now come from an env var,
  `config/analyzer.yml` or credentials. Safe to change because nothing set them: production runs on
  the defaults, and every default is unchanged. **If you set any of these locally, add the
  `ANALYZER_` prefix.**
- Code is organised in [layered Rails](https://github.com/palkan/layered-rails) directories:
  `app/presenters` (read a finished run and decide what it says), `app/policies` (who may do what),
  `app/services` (measure and orchestrate), `app/infrastructure` (HTTP, cache, API keys),
  `app/configs`. No behaviour changed and no public constant was renamed.

### Added

- MIT licence, contribution guide, code of conduct and this changelog.
- CI running RuboCop, Brakeman, the test suite, and a check that `dist/` still regenerates
  unchanged from `data/` and `src/`.
- RuboCop wired to `rubocop-rails-omakase`, which the project had carried as a dependency without a
  config since the beginning.

## 2026-08-09

### Added

- **Code:** paste a paragraph and check model recall on it directly, with no site or repo.
- **Data:** The Stack v3 membership is now reported as **observed**, queried from the official
  "Am I in The Stack?" index, rather than inferred from a licence. The per-file decisions surprise in
  both directions, so the observed answer overrides the licence reading.

### Changed

- `/guide` and `/learn` were two pages restating the same research and cross-linking each other.
  They are now one page at `/learn`; `/guide` redirects there permanently. The page leads with a
  checklist, carries four diagrams, and keeps every measurement one click from the claim it supports.

### Fixed

- **Data:** restored the 92-resource quality sample that a single-page run had overwritten.

## 2026-08-08

### Changed

- `/test` became a click-through deck with separate **docs URL** and **repo** fields. The repo behind
  a docs URL used to be inferred, and the last resort was "the most-starred repo in the org", which is
  a guess and the wrong thing to base a licence verdict on.

## 2026-08-07

### Added

- `/learn`, and ranked next steps on every result rather than bare findings.
- The indicator probe now runs on Fly alongside the Common Crawl coverage probe, so a refresh does not
  depend on a laptop's network.

### Fixed

- The probe refuses to write a run in which more than 15% of resources were unreachable, and retries
  once before calling a host dead. Three separate local runs had produced datasets that would have
  published "dozens of projects deleted their sitemap" as a finding.

## 2026-08-05 and earlier

### Fixed

- Every GitHub call is authenticated, not just the code channel. Fly's shared egress IP hit the
  60 requests/hour unauthenticated limit, which surfaced as "repo not found" for public repos.
- Fully cached runs are recorded as cached, so re-running a link stays free.
- A 9-word continuation is reported as a hint rather than as strong evidence.
