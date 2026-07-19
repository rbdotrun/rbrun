# frozen_string_literal: true

require "rbrun"
require_relative "support"

# Phase 1 dogfood — the config kernel, for real. Loads a config, resolves a provider by convention
# through the config-aware constructor (Rbrun.build), and proves a missing required key fails fast.
#
#   bin/rails dogfood:config

# A throwaway family that mimics a real provider gem: `.new(provider:)` resolves an adapter by
# constant lookup; the adapter validates the config it is handed.
module DogfoodDemoFamily
  def self.new(provider:, config:, **opts)
    const_get(provider.to_s.camelize).new(**config, **opts)
  end

  class Sqlite
    attr_reader :path

    def initialize(path: nil, **)
      raise Rbrun::ConfigError, "sqlite provider requires :path" if path.nil? || path.to_s.empty?
      @path = path
    end
  end
end

namespace :dogfood do
  desc "Phase 1: config kernel resolves a provider by convention and fails fast on a bad config"
  task :config do
    dog = Rbrun::Dogfood

    Rbrun.reset_config!
    Rbrun.configure do |c|
      c.database_connection = :rbrun
      c.tenancy_key         = "tenant"
      c.user email: "dev@example.com", password: "secret"
      c.sandbox_provider = { default: :sqlite, sqlite: { path: "/tmp/box.db" } }
    end

    dog.header "config parsed"
    dog.ok "flat knob defaulted (subprocess_timeout=900)", Rbrun.config.subprocess_timeout == 900
    dog.ok "tenancy_key = tenant", Rbrun.config.tenancy_key == "tenant"
    dog.ok "one user, default tenant rbrun",
           Rbrun.config.users == [ { email: "dev@example.com", password: "secret", tenant: "rbrun" } ]

    dog.header "provider resolved by convention"
    obj = Rbrun.build(DogfoodDemoFamily, Rbrun.config.sandbox_provider) # default: :sqlite
    dog.ok "resolved :sqlite → DogfoodDemoFamily::Sqlite", obj.is_a?(DogfoodDemoFamily::Sqlite)
    dog.ok "config injected (path=/tmp/box.db)", obj.path == "/tmp/box.db"

    dog.header "fail-fast on bad config"
    failed =
      begin
        Rbrun.build(DogfoodDemoFamily, { default: :sqlite, sqlite: {} })
        false
      rescue Rbrun::ConfigError => e
        dog.info "raised", e.message
        true
      end
    dog.ok "missing required key raised Rbrun::ConfigError", failed
  end
end
