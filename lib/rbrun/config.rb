# frozen_string_literal: true

module Rbrun
  # Boot-time configuration for the engine and its provider families.
  # Filled by the host in one initializer: Rbrun.configure { |c| ... }.
  class Config
    DEFAULT_TENANT = "rbrun"
    FAMILIES = %i[sandbox runtime dns server].freeze
    MCP_TRANSPORTS = %i[stdio http].freeze
    MCP_AUTHS = %i[api_key bearer oauth].freeze

    attr_accessor :database_connection, :subprocess_timeout, :github_pat, :tenancy_key, :system_prompt,
                  :auth_managed_at_runtime, :skills_path, :preview_domain
    attr_reader :users, :skills, :mcp_servers

    def initialize
      @database_connection     = :rbrun
      @subprocess_timeout      = 900
      @github_pat              = nil
      @tenancy_key             = "tenant"
      @auth_managed_at_runtime = false
      @skills_path             = nil
      @preview_domain          = nil # e.g. "rb.run" — the domain deployed hosts live under (rbrun-w<id>.<preview_domain>)
      @users                   = []
      @skills                  = []
      @mcp_servers             = []
      @providers               = {}
      @system_prompt       = <<~PROMPT
        You are an assistant working inside a sandboxed workspace. Call the `identity` tool first to
        learn who you are working for. Use your tools to fulfil the request; when asked for a
        deliverable, build it. Never invent data — everything you present must come from your tools.
      PROMPT
    end

    # Repeatable: append one login identity. Omitted tenant ⇒ DEFAULT_TENANT.
    def user(email:, password:, tenant: DEFAULT_TENANT)
      @users << { email: email, password: password, tenant: tenant }
    end

    # Repeatable: append an inline skill (a seed source — the DB is the runtime store). Two forms:
    #   c.skill "pdf-report", <<~MD ... MD        # shorthand: slug + SKILL.md body
    #   c.skill slug: "invoice", name: "Invoice", files: { "SKILL.md" => "…", "t.tex" => "…" }
    # The shorthand may also carry files: for a multi-file inline skill. Collected here, read only by
    # the seeder; skills_path folders are the other seed source.
    def skill(shorthand_slug = nil, body = nil, slug: nil, name: nil, files: nil)
      if shorthand_slug
        slug  ||= shorthand_slug
        files ||= { "SKILL.md" => body.to_s }
      end
      slug or raise ArgumentError, "c.skill needs a slug (positional shorthand or slug:)"
      @skills << { slug: slug, name: name || slug, files: files || {} }
      nil
    end

    # Repeatable: declare an external MCP server (a seed source — the DB is the runtime store; the
    # SaaS path uses Rbrun.mcp_resolver instead). Fails fast on an unknown transport/auth.
    #   c.mcp_server name: "stripe", transport: :stdio, auth: :api_key, command: "npx",
    #                args: ["-y", "@stripe/mcp@latest"], env: { "STRIPE_SECRET_KEY" => "…" },
    #                tools: %w[create_payment_link], tool_permissions: { default: :needs_approval }
    #   c.mcp_server name: "linear", transport: :http, auth: :oauth, url: "https://mcp.linear.app"
    def mcp_server(name:, transport:, auth: nil, command: nil, args: [], url: nil, env: {}, headers: {}, tools: nil, tool_permissions: {})
      transport = transport.to_sym
      MCP_TRANSPORTS.include?(transport) or raise ArgumentError, "c.mcp_server transport must be one of #{MCP_TRANSPORTS.join('/')}"
      auth = auth&.to_sym
      auth.nil? || MCP_AUTHS.include?(auth) or raise ArgumentError, "c.mcp_server auth must be one of #{MCP_AUTHS.join('/')}"
      @mcp_servers << { name: name, transport: transport, auth: auth, command: command, args: args,
                        url: url, env: env, headers: headers, tools: tools, tool_permissions: tool_permissions }
      nil
    end

    FAMILIES.each do |family|
      define_method("#{family}_provider") { @providers[family] || {} }
      define_method("#{family}_provider=") { |hash| @providers[family] = hash }
    end

    # Auth is mandatory: at least one built-in user, a host-supplied current_user resolver, OR the
    # host running rbrun's built-in login with users created at runtime (invite/CRUD, empty at boot)
    # — signalled by c.auth_managed_at_runtime. Strict "no auth ⇒ no boot" stays the default.
    def auth_configured?
      users.any? ||
        !Rbrun.instance_variable_get(:@current_user_resolver).nil? ||
        auth_managed_at_runtime
    end

    def validate!
      return if auth_configured?

      raise Rbrun::ConfigError,
            "rbrun requires auth: define at least one c.user, set Rbrun.current_user_resolver, " \
            "or set c.auth_managed_at_runtime = true (built-in login, users created at runtime)"
    end
  end

  class << self
    # The static, process-global config — the boot-time truth (Rbrun.configure fills it) and the
    # source for process-global reads (database_connection, tenancy_key column, boot validate!).
    def config(tenant = nil)
      return @config_resolver.call(tenant) if tenant && @config_resolver

      @config ||= Config.new
    end

    def configure
      yield config
      config
    end

    def reset_config!
      @config = Config.new
      @config_resolver = nil
      @mcp_resolver = nil
    end

    # Host-set DI seam (same idiom as current_tenant_resolver / current_user_resolver): given a tenant
    # slug, return the Config to use for that tenant's per-tenant reads — sandbox_provider,
    # runtime_provider, github_pat, system_prompt. Consulted ONLY where a tenant is threaded in
    # (Rbrun.sandbox/runtime/config(tenant)); process-global reads always use the static global. When
    # unset, every tenant falls back to the static global, so self-hosting is byte-for-byte unchanged.
    # Keep it cheap/memoized — it is called several times per turn.
    attr_writer :config_resolver
  end
end
