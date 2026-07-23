require "yaml"

module Rbrun
  # Reads a skill folder's hand-authored `scenarios/*.yml` and upserts each into a skill-bound
  # Rbrun::Workflow (the scenario) — the DB seed the dogfood board replays. Autoloaded + testable (not
  # buried in a rake). The `scenarios/` folder is excluded from the staged archive (Rbrun::SkillArchive)
  # — these drive eval, they never reach the agent's workspace.
  module SkillScenarios
    module_function

    # Upsert every scenarios/*.yml under `dir` into SkillScenario rows for `skill` (keyed [skill,
    # label]). Idempotent; returns the count upserted.
    def ingest(skill, dir)
      Dir.glob(File.join(dir, "scenarios", "*.yml")).sort.count { |path| upsert(skill, path) }
    end

    # One scenario YAML → one skill-bound Workflow (the scenario). Blank label ⇒ skipped (false).
    # Find-or-create by [skill, label]; the steps are rebuilt so re-ingest converges (idempotent).
    def upsert(skill, path)
      data  = YAML.safe_load(File.read(path)) || {}
      label = data["label"].to_s.strip
      return false if label.blank?

      steps = Array(data["steps"]).each_with_index.map do |s, i|
        { position: i + 1, title: s["label"].to_s, description: s["description"].to_s }
      end

      workflow = skill.workflows.for_tenant(skill.tenant).find_or_initialize_by(label:)
      workflow.assign_attributes(prompt: data["prompt"].to_s, goal: data["description"].to_s)
      workflow.steps.destroy_all if workflow.persisted? # idempotent rebuild
      workflow.steps.build(steps)
      workflow.save!
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

    # Reconcile a SEED/SCRATCH tenant to its authored sources: destroy skills no longer authored on disk
    # (cascading their versions + scenario workflows) and, for surviving skills, destroy scenario
    # workflows whose label is no longer in the folder's scenarios/*.yml. Returns the count reaped.
    #
    # DESTRUCTIVE and one-directional — the authored files are the truth. Use ONLY for a tenant whose
    # skills/scenarios come solely from folders (the dogfood tenant). NEVER call it for a tenant whose
    # users author skills or scenarios in the UI — it would delete their work. This is why reaping is
    # opt-in here and never folded into `ingest`/`ingest_all` (which stay purely additive).
    def reap_unauthored!(tenant, config)
      authored_slugs = Rbrun::SkillSeeder.authored_from_config(config).map { |a| a[:slug] }.to_set
      labels_by_slug = scenario_labels_by_slug(config)
      reaped = 0

      Rbrun::Skill.for_tenant(tenant).find_each do |skill|
        unless authored_slugs.include?(skill.slug)
          reaped += 1 + skill.workflows.count
          skill.destroy! # a removed skill — cascade its versions + scenario workflows
          next
        end

        keep = labels_by_slug[skill.slug] || Set.new
        skill.workflows.reject { |wf| keep.include?(wf.label) }.each do |stale|
          stale.destroy!
          reaped += 1
        end
      end
      reaped
    end

    # { skill_slug => Set[scenario label] } read from each authored folder's scenarios/*.yml.
    def scenario_labels_by_slug(config)
      folders_with_scenarios(config).each_with_object({}) do |folder, map|
        labels = Dir.glob(File.join(folder, "scenarios", "*.yml")).filter_map do |path|
          (YAML.safe_load(File.read(path)) || {})["label"].to_s.strip.presence
        end
        map[File.basename(folder)] = labels.to_set
      end
    end
  end
end
