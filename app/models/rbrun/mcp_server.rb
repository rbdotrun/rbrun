require "digest"
require "json"

module Rbrun
  # An external MCP server the agent may connect to during a run — declared in config (seeded) or
  # supplied per turn by Rbrun.mcp_resolver. Tenant-scoped; the runtime materializes it into mcp.json,
  # never reading config at turn time. Secret VALUES live in `env`/`headers` for the self-hosted path
  # (operator's choice, like config.github_pat); the SaaS path keeps secrets out of the DB and fills
  # them via the resolver's Spec.
  class McpServer < ApplicationRecord
    include Rbrun::Tenanted

    # The value object the resolver returns and the materializer consumes — already carrying live
    # secrets. The control plane constructs these directly: Rbrun::McpServer::Spec.new(...).
    Spec = Data.define(:name, :transport, :auth, :command, :args, :url, :env, :headers, :tools, :tool_permissions)

    enum :transport, { stdio: "stdio", http: "http" }
    enum :auth, { api_key: "api_key", bearer: "bearer", oauth: "oauth" }

    validates :name, :transport, presence: true

    before_save :assign_digest

    def to_spec
      Spec.new(name:, transport: transport&.to_sym, auth: auth&.to_sym, command:,
               args: args || [], url:, env: env || {}, headers: headers || {},
               tools:, tool_permissions: tool_permissions || {})
    end

    # A hash over the config that DEFINES the server — env/header KEYS only (secret values don't define
    # identity and aren't stored in the SaaS path). Stable across set reorderings (env keys, tools,
    # header keys); `args` stays ordered (it's a command line).
    def compute_digest
      Digest::SHA256.hexdigest(JSON.generate(
        transport:, auth:, command:, args: args || [], url:,
        env_keys: (env || {}).keys.map(&:to_s).sort, header_keys: (headers || {}).keys.map(&:to_s).sort,
        tools: (tools || []).map(&:to_s).sort, tool_permissions: tool_permissions || {}
      ))
    end

    private

      def assign_digest = self.config_digest = compute_digest
  end
end
