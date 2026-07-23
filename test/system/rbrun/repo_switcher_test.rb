require "application_system_test_case"

module Rbrun
  class RepoSwitcherTest < ApplicationSystemTestCase
    # A DI fake for the repo directory — returns fixed repos, records the query. No network.
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
      # Sign in through the real login form so the session cookie is set in the browser.
      visit "/rbrun/login"
      fill_in "email", with: "dev@rbrun.test"
      fill_in "password", with: "password"
      click_button "Sign in"
    end

    teardown { Rbrun.github_repos = nil }

    test "opening the switcher lazy-loads repos, filters, and picks one" do
      visit "/rbrun/c"

      # The trigger is present; the dialog is not open yet.
      assert_selector "#repo_switcher a"
      assert_no_selector "dialog[open]"

      # Open the dialog — the shell paints instantly, the lazy frame streams the rows in.
      find("#repo_switcher a").click
      assert_selector "dialog[open]"
      assert_selector "dialog[open] h2", text: "Switch repository"
      assert_selector "turbo-frame#repo_results a[role=menuitem]", text: "rbdotrun/rbrun"
      assert_selector "turbo-frame#repo_results a[role=menuitem]", text: "acme/api"

      # Typing narrows the server-side list.
      fill_in "q", with: "acme"
      assert_selector "turbo-frame#repo_results a[role=menuitem]", text: "acme/api"
      assert_no_selector "turbo-frame#repo_results a[role=menuitem]", text: "rbdotrun/rbrun"

      # Picking a repo full-navigates and updates the trigger face.
      find("a[role=menuitem]", text: "acme/api").click
      assert_no_selector "dialog[open]"
      assert_selector "#repo_label", text: "acme/api"
    end
  end
end
