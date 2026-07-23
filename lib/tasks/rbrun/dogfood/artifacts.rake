# frozen_string_literal: true

require_relative "support"

# Artifacts dogfood — a REAL turn writes a file and calls save_artifact; a versioned artifact with an
# attached blob lands in the DB, scoped to the tenant, with provenance on the turn's lead message.
# Real Claude + real Daytona; no GitHub. Creds from .env (ANTHROPIC_OAUTH_TOKEN, DAYTONA_API_KEY).
#
#   bin/rails app:dogfood:artifacts
namespace :dogfood do
  desc "Artifacts: a real turn writes a file and save_artifact persists it as a versioned artifact"
  task artifacts: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    abort "Missing .env creds." if ENV["ANTHROPIC_OAUTH_TOKEN"].to_s.empty? || ENV["DAYTONA_API_KEY"].to_s.empty?

    Rbrun.configure do |c|
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] } }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"], model: "sonnet", max_turns: 12 } }
    end

    dog.header "reap prior dogfood artifacts (idempotency)"
    Rbrun::Artifact.for_tenant("dogfood").destroy_all
    dog.ok "no dogfood artifacts remain", Rbrun::Artifact.for_tenant("dogfood").none?

    wt = Rbrun::Worktree.create!(tenant: "dogfood", repo: "rbdotrun/scratch")
    session = wt.sessions.create!(tenant: "dogfood")
    begin
      dog.header "a real turn writes a file and calls save_artifact"
      session.run_turn(
        "Write a short markdown file called report.md containing a one-line status, " \
        "then save it as an artifact using the save_artifact tool."
      )
      dog.ok "status landed on done", session.reload.done?

      tool_uses = session.messages.where(event_type: "tool_use")
      dog.info "tool_use events", tool_uses.map { |m| m.payload["name"] }.inspect
      dog.ok "save_artifact was called", tool_uses.any? { |m| m.payload["name"].to_s == "save_artifact" }

      artifact = Rbrun::Artifact.for_tenant("dogfood").order(:id).last
      dog.ok "an artifact was persisted for the tenant", artifact.present?
      dog.ok "it has a current version with an attached blob",
             artifact&.current_version&.file&.attached? == true
      dog.ok "provenance points at this session's turn",
             artifact&.current_version&.message&.session_id == session.id
      dog.info "content_type", artifact&.current_version&.content_type
    ensure
      # Reap artifacts FIRST: their versions reference this session's messages, which wt.destroy!
      # deletes — so the worktree must go last, after nothing points at its messages.
      Rbrun::Artifact.for_tenant("dogfood").destroy_all
      session.sandbox.destroy!
      wt.destroy!
    end
  end
end
