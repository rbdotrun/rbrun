module Rbrun
  # A fresh user turn (carries the user's own words).
  class AgentTurnJob < ApplicationJob
    def perform(session_id, content) = Rbrun::Session.find(session_id).run_turn(content)
  end
end
