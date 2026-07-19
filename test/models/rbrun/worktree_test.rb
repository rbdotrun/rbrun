require "test_helper"

module Rbrun
  class WorktreeTest < ActiveSupport::TestCase
    test "creating a worktree assigns a branch and is tenanted" do
      wt = Worktree.create!(tenant: "acme", repo: "acme/webapp", base: "main")
      assert_match(%r{\Arbrun/wt-[0-9a-f]+\z}, wt.branch)
      assert_includes Worktree.for_tenant("acme"), wt
    end

    test "#sandbox is labelled by the worktree and shared" do
      wt = Worktree.create!(tenant: "acme", repo: "a/b")
      assert_instance_of Rbrun::Sandbox::Local, wt.sandbox
      assert_same wt.sandbox, wt.sandbox
    ensure
      wt&.sandbox&.destroy!
    end

    test "provision_command clones the repo with the PAT and spins the branch off base" do
      Rbrun.config.github_pat = "ghp_TOKEN"
      wt = Worktree.create!(tenant: "acme", repo: "acme/webapp", base: "develop")
      cmd = wt.provision_command
      assert_includes cmd, "x-access-token:ghp_TOKEN@github.com/acme/webapp.git"
      assert_includes cmd, "checkout -B #{wt.branch}"
      assert_includes cmd, "develop"
    ensure
      wt&.sandbox&.destroy!
    end

    test "head_sha returns nil for a non-git sandbox (guarded)" do
      wt = Worktree.create!(tenant: "acme", repo: "a/b")
      assert_nil wt.head_sha
    ensure
      wt&.sandbox&.destroy!
    end

    test "commits belong to the worktree and are unique per sha" do
      wt = Worktree.create!(tenant: "acme", repo: "a/b")
      wt.commits.create!(sha: "abc", message: "one")
      assert_raises(ActiveRecord::RecordNotUnique) { wt.commits.create!(sha: "abc", message: "dup") }
    end
  end
end
