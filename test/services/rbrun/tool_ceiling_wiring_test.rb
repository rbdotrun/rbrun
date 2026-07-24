require "test_helper"

module Rbrun
  # Ruby cannot pre-count an MCP server declared `tools: nil` ("all of them"), so the SDK tool ceiling
  # can only truly be enforced where the real count exists — client.ts. It must therefore REACH the
  # runtime: ToolBudget's comment used to claim it did while nothing actually passed it.
  class ToolCeilingWiringTest < ActiveSupport::TestCase
    class CapturingRuntime
      attr_reader :mcp
      def run(prompt:, system:, tools: [], skills: nil, mcp: nil, resume: nil, auto: nil, cwd: nil,
              tool_handler: nil, on_event: nil)
        @mcp = mcp
        on_event.call({ "type" => "result", "session_id" => "s1" })
      end
    end

    test "the mcp payload carries the engine-owned CEILING to the runtime" do
      # `tools: nil` is the DEFAULT and means "all of this server's tools" — the uncountable case that
      # Ruby cannot pre-budget, which is precisely why the runtime must receive the ceiling.
      Rbrun::McpServer.create!(tenant: "acme", name: "stripe", transport: "stdio",
                               command: "stripe-mcp", enabled: true, tools: nil)
      wt = Rbrun::Worktree.create!(tenant: "acme", repo: "a/b")
      session = wt.sessions.create!
      runtime = CapturingRuntime.new
      Rbrun::AgentTurn.new(session:, runtime:).run("go")

      assert runtime.mcp, "an mcp payload is materialized when a server is configured"
      assert_equal Rbrun::Mcp::ToolBudget::CEILING, runtime.mcp["ceiling"]
    ensure
      begin
        wt&.sandbox&.destroy!
      rescue StandardError
        nil
      end
    end
  end
end
