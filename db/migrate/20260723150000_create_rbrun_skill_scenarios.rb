class CreateRbrunSkillScenarios < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_skill_scenarios do |t|
      t.string Rbrun.config.tenancy_key, null: false
      t.references :skill, null: false, foreign_key: { to_table: :rbrun_skills } # a scenario is always about a skill
      t.string :label, null: false          # names the case; unique per [tenant, skill]
      t.text :description                    # what the scenario demonstrates
      t.text :prompt, null: false            # the vague request to replay
      t.json :steps, null: false, default: [] # ordered [{label, description}] — the validation checklist
      t.json :attachments, null: false, default: [] # repo-relative fixture paths
      t.timestamps
    end
    add_index :rbrun_skill_scenarios, [ Rbrun.config.tenancy_key, :skill_id, :label ],
              unique: true, name: "idx_rbrun_skill_scenarios_unique"
  end
end
