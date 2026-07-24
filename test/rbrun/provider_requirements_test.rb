require "test_helper"

module Rbrun
  # A provider config is either VALID or it RAISES — there is no "valid-looking" third state. Each
  # adapter DECLARES what it cannot run without (`requires`), and construction validates it in one
  # place, uniformly across runtime / server / dns / sandbox.
  #
  # This is what a placeholder defeats: a fake api key or a guessed model makes an INVALID config pass,
  # so the adapter's own fail-fast never fires and the real failure surfaces on the first live call.
  class ProviderRequirementsTest < ActiveSupport::TestCase
    def sandbox = Rbrun::Sandbox.new(provider: :local, config: {}, labels: { t: "req" })

    test "claude_sdk declares its requirements and names every missing one" do
      box = sandbox
      error = assert_raises(Rbrun::Runtime::Error) do
        Rbrun::Runtime.new(provider: :claude_sdk, sandbox: box, config: {})
      end
      %w[anthropic_api_key model max_turns subprocess_timeout].each do |key|
        assert_match(/#{key}/, error.message, "the error must name #{key}")
      end
    ensure
      box&.destroy!
    end

    test "claude_sdk builds when its declared config is genuinely satisfied" do
      box = sandbox
      rt = Rbrun::Runtime.new(provider: :claude_sdk, sandbox: box,
                              config: { anthropic_api_key: "sk-real", model: "sonnet",
                                        max_turns: 12, subprocess_timeout: 900 })
      assert_instance_of Rbrun::Runtime::ClaudeSdk, rt
    ensure
      box&.destroy!
    end

    test "a blank string is missing, not present (a placeholder must not satisfy a requirement)" do
      box = sandbox
      error = assert_raises(Rbrun::Runtime::Error) do
        Rbrun::Runtime.new(provider: :claude_sdk, sandbox: box,
                           config: { anthropic_api_key: "  ", model: "sonnet",
                                     max_turns: 12, subprocess_timeout: 900 })
      end
      assert_match(/anthropic_api_key/, error.message)
    ensure
      box&.destroy!
    end

    test "kamal_hetzner requires its api token" do
      error = assert_raises(Rbrun::Server::Error) { Rbrun::Server.new(provider: :kamal_hetzner, config: {}) }
      assert_match(/hcloud_token/, error.message)
    end

    test "cloudflare requires token + zone" do
      error = assert_raises(Rbrun::Dns::Error) { Rbrun::Dns.new(provider: :cloudflare, config: {}) }
      assert_match(/api_token/, error.message)
      assert_match(/zone_id/, error.message)
    end

    test "daytona requires api_url too — an absent one built relative urls and failed far away" do
      error = assert_raises(Rbrun::Sandbox::Error) do
        Rbrun::Sandbox.new(provider: :daytona, config: { api_key: "k" }, labels: {})
      end
      assert_match(/api_url/, error.message)
    end

    # The flat knob was NEVER threaded into the provider hash, so the adapter's `|| 900` made a dead
    # setting look alive: every host ran 900 whatever it configured.
    test "c.subprocess_timeout actually reaches the runtime adapter" do
      Rbrun.configure do |c|
        c.subprocess_timeout = 1234
        c.sandbox_provider = { default: :local, local: {} }
        c.runtime_provider = { default: :claude_sdk,
                               claude_sdk: { anthropic_api_key: "sk-real", model: "sonnet", max_turns: 12 } }
      end
      box = Rbrun.sandbox(labels: { t: "timeout" })
      rt  = Rbrun.runtime(sandbox: box)
      assert_equal 1234, rt.instance_variable_get(:@timeout)
    ensure
      box&.destroy!
    end

    test "c.github_pat reaches the runtime adapter (it injects GH_TOKEN into the agent's shell)" do
      Rbrun.configure do |c|
        c.github_pat = "ghp_wired"
        c.sandbox_provider = { default: :local, local: {} }
        c.runtime_provider = { default: :claude_sdk,
                               claude_sdk: { anthropic_api_key: "sk-real", model: "sonnet", max_turns: 12 } }
      end
      box = Rbrun.sandbox(labels: { t: "pat" })
      rt  = Rbrun.runtime(sandbox: box)
      assert_equal "ghp_wired", rt.instance_variable_get(:@github_pat)
    ensure
      box&.destroy!
    end
  end
end
