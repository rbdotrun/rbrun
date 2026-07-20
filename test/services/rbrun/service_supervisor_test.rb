require "test_helper"

module Rbrun
  # Real Local sandbox (the test config uses :local), real processes — no fakes.
  class ServiceSupervisorTest < ActiveSupport::TestCase
    setup do
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @sup = Rbrun::ServiceSupervisor.new(worktree: @worktree)
    end

    teardown { @worktree.sandbox.destroy! }

    test "write_env! materializes the repo's secrets into a sandbox env file" do
      Rbrun::RepoSecret.create!(tenant: "rbrun", repo: "a/b", key: "MY_SECRET", value: "hunter2")
      @sup.write_env!
      assert @worktree.sandbox.exist?(".rbrun/env"), "env file written"
      assert_includes @worktree.sandbox.read(".rbrun/env"), "MY_SECRET"
    end

    test "launch runs the command under a managed session and records the handles" do
      run = @worktree.service_runs.create!(name: "web", command: "sh -c 'sleep 30'")
      @sup.launch(run)
      assert run.status_running?
      assert run.process_session.present?
      assert run.cmd_id.present?
    end

    test "refresh_status leaves a live process running, and no-ops a stopped one" do
      run = @worktree.service_runs.create!(name: "web", command: "sh -c 'sleep 30'")
      @sup.launch(run)
      assert @sup.refresh_status(run).status_running?

      @sup.stop(run)
      assert run.status_stopped?
      assert @sup.refresh_status(run).status_stopped?, "stopped run is not re-probed"
    end
  end
end
