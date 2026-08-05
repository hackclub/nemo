Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  get "login", to: "sessions#new", as: :login
  match "auth/:provider/callback", to: "sessions#create", via: [:get, :post], as: :auth_callback
  get "auth/failure", to: "sessions#failure", as: :auth_failure
  delete "logout", to: "sessions#destroy", as: :logout

  resources :channels, only: [:index, :show]
  get "pipeline", to: "pipeline#index"
  post "pipeline/sync", to: "pipeline#sync", as: :pipeline_sync
  post "pipeline/cancel", to: "pipeline#cancel", as: :pipeline_cancel

  root "home#index"
end
