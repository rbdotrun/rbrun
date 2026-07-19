module Rbrun
  # The ONE gate endpoint. A needs_approval tool call is frozen as a pending tool_use row; this is
  # where the owner decides it. Nothing is parked — the decision runs the frozen call, then a JOB
  # resumes the conversation. The acting tab updates from THIS response (not the cable).
  class ApprovalsController < Rbrun::ApplicationController
    def update
      message = pending_call
      nudge = message.decide_approval!(params[:decision])

      # Claim lost (already decided by another click/tab): nothing ran, nothing to resume.
      return head :no_content unless nudge

      ApprovalTurnJob.perform_later(message.session_id, nudge)

      loc = message.session.segment_locals_for(message)
      render turbo_stream: turbo_stream.replace(
        loc[:dom_id], partial: "rbrun/sessions/segment", locals: { segment: loc[:segment] }
      )
    end

    private

    def pending_call
      Rbrun::SessionMessage.joins(:session)
                           .merge(Rbrun::Session.for_tenant(current_tenant))
                           .find_by!(tool_use_id: params[:tool_use_id], event_type: "tool_use")
    end
  end
end
