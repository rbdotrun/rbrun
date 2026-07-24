module Rbrun
  # A skill's scenarios — skill-bound Rbrun::Workflows authored through a nested form (label + example
  # prompt + WorkflowStep rows) and replayed by ▶ Run as self-validating autonomous runs.
  class WorkflowsController < Rbrun::ApplicationController
    before_action :set_skill

    def new
      @workflow = @skill.workflows.build(tenant: current_tenant)
      @workflow.steps.build(position: 1)
    end

    def create
      @workflow = @skill.workflows.build(workflow_params.merge(tenant: current_tenant))
      if @workflow.save
        redirect_to rbrun.edit_skill_path(@skill.slug), notice: "Scenario saved."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @workflow = find_workflow
    end

    def update
      @workflow = find_workflow
      if @workflow.update(workflow_params)
        redirect_to rbrun.edit_skill_path(@skill.slug), notice: "Scenario updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      find_workflow.destroy!
      redirect_to rbrun.edit_skill_path(@skill.slug), notice: "Scenario removed."
    end

    def run
      Rbrun::SkillScenarioRunJob.perform_later(find_workflow.id, tenant: current_tenant)
      redirect_to rbrun.edit_skill_path(@skill.slug), notice: "Scenario run started."
    end

    private

      def set_skill = @skill = Rbrun::Skill.for_tenant(current_tenant).find_by!(slug: params[:skill_slug])
      def find_workflow = @skill.workflows.find(params[:id])

      # `position` is deliberately NOT permitted: order comes from the submitted row order
      # (Workflow#renumber_steps), so a client can't dictate — or mis-guess — the sequence.
      def workflow_params
        params.require(:workflow).permit(:label, :prompt, :goal,
          steps_attributes: %i[id title description _destroy])
      end
  end
end
