# Pin npm packages by running ./bin/importmap

pin "application"
pin "turbo_actions"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin "chart.js"
pin "@kurkle/color", to: "@kurkle--color.js"
