require "test_helper"

module Rbrun
  module Mcp
    class MaterializerTest < ActiveSupport::TestCase
      def spec(**o)
        Rbrun::McpServer::Spec.new(**{ name: "s", transport: :stdio, auth: :api_key, command: "npx",
                                       args: [ "-y", "x" ], url: nil, env: { "K" => "v" }, headers: {},
                                       tools: nil, tool_permissions: {} }.merge(o))
      end

      test "stdio → command/args/env" do
        out = Materializer.call([ spec ])
        assert_equal({ "command" => "npx", "args" => [ "-y", "x" ], "env" => { "K" => "v" } },
                     out.dig("mcpServers", "s"))
      end

      test "http → type/url/headers, secrets carried through" do
        out = Materializer.call([ spec(name: "linear", transport: :http, command: nil, args: [],
                                       url: "https://mcp.linear.app", headers: { "Authorization" => "Bearer tok" }) ])
        assert_equal({ "type" => "http", "url" => "https://mcp.linear.app",
                       "headers" => { "Authorization" => "Bearer tok" } }, out.dig("mcpServers", "linear"))
      end
    end
  end
end
