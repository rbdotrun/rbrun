module Rbrun
  # The shared mechanics every gate-resolution endpoint performs — approvals (yes/no) and
  # ask_user (a pick). A gated tool_use froze as a pending row; resolving it is always: find that row
  # (tenant-scoped, by the SDK tool_use_id), CLAIM it (only a pending row can be taken, so a double
  # submit updates nothing), record the outcome as the call's tool_result, resume the turn off-request
  # via a job, and flip the gate band in place. Factored so a second gate can't re-implement it
  # slightly differently.
  module ResolvesGate
    extend ActiveSupport::Concern

    private

      # The frozen gate row this request resolves: a pending tool_use in a session the viewer owns.
      def pending_gate
        Rbrun::SessionMessage.joins(:session)
                             .merge(Rbrun::Session.for_tenant(current_tenant))
                             .find_by!(tool_use_id: params[:tool_use_id], event_type: "tool_use")
      end

      # Claim the gate — the UPDATE … WHERE approval_status='pending' IS the lock, so a double-submit is
      # impossible by construction. Returns whether THIS request won it.
      def claim_gate!(row, status:)
        Rbrun::SessionMessage.where(id: row.id, approval_status: "pending")
                             .update_all(approval_status: status, updated_at: Time.current)
                             .positive?
      end

      # The call's own tool_result — the outcome the agent reads when the turn resumes.
      def record_gate_result(row, result, is_error: false)
        row.session.messages.create!(
          role: "tool", event_type: "tool_result", tool_use_id: row.tool_use_id,
          content: result.to_json,
          payload: { "tool_use_id" => row.tool_use_id, "result" => result, "is_error" => is_error }
        )
      end

      # Resume the turn off-request — a JOB, never a 30-60s run inside this HTTP request; the nudge is
      # the app's sentence, never a user message.
      def resume_turn(row, job, nudge) = job.perform_later(row.session_id, nudge)

      # Flip the turn's gate band in place — the same partial the turn renders, so this response and any
      # later live event paint the identical band (live == reload).
      def render_gate_band(row)
        loc = row.session.segment_locals_for(row.reload)
        render turbo_stream: turbo_stream.replace(
          loc[:dom_id], partial: "rbrun/sessions/segment", locals: { segment: loc[:segment] }
        )
      end
  end
end
