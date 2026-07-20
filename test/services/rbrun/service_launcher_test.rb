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

      web = runs.find { |r| r.name == "web" }
      assert web.previewable?
      assert_equal "http://localhost:4321", web.url
      refute runs.find { |r| r.name == "worker" }.previewable?, "no port ⇒ not previewable"

      saved = Rbrun::RepoService.for_tenant("rbrun").for_repo("a/b")
      assert_equal %w[web worker], saved.map(&:name)
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
