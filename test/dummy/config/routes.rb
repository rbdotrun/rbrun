Rails.application.routes.draw do
  # Kamal / kamal-proxy healthcheck target.
  get "up" => "rails/health#show", as: :rails_health_check

  # The Turbo Streams WebSocket. Without this every <turbo-cable-stream-source> the engine renders
  # (live skills rows, the streaming conversation) has no endpoint and silently never updates.
  mount ActionCable.server => "/cable"

  mount Rbrun::Engine => "/rbrun"

  # Land visitors on the conversation UI.
  root to: redirect("/rbrun")
end
