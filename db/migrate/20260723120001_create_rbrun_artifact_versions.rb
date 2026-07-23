class CreateRbrunArtifactVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_artifact_versions do |t|
      t.references :artifact, null: false, foreign_key: { to_table: :rbrun_artifacts }
      t.references :message,  null: false, foreign_key: { to_table: :rbrun_session_messages }
      t.integer :number, null: false          # 1-based, per artifact
      t.timestamps
    end
    add_index :rbrun_artifact_versions, %i[artifact_id number], unique: true
  end
end
