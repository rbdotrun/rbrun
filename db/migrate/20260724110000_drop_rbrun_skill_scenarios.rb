class DropRbrunSkillScenarios < ActiveRecord::Migration[8.1]
  # Scenarios collapsed into skill-bound Rbrun::Workflow (Plan 2). The YAML seeds re-ingest into
  # workflows idempotently, so no data migration is needed.
  def up = drop_table :rbrun_skill_scenarios

  def down
    create_table :rbrun_skill_scenarios do |t|
      t.string  :tenant, null: false
      t.integer :skill_id, null: false
      t.string  :label, null: false
      t.text    :prompt, null: false
      t.text    :description
      t.json    :steps, null: false, default: []
      t.json    :attachments, null: false, default: []
      t.timestamps
      t.index %i[tenant skill_id label], unique: true, name: "idx_rbrun_skill_scenarios_unique"
      t.index :skill_id
    end
  end
end
