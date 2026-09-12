# Pin npm packages by running ./bin/importmap

pin "application"
pin "turbo_actions"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin_all_from "app/javascript/charts", under: "charts", preload: false
pin "d3-scale", preload: false # @4.0.2
pin "d3-shape", preload: false # @3.2.0
pin "d3-array", preload: false # @3.2.4
pin "d3-color", preload: false # @3.1.0
pin "d3-format", preload: false # @3.1.2
pin "d3-interpolate", preload: false # @3.0.1
pin "d3-path", preload: false # @3.1.0
pin "d3-time", preload: false # @3.1.0
pin "d3-time-format", preload: false # @4.1.0
pin "internmap", preload: false # @2.0.3
