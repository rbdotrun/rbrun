require "test_helper"

module Rbrun
  class SessionsFlowTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      Rbrun.register_tool(Rbrun::Tools::Identity)
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @session  = @worktree.sessions.create!
    end

    test "index and show render for a signed-in user" do
      get "/rbrun/c"
      assert_response :success
      get "/rbrun/c/#{@session.id}"
      assert_response :success
      assert_select "#conversation_#{@session.id}"
      assert_select "#composer"
    end

    test "the collapsible sidebar rail renders with its regions (no repo switcher)" do
      get "/rbrun/c"
      assert_response :success
      assert_select "#navbar[data-controller=?]", "sidebar"
      assert_select "#sidebar-header"
      assert_select "#sidebar-nav", text: /Conversations/
      assert_select "#sidebar-footer", text: /dev@rbrun.test/
      assert_select "#repo_switcher", count: 0
    end

    test "the sidebar_collapsed cookie makes the server render the collapsed rail" do
      cookies[:sidebar_collapsed] = "1"
      get "/rbrun/c"
      assert_response :success
      assert_select "#navbar[data-collapsed]"
    end

    test "composing from root creates a NEW worktree + session + first turn" do
      assert_difference([ "Rbrun::Worktree.count", "Rbrun::Session.count" ], 1) do
        assert_enqueued_with(job: Rbrun::AgentTurnJob) do
          post "/rbrun/c", params: { repo: "acme/web", base: "main", message: { content: "hello" } }
        end
      end
      s = Rbrun::Session.order(:id).last
      assert_equal "acme/web", s.worktree.repo
      assert_redirected_to "/rbrun/c/#{s.id}"
    end

    test "composing again on the same repo makes a SECOND worktree (new every time)" do
      post "/rbrun/c", params: { repo: "acme/web", base: "main", message: { content: "a" } }
      assert_difference("Rbrun::Worktree.count", 1) do
        post "/rbrun/c", params: { repo: "acme/web", base: "main", message: { content: "b" } }
      end
    end

    test "composing with no repo creates a bare worktree" do
      post "/rbrun/c", params: { message: { content: "no repo" } }
      assert Rbrun::Session.order(:id).last.worktree.bare?
    end

    test "composing without content is rejected" do
      assert_no_difference("Rbrun::Session.count") do
        post "/rbrun/c", params: { repo: "acme/web", message: { content: "" } }
      end
      assert_response :bad_request
    end

    test "the index lists worktrees grouped by repo" do
      get "/rbrun/c"
      assert_response :success
      assert_select "a[href=?]", "/rbrun/worktrees/#{@worktree.id}"
      assert_includes @response.body, "a/b"
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

    # The gate must FAIL CLOSED. Only an explicit "approve" may run a frozen needs_approval call —
    # a typo, a renamed button, or a hand-crafted POST must never resolve to "approved".
    test "an unknown approval decision is refused and the gate stays pending" do
      @session.messages.create!(role: "user", event_type: "text", content: "go")
      frozen = @session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "g2",
        approval_status: "pending", payload: { "name" => "identity", "input" => {} })

      [ "reject", "deny", "cancel", "" ].each do |bogus|
        patch "/rbrun/approvals/g2", params: { decision: bogus }
        assert_response :unprocessable_entity, "#{bogus.inspect} must not be accepted"
        assert frozen.reload.approval_pending?, "#{bogus.inspect} must leave the gate pending"
      end

      patch "/rbrun/approvals/g2" # no decision at all
      assert_response :unprocessable_entity
      assert frozen.reload.approval_pending?
    end

    test "an explicit refuse rejects the gate" do
      @session.messages.create!(role: "user", event_type: "text", content: "go")
      frozen = @session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "g3",
        approval_status: "pending", payload: { "name" => "identity", "input" => {} })

      patch "/rbrun/approvals/g3", params: { decision: "refuse" }
      assert frozen.reload.approval_rejected?
    end
  end
end
