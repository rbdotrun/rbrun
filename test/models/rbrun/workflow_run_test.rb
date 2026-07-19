require "test_helper"

module Rbrun
  class WorkflowRunTest < ActiveSupport::TestCase
    setup do
      @session  = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b").sessions.create!
      @workflow = Rbrun::Workflow.new(label: "Ship")
      @workflow[Rbrun.config.tenancy_key] = "rbrun"
      @workflow.save!
      @s1 = @workflow.steps.create!(position: 0, title: "one")
      @s2 = @workflow.steps.create!(position: 1, title: "two")
      @session.update!(workflow: @workflow, workflow_status: "active")
    end

    def progress = Rbrun::Workflow::Run.new(@session)

    test "empty run: current is the first step, nothing done" do
      assert_equal @s1, progress.current_step
      assert_equal 0, progress.done_count
      assert_equal 2, progress.total
      refute progress.all_done?
    end

    test "completing the current step advances current and the count, live" do
      @session.workflow_step_completions.create!(workflow_step: @s1, completed_at: Time.current)
      assert_equal @s2, progress.current_step
      assert_equal 1, progress.done_count
      refute progress.all_done?
    end

    test "all steps done → all_done?, current is nil" do
      @workflow.steps.each { |s| @session.workflow_step_completions.create!(workflow_step: s, completed_at: Time.current) }
      assert progress.all_done?
      assert_nil progress.current_step
    end

    test "no workflow bound → empty, not all_done" do
      @session.update!(workflow: nil)
      assert_equal 0, progress.total
      refute progress.all_done?
    end
  end
end
