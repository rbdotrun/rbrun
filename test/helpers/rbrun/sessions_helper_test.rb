require "test_helper"

module Rbrun
  class SessionsHelperTest < ActionView::TestCase
    include Rbrun::SessionsHelper

    test "markdown renders bold + escapes raw html" do
      out = markdown("**x** <script>alert(1)</script>")
      assert_includes out, "<strong>x</strong>"
      assert_includes out, "&lt;script&gt;"
      refute_includes out, "<script>"
    end

    test "tool_body pretty-prints a hash and passes a plain string through" do
      assert_includes tool_body({ "a" => 1 }), "\"a\": 1"
      assert_equal "hello", tool_body("hello")
    end

    test "tool_body parses a JSON string then pretty-prints it" do
      assert_includes tool_body('{"a":1}'), "\"a\": 1"
    end

    # A per-tool card defined by convention.
    module ::Rbrun::Sessions::ToolsValidation::WidgetGate
      class Component < ::Rbrun::Sessions::ToolsValidation::Base; end
    end

    test "tools_validation_component resolves a per-tool card by name, else Default" do
      assert_equal Rbrun::Sessions::ToolsValidation::WidgetGate::Component,
                   tools_validation_component("widget_gate")
      assert_equal Rbrun::Sessions::ToolsValidation::Default::Component,
                   tools_validation_component("nonexistent_tool")
    end
  end
end
