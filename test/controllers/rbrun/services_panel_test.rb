require "test_helper"

module Rbrun
  class ServicesPanelTest < ActionDispatch::IntegrationTest
    setup do
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @session  = @worktree.sessions.create!
      post "/rbrun/repos/switch", params: { repo: "a/b", base: "main" }
    end

    test "the conversation page shows the worktree stream + panel; a previewable service has Open" do
      web = @worktree.service_runs.create!(name: "web", command: "x", port: 3000,
                                           url: "http://localhost:3000", status: "running")
      @worktree.service_runs.create!(name: "worker", command: "y", status: "running")

      get "/rbrun/c/#{@session.id}"
      assert_response :success
      # two live streams now: the conversation's session stream + the worktree services stream.
      assert_select "turbo-cable-stream-source", 2
      assert_select "#services_panel_#{@worktree.id}"
      assert_select "a[href=?][target=_blank]", "/rbrun/services/#{web.id}/open"
      # worker (no port/url) has no Open link
      assert_select "a[href=?]", "/rbrun/services/#{@worktree.service_runs.find_by(name: 'worker').id}/open", false
    end

    test "Share publicly is offered ONLY once previewed, and public state is shown loudly" do
      run = @worktree.service_runs.create!(name: "web", command: "x", port: 3000, status: "running")

      # level 1 only — no share button at all
      get "/rbrun/c/#{@session.id}"
      assert_select "form[action=?]", "/rbrun/services/#{run.id}/share_public", false

      # level 2 — now it is offered
      run.update!(url: "http://localhost:3000")
      get "/rbrun/c/#{@session.id}"
      assert_select "form[action=?]", "/rbrun/services/#{run.id}/share_public"

      # level 3 — the action flips to revoke, and public state is shown loudly
      Rbrun::RepoService.for_tenant("rbrun").for_repo("a/b")
                        .find_or_create_by!(name: "web") { |r| r.command = "x" }
                        .update!(previewed: true, shared_public: true)
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

    test "open redirects to the live url; stop delegates to the launcher" do
      run = @worktree.service_runs.create!(name: "web", command: "x", port: 3000, url: "http://localhost:3000", status: "running")
      get "/rbrun/services/#{run.id}/open"
      assert_redirected_to "http://localhost:3000"

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
