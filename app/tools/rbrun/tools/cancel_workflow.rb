module Rbrun
  module Tools
    # Stop the workflow running in this conversation. Keeps the binding + the workflow (cancel ≠ delete):
    # it only sets the run's status to cancelled and hides the band.
    class CancelWorkflow < Rbrun::ApplicationTool
      description "Cancel the workflow currently running in this conversation. The workflow itself is kept; only this run stops and its progress band is hidden."

      def execute
        return error("no workflow is running") unless session.workflow_id && !session.workflow_status_cancelled?

        session.workflow_status_cancelled!
        session.broadcast_workflow
        { "data" => { "cancelled" => true } }
      end
    end
  end
end
