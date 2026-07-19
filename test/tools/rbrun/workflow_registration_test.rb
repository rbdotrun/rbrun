require "test_helper"

module Rbrun
  class WorkflowRegistrationTest < ActiveSupport::TestCase
    test "all five workflow tools are registered and findable" do
      %w[workflow_create validate_step cancel_workflow workflow_search use_workflow].each do |name|
        assert Rbrun::ApplicationTool.find(name), "#{name} not registered"
      end
    end

    test "the manifest marks the two gates as needing approval" do
      manifest = Rbrun::ApplicationTool.manifest.index_by { |e| e["name"] }
      assert manifest["workflow_create"]["needs_approval"]
      assert manifest["validate_step"]["needs_approval"]
      refute manifest["workflow_search"]["needs_approval"]
    end
  end
end
