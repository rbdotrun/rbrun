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
      build(Rbrun::Sandbox, config(tenant).sandbox_provider, provider:, **opts)
    end

    def runtime(sandbox:, provider: nil, tenant: nil, **opts)
      require "rbrun/runtime"
      build(Rbrun::Runtime, config(tenant).runtime_provider, provider:, sandbox:, **opts)
    end

    def dns(provider = nil, tenant: nil, **opts)
      require "rbrun/dns"
      build(Rbrun::Dns, config(tenant).dns_provider, provider:, **opts)
    end

    def server(provider = nil, tenant: nil, **opts)
      require "rbrun/server"
      build(Rbrun::Server, config(tenant).server_provider, provider:, **opts)
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

    # The repo directory behind the sidebar switcher, tenant-aware. Precedence:
    #   1. github_repos_resolver — a host proc taking the tenant (e.g. a GitHub-App-installation-scoped
    #      lister per tenant). The multi-tenant seam.
    #   2. a static github_repos override (tenant-agnostic) — the single-object seam tests/self-host use.
    #   3. the default: a GithubRepos on the tenant's PAT (config(tenant).github_pat) — so a multi-tenant
    #      host that only sets config_resolver gets per-tenant PATs for free, no override needed.
    # All DI seams, no registry — same idiom as the resolvers above.
    attr_writer :github_repos, :github_repos_resolver

    # Which seam is INSTALLED decides — never what a seam happened to return. Same shape as
    # mcp_servers_for below.
    #
    # This was an `||` chain, and that conflated two opposite facts: a resolver returning nil means
    # "THIS TENANT HAS NO GITHUB", not "ask someone else". The chain walked on to the static override
    # and then to the operator's own PAT, so a tenant with no GitHub App installation was shown — and
    # could act in — the operator's repositories. Cross-tenant exposure, and it looked perfectly normal.
    # A resolver, once installed, is the sole authority for every tenant; nil is its answer, and callers
    # render the "no GitHub" empty state.
    def github_repos(tenant = nil)
      return @github_repos_resolver.call(tenant) if @github_repos_resolver
      return @github_repos if @github_repos

      Rbrun::GithubRepos.new(pat: config(tenant).github_pat)
    end

    # The external MCP servers to materialize for a turn, scoped to (tenant, repo). Defaults to the
    # tenant's enabled DB rows (self-host / DB path); a host sets Rbrun.mcp_resolver (the SaaS
    # injection seam) to supply per-(tenant, repo) servers carrying live secrets. Same idiom as
    # config_resolver / github_repos_resolver: reentrant, set-once, pure read. Returns McpServer::Spec[].
    attr_writer :mcp_resolver

    def mcp_servers_for(tenant, repo)
      return @mcp_resolver.call(tenant, repo) if @mcp_resolver

      Rbrun::McpServer.for_tenant(tenant).where(enabled: true).map(&:to_spec)
    end
  end
end
