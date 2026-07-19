class CreateRbrunWorktrees < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_worktrees do |t|
      t.string Rbrun.config.tenancy_key, null: false
      t.string :repo,   null: false   # "owner/name"
      t.string :base,   null: false, default: "main"
      t.string :branch, null: false
      t.timestamps
    end
    add_index :rbrun_worktrees, Rbrun.config.tenancy_key
  end
end
