require "test_helper"
require "stringio"

module Rbrun
  class SkillScenarioRunTest < ActiveSupport::TestCase
    # A fake runtime standing in for an autonomous agent: each turn it validates the current workflow
    # step through the real tool path (validate_step), exactly as auto mode would let the SDK do.
    class SelfValidatingRuntime
      def initialize = @n = 0
      def run(prompt:, tool_handler:, on_event:, system: nil, tools: [], skills: nil, mcp: nil, resume: nil, auto: nil, cwd: nil)
        @n += 1
        tool_handler.call({ id: "v#{@n}", name: "validate_step", args: { summary: "did it" } })
        on_event.call({ "type" => "result", "session_id" => "sdk-#{@n}" })
      end
    end

    # A fake that never validates — the run must detect the stall and stop, not loop forever.
    class StuckRuntime
      def run(prompt:, on_event:, **)
        on_event.call({ "type" => "result", "session_id" => "sdk-x" })
      end
    end

    setup do
      @skill = Rbrun::Skill.create!(tenant: "acme", slug: "release-notes", name: "Release Notes")
      @workflow = Rbrun::Workflow.create!(
        tenant: "acme", skill: @skill, label: "Two steps", goal: "prove it", prompt: "do the thing",
        steps_attributes: [
          { position: 1, title: "Step one", description: "prove one" },
          { position: 2, title: "Step two", description: "prove two" }
        ]
      )
    end

    test "replays the workflow's prompt, self-validates every step, and passes" do
      record = Rbrun::SkillScenarioRun.run(@workflow, tenant: "acme", runtime: SelfValidatingRuntime.new)

      assert_equal 2, record[:total]
      assert_equal 2, record[:done]
      assert record[:pass]
      assert record[:steps].all? { |s| s[:done] }
      assert_equal [ "Step one", "Step two" ], record[:steps].map { |s| s[:label] }
    end

    test "a stuck run stops (two idle turns) and does not pass" do
      record = Rbrun::SkillScenarioRun.run(@workflow, tenant: "acme", runtime: StuckRuntime.new)

      refute record[:pass]
      assert_equal 0, record[:done]
    end

    test "it reaps its worktree but NEVER destroys the skill's workflow" do
      before = Rbrun::Worktree.count
      Rbrun::SkillScenarioRun.run(@workflow, tenant: "acme", runtime: SelfValidatingRuntime.new)
      assert_equal before, Rbrun::Worktree.count
      assert Rbrun::Workflow.exists?(@workflow.id), "the skill's template workflow survives the run"
    end

    test "capture_showcase sets the workflow's showcase to the latest artifact on the session" do
      wt = Rbrun::Worktree.create!(tenant: "acme", repo: "rbrun/scenarios", bare: true)
      session = wt.sessions.create!(tenant: "acme", kind: :skill_scenario, workflow: @workflow)
      lead = session.messages.create!(role: "user", event_type: "text", content: @workflow.prompt)
      version = Rbrun::Artifact.append_version!(tenant: "acme", message: lead,
                  io: StringIO.new("# result\n"), filename: "out.md", name: "Result")

      Rbrun::SkillScenarioRun.new(@workflow, tenant: "acme").send(:capture_showcase, session)
      assert_equal version, @workflow.reload.showcase_artifact_version
    ensure
      begin
        wt&.sandbox&.destroy!
      rescue StandardError
        nil
      end
    end
  end
end
