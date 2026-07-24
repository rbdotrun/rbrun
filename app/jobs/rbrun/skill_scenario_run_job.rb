module Rbrun
  # Runs a scenario (a skill-bound workflow) off the request: a real autonomous, self-validating run
  # (real LLM + sandbox). Enqueued by the ▶ Run button.
  class SkillScenarioRunJob < ApplicationJob
    def perform(workflow_id, tenant:)
      workflow = Rbrun::Workflow.for_tenant(tenant).scenarios.find(workflow_id)
      Rbrun::SkillScenarioRun.run(workflow, tenant:)
    end
  end
end
