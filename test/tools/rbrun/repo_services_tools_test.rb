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
      # STARTING NEVER EXPOSES: a port is only what the process binds to inside the box.
      assert_nil res.dig("data", "services", 0, "url"), "start must not resolve a preview"
      assert @worktree.service_runs.find_by(name: "web").status_running?

      # Previewing is a separate, explicit decision — the URL is the engine's own edge host.
      Rbrun.config.preview_domain = "rb.run"
      preview = tool(Rbrun::Tools::PreviewService).execute(name: "web")
      assert_match %r{\Ahttps://\w+-preview\.rb\.run\z}, preview.dig("data", "url")
      assert preview.dig("data", "previewed")
      assert_equal "http://localhost:4322", @worktree.service_runs.find_by(name: "web").url, "upstream on the run"

      stopped = tool(Rbrun::Tools::StopPreview).execute(name: "web")
      refute stopped.dig("data", "previewed")
      assert_nil @worktree.service_runs.find_by(name: "web").url
    ensure
      Rbrun.config.preview_domain = nil

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
