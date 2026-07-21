# frozen_string_literal: true

require "test_helper"

module Rbrun
  class DeployScaffoldTest < ActiveSupport::TestCase
    test "renders deploy.yml with service, host, registry image and local builder" do
      wt = Worktree.create!(tenant: "acme", repo: "a/b")
      target = wt.create_deploy_target!(provider: "kamal_hetzner", server_type: "cx23", region: "fsn1",
                                        image: "ubuntu-24.04", host: "w.rb.run", status: "pending")
      Rbrun.config.server_provider = { default: :kamal_hetzner,
                                       kamal_hetzner: { registry: { server: "docker.io", username: "nvoi" } } }

      yml = DeployScaffold.new(wt, target).deploy_yml
      assert_includes yml, "service: rbrun-w#{wt.id}"
      assert_includes yml, "host: w.rb.run"
      assert_includes yml, "nvoi/rbrun-w#{wt.id}"
      assert_includes yml, "arch: amd64"
    ensure
      wt&.sandbox&.destroy!
    end
  end
end
