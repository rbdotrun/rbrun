# frozen_string_literal: true

require_relative "support"

# Phase 5 dogfood — the approval gate, for real. A needs_approval! tool must PARK the run: the SDK's
# canUseTool has to fire and interrupt, and the engine must freeze a pending row with nothing run.
# The stubbed test can't see canUseTool; this can. Creds from .env.
#
#   bin/rails app:dogfood:gate

namespace :dogfood do
  desc "Phase 5: a needs_approval! tool actually parks the run (frozen pending row, nothing executed)"
  task gate: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    abort "Missing .env creds." if ENV["ANTHROPIC_OAUTH_TOKEN"].to_s.empty? || ENV["DAYTONA_API_KEY"].to_s.empty?

    # Defined here (after :environment) — ApplicationTool is autoloaded, not available at rake-load
    # time. An irreversible demo tool, declared needs_approval!.
    demo = Class.new(Rbrun::ApplicationTool) do
      description "Deploy the app to production. Irreversible."
      needs_approval!
      parameter :target, type: "string", description: "environment", required: false
      def execute(target: "production") = { "data" => "deployed to #{target}" }
      def name = "dogfood_deploy"
    end

    Rbrun.configure do |c|
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] } }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"], model: "sonnet", max_turns: 12 } }
    end
    Rbrun.register_tool(demo)

    worktree = Rbrun::Worktree.create!(tenant: "dogfood", repo: "rbdotrun/dogfood", base: "main")
    session  = worktree.sessions.create!
    begin
      session.run_turn("Deploy the app to production now, using the dogfood_deploy tool.")
      session.reload
      frozen = session.messages.approval_pending.last

      dog.header "the gate"
      dog.ok "the run PARKED on the owner (status=needs_approval)", session.needs_approval?
      dog.ok "a pending tool_use row was frozen", frozen.present?
      dog.ok "it froze dogfood_deploy, not something else", frozen&.payload&.dig("name") == "dogfood_deploy"
      dog.ok "NOTHING ran: no tool_result for the frozen call",
             frozen && session.messages.where(event_type: "tool_result", tool_use_id: frozen.tool_use_id).none?

      if !session.needs_approval? && session.messages.any? { |m| m.event_type == "tool_result" && m.payload.dig("result").to_s.include?("deployed") }
        puts "\n✗✗ THE GATE WAS BYPASSED — dogfood_deploy RAN without asking."
      end
    ensure
      session.sandbox.destroy!
      worktree.destroy!
    end
  end
end
