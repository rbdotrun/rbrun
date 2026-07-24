require "test_helper"

module Rbrun
  class WorkflowDecisionFlowTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    PLAN = { "label" => "Ship it", "goal" => "release v2",
             "steps" => [ "Bump", "Changelog", "Tag" ] }.freeze

    setup do
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @session  = @worktree.sessions.create!
      @session.messages.create!(role: "user", event_type: "text", content: "plan a release")
      @gate = @session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "wf1",
        approval_status: "pending", payload: { "name" => "workflow_create", "input" => PLAN })
    end

    def result_row = @session.messages.find_by(event_type: "tool_result", tool_use_id: "wf1")

    test "the card renders the plan + decision buttons (resolved by convention)" do
      get "/rbrun/c/#{@session.id}"
      assert_response :success
      assert_select "form[action=?]", "/rbrun/workflow_decision/wf1"
      assert_select "button[value=apply]"
      assert_select "button[value=save]"
      assert_select "button[value=cancel]"
    end

    test "apply creates the workflow, binds it, records + resumes" do
      assert_enqueued_with(job: Rbrun::WorkflowDecisionTurnJob) do
        assert_difference("Rbrun::Workflow.count", 1) do
          post "/rbrun/workflow_decision/wf1", params: { decision: "apply" }
        end
      end
      assert_response :success
      workflow = Rbrun::Workflow.order(:id).last
      assert_equal %w[Bump Changelog Tag], workflow.steps.map(&:title)
      assert_equal workflow.id, @session.reload.workflow_id
      assert @session.workflow_status_active?
      assert @gate.reload.approval_approved?
      assert_equal "apply", result_row.payload.dig("result", "decision")
    end

    test "save creates the workflow but does NOT bind it" do
      assert_difference("Rbrun::Workflow.count", 1) do
        post "/rbrun/workflow_decision/wf1", params: { decision: "save" }
      end
      assert_nil @session.reload.workflow_id
    end

    test "cancel creates nothing, marks rejected" do
      assert_no_difference("Rbrun::Workflow.count") do
        post "/rbrun/workflow_decision/wf1", params: { decision: "cancel" }
      end
      assert @gate.reload.approval_rejected?
      assert_equal "cancel", result_row.payload.dig("result", "decision")
    end

    test "an unknown decision is rejected (422), nothing claimed" do
      post "/rbrun/workflow_decision/wf1", params: { decision: "nuke" }
      assert_response :unprocessable_entity
      assert @gate.reload.approval_pending?
    end

    test "a double submit is a no-op (the claim is the lock)" do
      post "/rbrun/workflow_decision/wf1", params: { decision: "save" }
      assert_no_difference("Rbrun::Workflow.count") do
        post "/rbrun/workflow_decision/wf1", params: { decision: "apply" }
      end
    end
  end
end
