# frozen_string_literal: true

require "active_support/core_ext/string/inflections" # String#camelize (used by family modules)

module Rbrun
  class ConfigError < StandardError; end

  # The config-aware constructor mechanism shared by every family wrapper (Rbrun.sandbox,
  # Rbrun.runtime, … — added with their gems in later phases). Selects a provider from a
  # `<family>_provider` config hash and hands the pure family module an explicit config hash;
  # the family resolves the concrete adapter by constant lookup and validates the config itself.
  #
  #   Rbrun.build(Rbrun::Sandbox, Rbrun.config.sandbox_provider, provider: :local)
  #
  def self.build(family_module, providers_config, provider: nil, **opts)
    raise ConfigError, ":default is reserved and cannot be selected as a provider" if provider == :default

    name = provider || providers_config.fetch(:default) do
      raise ConfigError, "no provider given and no :default configured"
    end

    provider_config = providers_config.fetch(name) do
      raise ConfigError, "no configuration for provider #{name.inspect}"
    end

    family_module.new(provider: name, config: provider_config, **opts)
  end
end
