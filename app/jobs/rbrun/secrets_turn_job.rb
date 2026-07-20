module Rbrun
  # Resume a turn after the user submitted the request_secrets form. Off-request like the other gate
  # jobs; the nudge is the app's keys-only sentence, never a user message and never a value.
  class SecretsTurnJob < ApplicationJob
    def perform(session_id, nudge) = Rbrun::Session.find(session_id).continue_turn!(nudge)
  end
end
