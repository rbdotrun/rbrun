require "test_helper"

module Rbrun
  class CommitRecordingTest < ActiveSupport::TestCase
    # A worktree whose sandbox reports two new commits between the before/after HEADs.
    class GitWorktree < Worktree
      self.table_name = "rbrun_worktrees"
      def head_sha = @heads.shift
      def sandbox = @fake ||= FakeSandbox.new
      def stub_heads(*shas) = @heads = shas
    end

    class FakeSandbox
      def workspace = "/ws"
      def exec(cmd, **)
        if cmd.include?("git log")
          Rbrun::Sandbox::ExecResult.new(exit_code: 0, stdout: "sha2\tsecond\nsha1\tfirst\n", stderr: "")
        else
          Rbrun::Sandbox::ExecResult.new(exit_code: 0, stdout: "", stderr: "")
        end
      end
    end

    class NoopRuntime
      def run(**) = { type: "result", stop_reason: "end_turn" }
    end

    test "run_turn records the commits made during the turn" do
      wt = GitWorktree.create!(tenant: "acme", repo: "a/b")
      wt.stub_heads("HEAD_BEFORE", "HEAD_AFTER") # head_sha called before, then after the turn
      session = Session.create!(worktree: wt)
      session.run_turn("edit and commit", runtime: NoopRuntime.new)
      assert_equal %w[sha1 sha2], wt.reload.commits.pluck(:sha).sort
      assert_equal session, wt.commits.first.session
    end

    test "a non-git sandbox records nothing and does not error" do
      session = rbrun_session
      session.run_turn("no git here", runtime: NoopRuntime.new)
      assert_equal 0, session.commits.count
      assert session.done?
    ensure
      session&.worktree&.sandbox&.destroy!
    end
  end
end
