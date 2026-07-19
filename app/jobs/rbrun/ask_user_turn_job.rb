module Rbrun
  # Resume a turn after the user answered an ask_user gate. Off-request like ApprovalTurnJob — the
  # nudge is the app's sentence (the picks), never a user message.
  class AskUserTurnJob < ApplicationJob
    def perform(session_id, nudge) = Rbrun::Session.find(session_id).continue_turn!(nudge)
  end
end
