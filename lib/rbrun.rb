require "rbrun/version"
require "rbrun/config"
require "rbrun/resolver"
require "rbrun/engine"

module Rbrun
  # Config-aware constructors: read Rbrun.config and hand the pure gems an explicit config hash via
  # Rbrun.build. The gems themselves never read global state.
  class << self
    def sandbox(provider = nil, tenant: nil, **opts)
      require "rbrun/sandbox"
      build(Rbrun::Sandbox, config(tenant).sandbox_provider, provider: provider, **opts)
    end

    def runtime(sandbox:, provider: nil, tenant: nil, **opts)
      require "rbrun/runtime"
      build(Rbrun::Runtime, config(tenant).runtime_provider, provider: provider, sandbox: sandbox, **opts)
    end

    # The tool roster: engine built-ins + host-registered tools. ApplicationTool.manifest/find read it.
    def tools = @tools ||= []

    def register_tool(klass)
      tools << klass unless tools.include?(klass)
      klass
    end

    # Host-set resolver → the acting tenant slug (used when built-in auth is off). Defaults to the
    # single-tenant slug.
    attr_writer :current_tenant_resolver

    def current_tenant = @current_tenant_resolver&.call || Rbrun::Config::DEFAULT_TENANT

    # Optional host-supplied auth: given the controller session, return the acting user (any object
    # responding to #tenant). When set, it satisfies the mandatory-auth requirement.
    attr_writer :current_user_resolver

    def current_user_from(session) = @current_user_resolver&.call(session)
  end
end
