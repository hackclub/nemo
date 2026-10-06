Rails.application.routes.draw do
  get "up" => "health#show", as: :rails_health_check
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest

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
      get "channels/:channel_id/managers/:user_id", to: "channel_managers#show",
        as: :channel_manager
    end
  end

  get "docs", to: "docs#index", as: :docs
  get "docs/:slug", to: "docs#show", as: :doc

  namespace :settings do
    resource :appearance, only: [:show], controller: "appearances"
    resource :keys, only: [:show], controller: "keys"
    resource :permissions, only: [:show], controller: "permissions"
    resource :consent, only: [:update], controller: "consents"
    resources :apps, only: [:create, :destroy]
    resources :tokens, only: [:create, :destroy] do
      member { post :rotate }
    end
    resources :requests, only: [:index, :create] do
      member do
        post :settle
        delete :withdraw
      end
    end
  end

  get "profile/api", to: redirect("/settings/keys")

  get "cdn/destroy/:key", to: "fd/transcripts#show", as: :destroy_transcript,
      constraints: { key: %r{[^/]+} }, format: false

  get "messages/:channel_id/:ts", to: "messages#show", as: :message_activity,
      constraints: { channel_id: /[CDG][A-Z0-9]+/, ts: /\d+\.\d+/ }, format: false

  get "messages/:channel_id/:ts/files/:file_id", to: "message_files#show", as: :message_file,
      constraints: { channel_id: /[CDG][A-Z0-9]+/, ts: /\d+\.\d+/, file_id: /[A-Z0-9]+/ },
      format: false

  namespace :fd do
    root to: "fire#show"
    post "cases/merge", to: "merges#create", as: :merge_cases
    get "cases/merge", to: "merges#confirm", as: :confirm_merge_cases
    get "cases/:id/merge", to: "merges#show", as: :case_merge
    get "members/search", to: "members#search", as: :member_search
    get "members/pane", to: "members#pane", as: :member_pane
    get "channels/pane", to: "channels#pane", as: :channel_pane
    get "channels/search", to: "channels#search", as: :channel_search
    post "channels/:channel_id/purges", to: "channel_purges#create", as: :channel_purges
    get "channels/:channel_id/purges/:id", to: "channel_purges#show", as: :channel_purge
    post "channels/:channel_id/guards/:kind", to: "channel_guards#create", as: :channel_guard
    patch "channels/:channel_id/guards/:kind", to: "channel_guards#update"
    delete "channels/:channel_id/guards/:kind", to: "channel_guards#destroy"
    post "channels/:channel_id/guards/:kind/allows", to: "channel_allows#create",
         as: :channel_allows
    delete "channels/:channel_id/guards/:kind/allows/:id", to: "channel_allows#destroy",
           as: :channel_allow
    resources :channels, only: [:index, :show], param: :channel_id
    resource :configuration, only: [:show], controller: "configuration"
    resources :automod_words, only: [:create, :destroy], path: "configuration/automod"
    resources :blocked_domains, only: [:create, :destroy], path: "configuration/domains"
    post "configuration/responses/autoresponse", to: "responses#autoresponse",
         as: :configuration_autoresponse
    post "configuration/responses/unsub_shield", to: "responses#unsub_shield",
         as: :configuration_unsub_shield
    resources :new_members, only: [:index, :show]
    resources :bulk_deactivations, only: [:create], path: "new_members/deactivate"
    resources :links, only: [:index], controller: "member_links"
    resources :members, only: [:index, :show] do
      resources :notes, only: [:create, :destroy], controller: "member_notes"
      resources :guards, only: [:create, :update, :destroy], controller: "member_guards"
      resource :standing, only: [:show], controller: "member_standings"
      resource :logins, only: [:show], controller: "member_logins"
      resource :links, only: [:show], controller: "member_link_panes"
    end
    resources :files, only: [:show]
    resource :search, only: [:show], controller: "searches"
    get "audit", to: "audits#show", as: :audit, defaults: { format: "html" }
    get "audit/event", to: "audits#event", as: :audit_event
    get "slack_account/callback", to: "slack_accounts#callback", as: :slack_account_callback
    resource :slack_account, only: [:create, :destroy], controller: "slack_accounts"
    resource :role_permission, only: [:update, :destroy], controller: "role_permissions"
    resource :flag, only: [:update], controller: "flags"
    resources :cases, only: [:index, :show, :create, :update] do
      resource :standing, only: [:show], controller: "standings"
      resource :claim, only: [:create, :destroy]
      resources :assignees, only: [:create, :destroy]
      resource :resolution, only: [:create, :destroy]
      resources :replies, only: [:create]
      resources :chats, only: [:create]
      resource :chat_log, only: [:show]
      resources :notes, only: [:create, :destroy]
      resources :actions, only: [:create]
      resources :reversals, only: [:create]
      resources :participants, only: [:create, :destroy]
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
  get "profile", to: "profile#show", as: :profile
  resource :account, only: [:show], controller: "accounts"
  get "fd/settings", to: redirect("/account")

  namespace :admin do
    root to: "people#index"
    resources :people, only: [:index, :show], param: :user_id do
      collection { get "search" }
    end
    resources :grants, only: [:create, :destroy]
    resource :roles, only: [:show], controller: "roles"
    resource :flags, only: [:show], controller: "flags"
    resource :settings, only: [:show], controller: "settings"
    resource :api, only: [:show], controller: "api_settings"
    patch "api/setting", to: "api_settings#update", as: :api_setting
    patch "api/tokens/:id/rate", to: "api_settings#rate", as: :api_token_rate
    delete "api/tokens/:id", to: "api_settings#destroy", as: :api_token
    post "settings/firehouse", to: "settings#firehouse", as: :settings_firehouse
    post "settings/join_mode", to: "settings#join_mode", as: :settings_join_mode
    post "settings/sweep", to: "settings#sweep", as: :settings_sweep
    post "settings/react_channels", to: "settings#add_react", as: :settings_react_channels
    delete "settings/react_channels/:channel_id", to: "settings#drop_react",
           as: :settings_react_channel
    resources :channels, only: [:index, :update], param: :channel_id do
      collection { get "search", as: :search }
      member { patch "activity" }
    end
    resources :people, only: [], param: :user_id do
      resource :capability, only: [:update, :destroy], controller: "capabilities"
      resources :channel_grants, only: [:create, :destroy], param: :channel_id
    end
    resource :role_channels, only: [:show, :create, :destroy], controller: "role_channels"
  end

  get "engine", to: "engine#index"
  scope "engine", as: :engine, controller: "engine" do
    get "runs/:id", action: :show, as: :run
    post "sync", action: :sync, as: :sync
    post "cancel", action: :cancel, as: :cancel
    post "stages/:stage", action: :trigger_stage, as: :stage
    patch "tune", action: :tune, as: :tune
    delete "tune", action: :untune, as: :untune
    post "incidents/ack", action: :ack_incident, as: :ack_incident
    post "incidents/mute", action: :mute_incident, as: :mute_incident
    post "breakers/override", action: :override_breaker, as: :override_breaker
  end

  get "pipeline", to: redirect("/engine")
  get "pipeline/runs/:id", to: redirect("/engine/runs/%{id}")

  get "workspace-logo", to: "workspace_logo#show", as: :workspace_logo

  get "community", to: "home#index", as: :community
  root "home#index"
end
