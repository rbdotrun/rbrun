require "test_helper"

module Rbrun
  class ServiceRunTest < ActiveSupport::TestCase
    setup { @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b") }

    test "inherits the worktree tenant on create" do
      run = @worktree.service_runs.create!(name: "web", command: "x")
      assert_equal "rbrun", run.tenant
    end

    test "status enum is prefixed and defaults to starting" do
      run = @worktree.service_runs.create!(name: "web", command: "x")
      assert run.status_starting?
      run.status_running!
      assert run.status_running?
    end

    test "previewable? only when it has a port and a resolved url" do
      run = @worktree.service_runs.create!(name: "web", command: "x", port: 3000)
      refute run.previewable?, "no url yet"
      run.update!(url: "http://localhost:3000")
      assert run.previewable?
      worker = @worktree.service_runs.create!(name: "worker", command: "y")
      refute worker.previewable?
    end

    test "unique per [worktree, name]" do
      @worktree.service_runs.create!(name: "web", command: "x")
      assert_raises(ActiveRecord::RecordNotUnique) { @worktree.service_runs.create!(name: "web", command: "y") }
    end
  end
end
