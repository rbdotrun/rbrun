require "rbrun/version"
require "rbrun/config"
require "rbrun/resolver"
require "rbrun/engine"

module Rbrun
  # Config-aware constructors: read Rbrun.config and hand the pure gems an explicit config hash via
  # Rbrun.build. The gems themselves never read global state.
  class << self
    def sandbox(provider = nil, **opts)
      require "rbrun/sandbox"
      build(Rbrun::Sandbox, config.sandbox_provider, provider: provider, **opts)
    end

    def runtime(sandbox:, provider: nil, **opts)
      require "rbrun/runtime"
      build(Rbrun::Runtime, config.runtime_provider, provider: provider, sandbox: sandbox, **opts)
    end
  end
end
