require "test_helper"

module Rbrun
  class WorktreesFlowTest < ActionDispatch::IntegrationTest
    setup { post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" } }

    test "show lists the worktree's user sessions and excludes skill_scenario" do
      wt = Rbrun::Worktree.create!(tenant: "rbrun", repo: "acme/web")
      u  = wt.sessions.create!(kind: :user)
      m  = wt.sessions.create!(kind: :skill_scenario)
      get "/rbrun/worktrees/#{wt.id}"
      assert_response :success
      assert_select "a[href=?]", "/rbrun/c/#{u.id}"
      assert_select "a[href=?]", "/rbrun/c/#{m.id}", count: 0
    end

    test "a bare (no-repo) worktree titles as Scratch" do
      wt = Rbrun::Worktree.create!(tenant: "rbrun", repo: "", bare: true)
      get "/rbrun/worktrees/#{wt.id}"
      assert_response :success
      assert_select "h1", text: /Scratch/
    end

    test "a worktree is tenant-scoped (another tenant's is not found)" do
      other = Rbrun::Worktree.create!(tenant: "acme", repo: "acme/web")
      get "/rbrun/worktrees/#{other.id}"
      assert_response :not_found
    end
  end
end
