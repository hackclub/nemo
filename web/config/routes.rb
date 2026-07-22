Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  get "login", to: "sessions#new", as: :login
  match "auth/:provider/callback", to: "sessions#create", via: [:get, :post], as: :auth_callback
  get "auth/failure", to: "sessions#failure", as: :auth_failure
  delete "logout", to: "sessions#destroy", as: :logout

  namespace :fire_engine do
    root to: "home#index"
    resources :members, only: [:show] do
      resources :notes, only: [:create]
    end
    resources :cases, only: [:index, :show] do
      resources :case_actions, only: [:create]
    end
    resources :reports, only: [:index, :new, :create, :edit, :update]
  end

  resources :channels, only: [:index, :show]

  root "home#index"
end
