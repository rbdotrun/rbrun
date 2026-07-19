# frozen_string_literal: true

module Rbrun
  # Boot-time configuration for the engine and its provider families.
  # Filled by the host in one initializer: Rbrun.configure { |c| ... }.
  class Config
    DEFAULT_TENANT = "rbrun"
    FAMILIES = %i[sandbox runtime dns server].freeze

    attr_accessor :database_connection, :subprocess_timeout, :github_pat, :tenancy_key, :system_prompt,
                  :auth_managed_at_runtime, :skills_path
    attr_reader :users, :skills

    def initialize
      @database_connection     = :rbrun
      @subprocess_timeout      = 900
      @github_pat              = nil
      @tenancy_key             = "tenant"
      @auth_managed_at_runtime = false
      @skills_path             = nil
      @users                   = []
      @skills                  = []
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
