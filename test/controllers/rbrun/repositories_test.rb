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

    test "index renders the results frame with the searched repos" do
      get "/rbrun/repos", params: { q: "rb" }
      assert_response :success
      assert_equal "rb", @fake.last_query
      assert_select "turbo-frame#repo_results"
      assert_select "a", text: /rbdotrun\/rbrun/
      assert_select "a", text: /acme\/api/
    end

    test "switch sets the session repo and redirects to the conversation index" do
      post "/rbrun/repos/switch", params: { repo: "acme/api" }
      assert_redirected_to "/rbrun/c"

      # The session now carries the repo — it's the active one in the results frame.
      get "/rbrun/repos"
      assert_select "a[aria-current=?]", "true", text: /acme\/api/
    end

    test "the current repo is marked active in the results" do
      post "/rbrun/repos/switch", params: { repo: "rbdotrun/rbrun" }
      get "/rbrun/repos"
      assert_select "a[aria-current=?]", "true", text: /rbdotrun\/rbrun/
    end

    test "switching with a blank repo clears the workspace" do
      post "/rbrun/repos/switch", params: { repo: "acme/api" }
      post "/rbrun/repos/switch", params: { repo: "" }
      get "/rbrun/repos"
      # Nothing is active — the workspace is cleared.
      assert_select "a[aria-current=?]", "true", count: 0
    end
  end
end
