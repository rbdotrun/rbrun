# frozen_string_literal: true

require "rbrun/sandbox/version"
require "rbrun/sandbox/exec_result"
require "rbrun/sandbox/file_upload"
require "rbrun/sandbox/line_buffer"
require "rbrun/sandbox/local"
require "rbrun/sandbox/daytona"

module Rbrun
  # The sandbox backend family. Pure Ruby; depends on nothing else in rbrun.
  #
  #   Rbrun::Sandbox.new(provider: :local,   config: {},                                labels: { session: 42 })
  #   Rbrun::Sandbox.new(provider: :daytona, config: { api_key:, api_url:, dockerfile: }, labels: { session: 42 })
  #
  # Resolves the adapter by constant lookup in this namespace (explicit allowlist — no camelize of
  # attacker-supplied names, no ActiveSupport). The adapter validates its own config and fails fast.
  module Sandbox
    class Error < StandardError; end
    class TimeoutError < Error; end

    ADAPTERS = { local: "Local", daytona: "Daytona" }.freeze

    def self.new(provider:, config: {}, **opts)
      const_name = ADAPTERS.fetch(provider.to_sym) do
        raise Error, "unknown sandbox provider #{provider.inspect} (known: #{ADAPTERS.keys.join(", ")})"
      end
      const_get(const_name).new(config: config, **opts)
    end
  end
end
