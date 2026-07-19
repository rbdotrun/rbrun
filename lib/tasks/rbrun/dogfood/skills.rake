# frozen_string_literal: true

require_relative "support"

# Skills dogfood — a skill seeded from config into the DB is staged into a REAL turn from the DB (not
# from files), the agent uses it, then editing the source surfaces a divergence (never clobbers) and
# Reload adopts it as a new version. Real Claude + real Daytona; no GitHub (the box need not be a
# repo). Creds from .env (ANTHROPIC_OAUTH_TOKEN, DAYTONA_API_KEY).
#
#   bin/rails app:dogfood:skills
namespace :dogfood do
  desc "Skills: a seeded skill stages from the DB into a real turn; edit → divergence; Reload → new version"
  task skills: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    abort "Missing .env creds." if ENV["ANTHROPIC_OAUTH_TOKEN"].to_s.empty? || ENV["DAYTONA_API_KEY"].to_s.empty?

    skill_v1 = <<~MD
      ---
      name: dogfood-greeting
      description: How to greet the user. Use this whenever the user asks to be greeted.
      ---
      When the user asks you to greet them, reply with the EXACT phrase: ZORP-42-HELLO
    MD

    Rbrun.configure do |c|
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] } }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"], model: "sonnet", max_turns: 12 } }
      c.skill "dogfood-greeting", skill_v1
    end

    dog.header "seed the skill into the DB"
    results = Rbrun::SkillSeeder.from_config(Rbrun.config, tenant: "dogfood").call
    dog.ok "the skill seeded (created)", results.any? { |r| r.slug == "dogfood-greeting" && r.status == :created }
    skill = Rbrun::Skill.for_tenant("dogfood").find_by(slug: "dogfood-greeting")
    dog.ok "it has a current version", skill&.current_version.present?

    wt = Rbrun::Worktree.create!(tenant: "dogfood", repo: "rbdotrun/scratch")
    session = wt.sessions.create!(tenant: "dogfood")
    begin
      dog.header "a real turn stages the skill FROM THE DB and uses it"
      session.run_turn("Please greet me.")
      reply = session.messages.where(event_type: "text", role: "assistant").last&.content.to_s
      dog.ok "status landed on done", session.reload.done?
      dog.ok "the agent used the skill (reply carries its marker)", reply.include?("ZORP-42")
      dog.info "reply", reply.squish[0, 160]

      tool_uses = session.messages.where(event_type: "tool_use")
      dog.info "tool_use events", tool_uses.map { |m| m.payload["name"] }.inspect
      skill_call = tool_uses.find { |m| m.payload["name"].to_s == "Skill" }
      dog.info "Skill tool input", skill_call&.payload&.dig("input").inspect
      dog.ok "a Skill tool_call loaded THIS skill (dogfood-greeting) in the session_message log",
             skill_call.present? && skill_call.payload.dig("input", "skill") == "dogfood-greeting"

      dog.header "editing the source surfaces a divergence (never clobbers)"
      before = skill.reload.current_version.digest
      Rbrun.config.skills.clear
      Rbrun.config.skill "dogfood-greeting", skill_v1.sub("ZORP-42-HELLO", "ZORP-99-BYE")
      Rbrun::SkillSeeder.from_config(Rbrun.config, tenant: "dogfood").call
      dog.ok "current is untouched", skill.reload.current_version.digest == before
      dog.ok "the divergence is flagged", skill.diverged?

      dog.header "Reload adopts the edit as a new version"
      authored = Rbrun::SkillSeeder.authored_from_config(Rbrun.config).find { |a| a[:slug] == "dogfood-greeting" }
      skill.promote!(digest: Rbrun::SkillArchive.digest_files(authored[:files]),
                     archive: Rbrun::SkillArchive.pack_files(authored[:files]), source: :inline)
      dog.ok "current advanced + divergence cleared",
             skill.reload.current_version.digest != before && !skill.diverged?
    ensure
      session.sandbox.destroy!
      wt.destroy!
      skill&.destroy!
    end
  end
end
