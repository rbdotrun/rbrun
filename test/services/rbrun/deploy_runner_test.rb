# frozen_string_literal: true

require "test_helper"

module Rbrun
  class DeployRunnerTest < ActiveSupport::TestCase
    setup do
      @wt = Worktree.create!(tenant: "acme", repo: "acme/webapp", base: "main")
      @wt.create_deploy_target!(provider: "kamal_hetzner", server_type: "cx23", region: "fsn1",
                                image: "ubuntu-24.04", host: "w.rb.run", server_ip: "9.9.9.9", status: "provisioned")
    end

    # A fake server adapter (injected — no global stubbing).
    def fake_server(ok:, output:)
      srv = Object.new
      srv.define_singleton_method(:deploy) { |work_dir:, host:, server_ip:| Rbrun::Server::DeployResult.new(ok: ok, output: output) }
      srv
    end

    def runner_with(server)
      r = DeployRunner.new(worktree: @wt, server: server)
      r.define_singleton_method(:with_checkout) { |&blk| blk.call("/tmp/x", "abc123def4567") }
      r
    end

    test "run! deploys and records deployed state (status/sha/tag/log)" do
      assert runner_with(fake_server(ok: true, output: "built + deployed ok")).run!.ok
      t = @wt.reload.deploy_target
      assert_equal "deployed", t.status
      assert_equal "abc123def4567", t.deployed_sha
      assert_equal "abc123def456", t.deploy_tag
      assert_includes t.last_deploy_log, "deployed ok"
    end

    test "run! records failed status when the deploy fails" do
      refute runner_with(fake_server(ok: false, output: "boom")).run!.ok
      assert_equal "failed", @wt.reload.deploy_target.status
    end

    test "run! refuses when the server is not provisioned" do
      @wt.deploy_target.update!(server_ip: nil)
      assert_raises(ArgumentError) { DeployRunner.new(worktree: @wt).run! }
    end
  end
end
