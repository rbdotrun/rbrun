module Rbrun
  module Tools
    # Start a fresh run of an existing workflow (from workflow_search) in this conversation. Progress
    # starts empty — completions are per-session, so a reused workflow re-validates from step one.
    class UseWorkflow < Rbrun::ApplicationTool
      description "Start a run of an existing workflow (by id, from workflow_search) in this conversation. Binds it and shows its progress band at step one."

      parameter :workflow_id, type: "integer", description: "the id of a workflow from workflow_search", required: true

      def execute(workflow_id:)
        workflow = Rbrun::Workflow.for_tenant(tenant).find_by(id: workflow_id)
        return error("no such workflow: #{workflow_id}") unless workflow

        session.update!(workflow: workflow, workflow_status: "active")
        session.broadcast_workflow
        { "data" => { "label" => workflow.label, "total" => Rbrun::Workflow::Run.new(session).total } }
      end
    end
  end
end
