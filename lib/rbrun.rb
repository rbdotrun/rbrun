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

    # The tool roster: engine built-ins + host-registered tools. ApplicationTool.manifest/find read it.
    def tools = @tools ||= []

    def register_tool(klass)
      tools << klass unless tools.include?(klass)
      klass
    end
  end
end
