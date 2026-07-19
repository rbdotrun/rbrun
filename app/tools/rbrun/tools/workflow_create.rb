module Rbrun
  module Tools
    # Propose a durable, multi-step workflow. A custom gate: the run ENDS on the proposal and the user
    # decides via a 3-button card (Apply / Save / Cancel) handled by WorkflowDecisionsController. No
    # execute — a gate tool's operation IS the user's submission (custom_approval! supplies the degrade).
    class WorkflowCreate < Rbrun::ApplicationTool
      custom_approval! submit: :workflow_decision

      description <<~TXT
        Propose a multi-step workflow (a durable, reusable task procedure) for the user to review. Use it
        for any task with a clear goal and MORE THAN ONE step — never for a single step. The run ENDS on
        this proposal; the user decides via a card: Apply (create it AND start it here), Save (add to the
        library only), or Cancel (create nothing). `steps` are short imperative titles, in order.
        Example: { "label": "Ship the release", "goal": "Cut and publish v2.0",
                   "steps": ["Bump the version", "Update the changelog", "Tag and push"] }
      TXT

      parameter :label, type: "string", description: "a short name for the workflow", required: true
      parameter :goal, type: "string", description: "the outcome the workflow achieves"
      parameter :description, type: "string", description: "optional longer context"
      parameter :steps, type: "array", items: -> { { "type" => "string" } },
                description: "ordered list of short step titles", required: true
    end
  end
end
