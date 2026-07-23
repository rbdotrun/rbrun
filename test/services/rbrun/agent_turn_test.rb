require "test_helper"

module Rbrun
  class AgentTurnTest < ActiveSupport::TestCase
    # A scripted stand-in for a runtime adapter: plays events into on_event and round-trips the tool.
    class ToolCallingRuntime
      def run(prompt:, system:, tools:, resume:, tool_handler:, on_event:, skills: nil, mcp: nil, auto: nil, cwd: nil)
        on_event.call({ type: "session", session_id: "sess-1" })
        on_event.call({ type: "assistant", text: "on it" })
        resp = tool_handler.call({ type: "tool_request", id: "t1", name: "identity", args: {} })
        raise "bridge broke" if resp[:is_error]
        on_event.call({ type: "result", stop_reason: "end_turn" })
        { type: "result", stop_reason: "end_turn" }
      end
    end

    class GatingRuntime
      def run(prompt:, system:, tools:, resume:, tool_handler:, on_event:, skills: nil, mcp: nil, auto: nil, cwd: nil)
        on_event.call({ type: "session", session_id: "sess-2" })
        on_event.call({ type: "needs_approval", tool: "dangerous", arguments: { "x" => 1 }, tool_use_id: "g1" })
        { type: "result", stop_reason: "awaiting_approval" }
      end
    end

    setup do
      @session = rbrun_session(tenant: "acme")
      Rbrun.register_tool(Rbrun::Tools::Identity)
    end

    test "run persists the user row, the session id, tool_use+tool_result, and assistant text" do
      AgentTurn.new(session: @session, runtime: ToolCallingRuntime.new).run("who am I?")
      types = @session.messages.pluck(:event_type)
      assert_includes types, "text"        # user + assistant
      assert_includes types, "tool_use"
      assert_includes types, "tool_result"
      assert_equal "sess-1", @session.reload.sdk_session_id
      tr = @session.messages.find_by(event_type: "tool_result")
      refute tr.payload["is_error"]
      assert_equal "acme", JSON.parse(tr.content).dig("data", "tenant")
    end

    # Captures whatever skills dir the runtime is handed, and reads it back before the turn ends.
    class SkillsCapturingRuntime
      attr_reader :staged

      def run(prompt:, system:, tools:, resume:, tool_handler:, on_event:, skills: nil, mcp: nil, auto: nil, cwd: nil)
        @staged = skills && Rbrun::SkillArchive.read_dir(skills)
        on_event.call({ type: "result", stop_reason: "end_turn" })
        { type: "result", stop_reason: "end_turn" }
      end
    end

    test "a turn materializes the tenant's current skill versions from the DB into the runtime" do
      files = { "SKILL.md" => "# staged\n" }
      skill = Rbrun::Skill.create!(tenant: "acme", slug: "pdf", name: "PDF")
      skill.promote!(digest: Rbrun::SkillArchive.digest_files(files),
                     archive: Rbrun::SkillArchive.pack_files(files), source: :inline)

      runtime = SkillsCapturingRuntime.new
      AgentTurn.new(session: @session, runtime: runtime).run("go")

      assert_equal({ "pdf/SKILL.md" => "# staged\n" }, runtime.staged,
                   "the current version's folder is staged under <slug>/")
    end

    class McpCapturingRuntime
      attr_reader :mcp, :seen

      def run(prompt:, system:, tools:, resume:, tool_handler:, on_event:, skills: nil, mcp: nil, auto: nil, cwd: nil)
        @mcp = mcp
        on_event.call({ type: "result", stop_reason: "end_turn" })
        { type: "result", stop_reason: "end_turn" }
      end
    end

    test "a turn materializes the tenant's enabled MCP servers into mcp.json" do
      Rbrun::McpServer.create!(tenant: "acme", name: "stripe", transport: "stdio", command: "npx",
                               args: [ "-y", "x" ], env: { "K" => "v" })
      runtime = McpCapturingRuntime.new
      AgentTurn.new(session: @session, runtime: runtime).run("go")

      assert_equal({ "command" => "npx", "args" => [ "-y", "x" ], "env" => { "K" => "v" } },
                   runtime.mcp.dig("servers", "stripe"))
      assert runtime.mcp.key?("tools")
      assert runtime.mcp.key?("permissions")
    end

    test "the MCP resolver is called with the session's tenant + the WORKTREE's repo (R1)" do
      seen = nil
      Rbrun.mcp_resolver = ->(tenant, repo) { seen = [ tenant, repo ]; [] }
      AgentTurn.new(session: @session, runtime: ToolCallingRuntime.new).run("go")
      assert_equal [ "acme", "acme/webapp" ], seen
    ensure
      Rbrun.mcp_resolver = nil
    end

    test "no MCP servers ⇒ mcp is nil" do
      runtime = McpCapturingRuntime.new
      AgentTurn.new(session: @session, runtime: runtime).run("go")
      assert_nil runtime.mcp
    end

    class McpGatingRuntime
      def run(prompt:, system:, tools:, resume:, tool_handler:, on_event:, skills: nil, mcp: nil, auto: nil, cwd: nil)
        on_event.call({ type: "session", session_id: "sess-mcp" })
        on_event.call({ type: "needs_approval", tool: "mcp__stripe__pay", arguments: { "amt" => 5 },
                        tool_use_id: "g9", tool_kind: "mcp" })
        { type: "result", stop_reason: "awaiting_approval" }
      end
    end

    class McpStatusRuntime
      def run(prompt:, system:, tools:, resume:, tool_handler:, on_event:, skills: nil, mcp: nil, auto: nil, cwd: nil)
        on_event.call({ type: "mcp_status", servers: [ { name: "stripe", status: "failed" }, { name: "rbrun", status: "connected" } ] })
        on_event.call({ type: "result", stop_reason: "end_turn" })
        { type: "result", stop_reason: "end_turn" }
      end
    end

    test "a settled MCP connection failure is surfaced loud, not silent (readiness)" do
      AgentTurn.new(session: @session, runtime: McpStatusRuntime.new).run("go")
      status = @session.messages.find_by(event_type: "mcp_status")
      assert status, "a failed server produces a visible row"
      assert_includes status.payload["failed"], "stripe"
    end

    test "an external MCP needs_approval call freezes with tool_kind mcp (R3)" do
      turn = AgentTurn.new(session: @session, runtime: McpGatingRuntime.new)
      turn.run("pay")
      assert turn.gated?
      frozen = @session.messages.gated.last
      assert_equal "mcp__stripe__pay", frozen.payload["name"]
      assert_equal "mcp", frozen.payload["tool_kind"]
    end

    test "approving an MCP call does NOT run it in Ruby — it nudges the resume, no tool_result" do
      frozen = @session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "g9",
        approval_status: "pending", payload: { "name" => "mcp__stripe__pay", "input" => {}, "tool_kind" => "mcp" })

      nudge = nil
      assert_no_difference("@session.messages.where(event_type: 'tool_result').count") do
        nudge = frozen.decide_approval!("approve")
      end
      assert_match(/Call it again/, nudge)
    end

    test "the resume run passes approved MCP tools so the SERVER executes them" do
      Rbrun::McpServer.create!(tenant: "acme", name: "stripe", transport: "stdio", command: "npx")
      @session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "g9",
        approval_status: "approved", payload: { "name" => "mcp__stripe__pay", "tool_kind" => "mcp" })

      runtime = McpCapturingRuntime.new
      AgentTurn.new(session: @session, runtime: runtime).run("continue")
      assert_includes runtime.mcp["approved"], "mcp__stripe__pay"
    end

    test "a needs_approval event freezes a pending tool_use row and marks the turn gated" do
      turn = AgentTurn.new(session: @session, runtime: GatingRuntime.new)
      turn.run("do the dangerous thing")
      assert turn.gated?
      frozen = @session.messages.gated.last
      assert frozen.approval_pending?
      assert_equal "dangerous", frozen.payload["name"]
      assert_equal({ "x" => 1 }, frozen.payload["input"])
      assert @session.messages.where(event_type: "tool_result", tool_use_id: "g1").none?
    end
  end
end
