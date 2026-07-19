Rbrun::Engine.routes.draw do
  get    "login",  to: "auth/sessions#new",     as: :login
  post   "login",  to: "auth/sessions#create"
  delete "logout", to: "auth/sessions#destroy", as: :logout

  resources :sessions, path: "c", only: %i[index create show]
  post "c/:id",       to: "messages#create", as: :session_message
  post "c/:id/retry", to: "sessions#retry",  as: :session_retry
  resources :approvals, only: :update, param: :tool_use_id

  # Repo workspace switcher: the searchable result frame + the switch action.
  get  "repos",        to: "repositories#index",  as: :repos
  post "repos/switch", to: "repositories#switch", as: :switch_repo

  # Skills panel: list + reconcile a divergence (keep|reload).
  get  "skills",                 to: "skills#index",     as: :skills
  post "skills/:slug/reconcile", to: "skills#reconcile", as: :reconcile_skill

  root to: "sessions#index"
end
