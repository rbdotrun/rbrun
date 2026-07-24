require "test_helper"

module Rbrun
  class WorkflowsFlowTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      @skill = Rbrun::Skill.create!(tenant: "rbrun", slug: "changelog", name: "Changelog")
    end

    test "GET new renders a scenario form with one step row" do
      get "/rbrun/skills/changelog/workflows/new"
      assert_response :success
      assert_select "input[name=?]", "workflow[label]"
      assert_select "input[name=?]", "workflow[prompt]"
      assert_select "input[name^=?]", "workflow[steps_attributes]"
    end

    test "POST creates a skill-bound workflow with steps" do
      assert_difference("@skill.workflows.count", 1) do
        post "/rbrun/skills/changelog/workflows", params: { workflow: {
          label: "Weekly notes", prompt: "summarize the week",
          steps_attributes: { "0" => { position: 1, title: "Collect", description: "gather PRs" } }
        } }
      end
      wf = @skill.workflows.order(:id).last
      assert_equal "Weekly notes", wf.label
      assert_equal 1, wf.steps.count
      assert_redirected_to "/rbrun/skills/changelog/edit"
    end

    test "POST with a blank workflow label re-renders unprocessable_entity" do
      assert_no_difference("Rbrun::Workflow.count") do
        post "/rbrun/skills/changelog/workflows", params: { workflow: { label: "", prompt: "x" } }
      end
      assert_response :unprocessable_entity
    end

    test "POST with a step that has a description but no title surfaces a nested error" do
      assert_no_difference("Rbrun::Workflow.count") do
        post "/rbrun/skills/changelog/workflows", params: { workflow: {
          label: "Has bad step", prompt: "x",
          steps_attributes: { "0" => { position: 1, title: "", description: "content, no title" } }
        } }
      end
      assert_response :unprocessable_entity
      assert_select ".text-red-600" # a field error is rendered
    end

    test "▶ Run enqueues the scenario run" do
      wf = @skill.workflows.create!(tenant: "rbrun", label: "Case", prompt: "go")
      assert_enqueued_with(job: Rbrun::SkillScenarioRunJob) do
        post "/rbrun/skills/changelog/workflows/#{wf.id}/run"
      end
      assert_redirected_to "/rbrun/skills/changelog/edit"
    end

    test "DELETE removes a scenario" do
      wf = @skill.workflows.create!(tenant: "rbrun", label: "Case", prompt: "go")
      assert_difference("Rbrun::Workflow.count", -1) do
        delete "/rbrun/skills/changelog/workflows/#{wf.id}"
      end
    end
  end
end
