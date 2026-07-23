require "test_helper"

class McpResolverTest < ActiveSupport::TestCase
  setup    { Rbrun.reset_config! }
  teardown { Rbrun.reset_config! }

  def spec(name)
    Rbrun::McpServer::Spec.new(name:, transport: :stdio, auth: nil, command: "x", args: [],
                               url: nil, env: {}, headers: {}, tools: nil, tool_permissions: {})
  end

  test "unset ⇒ the tenant's ENABLED DB rows as Specs" do
    Rbrun::McpServer.create!(tenant: "acme", name: "on",  transport: "stdio", command: "npx")
    Rbrun::McpServer.create!(tenant: "acme", name: "off", transport: "stdio", command: "x", enabled: false)

    specs = Rbrun.mcp_servers_for("acme", "a/b")
    assert_equal [ "on" ], specs.map(&:name)
    assert_instance_of Rbrun::McpServer::Spec, specs.first
  end

  test "set ⇒ the resolver drives and is called with (tenant, repo)" do
    seen = nil
    Rbrun.mcp_resolver = ->(tenant, repo) { seen = [ tenant, repo ]; [ spec("injected") ] }

    specs = Rbrun.mcp_servers_for("acme", "owner/repo")
    assert_equal [ "injected" ], specs.map(&:name)
    assert_equal [ "acme", "owner/repo" ], seen
  end

  test "reset_config! clears the resolver (falls back to the DB path)" do
    Rbrun.mcp_resolver = ->(_t, _r) { raise "stale resolver" }
    Rbrun.reset_config!
    assert_nothing_raised { Rbrun.mcp_servers_for("acme", "a/b") }
  end
end
