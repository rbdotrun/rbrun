# frozen_string_literal: true

require "test_helper"

module Rbrun
  class DeployToolsTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @wt = Worktree.create!(tenant: "acme", repo: "acme/webapp", base: "main")
      @session = @wt.sessions.create!
    end

    def target!(**over)
      @wt.create_deploy_target!({ provider: "kamal_hetzner", server_type: "cx23", region: "fsn1",
                                  image: "ubuntu-24.04", host: "w.rb.run", status: "pending" }.merge(over))
    end

    # minitest 6 dropped minitest/mock, so override the Rbrun singleton method by hand and restore it.
    def with_rbrun(method, fake)
      original = Rbrun.method(method)
      Rbrun.define_singleton_method(method) { |*_a, **_k| fake }
      yield
    ensure
      Rbrun.define_singleton_method(method, original)
    end

    def fake(method, &blk)
      o = Object.new
      o.define_singleton_method(method, &blk)
      o
    end

    test "deploy is gated" do
      assert Rbrun::Tools::Deploy.needs_approval?
    end

    test "deploy_config hands the agent the exact image, registry, and ssh (no guessing)" do
      Rbrun.config.server_provider = { default: :kamal_hetzner,
                                       kamal_hetzner: { registry: { server: "docker.io", username: "acme" } } }
      data = Rbrun::Tools::DeployConfig.in_session(@session).execute["data"]
      assert_equal "docker.io", data["registry_server"]
      assert_equal "acme", data["registry_username"]
      assert_equal "rbrun-w#{@wt.id}", data["service"]
      assert_equal "acme/rbrun-w#{@wt.id}", data["image"]
      assert_equal "deploy", data["ssh_user"]
      assert_includes data["deploy_yml_ssh"], "user: deploy"
    end

    # The tool's whole purpose is "hand the agent the EXACT infra values so it never guesses" — so it
    # must not guess either. It used to report docker.io for a missing registry, and the agent wrote
    # that literally into deploy.yml: kamal then pushed to Docker Hub with (say) GHCR credentials and
    # failed deep in the build. A missing image ref also degraded to "/rbrun-w7" (leading slash).
    test "deploy_config REFUSES when no registry is configured — it never reports docker.io" do
      Rbrun.config.server_provider = { default: :kamal_hetzner, kamal_hetzner: {} }
      out = Rbrun::Tools::DeployConfig.in_session(@session).execute
      assert_match(/registry/i, out["error"].to_s)
      refute_includes out.to_s, "docker.io"
      assert_nil out["data"]
    end

    test "deploy_config REFUSES when no server provider is configured at all" do
      Rbrun.config.server_provider = {}
      out = Rbrun::Tools::DeployConfig.in_session(@session).execute
      assert_match(/server provider/i, out["error"].to_s)
    end

    test "deploy_config refuses a registry with no username (image would be a bare /service)" do
      Rbrun.config.server_provider = { default: :kamal_hetzner,
                                       kamal_hetzner: { registry: { server: "ghcr.io" } } }
      out = Rbrun::Tools::DeployConfig.in_session(@session).execute
      assert_match(/registry/i, out["error"].to_s)
      refute_match(%r{"/rbrun-w}, out.to_s)
    end

    test "list_deploy_secrets returns stored NAMES (never values) + the infra env the engine injects" do
      Rbrun::RepoSecret.create!(tenant: "acme", repo: "acme/webapp", key: "RAILS_MASTER_KEY", value: "topsecret")
      Rbrun::RepoSecret.create!(tenant: "acme", repo: "acme/webapp", key: "POSTGRES_PASSWORD", value: "pw")
      Rbrun::RepoSecret.create!(tenant: "acme", repo: "other/repo",  key: "LEAK", value: "no")

      data = Rbrun::Tools::ListDeploySecrets.in_session(@session).execute["data"]
      assert_equal %w[POSTGRES_PASSWORD RAILS_MASTER_KEY], data["stored_secrets"] # this repo only, sorted
      assert_includes data["infra_injected"], "KAMAL_SERVER_IP"
      # Never leak a value, anywhere in the payload.
      refute_includes data.to_s, "topsecret"
      refute_includes data.to_s, "LEAK"
    end

    test "deploy_status reports none, then the live url + tag after deploy" do
      assert_equal "none", Rbrun::Tools::DeployStatus.in_session(@session).execute.dig("data", "status")
      target!(server_ip: "9.9.9.9", status: "deployed", deploy_tag: "v1", deployed_sha: "abc")
      data = Rbrun::Tools::DeployStatus.in_session(@session).execute["data"]
      assert_equal "https://w.rb.run", data["url"]
      assert_equal "v1", data["deploy_tag"]
    end

    test "provision_server creates the box and records the ip on the target" do
      Rbrun.config.preview_domain = "rb.run" # the deploy host is built on it — provisioning is gated on it
      srv = fake(:create_server) { |**| Rbrun::Server::Node.new(id: 7, name: "n", ip: "5.5.5.5", status: "running", region: "fsn1") }
      with_rbrun(:server, srv) do
        data = Rbrun::Tools::ProvisionServer.in_session(@session).execute["data"]
        assert_equal "5.5.5.5", data["server_ip"]
      end
      assert_equal "5.5.5.5", @wt.reload.deploy_target.server_ip
    end

    test "create_deploy_dns upserts an A record at the server ip" do
      target!(server_ip: "9.9.9.9", status: "provisioned")
      rec = Struct.new(:name, :content).new("w.rb.run", "9.9.9.9")
      dns = fake(:upsert) { |name:, type:, content:| rec }
      with_rbrun(:dns, dns) do
        data = Rbrun::Tools::CreateDeployDns.in_session(@session).execute["data"]
        assert_equal "w.rb.run", data["host"]
        assert_equal "9.9.9.9", data["ip"]
      end
    end

    # Temporarily override a class method (no minitest/mock in minitest 6).
    def with_branch_pushed(pushed)
      original = Rbrun::DeployRunner.method(:branch_pushed?)
      Rbrun::DeployRunner.define_singleton_method(:branch_pushed?) { |_wt| pushed }
      yield
    ensure
      Rbrun::DeployRunner.define_singleton_method(:branch_pushed?, original)
    end

    test "deploy enqueues DeployJob and marks deploying when the branch is pushed" do
      target!(server_ip: "9.9.9.9", status: "provisioned")
      with_branch_pushed(true) do
        assert_enqueued_with(job: Rbrun::DeployJob, args: [ @wt.id ]) do
          data = Rbrun::Tools::Deploy.in_session(@session).execute["data"]
          assert_equal "deploying", data["status"]
        end
      end
      assert_equal "deploying", @wt.reload.deploy_target.status
    end

    test "deploy refuses when the branch is not committed + pushed" do
      target!(server_ip: "9.9.9.9", status: "provisioned")
      with_branch_pushed(false) do
        assert_match(/commit \+ push/, Rbrun::Tools::Deploy.in_session(@session).execute["error"].to_s)
      end
    end

    test "teardown_deploy destroys the server + removes dns and marks torn_down" do
      target!(server_ip: "9.9.9.9", status: "deployed")
      destroyed = []
      removed = []
      srv = fake(:destroy_server) { |name:| destroyed << name; true }
      dns = fake(:remove) { |name:, type:| removed << name; true }
      with_rbrun(:server, srv) do
        with_rbrun(:dns, dns) do
          Rbrun::Tools::TeardownDeploy.in_session(@session).execute
        end
      end
      assert_equal [ "rbrun-w#{@wt.id}" ], destroyed
      assert_equal [ "w.rb.run" ], removed
      assert_equal "torn_down", @wt.reload.deploy_target.status
    end

    test "tools error cleanly before a target/server exists" do
      assert_match(/provision/, Rbrun::Tools::CreateDeployDns.in_session(@session).execute["error"].to_s)
      assert_match(/provision/, Rbrun::Tools::Deploy.in_session(@session).execute["error"].to_s)
    end
  end
end
