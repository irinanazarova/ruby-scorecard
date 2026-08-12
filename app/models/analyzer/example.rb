# frozen_string_literal: true

module Analyzer
  # The demo pairs on the form: a real docs site next to the real repo its team would name.
  #
  # Curated data, not configuration. It never came from an env var and never should; putting it in
  # AnalyzerConfig meant a typed-settings object was also the place you edited prose. Warmed by
  # `bin/rails analyzer:warm` before a demo, so the on-stage run replays from cache instead of
  # waiting on Common Crawl's cold index. Run the SAME links live.
  #
  # Both fields are filled in, which is the point of the pair: the demo should never show the tool
  # guessing which repo belongs to a docs site.
  #
  # Content pages, not hub pages. A docs landing page is mostly links: workos.com/docs/authkit
  # yields 39 words even via its markdown twin, so the probe correctly refuses to test it. Pick
  # pages with real prose or the demo's best moment never runs.
  #
  # The notes are no longer rendered on /test: the list is a demo control surface and the room reads
  # the results off the run, not off the form. They stay here as the record of what each pair
  # actually produced, and a test keeps them present.
  #
  # Every note states a measured result that RE-MEASURES THE SAME. That rules out claims about
  # recall on a live page, which is the one thing here that does not reproduce. Measured on the same
  # passages, byte for byte, from a laptop and from the Fly machine an hour apart,
  # tailwindcss.com/docs/hover-focus-and-other-states scored a 54-word verbatim run on GPT-5.5 and
  # then a 3-word one. The pinned reference passages and the MIT control did not move (30 vs 28,
  # 31 vs 28), so this is not the probe drifting: strongly memorized text reproduces consistently and
  # borderline text is a coin flip, which is exactly what the "a short run is weak evidence" caveat
  # says. A note promising the room that two labs reproduce this page word for word is therefore a
  # note that will be wrong on stage roughly half the time.
  #
  # For a demonstration of recall that fires every time, use the paragraph field with text that is
  # duplicated across many repos.
  #
  # Ordered so the flat outcome comes first and the surprises come last.
  class Example
    ALL = [
      { docs: "https://docs.anycable.io/anycable-go/reliable_streams",
        repo: "anycable/docs.anycable.io",
        label: "AnyCable docs",
        note: "Our own docs, included so this is not only other people's bad news. Same outcome: " \
              "eligible, uncrawled, unmemorized." },

      # Software Heritage as the gate people forget: the licence is fine and the repo is popular, and
      # none of that matters because the archive never collected it.
      { docs: "https://resend.com/docs/send-with-nodejs",
        repo: "resend/resend-node",
        label: "Resend",
        note: "MIT with 941 stars, and Software Heritage has still never archived it. A licence on " \
              "an uncollected repo buys nothing." },

      # The two gates disagreeing about the same repo, which is the sharpest thing on the page: no
      # LICENSE file at all means The Stack keeps it and nobody may use it.
      { docs: "https://tailwindcss.com/docs/hover-focus-and-other-states",
        repo: "tailwindlabs/tailwindcss.com",
        label: "Tailwind CSS",
        note: "No LICENSE file and 140 stars. The Stack v2/v3 keep it anyway, while default copyright " \
              "means nobody may use it. Scores below the quality bar, so the web channel drops the " \
              "page and the code channel does not." }
    ].freeze

    # The three that demonstrate the CODE path carrying text into a model, which is the claim the
    # whole project rests on and the one the four pairs below never actually show. These LEAD the
    # list on /test: the others show gates closing, which is the commoner outcome and the weaker
    # thing to open on.
    #
    # `file` pins which source file gets probed. Without it the run asks "what is the largest
    # hand-written file in this repo", which is a guess at the project's signature code and moves as
    # the repo does. These three were measured, so the demo should not re-roll them.
    #
    # Why these are clean in a way no web-path example was. The probed text is source code: it is
    # rendered on no documentation page, so Common Crawl has no copy to have carried, and the code
    # route is not inferred from the licence but OBSERVED in the Am-I-in-The-Stack index. Every
    # docs page we found that fires (PostgreSQL MVCC, Python argparse, MDN) turned out to have 60-70%
    # of the same prose sitting in a public repo, so nothing about them can be attributed to the web;
    # and the developer content that is crawled with no public source (DigitalOcean, Heroku, Vercel,
    # Twilio) does not fire at all.
    # Rails first: it is the steadiest of the three, and this is a Ruby audience.
    CODE_PATH = [
      { docs: "https://guides.rubyonrails.org/active_support_core_extensions.html",
        repo: "rails/rails",
        file: "activesupport/lib/active_support/core_ext/object/blank.rb",
        label: "Rails",
        note: "Every model continued blank.rb on both measurements, which the guides page beside it " \
              "manages on none. Source code reaches models; the rendered docs do not." },

      { docs: "https://expressjs.com/en/guide/routing.html",
        repo: "expressjs/express",
        file: "lib/response.js",
        label: "Express",
        note: "69k stars, MIT, archived, and observed in The Stack v3. The probe reads its source " \
              "rather than its docs: Claude and GPT-5.5 each continued it for 50+ words on two " \
              "separate measurements." },

      # The two channels splitting inside ONE product, which is the cleanest version of the argument
      # available: Stripe's docs are not in any public repo and its SDKs are.
      { docs: "https://docs.stripe.com/payments/payment-intents",
        repo: "stripe/stripe-ruby",
        file: "lib/stripe/stripe_client.rb",
        label: "Stripe",
        note: "Closed docs, open SDK. Three prose-rich docs pages give two or three words on every " \
              "model; the Ruby client's own source clears the recall bar. Same product, and only " \
              "one channel delivers." }
    ].freeze

    def self.all = CODE_PATH + ALL

    # The source file to probe for a repo we have already measured, or nil to let the run pick.
    def self.pinned_file(repo)
      key = repo.to_s.chomp("/")
      CODE_PATH.find { |e| e[:repo] == key }&.dig(:file)
    end

    # Clicking a listed example must never cost a visitor an allowance slot or trip the per-IP
    # limit, however cold the cache happens to be. Compared ignoring a trailing slash, since that is
    # the one difference a hand-typed URL reliably picks up.
    def self.match?(docs_url, repo)
      d = docs_url.to_s.strip.chomp("/")
      r = repo.to_s.strip.chomp("/")
      all.any? { |e| e[:docs].to_s.chomp("/") == d && e[:repo].to_s.chomp("/") == r }
    end
  end
end
