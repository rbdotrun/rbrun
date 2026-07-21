# frozen_string_literal: true

require "test_helper"

module Rbrun
  class DeployKeysTest < ActiveSupport::TestCase
    setup do
      @wt = Worktree.create!(tenant: "acme", repo: "a/b")
      @target = @wt.create_deploy_target!(provider: "kamal_hetzner", server_type: "cx23", region: "fsn1",
                                          image: "ubuntu-24.04", host: "w.rb.run", status: "pending")
    end

    test "ensure! generates + stores a keypair we own" do
      pub, priv = DeployKeys.ensure!(@target)
      assert_match(/\Assh-rsa /, pub)
      assert_includes priv, "PRIVATE KEY"
      assert_equal pub, @target.reload.ssh_public_key
    end

    test "ensure! is idempotent — never rotates a stored key" do
      pub, priv = DeployKeys.ensure!(@target)
      pub2, priv2 = DeployKeys.ensure!(@target.reload)
      assert_equal pub, pub2
      assert_equal priv, priv2
    end
  end
end
