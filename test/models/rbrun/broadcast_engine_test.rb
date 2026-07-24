require "test_helper"

module Rbrun
  class BroadcastEngineTest < ActiveSupport::TestCase
    setup { Rbrun.register_tool(Rbrun::Tools::Identity) }

    test "turns group the visible timeline by user message" do
      s = rbrun_session
      u1 = s.messages.create!(role: "user", event_type: "text", content: "one")
      s.messages.create!(role: "assistant", event_type: "text", content: "a1")
      u2 = s.messages.create!(role: "user", event_type: "text", content: "two")
      s.messages.create!(role: "assistant", event_type: "text", content: "a2")

      turns = s.turns
      assert_equal 2, turns.size
      assert_equal u1, turns.first.first
      assert_equal u2, turns.last.first
    end

    test "token/session frames are not visible in the timeline" do
      s = rbrun_session
      s.messages.create!(role: "user", event_type: "text", content: "hi")
      s.messages.create!(role: "assistant", event_type: "token", content: "x")
      s.messages.create!(role: "assistant", event_type: "session", payload: { "session_id" => "z" })
      assert_equal 1, s.timeline.size
    end

    test "agent rows thread to the open turn lead" do
      s = rbrun_session
      lead = s.messages.create!(role: "user", event_type: "text", content: "do it")
      reply = s.messages.create!(role: "assistant", event_type: "text", content: "done")
      assert_equal lead, reply.reload.user_message
    end

    # A pending gate, approved, runs the frozen tool and logs a tool_result.
    class Adder < Rbrun::ApplicationTool
      description "add"
      parameter :a, type: "integer", required: true
      parameter :b, type: "integer", required: true
      def execute(a:, b:) = { "data" => { "sum" => a + b } }
    end

    test "decide_approval! approve runs the frozen call and returns a nudge" do
      Rbrun.register_tool(Adder)
      s = rbrun_session
      s.messages.create!(role: "user", event_type: "text", content: "add")
      frozen = s.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "g1",
        approval_status: "pending", payload: { "name" => "adder", "input" => { "a" => 2, "b" => 3 } })

      nudge = frozen.decide_approval!("approve")
      assert_match(/approved adder/i, nudge)
      assert frozen.reload.approval_approved?
      result = s.messages.find_by(event_type: "tool_result", tool_use_id: "g1")
      assert_equal({ "sum" => 5 }, result.payload.dig("result", "data"))
    end

    test "decide_approval! refuse records the rejection and does not run the tool" do
      s = rbrun_session
      frozen = s.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "g2",
        approval_status: "pending", payload: { "name" => "adder", "input" => {} })
      nudge = frozen.decide_approval!("refuse")
      assert_match(/refused/i, nudge)
      assert frozen.reload.approval_rejected?
      assert s.messages.where(event_type: "tool_result", tool_use_id: "g2").none?
    end

    test "a second decide_approval! loses the claim (returns nil)" do
      s = rbrun_session
      frozen = s.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "g3",
        approval_status: "pending", payload: { "name" => "adder", "input" => { "a" => 1, "b" => 1 } })
      frozen.decide_approval!("approve")
      assert_nil frozen.decide_approval!("approve")
    end

    class GateRuntime
      def run(on_event:, **)
        on_event.call({ type: "needs_approval", tool: "x", arguments: {}, tool_use_id: "gg", tool_kind: "ruby" })
        { type: "result", stop_reason: "awaiting_approval" }
      end
    end

    class OkRuntime
      def run(**) = { type: "result", stop_reason: "end_turn" }
    end

    test "continue_turn! resumes and lands done (internal row, no user row)" do
      s = rbrun_session
      before = s.messages.where(role: "user").count
      s.continue_turn!("carry on", runtime: OkRuntime.new)
      assert s.done?
      assert_equal before, s.messages.where(role: "user").count
      assert s.messages.exists?(event_type: "internal")
    end

    test "resume_turn! re-gates to needs_approval" do
      s = rbrun_session
      s.resume_turn!(runtime: GateRuntime.new)
      assert s.needs_approval?
    end
  end
end
