module Rbrun
  # A user-filed "this response was wrong" report against one turn (its lead user message). The
  # conversation footer's "Report an error" action creates it; one per turn.
  class TurnReport < ApplicationRecord
    include Rbrun::Tenanted

    belongs_to :session, class_name: "Rbrun::Session"
    belongs_to :user_message, class_name: "Rbrun::SessionMessage"

    # The reported turn's agent messages (the rows that threaded to its lead) — the easy handle to what
    # the agent actually did that turn.
    def turn_messages = user_message.turn_replies
  end
end
