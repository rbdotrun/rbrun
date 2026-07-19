require "test_helper"

module Rbrun
  class WorkflowToolsTest < ActiveSupport::TestCase
    setup do
      @session  = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b").sessions.create!
      @workflow = Rbrun::Workflow.new(label: "Ship", goal: "cut a release")
      @workflow[Rbrun.config.tenancy_key] = "rbrun"
      @workflow.save!
      @s1 = @workflow.steps.create!(position: 0, title: "one")
      @s2 = @workflow.steps.create!(position: 1, title: "two")
    end

    def tool(klass) = klass.in_session(@session)

    test "workflow_create is a custom_approval gate with no real execute" do
      assert Rbrun::Tools::WorkflowCreate.custom_approval?
      assert Rbrun::Tools::WorkflowCreate.needs_approval?
      assert_equal :workflow_decision, Rbrun::Tools::WorkflowCreate.approval_submit_route
    end

    test "validate_step records the current step, advances, completes on the last" do
      @session.update!(workflow: @workflow, workflow_status: "active")
      r1 = tool(Rbrun::Tools::ValidateStep).execute(summary: "did one")
      assert_equal "one", r1.dig("data", "step")
      assert_equal 1, r1.dig("data", "done")
      refute r1.dig("data", "all_done")
      assert_equal @s2, Rbrun::Workflow::Run.new(@session).current_step

      r2 = tool(Rbrun::Tools::ValidateStep).execute(summary: "did two")
      assert r2.dig("data", "all_done")
      assert @session.reload.workflow_status_completed?
    end

    test "validate_step errors when there is no current step" do
      assert_includes tool(Rbrun::Tools::ValidateStep).execute["error"], "no active workflow step"
    end

    test "cancel_workflow keeps the binding, sets cancelled" do
      @session.update!(workflow: @workflow, workflow_status: "active")
      assert tool(Rbrun::Tools::CancelWorkflow).execute.dig("data", "cancelled")
      assert @session.reload.workflow_status_cancelled?
      assert_equal @workflow.id, @session.workflow_id, "binding kept"
    end

    test "workflow_search is tenant-scoped and keyword-matched" do
      hits = tool(Rbrun::Tools::WorkflowSearch).execute(query: "release").dig("data", "workflows")
      assert_equal [ "Ship" ], hits.map { |h| h["label"] }
      assert_empty tool(Rbrun::Tools::WorkflowSearch).execute(query: "nomatch").dig("data", "workflows")
    end

    test "use_workflow binds a fresh run (progress empty)" do
      res = tool(Rbrun::Tools::UseWorkflow).execute(workflow_id: @workflow.id)
      assert_equal "Ship", res.dig("data", "label")
      assert_equal 2, res.dig("data", "total")
      assert @session.reload.workflow_status_active?
      assert_equal 0, Rbrun::Workflow::Run.new(@session).done_count
    end
  end
end
