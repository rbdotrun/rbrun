require "test_helper"

module Rbrun
  class PublicShareTest < ActiveSupport::TestCase
    setup { @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b") }

    test "mints an opaque token and inherits the worktree tenant" do
      share = @worktree.public_shares.create!(name: "web")
      assert share.token.present?
      assert_operator share.token.length, :>=, 32, "token must be long/unguessable"
      assert_equal "rbrun", share.tenant
    end

    test "re-sharing after a revoke mints a NEW token (the old link is dead)" do
      first = @worktree.public_shares.create!(name: "web").token
      @worktree.public_shares.where(name: "web").destroy_all
      second = @worktree.public_shares.create!(name: "web").token
      refute_equal first, second
    end

    test "unique per [worktree, name] and globally unique per token" do
      @worktree.public_shares.create!(name: "web")
      assert_raises(ActiveRecord::RecordNotUnique) { @worktree.public_shares.create!(name: "web") }
    end

    test "service_run resolves the live run, nil when the service is not running" do
      share = @worktree.public_shares.create!(name: "web")
      assert_nil share.service_run
      run = @worktree.service_runs.create!(name: "web", command: "x", port: 3000)
      assert_equal run, share.reload.service_run
    end

    test "destroying the worktree destroys its shares" do
      @worktree.public_shares.create!(name: "web")
      assert_difference("Rbrun::PublicShare.count", -1) { @worktree.destroy }
    end
  end
end
