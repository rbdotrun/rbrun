# frozen_string_literal: true

require "rbrun/server/version"
require "rbrun/server/requires"
require "rbrun/server/node"
require "rbrun/server/deploy_result"
require "rbrun/server/base"
require "rbrun/server/kamal_hetzner"

module Rbrun
  # The server provider family. Pure Ruby; depends on no other rbrun gem. Provisions a server and deploys an
  # app onto it — kamal_hetzner today, other adapters later, with no caller change. Resolves the adapter by
  # constant lookup in this namespace (explicit allowlist — no camelize of attacker-supplied names). The
  # adapter validates its own config and fails fast.
  #
  #   Rbrun::Server.new(provider: :kamal_hetzner, config: { hcloud_token:, ssh_private_key:, registry: {…} })
  module Server
    class Error < StandardError; end

    ADAPTERS = { kamal_hetzner: "KamalHetzner" }.freeze

    def self.new(provider:, config: {}, **opts)
      const_name = ADAPTERS.fetch(provider.to_sym) do
        raise Error, "unknown server provider #{provider.inspect} (known: #{ADAPTERS.keys.join(", ")})"
      end
      const_get(const_name).new(config:, **opts)
    end
  end
end
