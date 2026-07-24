# frozen_string_literal: true

require "rbrun/dns/version"
require "rbrun/dns/requires"
require "rbrun/dns/record"
require "rbrun/dns/base"
require "rbrun/dns/cloudflare"

module Rbrun
  # The DNS provider family. Pure Ruby; depends on nothing else in rbrun. Lets a host put its own domain
  # on previews — cloudflare today, route53 later, with no caller change.
  #
  #   Rbrun::Dns.new(provider: :cloudflare, config: { api_token:, zone_id: })
  #
  # Resolves the adapter by constant lookup in this namespace (explicit allowlist — no camelize of
  # attacker-supplied names, no ActiveSupport). The adapter validates its own config and fails fast.
  module Dns
    class Error < StandardError; end

    ADAPTERS = { cloudflare: "Cloudflare" }.freeze

    def self.new(provider:, config: {}, **opts)
      const_name = ADAPTERS.fetch(provider.to_sym) do
        raise Error, "unknown dns provider #{provider.inspect} (known: #{ADAPTERS.keys.join(", ")})"
      end
      const_get(const_name).new(config:, **opts)
    end
  end
end
