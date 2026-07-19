# frozen_string_literal: true

module Rbrun
  # Boot-time configuration for the engine and its provider families.
  # Filled by the host in one initializer: Rbrun.configure { |c| ... }.
  class Config
    DEFAULT_TENANT = "rbrun"
    FAMILIES = %i[sandbox runtime dns server].freeze

    attr_accessor :database_connection, :subprocess_timeout, :github_pat, :tenancy_key, :system_prompt
    attr_reader :users

    def initialize
      @database_connection = :rbrun
      @subprocess_timeout  = 900
      @github_pat          = nil
      @tenancy_key         = "tenant"
      @users               = []
      @providers           = {}
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

    FAMILIES.each do |family|
      define_method("#{family}_provider") { @providers[family] || {} }
      define_method("#{family}_provider=") { |hash| @providers[family] = hash }
    end

    # Auth is mandatory: at least one built-in user, or a host-supplied current_user resolver.
    def auth_configured? = users.any? || !Rbrun.instance_variable_get(:@current_user_resolver).nil?

    def validate!
      return if auth_configured?

      raise Rbrun::ConfigError,
            "rbrun requires auth: define at least one c.user (or set Rbrun.current_user_resolver)"
    end
  end

  class << self
    def config
      @config ||= Config.new
    end

    def configure
      yield config
      config
    end

    def reset_config!
      @config = Config.new
    end
  end
end
