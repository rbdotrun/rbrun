require "test_helper"

module Rbrun
  class WorkflowBandTest < ActionDispatch::IntegrationTest
    setup do
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @session  = @worktree.sessions.create!
      post "/rbrun/repos/switch", params: { repo: "a/b", base: "main" }
      @workflow = Rbrun::Workflow.new(label: "Ship")
      @workflow[Rbrun.config.tenancy_key] = "rbrun"
      @workflow.save!
      @s1 = @workflow.steps.create!(position: 0, title: "one")
      @s2 = @workflow.steps.create!(position: 1, title: "two")
    end

    test "no workflow → the band wrapper renders empty (a broadcast target)" do
      get "/rbrun/c/#{@session.id}"
      assert_select "#workflow_#{@session.id}"
      assert_select "#workflow_#{@session.id} [data-controller=workflow]", false
    end

    test "bound + active → the band shows steps and the counter" do
      @session.update!(workflow: @workflow, workflow_status: "active")
      @session.workflow_step_completions.create!(workflow_step: @s1, completed_at: Time.current)
      get "/rbrun/c/#{@session.id}"
      assert_select "#workflow_#{@session.id} [data-controller=workflow]"
      assert_select "#workflow_#{@session.id}", /1\/2/
      assert_select "form[action=?]", "/rbrun/c/#{@session.id}" # the cancel button posts to the composer endpoint
    end

    test "cancelled → the band hides" do
      @session.update!(workflow: @workflow, workflow_status: "cancelled")
      get "/rbrun/c/#{@session.id}"
      assert_select "#workflow_#{@session.id} [data-controller=workflow]", false
    end
  end
end
