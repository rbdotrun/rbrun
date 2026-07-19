module Rbrun
  # Resume after an approval decision (carries the app's nudge sentence — never a user message).
  class ApprovalTurnJob < ApplicationJob
    def perform(session_id, nudge) = Rbrun::Session.find(session_id).continue_turn!(nudge)
  end
end
