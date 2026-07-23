class CreateRbrunArtifacts < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_artifacts do |t|
      t.string Rbrun.config.tenancy_key, null: false
      t.string :name, null: false
      t.bigint :current_version_id            # → rbrun_artifact_versions (set after the version exists)
      t.timestamps
    end
    add_index :rbrun_artifacts, Rbrun.config.tenancy_key
  end
end
