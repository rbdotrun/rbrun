# frozen_string_literal: true

require "test_helper"

module Rbrun
  class DeployTargetTest < ActiveSupport::TestCase
    setup { @worktree = Worktree.create!(tenant: "acme", repo: "acme/webapp", base: "main") }

    def attrs(**over)
      { provider: "kamal_hetzner", server_type: "cx23", region: "fsn1", image: "ubuntu-24.04",
        host: "w1.rb.run", status: "pending" }.merge(over)
    end

    test "inherits the worktree's tenant" do
      dt = @worktree.create_deploy_target!(attrs)
      assert_equal @worktree.tenant, dt.tenant
    end

    test "one target per worktree (unique)" do
      @worktree.create_deploy_target!(attrs)
      assert_raises(ActiveRecord::RecordNotUnique) do
        DeployTarget.create!(attrs(worktree: @worktree, host: "dup.rb.run"))
      end
    end

    test "rejects an unknown status" do
      assert_raises(ActiveRecord::RecordInvalid) { @worktree.create_deploy_target!(attrs(status: "bogus")) }
    end
  end
end
