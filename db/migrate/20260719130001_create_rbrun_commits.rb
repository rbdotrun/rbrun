class CreateRbrunCommits < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_commits do |t|
      t.references :worktree, null: false, foreign_key: { to_table: :rbrun_worktrees }
      t.references :session,  null: true,  foreign_key: { to_table: :rbrun_sessions }
      t.string :sha, null: false
      t.text   :message
      t.timestamps
    end
    add_index :rbrun_commits, %i[worktree_id sha], unique: true
  end
end
