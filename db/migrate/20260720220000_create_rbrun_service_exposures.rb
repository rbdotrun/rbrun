class CreateRbrunServiceExposures < ActiveRecord::Migration[8.1]
  def change
    # Per-[worktree, name] exposure intent + the stable single-label preview token. A preview host must
    # resolve to ONE sandbox's service, so the token lives here (per worktree) — NOT on RepoService
    # (repo-level) nor ServiceRun (destroyed on every start-reset). Survives the reset; the flags moved
    # here from RepoService because they are per-worktree decisions.
    create_table :rbrun_service_exposures do |t|
      t.references :worktree, null: false, foreign_key: { to_table: :rbrun_worktrees }
      t.string  Rbrun.config.tenancy_key, null: false
      t.string  :name,          null: false
      t.string  :preview_token
      t.boolean :previewed,     null: false, default: false
      t.boolean :shared_public, null: false, default: false
      t.timestamps
    end
    add_index :rbrun_service_exposures, [ :worktree_id, :name ], unique: true
    add_index :rbrun_service_exposures, :preview_token, unique: true

    # The per-worktree flags supersede these repo-level ones; RepoService goes back to just the command set.
    remove_column :rbrun_repo_services, :previewed,     :boolean, null: false, default: false
    remove_column :rbrun_repo_services, :shared_public, :boolean, null: false, default: false
    remove_column :rbrun_repo_services, :preview_token, :string
  end
end
