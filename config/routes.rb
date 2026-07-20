Rbrun::Engine.routes.draw do
  # THE ONLY UNAUTHENTICATED ROUTE — the public edge (exposure ladder level 3). It proxies to exactly one
  # shared ServiceRun; a service without a PublicShare has no route here and cannot surface.
  match "p/:token(/*path)", to: "public_previews#show", via: :all, as: :public_preview

  get    "login",  to: "auth/sessions#new",     as: :login
  post   "login",  to: "auth/sessions#create"
  delete "logout", to: "auth/sessions#destroy", as: :logout

  resources :sessions, path: "c", only: %i[index create show]
  post "c/:id",       to: "messages#create", as: :session_message
  post "c/:id/retry", to: "sessions#retry",  as: :session_retry
  resources :approvals, only: :update, param: :tool_use_id
  # Custom gate: ask_user submits its picks here (a custom_approval! tool → its own submit route).
  post "ask_user/:tool_use_id", to: "ask_user_responses#create", as: :ask_user_response
  # Custom gate: workflow_create submits its Apply/Save/Cancel decision here.
  post "workflow_decision/:tool_use_id", to: "workflow_decisions#create", as: :workflow_decision
  # Custom gate: request_secrets submits the secure form here (values → encrypted store, never the LLM).
  post "secrets/:tool_use_id", to: "secrets#create", as: :secrets_submission

  # Repo services: operate the worktree's running services from the sidebar panel.
  resources :services, only: [] do
    member do
      get  :open   # 302 → the live app (new tab)
      get  :logs   # open the logs drawer
      post :restart
      post :stop
      post :preview      # expose this service for preview (separate from running it)
      post :stop_preview # withdraw the preview; the service keeps running
      post :share_public # level 3: anyone with the link (requires previewed)
      post :stop_sharing # revoke the public link
    end
  end
  post "services/restart_all", to: "services#restart_all", as: :restart_all_services

  # Repo workspace switcher: the searchable result frame + the switch action.
  get  "repos",        to: "repositories#index",  as: :repos
  post "repos/switch", to: "repositories#switch", as: :switch_repo

  # Skills panel: list + reconcile a divergence (keep|reload).
  get  "skills",                 to: "skills#index",     as: :skills
  post "skills/:slug/reconcile", to: "skills#reconcile", as: :reconcile_skill

  root to: "sessions#index"
end
