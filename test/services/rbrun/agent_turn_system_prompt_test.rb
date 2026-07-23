require "test_helper"

module Rbrun
  class AgentTurnSystemPromptTest < ActiveSupport::TestCase
    # A runtime double (injected via the designed `runtime:` seam) that captures the system prompt.
    class SystemCapturingRuntime
      attr_reader :system, :auto
      def run(prompt:, system:, tools:, resume:, tool_handler:, on_event:, skills: nil, mcp: nil, auto: nil)
        @system = system
        @auto = auto
        on_event.call({ "type" => "result", "session_id" => "sdk-1" })
      end
    end

    setup do
      @session = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b").sessions.create!
    end

    test "the turn's system prompt is the host prompt" do
      runtime = SystemCapturingRuntime.new
      Rbrun::AgentTurn.new(session: @session, runtime: runtime).run("go")
      assert_equal Rbrun.config(@session.tenant).system_prompt, runtime.system
    end

    test "preferred_skills append a steer to the system prompt" do
      @session.update!(preferred_skills: %w[create-skill])
      runtime = SystemCapturingRuntime.new
      Rbrun::AgentTurn.new(session: @session, runtime: runtime).run("go")

      assert runtime.system.start_with?(Rbrun.config(@session.tenant).system_prompt.to_s)
      assert_includes runtime.system, "prefer these skills"
      assert_includes runtime.system, "create-skill"
    end

    test "empty preferred_skills leave the system prompt untouched" do
      @session.update!(preferred_skills: [])
      runtime = SystemCapturingRuntime.new
      Rbrun::AgentTurn.new(session: @session, runtime: runtime).run("go")
      assert_equal Rbrun.config(@session.tenant).system_prompt, runtime.system
    end

    test "the session's auto flag flows to the runtime" do
      runtime = SystemCapturingRuntime.new
      Rbrun::AgentTurn.new(session: @session, runtime: runtime).run("go")
      assert_equal false, runtime.auto

      @session.update!(auto: true)
      auto_runtime = SystemCapturingRuntime.new
      Rbrun::AgentTurn.new(session: @session, runtime: auto_runtime).run("go")
      assert_equal true, auto_runtime.auto
    end
  end
end
