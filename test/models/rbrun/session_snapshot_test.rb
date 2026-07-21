require "test_helper"

module Rbrun
  class SessionSnapshotTest < ActiveSupport::TestCase
    setup do
      @session = Rbrun::Worktree.create!(tenant: "acme", repo: "acme/app").sessions.create!
    end

    test "inherits the tenant from its session" do
      snap = Rbrun::SessionSnapshot.create!(session: @session, data: "x")
      assert_equal "acme", snap.tenant
    end

    test "requires data" do
      snap = Rbrun::SessionSnapshot.new(session: @session)
      assert_not snap.valid?
      assert_includes snap.errors[:data], "can't be blank"
    end

    test "is one-per-session (unique on the session)" do
      Rbrun::SessionSnapshot.create!(session: @session, data: "a")
      dup = Rbrun::SessionSnapshot.new(session: @session, tenant: "acme", data: "b")
      assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
    end

    test "destroyed with its session" do
      Rbrun::SessionSnapshot.create!(session: @session, data: "a")
      assert_difference("Rbrun::SessionSnapshot.count", -1) { @session.destroy }
    end
  end
end
