require "application_system_test_case"

module Rbrun
  # Repo selection now lives in the composer, not the sidebar: the root composer's RepoBadge opens the
  # (reused) switcher dialog; a pick is client-side (no POST) and fills the badge; starting the chat
  # mints a worktree for it and the badge locks.
  class RepoSwitcherTest < ApplicationSystemTestCase
    class FakeRepos
      Repo = Struct.new(:full_name, :default_branch, :private)
      attr_reader :last_query

      def initialize(repos) = @repos = repos
      def search(query:)
        @last_query = query
        return @repos if query.to_s.strip.empty?

        @repos.select { |r| r.full_name.include?(query) }
      end
    end

    setup do
      Rbrun.github_repos = FakeRepos.new([
        FakeRepos::Repo.new("rbdotrun/rbrun", "main", false),
        FakeRepos::Repo.new("acme/api", "develop", true)
      ])
      visit "/rbrun/login"
      fill_in "email", with: "dev@rbrun.test"
      fill_in "password", with: "password"
      click_button "Sign in"
    end

    teardown { Rbrun.github_repos = nil }

    test "pick a repo in the composer, start a chat, the repo locks" do
      visit "/rbrun/c"

      # The composer badge is the (only) entry — no sidebar switcher exists anymore.
      assert_no_selector "#repo_switcher"
      badge = find("[data-controller='repo-badge']")
      within(badge) { assert_text "Select a repository" }

      # Open the reused dialog; rows are client-side picks (menuitem divs, not switch links).
      badge.find("a[data-turbo-frame='modal']").click
      assert_selector "dialog[open] h2", text: "Switch repository"
      assert_selector "[role=menuitem]", text: "rbdotrun/rbrun"
      assert_selector "[role=menuitem]", text: "acme/api"

      # Typing narrows the list; pick acme/api → dialog closes, badge fills, ✕ appears.
      fill_in "q", with: "acme"
      assert_no_selector "[role=menuitem]", text: "rbdotrun/rbrun"
      find("[role=menuitem]", text: "acme/api").click
      assert_no_selector "dialog[open]"
      within("[data-controller='repo-badge']") do
        assert_text "acme/api"
        assert_selector "[data-repo-badge-target='clear']:not(.hidden)"
      end

      # Start the chat → lands in the conversation, bound to acme/api, badge now locked (no picker).
      fill_in "message[content]", with: "kick off"
      click_button "Start"
      assert_selector "#composer"
      assert_no_selector "[data-controller='repo-badge'] a[data-turbo-frame='modal']"
      assert_text "acme/api"

      # The worktree was minted off the repo's real default branch (develop), not a guessed "main".
      assert_equal "develop", Rbrun::Worktree.for_tenant("rbrun").order(:id).last.base
    end
  end
end
