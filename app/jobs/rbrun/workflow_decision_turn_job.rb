module Rbrun
  # Resume a turn after the user decided a workflow_create gate. Off-request like the other gate jobs;
  # the nudge is the app's sentence, never a user message.
  class WorkflowDecisionTurnJob < ApplicationJob
    def perform(session_id, nudge) = Rbrun::Session.find(session_id).continue_turn!(nudge)
  end
end
