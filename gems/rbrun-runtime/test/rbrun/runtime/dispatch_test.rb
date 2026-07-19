require "test_helper"

class RuntimeDispatchTest < Minitest::Test
  def test_unknown_provider_raises
    error = assert_raises(Rbrun::Runtime::Error) do
      Rbrun::Runtime.new(provider: :nope, sandbox: Object.new, config: {})
    end
    assert_match(/unknown runtime provider :nope/, error.message)
  end

  def test_dispatches_to_claude_sdk_adapter
    sandbox = Rbrun::Sandbox.new(provider: :local, config: {}, labels: { session: "rt-dispatch" })
    runtime = Rbrun::Runtime.new(provider: :claude_sdk, sandbox: sandbox,
                                 config: { anthropic_api_key: "sk-test" })
    assert_instance_of Rbrun::Runtime::ClaudeSdk, runtime
  ensure
    sandbox&.destroy!
  end

  def test_client_ts_asset_is_present
    path = File.expand_path("../../../lib/rbrun/runtime/assets/client.ts", __dir__)
    assert File.exist?(path), "client.ts asset must ship with the gem"
    assert_includes File.read(path), 'const SERVER = "rbrun"'
  end
end
