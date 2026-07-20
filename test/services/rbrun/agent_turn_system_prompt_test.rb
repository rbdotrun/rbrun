require "test_helper"

module Rbrun
  class AgentTurnSystemPromptTest < ActiveSupport::TestCase
    # A runtime double (injected via the designed `runtime:` seam) that captures the system prompt.
    class SystemCapturingRuntime
      attr_reader :system
      def run(prompt:, system:, tools:, resume:, tool_handler:, on_event:, skills: nil, mcp: nil)
        @system = system
        on_event.call({ "type" => "result", "session_id" => "sdk-1" })
      end
    end

    setup do
      @session = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b").sessions.create!
    end

    test "the turn's system prompt carries the host prompt AND the repo-services convention" do
      runtime = SystemCapturingRuntime.new
      Rbrun::AgentTurn.new(session: @session, runtime: runtime).run("go")
      assert_includes runtime.system, Rbrun.config(@session.tenant).system_prompt.strip
      assert_includes runtime.system, "repo_services_start"
      assert_includes runtime.system, "NEVER a raw `&`" # the anti-backgrounding instruction
      assert_includes runtime.system, "request_secrets"
    end
  end
end
