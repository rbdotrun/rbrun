module Rbrun
  # ONE row per runtime event — a raw event log (no tool_calls/tool_results tables). `event_type` is
  # the event's type (text/tool_use/tool_result/token/session/…); `payload` its raw JSON. Ingested
  # verbatim; interpretation happens at render time (Phase 7).
  class SessionMessage < ApplicationRecord
    belongs_to :session, class_name: "Rbrun::Session"

    # The user message that opened this row's turn (agent rows point at it; a user lead points at
    # nothing). Self-referential, same-table — can never cross tenants because it never crosses sessions.
    belongs_to :user_message, class_name: "Rbrun::SessionMessage", optional: true
    has_many :turn_replies, class_name: "Rbrun::SessionMessage", foreign_key: :user_message_id,
                            inverse_of: :user_message, dependent: :nullify

    # A GATED tool call: nil on ordinary rows; present means this tool_use reached a needs_approval
    # gate (which ended the run — nothing executed), and payload name/input are the frozen action.
    enum :approval_status,
         { pending: "pending", approved: "approved", rejected: "rejected", cancelled: "cancelled" },
         prefix: :approval, validate: { allow_nil: true }

    scope :gated, -> { where.not(approval_status: nil) }

    def tool_use?    = event_type == "tool_use"
    def tool_result? = event_type == "tool_result"
  end
end
