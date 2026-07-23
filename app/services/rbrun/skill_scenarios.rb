require "yaml"

module Rbrun
  # Reads a skill folder's hand-authored `scenarios/*.yml` and upserts them into SkillScenario rows —
  # the DB seed the dogfood board replays. Autoloaded + testable (not buried in a rake). The
  # `scenarios/` folder is excluded from the staged archive (Rbrun::SkillArchive) — these drive eval,
  # they never reach the agent's workspace.
  module SkillScenarios
    module_function

    # Upsert every scenarios/*.yml under `dir` into SkillScenario rows for `skill` (keyed [skill,
    # label]). Idempotent; returns the count upserted.
    def ingest(skill, dir)
      Dir.glob(File.join(dir, "scenarios", "*.yml")).sort.count { |path| upsert(skill, path) }
    end

    # One scenario YAML → a SkillScenario row. Blank label ⇒ skipped (false).
    def upsert(skill, path)
      data  = YAML.safe_load(File.read(path)) || {}
      label = data["label"].to_s.strip
      return false if label.blank?

      steps = Array(data["steps"]).map do |s|
        { "label" => s["label"].to_s, "description" => s["description"].to_s }
      end

      scenario = Rbrun::SkillScenario.for_tenant(skill.tenant).find_or_initialize_by(skill: skill, label: label)
      scenario.update!(description: data["description"], prompt: data["prompt"].to_s,
                       steps: steps, attachments: Array(data["attachments"]).map(&:to_s))
      true
    end

    # Ingest scenarios for every skill folder (engine built-ins + skills_path) that has a scenarios/
    # dir, matched to the tenant's Skill by slug. Idempotent. Returns the count of scenarios upserted.
    def ingest_all(tenant, config)
      folders_with_scenarios(config).sum do |folder|
        skill = Rbrun::Skill.for_tenant(tenant).find_by(slug: File.basename(folder))
        skill ? ingest(skill, folder) : 0
      end
    end

    def folders_with_scenarios(config)
      dirs = []
      dirs.concat(Dir.glob(Rbrun::SkillSeeder::BUILTIN_DIR.join("*").to_s)) if Rbrun::SkillSeeder::BUILTIN_DIR.exist?
      path = config.skills_path.to_s
      dirs.concat(Dir.glob(File.join(path, "*"))) if path.present? && Dir.exist?(path)
      dirs.select { |d| File.directory?(d) && Dir.exist?(File.join(d, "scenarios")) }.sort
    end
  end
end
