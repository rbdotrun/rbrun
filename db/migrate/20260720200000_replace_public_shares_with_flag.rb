class ReplacePublicSharesWithFlag < ActiveRecord::Migration[8.1]
  def change
    # Level 3 is now the provider's own public switch, not an rbrun-owned reverse proxy, so a share is
    # just declared intent — the same shape as `previewed`, on the definition so it survives the
    # repo_services_start reset. The opaque-token table existed only to address our proxy edge.
    add_column :rbrun_repo_services, :shared_public, :boolean, null: false, default: false

    drop_table :rbrun_public_shares, if_exists: true do |t|
      t.references :worktree, null: false
      t.string :tenant, null: false
      t.string :name,  null: false
      t.string :token, null: false
      t.timestamps
    end
  end
end
