module Rbrun
  # Resume a failed/retried turn (carries nothing — the request is already in the SDK session).
  class ResumeTurnJob < ApplicationJob
    def perform(session_id) = Rbrun::Session.find(session_id).resume_turn!
  end
end
