class CreateRbrunSkills < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_skills do |t|
      t.string Rbrun.config.tenancy_key, null: false
      t.string :slug, null: false
      t.string :name, null: false
      t.bigint :current_version_id            # → rbrun_skill_versions (set after the version exists)
      t.string :divergence_digest             # authored source differs from current + dismissed
      t.string :dismissed_digest              # a reviewed authored digest the user chose to keep-stored over
      t.timestamps
    end
    add_index :rbrun_skills, [ Rbrun.config.tenancy_key, :slug ], unique: true
  end
end
