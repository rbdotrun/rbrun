module Rbrun
  # The workflow_create gate endpoint. A frozen workflow_create tool_use row carries the proposed plan;
  # the user's Apply/Save/Cancel arrives here, is applied to a NEW durable Workflow (read off the FROZEN
  # plan — the agent proposed it, so the decision only chooses what to do with it), recorded as the
  # call's tool_result, and resumes the turn — via the shared ResolvesGate dance.
  class WorkflowDecisionsController < Rbrun::ApplicationController
    include Rbrun::ResolvesGate

    DECISIONS = %w[apply save cancel].freeze

    def create
      row = pending_gate
      decision = params[:decision].to_s
      return head(:unprocessable_entity) unless DECISIONS.include?(decision)
      # A frozen call carrying no usable plan is a CORRUPT gate, not a nameable workflow. `label` and
      # `steps` are both required: true on the tool schema, so a blank one means the payload is
      # malformed. Inventing them ("Untitled workflow", zero steps) satisfied the model's own presence
      # validation, filed an unnamed row in the searchable library, told the agent the user had applied
      # a workflow they never saw, and — with no steps — left the session workflow_status:"active"
      # forever, since Run#all_done? is false while total is zero. Cancel is always allowed: you must be
      # able to dismiss a broken gate.
      plan = Rbrun::WorkflowPlan.for(row)
      return head(:unprocessable_entity) if decision != "cancel" && !plan.usable?

      return head :no_content unless claim_gate!(row, status: (decision == "cancel" ? "rejected" : "approved"))

      outcome = perform(decision, row.session, plan)
      record_gate_result(row, { "decision" => decision }.merge(outcome))
      resume_turn(row, WorkflowDecisionTurnJob, nudge_for(decision, outcome))
      render_gate_band(row)
    end

    private

      def perform(decision, session, plan)
        return { "created" => false } if decision == "cancel"

        workflow = create_workflow(session.tenant, plan)
        if decision == "apply"
          session.update!(workflow:, workflow_status: "active")
          session.broadcast_workflow
        end
        { "created" => true, "workflow_id" => workflow.id, "label" => workflow.label, "bound" => decision == "apply" }
      end

      # Takes a WorkflowPlan (the parsed boundary), never a raw hash — no key-digging, no coercion, and
      # no label fallback: a malformed plan was already refused above, and Workflow's own presence
      # validation is the backstop rather than something we paper over.
      def create_workflow(tenant, plan)
        workflow = Rbrun::Workflow.new(label: plan.label, goal: plan.goal, description: plan.description)
        workflow[Rbrun.config.tenancy_key] = tenant
        workflow.save!
        plan.steps.each_with_index { |title, i| workflow.steps.create!(position: i, title:) }
        workflow
      end

      def nudge_for(decision, outcome)
        case decision
        when "apply"
          "The user applied the workflow \"#{outcome['label']}\" — it is now running in this conversation. " \
            "Work the steps in order; call validate_step when you finish each one."
        when "save"
          "The user saved the workflow \"#{outcome['label']}\" to the library but did NOT start it here. " \
            "Continue with the current task."
        else
          "The user declined to create the workflow. Proceed without one, or propose a revised plan."
        end
      end
  end
end
