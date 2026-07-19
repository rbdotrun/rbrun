module Rbrun
  # The yes/no gate endpoint. A needs_approval tool call is frozen as a pending tool_use row; this is
  # where the owner decides it. decide_approval! claims the row and, on approve, runs the frozen Ruby
  # call; then a JOB resumes the conversation. The shared dance lives in ResolvesGate.
  class ApprovalsController < Rbrun::ApplicationController
    include Rbrun::ResolvesGate

    def update
      message = pending_gate
      nudge = message.decide_approval!(params[:decision])

      # Claim lost (already decided by another click/tab): nothing ran, nothing to resume.
      return head :no_content unless nudge

      resume_turn(message, ApprovalTurnJob, nudge)
      render_gate_band(message)
    end
  end
end
