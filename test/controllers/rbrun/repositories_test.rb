require "test_helper"

module Rbrun
  class RepositoriesTest < ActionDispatch::IntegrationTest
    # A DI fake for the repo directory — records the last query, returns fixed repos. No network.
    class FakeRepos
      Repo = Struct.new(:full_name, :default_branch, :private)
      attr_reader :last_query

      def initialize(repos) = @repos = repos
      def search(query:)
        @last_query = query
        @repos
      end
    end

    setup do
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      @fake = FakeRepos.new([
        FakeRepos::Repo.new("rbdotrun/rbrun", "main", false),
        FakeRepos::Repo.new("acme/api", "develop", true)
      ])
      Rbrun.github_repos = @fake
    end

    teardown { Rbrun.github_repos = nil }

    test "the result rows are client-side picks — no switch href, each carries repo + base" do
      get "/rbrun/repos", params: { q: "rb" }
      assert_response :success
      assert_equal "rb", @fake.last_query
      assert_select "turbo-frame#repo_results"
      assert_select "div[role=menu][data-controller~=?]", "repo-choices"
      assert_select "[role=menuitem]", minimum: 2
      assert_select "[role=menuitem][data-action*=?][data-repo=?][data-base=?]",
                    "repo-choices#pick", "rbdotrun/rbrun", "main"
      assert_select "[role=menuitem][data-repo=?][data-base=?]", "acme/api", "develop"
      # subtitle line carries the org (owner) segment
      assert_select "[role=menuitem] span", text: "rbdotrun"
      # the global switch path is gone
      assert_select "a[href*=?]", "repos/switch", count: 0
    end

    test "a request from the #modal frame renders the dialog shell without hitting GitHub" do
      get "/rbrun/repos", headers: { "Turbo-Frame" => "modal" }
      assert_response :success
      assert_nil @fake.last_query, "the shell must not call GithubRepos"
      assert_select "h2", text: "Switch repository"
      assert_select "input[data-command-target=?]", "input"
      assert_select "turbo-frame#repo_results[loading=?]", "lazy"
      assert_select "turbo-frame#repo_results[src]"
    end

    test "a request from the #repo_results frame renders the GitHub rows" do
      get "/rbrun/repos", params: { q: "rb" }, headers: { "Turbo-Frame" => "repo_results" }
      assert_response :success
      assert_equal "rb", @fake.last_query
      assert_select "turbo-frame#repo_results"
    end
  end
end
