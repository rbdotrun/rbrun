# frozen_string_literal: true

require_relative "support"

# THE dogfood board — the scenario way (like insitix). Every skill's hand-authored scenarios/*.yml is
# seeded as a SkillScenario (prompt + the steps it should produce, each step's description = what to
# validate); this seeds the skills, ingests the scenarios, replays each as a SELF-VALIDATING autonomous
# run (the agent does the work, validates each step against its own tool-call evidence, self-approves via
# auto mode), and prints the verdict. Real Claude + real Daytona. Creds from .env.
#
#   bin/rails app:dogfood:scenarios
namespace :dogfood do
  desc "Replay every seeded SkillScenario as a self-validating run (the dogfood board)"
  task scenarios: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    abort "Missing .env creds." if ENV["ANTHROPIC_OAUTH_TOKEN"].to_s.empty? || ENV["DAYTONA_API_KEY"].to_s.empty?

    Rbrun.configure do |c|
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] } }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"], model: "sonnet", max_turns: 16 } }
    end

    tenant = "dogfood"
    dog.header "seed the skills + ingest their scenarios (idempotent)"
    Rbrun::SkillSeeder.new(tenant: tenant, authored: Rbrun::SkillSeeder.builtin_authored).call
    ingested = Rbrun::SkillScenarios.ingest_all(tenant, Rbrun.config)
    dog.ok "scenarios ingested", ingested.positive?

    scenarios = Rbrun::SkillScenario.for_tenant(tenant).includes(:skill).order(:skill_id, :label)
    if scenarios.empty?
      puts "no scenarios seeded — add scenarios/*.yml under a skill folder."
      next
    end

    passed = 0
    scenarios.each do |scenario|
      dog.header "#{scenario.skill.slug} · #{scenario.label}"
      record = Rbrun::SkillScenarioRun.run(scenario, tenant: tenant)
      passed += 1 if record[:pass]
      record[:steps].each do |step|
        dog.ok "#{step[:label]}", step[:done]
      end
      mark = record[:pass] ? "✓" : "✗"
      puts format("%s  %s · %-32s  %s/%s", mark, scenario.skill.slug, scenario.label, record[:done], record[:total])
    end

    puts "\n— #{passed}/#{scenarios.size} scenarios passed"
  end
end
