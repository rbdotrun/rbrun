module Rbrun
  # Replays a skill's scenario (a skill-bound Workflow) as a SELF-VALIDATING run. It binds the workflow
  # to an AUTONOMOUS :skill_scenario session (auto mode → the gate never parks, so the agent
  # self-validates via validate_step without a human), replays the workflow's OWN prompt (never the
  # steps — that would spoon-feed the tools), nudges until every step is validated or the run stalls,
  # and captures the produced artifact as the workflow's showcase. The verdict is the agent's. The box +
  # session are reaped in `ensure`; the workflow (the skill's template) is NEVER destroyed.
  class SkillScenarioRun
    GUARD = 12 # cap on nudge turns beyond the step count — a run can't legitimately need more

    def self.run(workflow, tenant:, runtime: nil) = new(workflow, tenant:, runtime:).run

    def initialize(workflow, tenant:, runtime: nil)
      @workflow = workflow
      @tenant = tenant
      @runtime = runtime
    end

    def run
      worktree = Rbrun::Worktree.create!(tenant: @tenant, repo: "rbrun/scenarios", bare: true)
      session  = worktree.sessions.create!(tenant: @tenant, auto: true, kind: :skill_scenario,
                                           workflow: @workflow, workflow_status: "active",
                                           preferred_skills: [ @workflow.skill.slug ])
      begin
        session.run_turn(@workflow.prompt, runtime: @runtime)
        advance(session)
        capture_showcase(session)
        record(session.reload)
      ensure
        begin
          session.sandbox.destroy!
        rescue StandardError
          nil
        end
        worktree.destroy!
      end
    end

    private

      # A workflow is multi-turn: after the opening turn, nudge the next turn (a neutral "continue", never
      # the plan) while steps remain. Bounded by step count + GUARD, and stopped after TWO turns that
      # validated nothing new (the run is stuck — nudging again just burns turns).
      def advance(session)
        prev = -1
        idle = 0
        (@workflow.steps.size + GUARD).times do
          run = Rbrun::Workflow::Run.new(session.reload)
          break if run.all_done?

          idle = run.done_count > prev ? 0 : idle + 1
          break if idle >= 2

          prev = run.done_count
          session.run_turn("Continue the workflow: pick up at the next step you have not validated.", runtime: @runtime)
        end
      end

      # The artifact produced during this run (attributed to one of the session's messages) becomes the
      # workflow's showcase. Persisted before reaping; the version survives the session's deletion.
      def capture_showcase(session)
        version = Rbrun::ArtifactVersion.where(message: session.messages).order(:id).last
        @workflow.update!(showcase_artifact_version: version) if version
      end

      def record(session)
        run = Rbrun::Workflow::Run.new(session)
        steps = @workflow.steps.map do |step|
          { label: step.title, description: step.description,
            done: session.workflow_step_completions.exists?(workflow_step: step) }
        end
        { workflow: @workflow, session:, steps:, showcase: @workflow.showcase_artifact_version,
          done: run.done_count, total: run.total, pass: run.all_done? }
      end
  end
end
