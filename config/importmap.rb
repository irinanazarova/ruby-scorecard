# Pin npm packages by running ./bin/importmap

pin "application"
# Local module: without this pin the browser cannot resolve `import cable from "cable"`, and the
# resulting TypeError aborts the whole application.js module — taking Turbo down with it, so the
# page silently loses every stream AND all Turbo navigation.
pin "cable"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin "@anycable/turbo-stream", to: "@anycable--turbo-stream.js" # @0.8.1
pin "@anycable/web", to: "@anycable--web.js" # @1.1.1
pin "@anycable/core", to: "@anycable--core.js" # @1.1.6
pin "@hotwired/turbo", to: "@hotwired--turbo.js" # @8.0.23
pin "nanoevents" # @9.1.0
