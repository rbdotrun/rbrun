require "test_helper"

module Rbrun
  class SessionsFlowTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      Rbrun.register_tool(Rbrun::Tools::Identity)
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @session = @worktree.sessions.create!
      # Act inside repo a/b (the switcher sets this; conversations are scoped to it).
      post "/rbrun/repos/switch", params: { repo: "a/b", base: "main" }
    end

    test "index and show render for a signed-in user" do
      get "/rbrun/c"
      assert_response :success
      get "/rbrun/c/#{@session.id}"
      assert_response :success
      assert_select "#conversation_#{@session.id}"
      assert_select "#composer"
    end

    test "the collapsible sidebar rail renders with its regions" do
      get "/rbrun/c"
      assert_response :success
      assert_select "#navbar[data-controller=?]", "sidebar"
      assert_select "#sidebar-header"
      assert_select "#repo_switcher"
      assert_select "#sidebar-nav", text: /Conversations/
      assert_select "#sidebar-footer", text: /dev@rbrun.test/
      refute_match(/data-collapsed/, @response.body)
    end

    test "the repo switcher trigger opens the modal and shows the current repo" do
      get "/rbrun/c"
      assert_response :success
      assert_select "#repo_switcher a[href$=?][data-turbo-frame=?]", "/repos", "modal"
      assert_select "#repo_label", text: "a/b"
    end

    test "the sidebar_collapsed cookie makes the server render the collapsed rail" do
      cookies[:sidebar_collapsed] = "1"
      get "/rbrun/c"
      assert_response :success
      assert_select "#navbar[data-collapsed]"
    end

    test "creating a conversation redirects to its show page" do
      assert_difference("Rbrun::Session.count", 1) { post "/rbrun/c" }
      assert_response :redirect
    end

    test "create finds-or-creates the worktree for the current repo (no duplicate)" do
      assert_no_difference("Rbrun::Worktree.count") { post "/rbrun/c" }
      assert_equal "a/b", Rbrun::Session.order(:id).last.worktree.repo
    end

    test "the index is scoped to the current repo" do
      other = Rbrun::Worktree.create!(tenant: "rbrun", repo: "c/d")
      other_session = other.sessions.create!
      get "/rbrun/c"
      assert_select "a[href$=?]", "/c/#{@session.id}"
      assert_select "a[href$=?]", "/c/#{other_session.id}", count: 0
    end

    test "the index excludes skill_scenario sessions" do
      machine = @worktree.sessions.create!(kind: :skill_scenario)
      get "/rbrun/c"
      assert_select "a[href$=?]", "/c/#{@session.id}"
      assert_select "a[href$=?]", "/c/#{machine.id}", count: 0
    end

    test "with no current repo, create makes nothing and redirects" do
      post "/rbrun/repos/switch", params: { repo: "" }
      assert_no_difference("Rbrun::Session.count") { post "/rbrun/c" }
      assert_redirected_to "/rbrun/c"
    end

    test "posting a message enqueues the turn and resets the composer" do
      assert_enqueued_with(job: Rbrun::AgentTurnJob) do
        post "/rbrun/c/#{@session.id}", params: { message: { content: "hello" } },
             headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end
      assert_response :success
      assert_includes @response.body, "new_message"
    end

    test "deciding an approval runs the frozen call, enqueues the resume, and replaces the segment" do
      @session.messages.create!(role: "user", event_type: "text", content: "go")
      frozen = @session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "g1",
        approval_status: "pending", payload: { "name" => "identity", "input" => {} })

      assert_enqueued_with(job: Rbrun::ApprovalTurnJob) do
        patch "/rbrun/approvals/g1", params: { decision: "approve" }
      end
      assert_response :success
      assert frozen.reload.approval_approved?
    end

    test "a message post without content is rejected" do
      post "/rbrun/c/#{@session.id}", params: { message: { content: "" } }
      assert_response :bad_request
    end
  end
end
