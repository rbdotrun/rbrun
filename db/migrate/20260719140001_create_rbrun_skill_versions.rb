class CreateRbrunSkillVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_skill_versions do |t|
      t.references :skill, null: false, foreign_key: { to_table: :rbrun_skills }
      t.string :digest, null: false          # content hash of the folder (SkillArchive.digest)
      t.binary :archive, null: false         # the folder as one gzipped-tar blob
      t.string :source, null: false          # file | inline | ui
      t.datetime :created_at, null: false
    end
    add_index :rbrun_skill_versions, %i[skill_id digest], unique: true
  end
end
