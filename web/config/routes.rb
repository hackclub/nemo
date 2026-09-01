Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  get "login", to: "sessions#new", as: :login
  match "auth/:provider/callback", to: "sessions#create", via: [:get, :post], as: :auth_callback
  get "auth/failure", to: "sessions#failure", as: :auth_failure
  delete "logout", to: "sessions#destroy", as: :logout

  if Rails.env.development?
    get "dev/be/:user_id", to: "dev_sessions#create", as: :dev_be
  end

  namespace :fd do
    root to: "fire#show"
    post "cases/merge", to: "merges#create", as: :merge_cases
    get "cases/merge", to: "merges#confirm", as: :confirm_merge_cases
    get "cases/:id/merge", to: "merges#show", as: :case_merge
    get "members/search", to: "members#search", as: :member_search
    resources :members, only: [:index, :show] do
      resources :notes, only: [:create, :destroy], controller: "member_notes"
    end
    resource :search, only: [:show], controller: "searches"
    resource :settings, only: [:show]
    get "audit", to: "audits#show", as: :audit
    get "slack_account/callback", to: "slack_accounts#callback", as: :slack_account_callback
    resource :slack_account, only: [:create, :destroy], controller: "slack_accounts"
    resource :role_permission, only: [:update], controller: "role_permissions"
    resource :flag, only: [:update], controller: "flags"
    resources :grants, only: [:create, :destroy]
    resources :decisions, only: [:index, :show, :create, :update, :destroy] do
      resources :threads, only: [:create, :destroy], controller: "decision_threads"
      resource :settlement, only: [:create]
      resource :supersession, only: [:create]
      resource :retirement, only: [:create]
    end
    resources :cases, only: [:index, :show, :create, :update] do
      resource :claim, only: [:create, :destroy]
      resource :resolution, only: [:create, :destroy]
      resources :replies, only: [:create]
      resources :chats, only: [:create]
      resource :chat_log, only: [:show]
      resources :notes, only: [:create, :destroy]
      resources :actions, only: [:create]
      resources :reversals, only: [:create]
      resources :threads, only: [:create, :destroy]
      resources :participants, only: [:create, :destroy]
      resources :citations, only: [:create, :destroy]
      resource :decision, only: [:create, :destroy], controller: "case_decisions"
    end
  end

  ApplicationHelper::JOURNEY.each do |_label, stage|
    get "journey/#{stage}", to: "journey##{ApplicationHelper::ACTIONS.fetch(stage)}",
      as: :"#{stage}_journey"
  end

  ApplicationHelper::MOVED.each do |was, now|
    get was, to: redirect("/journey/#{now}")
  end

  resources :channels, only: [:index, :show] do
    member do
      post "replies", to: "channels#opt_in_replies", as: :opt_in
      delete "replies", to: "channels#opt_out_replies", as: :opt_out
    end
  end
  get "engine", to: "engine#index"
  scope "engine", as: :engine, controller: "engine" do
    get "runs/:id", action: :show, as: :run
    post "sync", action: :sync, as: :sync
    post "cancel", action: :cancel, as: :cancel
    post "stages/:stage", action: :trigger_stage, as: :stage
    patch "tune", action: :tune, as: :tune
    delete "tune", action: :untune, as: :untune
  end

  get "pipeline", to: redirect("/engine")
  get "pipeline/runs/:id", to: redirect("/engine/runs/%{id}")

  root "home#index"
end
