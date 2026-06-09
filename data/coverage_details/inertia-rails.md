# Inertia Rails — Common Crawl coverage

Docs: https://inertia-rails.dev/guide/ · scope `inertia-rails.dev` · Common Crawl index `CC-MAIN-2026-21`

Of **56** documentation pages found by crawling the live site, **18**
are present in Common Crawl (**32%**) and **38** are not.
(1 URLs are in Common Crawl but were not reached by the crawl,
e.g. redirects, old paths, or orphan pages.)

## In Common Crawl (18)
- https://inertia-rails.dev/
- https://inertia-rails.dev/cookbook/handling-validation-error-types
- https://inertia-rails.dev/guide
- https://inertia-rails.dev/guide/authentication
- https://inertia-rails.dev/guide/cached-props
- https://inertia-rails.dev/guide/caching
- https://inertia-rails.dev/guide/client-side-setup
- https://inertia-rails.dev/guide/csrf-protection
- https://inertia-rails.dev/guide/deferred-props
- https://inertia-rails.dev/guide/history-encryption
- https://inertia-rails.dev/guide/infinite-scroll
- https://inertia-rails.dev/guide/manual-visits
- https://inertia-rails.dev/guide/pages
- https://inertia-rails.dev/guide/partial-reloads
- https://inertia-rails.dev/guide/remembering-state
- https://inertia-rails.dev/guide/testing
- https://inertia-rails.dev/guide/title-and-meta
- https://inertia-rails.dev/guide/view-transitions

## NOT in Common Crawl (38)
- https://inertia-rails.dev/awesome
- https://inertia-rails.dev/cookbook/inertia-modal
- https://inertia-rails.dev/cookbook/integrating-shadcn-ui
- https://inertia-rails.dev/cookbook/server-managed-meta-tags
- https://inertia-rails.dev/guide/asset-versioning
- https://inertia-rails.dev/guide/authorization
- https://inertia-rails.dev/guide/code-splitting
- https://inertia-rails.dev/guide/configuration
- https://inertia-rails.dev/guide/error-handling
- https://inertia-rails.dev/guide/events
- https://inertia-rails.dev/guide/file-uploads
- https://inertia-rails.dev/guide/flash-data
- https://inertia-rails.dev/guide/forms
- https://inertia-rails.dev/guide/how-it-works
- https://inertia-rails.dev/guide/http-requests
- https://inertia-rails.dev/guide/instant-visits
- https://inertia-rails.dev/guide/layouts
- https://inertia-rails.dev/guide/links
- https://inertia-rails.dev/guide/load-when-visible
- https://inertia-rails.dev/guide/merging-props
- https://inertia-rails.dev/guide/once-props
- https://inertia-rails.dev/guide/optimistic-updates
- https://inertia-rails.dev/guide/polling
- https://inertia-rails.dev/guide/prefetching
- https://inertia-rails.dev/guide/progress-indicators
- https://inertia-rails.dev/guide/redirects
- https://inertia-rails.dev/guide/responses
- https://inertia-rails.dev/guide/routing
- https://inertia-rails.dev/guide/scroll-management
- https://inertia-rails.dev/guide/server-side-rendering
- https://inertia-rails.dev/guide/server-side-setup
- https://inertia-rails.dev/guide/shared-data
- https://inertia-rails.dev/guide/starter-kits
- https://inertia-rails.dev/guide/the-protocol
- https://inertia-rails.dev/guide/typescript
- https://inertia-rails.dev/guide/upgrade-guide
- https://inertia-rails.dev/guide/validation
- https://inertia-rails.dev/guide/who-is-it-for
## Why the gap, and what to do

**Cause: recently-added pages + no sitemap.** Every "found" URL is still live, so nothing is stale,
the missing pages are simply newer than Common Crawl's last pass. The found pages have been stable
since 2024 (e.g. `guide/authentication`, last changed 2024-10-30), while the missing ones come from
the recent docs expansion (`guide/routing` 2025-11, `guide/optimistic-updates` 2026-03,
`guide/forms` 2026-04). With no `sitemap.xml`, CC has no manifest of the new pages and its crawl
frontier predates them. The site also sits behind Cloudflare (content-signals `robots.txt`), which
can throttle CCBot.

**TODO**
- [ ] Publish a `sitemap.xml` (VitePress: set `sitemap: { hostname }`) so CC/search see every current page.
- [ ] Confirm Cloudflare isn't challenging `CCBot`/`GPTBot`/`ClaudeBot` (bot-fight / AI-bot blocking off for docs).
- [ ] Add internal links + a few external backlinks to the newer guide/cookbook pages to raise crawl priority.
- [ ] Re-check coverage after the next monthly Common Crawl.

