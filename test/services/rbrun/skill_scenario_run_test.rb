require "test_helper"

module Rbrun
  class SkillScenarioRunTest < ActiveSupport::TestCase
    # A fake runtime standing in for an autonomous agent: each turn it validates the current workflow
    # step through the real tool path (validate_step), exactly as auto mode would let the SDK do.
    class SelfValidatingRuntime
      def initialize = @n = 0
      def run(prompt:, tool_handler:, on_event:, system: nil, tools: [], skills: nil, mcp: nil, resume: nil, auto: nil)
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
      @skill = Rbrun::Skill.create!(tenant: "acme", slug: "create-skill", name: "Create Skill")
      @scenario = Rbrun::SkillScenario.create!(
        tenant: "acme", skill: @skill, label: "Two steps", prompt: "do the thing",
        steps: [ { "label" => "Step one", "description" => "prove one" },
                 { "label" => "Step two", "description" => "prove two" } ]
      )
    end

    test "replays the scenario, self-validates every step, and passes" do
      record = Rbrun::SkillScenarioRun.run(@scenario, tenant: "acme", runtime: SelfValidatingRuntime.new)

      assert_equal 2, record[:total]
      assert_equal 2, record[:done]
      assert record[:pass]
      assert record[:steps].all? { |s| s[:done] }
      assert_equal [ "Step one", "Step two" ], record[:steps].map { |s| s[:label] }
    end

    test "a stuck run stops (two idle turns) and does not pass" do
      record = Rbrun::SkillScenarioRun.run(@scenario, tenant: "acme", runtime: StuckRuntime.new)

      refute record[:pass]
      assert_equal 0, record[:done]
    end

    test "it reaps its worktree — no leak" do
      before = Rbrun::Worktree.count
      Rbrun::SkillScenarioRun.run(@scenario, tenant: "acme", runtime: SelfValidatingRuntime.new)
      assert_equal before, Rbrun::Worktree.count
    end
  end
end
