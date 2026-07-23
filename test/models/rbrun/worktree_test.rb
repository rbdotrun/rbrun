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

    test "checkout is a repo-named SUBDIR of the workspace (sibling of .claude), not the workspace" do
      wt = Worktree.create!(tenant: "acme", repo: "acme/webapp")
      assert_equal File.join(wt.sandbox.workspace, "webapp"), wt.checkout
      refute_equal wt.sandbox.workspace, wt.checkout, "the checkout must not be the workspace root (that's where .claude lives)"
    ensure
      wt&.sandbox&.destroy!
    end

    test "a bare worktree has no checkout subdir and provision! is a no-op" do
      wt = Worktree.create!(tenant: "acme", repo: "rbrun/skills", bare: true)
      assert_equal wt.sandbox.workspace, wt.checkout
      assert_same wt, wt.provision! # no clone, no raise
    ensure
      wt&.sandbox&.destroy!
    end

    test "provision! clones into the checkout subdir (not the workspace root, so .claude survives)" do
      Rbrun.config.github_pat = "ghp_TOKEN"
      wt = Worktree.create!(tenant: "acme", repo: "acme/webapp")
      cmd = wt.provision_command
      assert_includes cmd, "cd #{wt.checkout}", "clone target must be the checkout subdir"
      assert_includes cmd, "mkdir -p #{wt.checkout}"
    ensure
      wt&.sandbox&.destroy!
    end

    test "provision! RAISES on a worktree with no repo — never a silent bare box" do
      wt = Worktree.create!(tenant: "acme", repo: "acme/webapp")
      wt.update_columns(repo: "")
      assert_raises(Rbrun::Worktree::Error) { wt.provision! }
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
