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
