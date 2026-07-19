module Rbrun
  module Tools
    # Mark the CURRENT workflow step complete — pending the user's approval. On approve the frozen
    # execute runs (records a per-session completion, advances the band, completes the run on the last
    # step). A plain needs_approval! gate: the yes/no ApprovalsController resolves it.
    class ValidateStep < Rbrun::ApplicationTool
      needs_approval!

      description <<~TXT
        Mark the CURRENT workflow step complete — pending the user's approval. Call this ONLY after you
        have actually finished the current step. On approval the task-progress band advances to the next
        step; on refusal nothing is recorded and you should address the user's feedback. `summary` is one
        short line describing what you completed.
      TXT

      parameter :summary, type: "string", description: "one line: what you completed for this step"

      def execute(summary: nil)
        step = Rbrun::Workflow::Run.new(session).current_step
        return error("no active workflow step to validate") unless step

        session.workflow_step_completions.create!(
          workflow_step: step, user_message: session.open_turn_lead, completed_at: Time.current
        )
        run = Rbrun::Workflow::Run.new(session) # fresh read after the insert
        session.workflow_status_completed! if run.all_done?
        session.broadcast_workflow

        { "data" => { "step" => step.title, "summary" => summary, "done" => run.done_count,
                      "total" => run.total, "all_done" => run.all_done? } }
      end
    end
  end
end
