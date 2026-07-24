module Rbrun
  # ONE row per runtime event — a raw event log. `event_type` is the event's type; `payload` its raw
  # JSON. Ingested verbatim; the timeline interprets rows at render time.
  class SessionMessage < ApplicationRecord
    belongs_to :session, class_name: "Rbrun::Session"

    belongs_to :user_message, class_name: "Rbrun::SessionMessage", optional: true
    has_many :turn_replies, class_name: "Rbrun::SessionMessage", foreign_key: :user_message_id,
                            inverse_of: :user_message, dependent: :nullify

    before_create :assign_turn

    enum :approval_status,
         { pending: "pending", approved: "approved", rejected: "rejected", cancelled: "cancelled",
           answered: "answered" }, # answered = a custom gate (ask_user) was submitted (not approve/reject)
         prefix: :approval, validate: { allow_nil: true }

    scope :gated, -> { where.not(approval_status: nil) }

    # Rows the human sees. Text turns + tool events render; token/session frames are ingested silently.
    RENDERED_EVENTS  = %w[text tool_use tool_result internal].freeze
    BROADCAST_EVENTS = %w[text tool_use tool_result internal].freeze

    after_create_commit :broadcast_open_or_event, if: :broadcastable?
    after_update_commit :broadcast_finalized_event, if: :finalized?

    def tool_use?    = event_type == "tool_use"
    def tool_result? = event_type == "tool_result"

    def visible? = event_type.in?(RENDERED_EVENTS) || (event_type.nil? && role.in?(%w[user assistant]))

    # The ONLY decisions a human can render on a frozen call. The vocabulary lives here so the endpoint
    # can't drift from it.
    APPROVAL_DECISIONS = %w[approve refuse].freeze

    # The DATA a tool returned, for this frozen call. Every tool answers with the envelope
    # { "data" => {…} } (or { "error" => … }), stored verbatim under the result row's payload["result"].
    #
    # This is the ONE place that knows that shape. Reading payload["result"]["x"] by hand silently
    # misses by a level and returns nil forever — which is exactly what happened on the validate_step
    # card: `result["step"]` was ALWAYS nil, so its fallback ran on every render and showed the title of
    # the NEXT, not-yet-done step as the one just validated (and an empty title on the last step).
    # Returns {} while the call is still pending, so callers can read keys safely.
    def tool_result_data
      row = event_type == "tool_result" ? self : session.messages.find_by(event_type: "tool_result", tool_use_id:)
      row&.payload&.dig("result", "data") || {}
    end

    # Take the owner's decision on this frozen call and carry it out. Returns the nudge to resume with,
    # or nil when the claim lost (already decided elsewhere). The claim is the UPDATE's own WHERE.
    #
    # FAILS CLOSED, deliberately: approval must be stated explicitly. Anything that is not exactly
    # "approve"/"refuse" raises rather than resolving to a status — a gate that treats an unrecognized
    # decision as consent would run a needs_approval! tool (share_public, deploy…) that no human
    # authorized. This is why the status is derived from "approve", never from "not refuse".
    def decide_approval!(decision)
      unless APPROVAL_DECISIONS.include?(decision.to_s)
        raise ArgumentError, "unknown approval decision: #{decision.inspect}"
      end

      status = decision.to_s == "approve" ? "approved" : "rejected"
      claimed = self.class.where(id:, approval_status: "pending")
                    .update_all(approval_status: status, updated_at: Time.current)
      return nil if claimed.zero?

      reload
      return refusal_nudge if approval_rejected?

      # R3: an external MCP tool is executed by the SERVER, not Ruby. Approving it doesn't run anything
      # here — the resume re-runs with it allowed (see AgentTurn#approved_mcp_tools) and the server
      # runs it. Only Ruby tools execute via run_frozen_call!.
      mcp_tool? ? mcp_approved_nudge : run_frozen_call!
    end

    private

      def assign_turn
        self.user_message ||= session.open_turn_lead unless role == "user"
      end

      # Run the call the owner saw — THAT tool with THOSE args, off the row. Log the result like any
      # other. Returns the nudge to hand the resumed agent.
      def run_frozen_call!
        name = payload["name"]
        tool = Rbrun::ApplicationTool.find(name)
        args = (payload["input"] || {}).symbolize_keys
        result =
          begin
            tool ? tool.in_session(session).execute(**args) : { "error" => "unknown tool: #{name}" }
          rescue StandardError => e
            { "error" => e.message }
          end
        failed = result.is_a?(Hash) && result["error"]

        session.messages.create!(role: "tool", event_type: "tool_result", content: result.to_json,
          tool_use_id:,
          payload: { "tool_use_id" => tool_use_id, "result" => result, "is_error" => !!failed })

        "The user approved #{name}. Result: #{result.to_json}. Continue."
      end

      def mcp_tool? = payload["tool_kind"] == "mcp"

      # The external server reconnects asynchronously on resume; if the first re-call reports the tool
      # unavailable, that is the connection still settling, not a real absence — retry.
      def mcp_approved_nudge
        "The user approved #{payload['name']} — it is now enabled. Call it again with the same arguments. " \
          "If the first call reports the tool unavailable, wait a moment and retry it once or twice; " \
          "it is reconnecting."
      end

      def refusal_nudge = "The user refused #{payload['name']}. Do not retry it; propose an alternative."

      def broadcastable? = role == "user" || event_type.in?(BROADCAST_EVENTS)
      def finalized? = visible? && saved_change_to_content? && content.present?

      def broadcast_open_or_event
        if role == "user" && event_type == "text"
          ::Turbo::StreamsChannel.broadcast_append_to("rbrun_session_#{session_id}",
            target: "conversation_#{session_id}", partial: "rbrun/sessions/turn",
            locals: { user_message: self, messages: [ self ] })
        else
          session.broadcast_event(self, created: true)
        end
      end

      def broadcast_finalized_event = session.broadcast_event(self, created: false)
  end
end
