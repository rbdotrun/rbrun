require "test_helper"

module Rbrun
  class McpServerTest < ActiveSupport::TestCase
    def make(tenant: "rbrun", name: "stripe", **attrs)
      Rbrun::McpServer.create!({
        tenant:, name:, transport: "stdio", auth: "api_key", command: "npx",
        args: [ "-y", "@stripe/mcp" ], env: { "STRIPE_KEY" => "sk_test" }, tools: %w[a b],
        tool_permissions: { "default" => "needs_approval" }
      }.merge(attrs))
    end

    test "for_tenant scopes; name unique per tenant" do
      make(tenant: "rbrun")
      make(tenant: "acme")
      assert_equal 1, Rbrun::McpServer.for_tenant("rbrun").count
      assert_raises(ActiveRecord::RecordNotUnique) { make(tenant: "rbrun") }
    end

    test "to_spec round-trips into the Spec value object with symbols" do
      spec = make.to_spec
      assert_instance_of Rbrun::McpServer::Spec, spec
      assert_equal "stripe", spec.name
      assert_equal :stdio, spec.transport
      assert_equal :api_key, spec.auth
      assert_equal [ "-y", "@stripe/mcp" ], spec.args
      assert_equal %w[a b], spec.tools
    end

    test "config_digest is stable across set reorderings but sensitive to real change" do
      a = make(name: "one", env: { "A" => "1", "B" => "2" }, tools: %w[y x])
      b = make(name: "two", env: { "B" => "9", "A" => "9" }, tools: %w[x y]) # keys reordered, values differ, tools reordered
      assert_equal a.config_digest, b.config_digest, "reordered sets + different secret VALUES ⇒ same digest"

      c = make(name: "three", command: "node") # a real config change
      refute_equal a.config_digest, c.config_digest
    end

    test "an unknown transport is rejected" do
      assert_raises(ArgumentError) { make(name: "bad", transport: "grpc") }
    end
  end
end
