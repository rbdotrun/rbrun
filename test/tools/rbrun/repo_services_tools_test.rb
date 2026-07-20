require "test_helper"

module Rbrun
  # Real Local sandbox — no fakes. The tools are exercised .in_session on a live worktree.
  class RepoServicesToolsTest < ActiveSupport::TestCase
    setup do
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @session  = @worktree.sessions.create!
    end

    teardown { @worktree.sandbox.destroy! }

    def tool(klass) = klass.in_session(@session)

    test "start launches + saves; only start needs approval in the manifest" do
      res = tool(Rbrun::Tools::RepoServicesStart).execute(services: [
        { "name" => "web", "command" => "sh -c 'sleep 30'", "port" => 4322 }
      ])
      assert_equal "web", res.dig("data", "services", 0, "name")
      assert_equal "running", res.dig("data", "services", 0, "status")
      assert_equal "http://localhost:4322", res.dig("data", "services", 0, "url")
      assert @worktree.service_runs.find_by(name: "web").status_running?

      manifest = Rbrun::ApplicationTool.manifest.index_by { |e| e["name"] }
      assert manifest["repo_services_start"]["needs_approval"]
      refute manifest["repo_services_status"]["needs_approval"]
      refute manifest["repo_services_logs"]["needs_approval"]
    end

    test "status reflects running services; logs returns output; stop stops" do
      tool(Rbrun::Tools::RepoServicesStart).execute(services: [
        { "name" => "web", "command" => "sh -c 'echo hello-logs; sleep 30'" }
      ])
      status = tool(Rbrun::Tools::RepoServicesStatus).execute.dig("data", "services")
      assert_equal [ "web" ], status.map { |s| s["name"] }

      # logs are a non-follow SNAPSHOT now — give the process a moment to actually write.
      sleep 0.5
      logs = tool(Rbrun::Tools::RepoServicesLogs).execute(name: "web").dig("data", "logs")
      assert_includes logs, "hello-logs"

      tool(Rbrun::Tools::RepoServicesStop).execute(name: "web")
      assert @worktree.service_runs.find_by(name: "web").status_stopped?
    end

    test "restart of an unknown service errors" do
      assert_includes tool(Rbrun::Tools::RepoServicesRestart).execute(name: "nope")["error"], "no such service"
    end
  end
end
