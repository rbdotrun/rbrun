class CreateRbrunPublicShares < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_public_shares do |t|
      t.references :worktree, null: false, foreign_key: { to_table: :rbrun_worktrees }
      t.string Rbrun.config.tenancy_key, null: false
      t.string :name,  null: false
      t.string :token, null: false
      t.timestamps
    end
    add_index :rbrun_public_shares, :token, unique: true
    add_index :rbrun_public_shares, [ :worktree_id, :name ], unique: true
  end
end
