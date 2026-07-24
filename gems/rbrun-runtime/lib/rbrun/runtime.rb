# frozen_string_literal: true

require "rbrun/runtime/version"
require "rbrun/runtime/requires"
require "rbrun/runtime/claude_sdk"

module Rbrun
  # The AI-runtime family. `provider` selects the sandboxed RUNNER (claude_sdk today; codex/gemini
  # later). Resolves the adapter by constant lookup in this namespace; the adapter validates its own
  # config and fails fast. Depends on rbrun-sandbox (the loop runs inside a sandbox).
  #
  #   Rbrun::Runtime.new(provider: :claude_sdk, sandbox:, config: { anthropic_api_key: })
  module Runtime
    class Error < StandardError; end

    ADAPTERS = { claude_sdk: "ClaudeSdk" }.freeze

    def self.new(provider:, sandbox:, config: {})
      const_name = ADAPTERS.fetch(provider.to_sym) do
        raise Error, "unknown runtime provider #{provider.inspect} (known: #{ADAPTERS.keys.join(", ")})"
      end
      const_get(const_name).new(sandbox:, config:)
    end
  end
end
