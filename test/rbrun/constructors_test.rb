require "test_helper"

class ConstructorsTest < ActiveSupport::TestCase
  setup { Rbrun.reset_config! }
  teardown { Rbrun.reset_config! }

  test "Rbrun.sandbox resolves the default provider from config" do
    Rbrun.configure { |c| c.sandbox_provider = { default: :local, local: {} } }
    box = Rbrun.sandbox(labels: { session: "ctor" })
    assert_instance_of Rbrun::Sandbox::Local, box
  ensure
    box&.destroy!
  end

  test "Rbrun.sandbox honors an explicit provider override" do
    Rbrun.configure { |c| c.sandbox_provider = { default: :local, local: {} } }
    box = Rbrun.sandbox(:local, labels: { session: "ctor2" })
    assert_instance_of Rbrun::Sandbox::Local, box
  ensure
    box&.destroy!
  end

  test "Rbrun.runtime resolves claude_sdk with an injected sandbox" do
    Rbrun.configure do |c|
      c.sandbox_provider = { default: :local, local: {} }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: "sk-test" } }
    end
    box = Rbrun.sandbox(labels: { session: "ctor3" })
    rt = Rbrun.runtime(sandbox: box)
    assert_instance_of Rbrun::Runtime::ClaudeSdk, rt
  ensure
    box&.destroy!
  end
end
