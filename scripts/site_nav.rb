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
# The brand is the home link, which is why "/" is not repeated in LINKS.
SITE_NAV_LINKS = [
  [ "/learn", "Learn" ],
  [ "/test",  "Test a page" ]
].freeze

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
  @media print { .site-nav { display: none; } }
CSS

# `current` is the path of the page being generated, so it can mark itself.
def site_nav(current: nil)
  links = SITE_NAV_LINKS.map do |href, label|
    %(<a href="#{href}"#{' aria-current="page"' if href == current}>#{label}</a>)
  end.join("\n    ")

  <<~HTML
    <nav class="site-nav" aria-label="Main">
      <a class="site-nav__brand" href="/">Ruby &amp; Rails LLM scorecard</a>
      <div class="site-nav__links">
        #{links}
      </div>
    </nav>
  HTML
end
