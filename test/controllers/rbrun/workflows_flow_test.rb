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

    # The template row's index is the literal "NEW_RECORD", so a view-computed ordinal collapsed every
    # JS-added step to position 1 (ties on a new workflow, front-jumping on an existing one). Order must
    # come from the submitted row order.
    test "step positions come from the submitted order, not from the form" do
      post "/rbrun/skills/changelog/workflows", params: { workflow: {
        label: "Ordered", prompt: "x",
        # keys as the nested-form JS emits them: the server-rendered row is "0", cloned rows carry a
        # Date.now() stamp (numeric — Rails only treats numeric keys as nested-attribute elements)
        steps_attributes: {
          "0"             => { title: "First",  description: "a" },
          "1753364001234" => { title: "Second", description: "b" },
          "1753364005678" => { title: "Third",  description: "c" }
        }
      } }
      wf = @skill.workflows.find_by!(label: "Ordered")
      assert_equal [ [ "First", 1 ], [ "Second", 2 ], [ "Third", 3 ] ],
                   wf.steps.order(:position).pluck(:title, :position)
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
