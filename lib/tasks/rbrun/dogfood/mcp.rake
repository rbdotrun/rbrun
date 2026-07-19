# frozen_string_literal: true

require_relative "support"

# External MCP dogfood — an always_allow stdio server, seeded into the DB, materialized from the DB
# into a REAL turn and connected by the SDK: the agent calls the server's tool and its result
# round-trips. Uses the canonical @modelcontextprotocol/server-everything (an `echo` tool), launched
# with bunx (bun is guaranteed in the box; node/npx may not be). Real Claude + Daytona, no stubs.
# Creds from .env (ANTHROPIC_OAUTH_TOKEN, DAYTONA_API_KEY). always_allow ⇒ no dependency on the M-T8
# approval branch.
#
#   bin/rails app:dogfood:mcp
namespace :dogfood do
  desc "MCP: an always_allow external stdio server (from the DB) is connected in a real turn; the agent calls its tool"
  task mcp: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    abort "Missing .env creds." if ENV["ANTHROPIC_OAUTH_TOKEN"].to_s.empty? || ENV["DAYTONA_API_KEY"].to_s.empty?

    Rbrun.configure do |c|
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] } }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"], model: "sonnet", max_turns: 12 } }
      c.mcp_server name: "everything", transport: :stdio,
                   command: "bunx", args: [ "@modelcontextprotocol/server-everything" ],
                   tools: [ "echo" ], tool_permissions: { default: :always_allow }
    end

    dog.header "seed the MCP server into the DB"
    Rbrun::McpSeeder.from_config(Rbrun.config, tenant: "dogfood").call
    server = Rbrun::McpServer.for_tenant("dogfood").find_by(name: "everything")
    dog.ok "the server seeded (enabled)", server&.enabled?

    wt = Rbrun::Worktree.create!(tenant: "dogfood", repo: "rbdotrun/dogfood", base: "main")
    session = wt.sessions.create!(tenant: "dogfood")
    begin
      dog.header "a real turn materializes the server FROM THE DB and calls its tool"
      session.run_turn("Call the 'everything' MCP server's echo tool with exactly: MCPPING-7. Then tell me the exact text it returned.")
      dog.ok "status landed on done", session.reload.done?

      tool_uses = session.messages.where(event_type: "tool_use")
      dog.info "tool_use events", tool_uses.map { |m| m.payload["name"] }.inspect
      echo_call = tool_uses.find { |m| m.payload["name"].to_s.include?("everything") }
      dog.ok "an external MCP tool_call (mcp__everything__*) is in the log", echo_call.present?
      if echo_call
        result = session.messages.find_by(event_type: "tool_result", tool_use_id: echo_call.tool_use_id)
        dog.ok "the external tool returned (no error)", result && !result.payload["is_error"]
      end

      reply = session.messages.where(event_type: "text", role: "assistant").last&.content.to_s
      dog.ok "the echo round-tripped end to end (reply carries MCPPING-7)", reply.include?("MCPPING-7")
      dog.info "reply", reply.squish[0, 160]
    ensure
      session.sandbox.destroy!
      wt.destroy!
      server&.destroy!
    end
  end
end
