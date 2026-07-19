# frozen_string_literal: true

module Rbrun
  # Boot-time configuration for the engine and its provider families.
  # Filled by the host in one initializer: Rbrun.configure { |c| ... }.
  class Config
    DEFAULT_TENANT = "rbrun"
    FAMILIES = %i[sandbox runtime dns server].freeze

    attr_accessor :database_connection, :subprocess_timeout, :github_pat, :tenancy_key
    attr_reader :users

    def initialize
      @database_connection = :rbrun
      @subprocess_timeout  = 900
      @github_pat          = nil
      @tenancy_key         = "tenant"
      @users               = []
      @providers           = {}
    end

    # Repeatable: append one login identity. Omitted tenant ⇒ DEFAULT_TENANT.
    def user(email:, password:, tenant: DEFAULT_TENANT)
      @users << { email: email, password: password, tenant: tenant }
    end

    FAMILIES.each do |family|
      define_method("#{family}_provider") { @providers[family] || {} }
      define_method("#{family}_provider=") { |hash| @providers[family] = hash }
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
