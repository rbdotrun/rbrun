require "test_helper"

module Rbrun
  class SessionWorkflowTest < ActiveSupport::TestCase
    setup do
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @session  = @worktree.sessions.create!
      @workflow = Rbrun::Workflow.new(label: "Ship")
      @workflow[Rbrun.config.tenancy_key] = "rbrun"
      @workflow.save!
      @step = @workflow.steps.create!(position: 0, title: "Bump")
    end

    test "a session binds a workflow and carries a nil-able prefixed status" do
      assert_nil @session.workflow_status
      @session.update!(workflow: @workflow, workflow_status: "active")
      assert @session.workflow_status_active?
      @session.workflow_status_cancelled!
      assert @session.workflow_status_cancelled?
    end

    test "completions are per-session and cascade on session destroy" do
      c = @session.workflow_step_completions.create!(workflow_step: @step, completed_at: Time.current)
      assert_equal [ c ], @session.workflow_step_completions.to_a
      assert_difference("Rbrun::WorkflowStepCompletion.count", -1) { @session.destroy }
    end

    test "clearing a session nullifies the link but keeps the workflow" do
      @session.update!(workflow: @workflow)
      @session.destroy
      assert Rbrun::Workflow.exists?(@workflow.id), "workflow persists after its run is cleared"
    end
  end
end
