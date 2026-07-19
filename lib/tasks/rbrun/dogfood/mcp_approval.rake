# frozen_string_literal: true

require_relative "support"

# External MCP approval dogfood (M-T8, R3) — a needs_approval external tool PARKS the run (canUseTool
# gate), and on approval the SERVER executes it on resume (NOT Ruby): the resume run carries the
# approved tool name so canUseTool allows it. Real Claude + Daytona. Creds from .env.
#
#   bin/rails app:dogfood:mcp_approval
namespace :dogfood do
  desc "MCP approval: a needs_approval external tool parks → approve → the server executes it on resume"
  task mcp_approval: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    abort "Missing .env creds." if ENV["ANTHROPIC_OAUTH_TOKEN"].to_s.empty? || ENV["DAYTONA_API_KEY"].to_s.empty?

    Rbrun.configure do |c|
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] } }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"], model: "sonnet", max_turns: 12 } }
      c.mcp_server name: "everything", transport: :stdio,
                   command: "bunx", args: [ "@modelcontextprotocol/server-everything" ],
                   tools: [ "echo" ], tool_permissions: { default: :needs_approval } # ← gated
    end

    Rbrun::McpSeeder.from_config(Rbrun.config, tenant: "dogfood").call
    server = Rbrun::McpServer.for_tenant("dogfood").find_by(name: "everything")
    wt = Rbrun::Worktree.create!(tenant: "dogfood", repo: "rbdotrun/dogfood", base: "main")
    session = wt.sessions.create!(tenant: "dogfood")
    begin
      dog.header "the external tool PARKS the run (needs_approval gate)"
      session.run_turn("Call the 'everything' MCP server's echo tool with exactly: MCPGATE-9. Then tell me the exact text it returned.")
      session.reload
      frozen = session.messages.approval_pending.last
      dog.ok "the run parked (status=needs_approval)", session.needs_approval?
      dog.ok "a pending MCP tool_use row was frozen", frozen.present?
      dog.ok "it froze the external tool with tool_kind=mcp", frozen&.payload&.dig("tool_kind") == "mcp"
      dog.ok "NOTHING ran in Ruby: no successful result for the frozen call (Ruby never executes mcp tools)",
             frozen && session.messages.where(event_type: "tool_result", tool_use_id: frozen.tool_use_id)
                              .none? { |r| r.payload["is_error"] == false }
      dog.info "frozen tool", frozen&.payload&.dig("name")

      dog.header "approve → the SERVER executes it on resume (not Ruby)"
      nudge = frozen.decide_approval!("approve")
      dog.ok "approval nudged the resume (no Ruby exec)", nudge.to_s.include?("Call it again")
      session.continue_turn!(nudge)
      session.reload

      reply = session.messages.where(event_type: "text", role: "assistant").last&.content.to_s
      executed = session.messages.where(event_type: "tool_result")
                        .any? { |r| r.payload["is_error"] == false && r.content.to_s.include?("MCPGATE-9") }
      dog.ok "the SERVER executed the tool on resume (successful mcp tool_result)", executed
      dog.ok "the turn resumed to done", session.done?
      dog.ok "the echo round-tripped after approval (reply carries MCPGATE-9)", reply.include?("MCPGATE-9")
      dog.info "reply", reply.squish[0, 160]
    ensure
      session.sandbox.destroy!
      wt.destroy!
      server&.destroy!
    end
  end
end
