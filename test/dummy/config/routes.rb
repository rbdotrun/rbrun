Rails.application.routes.draw do
  # Kamal / kamal-proxy healthcheck target.
  get "up" => "rails/health#show", as: :rails_health_check

  mount Rbrun::Engine => "/rbrun"

  # Land visitors on the conversation UI.
  root to: redirect("/rbrun")
end
