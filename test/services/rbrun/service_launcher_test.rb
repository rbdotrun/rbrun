require "test_helper"

module Rbrun
  # Real Local sandbox + real processes — no fakes. Local implements preview_url as localhost, so the
  # preview facet is exercised offline.
  class ServiceLauncherTest < ActiveSupport::TestCase
    setup do
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @launcher = Rbrun::ServiceLauncher.new(worktree: @worktree)
    end

    teardown { @worktree.sandbox.destroy! }

    def start!
      @launcher.start([
        { "name" => "web",    "command" => "sh -c 'sleep 30'", "port" => 4321 },
        { "name" => "worker", "command" => "sh -c 'sleep 30'" }
      ])
    end

    test "start launches the set, resolves the HTTP preview, and saves the definitions" do
      start!
      runs = @worktree.service_runs.order(:name)
      assert_equal %w[web worker], runs.map(&:name)
      assert runs.all?(&:status_running?)

      # STARTING NEVER EXPOSES — a port is only what the process binds to inside the box.
      web = runs.find { |r| r.name == "web" }
      refute web.previewable?, "start must not resolve a preview"
      assert_nil web.url
      refute runs.find { |r| r.name == "worker" }.previewable?, "no port ⇒ not previewable"

      saved = Rbrun::RepoService.for_tenant("rbrun").for_repo("a/b")
      assert_equal %w[web worker], saved.map(&:name)
    end

    test "preview is a separate, declarative decision — and survives a restart" do
      start!
      web = @worktree.service_runs.find_by(name: "web")
      refute web.previewable?

      @launcher.preview("web")
      assert web.reload.previewable?
      assert_equal "http://localhost:4321", web.url
      assert Rbrun::RepoService.for_tenant("rbrun").for_repo("a/b").find_by(name: "web").previewed?

      # the declaration lives on the DEFINITION, so a reset-and-relaunch keeps it previewed
      start!
      assert @worktree.service_runs.find_by(name: "web").previewable?, "preview declaration survives a restart"

      @launcher.stop_preview("web")
      refute @worktree.service_runs.find_by(name: "web").previewable?
      refute Rbrun::RepoService.for_tenant("rbrun").for_repo("a/b").find_by(name: "web").previewed?

      # and once withdrawn, a restart does NOT re-expose it
      start!
      refute @worktree.service_runs.find_by(name: "web").previewable?
    end

    test "public STRICTLY requires previewed — and stop_preview revokes the share" do
      start!
      # level 3 is refused while only level 1 holds
      assert_equal :not_previewed, @launcher.share_public("web")
      refute @launcher.shared?("web")

      @launcher.preview("web")
      @launcher.share_public("web")
      assert @launcher.shared?("web")
      @launcher.share_public("web")
      assert @launcher.shared?("web"), "sharing twice is idempotent"

      # withdrawing level 2 must cascade — (public && !previewed) is unreachable
      @launcher.stop_preview("web")
      refute @launcher.shared?("web"), "stop_preview revokes the public share"
    end

    test "stop_sharing revokes without touching the service or its preview" do
      start!
      @launcher.preview("web")
      @launcher.share_public("web")
      @launcher.stop_sharing("web")

      refute @launcher.shared?("web")
      assert @worktree.service_runs.find_by(name: "web").previewable?, "still previewed"
      assert @worktree.service_runs.find_by(name: "web").status_running?, "still running"
    end

    test "share_public refuses a service that is not running, and an unknown one" do
      start!
      assert_equal :unknown, @launcher.share_public("nope")
      @launcher.preview("web")
      @launcher.stop(name: "web")
      assert_equal :not_running, @launcher.share_public("web")
    end

    test "preview refuses a service with no port, and an unknown service" do
      start!
      assert_equal :no_port, @launcher.preview("worker")
      assert_equal :unknown, @launcher.preview("nope")
    end

    test "start is idempotent — a second start does not duplicate runs" do
      start!
      assert_no_difference("Rbrun::ServiceRun.where(worktree_id: #{@worktree.id}).count") { start! }
      assert_equal 1, @worktree.service_runs.where(name: "web").count
    end

    test "restart keeps a single run; stop flips it stopped" do
      start!
      @launcher.restart("web")
      assert_equal 1, @worktree.service_runs.where(name: "web").count
      @launcher.stop(name: "web")
      assert @worktree.service_runs.find_by(name: "web").status_stopped?
    end

    test "restart_saved re-launches the repo's saved services in a fresh run" do
      start!
      @launcher.stop
      @worktree.service_runs.destroy_all
      @launcher.restart_saved
      assert_equal %w[web worker], @worktree.service_runs.order(:name).map(&:name)
    end
  end
end
