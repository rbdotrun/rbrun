require "test_helper"

module Rbrun
  class WorkflowTest < ActiveSupport::TestCase
    def build_workflow(label:, goal: nil, steps: [], tenant: "rbrun")
      wf = Rbrun::Workflow.new(label: label, goal: goal)
      wf[Rbrun.config.tenancy_key] = tenant
      wf.save!
      steps.each_with_index { |title, i| wf.steps.create!(position: i, title: title) }
      wf
    end

    test "requires a label" do
      wf = Rbrun::Workflow.new
      wf[Rbrun.config.tenancy_key] = "rbrun"
      refute wf.valid?
      assert_includes wf.errors[:label], "can't be blank"
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
