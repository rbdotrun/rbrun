module Rbrun
  class Workflow
    # Progress of ONE session against its bound workflow. A frozen value object: it re-reads the
    # completion join on each call (never a cached association), so a fresh Run.new(session) after an
    # insert reflects it immediately.
    Run = Data.define(:session) do
      def workflow = session.workflow
      def steps = workflow ? workflow.steps.to_a : []

      def completed_step_ids
        Rbrun::WorkflowStepCompletion.where(session_id: session.id).pluck(:workflow_step_id).to_set
      end

      def done?(step) = completed_step_ids.include?(step.id)
      def current_step = steps.find { |step| !done?(step) }
      def done_count = steps.count { |step| completed_step_ids.include?(step.id) }
      def total = steps.size
      def all_done? = total.positive? && done_count == total
    end
  end
end
