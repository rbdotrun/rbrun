# frozen_string_literal: true

require_relative "support"

# Plan A dogfood — a REAL turn authors a skill folder and calls save_skill; the gate PARKS the run
# (a promoted skill steers every future turn, so a human confirms). Approving runs the frozen call,
# which packs the folder and promotes it as the tenant's current version (source: ui). Real Claude +
# real Daytona. Creds from .env (ANTHROPIC_OAUTH_TOKEN, DAYTONA_API_KEY).
#
#   bin/rails app:dogfood:save_skill
namespace :dogfood do
  desc "Plan A: a real turn authors a skill folder, save_skill parks on approval, approve → promoted"
  task save_skill: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    abort "Missing .env creds." if ENV["ANTHROPIC_OAUTH_TOKEN"].to_s.empty? || ENV["DAYTONA_API_KEY"].to_s.empty?

    Rbrun.configure do |c|
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] } }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"], model: "sonnet", max_turns: 12 } }
    end

    slug = "weather-tip"
    dog.header "reap prior dogfood skills (idempotency)"
    Rbrun::Skill.for_tenant("dogfood").where(slug:).destroy_all
    dog.ok "no prior '#{slug}' skill", Rbrun::Skill.for_tenant("dogfood").where(slug:).none?

    wt = Rbrun::Worktree.create!(tenant: "dogfood", repo: "rbdotrun/scratch")
    session = wt.sessions.create!(tenant: "dogfood")
    begin
      dog.header "a real turn authors the folder and calls save_skill"
      session.run_turn(
        "Author a new skill in a folder named `#{slug}`: create `#{slug}/SKILL.md` with YAML " \
        "frontmatter (name: Weather Tip, description: gives a weather tip) and a one-line body, " \
        "then promote it by calling the save_skill tool with folder_path: \"#{slug}\"."
      )
      session.reload
      frozen = session.messages.approval_pending.last

      dog.ok "the run PARKED on the owner (status=needs_approval)", session.needs_approval?
      dog.ok "it froze save_skill", frozen&.payload&.dig("name") == "save_skill"
      dog.info "frozen args", frozen&.payload&.dig("input").inspect
      dog.ok "nothing promoted yet (gate not bypassed)",
             Rbrun::Skill.for_tenant("dogfood").where(slug:).none?

      dog.header "approving runs the frozen call → the skill is promoted"
      frozen.decide_approval!("approve") if frozen

      skill = Rbrun::Skill.for_tenant("dogfood").find_by(slug:)
      dog.ok "the skill was created", skill.present?
      dog.ok "it has a current version", skill&.current_version.present?
      dog.ok "the version's source is 'ui' (authored in-app)", skill&.current_version&.source == "ui"
      staged = skill && Rbrun::SkillArchive.files(skill.current_version.archive)
      dog.ok "the archive carries a SKILL.md", staged&.key?("SKILL.md") == true
    ensure
      Rbrun::Skill.for_tenant("dogfood").where(slug:).destroy_all
      session.sandbox.destroy!
      wt.destroy!
    end
  end
end
