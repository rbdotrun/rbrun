require "test_helper"

module Rbrun
  class ServicesPanelTest < ActionDispatch::IntegrationTest
    setup do
      @prev_domain = Rbrun.config.preview_domain
      Rbrun.config.preview_domain = "rb.run"
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @session  = @worktree.sessions.create!
      post "/rbrun/repos/switch", params: { repo: "a/b", base: "main" }
    end

    teardown { Rbrun.config.preview_domain = @prev_domain }

    # Mark a service previewed (per worktree), resolving its upstream, like the launcher does.
    def preview!(run, shared: false)
      exp = @worktree.service_exposures.create!(name: run.name, previewed: true, shared_public: shared)
      exp.ensure_preview_token!
      exp
    end

    test "the conversation page shows the worktree stream + panel; a PREVIEWED service has Open" do
      web = @worktree.service_runs.create!(name: "web", command: "x", port: 3000,
                                           url: "http://localhost:3000", status: "running")
      @worktree.service_runs.create!(name: "worker", command: "y", status: "running")
      exp = preview!(web)

      get "/rbrun/c/#{@session.id}"
      assert_response :success
      assert_select "turbo-cable-stream-source", 2
      assert_select "#services_panel_#{@worktree.id}"
      # Open links to the engine's OWN edge (external host), not a controller path.
      assert_select "a[href=?][target=_blank]", exp.preview_url
      assert_select "a[href*=?]", "worker-preview", false # the worker is not previewed
    end

    test "Share publicly is offered ONLY once previewed, and public state is shown loudly" do
      run = @worktree.service_runs.create!(name: "web", command: "x", port: 3000, status: "running")

      # level 1 only — no share button at all
      get "/rbrun/c/#{@session.id}"
      assert_select "form[action=?]", "/rbrun/services/#{run.id}/share_public", false

      # level 2 — previewed, so it is offered
      exp = preview!(run)
      run.update!(url: "http://localhost:3000")
      get "/rbrun/c/#{@session.id}"
      assert_select "form[action=?]", "/rbrun/services/#{run.id}/share_public"

      # level 3 — the action flips to revoke
      exp.update!(shared_public: true)
      get "/rbrun/c/#{@session.id}"
      assert_select "form[action=?]", "/rbrun/services/#{run.id}/stop_sharing"
      assert_select "form[action=?]", "/rbrun/services/#{run.id}/share_public", false
    end

    test "share_public refuses a service that is not previewed" do
      run = @worktree.service_runs.create!(name: "web", command: "x", port: 3000, status: "running")
      post "/rbrun/services/#{run.id}/share_public"
      refute Rbrun::ServiceLauncher.new(worktree: @worktree).shared?("web"), "public requires previewed"
    end

    test "no worktree in context → no panel" do
      get "/rbrun/c" # index, no @session
      assert_response :success
      assert_select "[id^=services_panel_]", false
    end

    test "open redirects to the engine's edge url; stop delegates to the launcher" do
      run = @worktree.service_runs.create!(name: "web", command: "x", port: 3000, url: "http://localhost:3000", status: "running")
      exp = preview!(run)
      get "/rbrun/services/#{run.id}/open"
      assert_redirected_to exp.preview_url

      post "/rbrun/services/#{run.id}/stop"
      assert_response :no_content
      assert @worktree.service_runs.find_by(name: "web").status_stopped?
    end

    test "logs opens the drawer with the service pane" do
      run = @worktree.service_runs.create!(name: "web", command: "x", status: "running",
                                           process_session: "svc-x", cmd_id: "c1")
      # no live sandbox process → tail returns "" quickly; the drawer still renders.
      get "/rbrun/services/#{run.id}/logs", headers: { "Accept" => "text/vnd.turbo-stream.html" }
      assert_response :success
      assert_select "turbo-stream[target=service_drawer]"
    end
  end
end
