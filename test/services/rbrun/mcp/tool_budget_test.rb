require "test_helper"

module Rbrun
  module Mcp
    class ToolBudgetTest < ActiveSupport::TestCase
      def spec(name:, tools:, tool_permissions: {})
        Rbrun::McpServer::Spec.new(name: name, transport: :stdio, auth: nil, command: "x", args: [],
                                   url: nil, env: {}, headers: {}, tools: tools,
                                   tool_permissions: tool_permissions)
      end

      test "blocked tools are removed from the allowlist" do
        s = spec(name: "s", tools: %w[a b c], tool_permissions: { "b" => :blocked })
        out = ToolBudget.apply([ s ], builtin_count: 0, rbrun_count: 0)
        assert_equal %w[a c], out.first.tools
      end

      test "a nil allowlist (all) is left nil and warned, not counted" do
        s = spec(name: "s", tools: nil)
        out = ToolBudget.apply([ s ], builtin_count: 0, rbrun_count: 0, ceiling: 5)
        assert_nil out.first.tools
      end

      test "over the cap: lowest-priority + later tools drop first, and nothing is silent" do
        log = StringIO.new
        with_logger(Logger.new(log)) do
          # ceiling 12, builtin 7, rbrun 3 ⇒ budget 2. Three tools, one always_allow ⇒ it survives.
          s = spec(name: "s", tools: %w[keep drop1 drop2],
                   tool_permissions: { "default" => :needs_approval, "keep" => :always_allow })
          out = ToolBudget.apply([ s ], builtin_count: 7, rbrun_count: 3, ceiling: 12)

          assert_equal 2, out.first.tools.size
          assert_includes out.first.tools, "keep", "always_allow survives the cut"
          assert_match(/dropped for tool budget/, log.string)
        end
      end

      test "under the cap: everything passes through unchanged" do
        s = spec(name: "s", tools: %w[a b])
        out = ToolBudget.apply([ s ], builtin_count: 7, rbrun_count: 3, ceiling: 40)
        assert_equal %w[a b], out.first.tools
      end

      def with_logger(logger)
        old = Rails.logger
        Rails.logger = logger
        yield
      ensure
        Rails.logger = old
      end
    end
  end
end
