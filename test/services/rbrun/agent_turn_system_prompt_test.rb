require "test_helper"

module Rbrun
  class AgentTurnSystemPromptTest < ActiveSupport::TestCase
    # A runtime double (injected via the designed `runtime:` seam) that captures the system prompt.
    class SystemCapturingRuntime
      attr_reader :system, :auto, :cwd
      def run(prompt:, system:, tools:, resume:, tool_handler:, on_event:, skills: nil, mcp: nil, auto: nil, cwd: nil)
        @system = system
        @auto = auto
        @cwd = cwd
        on_event.call({ "type" => "result", "session_id" => "sdk-1" })
      end
    end

    setup do
      @session = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b").sessions.create!
    end

    test "the system prompt names the exact checkout (the SDK cwd option doesn't surface it to the agent)" do
      runtime = SystemCapturingRuntime.new
      Rbrun::AgentTurn.new(session: @session, runtime:).run("go")
      assert runtime.system.start_with?(Rbrun.config(@session.tenant).system_prompt.to_s)
      assert_includes runtime.system, "Your working directory"
      assert_includes runtime.system, @session.worktree.checkout
    end

    test "preferred_skills append a steer to the system prompt" do
      @session.update!(preferred_skills: %w[create-skill])
      runtime = SystemCapturingRuntime.new
      Rbrun::AgentTurn.new(session: @session, runtime:).run("go")

      assert runtime.system.start_with?(Rbrun.config(@session.tenant).system_prompt.to_s)
      assert_includes runtime.system, "prefer these skills"
      assert_includes runtime.system, "create-skill"
    end

    test "empty preferred_skills add no skills steer" do
      @session.update!(preferred_skills: [])
      runtime = SystemCapturingRuntime.new
      Rbrun::AgentTurn.new(session: @session, runtime:).run("go")
      refute_includes runtime.system, "prefer these skills"
    end

    test "the checkout is passed to the runtime as cwd (the SDK's working dir)" do
      runtime = SystemCapturingRuntime.new
      Rbrun::AgentTurn.new(session: @session, runtime:).run("go")
      assert_equal @session.worktree.checkout, runtime.cwd
    end

    test "the session's auto flag flows to the runtime" do
      runtime = SystemCapturingRuntime.new
      Rbrun::AgentTurn.new(session: @session, runtime:).run("go")
      assert_equal false, runtime.auto

      @session.update!(auto: true)
      auto_runtime = SystemCapturingRuntime.new
      Rbrun::AgentTurn.new(session: @session, runtime: auto_runtime).run("go")
      assert_equal true, auto_runtime.auto
    end
  end
end
