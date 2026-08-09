Rails.application.routes.draw do
  # --- the existing static site (generated into dist/, copied to public/ by build.sh) ---
  root "pages#show", defaults: { page: "scorecard" }
  # Rendered by Rails, not generated: /test links into its anchors from every result.
  get "/learn",                to: "pages#learn", as: :learn
  # /guide and /learn were two pages restating the same research, cross-linking each other five
  # times. They are now one page at /learn, which is the URL every result on /test deep-links into.
  # The old URL is in the wild, so it redirects rather than 404s.
  get "/guide", to: redirect("/learn", status: 301)
  get "/check",                to: "pages#show", defaults: { page: "check" }
  get "/contributors",         to: "pages#show", defaults: { page: "contributors" }
  get "/quality-rewrites",     to: "pages#show", defaults: { page: "quality-rewrites" }
  get "/blog-rewrites-review", to: "pages#show", defaults: { page: "blog-rewrites-review" }

  # Links to /scorecard.html are already in the wild; keep them alive rather than 404.
  get "/scorecard.html", to: redirect("/", status: 301)

  # --- /test : the live analyzer ---
  get "/test", to: "analyses#new", as: :test
  resources :analyses, only: %i[create show]

  # --- auth (GitHub only; identity exists purely to meter per-user spend) ---
  get    "/auth/github/callback", to: "sessions#create"
  get    "/auth/failure",         to: "sessions#failure"
  delete "/sign_out",             to: "sessions#destroy", as: :sign_out

  get "up" => "rails/health#show", as: :rails_health_check
end
