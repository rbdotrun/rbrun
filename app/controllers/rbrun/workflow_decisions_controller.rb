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
      return head :no_content unless claim_gate!(row, status: (decision == "cancel" ? "rejected" : "approved"))

      outcome = perform(decision, row.session, row.payload["input"] || {})
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

      def create_workflow(tenant, plan)
        workflow = Rbrun::Workflow.new(label: plan["label"].to_s.strip.presence || "Untitled workflow",
                                       goal: plan["goal"], description: plan["description"])
        workflow[Rbrun.config.tenancy_key] = tenant
        workflow.save!
        Array(plan["steps"]).map(&:to_s).map(&:strip).reject(&:empty?).each_with_index do |title, i|
          workflow.steps.create!(position: i, title:)
        end
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
