# frozen_string_literal: true

require_relative "support"

# Plan A dogfood — the create-skill SKILL, end to end. The skill is staged into a REAL turn whose
# session prefers it (preferred_skills → system-prompt steer); a natural "make me a skill" prompt must
# TRIGGER the skill, author a folder, and call save_skill; approving promotes it. This exercises the
# whole drawer flow (minus the browser). Real Claude + real Daytona. Creds from .env.
#
#   bin/rails app:dogfood:create_skill
namespace :dogfood do
  desc "Plan A: the create-skill skill triggers on a natural prompt, authors + save_skill → promoted"
  task create_skill: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    abort "Missing .env creds." if ENV["ANTHROPIC_OAUTH_TOKEN"].to_s.empty? || ENV["DAYTONA_API_KEY"].to_s.empty?

    Rbrun.configure do |c|
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] } }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"], model: "sonnet", max_turns: 16 } }
    end

    new_slug = "dad-joke"
    dog.header "seed the create-skill skill for the tenant + reap prior state"
    Rbrun::Skill.for_tenant("dogfood").where(slug: [ "create-skill", new_slug ]).destroy_all
    md = File.read(Rbrun::Engine.root.join("app/skills/create-skill/SKILL.md"))
    files = { "SKILL.md" => md }
    creator = Rbrun::Skill.for_tenant("dogfood").create!(slug: "create-skill", name: "Create Skill")
    creator.promote!(digest: Rbrun::SkillArchive.digest_files(files), archive: Rbrun::SkillArchive.pack_files(files), source: :file)
    dog.ok "create-skill is staged for the tenant", creator.reload.current_version.present?

    wt = Rbrun::Worktree.create!(tenant: "dogfood", repo: "rbrun/skills")
    session = wt.sessions.create!(tenant: "dogfood", preferred_skills: %w[create-skill])
    begin
      dog.header "a natural prompt triggers create-skill, authors + calls save_skill"
      session.run_turn(
        "I want a skill called #{new_slug} that makes you tell a single dad joke whenever the user " \
        "asks for one. Build it and save it."
      )
      session.reload

      tool_uses = session.messages.where(event_type: "tool_use")
      dog.info "tool_use events", tool_uses.map { |m| m.payload["name"] }.inspect
      skill_call = tool_uses.find { |m| m.payload["name"].to_s == "Skill" }
      dog.ok "the create-skill skill TRIGGERED",
             skill_call.present? && skill_call.payload.dig("input", "skill") == "create-skill"

      frozen = session.messages.approval_pending.last
      dog.ok "it parked on save_skill (gate)", frozen&.payload&.dig("name") == "save_skill"
      dog.info "save_skill args", frozen&.payload&.dig("input").inspect
      dog.ok "nothing promoted before approval",
             Rbrun::Skill.for_tenant("dogfood").where(slug: new_slug).none?

      dog.header "approve → the authored skill is promoted"
      frozen.decide_approval!("approve") if frozen
      made = Rbrun::Skill.for_tenant("dogfood").find_by(slug: new_slug)
      dog.ok "the '#{new_slug}' skill was promoted", made&.current_version.present?
      dog.ok "its source is 'ui' (authored in-app)", made&.current_version&.source == "ui"
    ensure
      Rbrun::Skill.for_tenant("dogfood").where(slug: [ "create-skill", new_slug ]).destroy_all
      session.sandbox.destroy!
      wt.destroy!
    end
  end
end
