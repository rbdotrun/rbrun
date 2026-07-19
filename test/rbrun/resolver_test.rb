require "test_helper"

# A stand-in for a real provider gem: `.new(provider:)` resolves the adapter by constant lookup;
# the adapter validates the config it is handed (fail-fast). Real gems (rbrun-sandbox, …) do the same.
module ResolverDummy
  def self.new(provider:, config:, **opts)
    const_get(provider.to_s.camelize).new(**config, **opts)
  end

  class Echo
    attr_reader :token

    def initialize(token: nil, **)
      raise Rbrun::ConfigError, "echo requires :token" if token.nil? || token.to_s.empty?
      @token = token
    end
  end
end

class ResolverTest < ActiveSupport::TestCase
  CFG = { default: :echo, echo: { token: "hi" } }.freeze

  test "selects the :default provider and injects its config" do
    obj = Rbrun.build(ResolverDummy, CFG)
    assert_instance_of ResolverDummy::Echo, obj
    assert_equal "hi", obj.token
  end

  test "an explicit provider: overrides the default" do
    obj = Rbrun.build(ResolverDummy, CFG, provider: :echo)
    assert_equal "hi", obj.token
  end

  test "no provider and no :default raises ConfigError" do
    error = assert_raises(Rbrun::ConfigError) { Rbrun.build(ResolverDummy, {}) }
    assert_match(/no provider/i, error.message)
  end

  test "a selected provider with no config entry raises ConfigError" do
    error = assert_raises(Rbrun::ConfigError) { Rbrun.build(ResolverDummy, { default: :echo }) }
    assert_match(/no configuration for provider :echo/i, error.message)
  end

  test ":default is reserved and cannot be selected as a provider" do
    error = assert_raises(Rbrun::ConfigError) { Rbrun.build(ResolverDummy, CFG, provider: :default) }
    assert_match(/reserved/i, error.message)
  end

  test "adapter validates its own config — missing required key fails fast" do
    error = assert_raises(Rbrun::ConfigError) do
      Rbrun.build(ResolverDummy, { default: :echo, echo: {} })
    end
    assert_match(/echo requires :token/i, error.message)
  end
end
