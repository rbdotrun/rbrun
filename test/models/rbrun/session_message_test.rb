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

    test "user_message threads agent rows to the turn lead" do
      lead = @session.messages.create!(role: "user", event_type: "text", content: "do it")
      reply = @session.messages.create!(role: "assistant", event_type: "text", content: "done",
                                        user_message: lead)
      assert_equal lead, reply.user_message
      assert_includes lead.turn_replies, reply
    end
  end
end
