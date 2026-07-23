module Rbrun
  # Replays a SkillScenario as a SELF-VALIDATING run and returns the evidence-backed record. It asserts
  # nothing itself: it seeds a workflow from the scenario's steps, opens an AUTONOMOUS session (auto mode
  # → the gate never parks, so the agent self-validates via validate_step without a human), runs the
  # scenario's OWN prompt (never the plan — that would spoon-feed the tools), then nudges until every
  # step is validated or the run stalls. The verdict is the agent's; the trust anchor is the demo
  # guidance AgentTurn injects (validation is worth only its proof). The box is reaped in `ensure`.
  class SkillScenarioRun
    GUARD = 12 # cap on nudge turns beyond the step count — a run can't legitimately need more

    def self.run(scenario, tenant:, runtime: nil) = new(scenario, tenant:, runtime:).run

    def initialize(scenario, tenant:, runtime: nil)
      @scenario = scenario
      @tenant = tenant
      @runtime = runtime
    end

    def run
      worktree = Rbrun::Worktree.create!(tenant: @tenant, repo: "rbrun/scenarios", bare: true)
      workflow = seed_workflow
      session  = worktree.sessions.create!(tenant: @tenant, auto: true, workflow:,
                                           workflow_status: "active", preferred_skills: [ @scenario.skill.slug ])
      begin
        session.run_turn(@scenario.prompt, runtime: @runtime)
        advance(session)
        record(session.reload, workflow)
      ensure
        begin
          session.sandbox.destroy!
        rescue StandardError
          nil
        end
        worktree.destroy!
        workflow.destroy!
      end
    end

    private

      def seed_workflow
        workflow = Rbrun::Workflow.create!(tenant: @tenant, label: @scenario.label, goal: @scenario.description)
        @scenario.step_list.each_with_index do |step, i|
          workflow.steps.create!(position: i + 1, title: step["label"], description: step["description"])
        end
        workflow
      end

      # A workflow is multi-turn: after the opening turn, nudge the next turn (a neutral "continue", never
      # the plan) while steps remain. Bounded by step count + GUARD, and stopped after TWO turns that
      # validated nothing new (the run is stuck — nudging again just burns turns).
      def advance(session)
        prev = -1
        idle = 0
        (@scenario.step_list.size + GUARD).times do
          run = Rbrun::Workflow::Run.new(session.reload)
          break if run.all_done?

          idle = run.done_count > prev ? 0 : idle + 1
          break if idle >= 2

          prev = run.done_count
          session.run_turn("Continue the workflow: pick up at the next step you have not validated.", runtime: @runtime)
        end
      end

      def record(session, workflow)
        run = Rbrun::Workflow::Run.new(session)
        steps = workflow.steps.map do |step|
          done = session.workflow_step_completions.exists?(workflow_step: step)
          { label: step.title, description: step.description, done: }
        end
        { scenario: @scenario, session:, steps:,
          done: run.done_count, total: run.total, pass: run.all_done? }
      end
  end
end
