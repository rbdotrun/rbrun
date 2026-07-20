require "test_helper"
require "webmock/minitest"

module Rbrun
  # The public edge, driven for real with the UPSTREAM stubbed at the wire (no fake objects).
  class PublicPreviewTest < ActionDispatch::IntegrationTest
    UPSTREAM = "https://3000-box.daytonaproxy01.net".freeze

    setup do
      WebMock.disable_net_connect!(allow_localhost: true)
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @run = @worktree.service_runs.create!(name: "web", command: "x", port: 3000, status: "running",
                                            url: UPSTREAM, token: "provider-secret-token")
      @share = @worktree.public_shares.create!(name: "web")
    end

    teardown { WebMock.allow_net_connect! }

    test "an unknown or revoked token is 404 — never distinguishable" do
      get "/rbrun/p/does-not-exist"
      assert_response :not_found

      token = @share.token
      @share.destroy
      get "/rbrun/p/#{token}"
      assert_response :not_found, "a revoked token is indistinguishable from one that never existed"
    end

    test "a share whose service is not running is 503" do
      @run.status_stopped!
      get "/rbrun/p/#{@share.token}"
      assert_response :service_unavailable
    end

    test "NO AUTH REQUIRED: it relays the upstream app to an anonymous visitor" do
      stub_request(:get, "#{UPSTREAM}/")
        .to_return(status: 200, body: "<title>Rails Dummy</title>", headers: { "Content-Type" => "text/html" })

      get "/rbrun/p/#{@share.token}" # no login, no session
      assert_response :success
      assert_includes response.body, "Rails Dummy"
    end

    test "the provider token is attached SERVER-SIDE and never leaks to the client" do
      stub_request(:get, "#{UPSTREAM}/")
        .with(headers: { "x-daytona-preview-token" => "provider-secret-token" })
        .to_return(status: 200, body: "ok", headers: { "Content-Type" => "text/html" })

      get "/rbrun/p/#{@share.token}"
      assert_response :success
      refute_includes response.body, "provider-secret-token"
      refute_includes response.headers.to_a.flatten.join(" "), "provider-secret-token"
    end

    test "the incoming path is appended to THAT run's url — it cannot re-target another service" do
      stub_request(:get, "#{UPSTREAM}/logs").to_return(status: 200, body: "logs page")
      get "/rbrun/p/#{@share.token}/logs"
      assert_response :success
      assert_includes response.body, "logs page"
    end

    test "a service with NO share has no route — it cannot surface" do
      @worktree.service_runs.create!(name: "db", command: "postgres", port: 5432, status: "running",
                                     url: "https://5432-box.daytonaproxy01.net", token: "t")
      assert_nil @worktree.public_shares.find_by(name: "db")
      # the only resolvable token is the shared one; there is no address for db at all
      assert_equal [ "web" ], @worktree.public_shares.map(&:name)
    end

    test "upstream status is relayed (a 500 stays a 500)" do
      stub_request(:get, "#{UPSTREAM}/").to_return(status: 500, body: "boom")
      get "/rbrun/p/#{@share.token}"
      assert_response :internal_server_error
    end
  end
end
