require "test_helper"

module Rbrun
  class SessionMessageTest < ActiveSupport::TestCase
    setup { @session = rbrun_session(tenant: "acme") }

    test "persists an event row verbatim with json payload" do
      m = @session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "t1",
                                    payload: { "name" => "add", "input" => { "a" => 2 } })
      assert_equal "add", m.reload.payload["name"]
      assert m.tool_use?
    end

    test "approval_status enum is prefixed and gated scope finds frozen calls" do
      pending = @session.messages.create!(role: "assistant", event_type: "tool_use",
                                          approval_status: "pending", tool_use_id: "t2")
      @session.messages.create!(role: "assistant", event_type: "text", content: "hi")
      assert pending.approval_pending?
      assert_equal [ pending ], @session.messages.gated.to_a
    end

    test "answered (custom gate) is a valid status, prefixed predicate, and counts as gated" do
      row = @session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "t3",
                                      approval_status: "answered", payload: { "name" => "ask_user" })
      assert row.approval_answered?
      refute row.approval_pending?
      assert_includes @session.messages.gated, row
    end

    test "user_message threads agent rows to the turn lead" do
      lead = @session.messages.create!(role: "user", event_type: "text", content: "do it")
      reply = @session.messages.create!(role: "assistant", event_type: "text", content: "done",
                                        user_message: lead)
      assert_equal lead, reply.user_message
      assert_includes lead.turn_replies, reply
    end

    # Every tool answers with the envelope {"data" => {…}}. Reading payload["result"]["x"] by hand
    # misses by a level and returns nil FOREVER — which is what made the validate_step card fall back
    # to the next, not-yet-done step's title on every render. One accessor owns the shape.
    test "tool_result_data unwraps the tool envelope's data (not the raw result)" do
      session = rbrun_session(tenant: "acme")
      session.messages.create!(role: "user", event_type: "text", content: "go")
      call = session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "v1",
                                      approval_status: "approved", payload: { "name" => "validate_step" })
      session.messages.create!(role: "assistant", event_type: "tool_result", tool_use_id: "v1",
                               payload: { "result" => { "data" => { "step" => "Step one" } } })

      assert_equal "Step one", call.tool_result_data["step"]
      refute_nil call.tool_result_data["step"], "the envelope must not be read one level too shallow"
    end

    test "tool_result_data is an empty hash while the call is still pending" do
      session = rbrun_session(tenant: "acme")
      call = session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "v2",
                                      approval_status: "pending", payload: { "name" => "validate_step" })
      assert_equal({}, call.tool_result_data)
    end
  end
end
