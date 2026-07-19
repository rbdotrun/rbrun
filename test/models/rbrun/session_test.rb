require "test_helper"

module Rbrun
  class SessionTest < ActiveSupport::TestCase
    test "defaults to idle and stores sdk_session_id" do
      s = rbrun_session(tenant: "acme")
      assert s.idle?
      s.update!(sdk_session_id: "sess-123")
      assert_equal "sess-123", s.reload.sdk_session_id
    end

    test "status transitions via the enum" do
      s = rbrun_session(tenant: "acme")
      s.working!
      assert s.working?
      s.needs_approval!
      assert s.needs_approval?
    end

    test "has_many messages ordered, dependent destroy" do
      s = rbrun_session(tenant: "acme")
      s.messages.create!(role: "user", event_type: "text", content: "hi")
      assert_equal 1, s.messages.count
      assert_difference("Rbrun::SessionMessage.count", -1) { s.destroy }
    end

    test "#sandbox resolves a local box from config" do
      s = rbrun_session(tenant: "acme")
      assert_instance_of Rbrun::Sandbox::Local, s.sandbox
    ensure
      s&.sandbox&.destroy!
    end
  end
end
