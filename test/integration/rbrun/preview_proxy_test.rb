require "test_helper"
require "webmock/minitest"

module Rbrun
  # The preview edge, driven for real through the middleware stack with the UPSTREAM stubbed at the wire.
  class PreviewProxyTest < ActionDispatch::IntegrationTest
    UPSTREAM = "https://3000-box.daytonaproxy01.net".freeze

    setup do
      WebMock.disable_net_connect!(allow_localhost: true)
      @prev_domain = Rbrun.config.preview_domain
      Rbrun.config.preview_domain = "rb.run"

      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @svc = Rbrun::RepoService.create!(tenant: "rbrun", repo: "a/b", name: "web", command: "x",
                                        port: 3000, previewed: true, shared_public: true)
      @token = @svc.ensure_preview_token!
      @run = @worktree.service_runs.create!(name: "web", command: "x", port: 3000, status: "running",
                                            url: UPSTREAM, token: "provider-secret")
      host! "#{@token}-preview.rb.run"
    end

    teardown do
      Rbrun.config.preview_domain = @prev_domain
      WebMock.allow_net_connect!
    end

    test "an unknown preview host is 404" do
      host! "nope-preview.rb.run"
      get "/"
      assert_response :not_found
    end

    test "a preview whose service is not running is 503" do
      @run.status_stopped!
      get "/"
      assert_response :service_unavailable
    end

    test "PUBLIC service: an anonymous request is relayed to the live app" do
      stub_request(:get, "#{UPSTREAM}/").to_return(status: 200, body: "<title>App</title>", headers: { "Content-Type" => "text/html" })
      get "/"
      assert_response :success
      assert_includes response.body, "App"
    end

    test "the provider token is attached SERVER-SIDE and never leaks to the client" do
      stub_request(:get, "#{UPSTREAM}/").with(headers: { "x-daytona-preview-token" => "provider-secret" })
        .to_return(status: 200, body: "ok")
      get "/"
      assert_response :success
      refute_includes response.body, "provider-secret"
      refute_includes response.headers.to_a.flatten.join(" "), "provider-secret"
    end

    test "the path is appended to THAT run's url (assets relay, cannot re-target)" do
      stub_request(:get, "#{UPSTREAM}/assets/app.css").to_return(status: 200, body: "css")
      get "/assets/app.css"
      assert_response :success
      assert_includes response.body, "css"
    end

    test "a PRIVATE (previewed, not shared) preview refuses an anonymous visitor" do
      @svc.update!(shared_public: false)
      get "/"
      assert_response :forbidden
      assert_includes response.body, "private"
    end

    test "upstream status is relayed (500 stays 500)" do
      stub_request(:get, "#{UPSTREAM}/").to_return(status: 500, body: "boom")
      get "/"
      assert_response :internal_server_error
    end

    test "a non-preview host passes straight through to the app" do
      host! "www.example.com"
      get "/"
      # whatever the app returns, it must NOT be the proxy's own responses.
      refute_includes response.body.to_s, "No such preview."
      refute_includes response.body.to_s, "This preview is not running."
    end
  end
end
