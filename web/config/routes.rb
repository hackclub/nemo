Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  get "login", to: "sessions#new", as: :login
  match "auth/:provider/callback", to: "sessions#create", via: [:get, :post], as: :auth_callback
  get "auth/failure", to: "sessions#failure", as: :auth_failure
  delete "logout", to: "sessions#destroy", as: :logout

  if Rails.env.development?
    get "dev/be/:user_id", to: "dev_sessions#create", as: :dev_be
  end

  namespace :api do
    namespace :v1 do
      resource :token, only: [:show], controller: "tokens"
      post "channels/:channel_id/managers/check", to: "channel_managers#check",
        as: :channel_managers_check
      get "channels/:channel_id/managers/:user_id", to: "channel_managers#show",
        as: :channel_manager
    end
  end

  namespace :you do
    get "api", to: "api#show", as: :api
    resource :consent, only: [:update], controller: "consents"
    resources :tokens, only: [:create, :destroy]
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
    patch "api_setting", to: "api_settings#update", as: :api_setting
    patch "api_tokens/:id/rate", to: "api_settings#rate", as: :api_token_rate
    delete "api_tokens/:id", to: "api_settings#destroy", as: :api_token
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

  ApplicationHelper::JOURNEY.each do |_number, _label, stage|
    get stage, to: "journey##{ApplicationHelper::ACTIONS.fetch(stage)}",
      as: :"#{stage}_journey"
  end

  resources :channels, only: [:index, :show]
  get "engine", to: "engine#index"
  get "engine/runs/:id", to: "engine#show", as: :engine_run
  post "engine/sync", to: "engine#sync", as: :engine_sync
  post "engine/cancel", to: "engine#cancel", as: :engine_cancel
  post "engine/trigger_stage", to: "engine#trigger_stage", as: :engine_trigger_stage
  patch "engine/tune", to: "engine#tune", as: :engine_tune
  delete "engine/tune", to: "engine#untune", as: :engine_untune

  get "pipeline", to: redirect("/engine")
  get "pipeline/runs/:id", to: redirect("/engine/runs/%{id}")

  root "home#index"
end
