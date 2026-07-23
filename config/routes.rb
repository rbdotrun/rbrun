Rbrun::Engine.routes.draw do
  get    "login",  to: "auth/sessions#new",     as: :login
  post   "login",  to: "auth/sessions#create"
  delete "logout", to: "auth/sessions#destroy", as: :logout

  resources :sessions, path: "c", only: %i[index create show]
  post "c/:id",       to: "messages#create", as: :session_message
  post "c/:id/retry", to: "sessions#retry",  as: :session_retry
  # Per-turn "report an error": the footer link opens the dialog (new), the form files it (create).
  get  "c/:id/report/:message_id", to: "reports#new",    as: :new_report
  post "c/:id/report/:message_id", to: "reports#create", as: :report
  resources :approvals, only: :update, param: :tool_use_id
  # Custom gate: ask_user submits its picks here (a custom_approval! tool → its own submit route).
  post "ask_user/:tool_use_id", to: "ask_user_responses#create", as: :ask_user_response
  # Custom gate: workflow_create submits its Apply/Save/Cancel decision here.
  post "workflow_decision/:tool_use_id", to: "workflow_decisions#create", as: :workflow_decision
  # Custom gate: request_secrets submits the secure form here (values → encrypted store, never the LLM).
  post "secrets/:tool_use_id", to: "secrets#create", as: :secrets_submission

  # Repo workspace switcher: the searchable result frame + the switch action.
  get  "repos",        to: "repositories#index",  as: :repos
  post "repos/switch", to: "repositories#switch", as: :switch_repo

  # Skills panel: list + reconcile a divergence (keep|reload). `new` opens a create-skill
  # conversation in the app-wide drawer.
  get  "skills",                 to: "skills#index",     as: :skills
  post "skills/new",             to: "skills#build",     as: :build_skill
  post "skills/:slug/reconcile", to: "skills#reconcile", as: :reconcile_skill

  root to: "sessions#index"
end
