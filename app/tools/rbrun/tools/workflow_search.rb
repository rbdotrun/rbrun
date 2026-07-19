module Rbrun
  module Tools
    # Find reusable workflows in the library before authoring a new one.
    class WorkflowSearch < Rbrun::ApplicationTool
      description "Search the workflow library by keyword (matches label, goal, and description). Use this BEFORE proposing a new workflow, to reuse an existing one."

      parameter :query, type: "string", description: "keywords to match", required: true

      def execute(query:)
        workflows = Rbrun::Workflow.for_tenant(tenant).search(query).limit(10).map do |wf|
          { "id" => wf.id, "label" => wf.label, "goal" => wf.goal, "steps" => wf.steps.map(&:title) }
        end
        { "data" => { "workflows" => workflows } }
      end
    end
  end
end
