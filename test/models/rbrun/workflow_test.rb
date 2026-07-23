require "test_helper"

module Rbrun
  class WorkflowTest < ActiveSupport::TestCase
    def build_workflow(label:, goal: nil, steps: [], tenant: "rbrun")
      wf = Rbrun::Workflow.new(label:, goal:)
      wf[Rbrun.config.tenancy_key] = tenant
      wf.save!
      steps.each_with_index { |title, i| wf.steps.create!(position: i, title:) }
      wf
    end

    test "requires a label" do
      wf = Rbrun::Workflow.new
      wf[Rbrun.config.tenancy_key] = "rbrun"
      refute wf.valid?
      assert_includes wf.errors[:label], "can't be blank"
    end

    test "a workflow can belong to a skill and carry a prompt (a scenario)" do
      skill = Rbrun::Skill.create!(tenant: "acme", slug: "s", name: "S")
      wf = Rbrun::Workflow.create!(tenant: "acme", label: "Case", skill:, prompt: "do the thing")
      assert_equal skill, wf.skill
      assert_includes Rbrun::Workflow.scenarios, wf
    end

    test "a plain workflow has no skill and is excluded from scenarios" do
      wf = Rbrun::Workflow.create!(tenant: "acme", label: "Plain")
      assert_nil wf.skill
      refute_includes Rbrun::Workflow.scenarios, wf
    end

    test "nested steps_attributes build ordered steps; a fully blank row is rejected" do
      wf = Rbrun::Workflow.create!(tenant: "acme", label: "W", steps_attributes: [
        { position: 1, title: "One", description: "prove one" },
        { position: 2, title: "",    description: "" } # all-blank → rejected
      ])
      assert_equal 1, wf.steps.count
      assert_equal "One", wf.steps.first.title
    end

    test "a step with a description but no title is INVALID (surfaces a nested error)" do
      wf = Rbrun::Workflow.new(tenant: "acme", label: "W", steps_attributes: [
        { position: 1, title: "", description: "has content but no title" }
      ])
      refute wf.valid?
      assert wf.steps.first.errors[:title].present?
    end

    test "steps come back ordered" do
      wf = build_workflow(label: "Ship", steps: %w[a b c])
      assert_equal %w[a b c], wf.steps.map(&:title)
    end

    test "search matches label, goal, description case-insensitively; blank returns none" do
      hit = build_workflow(label: "Release Pipeline", goal: "Cut a version")
      build_workflow(label: "Unrelated")
      assert_includes Rbrun::Workflow.search("release"), hit
      assert_includes Rbrun::Workflow.search("VERSION"), hit
      assert_empty Rbrun::Workflow.search("   ")
    end

    test "search is tenant-scopable via for_tenant" do
      mine = build_workflow(label: "Mine", tenant: "rbrun")
      build_workflow(label: "Mine too", tenant: "other")
      assert_equal [ mine ], Rbrun::Workflow.for_tenant("rbrun").search("mine").to_a
    end
  end
end
