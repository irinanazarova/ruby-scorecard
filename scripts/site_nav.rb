# frozen_string_literal: true

# One navigation bar for every generated page.
#
# The site grew a page at a time, so each generator built its own top of page: the scorecard put a
# kicker and a theme toggle inside a dark hero, and /check opened straight into a <main>. Nothing
# linked to anything else, so a reader who landed on /check had no way to reach /test or /learn
# except by editing the URL.
#
# This is deliberately the SAME markup the Rails layout renders for /test and /learn, so the bar
# does not shift or restyle as a visitor crosses between the generated pages and the app. Keep the
# two in step: app/views/layouts/application.html.erb carries the other copy.
#
# Analytics, on every generated page.
#
# Goes in the <head> of each generator's template rather than into the pages themselves, so a page
# added later gets it by writing one interpolation instead of by remembering. The Rails layout
# carries the same snippet for /test, /learn and the results pages; keep the two in step.
#
# Both tags are needed and the order matters: the async loader may arrive at any time, so the queue
# shim below has to exist before anything calls plausible(). The shim is what makes a call made
# while the script is still in flight replay rather than throw.
#
# No cookies and no personal data, which is the whole reason for choosing this one. It is also why
# there is no consent banner to go with it: there is nothing here to consent to.
SITE_ANALYTICS = <<~HTML
  <!-- Privacy-friendly analytics by Plausible -->
  <script async src="https://plausible.io/js/pa-E8DFByDC1ezF67slDapJk.js"></script>
  <script>
    window.plausible=window.plausible||function(){(plausible.q=plausible.q||[]).push(arguments)},plausible.init=plausible.init||function(i){plausible.o=i||{}};
    plausible.init()
  </script>
HTML

# The brand is the home link, which is why "/" is not repeated in LINKS.
SITE_NAV_LINKS = [
  [ "/learn", "Learn" ],
  [ "/test",  "Test a page" ]
].freeze

# The GitHub mark (Octicons, MIT), drawn in currentColor so it follows the nav's palette.
# app/views/layouts/application.html.erb carries the same icon; keep the two in step.
SITE_NAV_GH = <<~HTML.strip
  <a class="nav-gh" href="https://github.com/irinanazarova/ruby-scorecard" aria-label="Source on GitHub" title="Source on GitHub"><svg viewBox="0 0 16 16" width="18" height="18" fill="currentColor" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8z"/></svg></a>
HTML

# The guide and the two rewrite showcases ship their own stylesheet rather than the design system,
# so the bar has to be styled locally on those pages. Same shape, expressed without the tokens they
# do not load. `color: inherit` keeps it readable whatever palette the host page sets.
SITE_NAV_CSS = <<~CSS
  .site-nav { display: flex; align-items: center; justify-content: space-between; gap: 1rem;
    flex-wrap: wrap; max-width: 60rem; margin: 0 auto; padding: 1.1rem 1.5rem; font-size: .9rem;
    font-family: "Inter", -apple-system, "Segoe UI", Arial, sans-serif;
    border-bottom: 1px solid rgba(128, 110, 120, .25); }
  .site-nav__brand { font-weight: 700; color: inherit; text-decoration: none; }
  .site-nav__links { display: flex; align-items: center; gap: 1rem; }
  .site-nav__links a[aria-current] { font-weight: 700; }
  .nav-gh { display: inline-flex; align-items: center; color: inherit; }
  @media print { .site-nav { display: none; } }
CSS

# `current` is the path of the page being generated, so it can mark itself.
# `toggle` adds the theme switcher; pass it only from pages that load the nanotags bundle
# (scorecard, contributors), because on any other page the button would render and do nothing.
# The Rails layout carries the same toggle in its own bar, so the control sits in the nav on
# every themed page instead of inside one page's hero.
def site_nav(current: nil, toggle: false)
  links = SITE_NAV_LINKS.map do |href, label|
    %(<a href="#{href}"#{' aria-current="page"' if href == current}>#{label}</a>)
  end.join("\n    ")
  switch = toggle ? <<~T.strip : ""
    <theme-toggle>
          <button type="button" data-ref="button" class="theme-toggle" aria-label="Colour theme: following your device. Click for light.">
            <span class="theme-toggle__dot"></span><span class="theme-toggle__label">Auto</span>
          </button>
        </theme-toggle>
  T

  <<~HTML
    <nav class="site-nav" aria-label="Main">
      <a class="site-nav__brand" href="/">Ruby &amp; Rails LLM scorecard</a>
      <div class="site-nav__links">
        #{links}
        #{SITE_NAV_GH}
        #{switch}
      </div>
    </nav>
  HTML
end
