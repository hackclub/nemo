Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  get "login", to: "sessions#new", as: :login
  match "auth/:provider/callback", to: "sessions#create", via: [:get, :post], as: :auth_callback
  get "auth/failure", to: "sessions#failure", as: :auth_failure
  delete "logout", to: "sessions#destroy", as: :logout

  namespace :fd do
    root to: "cases#index"
    post "cases/merge", to: "merges#create", as: :merge_cases
    resources :cases, only: [:index, :show] do
      resource :claim, only: [:create, :destroy]
      resource :resolution, only: [:create]
      resources :notes, only: [:create, :destroy]
      resources :actions, only: [:create]
    end
  end

  resources :channels, only: [:index, :show]
  get "pipeline", to: "pipeline#index"
  get "pipeline/runs/:id", to: "pipeline#show", as: :pipeline_run
  post "pipeline/sync", to: "pipeline#sync", as: :pipeline_sync
  post "pipeline/cancel", to: "pipeline#cancel", as: :pipeline_cancel
  post "pipeline/trigger_stage", to: "pipeline#trigger_stage", as: :pipeline_trigger_stage

  root "home#index"
end
