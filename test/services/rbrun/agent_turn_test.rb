require "test_helper"

module Rbrun
  class AgentTurnTest < ActiveSupport::TestCase
    # A scripted stand-in for a runtime adapter: plays events into on_event and round-trips the tool.
    class ToolCallingRuntime
      def run(prompt:, system:, tools:, resume:, tool_handler:, on_event:)
        on_event.call({ type: "session", session_id: "sess-1" })
        on_event.call({ type: "assistant", text: "on it" })
        resp = tool_handler.call({ type: "tool_request", id: "t1", name: "identity", args: {} })
        raise "bridge broke" if resp[:is_error]
        on_event.call({ type: "result", stop_reason: "end_turn" })
        { type: "result", stop_reason: "end_turn" }
      end
    end

    class GatingRuntime
      def run(prompt:, system:, tools:, resume:, tool_handler:, on_event:)
        on_event.call({ type: "session", session_id: "sess-2" })
        on_event.call({ type: "needs_approval", tool: "dangerous", arguments: { "x" => 1 }, tool_use_id: "g1" })
        { type: "result", stop_reason: "awaiting_approval" }
      end
    end

    setup do
      @session = Session.create!(tenant: "acme")
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
