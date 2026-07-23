module Rbrun
  # Seeds c.mcp_server declarations into the DB — the one place config becomes an McpServer row.
  # COMPARE-never-clobber via config_digest: an edited DB row whose config differs from the source is
  # left intact and warned, never overwritten. Simpler than skills (a flat config record, no folder
  # diff) — no version history, no reconcile UI. The SaaS path never runs this (resolver-driven).
  class McpSeeder
    Result = Data.define(:name, :status) # :created | :unchanged | :diverged

    def self.from_config(config, tenant:)
      new(tenant:, authored: config.mcp_servers)
    end

    # Boot hook (engine after_initialize): warn-only, self-host tenant. No-ops (silent) when nothing is
    # configured or the DB / table isn't there yet.
    def self.seed_at_boot!
      return if Rbrun.config.mcp_servers.empty?
      return unless Rbrun::McpServer.table_exists?

      from_config(Rbrun.config, tenant: Rbrun::Config::DEFAULT_TENANT).call.each do |r|
        next unless r.status == :diverged

        Rails.logger.warn("[rbrun] mcp server '#{r.name}' diverged from its config — the DB row was left intact")
      end
    rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished => e
      Rails.logger.debug { "[rbrun] mcp seed skipped (#{e.class})" }
    end

    def initialize(tenant:, authored:)
      @tenant = tenant
      @authored = authored
    end

    def call = @authored.map { |authored| seed_one(authored) }

    private

      def seed_one(authored)
        candidate = Rbrun::McpServer.new(authored.merge(tenant: @tenant))
        row = Rbrun::McpServer.for_tenant(@tenant).find_by(name: authored[:name])

        if row.nil?
          candidate.save!
          Result.new(authored[:name], :created)
        elsif row.config_digest == candidate.compute_digest
          Result.new(authored[:name], :unchanged)
        else
          Result.new(authored[:name], :diverged) # never overwrite an edited row
        end
      end
  end
end
