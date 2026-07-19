# frozen_string_literal: true

require_relative "support"

# Phase 5 dogfood — a real turn through Session#run_turn (real Claude + real Daytona box). Registers
# a demo tool, drives one turn, and reads the persisted event log. Creds from .env.
#
#   bin/rails app:dogfood:session_turn

namespace :dogfood do
  desc "Phase 5: a real turn runs through Session#run_turn, calls a tool, persists the log, ends done"
  task session_turn: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    abort "Missing .env creds." if ENV["ANTHROPIC_OAUTH_TOKEN"].to_s.empty? || ENV["DAYTONA_API_KEY"].to_s.empty?

    # Defined here (not at file top) so it loads AFTER the app environment — ApplicationTool is
    # autoloaded, not available at rake-load time. A demo tool the agent must call (auto, no approval).
    # `name` is overridden because an anonymous Class.new has no class name to demodulize.
    demo = Class.new(Rbrun::ApplicationTool) do
      description "Echo a short message back. Use this when asked to echo something."
      parameter :message, type: "string", description: "the text to echo", required: true
      def execute(message:) = { "data" => { "echoed" => message } }
      def name = "dogfood_echo"
    end

    Rbrun.configure do |c|
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] } }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"], model: "sonnet", max_turns: 12 } }
    end
    Rbrun.register_tool(demo)

    session = Rbrun::Session.create!(tenant: "dogfood")
    begin
      session.run_turn("Call the dogfood_echo tool with the message 'pong', then tell me what it returned.")

      dog.header "the turn ran through the engine"
      dog.ok "status landed on done", session.reload.done?
      dog.ok "an assistant reply was persisted",
             session.messages.where(event_type: "text", role: "assistant").where.not(content: [ nil, "" ]).exists?

      dog.header "the tool bridge (via ApplicationTool)"
      call = session.messages.where(event_type: "tool_use").find { |m| m.payload["name"] == "dogfood_echo" }
      dog.ok "the agent called dogfood_echo", call.present?
      result = session.messages.find_by(event_type: "tool_result", tool_use_id: call&.tool_use_id)
      dog.ok "the tool ran and returned (no error)", result && !result.payload["is_error"]

      dog.header "no errors"
      dog.ok "no tool_result errored", session.messages.where(event_type: "tool_result").none? { |m| m.payload["is_error"] }
      dog.info "reply", session.messages.where(event_type: "text", role: "assistant").last&.content.to_s.squish[0, 160]
    ensure
      session.sandbox.destroy!
      session.destroy!
    end
  end
end
