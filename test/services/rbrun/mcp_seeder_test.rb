require "test_helper"

module Rbrun
  class McpSeederTest < ActiveSupport::TestCase
    def server(name: "stripe", **overrides)
      { name: name, transport: :stdio, auth: :api_key, command: "npx", args: [ "-y", "x" ],
        env: { "K" => "v" }, headers: {}, tools: nil, tool_permissions: {} }.merge(overrides)
    end

    def seed(authored, tenant: "rbrun") = Rbrun::McpSeeder.new(tenant: tenant, authored: authored).call

    test "a new server is created" do
      assert_equal [ :created ], seed([ server ]).map(&:status)
      assert Rbrun::McpServer.for_tenant("rbrun").exists?(name: "stripe")
    end

    test "re-seeding identical config is unchanged (idempotent, symbol/string-agnostic)" do
      seed([ server ])
      assert_equal [ :unchanged ], seed([ server ]).map(&:status)
    end

    test "an edited DB row diverges and is NOT overwritten" do
      seed([ server(command: "npx") ])
      row = Rbrun::McpServer.for_tenant("rbrun").find_by(name: "stripe")
      row.update!(command: "hand-edited") # simulate a DB edit

      assert_equal [ :diverged ], seed([ server(command: "npx") ]).map(&:status)
      assert_equal "hand-edited", row.reload.command, "the edited row was left intact"
    end

    test "seed_at_boot! creates configured servers and no-ops when none" do
      Rbrun.reset_config!
      assert_no_difference("Rbrun::McpServer.count") { Rbrun::McpSeeder.seed_at_boot! }

      Rbrun.config.mcp_server(**server)
      assert_difference("Rbrun::McpServer.count", 1) { Rbrun::McpSeeder.seed_at_boot! }
    ensure
      Rbrun.config.mcp_servers.clear
    end
  end
end
