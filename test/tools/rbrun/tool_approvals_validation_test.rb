require "test_helper"

module Rbrun
  class ToolApprovalsValidationTest < ActiveSupport::TestCase
    # A custom gate with neither a card nor a real route.
    class Orphan < Rbrun::ApplicationTool
      custom_approval! submit: :nonexistent_route
      def name = "orphan_gate"
    end

    # A custom gate WITH a card (defined below) but a bogus route.
    class Carded < Rbrun::ApplicationTool
      custom_approval! submit: :nonexistent_route
      def name = "carded_gate"
    end
    module ::Rbrun::Sessions::ToolsValidation::CardedGate
      class Component < ::Rbrun::Sessions::ToolsValidation::Base; end
    end

    # A complete custom gate: a card + a real engine route (:skills exists).
    class Complete < Rbrun::ApplicationTool
      custom_approval! submit: :skills
      def name = "complete_gate"
    end
    module ::Rbrun::Sessions::ToolsValidation::CompleteGate
      class Component < ::Rbrun::Sessions::ToolsValidation::Base; end
    end

    def validate_with(tools)
      saved = Rbrun.tools.dup
      Rbrun.instance_variable_set(:@tools, tools)
      Rbrun::ApplicationTool.validate_tool_approvals!
    ensure
      Rbrun.instance_variable_set(:@tools, saved)
    end

    test "a custom_approval tool without its card fails the boot check" do
      err = assert_raises(Rbrun::Conventions::Error) { validate_with([ Orphan ]) }
      assert_match(/ToolsValidation::OrphanGate/, err.message)
    end

    test "a custom_approval tool without its submit route fails the boot check" do
      err = assert_raises(Rbrun::Conventions::Error) { validate_with([ Carded ]) }
      assert_match(/submit route :nonexistent_route/, err.message)
    end

    test "a complete custom_approval tool (card + route) passes" do
      assert_nothing_raised { validate_with([ Complete ]) }
    end
  end
end
