require "test_helper"

module Rbrun
  class GithubReposTest < ActiveSupport::TestCase
    # A Faraday connection on the test adapter — no network, no mocks (invariant: DI over stubbing).
    def conn_for(&stubs)
      stubbed = Faraday::Adapter::Test::Stubs.new(&stubs)
      Faraday.new do |f|
        f.response :json, content_type: /\bjson/
        f.adapter :test, stubbed
      end
    end

    test "list maps /user/repos into Repo structs, updated-first params sent" do
      conn = conn_for do |s|
        s.get("/user/repos") do |env|
          assert_equal "updated", env.params["sort"]
          assert_includes env.params["affiliation"], "owner"
          [ 200, { "Content-Type" => "application/json" },
            [ { "full_name" => "rbdotrun/rbrun", "default_branch" => "main", "private" => false },
              { "full_name" => "acme/api", "default_branch" => "develop", "private" => true } ].to_json ]
        end
      end

      repos = Rbrun::GithubRepos.new(pat: "x", conn:).list
      assert_equal %w[rbdotrun/rbrun acme/api], repos.map(&:full_name)
      assert_equal "develop", repos.last.default_branch
      assert repos.last.private
    end

    test "search hits /search/repositories and maps .items" do
      conn = conn_for do |s|
        s.get("/search/repositories") do |env|
          assert_equal "rb", env.params["q"]
          [ 200, { "Content-Type" => "application/json" },
            { "items" => [ { "full_name" => "rbdotrun/rbrun", "default_branch" => "main" } ] }.to_json ]
        end
      end

      repos = Rbrun::GithubRepos.new(pat: "x", conn:).search(query: "rb")
      assert_equal [ "rbdotrun/rbrun" ], repos.map(&:full_name)
    end

    test "a blank query lists instead of searching" do
      hit = { list: false }
      conn = conn_for do |s|
        s.get("/user/repos") { |_env| hit[:list] = true; [ 200, { "Content-Type" => "application/json" }, "[]" ] }
      end
      Rbrun::GithubRepos.new(pat: "x", conn:).search(query: "   ")
      assert hit[:list], "blank query should fall through to #list"
    end

    test "a missing pat fails fast" do
      assert_raises(ArgumentError) { Rbrun::GithubRepos.new(pat: "") }
    end

    test "a non-2xx response raises" do
      conn = conn_for { |s| s.get("/user/repos") { [ 401, {}, "bad creds" ] } }
      assert_raises(Rbrun::GithubRepos::Error) { Rbrun::GithubRepos.new(pat: "x", conn:).list }
    end
  end
end
